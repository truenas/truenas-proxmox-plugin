# LVM Filter for TrueNAS NVMe/TCP and iSCSI

## The problem

If a VM's disk lives on a TrueNAS NVMe/TCP namespace or iSCSI LUN and
the guest inside that VM uses LVM (default on Ubuntu, RHEL, and their
derivatives), the Proxmox host's LVM scanner sees the guest's PV
signatures at the outer device level and treats them as
host-level physical volumes.

Symptoms an operator will actually see:

- Every LVM invocation on the host (`pvesm status`, `pvesh get
  /nodes/<node>/storage`, `qm ...`, `pvestatd` polls) emits pages
  of `WARNING: VG name <name> is used by VGs <uuid1> and <uuid2>.
  Fix duplicate VG names with vgrename uuid, ...` lines. With many
  namespaces/LUNs cloned from the same template the duplicates cascade
  into thousands of lines.
- `pvesh get /nodes/<node>/storage` slows enough to trip the 596s
  API timeout, which in turn breaks external tools that poll it
  (Veeam's backup/restore scans have been observed to fail here).
- Boot is slower because `pvscan --cache` runs on every namespace/LUN
  udev-add event.

Reference: GitHub issue [#4](https://github.com/truenas/truenas-proxmox-plugin/issues/4).

## The fix

Add reject regexes to LVM's `global_filter` (see [Which file](#which-file-lvmlocalconf-vs-lvmconf))
so LVM stops scanning TrueNAS-served block devices:

```
"r|/dev/disk/by-id/nvme-TrueNAS_.*|"    # NVMe/TCP namespaces
"r|/dev/disk/by-path/ip-.*-iscsi-.*|"   # iSCSI LUNs
```

Both regexes are defined in `tools/truenas-plugin-lvm-filter:73-81`.
Why this works:

- `udev` populates `/dev/disk/by-id/nvme-<model>_<serial>` symlinks
  from the NVMe controller MODEL string. TrueNAS's NVMe controllers
  advertise `TrueNAS <hardware-model>` (e.g. `TrueNAS PowerEdge
  R730xd`, `TrueNAS FREENAS-MINI-2.0`), so every TrueNAS namespace
  ends up with a `nvme-TrueNAS_...` by-id name.
- iSCSI LUNs get `/dev/disk/by-path/ip-<portal>-iscsi-<iqn>-lun-<n>`
  symlinks from open-iscsi for every logged-in target, so the
  `by-path/ip-.*-iscsi-.*` regex covers every TrueNAS LUN on a
  plugin-managed PVE node.
- `pve-manager` sets `obtain_device_list_from_udev = 1` (LVM's
  default), so LVM's scan enumerates these symlinks and matches
  them against `global_filter`.
- Local NVMe drives use their own vendor prefix (e.g.
  `nvme-Samsung_...`, `nvme-Intel_...`) and never match; local SCSI
  devices do not carry an `iscsi-` by-path name. Host LVM (root
  filesystem VGs, local-lvm, etc.) is untouched.

## Which file: `lvmlocal.conf` vs `lvm.conf`

LVM reads `/etc/lvm/lvm.conf`, then `/etc/lvm/lvmlocal.conf`, and the
latter **overrides** the former for any key they both set. On PVE hosts
the effective `global_filter` usually lives in a `# truenasplugin
managed` `devices { }` block at the bottom of `lvmlocal.conf` (which also
sets `scan = [ "/dev/disk/by-id" ]`). Editing only `lvm.conf` would be
silently overridden by that block, so the helper and the installer both
target the **effective** file: `lvmlocal.conf` when it carries a
`global_filter` line, otherwise `lvm.conf`. They first check the merged
config (`lvm dumpconfig`) so they stay idempotent no matter which file the
filter already lives in.

## Applying the fix

### Automated (recommended)

The plugin ships a helper at `/usr/sbin/truenas-plugin-lvm-filter`:

```
sudo truenas-plugin-lvm-filter --install
sudo pvscan --cache
sudo vgscan
```

`--install` appends each missing reject regex to the effective
`global_filter` line (`lvmlocal.conf` preferred, else `lvm.conf`), tagged with a comment marker
(`# truenas-proxmox-plugin issue #4`) for future removal. A
timestamped backup is written first, and `lvm dumpconfig` is run
after the edit to verify the file still parses.

Reversal:

```
sudo truenas-plugin-lvm-filter --uninstall
```

`--uninstall` removes only the regexes the plugin added; anything
else in `global_filter` (including `pve-manager`'s default
`"r|/dev/zd.*|"` and `"r|/dev/rbd.*|"` for ZFS zvols and Ceph
rbds) is left in place.

Status check (does not need root):

```
truenas-plugin-lvm-filter --status
```

The script is idempotent: running `--install` when the filter is
already installed, or `--uninstall` when it isn't, is a no-op.

The installer offers the same step automatically after a storage is
configured (either transport), with the same idempotency and backup
behaviour.

### Manual

Edit the effective file (see [Which file](#which-file-lvmlocalconf-vs-lvmconf)) —
find the `global_filter =` line inside the `devices { ... }` block and append
`"r|/dev/disk/by-id/nvme-TrueNAS_.*|"` and
`"r|/dev/disk/by-path/ip-.*-iscsi-.*|"` to the list. Save. Refresh LVM:

```
sudo pvscan --cache
sudo vgscan
```

The `pve-manager`-provided line typically looks like:

```
global_filter = [ "r|/dev/zd.*|", "r|/dev/rbd.*|" ]
```

After the fix:

```
global_filter = [ "r|/dev/zd.*|", "r|/dev/rbd.*|", "r|/dev/disk/by-id/nvme-TrueNAS_.*|", "r|/dev/disk/by-path/ip-.*-iscsi-.*|" ]
```

## Cleaning up `/etc/lvm/archive`

Even with the filter in place, a host that ran without it for a while
has accumulated stale metadata archives in `/etc/lvm/archive/` — LVM
snapshots its metadata there before every change. A pile of thousands
of these files slows `vgs` / `pvscan`, and at the extreme makes
`pvesm status`-class calls even slower.

Once you have confirmed there are no pending LVM rollbacks you might
want to undo, it is safe to clear the directory:

```
sudo rm -f /etc/lvm/archive/*
```

The installer counts the files and offers this cleanup after applying
the filter when the directory is large. You can also delete individual
old archives if you want to keep the most recent one around.

## Why this isn't done at package install

`/etc/lvm/lvm.conf` is a Debian conffile owned by the `pve-manager`
package. It is intentionally NOT modified by
`truenas-proxmox-plugin`'s postinst, because:

- Debian policy discourages one package silently editing another
  package's conffile.
- LVM configuration is systemically load-bearing; a silent change
  applied on plugin install could surprise operators debugging
  unrelated LVM issues later.

`truenas-plugin-lvm-filter --install` exists so the sysadmin can
opt in with a clear audit trail (backup + marker comment + explicit
consent).

## Scope and caveats

- **Both transports are covered.** NVMe/TCP namespaces match on the
  `nvme-TrueNAS_` by-id prefix; iSCSI LUNs match on the
  `/dev/disk/by-path/ip-*-iscsi-*` symlink that open-iscsi creates.
  No SCSI vendor/model matching is involved.
- **Requires `obtain_device_list_from_udev = 1`** (LVM's default).
  If a local operator has set `obtain_device_list_from_udev = 0`,
  LVM will not enumerate the by-id symlinks and the filter has no
  effect.
- **The right long-term home for this fix is `pve-manager` itself**,
  in the same default `global_filter` that already excludes ZFS
  zvols and Ceph rbds. Filing an upstream patch is a separate
  planned follow-up.
