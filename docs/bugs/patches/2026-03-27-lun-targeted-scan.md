# Patch: Targeted LUN scan via sysfs (alternative to rescan-race patch)

**Date:** 2026-03-27
**Applies to:** `TrueNASPlugin.pm` — `_device_for_lun()` (line 2599)
**Alternative to:** `2026-03-27-lun-rescan-race.patch` (the two patches conflict — apply one or the other)

## Approach

Instead of relying on `iscsiadm -m session -R` (global rescan of all LUNs on all sessions), this patch:

1. Adds a `_scsi_hosts_for_target()` helper that finds scsi_host numbers for our IQN by reading `/sys/class/iscsi_session/sessionN/targetname` and resolving the symlink to extract the host number.

2. Adds a `_scan_lun_on_hosts()` helper that writes `- - <lun>` to `/sys/class/scsi_host/hostN/scan` for each matching host, telling the kernel to look for one specific LUN.

3. Modifies `_device_for_lun()` to issue a targeted scan immediately, then use a short retry loop (just udev settle + by-path check) for the symlink to appear. Falls back to the original global rescan if targeted scan doesn't work (e.g., sysfs permissions, non-standard kernel).

## Why this is better

- `iscsiadm -m session -R` rescans ALL LUNs on ALL sessions — O(sessions * LUNs). On a busy system with many LUNs, this is slow and can cause I/O latency spikes.
- Targeted scan asks the SCSI layer to discover exactly one LUN on the relevant host(s) — O(1).
- No timing guesswork — the scan is issued once, immediately, with the correct LUN number.
- The retry loop becomes a short wait for udev to create the symlink, not a retry-and-hope-for-rescan pattern.

## Risk

- Relies on `/sys/class/iscsi_session/` sysfs layout, which is stable across Linux 4.x+ kernels but could differ on unusual configurations.
- Falls back to original behavior if sysfs traversal fails, so worst case is no worse than current code.
