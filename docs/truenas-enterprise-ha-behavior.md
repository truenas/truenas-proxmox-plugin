# TrueNAS Enterprise HA: How It Works and What the Plugin Needs to Handle

This document describes the observed behavior of TrueNAS Enterprise HA from the Proxmox initiator's perspective, based on testing against a real HA pair. It covers the failover mechanics, iSCSI session behavior, ALUA path state transitions, and known issues discovered during Tier 4 and Tier 5 test development.

---

## Architecture

A TrueNAS Enterprise HA system consists of two controllers (A and B) sharing a storage pool. One controller is active (MASTER), the other is standby (BACKUP). A virtual IP (VIP) floats between them — the VIP always points to the active controller.

Three IP addresses matter:

| Address | What it is | When to use |
|---------|-----------|-------------|
| VIP | Floats to active controller | `api_host`, `discovery_portal` — for API calls and initial target discovery |
| Controller A IP | Physical, always on A | `portals` entry — iSCSI data path |
| Controller B IP | Physical, always on B | `portals` entry — iSCSI data path |

The plugin talks to the TrueNAS API through the VIP. iSCSI data sessions connect to both controller IPs directly for dual-path ALUA multipath.

## Failover Mechanics

### Why ALUA doesn't help during controller failover

This is the most important thing to understand about TrueNAS HA. ALUA provides two iSCSI paths — one through each controller. The expectation might be that when the active controller fails, I/O seamlessly switches to the standby's path. **This does not happen.**

During failover, the standby controller must do a full `zpool import` before it can serve any iSCSI targets. This is not a quick metadata handoff — it is a complete ZFS pool import, the same operation as importing a pool from detached disks. The import includes reading pool metadata, replaying the ZFS intent log (ZIL) for any uncommitted transactions, and mounting all datasets. No I/O can be served while this is happening.

Until the pool import completes, neither controller can serve I/O:

- The active controller's path is dead (it's shutting down)
- The standby controller's path exists but cannot serve I/O (no pool = no zvols = no LUNs to export as iSCSI targets)

There is a hard I/O blackout from the moment the active controller begins shutting down until the new active controller finishes importing the pool, re-creates the iSCSI target-to-extent mappings, and starts serving LUNs. ALUA does not shorten this blackout. The dual paths give you redundancy for **network** failures (link down, switch failure) but not for **controller** failover.

The duration of the blackout depends primarily on the pool size and how much ZIL replay is needed. Observed import times in testing ranged from under 1 second (fast failover, pool recently synced) to over 100 seconds (full reboot with large pool). This is the window that iSCSI timeout tuning must cover — sessions must be configured to wait out the entire pool import time without declaring the target dead.

### Failover sequence

Failover is triggered by calling `failover.become_passive` on the active controller's API. What happens:

1. The active controller begins shutting down its services
2. The VIP moves to the other controller
3. The former standby imports the ZFS pool and starts iSCSI target services — **this is the blackout period**
4. iSCSI sessions on the initiator (Proxmox) detect the disruption and attempt recovery

**Observed timing:**

| Event | Typical | Worst case |
|-------|---------|------------|
| VIP failover (API responds on new controller) | 1-4s | 110s |
| `pvesm list` succeeds through plugin | 3-5s after API | 13s after API |
| iSCSI session reconnection | 0s (already connected to both portals) | N/A for dual-path |
| Standby controller fully rebooted and ready | 34-95s | 125s |

A failover is fast (1-4s) when the standby controller is warm and ready. It's slow (60-125s) when the standby is still rebooting from a previous failover. In test runs where failover and failback happen back-to-back, the failback is typically slow because the former active controller hasn't finished rebooting yet. In production, where failovers are infrequent, both directions should be fast.

## iSCSI Session Behavior During Failover

### Single-path (VIP only)

With a single iSCSI session to the VIP:

1. The VIP drops — the session enters recovery
2. The kernel's SCSI error handler starts a `replacement_timeout` countdown
3. When the VIP comes back on the new controller, the session reconnects
4. If the outage exceeds `replacement_timeout`, the SCSI layer returns I/O errors and QEMU may stop the VM

### Dual-path (ALUA multipath)

With sessions to both controller IPs:

1. The active controller's path drops — that path goes to `i/o pending` or `faulty`
2. dm-multipath redirects I/O to the remaining path (the former standby, now active)
3. When the former active reboots and rejoins, its path recovers as Non-Optimized

This is more resilient than single-path because I/O continues on the surviving path. However, the `fast_io_fail_tmo` in `multipath.conf` controls how long multipath waits before marking a path as failed — the default of 5s is too short for HA and causes permanent path failure.

## ALUA Path State Transitions

ALUA's value in an HA environment is in the steady state before and after failover — it ensures I/O goes through the optimal path. During the failover itself, ALUA cannot help because neither path can serve I/O until the pool import completes on the new active controller (see above).

With ALUA configured (`hardware_handler "1 alua"`, `prio alua` in multipath.conf), each path has an ALUA priority:

### Before failover (steady state)
```
Active controller path:  prio=50  status=active    (Active Optimized)
Standby controller path: prio=10  status=enabled   (Active Non-Optimized)
```

### During/after failover
```
Former active path:  prio=0   status=active, i/o pending  (transitioning)
New active path:     prio=1   status=enabled, ready        (now preferred)
```

Note: the priorities after failover are **not** 50/10 — they're 0/1 (or sometimes 10/1). TrueNAS uses different ALUA target port group states during the transition. The `status=active` label on the old path is misleading — multipath keeps it as the active group even though it's pending, while the `enabled` path with higher prio is actually serving I/O.

### After failback (eventual steady state)
```
Original active path: prio=50  status=active    (restored)
Original standby path: prio=10 status=enabled   (restored)
```

The return to 50/10 priorities is not immediate — it can take 5-170 seconds after failback for ALUA priorities to fully restore.

## Known Issues

### 1. ALUA hardware handler lost during failover

**Severity: High**

During failover, `multipathd` rebuilds multipath maps for all devices. The rebuilt maps lose the `hwhandler='1 alua'` setting and revert to `hwhandler='0'`. This was observed as a global degradation — all 11 multipath devices on the system lost ALUA simultaneously.

Without the ALUA handler, multipath cannot query the target for path state information. Path priorities become meaningless, and multipath falls back to basic path selection.

The handler eventually recovers (observed to return by the next test cycle), but during the failover window itself, ALUA is non-functional.

**Impact:** During the failover window, I/O may be routed through the wrong path (the non-optimized one), causing latency degradation. If the non-optimized path is the one that's failing, I/O may stall.

**Detection:** T5-05 and T5-11 in the test harness catch this. `multipath -ll | grep hwhandler` will show `'0'` instead of `'1 alua'`.

**Mitigation:** Add `retain_attached_hw_handler yes` to the `defaults` section of `/etc/multipath.conf`. This tells multipathd to preserve the ALUA hardware handler when reconfiguring multipath maps during path disruptions. Testing confirmed this prevents the handler loss during fast failovers.

### 2. Double iSCSI session drop during failback

**Severity: Medium**

Failback causes two separate iSCSI disruptions:

1. Initial session drop when the VIP/controller swap begins
2. A second session drop caused by `noop_out_timeout` — the reconnected session's target isn't ready to respond to pings within the timeout window

The second drop starts a fresh `recovery_tmo` (or `fast_io_fail_tmo`) countdown. With the default 5s `noop_out_timeout`, the second drop happens almost immediately after the session reconnects.

**Mitigation:** Set `noop_out_interval = 15` and `noop_out_timeout = 30` in `/etc/iscsi/iscsid.conf` before establishing sessions. Set `fast_io_fail_tmo = 280` in `/etc/multipath.conf` for multipath environments.

### 3. multipathd overrides iSCSI replacement_timeout

**Severity: High (configuration trap)**

When dm-multipath is active, `multipathd` forcibly sets each iSCSI session's kernel `recovery_tmo` to the value of `fast_io_fail_tmo` (default: 5s). This completely ignores:
- `replacement_timeout` in `/etc/iscsi/iscsid.conf`
- Node record values set via `iscsiadm -o update`

The fix is `fast_io_fail_tmo 280` in `/etc/multipath.conf`, **not** `replacement_timeout` in `iscsid.conf`.

Reference: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/dm_multipath/iscsi-and-dm-multipath-overrides

### 4. Per-path I/O statistics not tracked after ALUA transition

**Severity: Low**

After an ALUA transition, `/sys/block/<sd>/stat` for individual paths may stop incrementing even while I/O continues successfully through the dm-multipath device. This is a kernel accounting issue — the I/O is flowing but the per-path counters don't reflect it.

The dm-multipath device's own stat counters may also stop tracking after the transition.

**Impact:** Makes it difficult to verify which physical path is carrying I/O after a failover using sysfs stats alone. The test harness works around this by checking the I/O process health (alive, zero errors, zero skips) as a fallback.

### 5. VIP session is redundant with dual-portal ALUA

**Severity: Informational**

When `portals` lists both controller IPs, the VIP iSCSI session is unnecessary for data I/O — the two controller sessions provide full coverage. The VIP session may fail to re-login after a failover if both controller sessions are already connected (TrueNAS rejects duplicate sessions to the same target).

The plugin uses the VIP for API calls (`api_host`), but the iSCSI data path should be through the controller-specific portals only.

## API Endpoints Used for HA

| Method | Purpose |
|--------|---------|
| `failover.licensed` | Check if HA license is active (returns `true`/`false`) |
| `failover.status` | Current controller role: `MASTER` or `BACKUP` |
| `failover.node` | Physical controller identifier: `A` or `B` |
| `failover.become_passive` | Trigger failover — current active becomes standby |
| `failover.config` | HA configuration details (used as permission check) |
| `failover.call_remote` | Execute an API call on the other controller (e.g., `core.ping` to check standby health) |

All are called via the WebSocket API through the VIP.

## Configuration Summary

### /etc/pve/storage.cfg
```ini
truenasplugin: ha-storage
    api_host <VIP>
    api_key <key>
    target_iqn <iqn>
    dataset <pool/dataset>
    discovery_portal <VIP>:3260
    portals <controller-A-IP>:3260,<controller-B-IP>:3260
    use_multipath 1
    force_delete_on_inuse 1
```

### /etc/multipath.conf
```conf
defaults {
    find_multipaths no
    fast_io_fail_tmo 280
    failback immediate
    no_path_retry queue
    retain_attached_hw_handler yes
}

devices {
    device {
        vendor "TrueNAS"
        product "iSCSI Disk"
        hardware_handler "1 alua"
        prio alua
        path_grouping_policy group_by_prio
        failback immediate
        no_path_retry queue
        retain_attached_hw_handler yes
    }
}
```

### /etc/iscsi/iscsid.conf
```ini
node.session.timeo.replacement_timeout = 280
node.conn[0].timeo.noop_out_interval = 15
node.conn[0].timeo.noop_out_timeout = 30
```

Set these **before** establishing any iSCSI sessions. For multipath environments, `fast_io_fail_tmo` in `multipath.conf` is what actually controls the session recovery timeout — `replacement_timeout` in `iscsid.conf` is overridden.

### Session establishment
```bash
iscsiadm -m discovery -t sendtargets -p <controller-A-IP>:3260
iscsiadm -m discovery -t sendtargets -p <controller-B-IP>:3260
iscsiadm -m node -T <iqn> --login
```

Do NOT establish a separate session to the VIP for data I/O when using dual-portal ALUA.

## Test Coverage

| Tier | Config | What it tests |
|------|--------|--------------|
| Tier 4 | `--config H` | Single-path HA: API recovery, iSCSI reconnection, VM survival, data integrity, background I/O through failover/failback |
| Tier 5 | `--config G` | ALUA + HA: path state transitions, dm-multipath I/O continuity, I/O routing through active path, ALUA handler persistence |
