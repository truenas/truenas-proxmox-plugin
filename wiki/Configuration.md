# Configuration Reference

Complete reference for all TrueNAS Proxmox VE Storage Plugin configuration parameters.

## Table of Contents

- [Configuration File](#configuration-file)
- [Required Parameters](#required-parameters)
  - [tn_api_host](#tn_api_host)
  - [tn_api_key](#tn_api_key)
  - [tn_target_iqn](#tn_target_iqn)
  - [tn_dataset](#tn_dataset)
  - [tn_discovery_portal](#tn_discovery_portal)
- [Content Type](#content-type)
  - [content](#content)
  - [shared](#shared)
  - [nodes](#nodes)
- [API Configuration](#api-configuration)
  - [tn_api_scheme](#tn_api_scheme)
  - [tn_api_port](#tn_api_port)
  - [tn_api_insecure](#tn_api_insecure)
  - [tn_api_retry_max](#tn_api_retry_max)
  - [tn_api_retry_delay](#tn_api_retry_delay)
  - [tn_storage_lock_timeout](#tn_storage_lock_timeout)
- [Network Configuration](#network-configuration)
  - [tn_prefer_ipv4](#tn_prefer_ipv4)
  - [tn_portals](#tn_portals)
  - [tn_use_multipath](#tn_use_multipath)
  - [tn_use_by_path](#tn_use_by_path)
  - [tn_ipv6_by_path](#tn_ipv6_by_path) ⚠️ not implemented
- [Transport Mode Selection](#transport-mode-selection)
  - [tn_transport_mode](#tn_transport_mode)
- [NVMe/TCP Configuration](#nvmetcp-configuration)
  - [tn_subsystem_nqn](#tn_subsystem_nqn)
  - [tn_hostnqn](#tn_hostnqn)
  - [tn_nvme_dhchap_secret](#tn_nvme_dhchap_secret)
  - [tn_nvme_dhchap_ctrl_secret](#tn_nvme_dhchap_ctrl_secret)
  - [tn_nr_io_queues](#tn_nr_io_queues)
  - [tn_nvme_ctrl_loss_tmo](#tn_nvme_ctrl_loss_tmo)
  - [tn_nvme_reconnect_delay](#tn_nvme_reconnect_delay)
  - [tn_nvme_keep_alive_tmo](#tn_nvme_keep_alive_tmo)
- [iSCSI Behavior](#iscsi-behavior)
  - [tn_force_delete_on_inuse](#tn_force_delete_on_inuse)
  - [tn_logout_on_free](#tn_logout_on_free)
- [ZFS Volume Options](#zfs-volume-options)
  - [tn_zvol_blocksize](#tn_zvol_blocksize)
  - [tn_sparse](#tn_sparse)
  - [tn_compression](#tn_compression)
- [Snapshot Configuration](#snapshot-configuration)
  - [tn_vmstate_storage](#tn_vmstate_storage) ⚠️ not implemented
  - [tn_enable_live_snapshots](#tn_enable_live_snapshots) ⚠️ not implemented
  - [tn_snapshot_volume_chains](#tn_snapshot_volume_chains) ⚠️ not implemented
- [Performance Options](#performance-options)
  - [tn_enable_bulk_operations](#tn_enable_bulk_operations)
  - [tn_device_ready_retries](#tn_device_ready_retries)
- [Security Options](#security-options)
  - [tn_chap_user](#tn_chap_user)
  - [tn_chap_password](#tn_chap_password)
- [Diagnostics](#diagnostics)
  - [tn_debug](#tn_debug)
- [Configuration Examples](#configuration-examples)
  - [Basic Single-Node Configuration (iSCSI)](#basic-single-node-configuration-iscsi)
  - [Basic NVMe/TCP Configuration](#basic-nvmetcp-configuration)
  - [Production Cluster Configuration](#production-cluster-configuration)
  - [High Availability Configuration](#high-availability-configuration)
  - [NVMe/TCP with DH-CHAP Authentication](#nvmetcp-with-dh-chap-authentication)
  - [NVMe/TCP Multipath Configuration](#nvmetcp-multipath-configuration)
  - [IPv6 Configuration](#ipv6-configuration)
  - [Development/Testing Configuration](#developmenttesting-configuration)
  - [Enterprise Production Configuration (All Features)](#enterprise-production-configuration-all-features)
- [Configuration Validation](#configuration-validation)
- [Modifying Configuration](#modifying-configuration)

---

## Configuration File

All storage configurations are stored in `/etc/pve/storage.cfg`. This file is automatically shared across all cluster nodes.

## Required Parameters

These parameters must be specified for the plugin to function:

### `tn_api_host`
**Description**: TrueNAS hostname or IP address
**Type**: String (hostname or IP)
**Example**: `192.168.1.100` or `truenas.example.com`

```ini
tn_api_host 192.168.1.100
```

### `tn_api_key`
**Description**: TrueNAS API key for authentication
**Type**: String (API key format: `1-xxx...`)
**Example**: `1-abc123def456...`

Generate in TrueNAS: **Credentials** → **Local Users** → **Edit User** → **API Key**

```ini
tn_api_key 1-your-api-key-here
```

### `tn_target_iqn`
**Description**: iSCSI target IQN (iSCSI Qualified Name)
**Type**: String (IQN format)
**Example**: `iqn.2005-10.org.freenas.ctl:proxmox`
**Required For**: iSCSI transport mode only

Configure in TrueNAS: **Shares** → **Block Shares (iSCSI)** → **Targets**

```ini
tn_target_iqn iqn.2005-10.org.freenas.ctl:proxmox
```

**Note**: When using `transport_mode nvme-tcp`, use `tn_subsystem_nqn` instead of `tn_target_iqn`.

### `tn_dataset`
**Description**: Parent ZFS dataset path for Proxmox volumes
**Type**: String (ZFS dataset path)
**Validation**: Alphanumeric, `_`, `-`, `.`, `/` only. No leading/trailing `/`, no `//`
**Example**: `tank/proxmox` or `pool1/vms/proxmox`

The plugin creates zvols as children of this dataset (e.g., `tank/proxmox/vm-100-disk-0`).

```ini
tn_dataset tank/proxmox
```

### `tn_discovery_portal`
**Description**: Primary portal for target/subsystem discovery
**Type**: String (IP:PORT format)
**Default Port**:
  - `3260` for iSCSI transport mode
  - `4420` for NVMe/TCP transport mode
**Example**:
  - iSCSI: `192.168.1.100:3260`
  - NVMe/TCP: `192.168.1.100:4420`

```ini
# iSCSI mode
tn_discovery_portal 192.168.1.100:3260

# NVMe/TCP mode
tn_discovery_portal 192.168.1.100:4420
```

## Content Type

### `content`
**Description**: Types of content this storage can hold
**Type**: Comma-separated list
**Valid Values**: `images` (VM disks)
**Default**: `images`

Currently, only `images` (VM disk images) is supported.

```ini
content images
```

### `shared`
**Description**: Whether storage is shared across cluster nodes
**Type**: Boolean (0 or 1)
**Default**: `0`
**Recommended**: `1` for clusters

Set to `1` for cluster configurations to enable VM migration and HA.

```ini
shared 1
```

### `nodes`
**Description**: Restrict storage visibility to specific cluster nodes
**Type**: String (comma-separated node hostnames)
**Default**: Empty (all nodes can access the storage)

When set, only the listed nodes will see and be able to use this storage. Omit this parameter or leave it empty to allow all cluster nodes to access the storage. Node names must match the Proxmox hostnames exactly (as shown in `/etc/pve/nodes/`).

```ini
# Restrict to two specific nodes
nodes pve01,pve02

# Allow all nodes (default - omit the line entirely)
```

## API Configuration

### `tn_api_scheme`
**Description**: API URL scheme
**Type**: String
**Valid Values**: `wss`, `ws`
**Default**: `wss`

Use `wss` in production for security.

```ini
tn_api_scheme wss
```

### `tn_api_port`
**Description**: TrueNAS API port
**Type**: Integer
**Default**: `443` for HTTPS/WSS, `80` for HTTP/WS

```ini
tn_api_port 443
```

### `tn_api_insecure`
**Description**: Skip TLS certificate verification
**Type**: Boolean (0 or 1)
**Default**: `0`
**Warning**: Only use `1` for testing with self-signed certificates

```ini
tn_api_insecure 0
```

### `tn_api_retry_max`
**Description**: Maximum number of API retry attempts
**Type**: Integer (0-10)
**Default**: `3`
**Validation**: Must be between 0 and 10

Automatic retry with exponential backoff for transient failures (network issues, rate limits).

```ini
tn_api_retry_max 5
```

### `tn_api_retry_delay`
**Description**: Initial retry delay in seconds
**Type**: Float (0.1-60.0)
**Default**: `1`
**Validation**: Must be between 0.1 and 60

Each retry doubles the delay: `delay * 2^(attempt-1)`. Example: 1s → 2s → 4s → 8s

```ini
tn_api_retry_delay 2
```

### `tn_storage_lock_timeout`
**Description**: Cluster lock timeout in seconds for storage operations
**Type**: Integer (10-600)
**Default**: `120`
**Validation**: Must be between 10 and 600 seconds

Configures the timeout for Proxmox Cluster File System (CFS) locks used during write operations. The default Proxmox timeout (10 seconds) may be insufficient for concurrent disk allocation operations, especially when multiple VMs are being created in parallel.

Increase this value for:
- Parallel VM provisioning (multiple simultaneous disk allocations)
- Bulk storage operations
- High-concurrency environments
- Slower TrueNAS backends (high latency, lower throughput)

```ini
# Default (suitable for most deployments)
tn_storage_lock_timeout 120

# Extended timeout for high-concurrency scenarios
tn_storage_lock_timeout 300
```

**Technical Details**: This property controls the timeout for `PVE::Storage::lock_storage()` calls, which serialize access to the storage configuration file during write operations. When concurrent operations exceed this timeout, they fail with a "lock timeout" error. Typical disk allocation operations take 10-15 seconds on standard hardware, so the default 120-second timeout provides ample time for 8+ concurrent operations.

## Network Configuration

### `tn_prefer_ipv4`
**Description**: Prefer IPv4 when resolving hostnames
**Type**: Boolean (0 or 1)
**Default**: `1`

Useful when TrueNAS has both IPv4 and IPv6 addresses.

```ini
tn_prefer_ipv4 1
```

### `tn_portals`
**Description**: Additional iSCSI portals for redundancy
**Type**: Comma-separated list of IP:PORT
**Example**: `192.168.1.101:3260,192.168.1.102:3260`

Configure multiple portals for failover and multipath.

**Configuration Methods**:
- **Interactive Installer (v1.1.0+)**: Automatically discovers and presents available portal IPs from TrueNAS when multipath is enabled
- **Manual**: Add comma-separated IP:port pairs to `/etc/pve/storage.cfg`

```ini
tn_portals 192.168.1.101:3260,192.168.1.102:3260
```

### `tn_use_multipath`
**Description**: Enable iSCSI multipath support
**Type**: Boolean (0 or 1)
**Default**: `1`

Requires multiple portals for redundancy and load balancing.

```ini
tn_use_multipath 1
```

### `tn_use_by_path`
**Description**: Use `/dev/disk/by-path/` device names
**Type**: Boolean (0 or 1)
**Default**: `0`

Use persistent by-path device names instead of by-id.

```ini
tn_use_by_path 0
```

### `tn_ipv6_by_path`
**Status**: ⚠️ Not currently implemented — accepted in `storage.cfg` but has no effect on plugin behavior
**Description**: Normalize IPv6 addresses in by-path device names
**Type**: Boolean (0 or 1)
**Default**: `0`

Required for IPv6 iSCSI connections when using by-path.

```ini
tn_ipv6_by_path 0
```

## Transport Mode Selection

### `tn_transport_mode`
**Description**: Storage transport protocol
**Type**: String
**Valid Values**: `iscsi`, `nvme-tcp`
**Default**: `iscsi`
**Fixed**: Yes (cannot be changed after storage creation)

Selects the protocol for communicating with TrueNAS storage:
- `iscsi`: Traditional iSCSI block storage (default, widely compatible)
- `nvme-tcp`: NVMe over TCP (lower latency, reduced CPU overhead, requires TrueNAS SCALE 25.10+)

```ini
# iSCSI mode (default)
tn_transport_mode iscsi

# NVMe/TCP mode
tn_transport_mode nvme-tcp
```

**Important Notes:**
- `tn_transport_mode` cannot be changed after storage creation (prevents volume orphaning)
- Different transport modes have different required parameters:
  - **iSCSI mode**: Requires `tn_target_iqn`, `tn_discovery_portal` (port 3260)
  - **NVMe/TCP mode**: Requires `tn_subsystem_nqn`, `tn_discovery_portal` (port 4420), TrueNAS SCALE 25.10+
- Volume naming formats differ between modes (incompatible for migration)
- See [NVMe-Setup.md](NVMe-Setup.md) for complete NVMe/TCP setup guide

**When to Use NVMe/TCP:**
- Modern infrastructure (TrueNAS SCALE 25.10+, Proxmox 9.x+)
- Performance-critical workloads (databases, high IOPS)
- Lower latency requirements
- CPU overhead reduction

**When to Use iSCSI:**
- Older infrastructure (compatibility)
- Proven stability requirements
- Existing iSCSI infrastructure

## NVMe/TCP Configuration

These parameters are only applicable when `transport_mode nvme-tcp` is set.

### `tn_subsystem_nqn`
**Description**: NVMe subsystem NQN (NVMe Qualified Name)
**Type**: String (NQN format)
**Required**: Yes (when using NVMe/TCP transport)
**Fixed**: Yes (cannot be changed after creation)
**Format**: `nqn.YYYY-MM.domain:identifier`
**Example**: `nqn.2005-10.org.freenas.ctl:proxmox-nvme`

The NVMe subsystem identifier on TrueNAS. The plugin automatically creates the subsystem if it doesn't exist.

```ini
tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
```

**Format Requirements:**
- Must start with `nqn.`
- Followed by date in `YYYY-MM` format (e.g., `2005-10`)
- Reverse domain notation (e.g., `org.freenas.ctl`)
- Colon-separated identifier (e.g., `:proxmox-nvme`)

**Validation Examples:**
```
✓ Valid:   nqn.2005-10.org.freenas.ctl:proxmox-nvme
✓ Valid:   nqn.2025-10.us.neuforth:proxmox-multipath
✗ Invalid: iqn.2005-10.org.freenas.ctl:proxmox  (wrong protocol prefix)
✗ Invalid: nqn.org.freenas.ctl:proxmox         (missing date)
```

### `tn_hostnqn`
**Description**: NVMe host NQN (initiator identifier)
**Type**: String (NQN format)
**Required**: No (auto-detected from `/etc/nvme/hostnqn`)
**Format**: Must start with `nqn.`
**Example**: `nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400`

Override the default host NQN for custom host identification. By default, the plugin reads the host NQN from `/etc/nvme/hostnqn` on the Proxmox node.

```ini
tn_hostnqn nqn.2014-08.org.nvmexpress:uuid:custom-uuid-here
```

**Use Cases:**
- Custom host identification for security policies
- Multi-host setups with specific NQN requirements
- Testing different host identities

**Default Behavior:**
If not specified, the plugin reads from:
```bash
cat /etc/nvme/hostnqn
# Example output: nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400
```

Generate a new hostnqn:
```bash
nvme gen-hostnqn > /etc/nvme/hostnqn
```

### `tn_nvme_dhchap_secret`
**Description**: DH-HMAC-CHAP host authentication secret (unidirectional)
**Type**: String
**Format**: `DHHC-1:01:base64encodeddata...`
**Required**: No (authentication is optional)
**Default**: None

Host authentication secret for authenticating the Proxmox host to the TrueNAS controller. Provides security by preventing unauthorized hosts from accessing the subsystem.

```ini
tn_nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
```

**Secret Format:**
- `DHHC-1`: DH-CHAP protocol version 1
- `01`: Hash algorithm (01 = SHA-256, 02 = SHA-384, 03 = SHA-512)
- Base64-encoded secret data

**Generate Secret:**
```bash
nvme gen-dhchap-key /dev/nvme0 --key-length=32 --hmac=1
# Output: DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
```

**Key Length Options:**
- `32` bytes (256-bit) - Recommended
- `48` bytes (384-bit)
- `64` bytes (512-bit)

**Security Notes:**
- The same secret must be configured on TrueNAS for the host NQN
- Secrets are stored in `/etc/pve/storage.cfg` (cluster-wide sync)
- See [NVMe-Setup.md - DH-CHAP Authentication](NVMe-Setup.md#dh-chap-authentication-setup) for complete setup

### `tn_nvme_dhchap_ctrl_secret`
**Description**: DH-HMAC-CHAP controller authentication secret (bidirectional)
**Type**: String
**Format**: `DHHC-1:01:base64encodeddata...`
**Required**: No (bidirectional authentication is optional)
**Default**: None

Controller authentication secret for authenticating the TrueNAS controller to the Proxmox host (mutual authentication). Prevents man-in-the-middle attacks.

```ini
tn_nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
```

**Use Cases:**
- Mutual authentication (both host and controller verify each other)
- High-security environments
- Preventing man-in-the-middle attacks

**Setup:**
1. Generate a separate controller secret (different from host secret)
2. Configure on Proxmox as `tn_nvme_dhchap_ctrl_secret`
3. Configure the same secret on TrueNAS as the controller secret

**Security Model:**
- **Unidirectional** (host secret only): Proxmox proves identity to TrueNAS
- **Bidirectional** (host + controller secrets): Both sides prove identity (recommended)

### `tn_nr_io_queues`
**Description**: Number of NVMe/TCP I/O queues per controller
**Type**: Integer
**Valid Range**: 1-256
**Default**: None (auto-detected)

When unset, the plugin auto-detects a queue count: the online CPU count when all CPUs are online, or half of the possible CPU count when any CPU is offlined (avoids kernel queue-to-CPU mapping failures on gapped CPU topologies, e.g. `EXDEV` errors). Set explicitly to override auto-detection.

```ini
tn_nr_io_queues 8
```

### `tn_nvme_ctrl_loss_tmo`
**Description**: Seconds the kernel keeps retrying a lost controller before removing it
**Type**: Integer
**Valid Range**: -1, or 1-3600 (`-1` means retry forever)
**Default**: None (kernel default of 600 applies)

Passed to `nvme connect --ctrl-loss-tmo`. Once a controller exists, the kernel — not
the plugin — is what brings a path back after an outage. With the kernel default of
600 seconds, a path whose fabric stays down for over ten minutes is removed outright
and does not return on its own.

Recommended for multi-portal setups, where silently dropping a path is worse than
retrying indefinitely:

```ini
tn_nvme_ctrl_loss_tmo -1
```

A value of `0` is rejected: it disables retries entirely, which is worse than the
default this option exists to override.

### `tn_nvme_reconnect_delay`
**Description**: Seconds between kernel reconnect attempts for a lost controller
**Type**: Integer
**Valid Range**: 1-3600
**Default**: None (kernel default of 10 applies)

Passed to `nvme connect --reconnect-delay`.

```ini
tn_nvme_reconnect_delay 5
```

### `tn_nvme_keep_alive_tmo`
**Description**: NVMe/TCP keep-alive timeout in seconds
**Type**: Integer
**Valid Range**: 1-3600
**Default**: None (kernel default applies)

Passed to `nvme connect --keep-alive-tmo`. Lower values detect a dead path sooner,
at the cost of more keep-alive traffic. At the default, a cut path takes roughly ten
seconds to move out of `live`.

```ini
tn_nvme_keep_alive_tmo 5
```

## iSCSI Behavior

### `tn_force_delete_on_inuse`
**Description**: Force target logout when deleting in-use volumes
**Type**: Boolean (0 or 1)
**Default**: `0`

When enabled, forces iSCSI target logout if volume deletion fails due to "target in use" errors.

```ini
tn_force_delete_on_inuse 1
```

### `tn_logout_on_free`
**Description**: Logout from target when no LUNs remain
**Type**: Boolean (0 or 1)
**Default**: `0`

Automatically logout from iSCSI target when all volumes are freed.

```ini
tn_logout_on_free 0
```

## ZFS Volume Options

### `tn_zvol_blocksize`
**Description**: ZFS volume block size
**Type**: String (power of 2 from 4K to 1M)
**Valid Values**: `4K`, `8K`, `16K`, `32K`, `64K`, `128K`, `256K`, `512K`, `1M`
**Default**: None (uses TrueNAS default, typically 16K)
**Recommended**: `128K` for VM workloads

Larger block sizes improve sequential I/O performance but increase space overhead.

```ini
tn_zvol_blocksize 128K
```

### `tn_sparse`
**Description**: Create sparse (thin-provisioned) volumes
**Type**: Boolean (0 or 1)
**Default**: `1`

Sparse volumes only consume space as data is written, enabling overprovisioning.

```ini
tn_sparse 1
```

### `tn_compression`
**Description**: ZFS compression algorithm for new volumes
**Type**: String
**Valid Values**: `OFF`, `LZ4`, `GZIP`, `GZIP-1`, `GZIP-9`, `ZSTD`, `ZSTD-1`, `ZSTD-3`, `ZSTD-5`, `ZSTD-7`, `ZSTD-9`, `ZLE`, `LZJB`
**Default**: None (inherits from the parent dataset)

Applied at zvol creation time. Existing volumes are unaffected by later changes to this setting.

```ini
tn_compression ZSTD
```

## Snapshot Configuration

> ⚠️ **The three options below (`tn_vmstate_storage`, `tn_enable_live_snapshots`, `tn_snapshot_volume_chains`) are not currently implemented.** They are declared in the plugin's `storage.cfg` schema (so setting them is accepted without error) but are never read anywhere in the plugin — they have no effect on runtime behavior. Live VM snapshots with vmstate are handled automatically by Proxmox core, not gated by these flags. Documented here for when/if the feature is implemented.

### `tn_vmstate_storage`
**Status**: ⚠️ Not currently implemented — accepted in `storage.cfg` but has no effect on plugin behavior
**Description**: Storage location for VM state (RAM) during live snapshots
**Type**: String
**Valid Values**: `local`, `shared`
**Default**: `local`

- `local`: Store vmstate on local Proxmox storage (better performance)
- `shared`: Store vmstate on TrueNAS storage (required for migration)

```ini
tn_vmstate_storage local
```

### `tn_enable_live_snapshots`
**Status**: ⚠️ Not currently implemented — accepted in `storage.cfg` but has no effect on plugin behavior
**Description**: Enable live VM snapshots with vmstate
**Type**: Boolean (0 or 1)
**Default**: `1`

Allows creating snapshots of running VMs including RAM state.

```ini
tn_enable_live_snapshots 1
```

### `tn_snapshot_volume_chains`
**Status**: ⚠️ Not currently implemented — accepted in `storage.cfg` but has no effect on plugin behavior
**Description**: Use volume snapshot chains (Proxmox 9+)
**Type**: Boolean (0 or 1)
**Default**: `1`

Enables Proxmox 9.x+ volume chain feature for improved snapshot management.

```ini
tn_snapshot_volume_chains 1
```

## Performance Options

### `tn_enable_bulk_operations`
**Description**: Use TrueNAS bulk API for multiple operations
**Type**: Boolean (0 or 1)
**Default**: `1`

Batch multiple API calls into single bulk request for better performance.

```ini
tn_enable_bulk_operations 1
```

### `tn_device_ready_retries`
**Description**: Number of 100ms retries waiting for a block device to appear after connect
**Type**: Integer
**Valid Range**: 0-600
**Default**: `200` (up to ~20s)

Increase on slower storage backends or high-latency networks where the block device takes longer to appear after an iSCSI login or NVMe connect.

```ini
tn_device_ready_retries 200
```

## Security Options

### `tn_chap_user`
**Description**: CHAP authentication username
**Type**: String
**Default**: None

Configure in TrueNAS: **Shares** → **Block Shares (iSCSI)** → **Authorized Access**

```ini
tn_chap_user proxmox-chap
```

### `tn_chap_password`
**Description**: CHAP authentication password
**Type**: String
**Default**: None
**Requirement**: 12-16 characters

Must match the CHAP secret configured in TrueNAS.

```ini
tn_chap_password your-secure-chap-password
```

## Diagnostics

### `tn_debug`
**Description**: Debug logging verbosity level
**Type**: Integer (0-2)
**Default**: `0`
**Validation**: Must be between 0 and 2

Enables debug logging with configurable verbosity. All log messages are prefixed with `[TrueNAS]` for easy filtering.

**Debug Levels**:
| Level | Description | Use Case |
|-------|-------------|----------|
| `0` | Errors only (always logged) | Production - minimal logging |
| `1` | Light debug - function entry points, major operations | Troubleshooting - recommended starting point |
| `2` | Verbose - full API call traces with JSON payloads | Deep diagnosis - generates significant log volume |

```ini
# Light debugging (recommended for troubleshooting)
tn_debug 1

# Verbose debugging (API payload tracing)
tn_debug 2
```

**Viewing Debug Logs**:
```bash
# Filter all plugin messages by [TrueNAS] prefix
journalctl --since '10 minutes ago' | grep '\[TrueNAS\]'

# Real-time monitoring
journalctl -f | grep '\[TrueNAS\]'
```

**Note**: Changes take effect immediately for new operations (no service restart required).

See [Troubleshooting Guide - Enable Debug Logging](Troubleshooting.md#enable-debug-logging) for detailed usage.

## Configuration Examples

### Basic Single-Node Configuration (iSCSI)
```ini
truenasplugin: truenas-basic
    tn_api_host 192.168.1.100
    tn_api_key 1-your-api-key
    tn_target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.1.100:3260
    content images
    shared 1
```

### Basic NVMe/TCP Configuration
```ini
truenasplugin: truenas-nvme
    tn_api_host 192.168.1.100
    tn_api_key 1-your-api-key
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.1.100:4420
    content images
    shared 1
```

### Production Cluster Configuration
```ini
truenasplugin: truenas-cluster
    tn_api_host 192.168.10.100
    tn_api_key 1-your-api-key
    tn_target_iqn iqn.2005-10.org.freenas.ctl:cluster
    tn_dataset tank/cluster/proxmox
    tn_discovery_portal 192.168.10.100:3260
    tn_portals 192.168.10.101:3260,192.168.10.102:3260
    content images
    shared 1
    # Performance
    tn_zvol_blocksize 128K
    tn_sparse 1
    tn_use_multipath 1
    tn_vmstate_storage local
    tn_storage_lock_timeout 120
    # Security
    tn_chap_user proxmox-cluster
    tn_chap_password your-secure-password
    # Advanced
    tn_force_delete_on_inuse 1
    tn_logout_on_free 0
    tn_api_retry_max 5
    tn_api_retry_delay 2
```

### High Availability Configuration
```ini
truenasplugin: truenas-ha
    tn_api_host truenas-vip.company.com
    tn_api_key 1-your-api-key
    tn_api_scheme wss
    tn_api_port 443
    tn_api_insecure 0
    tn_target_iqn iqn.2005-10.org.freenas.ctl:ha-cluster
    tn_dataset tank/ha/proxmox
    tn_discovery_portal 192.168.100.10:3260
    tn_portals 192.168.100.11:3260,192.168.100.12:3260,192.168.101.10:3260
    content images
    shared 1
    tn_zvol_blocksize 128K
    tn_sparse 1
    tn_use_multipath 1
    tn_vmstate_storage local
    tn_storage_lock_timeout 180
    tn_chap_user proxmox-ha
    tn_chap_password very-secure-password
    tn_force_delete_on_inuse 1
    tn_api_retry_max 5
```

### NVMe/TCP with DH-CHAP Authentication
```ini
truenasplugin: truenas-nvme-secure
    tn_api_host 192.168.10.100
    tn_api_key 1-your-api-key
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-secure
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.10.100:4420
    tn_nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    tn_nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
    tn_api_scheme wss
    tn_api_port 443
    content images
    shared 1
    tn_zvol_blocksize 64K
```

### NVMe/TCP Multipath Configuration
```ini
truenasplugin: truenas-nvme-multipath
    tn_api_host 192.168.10.100
    tn_api_key 1-your-api-key
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-ha
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.10.100:4420
    tn_portals 192.168.10.101:4420,192.168.10.102:4420
    content images
    shared 1
    tn_zvol_blocksize 128K
    tn_sparse 1
```

### IPv6 Configuration
```ini
truenasplugin: truenas-ipv6
    tn_api_host 2001:db8::100
    tn_api_key 1-your-api-key
    tn_target_iqn iqn.2005-10.org.freenas.ctl:ipv6
    tn_dataset tank/ipv6/proxmox
    tn_discovery_portal [2001:db8::100]:3260
    tn_portals [2001:db8::101]:3260,[2001:db8::102]:3260
    content images
    shared 1
    tn_prefer_ipv4 0
    tn_ipv6_by_path 1
    tn_use_by_path 1
    tn_zvol_blocksize 128K
    tn_use_multipath 1
```

### Development/Testing Configuration
```ini
truenasplugin: truenas-dev
    tn_api_host 192.168.1.50
    tn_api_key 1-dev-api-key
    tn_api_scheme ws
    tn_api_port 80
    tn_api_insecure 1
    tn_target_iqn iqn.2005-10.org.freenas.ctl:dev
    tn_dataset tank/development
    tn_discovery_portal 192.168.1.50:3260
    content images
    shared 0
    tn_zvol_blocksize 64K
    tn_sparse 1
    tn_use_multipath 0
    tn_vmstate_storage shared
```

### Enterprise Production Configuration (All Features)

Complete configuration showing all available features for enterprise production environments:

```ini
truenasplugin: enterprise-storage
    # API Configuration
    tn_api_host truenas-ha-vip.corp.com
    tn_api_key 1-production-api-key-here
    tn_api_scheme wss
    tn_api_port 443
    tn_api_insecure 0
    tn_api_retry_max 5
    tn_api_retry_delay 2
    tn_prefer_ipv4 1

    # Storage Configuration
    tn_dataset tank/production/proxmox
    tn_zvol_blocksize 128K
    tn_sparse 1
    tn_target_iqn iqn.2005-10.org.freenas.ctl:production-cluster

    # iSCSI Network Configuration
    tn_discovery_portal 10.10.100.10:3260
    tn_portals 10.10.100.11:3260,10.10.100.12:3260,10.10.101.10:3260,10.10.101.11:3260
    tn_use_multipath 1
    tn_use_by_path 0
    tn_ipv6_by_path 0

    # Security
    tn_chap_user production-proxmox
    tn_chap_password very-long-secure-chap-password-here

    # iSCSI Behavior
    tn_force_delete_on_inuse 1
    tn_logout_on_free 0

    # Cluster & HA
    content images
    shared 1

    # Snapshot Configuration
    tn_enable_live_snapshots 1
    tn_snapshot_volume_chains 1
    tn_vmstate_storage local

    # Performance Optimization
    tn_storage_lock_timeout 180
    tn_enable_bulk_operations 1
```

**Use Case**: Enterprise production environment with:
- TrueNAS HA configuration (VIP for failover)
- Secure WebSocket API transport
- 4-path multipath I/O (2 controllers × 2 networks)
- CHAP authentication for security
- Aggressive retry for HA tolerance
- Local vmstate for performance
- Bulk operations for efficiency

**Performance Tuning**: See [Advanced Features - Performance Tuning](Advanced-Features.md#performance-tuning) for detailed optimization guidance.

**Security**: See [Advanced Features - Security Configuration](Advanced-Features.md#security-configuration) for hardening recommendations.

**Clustering**: See [Advanced Features - Cluster Configuration](Advanced-Features.md#cluster-configuration) for HA setups.

## Configuration Validation

The plugin validates configuration at storage creation/modification time:

### Validation Rules
- **Required Fields**: `tn_api_host`, `tn_api_key`, `tn_dataset`, `tn_target_iqn`, `tn_discovery_portal` must be present
- **Retry Limits**: `tn_api_retry_max` must be 0-10, `tn_api_retry_delay` must be 0.1-60
- **Dataset Naming**: Must follow ZFS naming rules (alphanumeric, `_`, `-`, `.`, `/`)
- **Dataset Format**: No leading/trailing `/`, no `//`, no special characters
- **Security**: Warns if using insecure HTTP/WS transport

### Example Validation Errors
```
# Invalid retry value
tn_api_retry_max must be between 0 and 10 (got 15)

# Invalid dataset name
tn_dataset name contains invalid characters: 'tank/my storage'
  Allowed characters: a-z A-Z 0-9 _ - . /

# Missing required field
tn_api_host is required
```

## Modifying Configuration

### Edit Configuration File
```bash
# Edit storage configuration
nano /etc/pve/storage.cfg

# Changes are automatically propagated to cluster nodes
```

### Restart Services After Changes
```bash
# Restart Proxmox services to apply changes
systemctl restart pvedaemon pveproxy
```

### Verify Configuration
```bash
# Check storage status
pvesm status

# Verify storage appears and is active
pvesm list truenas-storage
```

## See Also
- [Installation Guide](Installation.md) - Initial setup instructions
- [Advanced Features](Advanced-Features.md) - Performance tuning and clustering
- [Troubleshooting](Troubleshooting.md) - Common configuration issues
- [Multi-Tenancy](Multi-Tenancy.md) - Sharing a TrueNAS system across multiple clusters
