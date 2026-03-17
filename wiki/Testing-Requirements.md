# TrueNAS Proxmox Plugin — Testing Requirements and Risk Assessment

**Document purpose**: Defines test cases, acceptance criteria, and risk areas for the TrueNAS Proxmox VE Storage Plugin. Intended for use by QA, support engineers validating customer deployments, and engineering teams evaluating changes.

**Plugin version**: 2.0.x
**Last updated**: 2026-03-11

---

## Table of Contents

1. [Test Environment Configurations](#1-test-environment-configurations)
2. [Functional Test Cases](#2-functional-test-cases)
3. [Multipath and ALUA Testing](#3-multipath-and-alua-testing)
4. [NVMe/TCP Testing](#4-nvmetcp-testing)
5. [Cluster and Migration Testing](#5-cluster-and-migration-testing)
6. [Failure and Recovery Testing](#6-failure-and-recovery-testing)
7. [Performance Benchmarks](#7-performance-benchmarks)
8. [Risk Register](#8-risk-register)
9. [Known Limitations Reference](#9-known-limitations-reference)

---

## 1. Test Environment Configurations

Testing must cover all matrix combinations that are likely to appear in customer deployments. At minimum, the following configurations need a passing test run before each plugin release.

### Required Configurations

| ID | Transport | Multipath | Nodes | Proxmox | TrueNAS | Notes |
|----|-----------|-----------|-------|---------|---------|-------|
| A | iSCSI | off | 1 | 8.x | 25.10+ | Simplest baseline |
| B | iSCSI | on (2 paths) | 1 | 8.x | 25.10+ | Core multipath case |
| C | iSCSI | on (2 paths) | 3 | 8.x | 25.10+ | Cluster + multipath |
| D | iSCSI | on (2 paths) | 3 | 9.x | 25.10+ | Current recommended |
| E | NVMe/TCP | kernel mpath | 1 | 9.x | 25.10+ | NVMe baseline |
| F | NVMe/TCP | kernel mpath | 3 | 9.x | 25.10+ | NVMe cluster |

### Hardware / Network Requirements

- For multipath configurations (B, C, D): two separate NICs on the Proxmox node connected to two separate iSCSI portals on TrueNAS (different IP addresses)
- For NVMe/TCP: kernel booted with `nvme_core.multipath=Y`
- Network isolation between storage paths for meaningful failover tests

---

## 2. Functional Test Cases

These are pass/fail tests for the core plugin operations. Run against each test configuration above.

### 2.1 Plugin Installation

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Syntax validation | `perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` | No errors |
| Service restart | `systemctl restart pvedaemon pveproxy` | Both services running after restart |
| Storage activation | `pvesm status` after adding storage entry | Storage shows as active |
| APT install | Install via `--apt-install` flag | Package installs, no file conflicts |
| Upgrade | Install over existing version | Old backups preserved, new version active |

### 2.2 Volume Lifecycle

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Create volume | Create a VM with a disk on TrueNAS storage | Zvol and iSCSI extent appear in TrueNAS; disk visible in VM |
| Delete volume (GUI) | Delete VM through Proxmox web UI | Zvol, extent, and target-extent mapping all removed from TrueNAS |
| Resize volume | Resize VM disk upward in Proxmox | Zvol size increased in TrueNAS; guest OS sees new size after rescan |
| Resize rejection | Attempt to shrink a disk | Operation rejected; disk size unchanged |
| 1000-volume stress | Create VMs until 1000+ disks exist in the dataset | No naming collision errors; all volumes accessible |

### 2.3 Snapshots

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Snapshot create | `qm snapshot <VMID> snap1` (VM running) | ZFS snapshot visible under zvol in TrueNAS |
| Live snapshot | `qm snapshot <VMID> live1 --vmstate 1` | Snapshot includes vmstate; VM continues running |
| Snapshot list | `qm listsnapshot <VMID>` | All snapshots listed correctly |
| Snapshot rollback | Stop VM, `qm rollback <VMID> snap1` | VM restores to pre-snapshot state |
| Snapshot delete | `qm delsnapshot <VMID> snap1` | ZFS snapshot removed from TrueNAS |
| Chained snapshots | Create 5 sequential snapshots, rollback to snap2 | Snaps 3–5 deleted; snap2 becomes current |

### 2.4 Cloning

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Full clone | Clone a VM through Proxmox UI | New VM gets distinct zvol; data matches source |
| Clone cleanup | Delete cloned VM | Cloned zvol fully removed |

Note: linked clones are not supported. All clones are full copies.

### 2.5 API Behavior

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| API key validation | Configure with invalid API key | Storage shows inactive; clear error in logs |
| API retry | Temporarily block TrueNAS port 443, unblock after 5s, trigger operation | Plugin retries and succeeds after connectivity restores |
| Rate limit handling | Perform rapid sequential operations | No unhandled errors; plugin backs off and retries |
| Debug logging | Set `debug 1`, perform a volume create | Operation details logged to journald |

---

## 3. Multipath and ALUA Testing

This section documents the highest-risk area of the plugin. Read the background before running tests.

### Background

The plugin does not configure `multipath.conf`. It assumes that the customer has installed and configured `multipath-tools` independently, and that the dm-multipath daemon has already created `/dev/mapper/mpathX` devices for the iSCSI paths.

The plugin's multipath behavior:
1. On volume access: resolves a `by-path` symlink to the underlying `/dev/sdX` device, then walks `/sys/block` to find if that device is a slave of a dm-multipath map, and returns `/dev/mapper/<name>` if so.
2. Falls back silently to the `by-path` device if no dm map is found.
3. Calls `multipath -r` after iSCSI session rescans.
4. Calls `multipath -f <wwid>` (best-effort) when deleting a volume.

**Silent fallback risk**: If multipath is configured but the dm map hasn't been created yet (e.g., WWID not in `/etc/multipath/wwids`, or `find_multipaths strict` mode), the plugin falls back to a single-path device without warning. The VM runs on one path and the customer believes multipath is active.

**ALUA**: TrueNAS's iSCSI target stack (CTL) operates in **Active/Passive ALUA** mode (confirmed with Engineering). Each LUN has one Active Optimized path (through the preferred portal) and one or more Active Non-Optimized paths (through secondary portals). If dm-multipath is not configured with `hardware_handler "1 alua"` and `prio "alua"`, multipathd will distribute I/O across all paths equally — including non-optimized paths — resulting in degraded performance and incorrect failover behavior. The ALUA handler configuration is **required**, not optional, for any multipath iSCSI deployment against TrueNAS.

### 3.1 Multipath Device Resolution

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Multipath map created | After volume allocation with `use_multipath 1`, check `multipath -ll` | LUN appears as `/dev/mapper/mpathX` with both paths active |
| Plugin returns mapper device | `pvesm path <volid>` or check device Proxmox assigns to VM | Device path is `/dev/mapper/mpathX`, not `/dev/sdX` or by-path |
| By-path fallback test | Configure multipath with a WWID not in `/etc/multipath/wwids`, allocate volume | Plugin falls back to by-path (expected) — **verify this fallback is logged at debug level** |
| `use_by_path` mode | Set `use_by_path 1`, allocate volume | Device path is a `/dev/disk/by-path/` entry rather than mapper |

### 3.2 ALUA Configuration Test

TrueNAS CTL uses **Active/Passive ALUA**. Each LUN has one Active Optimized path (through the preferred portal) and Active Non-Optimized paths through secondary portals. The correct multipath.conf configuration is **not optional** — without the ALUA hardware handler, multipathd will route I/O over non-optimized paths, causing performance degradation and unreliable failover.

**Required `/etc/multipath.conf` for TrueNAS targets:**

```
devices {
    device {
        vendor "TrueNAS"
        product "iSCSI Disk"
        path_grouping_policy    group_by_prio
        hardware_handler        "1 alua"
        prio                    alua
        path_checker            tur
        failback                immediate
        no_path_retry           queue
        fast_io_fail_tmo        10
        dev_loss_tmo            30
    }
}
```

**Verify ALUA is working correctly after configuration:**

```bash
multipath -ll
# Correct output shows paths with differing priorities in separate groups:
# mpath0 (3600...) dm-3 TrueNAS,iSCSI Disk
# size=100G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
# |-+- policy='service-time 0' prio=50 status=active    <- Active Optimized
# |  `- sdb  active ready  prio=50
# `-+- policy='service-time 0' prio=10 status=enabled   <- Active Non-Optimized
#    `- sdc  active ready  prio=10
```

If `hwhandler='0'` appears in the output, the ALUA handler is not active — the configuration is incorrect.

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| ALUA handler active | `multipath -ll` after configuring devices block | Output shows `hwhandler='1 alua'`; paths in separate priority groups |
| Optimized path preference | Run I/O on a running VM; check which path carries traffic | I/O flows through the prio=50 (Active Optimized) path group |
| Non-optimized path I/O | Temporarily block the optimized portal; verify I/O continues | I/O continues on non-optimized path without VM error; performance degraded (expected) |
| Failback to optimized path | Re-enable the optimized portal | multipathd reinstates Active Optimized group as primary within `failback immediate` time |
| Without ALUA handler (regression) | Configure `path_grouping_policy multibus` (no ALUA handler), run I/O with two portals | I/O completes but non-optimized paths carry equal traffic — document observed latency difference vs. ALUA-configured case |

### 3.3 `find_multipaths strict` Mode (Default on Modern Systems)

Modern `multipath-tools` defaults to `find_multipaths "strict"`, which means multipath will not create a dm map for a device unless its WWID is explicitly listed in `/etc/multipath/wwids`. This is a common source of silent fallback.

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Fresh system | Install `multipath-tools`, do not add any WWIDs, connect two iSCSI paths, allocate volume | Confirm whether plugin falls back to single path — document observed behavior |
| After WWID registration | Run `multipath -a <wwid>` for each LUN WWID, then allocate volume | dm map created; plugin returns `/dev/mapper/mpathX` |
| Autodetect | Test with `find_multipaths "yes"` (less strict) — multipath creates maps for any device with multiple paths | dm maps created without explicit WWID registration |

**Installer recommendation**: If the installer wizard enables multipath, it should advise customers to add WWIDs or set `find_multipaths "yes"`, and it should not assume multipath is working simply because `use_multipath 1` is set.

### 3.4 Per-Node Multipath Configuration

Proxmox does not replicate multipath configuration across cluster nodes. Files that must be identical on every node:
- `/etc/multipath.conf`
- `/etc/multipath/wwids`
- `/etc/iscsi/iscsid.conf` (particularly `replacement_timeout`)

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Node consistency | After cluster setup, diff multipath configs across all nodes | All nodes have identical configs |
| VM migration | Migrate a running VM to a second node that has multipath configured | VM migrates; block device on destination is `/dev/mapper/mpathX` |
| Migration without multipath on dest | Migrate VM to a node where `multipath-tools` is not installed or multipath map is absent | Migration fails OR completes with VM using single-path device (document which, raise as risk) |

---

## 4. NVMe/TCP Testing

NVMe/TCP support is entirely managed by the plugin. Proxmox has no native NVMe/TCP storage plugin and no official documentation on NVMe/TCP multipath. This makes this transport mode higher-risk from a supportability standpoint.

### 4.1 Prerequisites Validation

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| nvme-cli installed | `nvme version` | Returns version string |
| Kernel multipath enabled | `cat /sys/module/nvme_core/parameters/multipath` | Returns `Y` |
| Host NQN | `cat /etc/nvme/hostnqn` | Returns a valid NQN string |
| Subsystem connectivity | `nvme discover -t tcp -a <portal-ip> -s 4420` | Returns subsystem info |

### 4.2 Volume Lifecycle (NVMe/TCP)

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Volume create | Create VM disk on NVMe/TCP storage | Namespace appears in TrueNAS NVMe-oF UI; `nvme list` shows device on Proxmox node |
| Device identification | Confirm correct namespace is returned | Plugin returns device matched by NGUID (primary) or NSID (fallback); no incorrect device returned |
| Volume delete | Delete VM disk | Namespace removed from TrueNAS |
| Resize | Resize VM disk | `nvme list` shows updated size on Proxmox node; no reconnect needed |

### 4.3 NVMe Native Multipath

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Multiple paths | Configure two NVMe/TCP portals; `nvme list-subsys` | Subsystem shows two paths |
| Path display | `nvme list-subsys` | Paths show as `live optimized` or `live non-optimized` — no `dead` paths |
| I/O distribution | Run fio while monitoring path usage | Both paths show traffic |
| Path failure | Disconnect one NVMe/TCP portal; observe I/O | I/O continues on remaining path within kernel failover time |
| Path restore | Reconnect portal | Both paths show as live in `nvme list-subsys` |

### 4.4 DH-HMAC-CHAP Authentication

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Host-only auth | Configure `nvme_dhchap_secret`, leave `nvme_dhchap_ctrl_secret` unset | Connection established; auth verified in TrueNAS logs |
| Bidirectional auth | Configure both secrets | Connection established with mutual authentication |
| Invalid secret | Configure a malformed secret | Connection rejected; clear error in plugin logs, not a silent failure |

---

## 5. Cluster and Migration Testing

### 5.1 Storage Sharing

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Shared flag | Set `shared 1`; check all cluster nodes | `pvesm status` on each node shows storage active |
| Volume visibility | Create a volume on node A, list storage on node B | Volume appears in `pvesm list` on node B |
| Concurrent access | Start VMs with disks on the same TrueNAS storage from two different nodes simultaneously | Both VMs run without I/O errors |

### 5.2 Live Migration

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Online migration | `qm migrate <VMID> <node> --online` | VM migrates without perceptible downtime; storage reconnects on destination |
| iSCSI session state after migration | Check `iscsiadm -m session` on source and destination | Source may disconnect, destination has active sessions |
| NVMe migration | Same as above for NVMe/TCP transport | `nvme list-subsys` on destination shows connected namespaces |
| Multipath state after migration | Check `multipath -ll` on destination after migration | All paths present and active on destination |

### 5.3 Cluster Lock Timeout

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Default timeout | Create two VMs simultaneously on the same storage from two cluster nodes | Both succeed without lock timeout errors |
| Lock contention | Simulate heavy concurrent volume creation; observe `storage_lock_timeout` | Operations queue and complete; no data corruption |

---

## 6. Failure and Recovery Testing

### 6.1 Network Failure Scenarios

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| API network loss | Block port 443 to TrueNAS for 10s during a volume create | Plugin retries (up to `api_retry_max`); succeeds if connectivity restores within retry window |
| Storage network loss (iSCSI) | Block port 3260 briefly; restore | dm-multipath queues I/O (`no_path_retry queue`); I/O resumes without VM crash |
| Storage network loss (NVMe/TCP) | Block port 4420 briefly; restore | Kernel NVMe multipath handles failover; I/O resumes |
| Complete TrueNAS outage during I/O | Shut TrueNAS down while VM is running I/O | I/O queues; VM eventually reports disk error if outage exceeds timeout. Confirm VM does not panic. |

### 6.2 Orphan Detection and Cleanup

**Context**: If a VM is deleted via `qm destroy` (CLI) rather than the Proxmox web UI, TrueNAS resources are not cleaned up. This is a known limitation of the Proxmox plugin API.

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Create orphans | Delete a VM with `qm destroy <VMID>` | Orphaned zvols and extents confirmed present in TrueNAS |
| Health check detection | Run installer health check | Orphaned resources listed in report |
| Manual cleanup | Follow cleanup instructions | Resources removed from TrueNAS |
| Verify no storage leak | Check dataset storage consumption before and after | Usage returns to expected level |

### 6.3 TLS Certificate Scenarios

| Test | Procedure | Pass Criteria |
|------|-----------|---------------|
| Valid certificate | Default `api_insecure 0` | Connection succeeds |
| Self-signed cert | Default `api_insecure 0` without custom CA | Connection fails with clear TLS error |
| Self-signed cert | Set `api_insecure 1` | Connection succeeds with warning in logs |
| Expired certificate | Connect to TrueNAS with expired cert | Connection fails clearly; not a silent hang |

---

## 7. Performance Benchmarks

These are not pass/fail tests but baselines that should be established and tracked across plugin versions.

### 7.1 Known Read Performance Constraint

**Important**: TrueNAS 25.10 sets `MaxOutstandingR2T=1` on iSCSI targets. This limits each iSCSI session to one in-flight read request at a time. On multipath with two 1GbE paths, this means sequential read performance will be below the theoretical aggregate bandwidth. This is a TrueNAS platform behavior, not a plugin bug, and the parameter is not user-configurable (target config files are auto-generated and overwritten).

Expected behavior:
- Single-threaded sequential reads: ~50–100 MB/s per path (limited by R2T serialization)
- Parallel reads (multiple VMs or `fio --numjobs=4`): approaches aggregate bandwidth
- Sequential writes: full aggregate bandwidth (unaffected by R2T)

Document the observed values in the test environment rather than asserting expected numbers.

### 7.2 Benchmark Cases

| Test | Tool | Metric |
|------|------|--------|
| Sequential write | `fio --rw=write --bs=1M --iodepth=32 --numjobs=1` | MB/s |
| Sequential read (single-threaded) | `fio --rw=read --bs=1M --iodepth=32 --numjobs=1` | MB/s |
| Sequential read (parallel) | `fio --rw=read --bs=1M --iodepth=32 --numjobs=4` | MB/s |
| Random 4K read | `fio --rw=randread --bs=4k --iodepth=32 --numjobs=4` | IOPS |
| Random 4K write | `fio --rw=randwrite --bs=4k --iodepth=32 --numjobs=4` | IOPS |

Run for both iSCSI and NVMe/TCP, and for single-path vs. multipath.

---

## 8. Risk Register

Risks are ranked by likelihood × impact.

### CRITICAL

#### R1 — Silent Single-Path Fallback

**Description**: When `use_multipath 1` is set but dm-multipath has not created a map for the LUN (e.g., WWID not registered, `find_multipaths strict` prevents auto-creation), the plugin silently falls back to a single by-path device. The customer believes multipath is active but the VM is running on one path.

**Trigger conditions**: Default modern `multipath-tools` installation without explicit WWID registration; or multipath-tools not running.

**Impact**: Loss of path redundancy. If that path fails, the VM loses storage access.

**Detection**: `pvesm path <volid>` returns a by-path device instead of `/dev/mapper/...`. Or `multipath -ll` shows no maps for the LUN.

**Mitigation needed**:
- The plugin should log a warning when `use_multipath 1` but the resolved device is not a dm map.
- The installer health check should verify that volumes are actually accessible via dm maps, not just that `multipath-tools` is installed.

---

#### R2 — ALUA Misconfiguration with TrueNAS CTL

**Description**: TrueNAS CTL operates in Active/Passive ALUA mode (confirmed). Each LUN has one Active Optimized path and one or more Active Non-Optimized paths across the configured portals. If dm-multipath is not configured with `hardware_handler "1 alua"` and `prio "alua"`, multipathd uses all paths equally, routing I/O through non-optimized paths at equal weight. On failover, the ALUA state transition is not signaled to the target correctly, risking I/O errors during path recovery.

**Trigger conditions**: Any iSCSI multipath deployment against TrueNAS. This affects all customers using `use_multipath 1` who do not have the ALUA devices block in `/etc/multipath.conf`.

**Impact**: I/O performance degradation (non-optimized paths carry production traffic); unreliable failover behavior as ALUA path state transitions are unhandled.

**Detection**: `multipath -ll` — look for `hwhandler='0'` (no ALUA handler) or all paths in a single group with equal prio values. Correct configuration shows `hwhandler='1 alua'` and paths in separate priority groups.

**Installer gap** (confirmed by code review): The installer wizard actively guides customers through enabling multipath — it sets `use_multipath 1` in `storage.cfg` and configures the `portals` list — but it writes nothing to `/etc/multipath.conf`. It does not add the ALUA devices block, does not register WWIDs, and does not set `replacement_timeout`. The health check considers multipath "OK" if `multipath -ll` returns any `dm-` device, without checking whether `hwhandler='1 alua'` is active. Every customer who enables multipath through the installer is therefore left with ALUA unconfigured by default.

**Mitigation**:
- The installer must be updated to either: (a) write the TrueNAS ALUA `devices` block into `/etc/multipath.conf` when the user enables multipath, or (b) display a blocking warning with the required configuration before proceeding, making it impossible to miss.
- The installer health check must be updated to verify `hwhandler='1 alua'` is present in `multipath -ll` output, not just that dm devices exist.
- Until the installer is fixed, support staff must treat any customer using `use_multipath 1` as having ALUA unconfigured unless they can show `multipath -ll` output with `hwhandler='1 alua'`.
- Any customer reporting multipath I/O issues or degraded performance should have their `multipath -ll` output reviewed for ALUA handler status as the first diagnostic step.

---

### HIGH

#### R3 — `qm destroy` Leaves Orphaned TrueNAS Resources

**Description**: Deleting VMs via the Proxmox CLI (`qm destroy`) does not trigger plugin cleanup methods. Zvols, iSCSI extents, and target-extent mappings are left on TrueNAS.

**Impact**: Storage space consumed; iSCSI LUN slot table fills up over time; customers report "disk still exists" confusion.

**Mitigation**: This is a known Proxmox API limitation, not a plugin bug. Document it prominently in support playbooks. The installer health check detects orphans.

---

#### R4 — Cluster Node Multipath Config Inconsistency

**Description**: Proxmox does not replicate `/etc/multipath.conf`, `/etc/multipath/wwids`, or `/etc/iscsi/iscsid.conf` between cluster nodes. If these are inconsistent, a VM migrated to another node may lose multipath redundancy silently.

**Impact**: Post-migration VMs run on single-path storage without the customer knowing.

**Mitigation**: The installer must document and check that all cluster nodes have identical multipath configurations. A cluster-wide config audit tool would reduce risk.

---

#### R5 — NVMe/TCP NGUID/NSID Mismatch

**Description**: The plugin uses NGUID as the primary identifier for NVMe namespace → block device matching, with NSID as fallback. If TrueNAS changes a namespace's NSID (which can happen during target reconfiguration), the fallback may resolve to the wrong device.

**Impact**: VM disk attached to wrong block device, causing data corruption.

**Mitigation**: NVMe namespaces should be stable. Investigate whether any TrueNAS operations (target restart, plugin update) cause NSID reassignment. If so, verify plugin's NGUID-primary matching is always successful and the NSID fallback is never triggered in normal operation.

---

#### R6 — iSCSI `replacement_timeout` Too Long

**Description**: The default `replacement_timeout` in `/etc/iscsi/iscsid.conf` is 120 seconds. If a path fails, the iSCSI initiator will wait up to 120 seconds before failing I/O. During this window, VMs appear frozen.

**Impact**: VMs pause for up to 2 minutes during path failures even when multipath could recover in seconds.

**Recommendation**: Set `replacement_timeout = 15` in `/etc/iscsi/iscsid.conf` on all cluster nodes, as recommended by the Proxmox multipath wiki. The installer should set this value automatically or prompt for it.

---

### MEDIUM

#### R7 — MaxOutstandingR2T=1 Read Performance

**Description**: TrueNAS 25.10 iSCSI targets enforce `MaxOutstandingR2T=1`, serializing read requests per session. The parameter is not user-configurable — the target config files are auto-generated and overwritten. This limits sequential read throughput per session regardless of multipath configuration.

**Impact**: Single-threaded sequential read benchmarks will underperform theoretical multipath bandwidth. Not a safety concern; a customer expectation issue.

**Mitigation**: Document the limitation explicitly. Advise 10GbE single-path over 2x 1GbE multipath for read-heavy workloads, or NVMe/TCP which does not have this constraint. Track TrueNAS releases for `MaxOutstandingR2T` becoming configurable.

---

#### R8 — Thin Provisioning Overcommit

**Description**: Thin provisioning (`tn_sparse 1`, the default) allows the sum of allocated zvol sizes to exceed the physical pool capacity. If the pool fills, zvol writes fail silently at the storage layer, causing filesystem corruption inside VMs.

**Impact**: Data corruption, VM crashes.

**Mitigation**: Customers should configure TrueNAS pool alerts for high capacity usage. Thick provisioning (`tn_sparse 0`) eliminates this risk at the cost of immediate space consumption.

---

#### R9 — NVMe/TCP No Proxmox Documentation

**Description**: Proxmox has no official documentation or storage plugin for NVMe/TCP. The plugin implements the full NVMe/TCP stack itself. There is no Proxmox reference implementation to compare against for correctness.

**Impact**: Edge cases in NVMe session management, multipath, and device mapping are harder to diagnose because there is no Proxmox baseline. Support escalations go to plugin engineering without a fallback to Proxmox support.

**Mitigation**: The NVMe/TCP code path needs the most test coverage precisely because there is no external reference.

---

#### R10 — API Connection Race Conditions Under Concurrent Operations

**Description**: The plugin uses persistent WebSocket connections for reads and ephemeral connections for writes. In a cluster with multiple nodes performing simultaneous operations (e.g., creating VMs on the same storage), API rate limiting and connection state could interact.

**Impact**: Transient failures during heavy concurrent use; retry logic should handle most cases, but edge cases may produce unexpected errors.

**Mitigation**: Stress test concurrent operations across cluster nodes (see functional test 2.2, "1000-volume stress").

---

### LOW

#### R11 — API Key in Plain Text

**Description**: The TrueNAS API key is stored in `/etc/pve/storage.cfg` which is a Proxmox cluster filesystem file, readable by all cluster nodes.

**Impact**: Any user with shell access to any cluster node can read the API key.

**Mitigation**: Proxmox manages file permissions. Advise customers to use a dedicated TrueNAS API key scoped to only the required dataset — not an admin-level key.

---

#### R12 — Perl WebSocket Implementation

**Description**: The plugin implements its own WebSocket client (RFC 6455 framing over IO::Socket::SSL) rather than using a standard library. Custom protocol implementations can have subtle bugs.

**Impact**: WebSocket framing bugs could cause protocol errors under specific payload sizes or network conditions.

**Mitigation**: This implementation has been in use; low risk unless TrueNAS changes WebSocket server behavior.

---

## 9. Known Limitations Reference

These are documented behaviors that are not bugs but that support staff will encounter.

| Limitation | Customer Impact | Support Guidance |
|-----------|-----------------|------------------|
| TrueNAS 25.10+ required | Older TrueNAS cannot be used | Upgrade TrueNAS before attempting to use plugin |
| VM images only | Cannot store ISOs, backups, or CT templates on this storage | Use a separate storage for those content types |
| No Proxmox Backup Server integration | PBS cannot back up to this storage; plugin snapshots are not PBS backups | Configure PBS with a separate NFS/local storage target |
| No volume shrinking | VM disks can only grow | Plan disk sizes carefully; use separate zvols for flexible resizing needs |
| No linked clones | VM cloning copies all data | Clone time proportional to disk size; expect slow clones for large disks |
| GUI deletion required | `qm destroy` leaves TrueNAS orphans | Always delete VMs through Proxmox web UI |
| iSCSI mutual CHAP not supported | Only one-way CHAP auth | Use NVMe DH-HMAC-CHAP for bidirectional auth if required |
| `MaxOutstandingR2T=1` | Sequential reads limited per iSCSI session | Expected; not configurable on TrueNAS side currently |
| Cluster multipath configs not replicated | Manual per-node configuration required | Provide customers with a configuration script or Ansible playbook |
