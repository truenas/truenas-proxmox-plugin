# TrueNAS Proxmox Plugin — Test Plan

> This is the executable test plan. For risk analysis and background on ALUA/multipath requirements, see `wiki/Testing-Requirements.md`.

---

## 1. Overview

This plan covers functional, multipath, and cluster testing for the TrueNAS Proxmox VE Storage Plugin. Tests are organized in three hardware tiers. The automated harness (`tools/run-tests.sh`) runs all tiers that the available hardware supports.

Three hardware configurations are required for every release:

| Config | Environment | Release Gate |
|--------|-------------|--------------|
| A | Single-node iSCSI, no multipath, Proxmox 8.x | Required |
| D | 3-node iSCSI cluster + multipath, Proxmox 9.x | Required |
| F | 3-node NVMe/TCP cluster, Proxmox 9.x | Required |

Configs B, C, and E are advisory — run them when hardware is available but they do not block a release.

---

## 2. Hardware Configuration Matrix

| ID | Transport | Multipath | Nodes | Proxmox | TrueNAS | Release Gate |
|----|-----------|-----------|-------|---------|---------|--------------|
| A  | iSCSI     | off       | 1     | 8.x     | 25.10+  | Required |
| B  | iSCSI     | on (2p)   | 1     | 8.x     | 25.10+  | Advisory |
| C  | iSCSI     | on (2p)   | 3     | 8.x     | 25.10+  | Advisory |
| D  | iSCSI     | on (2p)   | 3     | 9.x     | 25.10+  | Required |
| E  | NVMe/TCP  | kernel    | 1     | 9.x     | 25.10+  | Advisory |
| F  | NVMe/TCP  | kernel    | 3     | 9.x     | 25.10+  | Required |

---

## 3. Running the Harness

### Prerequisites

- Run as root on a Proxmox VE node
- Plugin installed: `/usr/share/perl5/PVE/Storage/TrueNASPlugin.pm`
- Storage configured and active in `pvesm status`
- **Test environment only** — the harness creates and destroys VMs and volumes

### Command Reference

```bash
# Run all tiers auto-detected from hardware, prompt before running
tools/run-tests.sh --storage <name>

# Run Config A gates only (Tier 1, single-node iSCSI)
tools/run-tests.sh --storage <name> --config A --yes

# Run Config D gates (Tier 1 + Tier 2, iSCSI cluster + multipath)
tools/run-tests.sh --storage <name> --config D --yes

# Run Config F gates (Tier 1 + Tier 3, NVMe/TCP cluster)
tools/run-tests.sh --storage <name> --config F --yes

# Run only Tier 2 tests regardless of config
tools/run-tests.sh --storage <name> --tier 2 --yes
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--storage <name>` | (required) | Proxmox storage ID configured for TrueNAS plugin |
| `--config <A\|D\|F\|all>` | `all` | Hardware config context; validates hardware and sets transport skip rules |
| `--tier <1\|2\|3\|all>` | `all` | Override tier selection; overrides `--config` tier logic |
| `--yes` | off | Skip confirmation prompt |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All non-skipped required tests passed |
| 1 | One or more required non-gate tests failed |
| 2 | Pre-flight abort, hardware insufficient for `--config`, or hard gate failed |

### Output Tokens

| Token | Meaning |
|-------|---------|
| `[PASS]` | Test passed |
| `[FAIL]` | Test failed — review and fix before release |
| `[SKIP]` | Test not applicable (hardware not present or transport mismatch) |
| `[WARN]` | Non-blocking advisory; log and investigate |
| `[INFO]` | Informational — no action required |

### Log File

Timestamped log written to `/tmp/truenas-test-YYYYMMDD-HHMMSS.log`. Submit with any bug reports.

---

## 4. Hardware Tiers

### Tier 1 — Core Functional (All Configs)

**Hardware:** Any single Proxmox node with active TrueNAS storage.
**Runtime:** ~5 minutes.

The harness detects Tier 1 when `pvesh` is available and the specified storage is active in `pvesm status`.

### Tier 2 — Multipath and ALUA (Configs B, C, D)

**Hardware:** Tier 1 + two NICs connected to separate TrueNAS iSCSI portals + `multipath-tools` installed.
**Runtime:** ~15 minutes additional.

The harness detects Tier 2 when `multipathd` is active, `use_multipath 1` is in `storage.cfg`, and a `portals` key is present.

Tier 2 is not required for Config F (NVMe/TCP uses kernel-native multipath, not `dm-multipath`).

### Tier 3 — Cluster and Migration (Configs C, D, F)

**Hardware:** Tier 1 + 3-node Proxmox cluster, all nodes SSH-reachable as root without a password prompt.
**Runtime:** ~20 minutes additional.

The harness detects Tier 3 when `pvecm status` shows >=3 nodes and all peers are SSH-reachable.

**Prerequisite:** Set up passwordless SSH between all cluster nodes before running Tier 3:
```bash
# On each node, copy your root SSH key to all peers
ssh-copy-id root@<peer-node>
```

### Tier Override

`--tier` overrides `--config` tier logic. Use to run a single tier in isolation during development:
```bash
tools/run-tests.sh --storage mystore --tier 2 --yes
```

---

## 5. Test Case Reference

### Tier 1

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T1-core | Existing script: storage status, create/list/resize/delete, snapshot, clone, VM start/stop (8 sub-tests) | Yes | — |
| T1-01 | TLS config audit — `api_insecure 1` must not be present | Yes | **Exit 2** |
| T1-02 | API retry after connection loss — `pvesm status` recovers within computed window | Yes | — |
| T1-03 | Snapshot rollback data integrity | Yes | — |
| T1-04 | Orphan detection — clean deletion (`--purge`) leaves zero orphans | Yes | — |
| T1-05 | Orphan detection — `qm destroy` without `--purge` detected by health check | Yes | — |
| T1-06 | Debug logging — `debug 1` produces `[TrueNAS]` entries in `journald` | Yes | — |
| T1-07 | Volume naming uniqueness — 5 disks in rapid succession get distinct names | Yes | — |

### Tier 2

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T2-01 | dm-multipath map creation — LUN appears as `/dev/mapper/mpathX` | Yes | — |
| T2-02 | Plugin returns mapper device path from `pvesm path` | Yes | — |
| T2-03 | ALUA hardware handler — `hwhandler='1 alua'` in `multipath -ll` | Yes | **Exit 2** |
| T2-04 | Optimized path carries >=90% of write I/O (iostat verification) | **Manual** | — |
| T2-05 | Path failure — VM stays running when primary portal is blocked | Yes | — |
| T2-06 | Failback — Active Optimized path restored within 60s of portal unblock | Yes | — |
| T2-07 | Stale map cleanup — dm map removed after volume deletion | Yes | — |
| T2-08 | Silent fallback detection — pvedaemon logs warning when dm map removed externally | Yes | — |
| T2-09 | `replacement_timeout` <=15s in `/etc/iscsi/iscsid.conf` | Yes | — |

### Tier 3

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T3-01 | Shared storage visibility — volume created on node 1 visible on nodes 2 and 3 | Yes | — |
| T3-02 | Concurrent VM creation on two nodes — no lock timeouts | Yes | — |
| T3-03 | Live migration (iSCSI) — VM migrates online; disk path is mapper device on destination | Yes (Config D) | — |
| T3-04 | Live migration (NVMe/TCP) — VM migrates online; NVMe subsystem connected on destination | Yes (Config F) | **Exit 2** |
| T3-05 | Multipath state post-migration — no failed or ghost paths on destination node | Yes (Config D) | — |
| T3-06 | Per-node config consistency — `/etc/multipath.conf` or `/etc/nvme/hostnqn` checksums match | Yes | — |
| T3-07 | Cluster lock timeout — concurrent creates complete within `storage_lock_timeout` | Yes | — |
| T3-08 | Orphan scan on all nodes after clean deletion | Yes | — |
| T3-09 | Plugin version consistency — identical checksums on all nodes | Yes | — |

---

## 6. Manual Procedures

Some tests require operator judgment and cannot be fully automated.

### T2-04: ALUA Path Distribution

The harness marks T2-04 as `[SKIP]` and logs instructions. To complete this test manually:

1. Identify the dm device: `multipath -ll` — note the `/dev/mapper/mpathX` name.
2. Run a write workload: `fio --filename=/dev/mapper/mpathX --rw=randwrite --bs=4k --iodepth=16 --numjobs=1 --runtime=10 --time_based --name=alua-test`
3. While fio runs, capture path stats: `iostat -x 1 5 /dev/sd*`
4. In the `multipath -ll` output, identify which `/dev/sdX` device is in the `prio=50` group (Active Optimized) and which is in the `prio=10` group (Active Non-Optimized).
5. Parse the `w/s` column from `iostat` for each device.

**Pass criterion:** Active Optimized path (`prio=50` group) carries >=90% of total write operations. Active Non-Optimized path carries <=10%.

Record the raw `iostat` output in the test log before signing off.

### Physical NIC Disconnection

`iptables` rules simulate path failure at the packet level. For a real hardware failure test (NIC pull), use T2-05 as a template but disconnect the physical interface instead of adding an `iptables` rule. The pass/fail criteria are the same.

### Debug Log Verification (T1-06)

The harness checks for `[TrueNAS]` in the journal. If the test fails, verify manually:
```bash
journalctl -u pvedaemon -f &
pvesm status <storage>
# Look for [TrueNAS] prefix lines
```

---

## 7. Release Gate Checklist

All three required configs must pass before a release tag is created. QA lead signs off after all rows show exit code 0 with hard gates passing.

| Config | Run date | Operator | Harness exit code | Hard gates | Result | Notes |
|--------|----------|----------|-------------------|------------|--------|-------|
| A | | | | T1-01 | | |
| D | | | | T1-01, T2-03 | | |
| F | | | | T1-01, T3-04 | | |

**Sign-off:** _________________________ Date: _____________

Commit this file (with the sign-off table filled in) to the repo before creating the release tag.

---

## 8. Developer Regression Rules

| Code area changed | Minimum required |
|---|---|
| Any plugin code change | Tier 1 full (Config A) |
| Multipath or ALUA code paths | Tier 1 + Tier 2 (Config D) |
| Cluster or migration code paths | Tier 1 + Tier 3 (Config F) |
| Installer only | T1-01 (TLS audit) + installer health check |
| Documentation only | No test run required |

Quick alias for developer Config A run:
```bash
tools/run-tests.sh --storage <name> --config A --tier 1 --yes
```
