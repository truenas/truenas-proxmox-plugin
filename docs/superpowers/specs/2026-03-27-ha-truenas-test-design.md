# Tier 4: TrueNAS Enterprise HA Test Design

**Date:** 2026-03-27
**Status:** Approved

---

## Overview

Tier 4 tests validate that the Proxmox plugin survives a TrueNAS Enterprise HA failover/failback cycle. The target is an active/standby controller pair behind a shared VIP. Tests confirm API continuity, iSCSI session survival, VM resilience, and storage operation correctness across both failover and failback events.

## Approach

Single failover event followed by post-failover validation, then a failback with the same validations in reverse (Approach B). Two failover cycles total per run.

## Harness Integration

### Config type

New `--config H`. Required tiers: `1 4`. Hard gates: `T1-01 T4-04`.

### Hardware detection

`detect_max_tier` gains a Tier 4 check: Tier 1 must pass AND the TrueNAS API at `api_host` must respond to `failover.licensed` with `true`. Tier 4 is independent of Tiers 2 and 3 — an HA TrueNAS with a single Proxmox node and no multipath qualifies.

### New file

`tools/lib/tier4.sh` — same structure as other tier files: preflight, individual test functions, `run_tier4` entry point.

### API helper

Failover API calls go through the plugin's WebSocket path via a Perl shim:

```bash
tn_api_call() {
    local storage="$1" method="$2"
    shift 2
    perl -e '
        use PVE::Storage::Custom::TrueNASPlugin;
        # call method via plugin internals
    ' "$storage" "$method" "$@"
}
```

This tests the same code path the plugin uses in production.

### VMIDs

9740-9749, following the existing convention (T1: 9701-9704, T2: 9710-9712, T3: 9720-9726).

### Timeouts

Failover polling timeout: 180 seconds (3 minutes), 5-second poll intervals. TrueNAS Enterprise failover typically takes 30-90 seconds.

---

## Preflight

Tier 4 preflight confirms:

1. `api_host` in `storage.cfg` responds to API calls (VIP is reachable)
2. `failover.licensed` returns true (HA is enabled)
3. `failover.status` returns MASTER or BACKUP (both controllers healthy)
4. API key has permission to call `failover.become_passive`

If any check fails, the tier skips with a message explaining what's missing.

---

## Test Sequence

### Pre-failover setup

#### T4-01: HA status baseline

Call `failover.status`, record which controller is MASTER. Confirm `failover.licensed` is true. This is the reference point for all later checks.

#### T4-02: Create test volume and start VM

Allocate a 1G volume on the storage (vmid 9740), create a minimal VM (128M RAM, 1 core), start it. This VM stays running through the failover.

#### T4-03: Pre-failover I/O marker

Write a known marker to the volume via `dd` (same pattern as T1-03). Verifies data survives the failover.

### Failover

#### T4-04: Trigger failover — HARD GATE

Call `failover.become_passive`. Poll the VIP until the API responds again (180s timeout, 5s intervals). Confirm `failover.status` now reports the *other* controller as MASTER.

If this fails, set `HARD_GATE_FAILED=1` and skip all remaining T4 tests. Before returning, attempt to query both controllers directly (not via VIP) to log their state for diagnostics.

#### T4-05: API recovery timing

Time how long until `pvesm list <storage>` succeeds through the VIP after failover. Record elapsed time. Pass if it recovers within the retry window (same formula as T1-02: `(15 * retry_max) + (delay * retry_max) + 30`).

#### T4-06: iSCSI session reconnection

Verify `iscsiadm -m session` shows active sessions to the VIP/portal. Pass if sessions are re-established within the retry window. Fail if no sessions exist after timeout.

#### T4-07: VM survival

Check `qm status 9740` reports "running". Check `dmesg` for I/O errors on the backing device. Pass if VM is running with no I/O errors.

#### T4-08: Storage operations post-failover

Create a second volume (vmid 9741), snapshot it, resize it, delete it. Confirms the full CRUD path works against the new active controller.

### Failback

#### T4-09: Trigger failback

Call `failover.become_passive` again. Poll VIP until API responds. Confirm the original controller (recorded in T4-01) is MASTER again. 180s timeout.

If failback fails, `log_warn` that the original controller is not back in MASTER role (not a hard gate — the system is in a valid HA state, just not the original one).

#### T4-10: API recovery after failback

Same check as T4-05.

#### T4-11: VM survival after failback

Same check as T4-07. Confirm VM is still running with no I/O errors.

#### T4-12: Data integrity

Read the marker written in T4-03 from the volume via `dd`. Pass if it matches. Confirms data survived both failover and failback.

### Cleanup

Always runs regardless of pass/fail:

1. Stop and destroy test VM (`qm destroy 9740 --purge`)
2. Free all test volumes in the 9740-9749 range
3. Sweep any leftover `vm-974x-disk-*` volumes (pre-cleanup also runs at tier start)

---

## Error Handling

**Failover timeout:** If T4-04 times out, hard gate fails. Diagnostic info (controller states) logged before skipping remaining tests.

**Failback failure:** T4-09 failure is a `log_warn`, not a hard gate. The HA pair is in a valid state, just not the original topology.

**VM cleanup on failure:** Cleanup function always runs at end of `run_tier4`. Falls back to `pvesm free` for individual volumes if `qm destroy --purge` fails.

**No iptables needed:** Tests trigger real failovers through the API, not simulated outages.

**Stale state between runs:** Pre-cleanup at tier start sweeps leftover `vm-974x-disk-*` volumes from previous runs.

---

## Dependencies

- TrueNAS Enterprise HA license (not available on community SCALE)
- Active/standby controller pair with shared VIP configured as `api_host`
- API key with failover permissions
- Existing Tier 1 preflight (plugin installed, storage active)
