# Multi-Tenancy / Shared TrueNAS

Guide for safely sharing a single TrueNAS appliance across multiple Proxmox clusters or standalone nodes.

## Table of Contents

- [Overview](#overview)
- [One Dataset per Cluster](#one-dataset-per-cluster)
- [One Target or Subsystem per Cluster](#one-target-or-subsystem-per-cluster)
- [Global iSCSI Extent-Name Uniqueness](#global-iscsi-extent-name-uniqueness)
- [What Happens When Isolation Is Incomplete](#what-happens-when-isolation-is-incomplete)
  - [Shared Dataset, Shared Target](#shared-dataset-shared-target)
  - [Separate Datasets, Shared Target](#separate-datasets-shared-target)
  - [Separate Datasets, Separate Targets](#separate-datasets-separate-targets)
- [Separating an Already-Shared Deployment](#separating-an-already-shared-deployment)

---

## Overview

A single TrueNAS system can serve storage to multiple independent Proxmox clusters. To avoid data collisions and phantom block devices, each cluster must be assigned its own dedicated ZFS dataset **and** its own iSCSI target (or NVMe subsystem). This page explains the rules, the consequences of breaking them, and how to retroactively separate a shared deployment.

## One Dataset per Cluster

Each Proxmox cluster (or standalone node) should use its own dedicated ZFS dataset on TrueNAS. The plugin creates child zvols under this dataset (e.g., `vm-100-disk-0`), so sharing a dataset means both clusters write into the same namespace.

**Recommended layout:**

| Environment | Dataset |
|---|---|
| Cluster A (production) | `tank/proxmox-cluster-a` |
| Cluster B (staging) | `tank/proxmox-cluster-b` |
| Standalone node | `tank/proxmox-standalone` |

**Example storage.cfg entries:**

```ini
# Cluster A
truenasplugin: cluster-a-storage
    tn_api_host 10.0.0.100
    tn_api_key 1-cluster-a-key
    tn_dataset tank/proxmox-cluster-a
    tn_target_iqn iqn.2005-10.org.freenas.ctl:cluster-a
    tn_discovery_portal 10.0.0.100:3260
    content images
    shared 1

# Cluster B
truenasplugin: cluster-b-storage
    tn_api_host 10.0.0.100
    tn_api_key 1-cluster-b-key
    tn_dataset tank/proxmox-cluster-b
    tn_target_iqn iqn.2005-10.org.freenas.ctl:cluster-b
    tn_discovery_portal 10.0.0.100:3260
    content images
    shared 1
```

**Why this matters:** Proxmox assigns VM IDs independently per cluster. Both clusters can have a VM 101, and both will try to create a zvol named `vm-101-disk-0`. With separate datasets, these resolve to different full paths (`tank/proxmox-cluster-a/vm-101-disk-0` vs `tank/proxmox-cluster-b/vm-101-disk-0`) and never collide.

## One Target or Subsystem per Cluster

Each cluster should have its own iSCSI target or NVMe subsystem. This controls which block devices are visible at the transport layer.

**iSCSI example:**

| Environment | Target IQN |
|---|---|
| Cluster A | `iqn.2005-10.org.freenas.ctl:cluster-a` |
| Cluster B | `iqn.2005-10.org.freenas.ctl:cluster-b` |

**NVMe/TCP example:**

| Environment | Subsystem NQN |
|---|---|
| Cluster A | `nqn.2005-10.org.freenas.ctl:cluster-a-nvme` |
| Cluster B | `nqn.2005-10.org.freenas.ctl:cluster-b-nvme` |

Create these in TrueNAS before configuring storage:
- **iSCSI**: Shares > Block Shares (iSCSI) > Targets > Add
- **NVMe/TCP**: The plugin creates the subsystem automatically if it does not exist

**Why this matters:** An iSCSI target (or NVMe subsystem) defines which LUNs (or namespaces) a set of initiators can discover. If two clusters share the same target, every node in both clusters sees every block device, regardless of which dataset the zvol lives in.

## Global iSCSI Extent-Name Uniqueness

TrueNAS requires iSCSI extent names to be globally unique across the entire system, not just within a single target. Even with separate datasets and separate targets, two extents cannot share the same name.

**The plugin solves this automatically.** It generates deterministic, collision-resistant extent names using the format:

```
<zname>-<8-char-sha1-hash>
```

The hash is derived from the full dataset path (`dataset/zname`), so the same zvol name under different datasets produces different extent names:

```
Cluster A zvol:  tank/proxmox-cluster-a/vm-101-disk-0
Extent name:     vm-101-disk-0-a3f8c1d2

Cluster B zvol:  tank/proxmox-cluster-b/vm-101-disk-0
Extent name:     vm-101-disk-0-7e4b09f1
```

**Constraints respected:**
- TrueNAS 64-character extent name limit (base is truncated to 55 characters, leaving room for the `-` separator and 8-character hash)
- Allowed characters: lowercase `a-z`, `0-9`, `.`, `-`, `:`
- Weight volumes (`pve-weight-*`) are exempt and keep their plain name

**On older versions without unique extent naming:** Extent names equal the bare zvol name (e.g., `vm-101-disk-0`). If two clusters share a TrueNAS system and both have a VM 101, the second extent creation fails with a duplicate name error. Upgrade to a version with unique extent naming before adding a second cluster.

## What Happens When Isolation Is Incomplete

The table below summarizes the three possible sharing scenarios. Only the last one is recommended.

| Dataset | Target/Subsystem | Isolation Level | Risk |
|---|---|---|---|
| Shared | Shared | None | Data collision, mutual overwrites |
| Separate | Shared | Partial | Phantom block devices in kernel |
| Separate | Separate | Full | No cross-cluster interference |

### Shared Dataset, Shared Target

Both clusters see **all** volumes and can read/write any of them.

**Risks:**
- **VM ID collision**: If both clusters create VM 101, the second `vm-101-disk-0` zvol creation fails or silently overwrites the first
- **Accidental deletion**: Deleting a VM on Cluster A may remove zvols that Cluster B depends on
- **Snapshot interference**: Snapshot names may collide, causing unexpected rollback behavior

The plugin's unique extent naming prevents iSCSI extent name collisions, but shared datasets mean both clusters operate on the same zvols. Extent naming does not protect against zvol-level collisions.

**Verdict:** Never use this configuration.

### Separate Datasets, Shared Target

Each cluster's zvols are isolated at the ZFS level (separate datasets), but **all LUNs are visible** at the iSCSI transport layer to every node in both clusters.

**Consequences:**
- Proxmox nodes in Cluster A see phantom block devices for Cluster B's volumes (and vice versa)
- The kernel's SCSI layer allocates `/dev/sd*` entries for every LUN, consuming resources
- The plugin's `list_images` correctly filters by dataset path, so the Proxmox UI only shows volumes belonging to the local cluster
- However, the phantom devices are still attached at the kernel level and may appear in `lsscsi`, `multipath -ll`, or similar tools

**Verdict:** Functional but wasteful and confusing. Not recommended.

### Separate Datasets, Separate Targets

Full isolation. Each cluster discovers only its own LUNs. No phantom devices, no naming conflicts, no cross-cluster interference.

**Verdict:** Recommended configuration for all multi-tenant deployments.

## Separating an Already-Shared Deployment

If two or more clusters currently share a dataset or target, follow these steps to separate them without data loss.

### Prerequisites

- Identify which clusters share the dataset and/or target
- Plan new dataset names and target IQNs (or subsystem NQNs) for each cluster
- Schedule a maintenance window; VMs will need to be shut down during migration

### Step 1 - Create New Resources on TrueNAS

Create a new dedicated dataset for each cluster that needs to be migrated away from the shared configuration:

```bash
# On TrueNAS (via CLI or web UI)
zfs create tank/proxmox-cluster-b
```

Create a new dedicated iSCSI target (or NVMe subsystem) for each cluster:
- **iSCSI**: TrueNAS web UI > Shares > Block Shares (iSCSI) > Targets > Add
- **NVMe/TCP**: The plugin creates the subsystem automatically if it does not exist

### Step 2 - Migrate VM Volumes

For each VM that belongs to the cluster being moved to the new dataset:

**a.** Shut down the VM:
```bash
qm shutdown VMID
```

**b.** Copy the zvol to the new dataset using ZFS send/receive:
```bash
# On TrueNAS
zfs snapshot tank/shared-dataset/vm-VMID-disk-0@migrate
zfs send tank/shared-dataset/vm-VMID-disk-0@migrate | zfs recv tank/proxmox-cluster-b/vm-VMID-disk-0
zfs destroy tank/proxmox-cluster-b/vm-VMID-disk-0@migrate
```

**c.** Repeat for every disk the VM owns (disk-0, disk-1, etc.) and any associated snapshots.

### Step 3 - Update Storage Configuration

Edit `/etc/pve/storage.cfg` on the cluster being migrated to point to the new dataset and target:

```ini
truenasplugin: cluster-b-storage
    tn_api_host 10.0.0.100
    tn_api_key 1-cluster-b-key
    tn_dataset tank/proxmox-cluster-b
    tn_target_iqn iqn.2005-10.org.freenas.ctl:cluster-b
    tn_discovery_portal 10.0.0.100:3260
    content images
    shared 1
```

Restart Proxmox services on all nodes in the cluster:

```bash
systemctl restart pvedaemon pveproxy
```

### Step 4 - Verify and Start VMs

```bash
# Verify storage is active
pvesm status

# List volumes on new storage
pvesm list cluster-b-storage

# Start VMs
qm start VMID
```

### Step 5 - Clean Up Old Resources

Once all VMs are confirmed working on the new dataset, remove the old shared resources:

1. Delete old iSCSI extents and target-extent mappings that pointed to the migrated zvols
2. Destroy the migrated zvols from the old shared dataset:
   ```bash
   # On TrueNAS - only after confirming VMs work on the new dataset
   zfs destroy tank/shared-dataset/vm-VMID-disk-0
   ```
3. If the old target is no longer needed by any cluster, delete it from TrueNAS
4. Run the installer's orphan cleanup tool to catch any missed resources:
   ```bash
   ./install.sh
   # Choose: Diagnostics > Cleanup orphaned resources
   ```

## See Also
- [Configuration Reference](Configuration.md) - All storage configuration parameters
- [Advanced Features - Cluster Configuration](Advanced-Features.md#cluster-configuration) - Cluster setup details
- [Known Limitations](Known-Limitations.md) - Important restrictions
- [Installation Guide](Installation.md) - Initial setup instructions
