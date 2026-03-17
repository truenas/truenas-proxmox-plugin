# Test Plan Design — TrueNAS Proxmox VE Storage Plugin

**Date**: 2026-03-17
**Status**: Approved
**Audience**: QA team (release validation), developers (regression)

---

## 1. Goals and Scope

This spec defines a comprehensive, tiered test plan for the TrueNAS Proxmox VE Storage Plugin. It covers:

- A test harness (`tools/run-tests.sh`) with a single entry point that orchestrates all test tiers
- Three hardware tiers that auto-detect available infrastructure and skip what isn't present
- A test plan document (`wiki/Test-Plan.md`) serving as both QA checklist and developer reference
- Release gate criteria: Configs A, D, and F must pass before any release ships

This does not replace `wiki/Testing-Requirements.md` (the risk document) or the existing `tools/dev-truenas-plugin-full-function-test.sh` (preserved and called by the harness as Tier 1 core).

---

## 2. Hardware Configuration Matrix

| ID | Transport | Multipath | Nodes | Proxmox | TrueNAS | Release Gate |
|----|-----------|-----------|-------|---------|---------|--------------|
| A  | iSCSI     | off       | 1     | 8.x     | 25.10+  | ✅ Required  |
| B  | iSCSI     | on (2p)   | 1     | 8.x     | 25.10+  | Advisory     |
| C  | iSCSI     | on (2p)   | 3     | 8.x     | 25.10+  | Advisory     |
| D  | iSCSI     | on (2p)   | 3     | 9.x     | 25.10+  | ✅ Required  |
| E  | NVMe/TCP  | kernel    | 1     | 9.x     | 25.10+  | Advisory     |
| F  | NVMe/TCP  | kernel    | 3     | 9.x     | 25.10+  | ✅ Required  |

---

## 3. Harness Architecture

### Entry Point

```
tools/run-tests.sh [--storage <name>] [--config <A|D|F|all>] [--tier <1|2|3|all>] [--yes]
```

### `--config` Flag Behavior

Selecting `--config` sets the transport context for skip logic (iSCSI vs NVMe/TCP) and determines which tiers are required vs. advisory:

| Config | Transport context | Required tiers | Hard gates |
|--------|-------------------|---------------|------------|
| A      | iSCSI             | 1             | T1-01 |
| D      | iSCSI             | 1, 2          | T1-01, T2-03 |
| F      | NVMe/TCP          | 1, 3          | T1-01, T3-04 |
| all    | both              | 1, 2, 3       | T1-01, T2-03, T3-04 |

The `--config` flag also activates transport-specific skip rules (see Section 6, T3-03/T3-04 skip logic). The `--tier` flag overrides tier selection regardless of `--config`.

### Hardware Detection

When `--config` is not specified, the harness probes the environment and determines the maximum tier available:

| Probe | Required for |
|-------|-------------|
| `pvesh` available + storage active | Tier 1 |
| Multiple portals in `storage.cfg`, `use_multipath 1`, `multipathd` running | Tier 2 |
| `pvecm status` shows ≥3 nodes, all SSH-reachable | Tier 3 |

Tests above the detected tier emit `SKIP - requires <hardware>` and do not affect the exit code. When `--config` is specified, hardware detection still runs; if detected hardware is insufficient for the required tiers of the chosen config, the run aborts with exit code 2.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All non-skipped required tests passed (including all hard gates) |
| 1 | One or more required non-gate tests failed |
| 2 | Pre-flight check failed (run aborted), OR detected hardware insufficient for `--config` required tiers, OR a hard gate test failed |
| 3 | (unused; reserved) |

Hard gate failures (T1-01, T2-03, T3-04) produce exit code 2, not exit code 1, so CI consumers can distinguish "hard gate blocked release" from "non-gate test regression."

### Output Format and Existing Script Integration

The harness uses these status tokens: `[PASS]`, `[FAIL]`, `[SKIP]`, `[WARN]`, `[INFO]`.

The existing script (`dev-truenas-plugin-full-function-test.sh`) uses `[TEST]`, `[PASS]`, `[FAIL]`, `[WARN]`, `[INFO]`. The harness wrapper translates:
- `[TEST]` lines from the existing script → `[INFO]` in harness output
- `[PASS]`/`[FAIL]`/`[WARN]` lines are passed through unchanged
- The existing script's final summary counts are discarded; the harness produces its own unified summary

### Logging

- Timestamped log: `/tmp/truenas-test-YYYYMMDD-HHMMSS.log`
- Summary at end: pass count, fail count, skip count, timing per test, hard gate status

---

## 4. Tier 1 — Core Functional Tests

**Hardware required**: Any single Proxmox node with active TrueNAS storage config.
**Estimated runtime**: ~5 minutes.
**Required for**: All configs (A, D, F).

### Pre-flight checks
- Plugin file present and passes `perl -c`
- Storage active in `pvesm status`
- Running as root

### Tests carried forward from existing script
The harness calls `dev-truenas-plugin-full-function-test.sh` and maps its 8 test results (storage status, volume create/list/resize/delete, snapshot, clone, VM start/stop) into the harness output format. All 8 must pass.

### New tests added

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| T1-01 | TLS config audit | Read `storage.cfg`, grep for `api_insecure` | **Hard gate (exit 2)**: fail if `api_insecure 1` present |
| T1-02 | API retry | (1) Read `api_retry_max` and `api_retry_delay` from `storage.cfg` (defaults: 3 and 1). (2) Block port 443 with `iptables -A OUTPUT -p tcp --destination <api_host> --dport 443 -j DROP`. (3) In a background subshell, trigger `pvesm status <storage>`. (4) Wait 20 seconds (exceeds the 15-second WebSocket connect timeout, ensuring at least one retry fires). (5) Unblock with `iptables -D`. (6) Wait up to `(15 * api_retry_max) + (api_retry_delay * api_retry_max) + 30` seconds for the background `pvesm status` to exit 0. | Background `pvesm status` exits 0 after unblock; overall wall time does not exceed the computed maximum wait |
| T1-03 | Snapshot rollback | Create VM disk, write a known marker file via `qemu-img` check on the raw device, create snapshot, overwrite marker, rollback snapshot, verify marker restored | Data matches pre-snapshot state |
| T1-04 | Orphan detection — clean | Delete VM with `--purge`, run installer health check orphan scan (`./install.sh --health-check`) | Output contains "Orphaned resources: 0" or equivalent |
| T1-05 | Orphan detection — `qm destroy` | Create VM, delete with `qm destroy <VMID>`, run orphan scan | Output confirms orphans detected; logged as expected behavior |
| T1-06 | Debug logging | Set `debug 1` in `storage.cfg`, restart pvedaemon, trigger volume create, check `journalctl -u pvedaemon` for `[TrueNAS]` entries | At least one `[TrueNAS]` debug entry present in journal |
| T1-07 | Volume naming | Create 5 disks on same VMID in rapid succession using `pvesh` | All 5 created with distinct names; no `Unable to find free disk name` error |

---

## 5. Tier 2 — Multipath and ALUA Tests

**Hardware required**: Tier 1 + two NICs connected to two separate TrueNAS iSCSI portals (different IPs) + `multipath-tools` installed.
**Estimated runtime**: ~15 minutes additional.
**Required for**: Config D. Config F does not require Tier 2 (NVMe/TCP uses kernel-native multipath, not dm-multipath).

### Pre-flight checks
- `multipath-tools` installed and `multipathd` active (`systemctl is-active multipathd`)
- `use_multipath 1` in `storage.cfg`
- `portals` key present in `storage.cfg` with at least one additional portal
- Both portals reachable via `nc -zv <ip> 3260`
- Aborts Tier 2 only (not entire run) if any check fails; remaining tiers proceed

### Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| T2-01 | dm map creation | Alloc volume via `pvesh`, run `multipath -ll` | LUN appears as `/dev/mapper/mpathX` with both paths listed |
| T2-02 | Plugin returns mapper device | Run `pvesm path <volid>` | Returned path matches `/dev/mapper/mpath[0-9]+` |
| T2-03 | ALUA handler active | Run `multipath -ll`, grep for `hwhandler` | **Hard gate (exit 2)**: fail if `hwhandler='1 alua'` not present in output |
| T2-04 | Optimized path carries I/O | **Manual only.** (1) Alloc volume, start VM. (2) Run `fio --filename=/dev/mapper/mpathX --rw=randwrite --bs=4k --iodepth=16 --numjobs=1 --runtime=10 --time_based --name=test` directly on the dm device from the Proxmox node. (3) While fio runs, capture `iostat -x 1 5` output for each path device (`/dev/sdX`). (4) Parse iostat `w/s` columns. | Active Optimized path (`/dev/sdX` in prio=50 group) shows ≥ 90% of total write ops; Active Non-Optimized path (`/dev/sdX` in prio=10 group) shows ≤ 10% of total write ops. Operator records raw `iostat` values in test log. |
| T2-05 | Path failure — I/O continues | (1) Start VM with running disk I/O (background fio). (2) Block outbound iSCSI to primary portal with `iptables -A OUTPUT -p tcp --destination <portal1-ip> --dport 3260 -j DROP`. (3) Wait 30s. (4) Check VM status. | VM remains in `running` state; no disk I/O error in `dmesg` within 30s of block |
| T2-06 | Failback to optimized path | (1) Continuing from T2-05. (2) Remove `iptables` rule. (3) Run `multipath -ll` every 5s for up to 60s. | Within 60s, Active Optimized path group status returns to `active` |
| T2-07 | Stale map cleanup | Delete volume via `pvesh --purge`, run `multipath -ll` | Map for deleted WWID no longer present in output |
| T2-08 | Silent fallback detection | (1) Alloc volume (create dm map). (2) Run `multipath -f <wwid>` to remove map. (3) Remove WWID from `/etc/multipath/wwids`. (4) Run `multipath -r`. (5) Call `pvesm path <volid>`. (6) Check `journalctl -u pvedaemon` for warning. | `pvesm path` returns a by-path device (not `/dev/mapper/...`); journal contains a warning-level log entry indicating multipath map not found |
| T2-09 | `replacement_timeout` value | Read `/etc/iscsi/iscsid.conf`, extract `node.session.timeo.replacement_timeout` | Value ≤ 15; fail with message "Set replacement_timeout = 15 in /etc/iscsi/iscsid.conf" if exceeded |

---

## 6. Tier 3 — Cluster and Migration Tests

**Hardware required**: Tier 1 + 3-node Proxmox cluster, all nodes SSH-reachable as root without password prompt.
**Estimated runtime**: ~20 minutes additional.
**Required for**: Configs D and F.

*Note: Tier 2 is NOT required for Config F. Config F requires Tier 1 + Tier 3 only.*

### Pre-flight checks
- `pvecm status` shows ≥3 nodes, all online
- SSH to each peer node succeeds (`ssh -o BatchMode=yes root@<node> true`)
- Plugin file checksum identical on all nodes
- Storage active on all nodes (`pvesm status` via SSH)
- For Config D: multipath config files consistent across nodes (md5sum of `/etc/multipath.conf` and `/etc/multipath/wwids`)

### Transport-specific skip rules

| Test | Config D (iSCSI) | Config F (NVMe/TCP) |
|------|-----------------|---------------------|
| T3-03 (iSCSI migration) | Run | SKIP |
| T3-04 (NVMe/TCP migration) | SKIP | Run |
| T3-05 (multipath post-migration) | Run | SKIP |
| T3-06 (config consistency) | Run (checks multipath files) | Run (checks nvme hostnqn files) |

### Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| T3-01 | Shared storage visibility | Create volume on node 1 via `pvesh` | Volume appears in `pvesm list <storage>` output when run via SSH on nodes 2 and 3 |
| T3-02 | Concurrent VM creation | Simultaneously run `pvesh POST /nodes/<node1>/qemu` and `pvesh POST /nodes/<node2>/qemu` with disks on shared storage (use `&` and `wait`) | Both VMs created with distinct disk names; no lock timeout errors in `journalctl` |
| T3-03 | Live migration (iSCSI) | `qm migrate <VMID> <node2> --online` | Command exits 0; VM running on node2; `pvesm path <volid>` on node2 returns `/dev/mapper/mpathX` |
| T3-04 | Live migration (NVMe/TCP) | `qm migrate <VMID> <node2> --online` | Command exits 0; VM running on node2; `nvme list-subsys` on node2 shows connected namespace |
| T3-05 | Multipath state post-migration | Run `multipath -ll` on destination node after T3-03 | Both paths listed as active; no `failed` or `ghost` paths |
| T3-06 | Per-node config consistency | md5sum `/etc/multipath.conf` (iSCSI) or `/etc/nvme/hostnqn` (NVMe/TCP) on all nodes via SSH | All checksums match; fail with "Node <name> has different config" if any differ |
| T3-07 | Cluster lock timeout | (1) Read `storage_lock_timeout` from `storage.cfg` (default: 120). (2) Record wall-clock start time. (3) Trigger concurrent volume creates: `ssh root@<node1> pvesh POST ... & ssh root@<node2> pvesh POST ... & wait`. (4) Record wall-clock end time when `wait` returns. | `wait` returns within `storage_lock_timeout` seconds of start time; both SSH jobs exit 0; no `lock timeout` errors in `journalctl -u pvedaemon` on any node |
| T3-08 | Orphan scan — all nodes | After all VMs deleted cleanly, run installer orphan scan via SSH on each node | All nodes report zero orphans |
| T3-09 | Plugin version consistency | md5sum plugin file on all nodes | Identical checksums; fail with differing node names if any differ |

---

## 7. Release Gate Criteria

A release is blocked if any required-tier test fails for a required config, or if any hard gate fails.

| Config | Required tiers | Hard gates | Sign-off required |
|--------|---------------|------------|-------------------|
| A (single-node iSCSI) | 1 | T1-01 | QA lead |
| D (iSCSI cluster + multipath) | 1, 2 | T1-01, T2-03 | QA lead |
| F (NVMe/TCP cluster) | 1, 3 | T1-01, T3-04 | QA lead |

### Sign-off Record Structure

The `wiki/Test-Plan.md` release gate checklist contains one row per required config:

| Config | Run date | Operator | Harness exit code | Hard gates | Result | Notes |
|--------|----------|----------|-------------------|------------|--------|-------|
| A | | | | T1-01 | | |
| D | | | | T1-01, T2-03 | | |
| F | | | | T1-01, T3-04 | | |

QA lead signs (name + date) after all three rows show exit code 0. This record is committed to the repo before the release tag is created.

---

## 8. Test Plan Document Structure (`wiki/Test-Plan.md`)

The document produced by this plan contains:

1. Overview and relation to `Testing-Requirements.md`
2. Hardware configuration matrix (A–F) with required vs. advisory designation
3. Running the harness — command reference, flag descriptions, exit codes, output token meanings, log file location
4. Tier definitions — hardware requirements per tier, detection logic, `--tier` override behavior
5. Test case reference — full table of all test IDs across tiers (ID, tier, description, procedure, pass criteria, automated/manual)
6. Manual procedures — items the harness cannot automate: physical NIC disconnection for true hardware failure simulation (vs. `iptables`), visual inspection of `fio` / `iostat` output for ALUA path preference, interpretation of `journald` log entries for debug level validation
7. Release gate checklist — sign-off table (structure defined in Section 7 above)
8. Developer regression rules (Section 9 below)

---

## 9. Developer Regression Rules

| Code area changed | Minimum required |
|---|---|
| Any plugin code change | Tier 1 full (Config A) |
| Multipath or ALUA code paths | Tier 1 + Tier 2 (Config D) |
| Cluster or migration code paths | Tier 1 + Tier 3 (Config F) |
| Installer only | T1-01 (TLS audit) + installer health check |
| Documentation only | No test run required |

---

## 10. Files Created or Modified

| File | Action |
|------|--------|
| `tools/run-tests.sh` | New — harness entry point |
| `tools/lib/common.sh` | New — shared utilities: logging functions, `iptables` path-block helpers, SSH remote-run helpers, `storage.cfg` value reader |
| `tools/lib/tier1.sh` | New — Tier 1 test functions; calls existing script internally |
| `tools/lib/tier2.sh` | New — Tier 2 test functions |
| `tools/lib/tier3.sh` | New — Tier 3 test functions |
| `tools/dev-truenas-plugin-full-function-test.sh` | Unchanged — called by `tier1.sh` |
| `wiki/Test-Plan.md` | New — executable test plan document |
