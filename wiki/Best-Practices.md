# Best Practices

Operational guidance for running the TrueNAS Proxmox VE Storage Plugin in
production. Distilled from field experience and the external test-suite
runs against real Proxmox clusters. This document is prescriptive; where a
value is tested, the tested value is given. See the linked reference pages
for the underlying option definitions.

## Table of Contents

- [Deployment](#deployment)
  - [Install from the .deb, not by hand](#install-from-the-deb-not-by-hand)
  - [Broker daemon is required](#broker-daemon-is-required)
- [Storage Layout](#storage-layout)
  - [Dedicated dataset per PVE cluster](#dedicated-dataset-per-pve-cluster)
  - [Pool sizing](#pool-sizing)
  - [ZFS tunables](#zfs-tunables)
- [Transport Choice](#transport-choice)
  - [iSCSI vs NVMe/TCP](#iscsi-vs-nvmetcp)
- [Networking](#networking)
  - [Dedicated storage VLAN](#dedicated-storage-vlan)
  - [Jumbo frames](#jumbo-frames)
  - [Multipathing](#multipathing)
- [Reliability](#reliability)
  - [iSCSI HA failover tuning](#iscsi-ha-failover-tuning)
  - [NVMe/TCP HA failover](#nvmetcp-ha-failover)
  - [Snapshot coexistence with TrueNAS auto-snapshots](#snapshot-coexistence-with-truenas-auto-snapshots)
- [Provisioning Workflow](#provisioning-workflow)
  - [Templates and linked clones](#templates-and-linked-clones)
  - [What is offloaded, what is not](#what-is-offloaded-what-is-not)
- [Security](#security)
  - [Least-privilege TrueNAS API key](#least-privilege-truenas-api-key)
  - [DH-HMAC-CHAP for NVMe/TCP](#dh-hmac-chap-for-nvmetcp)
- [`storage.cfg` example](#storagecfg-example)
- [Validation](#validation)
- [When you have a problem](#when-you-have-a-problem)

---

## Deployment

### Install from the `.deb`, not by hand

Do not copy `TrueNASPlugin.pm` into `/usr/share/perl5/PVE/Storage/Custom/`
by hand. The Debian package's `postinst` installs the
`truenas-plugin-broker` binary and systemd unit, enables the service, and
verifies its Unix socket appears at `/run/truenas-plugin/broker.sock`.
Skipping the package means skipping the broker, and the plugin refuses to
open a direct WebSocket without it (2.1.21+ behavior; see
[Broker daemon is required](#broker-daemon-is-required)).

The [Installation Guide](Installation.md) documents both the local `.deb`
path and the official APT repository. Prefer the APT repo — it handles
upgrades atomically.

### Broker daemon is required

`truenas-plugin-broker` holds a single authenticated WebSocket per
`(host, api_key)` pair for the entire PVE node, and every plugin process
funnels its JSON-RPC calls through the Unix socket at
`/run/truenas-plugin/broker.sock`. Without the broker, every forked
`pvedaemon` / `pvestatd` / `pveproxy` worker re-authenticates via
`auth.login_with_api_key`, which TrueNAS middlewared rate-limits per source
IP. Under real test load the rate-limiter fires within seconds and
cascades into pre-flight failures across snapshot, resize, clone,
additional-disk, and backup paths (see the `test_run4` reports for the
symptom set).

Verify after install:

```bash
systemctl is-active truenas-plugin-broker
ls -l /run/truenas-plugin/broker.sock
```

The socket must exist and be `0600` in a `0700` directory. If it is
absent, `systemctl status truenas-plugin-broker` and
`journalctl -u truenas-plugin-broker -n 50` will explain why.

An escape hatch (`TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1` in the environment)
exists for developer use against a private TrueNAS. Never set it in
production.

---

## Storage Layout

### Dedicated dataset per PVE cluster

Use a distinct child dataset per Proxmox cluster (or single-node
deployment) that consumes storage. Do not point two clusters at the same
dataset unless you are deliberately exercising [Multi-Tenancy](Multi-Tenancy.md).
A shared dataset works, but reasoning about volume ownership across
clusters is harder than reasoning about ZFS quotas across siblings.

Layout example on TrueNAS:

```
tank/proxmox                   -> reserved parent (do not use directly)
tank/proxmox/prod-cluster      -> tn_dataset for the production PVE cluster
tank/proxmox/dev-cluster       -> tn_dataset for the dev PVE cluster
tank/proxmox/backup-target     -> optional; Proxmox Backup Server target
```

The plugin only enumerates volumes under the `tn_dataset` prefix it was
configured with, so an accidental cross-list between clusters is
prevented at the plugin level.

### Pool sizing

- Keep the pool below **80 %** used capacity. ZFS fragmentation and
  write-amplification climb rapidly past that mark, and the plugin's
  pre-flight refuses to allocate when the parent dataset has less
  headroom than the requested zvol.
- Use **mirrors** (or small RAIDZ groups for capacity-heavy backup
  workloads). Wide RAIDZ is not recommended for VM images because random
  small-block writes amplify against the stripe width.
- Add an **SLOG** (enterprise NVMe with PLP) if the workload is
  sync-heavy — iSCSI extents with `insecure_tpc` set default to sync
  behavior for host writes.
- **Deduplication off.** It costs RAM and rarely helps VM images. Enable
  only after measurement, on a dedicated dataset.

### ZFS tunables

For `tn_dataset` children the plugin creates:

| Property | Recommended | Why |
|---|---|---|
| `compression` | `zstd` (TrueNAS 25.10 default) | Better ratio than `lz4`; CPU cost is negligible for VM I/O |
| `volblocksize` | `16K` for general VM disks | Set via `tn_zvol_blocksize`. Match to guest FS block size when tuning |
| `sparse` | `1` (default) | Thin provisioning; set via `tn_sparse` |
| `sync` | `standard` | Use `always` only for workloads that require it, and add an SLOG |
| `atime` | `off` | Unnecessary write amplification for VM disks |

`recordsize` does not apply — the plugin creates ZFS volumes (`type=VOLUME`,
`volsize`, `volblocksize`), not filesystems.

---

## Transport Choice

### iSCSI vs NVMe/TCP

Both are supported. Pick one per storage entry via `tn_transport`.

| Aspect | iSCSI | NVMe/TCP |
|---|---|---|
| Latency | Higher (SCSI command overhead) | Lower (native NVMe queues) |
| Throughput on 25 Gb+ links | Good, may need multipath | Better with high queue count |
| Multipath | Standard `multipath-tools` (dm-mp) | Native NVMe multipath (`nvme-cli`) |
| Auth | CHAP (optional) | DH-HMAC-CHAP (optional) |
| TrueNAS support | All 25.x | Requires 25.04+ nvmet |
| Namespace identity | LUN number per extent | NGUID per namespace |
| Snapshot handling | Same via `pool.snapshot.*` | Same via `pool.snapshot.*` |
| Field maturity | Very mature | Newer; use TrueNAS 25.10 stable or later |

Default to **iSCSI** for most deployments. Move to **NVMe/TCP** when you
have measurably latency-sensitive workloads and a 25 Gb+ storage fabric.
Do not run both transports against the same dataset from the same PVE
cluster; use two datasets and two storage entries.

---

## Networking

### Dedicated storage VLAN

Isolate storage traffic on its own VLAN and bridge. Storage IO on the
shared VM bridge competes with guest traffic and produces unpredictable
latency spikes under load.

### Jumbo frames

Enable end-to-end MTU 9000 on the storage VLAN — TrueNAS interface, all
PVE storage bridges, and every switch port in between. Verify with
`ping -M do -s 8972 <truenas-ip>` from every PVE node; any fragmentation
along the path will silently degrade throughput and produce difficult-to-
diagnose stalls.

### Multipathing

Configure two portals on separate physical NICs and separate VLANs and
set `tn_use_multipath 1`. The plugin brings up both paths via
`iscsiadm -m session -R` and configures dm-mp. For NVMe/TCP, `nvme-cli`
native multipath is used; no additional config required.

Portal list example:

```
tn_portals 10.10.10.68:3260,10.10.11.68:3260
```

---

## Reliability

### iSCSI HA failover tuning

TrueNAS HA failover interrupts the storage path for ~20–60 s. PVE's
default iSCSI initiator timeouts do not survive that. Apply the tested
values in `/etc/iscsi/iscsid.conf` on every PVE node:

```
node.session.timeo.replacement_timeout = 280
node.conn[0].timeo.noop_out_interval   = 15
node.conn[0].timeo.noop_out_timeout    = 30
```

After the edit, restart `iscsid` and re-login: `systemctl restart iscsid
&& iscsiadm -m session --rescan`. VM I/O will pause during failover and
resume when the surviving controller takes over the LUN.

These values were tested against a live TrueNAS HA pair with running
guests; they are not round-number guesses. See
[Testing Guide](Testing.md#ha-failover-test) for the reproducer.

### NVMe/TCP HA failover

NVMe/TCP handles path loss via native multipath. Verify with:

```
nvme list-subsys
```

Both paths must show as `live` before failover; after failover, the
surviving path stays `live` and the guest sees no I/O error at kernel
level.

Kernel NGUID must match TrueNAS-reported NGUID; the plugin cross-checks
this on the stale-recovery path to prevent writing to the wrong device
if a compromised or misbehaving TrueNAS ever returns a duplicate NGUID.

### Snapshot coexistence with TrueNAS auto-snapshots

The plugin creates snapshots on demand via `pool.snapshot.create` with
names PVE picks (`snap-*` or the user-provided `snapshot` name). If you
configure TrueNAS Periodic Snapshot Tasks on the same `tn_dataset` (or
its parents), use a distinct naming prefix and configure the task to
skip plugin-managed snapshots.

Suggested convention:

- TrueNAS periodic tasks: prefix `auto-` (e.g. `auto-daily-%Y-%m-%d`)
- Plugin/PVE snapshots: whatever PVE picks; typically `snap-*`
- Retention: exclude `snap-*` from TrueNAS retention policy

Do not let TrueNAS retention delete a snapshot that PVE thinks it owns —
it will surface as a rollback failure inside PVE.

---

## Provisioning Workflow

### Templates and linked clones

For repeated VM provisioning, always create a template (`qm template`)
and use linked clones (`qm clone <tpl> <new>`). The plugin implements
this via ZFS-native `pool.snapshot.clone`: no data crosses the wire, and
the new VM is ready in under two seconds regardless of source size.

Full clone (`qm clone --full`) and disk move (`qm move_disk` between
storages) run host-side through `qemu-img convert` and are subject to
network bandwidth.

### What is offloaded, what is not

Proxmox has no server-side copy hook in its storage plugin contract.
Only linked clones from a template snapshot are offloaded.

| Operation | Where the data moves |
|---|---|
| `qm clone <tpl> <new>` (linked, from template) | Server-side ZFS clone — nothing over the wire |
| `qm snapshot` / `qm delsnapshot` / `qm rollback` | Server-side ZFS op — nothing over the wire |
| `qm clone --full` | Host-side `qemu-img convert` |
| `qm move_disk` between storages | Host-side copy |
| `vzdump` backup | Host-side read of the LUN |
| `qm importdisk` | Host-side write of the LUN |

---

## Security

### Least-privilege TrueNAS API key

Do not give the plugin's API key `Full Admin`. See
[API Permissions](API-Permissions.md) for the audited, method-by-method
minimum role set. The plugin's audit is what the file records; do not
grant beyond it.

Store the API key via `tn_api_key_file` (a path readable only by
`root:root`) instead of inline `tn_api_key` in `storage.cfg`. The latter
is world-readable to `www-data` on a stock PVE install.

### DH-HMAC-CHAP for NVMe/TCP

When enabling authentication for NVMe/TCP, DH-HMAC-CHAP is preferred
over unauthenticated allow-any-host. Configure via `tn_nvme_dhchap_secret`
and, for bidirectional, `tn_nvme_dhchap_ctrl_secret`.

**Security note (2026-06 review):** the current plugin passes DH-HMAC-CHAP
secrets on the `nvme connect` argv, which is visible via
`/proc/<pid>/cmdline` to unprivileged local users on the PVE node and
persists in `syslog` on any transient connect failure. Track / plan for
the fix documented in `wiki/Security-Review-2026-06.md` if the secret
value is treated as sensitive in your threat model.

---

## `storage.cfg` example

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

Full parameter reference: [Configuration.md](Configuration.md).

---

## Validation

After deploying (or changing) a storage entry, run at minimum:

1. `pvesm status --storage <id>` — must return `active` with a plausible
   `Total` / `Avail`.
2. Create + destroy a 1 GB test VM. Verify no orphaned zvol on TN after
   destroy (`zfs list -r <tn_dataset>` should return only expected volumes).
3. Take + roll back a snapshot on a running VM.
4. Create a template, linked-clone it, verify the clone is <2 s and the
   `zfs list` clone hierarchy matches.
5. For HA: pull a portal cable (or block its IP) and verify VM I/O
   pauses then resumes within `replacement_timeout`.

The full external test-runner suite (`proxmox-test-runner
storage-plugin-validation`) exercises 23 capabilities per iteration; see
[Testing.md](Testing.md).

---

## When you have a problem

- Start with [Troubleshooting.md](Troubleshooting.md).
- Check `journalctl -u truenas-plugin-broker` for broker-level errors.
- Check `journalctl -t pvedaemon -t pvestatd` for `[TrueNAS]` log
  entries; the plugin prefixes all its own messages.
- Increase verbosity: add `tn_debug 2` to the storage stanza and
  restart PVE services.
- For paste-ready bug reports use the `truenas-pve-bugreport` skill /
  bundle path documented in [Troubleshooting.md](Troubleshooting.md).
