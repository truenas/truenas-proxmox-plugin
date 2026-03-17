# Proxmox VE — Limits and Constraints Reference

Relevant limits and behaviors for planning and testing TrueNAS Proxmox plugin deployments.

---

## Disks Per VM

### Hard Limit

Proxmox enforces a maximum of **31 SCSI devices per VM** (`scsi0`–`scsi30`) in `qm.conf`, regardless of the underlying QEMU/virtio-scsi theoretical capacity. The 256-disk figure sometimes cited comes from QEMU itself and is not reachable through standard Proxmox tooling.

Full device-type limits that can be used simultaneously:

| Controller Type | Max Disks |
|----------------|-----------|
| VirtIO SCSI (any) | **31** (scsi0–scsi30) |
| VirtIO Block | 16 |
| SATA | 6 |
| IDE | 4 |

### Practical Notes

- No documented performance cliff below 31 disks. At 30+ disks, Proxmox community guidance shifts toward HBA/PCIe passthrough rather than emulated SCSI controllers.
- The plugin's internal naming loop tries `vm-<vmid>-disk-0` through `vm-<vmid>-disk-999`, so the plugin is never the bottleneck — Proxmox will refuse to attach more than 31 SCSI devices before the plugin runs out of names.

---

## VirtIO SCSI vs VirtIO SCSI Single

| | VirtIO SCSI (classic) | VirtIO SCSI Single |
|---|---|---|
| Controllers | One controller for all disks | One controller per disk |
| IOThreads | One IOThread serves all disks | One IOThread per disk (independent) |
| Performance gain with IOThreads | ~5% | ~45% more IOPS |
| Default since | (older default) | Proxmox VE 7.3 |

**VirtIO SCSI Single + IOThread enabled** is the current recommended configuration. Without IOThreads, the performance difference between the two modes is negligible.

**SCSI UNMAP/TRIM**: VirtIO SCSI passes SCSI UNMAP commands through to the iSCSI layer, allowing TrueNAS to reclaim space from deleted blocks on sparse zvols. VirtIO Block does not support this.

---

## Shared LUN / Cluster Storage

### Scenario 1 — Multiple Proxmox Nodes Sharing a LUN (Normal Cluster Use)

This is the supported use case for this plugin. All cluster nodes can see the TrueNAS iSCSI target, but Proxmox's cluster lock stack ensures only one node has a given logical volume active at a time. Live VM migration works by handing off the active lock between nodes.

**Limits:**

| Layer | Limit | Notes |
|-------|-------|-------|
| Proxmox cluster size | No hard limit | Practical ceiling ~20–25 nodes without dedicated cluster network tuning; 50+ node deployments exist with careful engineering |
| Corosync (cluster communication) | No hard-coded limit in current versions | Older versions had a 32-node limit; network latency and PPS are the real constraints |
| TrueNAS CTL — simultaneous initiator sessions per target | Not publicly documented | Each cluster node holds one open iSCSI session to the target; confirm with engineering for large (20+) node deployments |
| TrueNAS CTL — total LUNs | 1024 | Aggregate across all targets |

For typical deployments of 3–10 nodes, none of these limits are a concern.

**Note on LVM**: Proxmox's native iSCSI+LVM shared storage supports thick LVM only — LVM-thin cannot be shared across cluster nodes. This plugin uses zvols directly and sidesteps that restriction entirely.

### Scenario 2 — Multiple VMs Simultaneously Writing the Same Block Device

This is for clustered filesystems inside guest VMs (e.g., GFS2, OCFS2). This is **not supported by this plugin** — each zvol is owned by one VM by naming convention and plugin cleanup logic is tied to that ownership.

Even outside this plugin, Proxmox has no orchestration for in-guest clustered filesystems:

- **GFS2**: Technically functional but not integrated or supported by Proxmox.
- **OCFS2**: Known kernel bug causing IO errors with `io_uring` from kernel 6.5 through at least 6.8. Effectively broken on current Proxmox versions.

For customers needing shared block storage across VMs, the recommended alternatives are Ceph RBD (natively integrated with Proxmox) or TrueNAS NFS (file-level, not block-level).
