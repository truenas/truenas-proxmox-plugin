# TrueNAS Proxmox Plugin — Best Practices, Limitations, and Recommendations

**Quality Management System Document**
**Document code:** PRD-3-XXXXX
**Status:** Draft
**Applies to plugin:** `truenas-proxmox-plugin` 2.1.21+

## Document Status

| Version | Person | Changes | Date |
|---|---|---|---|
| v0.1 | Bill O'Hanlon | Original content | 2026-07-24 |

## Review Tracker

| Assignee | Title | Date | Status |
|---|---|---|---|
|  | Primary Content |  | In progress |
|  | Engineering review |  | Not started |
|  | Solutions review |  | Not started |
|  | Support review |  | Not started |
|  | Marketing / PM review |  | Not started |

**Publication links:** _to be populated_

---

## Purpose

Customer-facing guidance for deploying the TrueNAS Proxmox Storage
Plugin in production. Covers install, storage layout, transport choice,
HA behavior, provisioning workflow, security, and post-deploy validation.
This document is prescriptive: where a value has been tested, the tested
value is given. It complements the general
[TrueNAS Best Practices with Proxmox](https://truenas.github.io/) product
guide by focusing on the automated block-storage plugin (iSCSI and
NVMe/TCP), rather than on file-based NFS or SMB integration.

---

## 1. Integration Overview

The TrueNAS Proxmox Plugin is an official storage backend for Proxmox
Virtual Environment (PVE). It provisions ZFS volumes on TrueNAS SCALE
25.10 (or later) via the TrueNAS API, publishes them to PVE as either
iSCSI LUNs or NVMe-oF namespaces, and integrates the resulting devices
into the standard PVE storage lifecycle (create, snapshot, clone,
template, live-migrate, delete). No manual iSCSI extent or NVMe
namespace configuration is required.

The plugin runs on every Proxmox node in a cluster. It uses TrueNAS'
WebSocket JSON-RPC API for control-plane operations and standard Linux
block-storage transports (open-iscsi or nvme-cli) for the data path.

Typical deployment models:

- **Shared block storage for a Proxmox cluster** — one TrueNAS system
  serves VM disks to all nodes in the cluster over iSCSI or NVMe/TCP.
  Live migration works out of the box because the LUNs are visible on
  every node.
- **Multiple Proxmox clusters against one TrueNAS** — supported. Each
  cluster gets its own child dataset under the plugin's parent dataset;
  volume listings and destructive operations are scoped by dataset name.
- **Combined block + file** — the plugin is complementary to Proxmox's
  built-in NFS support. A common pattern is block via this plugin for VM
  disks, plus NFS from the same TrueNAS for ISOs and backups.

The plugin's source of truth is the TrueNAS API. All zvol create /
snapshot / clone / delete operations are issued as authenticated JSON-RPC
calls; PVE never talks to the ZFS command line on TrueNAS directly.

---

## 2. Supported Protocols and Integration Methods

The plugin implements two transports. Both use ZFS volumes (zvols) on
TrueNAS as backing store.

| Protocol | Supported | Description | When to Use | Notes / Caveats |
|---|---|---|---|---|
| iSCSI | Yes | Block storage via LUNs mapped from zvol-backed extents | General VM workloads on 10 GbE or slower fabrics | Multipath recommended for reliability; timeouts must be tuned for HA (see §4). Auth via CHAP optional. |
| NVMe/TCP | Yes | Block storage via NVMe-oF namespaces mapped to zvols | Latency-sensitive workloads on 25 GbE+ fabrics | Requires TrueNAS 25.04 or later. Native NVMe multipath; DH-HMAC-CHAP optional. |
| NFS | Yes (via native Proxmox) | Not implemented by this plugin | ISO libraries, backup targets, mixed file/block deployments | Use Proxmox's built-in NFS storage type; ensure UID/GID mapping is consistent. |
| SMB | Yes (via native Proxmox) | Not implemented by this plugin | Windows-adjacent workloads, mixed OS environments | Not suitable for VM disk images. |

The `tn_transport` option on each storage entry selects `iscsi` or
`nvme-tcp`. Do not run both transports against the same dataset from the
same Proxmox cluster — provision two datasets and two storage entries if
you need both.

---

## 3. Deployment and Configuration Best Practices

### 3.1 Prerequisites

Software:

- **Proxmox VE** 8.x or later (9.x recommended when using volume-chain
  snapshots).
- **TrueNAS SCALE** 25.10 or later. NVMe/TCP transport additionally
  requires TrueNAS 25.04 or later.
- **Perl** 5.36 or later (shipped with Proxmox VE).

Network:

- Reachability from every Proxmox node to the TrueNAS management IP on
  the WebSocket API port (443 for `wss`, 80 for `ws`; `wss` is
  strongly recommended).
- Reachability to the TrueNAS storage IP on TCP/3260 (iSCSI) or
  TCP/4420 (NVMe/TCP), on the dedicated storage VLAN.

TrueNAS prerequisites, in order:

1. **Create the parent ZFS dataset.** Web UI: *Datasets → Add Dataset*.
   Set *Compression* to `zstd`, *Enable Atime* to Off. CLI on the
   TrueNAS shell:

   ```bash
   zfs create tank/proxmox
   zfs set compression=zstd tank/proxmox
   zfs set atime=off tank/proxmox
   ```

2. **Enable the transport service.** For iSCSI: *System Settings →
   Services → iSCSI* — toggle *Running* on and *Start Automatically*
   on. For NVMe/TCP: same page, service `nvmet`.

3. **Create the iSCSI target and portal** (iSCSI transport only).
   *Shares → Block Shares (iSCSI) → Targets → Add*, name `proxmox`
   (results in IQN `iqn.2005-10.org.freenas.ctl:proxmox`). Then
   *Portals* — the default `0.0.0.0:3260` is sufficient for basic
   deployments; add explicit portal IPs when using multipath.

4. **Create the NVMe subsystem** (NVMe/TCP transport only). *Shares →
   Block Shares (NVMe-oF) → Subsystems → Add*, with a subsystem NQN
   the plugin will reference via `tn_subsystem_nqn`.

5. **Create the API user and API key** — see §3.7 for the recommended
   least-privilege setup.

### 3.2 Installation

Install the plugin from the Debian package. Two installation paths are
supported:

1. **Official APT repository** (recommended). Handles upgrades, key
   management, and signed metadata. On every Proxmox node:

   ```bash
   install -d -m 0755 /etc/apt/keyrings
   curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/apt/pubkey.gpg \
     -o /etc/apt/keyrings/truenas-proxmox-plugin.gpg
   cat > /etc/apt/sources.list.d/truenas-proxmox-plugin.sources <<'EOF'
   Types: deb
   URIs: https://truenas.github.io/truenas-proxmox-plugin/apt/
   Suites: bookworm
   Components: main
   Architectures: amd64 all
   Signed-By: /etc/apt/keyrings/truenas-proxmox-plugin.gpg
   EOF
   apt-get update
   apt-get install -y truenas-proxmox-plugin
   ```

   Substitute `trixie` for `bookworm` on PVE 9.x nodes.

2. **Local `.deb` install** for air-gapped environments. Download the
   release artifact from
   `https://github.com/truenas/truenas-proxmox-plugin/releases` and, on
   every Proxmox node:

   ```bash
   dpkg -i truenas-proxmox-plugin_<version>_all.deb
   apt-get install -f
   ```

Under no circumstances should `TrueNASPlugin.pm` be copied into
`/usr/share/perl5/PVE/Storage/Custom/` by hand. As of plugin release
2.1.21 the plugin refuses to open a direct WebSocket if the broker
daemon socket is absent, and manual copies do not install the broker.

### 3.3 The `truenas-plugin-broker` daemon

The plugin ships a session-broker daemon that holds a single
authenticated WebSocket per `(TrueNAS host, API key)` pair for the
entire Proxmox node. All plugin processes forward their JSON-RPC calls
through the broker's Unix socket at `/run/truenas-plugin/broker.sock`.

Without the broker, every forked `pvedaemon`, `pvestatd`, and `pveproxy`
worker re-authenticates against TrueNAS via `auth.login_with_api_key`.
TrueNAS middlewared rate-limits that endpoint per source IP. Under real
test load the limiter fires within seconds and cascades into pre-flight
failures across snapshot, resize, clone, additional-disk, and backup
operations. The broker is required, not optional.

The Debian `postinst` enables and starts the `truenas-plugin-broker`
service automatically and verifies its socket appears. Verify after
install:

```bash
systemctl is-active truenas-plugin-broker
ls -l /run/truenas-plugin/broker.sock
```

The socket must exist as a `0600` Unix stream socket in a `0700`
directory. Any other state indicates a broker service failure — see
`systemctl status truenas-plugin-broker` and
`journalctl -u truenas-plugin-broker`.

### 3.4 Storage layout on TrueNAS

Provision a dedicated parent dataset for Proxmox on the TrueNAS pool
that will back VM disks, and give each Proxmox cluster its own child
dataset under that parent. This isolates volume listings, quotas, and
destructive operations per cluster.

Recommended layout:

```
tank/proxmox                       (reserved parent, not used directly)
tank/proxmox/prod-cluster          (tn_dataset for the production cluster)
tank/proxmox/dev-cluster           (tn_dataset for the dev cluster)
tank/proxmox/backup-target         (optional; Proxmox Backup Server target)
```

Point each storage entry's `tn_dataset` at the child. The plugin only
enumerates volumes under its configured `tn_dataset` prefix, so cross-
cluster listing is prevented at the plugin level.

Keep the ZFS pool below 80% used capacity. Fragmentation and write
amplification climb rapidly beyond that mark, and the plugin's
pre-flight validator refuses allocations when the parent dataset has
less headroom than the requested zvol.

### 3.5 ZFS parameters for plugin-managed datasets

The plugin creates ZFS volumes (`type=VOLUME`, `volsize`, `volblocksize`)
rather than filesystems. `recordsize` therefore does not apply. Set the
following on the parent dataset so children inherit them:

| Property | Recommended | Reason |
|---|---|---|
| `compression` | `zstd` (TrueNAS 25.10 default) | Better ratio than lz4; CPU cost negligible for VM I/O |
| `sync` | `standard` | Balances safety and performance. Use `always` only when required, and add an SLOG. |
| `atime` | `off` | Eliminates unnecessary write amplification |
| `dedup` | `off` | Memory-intensive; rarely helps VM images. Enable only after measurement. |

Per-storage tunables set via `storage.cfg`:

- `tn_zvol_blocksize` — `16K` is a good default for general VM disks.
  Match to the guest filesystem block size for I/O-sensitive workloads.
- `tn_sparse` — leave at `1` (default) for thin provisioning.

### 3.6 Networking

Isolate storage traffic on its own VLAN and Linux bridge. Storage I/O
competing with VM guest traffic on a shared bridge produces
unpredictable latency spikes under load.

Enable end-to-end MTU 9000 (jumbo frames) on every hop of the storage
VLAN: TrueNAS interface, all Proxmox storage bridges, and every switch
port in between. Verify from each Proxmox node with:

```bash
ping -M do -s 8972 <truenas-storage-ip>
```

Any fragmentation along the path will degrade throughput and produce
difficult-to-diagnose stalls.

For redundancy and throughput, configure two portals on separate
physical NICs and separate VLANs, and set `tn_use_multipath 1`. For
iSCSI this activates standard `multipath-tools` (dm-mp). For NVMe/TCP,
`nvme-cli` uses native NVMe multipath and requires no additional
configuration on Proxmox.

Example portal list:

```
tn_portals 10.10.10.68:3260,10.10.11.68:3260
```

### 3.7 storage.cfg examples

Single-node iSCSI:

```
truenasplugin: truenas-iscsi
    tn_api_host 192.168.1.68
    tn_api_key_file /etc/pve/priv/truenas-iscsi.key
    tn_api_scheme wss
    tn_dataset tank/proxmox/prod
    tn_target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    tn_discovery_portal 192.168.1.68:3260
    tn_transport iscsi
    tn_use_multipath 1
    tn_portals 10.10.10.68:3260,10.10.11.68:3260
    shared 1
```

Same TrueNAS, NVMe/TCP transport:

```
truenasplugin: truenas-nvme
    tn_api_host 192.168.1.68
    tn_api_key_file /etc/pve/priv/truenas-nvme.key
    tn_api_scheme wss
    tn_dataset tank/proxmox/prod-nvme
    tn_transport nvme-tcp
    tn_subsystem_nqn nqn.2011-06.com.truenas:proxmox-nvme
    tn_portals 10.10.10.68:4420,10.10.11.68:4420
    shared 1
```

Store the API key in a root-owned key file referenced by
`tn_api_key_file`, not inline via `tn_api_key`. `/etc/pve/storage.cfg`
is world-readable to the `www-data` user on a stock Proxmox install; a
key file is not.

Key parameters (a subset of the full option set):

| Parameter | Purpose | Default |
|---|---|---|
| `tn_api_host` | TrueNAS management hostname or IP | (required) |
| `tn_api_key` / `tn_api_key_file` | API key (inline) or path to file containing it | (one required) |
| `tn_api_scheme` | `wss` (recommended) or `ws` | `wss` |
| `tn_dataset` | ZFS dataset that will hold this storage's zvols | (required) |
| `tn_transport` | `iscsi` or `nvme-tcp` | `iscsi` |
| `tn_target_iqn` | iSCSI target IQN (iSCSI only) | (required for iSCSI) |
| `tn_discovery_portal` | Discovery portal `IP:PORT` (iSCSI only) | (required for iSCSI) |
| `tn_subsystem_nqn` | NVMe subsystem NQN (NVMe/TCP only) | (required for NVMe/TCP) |
| `tn_portals` | Comma-separated list of data-path portal `IP:PORT`s | discovered |
| `tn_use_multipath` | Enable dm-mp for iSCSI; ignored for NVMe/TCP | `0` |
| `tn_zvol_blocksize` | `volblocksize` for created zvols | `16K` |
| `tn_sparse` | Thin-provision new zvols | `1` |
| `shared` | Must be `1` for a Proxmox cluster | `1` |
| `tn_debug` | 0=errors only, 1=info, 2=verbose | `0` |

---

### 3.8 Least-privilege TrueNAS API user

Do not give the plugin's API key `Full Admin` or `SHARING_ADMIN`. The
plugin calls a fixed, small set of TrueNAS methods and can operate
with the following role bundle:

Common (both transports):

| Role | Grants |
|---|---|
| `POOL_READ` | Pool status queries |
| `DATASET_WRITE` | Create, update, rename, and query datasets/zvols |
| `DATASET_DELETE` | Delete datasets/zvols |
| `SNAPSHOT_WRITE` | Create, query, clone, and rollback snapshots |
| `SNAPSHOT_DELETE` | Delete snapshots |
| `SERVICE_READ` | Query TrueNAS service status |

Add for iSCSI:

| Role | Grants |
|---|---|
| `SHARING_ISCSI_GLOBAL_READ` | Read iSCSI global config |
| `SHARING_ISCSI_TARGET_READ` | Query iSCSI targets |
| `SHARING_ISCSI_EXTENT_WRITE` | Manage extents |
| `SHARING_ISCSI_TARGETEXTENT_WRITE` | Manage target-extent mappings |

Add for NVMe/TCP:

| Role | Grants |
|---|---|
| `SHARING_NVME_TARGET_WRITE` | Manage all NVMe/TCP objects (ports, subsystems, namespaces) |

TrueNAS API keys inherit roles from their owning user's group, via an
attached Privilege object. Set this up once in the TrueNAS web UI:

1. **Create a dedicated group.** Navigate to *Credentials → Groups*
   and click *Add*. Name the group `proxmox_plugin`. Leave the other
   fields at their defaults. Save.

2. **Attach a Privilege to that group.** Navigate to *Credentials →
   Privileges* and click *Add*. Name the Privilege
   `proxmox-plugin-minimal`. In the *Local Groups* selector choose the
   `proxmox_plugin` group created in step 1. In the *Roles* selector,
   add exactly the roles listed in the two tables above (common set,
   plus the iSCSI or NVMe/TCP subset the site actually uses). Leave
   *Web Shell Access* unchecked. Save.

3. **Create a dedicated user in that group.** Navigate to *Credentials
   → Users* and click *Add*. Set *Username* to `proxmox_plugin` and
   *Full Name* to something identifying, e.g. "Proxmox VE Storage
   Plugin". In the *Primary Group* selector choose `proxmox_plugin`
   (uncheck *Create New Primary Group*). Disable password login (check
   *Disable Password* or leave the password field empty and *Lock
   User*), set *Shell* to `nologin`, and disable SMB. Save.

4. **Generate an API key for that user.** Still under *Credentials →
   Users*, edit the newly created `proxmox_plugin` user. In the *API
   Keys* section click *Add*, give the key a name such as
   `proxmox-plugin-key`, and save. **Copy the returned key value
   immediately** — TrueNAS will not display it again.

Paste the key into the file that `tn_api_key_file` in `storage.cfg`
points to (owned by root, mode `0600`). Drop the iSCSI or NVMe/TCP
role subset in step 2 if the site uses only one transport.

Caveats:

- TrueNAS roles are global, not dataset-scoped. `DATASET_WRITE` /
  `DATASET_DELETE` let the key touch any dataset on the system, not
  just the one configured in `tn_dataset`.
- `api_key.create` cannot attach roles directly to a key; the key
  inherits its user's roles through group membership + Privilege as
  shown above.
- This role set has been verified against TrueNAS SCALE 25.10.2.1.
  Re-verify against the release in use if TrueNAS changes its
  method-to-role mapping in a materially newer version.

## 4. Proxmox-Specific Configuration

### 4.1 iSCSI HA failover tuning

TrueNAS High-Availability failover interrupts the storage path for
approximately 20 to 60 seconds while the passive controller takes over
the pool. Proxmox's default open-iscsi timeouts do not survive that
window; running VMs will report I/O errors and their filesystems may
remount read-only.

Apply the following values in `/etc/iscsi/iscsid.conf` on every Proxmox
node in the cluster:

```
node.session.timeo.replacement_timeout = 280
node.conn[0].timeo.noop_out_interval   = 15
node.conn[0].timeo.noop_out_timeout    = 30
```

After the edit:

```bash
systemctl restart iscsid
iscsiadm -m session --rescan
```

These values were tested against a live TrueNAS HA pair with running
guests and are not round-number guesses. VM I/O pauses during failover
and resumes when the surviving controller takes over the LUN, with no
guest-visible I/O errors.

### 4.2 NVMe/TCP HA failover

NVMe/TCP handles path loss via native multipath and does not require
timeout tuning of the same kind. Verify path health before failover:

```bash
nvme list-subsys
```

Both paths should show as `live`. During failover one path transitions
away and the surviving path takes over transparently. After failover,
verify both paths return to `live` state before considering the failover
complete.

### 4.3 Templates and linked clones

For repeated provisioning, use Proxmox templates (`qm template`) and
linked clones (`qm clone <tpl> <new>`). The plugin implements linked
clone via ZFS-native `pool.snapshot.clone`. No data crosses the wire,
and the new VM is ready in under two seconds regardless of source disk
size.

Only linked clones from a template snapshot are offloaded. Full clones,
disk moves between storages, and backups still run host-side through
`qemu-img convert` because Proxmox has no server-side copy hook in its
storage plugin contract for those paths.

### 4.4 Snapshot coexistence with TrueNAS auto-snapshots

If TrueNAS Periodic Snapshot Tasks are configured on the same dataset
(or a parent), use distinct naming prefixes so retention policies do not
delete PVE-managed snapshots.

Recommended convention:

- TrueNAS periodic tasks: `auto-` prefix (`auto-daily-%Y-%m-%d`).
- Plugin/PVE snapshots: whatever Proxmox picks; typically `snap-*`.
- Exclude the plugin's prefix from TrueNAS retention rules.

A TrueNAS retention rule deleting a snapshot that Proxmox thinks it
owns will surface as an opaque rollback failure inside Proxmox.

### 4.5 Recommended settings summary

- Use iSCSI for general workloads, NVMe/TCP for latency-sensitive
  workloads on 25 GbE+ fabrics.
- Apply the tested iSCSI HA timeouts to every Proxmox node.
- Configure two portals on separate VLANs and enable `tn_use_multipath`.
- Isolate storage traffic on a dedicated VLAN with jumbo frames.
- Provision templates and prefer linked clones for repeated VM builds.
- Store TrueNAS API keys in `tn_api_key_file`, not inline.

### 4.6 Known Limitations

- Proxmox has no server-side copy hook in its storage plugin contract.
  Only linked clones from a template snapshot are offloaded; full
  clones, disk moves, backups, and image imports run host-side through
  `qemu-img convert` regardless of storage backend.
- Snapshot rollback is restricted to the most recent snapshot for the
  volume, matching Proxmox's built-in ZFS storage semantics. Rolling
  back to an older snapshot requires deleting the intervening
  snapshots first.
- Live storage migration between different transports (iSCSI to
  NVMe/TCP, or vice versa) is not supported. Use a full clone and
  cutover.
- SMB shares from TrueNAS are usable via Proxmox's native SMB storage
  type for ISO or backup content, but never for VM disk images.
- Volume shrinking is not supported (a ZFS restriction). Volume growth
  is fully supported.

---

## 5. Validation and Troubleshooting

The following checks should be performed after every deployment or
storage-configuration change, before handing the storage to end users.

| Test | Expected result | Common failure | Remediation |
|---|---|---|---|
| Storage status | `pvesm status --storage <id>` returns `active` with plausible `Total` / `Avail` | Storage marked `inactive` | Check broker socket exists; check TrueNAS reachability; check API key validity |
| Create + destroy 1 GB VM | Test VM allocates, boots, destroys cleanly; no orphaned zvol on TN | Zvol persists after `qm destroy` | Check plugin logs for API-side deletion errors; verify TN API key permissions |
| Snapshot + rollback | Rollback on a running VM completes without I/O error | Rollback returns "not most recent" | Delete intervening snapshots first |
| Linked clone from template | New VM ready in under two seconds; no significant wire traffic | Slow clone, gigabytes of iSCSI/NVMe traffic | Source was not a template (`qm template <id>` first); confirm volname slash-encoding via `qm config` |
| iSCSI HA failover | VM I/O pauses and resumes within `replacement_timeout` (280 s tested) | VM I/O hangs indefinitely, guest FS remounts read-only | Verify `iscsid.conf` has the tested timeout values; restart `iscsid` and rescan sessions |
| NVMe/TCP path recovery | Both paths return to `live` after a portal interruption | One path stays `inaccessible` | Restart `nvmet` on TN; check subsystem NGUID cross-check in plugin log |
| Backup to fallback storage | Backup completes to `backup-fallback-storage` | Backup fails with "storage does not support vm images" | Verify the fallback storage has `images` in its content types (or use a different storage) |

For all of the above, the plugin prefixes its log entries with
`[TrueNAS]` in the systemd journal. Increase verbosity with `tn_debug 2`
on the storage entry and restart Proxmox services to capture more
detail.

### 5.1 Common issues and remediation

| Symptom | Likely cause | Remediation |
|---|---|---|
| `pvesm status` shows the storage as `inactive` immediately after install | Broker daemon not running (socket absent) | `systemctl status truenas-plugin-broker`; if inactive, `systemctl enable --now truenas-plugin-broker`; verify `/run/truenas-plugin/broker.sock` exists |
| Every plugin call fails with `[EBUSY] Rate Limit Exceeded` from `auth.login_with_api_key` | Broker not running, or manual `.pm` copy skipped the postinst | Reinstall via the `.deb`; do not copy `TrueNASPlugin.pm` by hand |
| `authentication failed: invalid API key` | Wrong key, or key belongs to a user missing required roles | Regenerate the key and re-verify the role set from §3.8 |
| `broker: EOF before complete response` in `pvestatd` logs | Broker process was restarted mid-call | Transient; if persistent, check `journalctl -u truenas-plugin-broker` for the restart trigger |
| `storage migration failed: ... does not support vm images` (400 from PVE) | Fallback / migration target storage does not include the `images` content type | Use a target storage with `images` (e.g. `local-lvm`), or add `images` to the target's content list |
| iSCSI VM I/O hangs after a TrueNAS failover, guest filesystem remounts read-only | `iscsid.conf` timeouts too short for HA failover window | Apply the tested values in §4.1; restart `iscsid` and rescan sessions |
| Linked-clone create fails with `Device '/dev/zvol/...' does not exist` on first try, sometimes succeeds on retry | Timing race between ZFS clone and the `/dev/zvol` udev symlink | Plugin 2.1.21+ retries the specific validator error; upgrade if seen on older versions |
| Snapshot rollback fails with `not most recent snapshot` | Newer snapshots exist for the same volume | Delete the intervening snapshots first; the plugin follows the same linear-snapshot rule as the built-in ZFS storage |

For paste-ready bug reports, include the plugin version
(`dpkg -l truenas-proxmox-plugin`), the last 200 lines of
`journalctl -t pvedaemon -t pvestatd`, and the broker log at
`/var/log/truenas-plugin-broker.log`.

---

## 6. Summary Recommendations

- Install the plugin from the Debian package (APT repository preferred).
  Never copy `TrueNASPlugin.pm` by hand.
- Verify `truenas-plugin-broker` is active and its socket exists
  immediately after install and after every upgrade.
- Give each Proxmox cluster its own child dataset under a shared parent.
- Keep ZFS pool utilization below 80%. Use mirrors, or small RAIDZ
  groups, for VM disk workloads.
- Enable ZFS compression (`zstd`); leave deduplication off unless
  measurement justifies it.
- Choose iSCSI by default; move to NVMe/TCP for measurably
  latency-sensitive workloads on 25 GbE+ fabrics.
- Isolate storage on a dedicated VLAN with jumbo frames and dual
  portals.
- Apply the tested iSCSI HA timeouts on every Proxmox node.
- Use Proxmox templates plus linked clones for repeated VM provisioning.
- Store the TrueNAS API key in a root-owned `tn_api_key_file`, and grant
  the API user only the roles listed in §3.8.
- Coordinate snapshot naming with any TrueNAS Periodic Snapshot Task
  running on the same dataset.

---

_This document is proprietary and intended for internal use during the
review cycle. Upon final approval it may be exported as a PDF and
published as a customer-facing deliverable._
