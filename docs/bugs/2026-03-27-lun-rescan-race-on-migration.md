# Bug: LUN not discovered on destination node during multi-disk live migration

**Date:** 2026-03-27
**Status:** Diagnosed, patch ready (not applied)
**Affected:** `TrueNASPlugin.pm` — `_device_for_lun()` (line 2599)

---

## Symptom

Live migration of a VM with 3 disks fails on the destination node:

```
Could not locate by-path device for LUN 12 (IQN iqn.2005-10.org.freenas.ctl:truenas-main, retries 200).
Sessions: tcp: [1] 192.168.100.10:3260,1 iqn.2005-10.org.freenas.ctl:truenas-main (non-flash).
by-path: ...-lun-11, ...-lun-9, ...-lun-8, ...-lun-7, ...-lun-5, ...-lun-6, ...-lun-4,
         ...-lun-1, ...-lun-3, ...-lun-2, ...-lun-0
```

LUNs 0-9 and 11 are visible. LUNs 10 and 12 are not. The iSCSI session is connected.

## Root Cause

`_device_for_lun()` retries 200 times with a 100ms sleep (~20s total) looking for a by-path symlink. It calls `iscsiadm -m session -R` (which tells the kernel to re-scan the iSCSI target for new LUNs) only at iterations 10, 20, 35, 60, 100, and 150.

The problem is twofold:

1. **`udevadm settle` doesn't discover new LUNs.** Between rescans, the loop only runs `udevadm settle`, which waits for already-discovered devices to stabilize. It does not ask the target about new LUNs. If TrueNAS publishes the LUN between rescan intervals, the kernel won't see it until the next `iscsiadm -m session -R`.

2. **Multi-disk migration creates LUNs in rapid succession.** Each disk's `activate_volume` on the destination node calls `_iscsi_login_all` (which is a no-op since the session already exists) and then `_device_for_lun`. The third disk's LUN may be mapped on TrueNAS but the destination kernel was last rescanned during the second disk's activation — the third LUN was not yet published at that point.

The rescan at iteration 10 (~1s) is too late for the common case, and the gap between iteration 10 and 20 (~1s) is long enough for a freshly-mapped LUN to be missed entirely if TrueNAS takes >1s to publish after the extent-targetextent mapping is created.

## Fix

Rescan more frequently in the early iterations where timing is most critical. The current schedule rescans at iterations {10, 20, 35, 60, 100, 150}. The fix changes this to {3, 6, 10, 15, 20, 35, 60, 100, 150}, adding three early rescans in the first ~1.5s when a freshly-mapped LUN is most likely to appear.

## Patch

See: `docs/bugs/patches/2026-03-27-lun-rescan-race.patch`

## How to Test

Run the multi-disk migration test (test phase 27 in `dev-truenas-plugin-full-function-test.sh`) which creates a VM with 3 disks and live-migrates it. Before this fix, LUN discovery fails intermittently on the destination node. After the fix, the earlier rescans should catch newly-published LUNs.

Alternatively, run the test harness:
```bash
tools/run-tests.sh --storage truenas-main --config all --tier 3 --yes
```
T3-03 (live migration) exercises this code path.
