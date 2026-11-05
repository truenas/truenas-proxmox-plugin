# Known Limitations

Important limitations, restrictions, and workarounds for the TrueNAS Proxmox VE Storage Plugin.

## Table of Contents

- [Critical Workflow Limitations](#critical-workflow-limitations)
  - [VM deletion (`qm destroy`)](#vm-deletion-qm-destroy)
- [Storage Feature Limitations](#storage-feature-limitations)
  - [Where the plugin's `clone_image()` is invoked](#where-the-plugins-clone_image-is-invoked)
  - [No Volume Shrinking](#no-volume-shrinking)
  - [Resize Headroom Limit](#resize-headroom-limit)
- [Content Type Limitations](#content-type-limitations)
  - [Supported content types](#supported-content-types)
  - [Not supported (and probably shouldn't be, in this plugin)](#not-supported-and-probably-shouldnt-be-in-this-plugin)
- [Snapshot Limitations](#snapshot-limitations)
  - [vzdump captures live state, not snapshot history](#vzdump-captures-live-state-not-snapshot-history)
- [Live Migration Limitations](#live-migration-limitations)
  - [Requires Shared Storage](#requires-shared-storage)
  - [vmstate Storage Considerations](#vmstate-storage-considerations)
- [TrueNAS Specific Limitations](#truenas-specific-limitations)
  - [nvmet-tcp missing .get_mdts → large-transfer I/O errors](#nvmet-tcp-missing-get_mdts--large-transfer-io-errors)
  - [TrueNAS HA + NVMe/TCP needs tn_nvme_manage_ports 0](#truenas-ha--nvmetcp-needs-tn_nvme_manage_ports-0)
  - [API Rate Limits](#api-rate-limits)
  - [WebSocket Connection Stability](#websocket-connection-stability)
- [Proxmox Specific Limitations](#proxmox-specific-limitations)
  - [Proxmox Version Requirements](#proxmox-version-requirements)
  - [Custom Storage Plugin Directory](#custom-storage-plugin-directory)
- [Network Limitations](#network-limitations)
  - [No NFS/CIFS Support](#no-nfscifs-support)
  - [IPv6 Considerations](#ipv6-considerations)
- [Security Limitations](#security-limitations)
  - [No Mutual CHAP (iSCSI)](#no-mutual-chap-iscsi)
  - [API Key Storage](#api-key-storage)
  - [No SCSI persistent reservations for HA fencing](#no-scsi-persistent-reservations-for-ha-fencing)
  - [`rename_volume` not implemented](#rename_volume-not-implemented)
- [Performance Limitations](#performance-limitations)
  - [Clone Performance](#clone-performance)
  - [Snapshot Overhead](#snapshot-overhead)
  - [Network-Bound Performance](#network-bound-performance)
  - [Multipath Read Performance Limitation](#multipath-read-performance-limitation)
- [Platform Limitations](#platform-limitations)
  - [Linux/Proxmox Only](#linuxproxmox-only)
  - [ZFS Dependency](#zfs-dependency)
- [Operational Limitations](#operational-limitations)
  - [No Bulk Deletion](#no-bulk-deletion)
  - [Configuration Changes Require Restart](#configuration-changes-require-restart)
  - [No Storage Overcommit Protection](#no-storage-overcommit-protection)
- [Workarounds Summary](#workarounds-summary)

---

## Critical Workflow Limitations

### VM deletion (`qm destroy`)

**Works correctly.** `qm destroy VMID --purge` cleans the Proxmox-side
config *and* calls the plugin's `free_image()` for every disk the VM
owned, which removes the zvol, the iSCSI extent, and the target-extent
mapping on TrueNAS. The same path runs when you delete the VM from
the web UI — both go through `PVE::QemuServer::destroy_vm` →
`foreach_volume_full` → `path()` → `remove_owned_drive` → `free_image()`.

Earlier plugin releases (pre-2.1.23~beta8) had a bug where `path()`
could hang 60 seconds and abort the destroy loop before `free_image`
ran, leaking state when the destroy ran on a node that had never
activated the disk locally (cross-node destroy of an orphan, destroy
after a leaked config-migrate, destroy on a node with the iSCSI
session down). That is tracked as #88 and is fixed in beta8:
`path()` now returns a deterministic by-path string when the device
is not locally attached, so the destroy loop never hangs. If you are
running pre-beta8 and see orphan zvols on TrueNAS after
`qm destroy` on a node where the disk was never activated, upgrade
to beta8 or later.

## Storage Feature Limitations

### Where the plugin's `clone_image()` is invoked

The plugin exposes `clone_image()`, which performs an instant ZFS
clone on TrueNAS via `pool.snapshot.clone` — no data copy, metadata
only. PVE invokes it for **linked clones from a template**:

1. `qm template VMID` runs the plugin's `create_base`, which
   renames the source zvol to `base-VMID-disk-N` and takes an
   immutable `@__base__` snapshot.
2. `qm clone BASE_VMID NEW_VMID` (linked clone) calls the plugin's
   `clone_image()`, which clones the `@__base__` snapshot on
   TrueNAS.

Full clones (`qm clone --full`) and cross-storage disk moves
(`qm move_disk`) are routed by PVE through its own data-copy
mechanisms, not through our `clone_image()`. For cross-storage
*moves*, prefer `pvesm export | pvesm import` or
`qm migrate … --targetstorage`, which route through the plugin's
`volume_export`/`volume_import` methods (as of 2.1.23~beta8+).

### No Volume Shrinking

**Limitation**: Cannot reduce volume size, only grow

**Explanation**: ZFS does not support zvol shrinking

**Impact**:
- Can only use `qm resize VMID diskN +SIZE` (grow)
- Cannot use `qm resize VMID diskN SIZE` (set absolute size smaller)

**Workaround**:
```bash
# To "shrink" a disk:
# 1. Create new smaller volume
pvesm alloc truenas-storage 100 vm-100-disk-1 32G

# 2. Clone data from old disk to new disk (within VM or using rescue)
# 3. Detach old disk, attach new disk
qm set 100 --scsi1 truenas-storage:vm-100-disk-1

# 4. Delete old disk
pvesm free truenas-storage:vm-100-disk-0-lun1
```

### Resize Headroom Limit

**Limitation**: Can only resize volumes up to 80% of available dataset space

**Explanation**: Pre-flight checks enforce 20% safety margin for ZFS overhead

**Example**:
```
Dataset has 100GB free
Maximum resize: 80GB
Safety margin: 20GB (for ZFS metadata, snapshots, etc.)
```

**Impact**:
- Cannot resize volume to consume all available space
- Prevents pool exhaustion

**Workaround**:
```bash
# If you need more space:
# 1. Add storage to ZFS pool
# 2. Or free up space by deleting snapshots/volumes
# 3. Or use different dataset with more space
```

## Content Type Limitations

### Supported content types

The plugin ships block storage over iSCSI or NVMe/TCP. Two PVE
content types are supported:

- **`images`** — VM virtual disks (default; always available).
- **`rootdir`** — LXC container root volumes (opt-in; add `rootdir`
  to the storage's `content` field in `storage.cfg`). The plugin
  allocates a zvol per container, formats it ext4, mounts it on the
  node under `/mnt/<storage>/pct-<vmid>-rootdir/` during
  `activate_volume`, and tears the mount down in `deactivate_volume`.
  Tested end-to-end by the Proxmox storage-plugin-validation suite:
  container create, start, backup to PBS, restore round-trip.

### Not supported (and probably shouldn't be, in this plugin)

- **`iso`** (ISO images), **`vztmpl`** (LXC templates), **`snippets`**
  (cloud-init hook scripts and user-data).
- **`backup`** (vzdump archives).
- **`import`** (OVF/VMA staging).

**Why not here**: all of these are file-level content, not block.
PVE has first-class storage types (NFS, dir, CephFS, PBS) that are
better fits — point one of those at a TrueNAS NFS share, PBS
datastore, or local directory. Running these through this plugin
would mean growing a parallel NFS-mount code path next to the
iSCSI/NVMe one.

**Workaround — split by content type in `storage.cfg`:**

```ini
truenasplugin: truenas-storage
    # ... VM disks and LXC root volumes ...
    content images,rootdir

nfs: truenas-iso
    server 192.168.1.100
    export /mnt/tank/pve-iso
    content iso,vztmpl,snippets

pbs: pbs
    server 192.168.0.145
    datastore main
    content backup
    # ... fingerprint/username/password elsewhere ...
```

## Snapshot Limitations

### vzdump captures live state, not snapshot history

`vzdump` (and PBS backup) always captures the **current** VM disk
state. The ZFS snapshot history on TrueNAS is separate — it stays on
TrueNAS, not in the backup archive. This is standard PVE behavior,
same as any other block-based storage plugin.

**What this means in practice:**

- `vzdump → PBS` and `vzdump → local directory` both work end-to-end
  for VMs with disks on this plugin, in both `--mode stop` and
  `--mode snapshot`. For running VMs in snapshot mode, the plugin's
  `volume_snapshot` is called to create an ephemeral ZFS snapshot and
  `_expose_snapshot_device` publishes a clone-of-snapshot as a device
  the backup can read, then both are torn down after. Verified on
  the storage-plugin-validation suite 2026-10 against both iSCSI and
  NVMe/TCP, into PBS.
- Restoring a backup produces a VM with the **disk contents as of
  backup time**. It does NOT recreate the chain of ZFS snapshots that
  existed on TrueNAS at backup time.

**If you want snapshot history preserved offsite:**

- Set up TrueNAS-side snapshot schedules on `tank/proxmox` (or
  whatever dataset the plugin manages). TrueNAS keeps the full
  snapshot chain under its retention rules.
- Add a TrueNAS replication task to replicate `tank/proxmox` to
  another TrueNAS. ZFS send/recv preserves the full snapshot chain.
- Keep PBS as your Proxmox-side VM backup (fast dedup, cross-storage
  restore). It will keep its own history of backup snapshots.

The two mechanisms are complementary, not substitutes. Use PBS for
"restore the VM", TN replication for "preserve the ZFS snapshot
chain for forensics or long-term rollback".

## Live Migration Limitations

### Requires Shared Storage

**Limitation**: Live migration requires `shared 1` configuration

**Configuration**:
```ini
# Required for live migration
shared 1
```

**Impact**:
- Cannot live migrate VMs between nodes if `shared 0`
- Offline migration still works (VM stopped during migration)

### vmstate Storage Considerations

**Limitation**: Live migration with existing snapshots requires vmstate to be reachable from the target node.

**Explanation**:
- If VM has snapshots with vmstate on local storage
- Live migration fails (vmstate not accessible from target node)

> ⚠️ `tn_vmstate_storage` is not currently implemented by this plugin (see [Configuration Reference](Configuration.md#tn_vmstate_storage)) — vmstate placement is controlled entirely by Proxmox core, not by this setting.

**Workaround**:
```ini
# Use shared storage for vmstate in environments requiring migration
# (configure via Proxmox's own vmstate storage selection, not this plugin)

# Or delete snapshots before migration
# Or use offline migration (stop VM, migrate, start)
```

## TrueNAS Specific Limitations

### `nvmet-tcp` missing `.get_mdts` → large-transfer I/O errors

**Tracking:** GitHub #45 (original report, 2026-06), GitHub #96
(current tracking issue with upstream analysis).

**Affected:** NVMe/TCP on TrueNAS 25.10.4, 25.10.7 and 27.0.0 RC1;
iSCSI on 25.10.6. Not every release in a series is confirmed; those
are the versions reported in #96. The iSCSI case comes from a
different mechanism (see below), and the 25.10.5/25.10.6 release
notes contain no NVMe target data-path fix.

**Symptom (NVMe/TCP):** vzdump streaming backups, `qemu-img convert -t none`
disk moves, `pvesm export | pvesm import` transfers, and any other
large direct-I/O workload against an NVMe/TCP namespace can fail
with `err -5 - Input/output error` partway through. On the Proxmox
node:

```
nvme0c0n2: I/O Cmd(0x2) @ LBA ..., 32768 blocks, I/O Error (sct 0x0 / sc 0x6)
```

Matching entries on TrueNAS:

```
nvmet_tcp: queue N: failed to map data
nvmet_tcp_map_data+... [nvmet_tcp]
nvmet_tcp_try_recv_pdu+... [nvmet_tcp]
nvmet_tcp_io_work+... [nvmet_tcp]
```

Oversized requests from the client have, in some reports, also led
to silent corruption on offline (stopped-VM) disk moves — see #96
and #32 for examples.

**Root cause (NVMe/TCP):** The `nvmet-tcp` kernel module does not implement
the `.get_mdts` (Maximum Data Transfer Size) callback, so the target
advertises an unlimited transfer size. Linux's nvme block layer
chooses a default `max_sectors_kb` of 32768 (16 MB per request).
When a request arrives, `nvmet_tcp_map_data()` cannot allocate the
scatter-gather map and returns Internal Error (sct 0x0 / sc 0x6).

**Root cause (iSCSI):** the target advertises an 8 MiB maximum and
optimal transfer length, so the SCSI block layer sets
`max_sectors_kb=8192` and `read_ahead_kb=16384` and issues 8 MiB
requests. SCST then fails to allocate the request buffer on TrueNAS:

```
scst: Allocation of sgv_pool_obj failed (size 8388608)
scst: Unable to allocate or build requested buffer (size 8388608), sending BUSY or QUEUE FULL status
```

On the initiator the command is requeued until the SCSI layer gives
up after 180 s, then reported as an I/O error:

```
sd 1:0:0:18: [sds] tag#80 timing out command, waited 180s
I/O error, dev sds, sector 64421888 op 0x0:(READ) flags 0x0 phys_seg 2048 prio class 2
```

Failed reads are readahead requests. `scst_max_cmd_mem` and
`scst_max_dev_cmd_mem` were not the limit in the reported case; the
allocation is believed to fail on memory fragmentation (unconfirmed,
see #96).

**Status:** Kernel patch exists upstream and has received Reviewed-by
from the NVMe maintainer. Not yet in a released TrueNAS point
version at the time of writing. For the iSCSI case no target-side fix
is reported in #96; until TrueNAS either stops advertising 8 MiB or
stops failing the buffer allocation, the initiator-side cap is the
mitigation.

**Workaround for NVMe/TCP:** cap `max_sectors_kb` on every PVE node.

```bash
cat > /etc/udev/rules.d/60-nvme-tcp-max-sectors.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n*", ENV{DEVTYPE}=="disk", \
  ATTRS{subsysnqn}=="nqn.*truenas*", ATTR{queue/max_sectors_kb}="1024"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=block --action=change
```

Four clauses, each necessary:

- `KERNEL=="nvme*n*"` — any NVMe block device.
- `ENV{DEVTYPE}=="disk"` — namespace head only; without this, udev
  tries to write `max_sectors_kb` on every partition (`nvme6n2p1`
  etc.) during guest-disk partition-table scans and logs an error
  per partition in `journalctl -p err`.
- `ATTRS{subsysnqn}=="nqn.*truenas*"` — scopes the cap to TrueNAS
  subsystems only; local NVMe SSDs behind `local-lvm` or `local-zfs`
  keep their native (large) MDTS. Adjust the glob if your subsystem
  NQNs don't contain "truenas".
- `ATTR{queue/max_sectors_kb}="1024"` — 1024 KiB (2048 sectors) is
  the value validated against TN 25.10.4 in #96; it stays well under
  the mapping limit while leaving streaming workloads at
  near-line-rate. If you still see sporadic errors with 1024, drop to
  128 (used by the original #45 reporter).

**Trap:** `ATTRS{transport}=="tcp"` as a scope filter **does not
work** with native NVMe multipath. The `transport` attribute lives on
the per-path controllers (`nvme0c0n1`), not the namespace head
(`nvme0n1`) that carries the queue limits — the rule installs cleanly
and does nothing. Use `ATTRS{subsysnqn}` instead.

**Verify** the value actually changed:

```bash
cat /sys/block/<nvmeNnM>/queue/max_sectors_kb
```

A rule that doesn't match any device fails silently. Capping the
namespace head alone is enough; the bio layer splits before
forwarding to the paths, so per-path `max_sectors_kb` doesn't need to
be touched. The value survives a full disconnect/reconnect of the
subsystem.

**Workaround for iSCSI:** cap the same value on SCSI block devices.

```bash
cat > /etc/udev/rules.d/60-scsi-max-sectors.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", \
  ATTRS{vendor}=="TrueNAS*", ATTR{queue/max_sectors_kb}="1024", \
  ATTR{queue/read_ahead_kb}="1024"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=block --action=change
```

`KERNEL=="sd*[!0-9]"` matches whole SCSI disks only, so partitions
(`sds1`, `sds2`) are skipped. `ATTRS{vendor}=="TrueNAS*"` scopes the
rule to LUNs served by the TrueNAS target; check with
`cat /sys/block/sdX/device/vendor`. Both attributes are required:
`max_sectors_kb` caps the request size, and `read_ahead_kb` caps the
readahead cluster; failed reads in #96 were readahead requests, and
readahead alone can reach the 8 MiB limit while `max_sectors_kb`
stays low.

**Note:** a SCSI rescan resets `read_ahead_kb` to 16384 while
`max_sectors_kb` stays at 1024. Re-trigger the rule after a rescan:

```bash
udevadm trigger --subsystem-match=block --action=change
```

**Remove the rules** once the target stops advertising a transfer
size it cannot serve: `mdts 0` (i.e. 32 MiB requests) on NVMe/TCP,
8 MiB on iSCSI, or once the kernel fix lands in your TrueNAS
version.

### TrueNAS HA + NVMe/TCP needs `tn_nvme_manage_ports 0`

**Affected:** NVMe/TCP against a TrueNAS HA pair (dual controller)
on 25.10.x. iSCSI is not affected.

**Symptom:** the subsystem connects, but no namespaces appear as
block devices on the Proxmox host. `nvme list-subsys` shows the
controller as live; `nvme list` shows nothing from that subsystem.
On the TrueNAS side the middlewared log contains a stack ending in
`KeyError` out of `map_attrs()` whenever the plugin tries to create
an `nvmet.port` record.

**Root cause:** the `nvmet` middleware's `map_attrs()` validates
each `nvmet.port` record's `addr_traddr` against a hard-coded
`choices` dict. On HA, that dict contains only the pair's VIP, so a
record whose `addr_traddr` is a physical controller IP trips a
`KeyError` inside `write_config()`. The exception aborts the entire
configfs render, which includes every port AND every namespace in
the subsystem. By default this plugin creates one `nvmet.port` per
configured portal, and those portals naturally carry physical IPs —
exactly the pattern that triggers the KeyError. On a single-head
TrueNAS the dict accepts the controller IP and the default works.

**Workaround:** set `tn_nvme_manage_ports 0` on the HA pair's
storage stanza and pre-provision one VIP-based `nvmet.port` by
hand. With `manage_ports=0` the plugin skips every `nvmet.port.*`
mutation; the subsystem lookup, the namespace lifecycle, and the
initiator-side connect still work as before.

See
[Best-Practices.md#nvmetcp-ha-failover](Best-Practices.md#nvmetcp-ha-failover)
for the full setup, including the three `midclt` calls that
bootstrap the TrueNAS side.

**Status:** this is a TrueNAS middleware constraint, not a plugin
bug. The workaround stays as long as the HA `map_attrs()` dict
only accepts the VIP.

### API Rate Limits

**Limitation**: TrueNAS limits API requests to 20 calls per 60 seconds

**Impact**:
- Exceeding limit triggers 10-minute cooldown
- Bulk operations (creating many VMs) may hit limit

**Plugin Mitigation**:
- Automatic retry with exponential backoff
- Bulk operations batching (when `enable_bulk_operations=1`)
- Connection caching and reuse

**User Mitigation**:
```ini
# Increase retry tolerance
tn_api_retry_max 5
tn_api_retry_delay 2

# Enable bulk operations
tn_enable_bulk_operations 1
```

**Manual Recovery**:
```bash
# If rate limited, wait 10 minutes
# Check TrueNAS logs:
tail -f /var/log/middlewared.log | grep rate
```

### WebSocket Connection Stability

**Limitation**: WebSocket connections may be unstable in some network environments

**Symptoms**:
- Random connection drops
- "WebSocket closed unexpectedly" errors
- Increased latency

**Mitigation**:
- Ensure reliable network path (avoid flaky links, check MTU consistency)
- Use TLS (`api_scheme wss`) and valid certificates
- Increase retry settings: `tn_api_retry_max`, `tn_api_retry_delay`
- Verify firewall allows TCP 443 from all Proxmox nodes

## Proxmox Specific Limitations

### Proxmox Version Requirements

**Limitation**: Some features require specific Proxmox VE versions

**Feature Requirements**:
- **Basic functionality**: Proxmox VE 8.x+
- **Volume snapshot chains**: Proxmox VE 9.x+
- **Optimal storage plugin API**: Proxmox VE 8.2+

**Recommendation**: Use Proxmox VE 8.2 or later (or Proxmox VE 9.x for volume chains)

### Custom Storage Plugin Directory

**Limitation**: Plugin must be in `/usr/share/perl5/PVE/Storage/Custom/`

**Impact**:
- Updates to Proxmox may require plugin reinstallation
- Manual installation required (not in Proxmox repositories)

**Mitigation**:
```bash
# Keep plugin source in safe location
cp TrueNASPlugin.pm /root/truenas-plugin-backup/

# Use installer for easy cluster-wide reinstall
./install.sh  # Select "Install latest version (all cluster nodes)"
```

## Network Limitations

### No NFS/CIFS Support

**Limitation**: Plugin only supports iSCSI and NVMe/TCP block storage

**Not Supported**:
- NFS file shares
- SMB/CIFS file shares
- Direct ZFS dataset mounting

**Explanation**: Plugin architecture designed specifically for block storage (iSCSI and NVMe/TCP)

**Workaround**:
```bash
# Use separate TrueNAS NFS/SMB shares for file-based storage
# Example /etc/pve/storage.cfg:

# iSCSI for VM disks
truenasplugin: truenas-vms
    content images
    # ... config ...

# NFS for LXC/backups
nfs: truenas-files
    server 192.168.1.100
    export /mnt/tank/nfs-share
    content rootdir,vztmpl,backup
```

### IPv6 Considerations

**Limitation**: IPv6 requires specific configuration

**Required Settings**:
```ini
tn_prefer_ipv4 0
tn_ipv6_by_path 1  # not currently implemented, see Configuration.md#tn_ipv6_by_path
tn_use_by_path 1
```

**Portal Format**:
```ini
# Must use brackets for IPv6 addresses
tn_discovery_portal [2001:db8::100]:3260
tn_portals [2001:db8::101]:3260,[2001:db8::102]:3260
```

## Security Limitations

### No Mutual CHAP (iSCSI)

**Limitation**: Only one-way CHAP authentication supported for iSCSI transport

**Explanation**:
- iSCSI transport supports CHAP authentication (initiator → target)
- Mutual CHAP (target → initiator) not implemented for iSCSI

**Note**: NVMe/TCP transport supports full bidirectional DH-HMAC-CHAP authentication (host + controller secrets). See [NVMe Setup Guide](NVMe-Setup.md#dh-chap-authentication-setup) for details.

**Impact**: Slightly reduced security in high-security iSCSI environments

**Mitigation**:
- Use NVMe/TCP transport for bidirectional authentication
- Use network segmentation (VLANs)
- Firewall rules restricting iSCSI access
- Strong CHAP passwords

### API Key Storage

**Limitation**: API key stored in plaintext in `/etc/pve/storage.cfg`

**Impact**: Anyone with root access to Proxmox can read API key

**Mitigation**:
- Restrict TrueNAS API user permissions (least privilege)
- Use dedicated API user (not root)
- Monitor TrueNAS audit logs
- Rotate API keys regularly

**File Permissions**:
```bash
# /etc/pve/storage.cfg is readable by root only
ls -la /etc/pve/storage.cfg
# -rw-r----- 1 root www-data
```

### No SCSI persistent reservations for HA fencing

**Limitation**: The plugin does not acquire or release SCSI
persistent reservations on `activate_volume` / `deactivate_volume`.

**Explanation**: In a Proxmox HA cluster, when a node is fenced
out, the fenced node's iSCSI target-extent mapping stays as-is on
TrueNAS. HA will restart the VM on another node, which re-activates
the same LUN. If the fenced node ever comes back and re-enters the
cluster before TrueNAS has invalidated the stale initiator session,
both nodes briefly have the LUN visible — split-brain write risk,
bounded only by what the TrueNAS target enforces at the SCST layer
(which, without reservations configured, is nothing).

**Impact**: Serious HA deployments on top of this plugin do not get
plugin-level split-brain protection. The TN target itself does not
currently drive persistent reservations on behalf of the plugin.

**Mitigation**:
- Rely on PVE's own fencing (watchdog + corosync membership
  consensus) to ensure the fenced node is truly down before the
  surviving node takes over.
- Keep storage-network and corosync-network reliable; most "false
  fence" scenarios come from flaky corosync, not storage.
- A plugin that drives SCSI PR explicitly is on the roadmap but not
  shipped as of 2.1.23~beta8.

### `rename_volume` not implemented

**Limitation**: The plugin does not implement PVE's
`rename_volume()` method.

**Impact**: A few housekeeping paths in PVE core die with
`not implemented in storage plugin 'PVE::Storage::Custom::TrueNASPlugin'`:

- Changing a VM's VMID (`qm set --newid`-style flows).
- Some edge cases of PVE's volume-renaming utilities.

**Workaround**: These are uncommon operations. For VMID change,
clone → verify → destroy old is the stable workflow until
`rename_volume` lands. The implementation path exists on the
TrueNAS side (`zfs rename` + iSCSI extent `name` update); the
plugin just doesn't expose it yet.

## Performance Limitations

### Clone Performance

**Limitation**: A full clone copies data over the network; the plugin does not implement storage-side fast cloning for plain `clone_image` calls. Linked clones from a base image use `create_base` and `clone_image` and avoid the copy.

**Impact**: Large VM clones are slow

### Snapshot Overhead

**Limitation**: Many snapshots can impact performance

**Explanation**:
- Each snapshot creates metadata overhead
- Write performance degrades with many snapshots
- Space usage increases as data diverges from snapshots

**Recommendation**:
```bash
# Manage snapshot lifecycle
# Delete old snapshots regularly
# TrueNAS automated snapshot retention policy

# Example: Keep 7 daily snapshots
# In TrueNAS: Storage > Snapshots > Add
# Lifetime: 1 week
```

### Network-Bound Performance

**Limitation**: Performance limited by network speed and latency

**Impact**:
- VM disk I/O limited by network bandwidth
- Latency affects random I/O performance

**Mitigation**:
- Use 10GbE or faster network
- Jumbo frames (MTU 9000)
- Dedicated storage network
- Multiple paths (multipath I/O)

### Multipath Read Performance Limitation

**Limitation**: Multipath read performance is constrained by iSCSI protocol limitations in TrueNAS SCALE

**Explanation**:
- TrueNAS SCALE (as of version 25.04) sets `MaxOutstandingR2T=1` on iSCSI targets
- This limits each iSCSI session to **1 outstanding read request** at a time
- Even with multiple paths configured, read operations cannot fully utilize aggregate bandwidth
- Write operations are **not affected** (use immediate/unsolicited data transfer)

**Observed Behavior**:
```
Configuration: 2x 1GbE multipath (theoretical 250 MB/s aggregate)

Write Performance: ~100-110 MB/s ✅
- Both paths utilized simultaneously
- Full aggregate bandwidth achieved

Sequential Read Performance: ~50-100 MB/s ⚠️
- Paths alternate handling requests (round-robin)
- Limited by serialized read operations (one R2T per session)
- Both paths ARE being used, but not fully in parallel

Parallel Read Performance: ~100-110 MB/s ✅
- Multiple parallel I/O streams (e.g., fio with numjobs=4)
- Can achieve near-full aggregate bandwidth
```

**Technical Details**:
- `MaxOutstandingR2T=1` is an iSCSI protocol parameter
- Controls how many read requests can be in-flight simultaneously per session
- TrueNAS SCALE does not currently expose this parameter for configuration
- Configuration files (`/etc/ctl.conf`, `/etc/scst.conf`) are auto-generated and manual edits are overwritten
- This is a **known limitation** with an active feature request in the TrueNAS community

**Impact**:
- Single-threaded sequential reads (e.g., disk benchmarks like kdiskmark) show lower performance
- Real-world workloads with multiple VMs or parallel I/O see better performance
- Write-heavy workloads are not affected
- Random I/O workloads naturally create parallelism and perform better

**Workarounds**:

1. **Upgrade to 10GbE Network** (Recommended)
   - Single 10GbE path provides ~1000 MB/s
   - Bypasses R2T bottleneck entirely
   - Best long-term solution

2. **Accept Current Performance**
   - ~100 MB/s read is still reasonable for many workloads
   - Most real-world applications do parallel I/O
   - Multiple VMs naturally create parallel load

3. **Add More Network Paths**
   - 4x 1GbE = 4 concurrent read operations possible
   - Diminishing returns, but may help read-heavy workloads

4. **Optimize Workloads for Parallelism**
   - Applications that issue multiple concurrent reads perform better
   - Databases and random I/O workloads less affected
   - Avoid single-threaded sequential read benchmarks as sole metric

5. **Monitor TrueNAS Feature Requests**
   - Feature request exists for configurable iSCSI parameters
   - May be addressed in future TrueNAS SCALE releases
   - Check TrueNAS forums for updates

**Available Solution: NVMe/TCP**:
- Use NVMe over TCP (NVMe-oF) to eliminate this limitation
- NVMe protocol supports native parallelism and higher queue depths
- Fully supported in this plugin version (requires TrueNAS SCALE 25.10+)

**Note**: This is a TrueNAS SCALE platform limitation, not a plugin configuration issue. Multipath is configured correctly and both paths are being utilized - the bottleneck is at the iSCSI protocol layer.

## Platform Limitations

### Linux/Proxmox Only

**Limitation**: Plugin is Proxmox VE specific

**Not Supported**:
- Generic Linux systems
- Other hypervisors (VMware, Hyper-V, etc.)
- FreeBSD/BSD systems

**Explanation**: Plugin uses Proxmox storage plugin API

### ZFS Dependency

**Limitation**: Requires TrueNAS with ZFS

**Not Supported**:
- TrueNAS CORE (FreeBSD-based) - untested, may work
- Other iSCSI targets (not designed for them)
- Non-ZFS storage backends

**Explanation**: Plugin assumes ZFS dataset/zvol semantics

## Operational Limitations

### No Bulk Deletion

**Limitation**: Deleting many VMs sequentially may hit rate limits

**Explanation**: Each VM deletion makes multiple API calls

**Workaround**:
```bash
# Delete VMs with delays
for vm in 100 101 102 103; do
    qm destroy $vm --purge
    sleep 5
done

# Or delete zvols directly on TrueNAS after qm destroy
# (But loses automatic cleanup benefit)
```

### Configuration Changes Require Restart

**Limitation**: Changes to `/etc/pve/storage.cfg` require service restart

**Procedure**:
```bash
# After editing /etc/pve/storage.cfg
systemctl restart pvedaemon pveproxy
```

**Impact**: Brief interruption to API (web UI may disconnect)

### No Storage Overcommit Protection

**Limitation**: Plugin doesn't prevent overcommitting storage

**Explanation**:
- Thin provisioning allows allocating more virtual capacity than physical
- Plugin enforces 20% safety margin on individual operations
- But doesn't track total allocated vs available

**Mitigation**:
```bash
# Monitor actual space usage
zfs list tank/proxmox

# Set ZFS quotas/reservations if needed
zfs set quota=500G tank/proxmox
```

## Workarounds Summary

| Limitation | Recommended Workaround |
|------------|------------------------|
| No fast clones | Use smaller templates, faster network, accept limitation |
| No volume shrink | Create new smaller volume, migrate data, delete old |
| Images only | Use separate storage for LXC/ISO/backups |
| No backup integration | Use TrueNAS replication or Proxmox Backup Server |
| `qm destroy` orphans | Always use GUI deletion or add cleanup to scripts |
| API rate limits | Enable bulk operations, increase retry limits, pace operations |
| WebSocket instability | Improve network stability, verify TLS/certs, tune retry settings |
| Clone performance | Faster network, smaller images, accept limitation |
| Multipath read performance | Upgrade to 10GbE, accept ~100 MB/s, or use parallel workloads |
| Large-transfer I/O errors | Cap `max_sectors_kb=1024` via udev rule (`read_ahead_kb=1024` too on iSCSI) until fixed upstream |

## See Also
- [Troubleshooting Guide](Troubleshooting.md) - Solutions to common issues
- [Advanced Features](Advanced-Features.md) - Performance optimization
- [Configuration Reference](Configuration.md) - All configuration options
- [Multi-Tenancy](Multi-Tenancy.md) - Sharing a TrueNAS system across multiple clusters
