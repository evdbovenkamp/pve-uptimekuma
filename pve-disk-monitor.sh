#!/usr/bin/env bash
#
# pve-disk-monitor.sh - disk-monitoring voor Proxmox VE hosts (alleen de host, geen VM's/LXC)
#
# Controleert lokale en USB-disks en meldt naar een Uptime Kuma *push* monitor
# (en optioneel een generieke JSON-webhook). Elke run stuurt een heartbeat:
#   status=up   -> alles OK (of alleen waarschuwingen, zie [kuma] down_severity)
#   status=down -> problemen; msg bevat een samenvatting
# Stopt het script met draaien, dan gaat de Kuma push monitor vanzelf down.
#
# Checks (te kiezen via [general] checks):
#   disks    verdwenen / opnieuw verbonden / verwachte disks (USB-disconnects)
#   smart    SMART-status, reallocated/pending sectors, CRC-fouten, temperatuur, NVMe-slijtage
#   kernel   I/O-fouten, USB-resets, link-resets, fs-fouten in de kernellog sinds vorige run
#   mounts   verwachte mountpoints: gemount, niet read-only, schrijfbaar, niet hangend
#   usage    vulgraad + inodes van lokale filesystems
#   zfs      pool-health, fouten, capaciteit
#   lvmthin  thin pool data/metadata vulgraad
#   mdraid   degraded md-arrays
#   btrfs    btrfs device-foutentellers
#   pvesm    lokale Proxmox-storages die inactive zijn
#
# Gebruik: pve-disk-monitor.sh [opties]
#   -c, --config FILE   ini-bestand (standaard /etc/pve-disk-monitor.ini)
#   -n, --dry-run       niets versturen, geen state bijwerken; toont wat er verstuurd zou worden
#   -v, --verbose       ook INFO-meldingen tonen
#       --list-disks    gevonden disks + identifiers tonen (handig voor [disks] expected)
#       --test-alert    stuur een test-melding (down) naar Kuma/webhook
#       --forget KEY    disk (serial/key) vergeten zodat hij niet meer als verdwenen gemeld wordt
#       --reset-known   lijst bekende disks wissen (volgende run leert opnieuw)
#
# Exitcode: 0 = OK, 1 = waarschuwingen, 2 = kritiek, 3 = scriptfout
#
# Vereist: bash 4.4+, jq, curl, smartmontools (>= 7.0), util-linux

set -uo pipefail
umask 077
export LC_ALL=C

VERSION="1.0"
SCRIPT_NAME=$(basename "$0")

# ======================================================================
# Standaardinstellingen (overschrijfbaar via het ini-bestand)
# ======================================================================
CONFIG_FILE="/etc/pve-disk-monitor.ini"

# [general]
CHECKS="disks smart kernel mounts usage zfs lvmthin mdraid btrfs pvesm"
STATE_DIR="/var/lib/pve-disk-monitor"
HOST_LABEL=""                       # leeg = hostname -s
MAX_MSG_LEN=900

# [kuma]
KUMA_PUSH_URL=""
KUMA_DOWN_SEVERITY="WARN"           # WARN: down bij warn+crit | CRIT: alleen down bij crit
KUMA_TIMEOUT=20

# [webhook]
WEBHOOK_URL=""
WEBHOOK_ON_CHANGE_ONLY=1
WEBHOOK_HEADERS=()

# [disks]
DISK_EXCLUDE_REGEX='^(loop|zd|rbd|nbd|sr|dm-|md|ram|zram|drbd)'
TRACK_DISKS="all"                   # all | internal | none
TRACK_IGNORE_REGEX=""
EXPECTED_DISKS=()
WARN_ON_RENAME=1

# [smart]
SMART_TIMEOUT=60
SMART_NOWAKE=1
SMART_SKIP_REGEX=""
SMART_UNSUPPORTED="INFO"            # INFO | WARN
SMART_USB_TRY_TYPES=(sat sntjmicron sntasmedia sntrealtek)
SMART_EXTRA=()                      # "device|type|label", bv. "/dev/sda|megaraid,0|bay0"
ATTR_WARN_ABOVE="5:0 187:0 197:0 198:0"
ATTR_CRIT_INCREASE="5 197 198"
ATTR_WARN_INCREASE="187 199"
ATA_ERRLOG_INCREASE="WARN"          # WARN | CRIT | IGNORE
TEMP_HDD="50 60"
TEMP_SSD="60 70"
TEMP_NVME="70 80"
NVME_WEAR_WARN=90
NVME_MEDIA_WARN_ABOVE=0
declare -A SMART_DEVTYPE=()         # [smart.devtype] serial/naam = type

# [kernel]
KERNEL_LOOKBACK=3600
KERNEL_BOOT_GRACE=180
KERNEL_SEVERITY="WARN"
KERNEL_CRIT_COUNT=50
KERNEL_USE_DEFAULT_PATTERNS=1
KERNEL_PATTERNS=()
KERNEL_IGNORE_PATTERNS=()
KERNEL_DEFAULT_PATTERNS=(
  'I/O error'
  'critical (medium|target|nexus|space allocation) error'
  'Medium Error|Unrecovered read error|Sense Key : (Medium|Hardware) Error'
  'failed command: (READ|WRITE)'
  'exception Emask'
  'hard resetting link'
  'uas_eh_(abort|device_reset)_handler'
  'reset ((high|full|low)-speed|SuperSpeed)[^:]* USB device'
  'rejecting I/O to offline device|device offlined'
  'DID_BAD_TARGET|DID_NO_CONNECT'
  'Remounting filesystem read-only'
  'EXT4-fs error'
  'XFS \([^)]*\): (metadata I/O error|Corruption|log I/O error|Filesystem has been shut down)'
  'BTRFS (error|critical)'
  'nvme[0-9]+: (I/O [0-9]+ QID [0-9]+ timeout|controller is down|Removing after probe failure|Device not ready)'
)

# [mounts]
EXPECTED_MOUNTS=()
MOUNT_WRITE_TEST=1
MOUNT_TIMEOUT=15

# [usage]
USAGE_WARN=85
USAGE_CRIT=95
INODE_WARN=85
INODE_CRIT=95
USAGE_FSTYPES_REGEX='^(ext[234]|xfs|btrfs|vfat|exfat|ntfs|ntfs3|fuseblk|f2fs)$'
USAGE_EXCLUDE_REGEX='^/boot/efi$'
declare -A USAGE_THRESHOLDS=()      # [usage.thresholds] mountpoint = "warn crit"

# [zfs]
ZFS_CAP_WARN=80
ZFS_CAP_CRIT=90

# [lvmthin]
THIN_DATA_WARN=85
THIN_DATA_CRIT=95
THIN_META_WARN=75
THIN_META_CRIT=90

# [pvesm]
PVESM_TYPES_REGEX='^(dir|lvm|lvmthin|zfspool|btrfs)$'
PVESM_IGNORE_REGEX=""

# ======================================================================
# Helpers
# ======================================================================
DRY_RUN=0
VERBOSE=0
ACTION="run"
ACTION_ARG=""
CRIT=()
WARN=()
INFO=()
STANDBY_RC=3        # exitcode die smartctl -n standby,N teruggeeft als de disk slaapt

die()  { echo "$SCRIPT_NAME: $*" >&2; exit 3; }
have() { command -v "$1" >/dev/null 2>&1; }
want() { [[ " $CHECKS " == *" $1 "* ]]; }
oneline() { local s=${*//$'\n'/ }; printf '%s' "${s//$'\t'/ }"; }
crit() { CRIT+=("$(oneline "$*")"); }
warn() { WARN+=("$(oneline "$*")"); }
info() { INFO+=("$(oneline "$*")"); }
isnum() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

join_by() {
  local sep=$1 out=${2:-}
  shift 2 2>/dev/null || shift $#
  local x
  for x in "$@"; do out+="$sep$x"; done
  printf '%s' "$out"
}

# level WAARDE WARN CRIT -> print CRIT/WARN/niets (werkt ook met decimalen)
level() {
  awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN {
    if (v !~ /^[0-9]+(\.[0-9]+)?$/) exit
    if (v + 0 >= c + 0) print "CRIT"; else if (v + 0 >= w + 0) print "WARN"
  }'
}

report_level() {
  case $1 in
    CRIT) crit "$2" ;;
    WARN) warn "$2" ;;
    INFO) info "$2" ;;
  esac
}

state_get() { [[ -r "$STATE_DIR/$1" ]] && cat -- "$STATE_DIR/$1"; return 0; }

state_put() {
  (( DRY_RUN )) && return 0
  local f="$STATE_DIR/$1"
  mkdir -p -- "$(dirname -- "$f")" && printf '%s\n' "$2" > "$f.tmp" && mv -f -- "$f.tmp" "$f"
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

# Lijstwaarde: komma- of spatiegescheiden -> array-elementen
split_list() { local IFS=$', \t'; read -r -a _LIST <<<"$1"; }

bool() {
  case ${1,,} in
    1|yes|y|true|on|ja) echo 1 ;;
    *) echo 0 ;;
  esac
}

# ======================================================================
# INI-parser (geen source/eval: alleen bekende sleutels worden gezet)
# ======================================================================
ini_set() {
  local sec=$1 key=$2 val=$3 where=$4
  case "$sec.$key" in
    general.checks)                 CHECKS=${val//,/ } ;;
    general.state_dir)              STATE_DIR=$val ;;
    general.host_label)             HOST_LABEL=$val ;;
    general.max_msg_len)            MAX_MSG_LEN=$val ;;

    kuma.push_url)                  KUMA_PUSH_URL=$val ;;
    kuma.down_severity)             KUMA_DOWN_SEVERITY=${val^^} ;;
    kuma.timeout)                   KUMA_TIMEOUT=$val ;;

    webhook.url)                    WEBHOOK_URL=$val ;;
    webhook.on_change_only)         WEBHOOK_ON_CHANGE_ONLY=$(bool "$val") ;;
    webhook.header)                 WEBHOOK_HEADERS+=("$val") ;;

    disks.exclude_regex)            DISK_EXCLUDE_REGEX=$val ;;
    disks.track)                    TRACK_DISKS=${val,,} ;;
    disks.track_ignore_regex)       TRACK_IGNORE_REGEX=$val ;;
    disks.expected)                 split_list "$val"; EXPECTED_DISKS+=("${_LIST[@]}") ;;
    disks.warn_on_rename)           WARN_ON_RENAME=$(bool "$val") ;;

    smart.timeout)                  SMART_TIMEOUT=$val ;;
    smart.nowake)                   SMART_NOWAKE=$(bool "$val") ;;
    smart.skip_regex)               SMART_SKIP_REGEX=$val ;;
    smart.unsupported)              SMART_UNSUPPORTED=${val^^} ;;
    smart.usb_try_types)            split_list "$val"; SMART_USB_TRY_TYPES=("${_LIST[@]}") ;;
    smart.extra)                    SMART_EXTRA+=("$val") ;;
    smart.attr_warn_above)          ATTR_WARN_ABOVE=${val//,/ } ;;
    smart.attr_crit_increase)       ATTR_CRIT_INCREASE=${val//,/ } ;;
    smart.attr_warn_increase)       ATTR_WARN_INCREASE=${val//,/ } ;;
    smart.ata_errlog_increase)      ATA_ERRLOG_INCREASE=${val^^} ;;
    smart.temp_hdd)                 TEMP_HDD=${val//,/ } ;;
    smart.temp_ssd)                 TEMP_SSD=${val//,/ } ;;
    smart.temp_nvme)                TEMP_NVME=${val//,/ } ;;
    smart.nvme_wear_warn)           NVME_WEAR_WARN=$val ;;
    smart.nvme_media_warn_above)    NVME_MEDIA_WARN_ABOVE=$val ;;
    smart.devtype.*)                SMART_DEVTYPE[$key]=$val ;;

    kernel.lookback)                KERNEL_LOOKBACK=$val ;;
    kernel.boot_grace)              KERNEL_BOOT_GRACE=$val ;;
    kernel.severity)                KERNEL_SEVERITY=${val^^} ;;
    kernel.crit_count)              KERNEL_CRIT_COUNT=$val ;;
    kernel.use_default_patterns)    KERNEL_USE_DEFAULT_PATTERNS=$(bool "$val") ;;
    kernel.pattern)                 KERNEL_PATTERNS+=("$val") ;;
    kernel.ignore)                  KERNEL_IGNORE_PATTERNS+=("$val") ;;

    mounts.path)                    EXPECTED_MOUNTS+=("$val") ;;
    mounts.write_test)              MOUNT_WRITE_TEST=$(bool "$val") ;;
    mounts.timeout)                 MOUNT_TIMEOUT=$val ;;

    usage.warn)                     USAGE_WARN=$val ;;
    usage.crit)                     USAGE_CRIT=$val ;;
    usage.inode_warn)               INODE_WARN=$val ;;
    usage.inode_crit)               INODE_CRIT=$val ;;
    usage.fstypes_regex)            USAGE_FSTYPES_REGEX=$val ;;
    usage.exclude_regex)            USAGE_EXCLUDE_REGEX=$val ;;
    usage.thresholds.*)             USAGE_THRESHOLDS[$key]=${val//,/ } ;;

    zfs.cap_warn)                   ZFS_CAP_WARN=$val ;;
    zfs.cap_crit)                   ZFS_CAP_CRIT=$val ;;

    lvmthin.data_warn)              THIN_DATA_WARN=$val ;;
    lvmthin.data_crit)              THIN_DATA_CRIT=$val ;;
    lvmthin.meta_warn)              THIN_META_WARN=$val ;;
    lvmthin.meta_crit)              THIN_META_CRIT=$val ;;

    pvesm.types_regex)              PVESM_TYPES_REGEX=$val ;;
    pvesm.ignore_regex)             PVESM_IGNORE_REGEX=$val ;;

    *) echo "$SCRIPT_NAME: onbekende instelling [$sec] $key ($where)" >&2 ;;
  esac
}

# Regels: [sectie], key = waarde. Commentaar: regels die met ; of # beginnen
# (geen inline-commentaar, zodat regexen # en ; mogen bevatten).
# Waarden mogen tussen "..." of '...' staan. Herhaalbare sleutels: zie voorbeeld-ini.
load_ini() {
  local file=$1 line sec="" key val n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=$(trim "${line%$'\r'}")
    [[ -z $line || $line == \;* || $line == \#* ]] && continue
    if [[ $line =~ ^\[([^]]+)\]$ ]]; then
      sec=$(trim "${BASH_REMATCH[1]}")
      sec=${sec,,}
      continue
    fi
    if [[ $line != *=* ]]; then
      echo "$SCRIPT_NAME: $file:$n: ongeldige regel genegeerd" >&2
      continue
    fi
    key=$(trim "${line%%=*}")
    val=$(trim "${line#*=}")
    if [[ ${#val} -ge 2 && ( ( $val == \"*\" ) || ( $val == \'*\' ) ) ]]; then
      val=${val:1:${#val}-2}
    fi
    # in [smart.devtype] / [usage.thresholds] is de sleutel een serial/pad -> hoofdletters behouden
    case $sec in
      smart.devtype|usage.thresholds) ini_set "$sec" "$key" "$val" "$file:$n" ;;
      *) ini_set "$sec" "${key,,}" "$val" "$file:$n" ;;
    esac
  done < "$file"
}

# ======================================================================
# Disk-inventaris
# ======================================================================
declare -A D_NAME=() D_TRAN=() D_MODEL=() D_SERIAL=() D_WWN=() D_LABEL=() N2K=()
DISK_KEYS=()

scan_disks() {
  local json name tran serial model size wwn key
  json=$(lsblk -J -d -o NAME,TYPE,TRAN,SERIAL,MODEL,SIZE,WWN 2>/dev/null) || die "lsblk faalde"
  while IFS=$'\t' read -r name tran serial model size wwn; do
    [[ $name =~ $DISK_EXCLUDE_REGEX ]] && continue
    key=$serial
    [[ $key == - ]] && key=$wwn
    [[ $key == - ]] && key="$name:$model:$size"
    # sommige USB-behuizingen geven dezelfde serial voor meerdere disks
    [[ -n ${D_NAME[$key]+x} ]] && key="$key:$name"
    DISK_KEYS+=("$key")
    D_NAME[$key]=$name
    D_TRAN[$key]=$tran
    D_MODEL[$key]=$model
    D_SERIAL[$key]=$serial
    D_WWN[$key]=$wwn
    D_LABEL[$key]="$name [$model, SN $serial${tran:+, $tran}]"
    N2K[$name]=$key
  done < <(jq -r '
      def t: (. // "" | tostring | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ")) | if . == "" then "-" else . end;
      .blockdevices[] | select(.type == "disk")
      | [(.name | t), (.tran | t), (.serial | t), (.model | t), (.size | t), (.wwn | t)] | @tsv' <<<"$json")
}

# ======================================================================
# Check: disks (verdwenen / reconnect / verwacht)
# ======================================================================
track_this() { # tran
  case $TRACK_DISKS in
    all) return 0 ;;
    internal) [[ $1 != usb ]] ;;
    *) return 1 ;;
  esac
}

check_disks() {
  local boot_id prev_boot key name tran model out="" exp found
  local -A K_NAME=() K_TRAN=() K_MODEL=()
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  prev_boot=$(state_get boot_id)

  while IFS=$'\t' read -r key name tran model; do
    [[ -n $key ]] || continue
    K_NAME[$key]=$name
    K_TRAN[$key]=$tran
    K_MODEL[$key]=$model
  done < <(state_get known_disks)

  if [[ $TRACK_DISKS != none ]]; then
    for key in "${!K_NAME[@]}"; do
      track_this "${K_TRAN[$key]}" || continue
      if [[ -z ${D_NAME[$key]+x} ]]; then
        if [[ -n $TRACK_IGNORE_REGEX && "$key ${K_MODEL[$key]} ${K_NAME[$key]}" =~ $TRACK_IGNORE_REGEX ]]; then
          info "Disk niet aanwezig (genegeerd): ${K_MODEL[$key]} SN $key"
        else
          crit "Disk verdwenen: ${K_MODEL[$key]} SN $key (was /dev/${K_NAME[$key]}, ${K_TRAN[$key]})"
        fi
      elif (( WARN_ON_RENAME )) && [[ ${K_NAME[$key]} != "${D_NAME[$key]}" && -n $prev_boot && $boot_id == "$prev_boot" ]]; then
        warn "Disk opnieuw verbonden? ${D_LABEL[$key]} was /dev/${K_NAME[$key]}"
      fi
    done

    for key in "${DISK_KEYS[@]}"; do
      track_this "${D_TRAN[$key]}" || continue
      [[ -z ${K_NAME[$key]+x} && ${#K_NAME[@]} -gt 0 ]] && info "Nieuwe disk: ${D_LABEL[$key]}"
      out+="$key"$'\t'"${D_NAME[$key]}"$'\t'"${D_TRAN[$key]}"$'\t'"${D_MODEL[$key]}"$'\n'
    done
    # ontbrekende disks onthouden zodat de melding blijft staan tot ze terug zijn (of --forget)
    for key in "${!K_NAME[@]}"; do
      [[ -z ${D_NAME[$key]+x} ]] && track_this "${K_TRAN[$key]}" &&
        out+="$key"$'\t'"${K_NAME[$key]}"$'\t'"${K_TRAN[$key]}"$'\t'"${K_MODEL[$key]}"$'\n'
    done
    state_put known_disks "${out%$'\n'}"
  fi

  for exp in "${EXPECTED_DISKS[@]}"; do
    found=0
    for key in "${DISK_KEYS[@]}"; do
      if [[ $exp == "$key" || $exp == "${D_SERIAL[$key]}" || $exp == "${D_WWN[$key]}" || $exp == "${D_MODEL[$key]}" ]]; then
        found=1
        break
      fi
    done
    (( found )) || [[ -e /dev/disk/by-id/$exp ]] && found=1
    (( found )) || [[ $exp == /dev/* && -e $exp ]] && found=1
    (( found )) || crit "Verwachte disk ontbreekt: $exp"
  done
}

# ======================================================================
# Check: SMART
# ======================================================================
SMART_JSON=""
SMART_RC=0

smart_run() { # device type
  local args=(-j -a)
  if (( SMART_NOWAKE )) && [[ $1 != /dev/nvme* && $2 != snt* ]]; then
    args+=(-n "standby,$STANDBY_RC")
  fi
  [[ -n $2 ]] && args+=(-d "$2")
  SMART_JSON=$(timeout "$SMART_TIMEOUT" smartctl "${args[@]}" "$1" 2>/dev/null)
  SMART_RC=$?
}

smart_has_data() { jq -e '.smart_status.passed != null' <<<"$SMART_JSON" >/dev/null 2>&1; }

# 0 = data aanwezig, 1 = geen data, 2 = afgehandeld (slaapt / timeout)
smart_status_after_run() {
  local label=$1
  if (( SMART_RC == 124 )); then
    crit "smartctl timeout op $label (disk hangt?)"
    return 2
  fi
  if (( SMART_NOWAKE && SMART_RC == STANDBY_RC )); then
    info "$label slaapt, SMART overgeslagen"
    return 2
  fi
  smart_has_data && return 0
  return 1
}

smart_one() { # device type label statekey tran
  local dev=$1 devtype=$2 label=$3 skey=$4 tran=$5 t rc
  smart_run "$dev" "$devtype"
  smart_status_after_run "$label"; rc=$?
  if (( rc == 1 )) && [[ -z $devtype && $tran == usb ]]; then
    for t in "${SMART_USB_TRY_TYPES[@]}"; do
      smart_run "$dev" "$t"
      smart_status_after_run "$label"; rc=$?
      (( rc != 1 )) && break
    done
  fi
  (( rc == 2 )) && return
  if (( rc == 1 )); then
    report_level "$SMART_UNSUPPORTED" "Geen SMART-data voor $label (bridge ondersteunt het niet? zet [smart.devtype])"
    return
  fi

  local k v
  local -A S=() P=()
  while IFS='=' read -r k v; do
    [[ -n $k ]] && S[$k]=$v
  done < <(jq -r '
    def s: if . == null then "" else tostring end;
    "passed=\(.smart_status.passed | s)",
    "temp=\(.temperature.current | s)",
    "rot=\(.rotation_rate | s)",
    "isnvme=\(.nvme_smart_health_information_log != null)",
    "errlog=\(.ata_smart_error_log.summary.count | s)",
    "selftest=\(.ata_smart_self_test_log.standard.table[0].status.passed | s)",
    "nvme_cw=\(.nvme_smart_health_information_log.critical_warning | s)",
    "nvme_media=\(.nvme_smart_health_information_log.media_errors | s)",
    "nvme_used=\(.nvme_smart_health_information_log.percentage_used | s)",
    "nvme_spare=\(.nvme_smart_health_information_log.available_spare | s)",
    "nvme_spare_th=\(.nvme_smart_health_information_log.available_spare_threshold | s)",
    (.ata_smart_attributes.table[]? | "a\(.id)=\(.raw.value | s)", "n\(.id)=\(.name | s)"),
    "failing=\([.ata_smart_attributes.table[]? | select(.when_failed == "now") | .name] | join(","))"
  ' <<<"$SMART_JSON")

  local sfile="smart/$(safe_name "$skey")"
  while IFS='=' read -r k v; do
    [[ -n $k ]] && P[$k]=$v
  done < <(state_get "$sfile")

  [[ ${S[passed]:-} == false ]] && crit "SMART FAILED: $label"
  [[ -n ${S[failing]:-} ]] && crit "SMART attribuut onder drempel op $label: ${S[failing]}"
  [[ ${S[selftest]:-} == false ]] && warn "Laatste SMART self-test mislukt: $label"

  # ATA-attributen: stijging t.o.v. vorige run, en drempels
  local id cur prev spec max aname
  local -A seen=()
  for id in $ATTR_CRIT_INCREASE; do
    cur=${S[a$id]:-}; prev=${P[a$id]:-}
    if isnum "$cur" && isnum "$prev" && (( cur > prev )); then
      crit "$label: ${S[n$id]:-attr $id} gestegen $prev -> $cur"
      seen[$id]=1
    fi
  done
  for id in $ATTR_WARN_INCREASE; do
    [[ -n ${seen[$id]:-} ]] && continue
    cur=${S[a$id]:-}; prev=${P[a$id]:-}
    if isnum "$cur" && isnum "$prev" && (( cur > prev )); then
      warn "$label: ${S[n$id]:-attr $id} gestegen $prev -> $cur"
      seen[$id]=1
    fi
  done
  for spec in $ATTR_WARN_ABOVE; do
    id=${spec%%:*}; max=${spec#*:}
    [[ $spec == *:* ]] || max=0
    [[ -n ${seen[$id]:-} ]] && continue
    cur=${S[a$id]:-}
    if isnum "$cur" && (( cur > max )); then
      warn "$label: ${S[n$id]:-attr $id} = $cur"
    fi
  done

  cur=${S[errlog]:-}; prev=${P[errlog]:-}
  if [[ $ATA_ERRLOG_INCREASE != IGNORE ]] && isnum "$cur" && isnum "$prev" && (( cur > prev )); then
    report_level "$ATA_ERRLOG_INCREASE" "$label: ATA error log $prev -> $cur fouten"
  fi

  # NVMe
  if [[ ${S[isnvme]:-} == true ]]; then
    cur=${S[nvme_cw]:-}
    isnum "$cur" && (( cur != 0 )) && crit "$label: NVMe critical_warning=$(printf '0x%02x' "$cur")"
    cur=${S[nvme_media]:-}; prev=${P[nvme_media]:-}
    if isnum "$cur" && isnum "$prev" && (( cur > prev )); then
      crit "$label: NVMe media errors gestegen $prev -> $cur"
    elif isnum "$cur" && (( cur > NVME_MEDIA_WARN_ABOVE )); then
      warn "$label: NVMe media errors = $cur"
    fi
    cur=${S[nvme_used]:-}
    isnum "$cur" && (( cur >= NVME_WEAR_WARN )) && warn "$label: NVMe slijtage ${cur}%"
    cur=${S[nvme_spare]:-}; prev=${S[nvme_spare_th]:-}
    isnum "$cur" && isnum "$prev" && (( cur < prev )) && crit "$label: NVMe available spare ${cur}% < ${prev}%"
  fi

  # Temperatuur
  local tw tc kind
  if [[ ${S[isnvme]:-} == true ]]; then
    kind=NVMe; read -r tw tc <<<"$TEMP_NVME"
  elif [[ ${S[rot]:-} == 0 ]]; then
    kind=SSD; read -r tw tc <<<"$TEMP_SSD"
  else
    kind=HDD; read -r tw tc <<<"$TEMP_HDD"
  fi
  cur=${S[temp]:-}
  report_level "$(level "$cur" "$tw" "$tc")" "$label: temperatuur ${cur}°C ($kind, max $tw/$tc)"

  local st=""
  for k in "${!S[@]}"; do
    [[ $k == a* || $k == errlog || $k == nvme_media ]] && st+="$k=${S[$k]}"$'\n'
  done
  state_put "$sfile" "${st%$'\n'}"
}

check_smart() {
  have smartctl || { warn "smartctl niet gevonden (apt install smartmontools)"; return; }
  local key name devtype e dev t lbl
  for key in "${DISK_KEYS[@]}"; do
    name=${D_NAME[$key]}
    if [[ -n $SMART_SKIP_REGEX && "$name $key ${D_MODEL[$key]}" =~ $SMART_SKIP_REGEX ]]; then
      continue
    fi
    devtype=${SMART_DEVTYPE[$key]:-${SMART_DEVTYPE[${D_SERIAL[$key]}]:-${SMART_DEVTYPE[$name]:-}}}
    smart_one "/dev/$name" "$devtype" "${D_LABEL[$key]}" "$key" "${D_TRAN[$key]}"
  done
  for e in "${SMART_EXTRA[@]}"; do
    IFS='|' read -r dev t lbl <<<"$e"
    dev=$(trim "$dev"); t=$(trim "${t:-}"); lbl=$(trim "${lbl:-}")
    smart_one "$dev" "$t" "${lbl:-$dev $t}" "extra:$dev:$t" ""
  done
}

# ======================================================================
# Check: kernellog
# ======================================================================
check_kernel() {
  have journalctl || { warn "journalctl niet beschikbaar"; return; }
  local since boot_ts s2 pat ign lines="" n devs="" d last r a b
  local -a all=() ranges=()

  since=$(state_get last_run)
  isnum "$since" || since=$((RUN_START - KERNEL_LOOKBACK))
  boot_ts=$((RUN_START - $(cut -d. -f1 /proc/uptime)))

  # Kernelmeldingen in de eerste KERNEL_BOOT_GRACE seconden na boot overslaan
  # (USB-resets/link-meldingen bij het opstarten), maar wel de vorige boot meenemen.
  if (( since < boot_ts )); then
    ranges+=("$since $boot_ts")
    s2=$((boot_ts + KERNEL_BOOT_GRACE))
  else
    s2=$(( since > boot_ts + KERNEL_BOOT_GRACE ? since : boot_ts + KERNEL_BOOT_GRACE ))
  fi
  (( s2 < RUN_START )) && ranges+=("$s2 $RUN_START")
  (( ${#ranges[@]} )) || return

  (( KERNEL_USE_DEFAULT_PATTERNS )) && all+=("${KERNEL_DEFAULT_PATTERNS[@]}")
  all+=("${KERNEL_PATTERNS[@]}")
  (( ${#all[@]} )) || return
  pat=$(IFS='|'; printf '%s' "${all[*]}")

  for r in "${ranges[@]}"; do
    read -r a b <<<"$r"
    lines+=$(journalctl -k -q --no-pager -o short-iso --since "@$a" --until "@$b" 2>/dev/null | grep -E -- "$pat")$'\n'
  done
  if (( ${#KERNEL_IGNORE_PATTERNS[@]} )); then
    ign=$(IFS='|'; printf '%s' "${KERNEL_IGNORE_PATTERNS[*]}")
    lines=$(grep -vE -- "$ign" <<<"$lines")
  fi
  lines=$(grep -v '^$' <<<"$lines")
  [[ -z $lines ]] && return

  n=$(wc -l <<<"$lines")
  for d in $(grep -oE '\b(sd[a-z]+|nvme[0-9]+(n[0-9]+)?|ata[0-9]+)\b' <<<"$lines" | sort -u); do
    if [[ -n ${N2K[$d]:-} ]]; then
      devs+="$d(${D_MODEL[${N2K[$d]}]}) "
    else
      devs+="$d "
    fi
  done
  devs+=$(grep -oE 'usb [0-9]+-[0-9.]+' <<<"$lines" | sort -u | tr '\n' ' ')
  last=$(tail -n 1 <<<"$lines" | sed -E 's/^[^ ]+ [^ ]+ kernel: //')

  local sev=$KERNEL_SEVERITY
  (( n >= KERNEL_CRIT_COUNT )) && sev=CRIT
  report_level "$sev" "Kernel: $n disk-/IO-fout(en) ${devs:+[$(trim "$devs")] }laatste: $last"
}

# ======================================================================
# Check: mounts
# ======================================================================
check_mounts() {
  local m rc opts f
  for m in "${EXPECTED_MOUNTS[@]}"; do
    timeout "$MOUNT_TIMEOUT" mountpoint -q -- "$m"; rc=$?
    if (( rc == 124 )); then
      crit "Mount $m reageert niet (hangt)"
      continue
    elif (( rc != 0 )); then
      crit "Niet gemount: $m"
      continue
    fi
    opts=$(findmnt -n -o OPTIONS --mountpoint "$m" 2>/dev/null | head -n 1)
    if [[ ",$opts," == *,ro,* ]]; then
      crit "Read-only gemount: $m"
      continue
    fi
    if (( MOUNT_WRITE_TEST )); then
      f="$m/.pve-disk-monitor.test"
      if ! timeout "$MOUNT_TIMEOUT" sh -c 'printf "%s\n" "$2" > "$1" && rm -f -- "$1"' _ "$f" "$RUN_START" 2>/dev/null; then
        crit "Schrijftest mislukt op $m"
      fi
    fi
  done
}

# ======================================================================
# Check: vulgraad filesystems
# ======================================================================
check_usage() {
  local out rc src fst pc ipc tgt w c
  out=$(timeout 30 df -l --output=source,fstype,pcent,ipcent,target 2>/dev/null); rc=$?
  (( rc == 124 )) && { crit "df hangt (filesystem reageert niet)"; return; }
  while read -r src fst pc ipc tgt; do
    [[ $fst =~ $USAGE_FSTYPES_REGEX ]] || continue
    [[ -n $USAGE_EXCLUDE_REGEX && $tgt =~ $USAGE_EXCLUDE_REGEX ]] && continue
    read -r w c <<<"${USAGE_THRESHOLDS[$tgt]:-$USAGE_WARN $USAGE_CRIT}"
    report_level "$(level "${pc%\%}" "$w" "$c")" "Filesystem $tgt ($src) ${pc} vol"
    report_level "$(level "${ipc%\%}" "$INODE_WARN" "$INODE_CRIT")" "Filesystem $tgt ($src) inodes ${ipc} vol"
  done < <(tail -n +2 <<<"$out")
}

# ======================================================================
# Check: ZFS
# ======================================================================
check_zfs() {
  have zpool || return
  local name health cap st stat errs
  while IFS=$'\t' read -r name health cap; do
    [[ $health != ONLINE ]] && crit "ZFS pool $name is $health"
    st=$(timeout 30 zpool status -x "$name" 2>&1)
    if [[ $st != *"is healthy"* ]]; then
      stat=$(sed -nE 's/^[[:space:]]*status:[[:space:]]*//p' <<<"$st" | head -n 1)
      errs=$(sed -nE 's/^[[:space:]]*errors:[[:space:]]*//p' <<<"$st" | head -n 1)
      if [[ -n $errs && $errs != "No known data errors" ]]; then
        crit "ZFS pool $name: $errs"
      elif [[ $health == ONLINE ]]; then
        warn "ZFS pool $name: ${stat:-niet healthy}"
      fi
    fi
    report_level "$(level "${cap%\%}" "$ZFS_CAP_WARN" "$ZFS_CAP_CRIT")" "ZFS pool $name ${cap} vol"
  done < <(timeout 30 zpool list -H -o name,health,capacity 2>/dev/null)
}

# ======================================================================
# Check: LVM thin pools
# ======================================================================
check_lvmthin() {
  have lvs || return
  local vg lv attr d m
  while IFS='|' read -r vg lv attr d m; do
    vg=$(trim "$vg")
    [[ $attr == t* ]] || continue
    report_level "$(level "$d" "$THIN_DATA_WARN" "$THIN_DATA_CRIT")" "LVM thin $vg/$lv data ${d}% vol"
    report_level "$(level "$m" "$THIN_META_WARN" "$THIN_META_CRIT")" "LVM thin $vg/$lv metadata ${m}% vol"
  done < <(timeout 30 lvs --noheadings --nosuffix --separator '|' -o vg_name,lv_name,lv_attr,data_percent,metadata_percent 2>/dev/null)
}

# ======================================================================
# Check: mdraid
# ======================================================================
check_mdraid() {
  [[ -r /proc/mdstat ]] || return
  local l
  while IFS= read -r l; do
    [[ -n $l ]] && crit "mdraid: $l"
  done < <(awk '
    /^md[0-9]+ :/ { dev = $1
      if ($3 == "inactive") print dev " is inactive"
      if ($0 ~ /\(F\)/) print dev " heeft een failed member" }
    /\[[U_]+\]$/ && $NF ~ /_/ { print dev " degraded " $NF }' /proc/mdstat)
}

# ======================================================================
# Check: btrfs
# ======================================================================
check_btrfs() {
  have btrfs || return
  local mnt out
  while read -r mnt; do
    [[ -n $mnt ]] || continue
    mnt=$(printf '%b' "$mnt")
    out=$(timeout 30 btrfs device stats --check "$mnt" 2>&1) && continue
    warn "btrfs fouten op $mnt: $(grep -vE '[[:space:]]0$' <<<"$out" | head -n 3 | tr '\n' ' ')"
  done < <(findmnt -rn -t btrfs -o UUID,TARGET 2>/dev/null | awk '!s[$1]++ { print $2 }')
}

# ======================================================================
# Check: Proxmox storages
# ======================================================================
check_pvesm() {
  have pvesm || return
  local out rc name type status
  out=$(timeout 60 pvesm status 2>/dev/null); rc=$?
  (( rc == 124 )) && { warn "pvesm status timeout"; return; }
  while read -r name type status _; do
    [[ $type =~ $PVESM_TYPES_REGEX ]] || continue
    [[ -n $PVESM_IGNORE_REGEX && $name =~ $PVESM_IGNORE_REGEX ]] && continue
    [[ $status == inactive ]] && crit "Proxmox storage '$name' ($type) is inactive"
  done < <(tail -n +2 <<<"$out")
}

# ======================================================================
# Melden
# ======================================================================
send_kuma() { # status msg ping
  [[ -z $KUMA_PUSH_URL ]] && return 0
  local base=${KUMA_PUSH_URL%%\?*}
  if (( DRY_RUN )); then
    echo "[dry-run] Kuma push: status=$1 msg=$2"
    return 0
  fi
  curl -fsS -m "$KUMA_TIMEOUT" --retry 3 --retry-delay 5 -o /dev/null \
    "$base?status=$1&msg=$(urlencode "$2")&ping=$3" ||
    echo "$SCRIPT_NAME: Uptime Kuma push mislukt" >&2
}

send_webhook() { # status msg force
  [[ -z $WEBHOOK_URL ]] && return 0
  local hash prev payload h crit_json warn_json
  local -a hargs=()
  hash=$(printf '%s\n' "$1" "${CRIT[@]}" "${WARN[@]}" | sha256sum | cut -c1-16)
  prev=$(state_get webhook_hash)
  if [[ $3 != 1 ]] && (( WEBHOOK_ON_CHANGE_ONLY )); then
    [[ $hash == "$prev" ]] && return 0
    # eerste run en alles OK: niet melden, alleen onthouden
    [[ -z $prev && $1 == up ]] && { state_put webhook_hash "$hash"; return 0; }
  fi
  crit_json=$(printf '%s\n' "${CRIT[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
  warn_json=$(printf '%s\n' "${WARN[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
  payload=$(jq -nc --arg host "$HOST" --arg status "$1" --arg text "$2" \
    --argjson crit "$crit_json" --argjson warn "$warn_json" \
    '{host: $host, status: $status, text: $text, content: $text, message: $text,
      title: "pve-disk-monitor \($host)", critical: $crit, warning: $warn}')
  if (( DRY_RUN )); then
    echo "[dry-run] webhook POST: $payload"
    return 0
  fi
  for h in "${WEBHOOK_HEADERS[@]}"; do hargs+=(-H "$h"); done
  if curl -fsS -m 20 --retry 2 -o /dev/null -H 'Content-Type: application/json' "${hargs[@]}" \
       -d "$payload" "$WEBHOOK_URL"; then
    state_put webhook_hash "$hash"
  else
    echo "$SCRIPT_NAME: webhook mislukt" >&2
  fi
}

report() { # [force]
  local force=${1:-0} rc=0 status=up msg ping x
  (( ${#WARN[@]} )) && rc=1
  (( ${#CRIT[@]} )) && rc=2
  if (( rc == 2 )) || { (( rc == 1 )) && [[ $KUMA_DOWN_SEVERITY == WARN ]]; }; then
    status=down
  fi

  local -a parts=()
  (( ${#CRIT[@]} )) && parts+=("CRIT: $(join_by '; ' "${CRIT[@]}")")
  (( ${#WARN[@]} )) && parts+=("WARN: $(join_by '; ' "${WARN[@]}")")
  if (( rc == 0 )); then
    msg="OK - ${#DISK_KEYS[@]} disks, checks: $CHECKS"
  elif [[ $status == up ]]; then
    msg="OK met waarschuwingen - $(join_by ' | ' "${parts[@]}")"
  else
    msg="$HOST: $(join_by ' | ' "${parts[@]}")"
  fi
  (( ${#msg} > MAX_MSG_LEN )) && msg="${msg:0:MAX_MSG_LEN-3}..."

  for x in "${CRIT[@]}"; do echo "CRIT  $x"; done
  for x in "${WARN[@]}"; do echo "WARN  $x"; done
  if (( VERBOSE )); then
    for x in "${INFO[@]}"; do echo "INFO  $x"; done
  fi
  echo "Status: $status ($(( ${#CRIT[@]} )) crit, $(( ${#WARN[@]} )) warn, ${#DISK_KEYS[@]} disks)"

  ping=$(( $(date +%s%3N) - START_MS ))
  send_kuma "$status" "$msg" "$ping"
  send_webhook "$status" "$msg" "$force"
  return "$rc"
}

# ======================================================================
# Acties
# ======================================================================
list_disks() {
  local key name byid
  printf '%-9s %-5s %-28s %-22s %s\n' NAME TRAN MODEL SERIAL BY-ID
  for key in "${DISK_KEYS[@]}"; do
    name=${D_NAME[$key]}
    byid=$(find /dev/disk/by-id -maxdepth 1 -lname "*/$name" -printf '%f ' 2>/dev/null)
    printf '%-9s %-5s %-28s %-22s %s\n' "$name" "${D_TRAN[$key]}" "${D_MODEL[$key]}" "${D_SERIAL[$key]}" "$byid"
    [[ $key != "${D_SERIAL[$key]}" ]] && printf '%-9s key: %s\n' "" "$key"
  done
  echo
  echo "Bekende disks (state): $STATE_DIR/known_disks"
  state_get known_disks | awk -F'\t' 'NF { printf "  %-24s %-8s %-5s %s\n", $1, $2, $3, $4 }'
}

usage() { sed -n '/^# Gebruik:/,/^# Exitcode/p' "$0" | sed 's/^# \{0,1\}//'; }

# ======================================================================
# Main
# ======================================================================
while (( $# )); do
  case $1 in
    -c|--config)   CONFIG_FILE=${2:?}; shift ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    -v|--verbose)  VERBOSE=1 ;;
    --list-disks)  ACTION=list ;;
    --test-alert)  ACTION=test ;;
    --forget)      ACTION=forget; ACTION_ARG=${2:?}; shift ;;
    --reset-known) ACTION=reset ;;
    -V|--version)  echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; exit 3 ;;
  esac
  shift
done

if [[ -r $CONFIG_FILE ]]; then
  load_ini "$CONFIG_FILE"
elif [[ $CONFIG_FILE != /etc/pve-disk-monitor.ini ]]; then
  die "config niet leesbaar: $CONFIG_FILE"
fi

(( EUID == 0 )) || die "moet als root draaien"
for bin in jq lsblk curl timeout findmnt; do
  have "$bin" || die "$bin ontbreekt (apt install jq curl smartmontools)"
done
mkdir -p -- "$STATE_DIR" || die "kan $STATE_DIR niet aanmaken"
exec 9>"$STATE_DIR/.lock"
flock -n 9 || die "draait al"

HOST=${HOST_LABEL:-$(hostname -s)}
RUN_START=$(date +%s)
START_MS=$(date +%s%3N)
scan_disks

case $ACTION in
  list)
    list_disks
    exit 0 ;;
  forget)
    state_put known_disks "$(state_get known_disks | awk -F'\t' -v k="$ACTION_ARG" '$1 != k')"
    echo "Vergeten: $ACTION_ARG"
    exit 0 ;;
  reset)
    (( DRY_RUN )) || rm -f -- "$STATE_DIR/known_disks"
    echo "Lijst bekende disks gewist"
    exit 0 ;;
  test)
    CRIT=("TEST-melding van $SCRIPT_NAME op $HOST - negeren")
    report 1
    exit $? ;;
esac

for c in $CHECKS; do
  if declare -F "check_$c" >/dev/null; then
    "check_$c"
  else
    warn "Onbekende check in config: $c"
  fi
done

state_put last_run "$RUN_START"
state_put boot_id "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
report
exit $?
