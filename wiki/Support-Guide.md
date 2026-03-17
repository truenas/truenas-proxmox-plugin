# TrueNAS Proxmox VE Storage Plugin — Support Guide

**Audience**: TrueNAS Support team
**Plugin Version**: 2.0.x
**Last Updated**: 2026-03-10

---

## Table of Contents

1. [What This Plugin Does](#1-what-this-plugin-does)
2. [How It Works (Architecture Overview)](#2-how-it-works-architecture-overview)
3. [Requirements](#3-requirements)
4. [Installation](#4-installation)
5. [Configuration Reference](#5-configuration-reference)
6. [Storage Concepts for Support Staff](#6-storage-concepts-for-support-staff)
7. [Common Support Scenarios](#7-common-support-scenarios)
8. [Log Files and Diagnostics](#8-log-files-and-diagnostics)
9. [Known Limitations](#9-known-limitations)
10. [Escalation Checklist](#10-escalation-checklist)

---

## 1. What This Plugin Does

The TrueNAS Proxmox VE Storage Plugin lets a **Proxmox VE hypervisor** use **TrueNAS** as a block storage backend for virtual machine disks. Without this plugin, customers must configure iSCSI or NVMe storage manually; with it, Proxmox can create, delete, resize, and snapshot VM disks on TrueNAS automatically.

From a customer's perspective, TrueNAS appears as a storage pool in the Proxmox web interface. When they create a VM and add a disk, the plugin:

1. Creates a ZFS volume (zvol) on TrueNAS under the configured dataset
2. Exposes that zvol as a block device via iSCSI or NVMe/TCP
3. Connects the Proxmox node to that block device
4. Returns the device path to Proxmox to attach to the VM

When the VM disk is deleted, the plugin reverses this process.

**What it does NOT do:**
- Proxmox Backup Server (PBS) integration — snapshots only, no backup agent
- File/NFS/CIFS storage — block storage only (VM disk images)
- Container storage — VM images only, not CT templates or ISOs

---

## 2. How It Works (Architecture Overview)

### Communication

The plugin communicates with TrueNAS exclusively over the **WebSocket API** (JSON-RPC over WebSocket). The REST API is not used. The connection goes to port 443 (HTTPS/WSS) or 80 (HTTP/WS) on the TrueNAS host.

```
Proxmox Node
  └── Plugin (Perl) ──WSS/WS──> TrueNAS API (port 443)
                                     └── Creates/manages zvols, iSCSI/NVMe targets
  └── iSCSI initiator ──TCP:3260──> TrueNAS iSCSI service
       OR
  └── NVMe/TCP initiator ──TCP:4420──> TrueNAS NVMe-oF service
```

The plugin uses two types of connections:
- **Persistent connection** — reused for read-only API queries (disk listings, status checks)
- **Ephemeral connection** — new connection for each write operation (volume create/delete) to prevent race conditions

### Transport Modes

| Mode | Protocol | Port | Use Case |
|------|----------|------|----------|
| `iscsi` | iSCSI over TCP | 3260 | Broader compatibility, Proxmox 8+, TrueNAS 25.10+ |
| `nvme-tcp` | NVMe/TCP | 4420 | Lower latency, Proxmox 9+, TrueNAS 25.10+ |

### Volume Naming

The plugin names volumes with a predictable scheme:

| Object | Example Name |
|--------|-------------|
| ZFS zvol | `tank/proxmox/vm-100-disk-0` |
| iSCSI extent | `vm-100-disk-0` |
| NVMe namespace | `vol-vm-100-disk-0-ns<UUID>` |

This naming is how you can cross-reference Proxmox storage objects with TrueNAS zvols and iSCSI/NVMe configuration.

---

## 3. Requirements

### TrueNAS Side

| Requirement | Details |
|-------------|---------|
| TrueNAS version | **25.10 or later** (WebSocket API required) |
| Storage | ZFS pool with a dataset dedicated to Proxmox volumes |
| iSCSI service | Must be enabled and an iSCSI target/portal must be pre-configured (iSCSI mode) |
| NVMe-oF service | Must be enabled (NVMe/TCP mode) |
| API key | Generated under Credentials → API Keys. The key must have permission to manage the dataset and iSCSI/NVMe targets. |

### Proxmox Side

| Requirement | Details |
|-------------|---------|
| Proxmox VE version | 8.x or 9.x (9.x recommended for NVMe/TCP) |
| Plugin file | `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` |
| Package: `open-iscsi` | Required for iSCSI mode |
| Package: `multipath-tools` | Required for iSCSI multipath (optional but recommended) |
| Package: `nvme-cli` | **Required** for NVMe/TCP mode |
| Network | Connectivity from Proxmox to TrueNAS on port 443 (API), 3260 (iSCSI), or 4420 (NVMe/TCP) |

### Minimum TrueNAS Pre-Configuration (iSCSI Mode)

Before the plugin can work, the customer must have already created in TrueNAS:
1. A ZFS dataset (e.g., `tank/proxmox`)
2. An iSCSI portal with the storage network IP
3. An iSCSI target (the plugin will add extents/LUNs automatically)
4. The iSCSI service enabled

For NVMe/TCP mode, the NVMe-oF target service must be enabled. The plugin creates subsystems automatically.

---

## 4. Installation

### Recommended Method: APT Repository

This is the method to recommend for production. It installs the plugin as a managed Debian package and enables automatic updates.

```bash
# Run on each Proxmox node (as root)
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh) \
  --non-interactive --apt-install
```

After installation, the plugin file is at:
```
/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

### Alternative: Interactive Installer

For customers who want a guided setup with configuration wizard and validation:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh)
```

This provides:
- Dependency checks
- Plugin syntax validation
- Optional configuration wizard
- 12-point health check after installation
- Plugin function testing (8 core tests)
- Automatic backup of existing plugin before update

### Manual Installation

If the customer cannot reach GitHub:

```bash
# Copy TrueNASPlugin.pm to the node, then:
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm  # verify syntax
systemctl restart pvedaemon pveproxy
```

### Cluster Installations

In a Proxmox cluster, the plugin file must be installed on **every node**. The storage configuration (`/etc/pve/storage.cfg`) is automatically shared by Proxmox across all nodes. The installer can detect and install across cluster nodes when run interactively.

---

## 5. Configuration Reference

Storage is configured in `/etc/pve/storage.cfg` on any cluster node (changes replicate automatically). The entry uses the type `truenasplugin`.

### Minimal iSCSI Configuration

```ini
truenasplugin: my-truenas
    api_host 192.168.10.50
    api_key 1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    dataset tank/proxmox
    transport_mode iscsi
    discovery_portal 192.168.10.50:3260
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox-target
    content images
    shared 1
```

### Minimal NVMe/TCP Configuration

```ini
truenasplugin: my-truenas-nvme
    api_host 192.168.10.50
    api_key 1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    dataset tank/proxmox
    transport_mode nvme-tcp
    discovery_portal 192.168.10.50:4420
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    content images
    shared 1
```

### All Configuration Parameters

#### Required

| Parameter | Description | Example |
|-----------|-------------|---------|
| `api_host` | TrueNAS hostname or IP | `192.168.10.50` |
| `api_key` | TrueNAS API key | `1-abc123...` |
| `dataset` | ZFS dataset path for volumes | `tank/proxmox` |
| `transport_mode` | `iscsi` or `nvme-tcp` | `iscsi` |
| `discovery_portal` | IP:port for target discovery | `192.168.10.50:3260` |
| `target_iqn` | iSCSI target IQN *(iSCSI mode only)* | `iqn.2005-10.org.freenas.ctl:target1` |
| `subsystem_nqn` | NVMe subsystem NQN *(NVMe/TCP mode only)* | `nqn.2005-10.org.freenas.ctl:nvme1` |

#### Connection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `api_scheme` | `wss` | `wss` (TLS) or `ws` (plain) |
| `api_port` | `443` (wss) / `80` (ws) | TrueNAS API port |
| `api_insecure` | `0` | Set to `1` to skip TLS certificate verification (self-signed certs) |
| `prefer_ipv4` | `1` | Prefer IPv4 when resolving hostnames |

#### iSCSI Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `portals` | *(none)* | Additional portal IPs for multipath (comma-separated) |
| `use_multipath` | `1` | Enable dm-multipath |
| `use_by_path` | `0` | Use `/dev/disk/by-path/` device names (more stable in some environments) |
| `chap_user` | *(none)* | CHAP username for authentication |
| `chap_password` | *(none)* | CHAP password |
| `force_delete_on_inuse` | `0` | Temporarily logout target to force-delete in-use volumes |
| `logout_on_free` | `0` | Logout target after delete if no LUNs remain |

#### NVMe/TCP Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nvme_dhchap_secret` | *(none)* | Host DH-HMAC-CHAP key (`DHHC-1:01:...`) |
| `nvme_dhchap_ctrl_secret` | *(none)* | Controller key for bidirectional auth |

#### ZFS / Volume Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `tn_sparse` | `1` | Thin-provisioned (sparse) zvols |
| `zvol_blocksize` | *(system default)* | ZFS block size: `16K`, `64K`, `128K`, `256K` |
| `enable_live_snapshots` | `1` | Allow live snapshots (includes VM RAM state) |
| `snapshot_volume_chains` | `1` | Use volume chains for snapshots |
| `vmstate_storage` | `local` | Where to store VM state: `shared` or `local` |

#### API Behavior

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `api_retry_max` | `3` | 0–10 | Max retries for transient API errors |
| `api_retry_delay` | `1` | 0.1–60 | Initial retry delay in seconds (exponential backoff) |
| `storage_lock_timeout` | `120` | 10–600 | Cluster lock timeout in seconds |
| `enable_bulk_operations` | `1` | — | Use `core.bulk` for batch API calls |
| `debug` | `0` | 0–2 | Debug logging level (0=off, 1=operations, 2=verbose) |

---

## 6. Storage Concepts for Support Staff

### ZFS Zvols

Every VM disk corresponds to one ZFS zvol on TrueNAS. When a customer reports a missing disk or storage inconsistency, checking whether the zvol exists on TrueNAS is the first diagnostic step.

**Where to look**: TrueNAS UI → Datasets → navigate to the configured dataset (e.g., `tank/proxmox`) → child zvols.

Names follow the pattern `vm-<VMID>-disk-<N>` (e.g., `vm-100-disk-0`).

### iSCSI Extents and Target-Extent Mappings

In iSCSI mode, each zvol has a corresponding iSCSI extent, and that extent is mapped to the configured target. These are managed automatically by the plugin but can be viewed in TrueNAS UI → Shares → iSCSI.

If a zvol exists but its extent or target-extent mapping is missing, the Proxmox node will not be able to access the disk.

### NVMe Namespaces

In NVMe/TCP mode, each zvol is exposed as an NVMe namespace on the configured subsystem. These can be viewed in TrueNAS UI → Shares → NVMe-oF.

### Snapshots

Plugin snapshots are ZFS snapshots, not separate volumes. They appear under the zvol in the TrueNAS dataset tree (zvol@snapshotname). They cannot be used with Proxmox Backup Server — they are only accessible via Proxmox VM snapshot tools (`qm snapshot`).

### `shared = 1`

This Proxmox setting tells Proxmox that all cluster nodes can access this storage simultaneously. It must be set for VM live migration to work. The plugin handles per-node connections independently.

---

## 7. Common Support Scenarios

### Storage Shows as Inactive in Proxmox

**Symptom**: Storage entry appears in Proxmox but shows as unavailable/inactive.

**Steps**:

1. Check API connectivity:
   ```bash
   # On the Proxmox node
   curl -sk https://<truenas-ip>/api/v2.0/system/info | head -1
   ```
   Should return JSON. If it hangs or errors, it's a network/firewall issue.

2. Verify the API key is valid in TrueNAS (Credentials → API Keys).

3. If using a self-signed TLS certificate, check that `api_insecure 1` is set.

4. Check Proxmox service logs:
   ```bash
   journalctl -u pvedaemon --since "1 hour ago" | grep -i truenas
   ```

5. Restart Proxmox storage services:
   ```bash
   systemctl restart pvedaemon pveproxy
   ```

---

### "Could not connect to TrueNAS API"

**Cause**: WebSocket connection to TrueNAS API failed.

**Checklist**:
- Is TrueNAS reachable from the Proxmox node on port 443 (or configured `api_port`)?
- Is the TrueNAS web UI accessible at all from that IP?
- Is `api_host` the management IP, not a storage-only IP?
- Does the API key exist and is it not expired?
- If using `api_insecure 0` (default), is the TLS certificate valid? Try setting `api_insecure 1` to test.

---

### "Could not discover iSCSI targets"

**Cause**: The Proxmox node's iSCSI initiator could not perform SendTargets discovery against the configured portal.

**Checklist**:
- Is `discovery_portal` correct (IP:port, e.g., `192.168.10.50:3260`)?
- Is the TrueNAS iSCSI service running?
- Is the portal IP bound to the iSCSI portal in TrueNAS (Shares → iSCSI → Portals)?
- Is there a firewall blocking port 3260 between the Proxmox node and TrueNAS?
- Can the node reach TrueNAS on port 3260?
  ```bash
  nc -zv 192.168.10.50 3260
  ```
- Is the `open-iscsi` package installed on the Proxmox node?

---

### "Could not resolve iSCSI target ID for configured IQN"

**Cause**: The plugin discovered targets but none matched the configured `target_iqn`.

**Fix**: In TrueNAS UI → Shares → iSCSI → Targets, verify the exact IQN. Copy it exactly into `target_iqn` in `storage.cfg`. IQNs are case-sensitive.

---

### nvme-cli is not installed

**Cause**: NVMe/TCP mode requires `nvme-cli` on the Proxmox node.

**Fix**:
```bash
apt install nvme-cli
```
Run on every Proxmox node in the cluster.

---

### Volume Created but VM Disk Not Accessible

**Symptom**: Proxmox created a disk but the VM cannot start because the block device isn't found.

**Steps**:
1. Verify the zvol exists in TrueNAS (Datasets → navigate to `tank/proxmox`).
2. In iSCSI mode: verify an extent was created (Shares → iSCSI → Extents) and it's mapped to the target (Target/Extents tab).
3. On the Proxmox node, check if the iSCSI session is active:
   ```bash
   iscsiadm -m session
   ```
4. Check if the device is visible:
   ```bash
   lsblk | grep -i iscsi
   # or for NVMe:
   nvme list
   ```
5. Rescan storage targets manually:
   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.10.50:3260
   iscsiadm -m node --login
   ```

---

### Orphaned Volumes After VM Deletion

**Symptom**: A VM was deleted but zvols and iSCSI extents remain on TrueNAS.

**Cause**: This happens when a VM is deleted via `qm destroy` (CLI) instead of through the Proxmox web UI. The CLI command does not invoke plugin cleanup methods.

**Impact**: Orphaned resources consume storage and iSCSI LUN slots.

**Workaround**: Delete the orphaned resources manually:
1. In TrueNAS, remove the target-extent mapping (Shares → iSCSI → Target/Extents)
2. Delete the extent (Shares → iSCSI → Extents)
3. Delete the zvol (Datasets)

The installer's health check (`./install.sh` → Health Check) includes an orphan detection scan.

**Prevention**: Always delete VMs through the Proxmox web UI, not via `qm destroy`.

---

### Snapshot Fails or Rollback Fails

**Snapshot creation failure checklist**:
- Is there enough free space on the TrueNAS pool? ZFS snapshots need available pool space to be created.
- Is `enable_live_snapshots 1` set if the customer is taking live snapshots?

**Rollback failure checklist**:
- Is the VM stopped or suspended before rollback?
- Is there a snapshot that was taken while the disk was in an inconsistent state?
- Check the Proxmox node logs for the specific API error returned from TrueNAS.

---

### VM Live Migration Fails

**Checklist**:
- Is `shared 1` set on the storage definition?
- Is the plugin installed on the destination node?
- Does the destination node have network access to TrueNAS on the storage network?
- In iSCSI mode: can both nodes log in to the same iSCSI target simultaneously?
- If using `use_multipath 1`, is `multipath-tools` installed on both nodes?

---

### Slow Performance

**For iSCSI**:
- Verify the storage traffic uses a dedicated network, not the management network.
- Check if multipath is active: `multipath -ll`
- If multipath shows paths degraded, check switch/cable redundancy.
- Jumbo frames (MTU 9000) on both Proxmox and TrueNAS interfaces improve throughput.

**For NVMe/TCP**:
- Verify kernel NVMe multipath is enabled: `cat /sys/module/nvme_core/parameters/multipath` should be `Y`.
- NVMe/TCP latency is sensitive to CPU power state; ensure performance governor is active on both hosts.

**General**:
- `zvol_blocksize 64K` or `128K` is typically better for sequential workloads (databases).
- Thin provisioning (`tn_sparse 1`) is the default; for I/O-intensive VMs consider `tn_sparse 0` to pre-allocate.

---

### API Rate Limiting

**Symptom**: Errors mentioning rate limiting, 429 status, or slow API responses under heavy load.

**Explanation**: TrueNAS API has rate limits. The plugin automatically retries with exponential backoff.

**Tuning**:
```ini
api_retry_max 5
api_retry_delay 2
```
Increasing both values gives the plugin more time to recover from transient rate limit events.

---

## 8. Log Files and Diagnostics

### Proxmox Logs

```bash
# Plugin activity (primary diagnostic source)
journalctl -u pvedaemon -f

# Filter for plugin entries
journalctl -u pvedaemon | grep -i truenasplugin

# All storage-related errors
journalctl -u pvedaemon | grep -i "storage\|zvol\|iscsi\|nvme"
```

### TrueNAS Logs

In TrueNAS UI → System → Advanced → Logs, or via SSH:
```bash
tail -f /var/log/middlewared.log
```

Look for WebSocket authentication events and API call errors.

### Enable Plugin Debug Logging

Add to `storage.cfg` for the storage definition:
```ini
debug 1   # operation-level logging
debug 2   # verbose API request/response logging
```

Then restart Proxmox services:
```bash
systemctl restart pvedaemon pveproxy
```

Debug output appears in `journalctl -u pvedaemon`.

> **Note**: `debug 2` is very verbose. Disable after capturing the needed information.

### Installer Health Check

The installer includes a 12-point validation that tests:
- Plugin file presence and syntax
- API connectivity and authentication
- iSCSI or NVMe session status
- Multipath configuration
- Orphaned resource detection
- Dataset accessibility
- Portal connectivity
- Required packages

Run it with:
```bash
./install.sh
# Select: Diagnostics → Run Health Check
```

### Proxmox Storage Status Command

```bash
pvesm status
pvesm list <storage-name>
```

These commands invoke the plugin and will surface errors inline.

---

## 9. Known Limitations

| Limitation | Detail |
|-----------|--------|
| **TrueNAS 25.10+ required** | The plugin uses the WebSocket API exclusively. TrueNAS versions before 25.10 are not supported. |
| **VM images only** | The plugin stores VM disk images only. It does not support ISOs, CT templates, backups, or snippets. |
| **No Proxmox Backup Server integration** | Plugin snapshots are ZFS-level snapshots, not PBS backups. Use a separate storage pool for PBS. |
| **No volume shrinking** | ZFS zvols cannot be shrunk. Only disk resize (grow) is supported. |
| **No fast clone at creation** | Linked clones are not supported. VM clones require a full data copy. |
| **GUI deletion required** | Deleting VMs with `qm destroy` (CLI) does not clean up TrueNAS resources. Use the Proxmox web UI. |
| **Proxmox 9 required for NVMe/TCP** | NVMe/TCP transport mode requires Proxmox VE 9.x or later. |
| **API key stored in plain text** | The API key is stored in `/etc/pve/storage.cfg`. Ensure the file permissions are appropriate (Proxmox manages this). |
| **iSCSI mutual CHAP not supported** | Only one-way CHAP is supported (initiator authenticates to target). |
| **No storage overcommit protection** | The plugin does not prevent over-provisioning. Thin-provisioned zvols can consume more pool space than allocated if not monitored. |

---

## 10. Escalation Checklist

Before escalating a ticket, collect the following from the customer:

### Environment Information
- [ ] TrueNAS version (`System → General → About`)
- [ ] Proxmox VE version (`pveversion -v`)
- [ ] Plugin version (check top of `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`, or `pvesm status`)
- [ ] Transport mode (`iscsi` or `nvme-tcp`)
- [ ] Whether this is a cluster or single node

### Configuration
- [ ] Redacted `storage.cfg` entry (remove `api_key` before sharing)
- [ ] TrueNAS iSCSI or NVMe-oF target/portal configuration
- [ ] Network layout: are the API, storage, and management networks the same or separate?

### Logs
- [ ] `journalctl -u pvedaemon --since "2 hours ago" | grep -i truenas` output
- [ ] `journalctl -u pvedaemon --since "2 hours ago" | grep -iE "error|warn"` output
- [ ] Output of `pvesm status`
- [ ] Output of `pvesm list <storage-name>` (if storage is accessible)
- [ ] TrueNAS middleware log entries around the time of the failure

### Diagnostic Tests (if customer can run them)
- [ ] Output of `./install.sh` health check
- [ ] Output of `iscsiadm -m session` (iSCSI mode)
- [ ] Output of `nvme list` and `nvme list-subsys` (NVMe/TCP mode)
- [ ] Output of `multipath -ll` (iSCSI multipath mode)

### For Volume/Data Issues
- [ ] VMID and disk name involved
- [ ] Whether the zvol is present in TrueNAS datasets
- [ ] Whether the iSCSI extent/NVMe namespace still exists
- [ ] Whether the issue is consistent or intermittent
