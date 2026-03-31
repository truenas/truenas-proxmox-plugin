# Tier 5: ALUA + HA Failover Test Design

**Date:** 2026-03-31
**Status:** Approved

---

## Overview

Tier 5 tests validate that ALUA (Asymmetric Logical Unit Access) path states transition correctly during TrueNAS Enterprise HA failover/failback, and that dm-multipath seamlessly redirects I/O through the transition without errors. The target environment is a TrueNAS HA pair with dual iSCSI portals — one per controller — where the active controller serves Active Optimized paths and the standby serves Active Non-Optimized paths.

## Approach

Self-contained tier with three phases: (1) verify ALUA baseline with both paths up, (2) trigger failover and verify ALUA states swap while I/O continues on the dm-multipath device, (3) trigger failback and verify states return to baseline. Background I/O runs on the dm-multipath device (not raw by-path) throughout, which is how production VMs use it.

## Harness Integration

### Config type

New `--config G`. Required tiers: `1 5`. Hard gates: `T1-01 T5-04`.

### Hardware detection

`TIER5_AVAILABLE` flag, set when:
- `MAX_TIER >= 1`
- `use_multipath 1` in storage.cfg
- `portals` has at least 2 entries
- `failover.licensed` returns true

Independent of Tiers 2/3/4.

### New file

`tools/lib/tier5.sh` — same structure as other tier files.

### Shared helpers

Move failover helpers from tier4.sh to common.sh with tier-neutral names:
- `tier4_wait_for_api` → `ha_wait_for_api`
- `tier4_wait_for_standby` → `ha_wait_for_standby`
- Related globals: `HA_FAILOVER_TIMEOUT`, `HA_POLL_INTERVAL`, `HA_STANDBY_TIMEOUT`, `HA_RECOVERY_ELAPSED`

Tier 4 updated to use the renamed versions.

New helper in common.sh: `parse_multipath_ll` — parses `multipath -ll` output to extract dm device name, hwhandler, path group priorities, path statuses, and portal IPs. Used by both Tier 2 and Tier 5 instead of ad-hoc grep chains.

### VMIDs

9750-9759.

### Timeouts

Same as Tier 4: 180s failover polling, 5s poll intervals, 300s standby readiness wait.

---

## Preflight

Tier 5 preflight confirms:

1. `multipath-tools` installed and `multipathd` active
2. `multipath.conf` has `hardware_handler "1 alua"` and `prio alua` in the TrueNAS devices block
3. Storage has `use_multipath 1` in storage.cfg
4. Storage has `portals` with at least 2 portal IPs
5. Both portals reachable on port 3260
6. iSCSI sessions exist to both portals
7. `multipath -ll` shows at least one device with `hwhandler='1 alua'` and two path groups (prio=50 Active Optimized, prio=10 Active Non-Optimized)
8. TrueNAS HA licensed and `failover.status` returns MASTER

If any check fails, the tier skips with a message explaining what's missing.

---

## Test Sequence

### Phase 1: Baseline

#### T5-01: ALUA path state baseline

Parse `multipath -ll` output. Record:
- Which portal IP is Active Optimized (prio=50)
- Which portal IP is Active Non-Optimized (prio=10)
- The dm-multipath device name
- `hwhandler='1 alua'` confirmed
- Which HA controller is MASTER via `failover.node`

This is the reference point for all later comparisons.

#### T5-02: Create test volume on dm-multipath

Allocate a 1G volume (vmid 9750). Verify `pvesm path` returns a `/dev/mapper/` device. Confirm the dm device appears in `multipath -ll` with two path groups at the correct priorities.

#### T5-03: I/O routing baseline

Start background I/O on the dm-multipath device. Read per-path `/sys/block/<sd>/stat` before and after a few seconds of I/O. Verify the Active Optimized path's write count is increasing while the Non-Optimized path's write count is not (or near-zero). This is the automated version of the currently manual-only T2-04.

### Phase 2: Failover

#### T5-04: Trigger failover — HARD GATE

Call `failover.become_passive`. Poll VIP until API responds (180s timeout). Confirm controller changed via `failover.node`.

If this fails, set `HARD_GATE_FAILED=1` and skip remaining tests.

#### T5-05: ALUA state transition

Parse `multipath -ll` again. Verify path priorities have swapped:
- Previously Non-Optimized portal is now Active Optimized (prio=50)
- Previously Optimized portal is now Non-Optimized (prio=10) or temporarily offline

Poll `multipath -ll` for up to 60s for the state transition to complete — ALUA state changes are not instantaneous after failover.

#### T5-06: Multipath I/O continuity

Check that the background I/O process is still alive with zero errors. Check `multipath -ll` for any failed or faulty paths — poll for up to 60s for all paths to return to `active` or `enabled` before failing. Check dmesg for I/O errors. This validates that dm-multipath seamlessly redirected I/O during the ALUA state change.

#### T5-07: I/O routing after failover

Same per-path stat check as T5-03. Verify I/O is now flowing through the new Active Optimized path (the one that was Non-Optimized before failover).

### Phase 3: Failback

#### T5-08: Wait for standby, trigger failback

Wait for standby readiness via `failover.call_remote core.ping` (300s timeout). Trigger failback. Confirm original controller is MASTER again. Emit replacement_timeout proximity warning if failback is slow.

#### T5-09: ALUA state restored

Parse `multipath -ll`. Verify priorities match the original baseline from T5-01 — the original Active Optimized portal is back to prio=50. Poll for up to 60s for the transition to complete.

#### T5-10: Multipath I/O continuity after failback

Stop background I/O, check for errors across the full failover/failback cycle. Check `multipath -ll` for failed/faulty paths. Check dmesg for I/O errors.

#### T5-11: Path group health

Final `multipath -ll` check. All paths `active` or `enabled`, no `ghost`/`failed`/`faulty` paths, correct priority groups restored matching T5-01 baseline.

### Cleanup

Always runs regardless of pass/fail:
1. Free test volumes in 9750-9759 range
2. Sweep leftover `vm-975x-disk-*` volumes

---

## Error Handling

**Failover timeout:** If T5-04 times out, hard gate fails. Skip remaining tests.

**ALUA state doesn't swap:** T5-05 failure — not a hard gate. Reports expected vs actual priorities for both portals. Indicates either ALUA isn't responding to the controller change or multipathd hasn't re-evaluated path groups yet.

**Path goes faulty during failover:** T5-06 polls `multipath -ll` for up to 60s for recovery. Transient `faulty` state is expected during the transition; persistent faulty after 60s is a failure.

**dm-multipath device disappears:** Hard failure — the dm device should persist even when one underlying path drops. Logged with full multipath state.

**Failback warning:** Same replacement_timeout threshold check as Tier 4's T4-09.

**Cleanup:** Same pattern as Tier 4 — destroy VMs/volumes in 9750-9759 range.

---

## Dependencies

- TrueNAS Enterprise HA license
- Active/standby controller pair with dual iSCSI portals (one per controller)
- `multipath-tools` installed, `multipathd` active
- `multipath.conf` with TrueNAS ALUA devices block (`hardware_handler "1 alua"`, `prio alua`)
- `use_multipath 1` and `portals` configured in storage.cfg
- API key with failover permissions
- Existing Tier 1 preflight (plugin installed, storage active)
