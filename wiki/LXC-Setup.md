# LXC Container Setup Guide

This guide covers running LXC containers on a `truenasplugin` storage.
The plugin exposes each container's rootfs as a raw block LUN (over
iSCSI, NVMe/TCP, or Fibre Channel); Proxmox's LXC layer formats that
LUN with `ext4` and mounts it as the container's root filesystem.

Container support is opt-in via the storage's `content` field: it is
not enabled by default.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Enabling Container Storage](#enabling-container-storage)
- [Creating a Container](#creating-a-container)
- [Additional Mountpoints](#additional-mountpoints)
- [Snapshots and Rollback](#snapshots-and-rollback)
- [Backup and Restore](#backup-and-restore)
- [Foreign Snapshot Import for Containers](#foreign-snapshot-import-for-containers)
- [Bind Mounts and Other Non-Volume Mountpoints](#bind-mounts-and-other-non-volume-mountpoints)
- [Design Limitations](#design-limitations)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- A working `truenasplugin` storage entry (any transport: iSCSI, NVMe/TCP,
  Fibre Channel). Follow the transport-specific setup guide first:
  main README (iSCSI), [wiki/NVMe-Setup.md](NVMe-Setup.md), or
  [wiki/FC-Setup.md](FC-Setup.md).
- The plugin package installed on every Proxmox node that will host
  containers.
- LXC templates available in a **separate** storage. The plugin cannot
  host `vztmpl` files because it serves block LUNs, not files. The
  standard pattern is:

  ```ini
  # Container images live on truenas-storage (block LUN)
  # Template files live on the local vztmpl store (or a shared NFS)
  ```

  Pointing `pct create` at `local:vztmpl/<template>` while placing the
  rootfs on the truenasplugin storage is the intended workflow.

## Enabling Container Storage

Add `rootdir` to the storage's `content` field. Either edit
`/etc/pve/storage.cfg`:

```ini
truenasplugin: truenas-storage
    ...
    content images,rootdir
    shared 1
```

Or use the CLI:

```bash
pvesm set truenas-storage --content images,rootdir
```

`images` covers VM disks; `rootdir` covers LXC container rootfs and
additional mountpoints. Both can coexist on the same storage; they use
the same zvol allocation path.

Without `rootdir`, `pct create` against this storage will fail with:

```
storage 'truenas-storage' does not support container directories
```

## Creating a Container

Once `rootdir` is enabled, containers work with the standard `pct`
workflow:

```bash
pct create 100 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
    --hostname my-container \
    --storage truenas-storage \
    --rootfs truenas-storage:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --memory 512
pct start 100
```

- `--storage truenas-storage` — future disk allocations for this CT go
  here.
- `--rootfs truenas-storage:8` — 8 GB rootfs zvol on this storage.

Behind the scenes, the plugin allocates a raw zvol
(e.g. `tank/proxmox/subvol-100-disk-0`), exposes it as an iSCSI LUN or
NVMe namespace, and Proxmox's LXC code formats it with `ext4` and
mounts it under `/var/lib/lxc/100/rootfs`.

## Additional Mountpoints

Extra volumes (`mp0`, `mp1`, ...) work the same way:

```bash
pct set 100 --mp0 truenas-storage:16,mp=/data
pct restart 100
```

This allocates a second zvol, exposes it as another LUN/namespace, and
mounts it at `/data` inside the container. Each mountpoint is a
separate block device.

## Snapshots and Rollback

Native PVE container snapshots work exactly like VM snapshots:

```bash
pct snapshot 100 baseline --description 'before upgrade'
pct listsnapshot 100
pct rollback 100 baseline
pct delsnapshot 100 baseline
```

Under the hood the plugin creates a ZFS snapshot per zvol on TrueNAS,
recorded in the CT's config file. Rollback stops the CT, does
`zfs rollback` on each backing zvol, and restarts (if it was running).

All of the plugin's transports (iSCSI, NVMe/TCP, FC) handle CT
snapshots identically because the ZFS layer on TrueNAS does the work.

## Backup and Restore

`vzdump` in `snapshot` mode is fully supported: the plugin creates an
ephemeral clone of the CT's rootfs zvol at snapshot time, exposes that
clone as a temporary LUN, and lets vzdump read from it while the live
container keeps running. When vzdump finishes, the plugin tears the
clone back down.

```bash
vzdump 100 --mode snapshot --storage local
```

Restore is the standard flow — any storage that supports `rootdir` can
be a restore target:

```bash
pct restore 101 /var/lib/vz/dump/vzdump-lxc-100-*.tar.zst \
    --storage truenas-storage
```

Both `backup_ct.pl` and `backup_restore.pl` in Proxmox's
`proxmox-test-runner storage-plugin-validation` suite pass against
this plugin on both iSCSI and NVMe/TCP transports as of beta5.

## Foreign Snapshot Import for Containers

Snapshots taken outside PVE (periodic snapshot tasks on TrueNAS,
`zfs snapshot` by hand, replication targets) are invisible to the
container's config. The importer that ships with the plugin can adopt
them:

```bash
truenas-proxmox-manage import-snapshots <CTID>              # dry-run helpful:
truenas-proxmox-manage import-snapshots <CTID> --dry-run
truenas-proxmox-manage import-snapshots <CTID> --match 'nightly-.*'
```

The importer walks every disk that the CT has on this storage
(rootfs + any `mpN`), finds snapshots that exist on **all** of them
with the same name, and writes a section to the CT's config so
`pct rollback`/`pct delsnapshot` can drive them.

Same rules apply to CTs as to VMs:

- Snapshots are crash-consistent (no guest-agent freeze). Journaling
  filesystems inside the container come back clean; databases may
  need their own recovery. Details in
  [wiki/Best-Practices.md](Best-Practices.md).
- A periodic TrueNAS snapshot newer than your latest deliberate PVE
  snapshot blocks `pct rollback` with "not most recent snapshot" whether
  or not you import it; importing just makes the snapshot visible and
  deletable from the PVE side.
- Use `--match REGEX` to import only the snapshots you name on
  purpose; without it every ZFS snapshot on every disk of this CT is a
  candidate.

## Bind Mounts and Other Non-Volume Mountpoints

Containers with a bind mount (`mp0: /host/path,mp=/container/path`)
or a device mountpoint (`mp0: /dev/sdX,mp=/mnt/x`) cannot be
snapshotted. PVE's own `pct snapshot` refuses to snapshot such
containers because the non-volume mountpoint has no ZFS backing zvol,
and the plugin's snapshot importer applies the same rule:

```
truenas-proxmox-manage import-snapshots 101 --yes
import-snapshots: CT 101 has bind/device mountpoints (mp0: /host/data);
    PVE does not allow snapshots of this container, nothing imported
```

Remove the bind mount or convert it to a proper storage-backed
mountpoint before running snapshots.

## Design Limitations

- **One zvol per volume**. Each rootfs / mountpoint is its own zvol
  and its own LUN or namespace. There is no thin-subvolume-tree pattern
  like the built-in `zfspool` storage type.
- **ext4 only**. Proxmox formats new container rootfs devices with
  `ext4`; the plugin has no say in the filesystem choice. This matches
  every other Proxmox block-storage backend.
- **No `iso` / `vztmpl` on this storage**. It's a block storage, not a
  file storage. Keep ISOs and CT templates on `local` or a shared NFS.
- **Bind-mount containers cannot be snapshotted**. See section above;
  this is a PVE-wide constraint the plugin inherits.
- **Container rootfs shrinking is not supported**. The plugin allows
  online *growth* of a mountpoint (`pct resize 100 rootfs +8G`) but
  ZFS zvols cannot shrink safely, so shrinking is not offered.

## Troubleshooting

**`storage 'truenas-storage' does not support container directories`**
— `content` field is missing `rootdir`. Add it in storage.cfg or with
`pvesm set truenas-storage --content images,rootdir`.

**`Failed to read from container: /dev/mapper/... busy`** — usually a
lingering iSCSI session on the CT's rootfs LUN from a previous run.
`pct stop <ctid>` and then `pct start <ctid>` cycles the session.

**`pct rollback failed: is not most recent snapshot`** — a foreign
snapshot (periodic task on TrueNAS, hand-invoked `zfs snapshot`)
exists on the CT's rootfs zvol newer than the snapshot you are trying
to roll back to. Either import the foreign snapshot with
`truenas-proxmox-manage import-snapshots` and roll back to that, or
delete the foreign snapshot on TN so the desired one becomes the
newest. See the foreign snapshot import section above.

**Container starts but rootfs is empty / corrupted after rollback** —
the rollback target's zvol was not reformatted; the pre-rollback
rootfs image is what came out of it. If the pre-rollback state was
inconsistent (crash-consistent-only foreign snapshot on a
database-heavy container), the container's rootfs may need `fsck` or
restore from a proper backup. Use PVE-native `pct snapshot` for
application-consistent rollback points; treat foreign snapshots as a
safety net.

**Slow first activation on an NVMe/TCP CT** — namespace discovery on
the first LUN activation after container boot takes an extra second
or two while udev populates `/dev/disk/by-id`. Subsequent CT restarts
are fast because the namespace is already known.
