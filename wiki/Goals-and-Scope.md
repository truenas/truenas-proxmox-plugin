# Goals and Scope

What this plugin sets out to do, and what it deliberately does not.

---

## Goals

### Bring ZFS-backed block storage to Proxmox VE via TrueNAS

The plugin's central purpose is to let Proxmox VE provision, snapshot, resize, clone, and delete VM disk images on TrueNAS SCALE ZFS pools — using the same GUI and CLI workflows admins already know — without requiring manual iSCSI or NVMe target configuration.

### Support two transport protocols

- **iSCSI** for broad compatibility with existing networks and TrueNAS versions.
- **NVMe/TCP** for lower latency and higher queue depth on TrueNAS 25.10+.

Both transports present standard block devices to Proxmox; VMs and operators see no difference.

### Work correctly in Proxmox clusters

The plugin is designed as shared storage (`shared 1`) so that live migration, HA fencing, and multi-node scheduling all work. Every node in the cluster connects to the same TrueNAS dataset and sees the same volumes.

### Be safe by default

- 20% space headroom enforced on allocations and resizes to prevent ZFS pool exhaustion.
- 12-point pre-flight validation before provisioning.
- Exponential backoff with jitter to respect TrueNAS API rate limits.
- Non-retryable errors (auth failures, validation errors) fail fast instead of looping.

### Keep operations visible and debuggable

All API calls, retries, and transport events are logged to syslog. The test harness, health check, and diagnostic tools exist so that problems surface before they reach production VMs.

### Ship as a standard Debian package

The plugin installs via `dpkg` / APT with proper `postinst`/`prerm`/`postrm` hooks, integrates with Proxmox's custom plugin directory, and can be rolled out across a cluster from a single installer session.

---

## Out of Scope

### File-based storage

The plugin provides block devices only (`content images`). It does not serve ISO images, LXC container rootfs, backups, snippets, or templates. Use NFS, SMB, or local storage alongside the plugin for those content types.

### NFS / SMB / CIFS

The plugin communicates with TrueNAS over its WebSocket API and exposes storage via iSCSI or NVMe/TCP. It does not create, manage, or consume NFS or SMB shares.

### LXC containers

LXC requires filesystem-level storage (directories, bind mounts, ZFS datasets). Block devices do not satisfy that requirement, so LXC support is not a goal.

### Non-Proxmox hypervisors

The plugin extends `PVE::Storage::Plugin`. It will not work with VMware, Hyper-V, oVirt, or bare Linux systems. It is Proxmox-specific by design.

### TrueNAS CORE (FreeBSD)

Development and testing target TrueNAS SCALE exclusively. The FreeBSD-based TrueNAS CORE is untested and unsupported.

### Fast (ZFS-native) cloning

Proxmox treats iSCSI/NVMe block storage as "generic external" storage and performs clones via `qemu-img convert` over the network. The plugin implements `clone_image()`, but Proxmox never calls it. This is a Proxmox architectural constraint, not a missing feature in the plugin.

### Mutual CHAP / advanced iSCSI auth

One-way CHAP and DH-HMAC-CHAP (NVMe) are supported. Mutual CHAP (target authenticating back to the initiator) is not implemented. Network segmentation and firewalling are the recommended compensating controls.

### Backup integration

ZFS snapshots created by the plugin are not included in `vzdump` backups. Snapshot history lives on TrueNAS only. Use Proxmox Backup Server or TrueNAS replication for backup workflows.

### Storage overcommit protection

The plugin enforces per-operation headroom but does not track aggregate thin-provisioned capacity against physical pool size. Operators are responsible for monitoring overall utilization.

### Volume shrinking

ZFS does not support reducing zvol size. The plugin can only grow volumes.

---

## See Also

- [Known Limitations](Known-Limitations.md) — detailed limitation descriptions and workarounds
- [Configuration Reference](Configuration.md) — all `storage.cfg` options
- [Ideas](Ideas.md) — future feature candidates
