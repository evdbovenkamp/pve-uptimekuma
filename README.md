# pve-uptimekuma

Disk health monitoring for **Proxmox VE hosts**, reporting to an **Uptime Kuma push monitor**.

A single Bash script that runs on the Proxmox host itself (not inside VMs or containers) and checks local and USB-attached disks: SMART health, disappearing/reconnecting USB disks, kernel I/O errors, filesystem usage, ZFS, LVM-thin and more. Every run pushes a heartbeat to Uptime Kuma: `up` when everything is fine, `down` with a summary of the problems when something is wrong. All settings live in a separate INI file.

> **Note:** alert messages and inline comments in the script are in Dutch. This README and the configuration keys are in English.

## Features

| Check     | What it detects |
|-----------|-----------------|
| `disks`   | Disks that disappeared (e.g. USB disconnects), disks that reconnected under a new name (`sdc` → `sdd`) without a reboot, required disks that are missing |
| `smart`   | SMART failed, attributes below threshold, failed self-test, rising reallocated/pending/uncorrectable sectors, rising CRC errors (cable/USB problems), temperature, NVMe critical warnings, media errors, wear and spare |
| `kernel`  | I/O errors, medium errors, USB/UAS resets, SATA link resets, offline devices, filesystem errors (ext4/XFS/btrfs), NVMe timeouts since the previous run |
| `mounts`  | Expected mountpoints that are not mounted, mounted read-only, hanging, or not writable |
| `usage`   | Filesystem space and inode usage (per-mountpoint thresholds possible) |
| `zfs`     | Pool health, data errors, capacity |
| `lvmthin` | Thin pool data and metadata usage (e.g. Proxmox `local-lvm`) |
| `mdraid`  | Degraded, inactive or failed md arrays |
| `btrfs`   | btrfs device error counters |
| `pvesm`   | Local Proxmox storages (dir, lvm, lvmthin, zfspool, btrfs) that are `inactive` |

Other details:

- **USB disks:** if SMART autodetection fails, the script automatically tries `-d sat` and the common USB-NVMe bridge types (JMicron, ASMedia, Realtek). You can also set a fixed type per disk.
- **Sleeping disks are not woken up.** SMART uses `smartctl -n standby`.
- **No code execution from the config.** The INI is parsed, not sourced, and only known keys are accepted.
- **Locking:** a lock prevents runs from overlapping, and the script handles hanging devices with timeouts.
- **Optional generic JSON webhook** (Slack, Discord, Gotify, n8n, Home Assistant, ...), sent only when the problem list changes.

## Requirements

- Proxmox VE (tested on PVE 9.x; Debian-based PVE 7/8 should work)
- `bash` 4.4+, `jq`, `curl`, `smartmontools` 7.0+, `util-linux`

```bash
apt install jq curl smartmontools
```

## Installation

```bash
git clone https://github.com/evdbovenkamp/pve-uptimekuma.git
cd pve-uptimekuma

install -m 755 pve-disk-monitor.sh      /usr/local/sbin/
install -m 600 pve-disk-monitor.ini     /etc/
install -m 644 pve-disk-monitor.service /etc/systemd/system/
install -m 644 pve-disk-monitor.timer   /etc/systemd/system/
systemctl daemon-reload
```

### 1. Create a push monitor in Uptime Kuma

1. **Add New Monitor** → Monitor Type **Push**.
2. Set **Heartbeat Interval** to **600** seconds (twice the script interval, see below).
3. Copy the push URL, e.g. `https://kuma.example.com/api/push/AbCdEf123?status=up&msg=OK&ping=`

### 2. Configure

Edit `/etc/pve-disk-monitor.ini` and set at least the push URL:

```ini
[kuma]
push_url = https://kuma.example.com/api/push/AbCdEf123?status=up&msg=OK&ping=
```

The `?status=...` query part may stay; the script strips it.

### 3. Test

```bash
pve-disk-monitor.sh --list-disks   # detected disks, serials and /dev/disk/by-id names
pve-disk-monitor.sh -n -v          # dry run: show what would be sent, change nothing
pve-disk-monitor.sh --test-alert   # send a test 'down' to Uptime Kuma
```

### 4. Enable the timer

```bash
systemctl enable --now pve-disk-monitor.timer
systemctl list-timers pve-disk-monitor.timer
journalctl -u pve-disk-monitor.service
```

The timer runs every 5 minutes. The first run records which disks are present. From then on, a disk that disappears raises a critical alert.

## How it reports to Uptime Kuma

A Kuma push monitor expects regular heartbeats, so the script pushes on **every run**:

| Result               | Push |
|----------------------|------|
| No problems          | `status=up`, `msg=OK - N disks, checks: ...` |
| Warnings only        | `status=down` (or `up` with the warnings in the message if `down_severity = CRIT`) |
| Critical problems    | `status=down`, `msg=<host>: CRIT: ... \| WARN: ...` |
| Host down / script not running | no push → Kuma marks the monitor down after the heartbeat interval |

Uptime Kuma only sends a notification when the status changes (up → down or down → up), so you will not get a notification every 5 minutes.

**Heartbeat interval:** use roughly **twice** the script interval (600 s for the default 5-minute timer). With exactly 300 s, a slow run or the timer's random delay causes false alarms.

## Configuration reference

All keys are optional. Missing keys use the defaults shown. The bundled [`pve-disk-monitor.ini`](pve-disk-monitor.ini) documents every option.

INI rules:

- **Comments** are lines starting with `;` or `#`. Inline comments are not supported, so regexes can contain `#` and `;`.
- **Quoting:** values may be wrapped in `"..."` or `'...'`.
- **Repeatable keys** (marked below with *) can be given multiple times.
- **Booleans:** `1/0`, `yes/no`, `true/false` and `on/off` are accepted.
- **Unknown keys** produce a warning on stderr.

### `[general]`

| Key | Default | Description |
|-----|---------|-------------|
| `checks` | `disks smart kernel mounts usage zfs lvmthin mdraid btrfs pvesm` | Checks to run |
| `state_dir` | `/var/lib/pve-disk-monitor` | State (known disks, SMART counters, last run) |
| `host_label` | `hostname -s` | Name used in messages |
| `max_msg_len` | `900` | Truncate the Kuma message |

### `[kuma]`

| Key | Default | Description |
|-----|---------|-------------|
| `push_url` | – | Uptime Kuma push URL |
| `down_severity` | `WARN` | `WARN`: down on warnings and critical. `CRIT`: down only on critical |
| `timeout` | `20` | HTTP timeout in seconds |

### `[webhook]`

| Key | Default | Description |
|-----|---------|-------------|
| `url` | – | Optional generic webhook (HTTP POST, JSON) |
| `on_change_only` | `1` | Only send when the problem list changes (including recovery) |
| `header` * | – | Extra HTTP header, e.g. `Authorization: Bearer xyz` |

The payload looks like this:

```json
{
  "host": "pve1", "status": "down",
  "text": "...", "content": "...", "message": "...",
  "title": "pve-disk-monitor pve1",
  "critical": ["..."], "warning": ["..."]
}
```

`text` (Slack), `content` (Discord) and `message` (Gotify) contain the same summary.

### `[disks]`

| Key | Default | Description |
|-----|---------|-------------|
| `exclude_regex` | `^(loop\|zd\|rbd\|nbd\|sr\|dm-\|md\|ram\|zram\|drbd)` | Kernel names to ignore (zvols, loop devices, ...) |
| `track` | `all` | Remember disks and alert when one disappears: `all`, `internal` (non-USB only) or `none` |
| `track_ignore_regex` | – | Disks that may be absent without alarm (regex on serial/model/name), e.g. rotating backup disks |
| `expected` * | – | Disks that must always be present: serial, WWN, model, `/dev/disk/by-id` name or `/dev/...` path. Comma separated and/or repeatable |
| `warn_on_rename` | `1` | Warn when a disk gets a different kernel name without a reboot (USB reconnect) |

### `[smart]`

| Key | Default | Description |
|-----|---------|-------------|
| `timeout` | `60` | Timeout per `smartctl` call. A timeout is reported as critical (hanging disk) |
| `nowake` | `1` | Skip disks in standby instead of waking them |
| `skip_regex` | – | Skip SMART for these disks (regex on name/serial/model) |
| `unsupported` | `INFO` | USB bridge without SMART support: `INFO` (silent) or `WARN` |
| `usb_try_types` | `sat sntjmicron sntasmedia sntrealtek` | `-d` types to try for USB disks when autodetection gives no SMART data |
| `extra` * | – | Devices not visible as a disk in `lsblk`, e.g. behind a RAID controller: `device\|type\|label` |
| `attr_warn_above` | `5:0 187:0 197:0 198:0` | Warn when attribute raw value > threshold (`id:threshold`) |
| `attr_crit_increase` | `5 197 198` | Critical when these attributes increase since the previous run |
| `attr_warn_increase` | `187 199` | Warning when these attributes increase (199 = UDMA CRC errors, cable/USB issue) |
| `ata_errlog_increase` | `WARN` | ATA error log grows: `WARN`, `CRIT` or `IGNORE` |
| `temp_hdd` | `50 60` | Warn/critical temperature in °C for HDDs |
| `temp_ssd` | `60 70` | Same for SATA SSDs |
| `temp_nvme` | `70 80` | Same for NVMe |
| `nvme_wear_warn` | `90` | Warn when NVMe `percentage_used` ≥ value |
| `nvme_media_warn_above` | `0` | Warn when NVMe media errors > value (an increase is always critical) |

Attribute IDs: 5 Reallocated_Sector_Ct, 187 Reported_Uncorrect, 197 Current_Pending_Sector, 198 Offline_Uncorrectable, 199 UDMA_CRC_Error_Count.

### `[smart.devtype]`

Fixed `smartctl -d` type per disk. The key is the serial or kernel name:

```ini
[smart.devtype]
WX12A34B5678 = sat
sdc = sat,12
```

### `[kernel]`

| Key | Default | Description |
|-----|---------|-------------|
| `lookback` | `3600` | First run: seconds of kernel log to examine |
| `boot_grace` | `180` | Ignore messages in the first N seconds after boot (USB resets during startup). Messages from the previous boot are still checked |
| `severity` | `WARN` | Severity of kernel errors: `WARN` or `CRIT` |
| `crit_count` | `50` | Always critical from this many matching lines per run |
| `use_default_patterns` | `1` | Use the built-in patterns |
| `pattern` * | – | Additional extended regex patterns |
| `ignore` * | – | Ignore lines matching these regexes |

The built-in patterns cover:

- generic I/O, medium and sense errors
- ATA exceptions and link resets
- UAS aborts and USB device resets
- offline devices and `DID_BAD_TARGET`/`DID_NO_CONNECT`
- read-only remounts
- ext4, XFS and btrfs errors
- NVMe timeouts and controller failures

The kernel log line that reported the error is included in the alert, together with the affected device (`sdc(WD Elements)`, `usb 2-1`).

### `[mounts]`

| Key | Default | Description |
|-----|---------|-------------|
| `path` * | – | Mountpoint that must be mounted, read-write and writable |
| `write_test` | `1` | Create and remove a small test file |
| `timeout` | `15` | Seconds before a mount is considered hanging |

### `[usage]` and `[usage.thresholds]`

| Key | Default | Description |
|-----|---------|-------------|
| `warn` / `crit` | `85` / `95` | Filesystem usage % |
| `inode_warn` / `inode_crit` | `85` / `95` | Inode usage % |
| `fstypes_regex` | `^(ext[234]\|xfs\|btrfs\|vfat\|exfat\|ntfs\|ntfs3\|fuseblk\|f2fs)$` | Filesystem types to check (ZFS is handled by `[zfs]`) |
| `exclude_regex` | `^/boot/efi$` | Mountpoints to skip |

Per-mountpoint thresholds (`warn crit`):

```ini
[usage.thresholds]
/mnt/usb-backup = 95 98
```

### `[zfs]`, `[lvmthin]`, `[pvesm]`

| Key | Default | Description |
|-----|---------|-------------|
| `zfs.cap_warn` / `cap_crit` | `80` / `90` | Pool capacity % |
| `lvmthin.data_warn` / `data_crit` | `85` / `95` | Thin pool data % |
| `lvmthin.meta_warn` / `meta_crit` | `75` / `90` | Thin pool metadata % |
| `pvesm.types_regex` | `^(dir\|lvm\|lvmthin\|zfspool\|btrfs)$` | Storage types checked for `inactive` (local only) |
| `pvesm.ignore_regex` | – | Storage names to ignore |

## Command line

```
pve-disk-monitor.sh [options]
  -c, --config FILE   INI file (default /etc/pve-disk-monitor.ini)
  -n, --dry-run       send nothing, update no state; print what would be sent
  -v, --verbose       also print INFO messages (sleeping disks, new disks, ...)
      --list-disks    list detected disks and identifiers (useful for [disks] expected)
      --test-alert    send a test 'down' to Uptime Kuma / webhook
      --forget KEY    forget a disk (serial/key) so it is no longer reported missing
      --reset-known   clear the list of known disks (next run learns again)
  -V, --version
  -h, --help
```

Exit codes: `0` OK, `1` warnings, `2` critical, `3` script error. The systemd unit treats `1` and `2` as success, so the unit does not show as failed.

## Common scenarios

**A USB disk is unplugged.** The next run reports `Disk verdwenen` ("disk disappeared") as critical. The alert remains until the disk is back. If the disk was removed on purpose, run:

```bash
pve-disk-monitor.sh --forget <serial>
```

**Rotating offsite backup disks.** Use `track = internal`, or list them in `track_ignore_regex`.

**A disk has a few old reallocated sectors that never change.** Raise the warn threshold, e.g. `attr_warn_above = 5:8 187:0 197:0 198:0`. An *increase* remains critical through `attr_crit_increase`.

**A USB enclosure shows no SMART data.** Run `pve-disk-monitor.sh --list-disks` to find the serial. Then try `smartctl -a -d sat /dev/sdX` (or `sntjmicron`, `sntasmedia`) and pin the working type in `[smart.devtype]`.

**A flaky USB cable or enclosure** shows up as rising `UDMA_CRC_Error_Count` warnings and kernel `reset SuperSpeed USB device` / `uas_eh_abort_handler` messages.

**Noisy kernel messages**, e.g. from a USB device that is not a disk. Add an `ignore = ...` line in `[kernel]`.

## State

State is stored in `/var/lib/pve-disk-monitor/`:

- `known_disks`: disks seen before
- `smart/<serial>`: SMART counters from the previous run, used to detect increases
- `last_run`, `boot_id`: kernel log window and reboot detection
- `webhook_hash`: last sent problem list

Deleting the directory resets everything. The next run starts fresh.
