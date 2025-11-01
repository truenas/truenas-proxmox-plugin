# Configuration Reference

Complete reference for all TrueNAS Proxmox VE Storage Plugin configuration parameters.

## Table of Contents

- [Configuration File](#configuration-file)
- [Required Parameters](#required-parameters)
  - [api_host](#api_host)
  - [api_key](#api_key)
  - [target_iqn](#target_iqn)
  - [dataset](#dataset)
  - [discovery_portal](#discovery_portal)
- [Content Type](#content-type)
  - [content](#content)
  - [shared](#shared)
- [API Configuration](#api-configuration)
  - [api_transport](#api_transport)
  - [api_scheme](#api_scheme)
  - [api_port](#api_port)
  - [api_insecure](#api_insecure)
  - [api_retry_max](#api_retry_max)
  - [api_retry_delay](#api_retry_delay)
- [Network Configuration](#network-configuration)
  - [prefer_ipv4](#prefer_ipv4)
  - [portals](#portals)
  - [use_multipath](#use_multipath)
  - [use_by_path](#use_by_path)
  - [ipv6_by_path](#ipv6_by_path)
- [Transport Mode Selection](#transport-mode-selection)
  - [transport_mode](#transport_mode)
- [NVMe/TCP Configuration](#nvmetcp-configuration)
  - [subsystem_nqn](#subsystem_nqn)
  - [hostnqn](#hostnqn)
  - [nvme_dhchap_secret](#nvme_dhchap_secret)
  - [nvme_dhchap_ctrl_secret](#nvme_dhchap_ctrl_secret)
- [iSCSI Behavior](#iscsi-behavior)
  - [force_delete_on_inuse](#force_delete_on_inuse)
  - [logout_on_free](#logout_on_free)
- [ZFS Volume Options](#zfs-volume-options)
  - [zvol_blocksize](#zvol_blocksize)
  - [tn_sparse](#tn_sparse)
- [Snapshot Configuration](#snapshot-configuration)
  - [vmstate_storage](#vmstate_storage)
  - [enable_live_snapshots](#enable_live_snapshots)
  - [snapshot_volume_chains](#snapshot_volume_chains)
- [Performance Options](#performance-options)
  - [enable_bulk_operations](#enable_bulk_operations)
- [Security Options](#security-options)
  - [chap_user](#chap_user)
  - [chap_password](#chap_password)
- [Configuration Examples](#configuration-examples)
  - [Basic Single-Node Configuration](#basic-single-node-configuration)
  - [Production Cluster Configuration](#production-cluster-configuration)
  - [High Availability Configuration](#high-availability-configuration)
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

### `api_host`
**Description**: TrueNAS hostname or IP address
**Type**: String (hostname or IP)
**Example**: `192.168.1.100` or `truenas.example.com`

```ini
api_host 192.168.1.100
```

### `api_key`
**Description**: TrueNAS API key for authentication
**Type**: String (API key format: `1-xxx...`)
**Example**: `1-abc123def456...`

Generate in TrueNAS: **Credentials** → **Local Users** → **Edit User** → **API Key**

```ini
api_key 1-your-api-key-here
```

### `target_iqn`
**Description**: iSCSI target IQN (iSCSI Qualified Name)
**Type**: String (IQN format)
**Example**: `iqn.2005-10.org.freenas.ctl:proxmox`
**Required For**: iSCSI transport mode only

Configure in TrueNAS: **Shares** → **Block Shares (iSCSI)** → **Targets**

```ini
target_iqn iqn.2005-10.org.freenas.ctl:proxmox
```

**Note**: When using `transport_mode nvme-tcp`, use `subsystem_nqn` instead of `target_iqn`.

### `dataset`
**Description**: Parent ZFS dataset path for Proxmox volumes
**Type**: String (ZFS dataset path)
**Validation**: Alphanumeric, `_`, `-`, `.`, `/` only. No leading/trailing `/`, no `//`
**Example**: `tank/proxmox` or `pool1/vms/proxmox`

The plugin creates zvols as children of this dataset (e.g., `tank/proxmox/vm-100-disk-0`).

```ini
dataset tank/proxmox
```

### `discovery_portal`
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
discovery_portal 192.168.1.100:3260

# NVMe/TCP mode
discovery_portal 192.168.1.100:4420
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

## API Configuration

### `api_transport`
**Description**: API transport protocol
**Type**: String
**Valid Values**: `ws` (WebSocket), `rest` (HTTP REST)
**Default**: `ws`

WebSocket is recommended for better performance and persistent connections.

```ini
api_transport ws
```

### `api_scheme`
**Description**: API URL scheme
**Type**: String
**Valid Values**: `wss`, `ws`, `https`, `http`
**Default**: `wss` for WebSocket transport, `https` for REST

Use `wss`/`https` in production for security.

```ini
api_scheme wss
```

### `api_port`
**Description**: TrueNAS API port
**Type**: Integer
**Default**: `443` for HTTPS/WSS, `80` for HTTP/WS

```ini
api_port 443
```

### `api_insecure`
**Description**: Skip TLS certificate verification
**Type**: Boolean (0 or 1)
**Default**: `0`
**Warning**: Only use `1` for testing with self-signed certificates

```ini
api_insecure 0
```

### `api_retry_max`
**Description**: Maximum number of API retry attempts
**Type**: Integer (0-10)
**Default**: `3`
**Validation**: Must be between 0 and 10

Automatic retry with exponential backoff for transient failures (network issues, rate limits).

```ini
api_retry_max 5
```

### `api_retry_delay`
**Description**: Initial retry delay in seconds
**Type**: Float (0.1-60.0)
**Default**: `1`
**Validation**: Must be between 0.1 and 60

Each retry doubles the delay: `delay * 2^(attempt-1)`. Example: 1s → 2s → 4s → 8s

```ini
api_retry_delay 2
```

## Network Configuration

### `prefer_ipv4`
**Description**: Prefer IPv4 when resolving hostnames
**Type**: Boolean (0 or 1)
**Default**: `1`

Useful when TrueNAS has both IPv4 and IPv6 addresses.

```ini
prefer_ipv4 1
```

### `portals`
**Description**: Additional iSCSI portals for redundancy
**Type**: Comma-separated list of IP:PORT
**Example**: `192.168.1.101:3260,192.168.1.102:3260`

Configure multiple portals for failover and multipath.

```ini
portals 192.168.1.101:3260,192.168.1.102:3260
```

### `use_multipath`
**Description**: Enable iSCSI multipath support
**Type**: Boolean (0 or 1)
**Default**: `1`

Requires multiple portals for redundancy and load balancing.

```ini
use_multipath 1
```

### `use_by_path`
**Description**: Use `/dev/disk/by-path/` device names
**Type**: Boolean (0 or 1)
**Default**: `0`

Use persistent by-path device names instead of by-id.

```ini
use_by_path 0
```

### `ipv6_by_path`
**Description**: Normalize IPv6 addresses in by-path device names
**Type**: Boolean (0 or 1)
**Default**: `0`

Required for IPv6 iSCSI connections when using by-path.

```ini
ipv6_by_path 0
```

## Transport Mode Selection

### `transport_mode`
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
transport_mode iscsi

# NVMe/TCP mode
transport_mode nvme-tcp
```

**Important Notes:**
- `transport_mode` cannot be changed after storage creation (prevents volume orphaning)
- Different transport modes have different required parameters:
  - **iSCSI mode**: Requires `target_iqn`, `discovery_portal` (port 3260)
  - **NVMe/TCP mode**: Requires `subsystem_nqn`, `discovery_portal` (port 4420), `api_transport ws`
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

### `subsystem_nqn`
**Description**: NVMe subsystem NQN (NVMe Qualified Name)
**Type**: String (NQN format)
**Required**: Yes (when using NVMe/TCP transport)
**Fixed**: Yes (cannot be changed after creation)
**Format**: `nqn.YYYY-MM.domain:identifier`
**Example**: `nqn.2005-10.org.freenas.ctl:proxmox-nvme`

The NVMe subsystem identifier on TrueNAS. The plugin automatically creates the subsystem if it doesn't exist.

```ini
subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
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

### `hostnqn`
**Description**: NVMe host NQN (initiator identifier)
**Type**: String (NQN format)
**Required**: No (auto-detected from `/etc/nvme/hostnqn`)
**Format**: Must start with `nqn.`
**Example**: `nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400`

Override the default host NQN for custom host identification. By default, the plugin reads the host NQN from `/etc/nvme/hostnqn` on the Proxmox node.

```ini
hostnqn nqn.2014-08.org.nvmexpress:uuid:custom-uuid-here
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

### `nvme_dhchap_secret`
**Description**: DH-HMAC-CHAP host authentication secret (unidirectional)
**Type**: String
**Format**: `DHHC-1:01:base64encodeddata...`
**Required**: No (authentication is optional)
**Default**: None

Host authentication secret for authenticating the Proxmox host to the TrueNAS controller. Provides security by preventing unauthorized hosts from accessing the subsystem.

```ini
nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
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

### `nvme_dhchap_ctrl_secret`
**Description**: DH-HMAC-CHAP controller authentication secret (bidirectional)
**Type**: String
**Format**: `DHHC-1:01:base64encodeddata...`
**Required**: No (bidirectional authentication is optional)
**Default**: None

Controller authentication secret for authenticating the TrueNAS controller to the Proxmox host (mutual authentication). Prevents man-in-the-middle attacks.

```ini
nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
```

**Use Cases:**
- Mutual authentication (both host and controller verify each other)
- High-security environments
- Preventing man-in-the-middle attacks

**Setup:**
1. Generate a separate controller secret (different from host secret)
2. Configure on Proxmox as `nvme_dhchap_ctrl_secret`
3. Configure the same secret on TrueNAS as the controller secret

**Security Model:**
- **Unidirectional** (host secret only): Proxmox proves identity to TrueNAS
- **Bidirectional** (host + controller secrets): Both sides prove identity (recommended)

## iSCSI Behavior

### `force_delete_on_inuse`
**Description**: Force target logout when deleting in-use volumes
**Type**: Boolean (0 or 1)
**Default**: `0`

When enabled, forces iSCSI target logout if volume deletion fails due to "target in use" errors.

```ini
force_delete_on_inuse 1
```

### `logout_on_free`
**Description**: Logout from target when no LUNs remain
**Type**: Boolean (0 or 1)
**Default**: `0`

Automatically logout from iSCSI target when all volumes are freed.

```ini
logout_on_free 0
```

## ZFS Volume Options

### `zvol_blocksize`
**Description**: ZFS volume block size
**Type**: String (power of 2 from 4K to 1M)
**Valid Values**: `4K`, `8K`, `16K`, `32K`, `64K`, `128K`, `256K`, `512K`, `1M`
**Default**: None (uses TrueNAS default, typically 16K)
**Recommended**: `128K` for VM workloads

Larger block sizes improve sequential I/O performance but increase space overhead.

```ini
zvol_blocksize 128K
```

### `tn_sparse`
**Description**: Create sparse (thin-provisioned) volumes
**Type**: Boolean (0 or 1)
**Default**: `1`

Sparse volumes only consume space as data is written, enabling overprovisioning.

```ini
tn_sparse 1
```

## Snapshot Configuration

### `vmstate_storage`
**Description**: Storage location for VM state (RAM) during live snapshots
**Type**: String
**Valid Values**: `local`, `shared`
**Default**: `local`

- `local`: Store vmstate on local Proxmox storage (better performance)
- `shared`: Store vmstate on TrueNAS storage (required for migration)

```ini
vmstate_storage local
```

### `enable_live_snapshots`
**Description**: Enable live VM snapshots with vmstate
**Type**: Boolean (0 or 1)
**Default**: `1`

Allows creating snapshots of running VMs including RAM state.

```ini
enable_live_snapshots 1
```

### `snapshot_volume_chains`
**Description**: Use volume snapshot chains (Proxmox 9+)
**Type**: Boolean (0 or 1)
**Default**: `1`

Enables Proxmox 9.x+ volume chain feature for improved snapshot management.

```ini
snapshot_volume_chains 1
```

## Performance Options

### `enable_bulk_operations`
**Description**: Use TrueNAS bulk API for multiple operations
**Type**: Boolean (0 or 1)
**Default**: `1`

Batch multiple API calls into single bulk request for better performance.

```ini
enable_bulk_operations 1
```

## Security Options

### `chap_user`
**Description**: CHAP authentication username
**Type**: String
**Default**: None

Configure in TrueNAS: **Shares** → **Block Shares (iSCSI)** → **Authorized Access**

```ini
chap_user proxmox-chap
```

### `chap_password`
**Description**: CHAP authentication password
**Type**: String
**Default**: None
**Requirement**: 12-16 characters

Must match the CHAP secret configured in TrueNAS.

```ini
chap_password your-secure-chap-password
```

## Configuration Examples

### Basic Single-Node Configuration (iSCSI)
```ini
truenasplugin: truenas-basic
    api_host 192.168.1.100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    dataset tank/proxmox
    discovery_portal 192.168.1.100:3260
    content images
    shared 1
```

### Basic NVMe/TCP Configuration
```ini
truenasplugin: truenas-nvme
    api_host 192.168.1.100
    api_key 1-your-api-key
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    dataset tank/proxmox
    discovery_portal 192.168.1.100:4420
    api_transport ws
    content images
    shared 1
```

### Production Cluster Configuration
```ini
truenasplugin: truenas-cluster
    api_host 192.168.10.100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:cluster
    dataset tank/cluster/proxmox
    discovery_portal 192.168.10.100:3260
    portals 192.168.10.101:3260,192.168.10.102:3260
    content images
    shared 1
    # Performance
    zvol_blocksize 128K
    tn_sparse 1
    use_multipath 1
    vmstate_storage local
    # Security
    chap_user proxmox-cluster
    chap_password your-secure-password
    # Advanced
    force_delete_on_inuse 1
    logout_on_free 0
    api_retry_max 5
    api_retry_delay 2
```

### High Availability Configuration
```ini
truenasplugin: truenas-ha
    api_host truenas-vip.company.com
    api_key 1-your-api-key
    api_scheme https
    api_port 443
    api_insecure 0
    target_iqn iqn.2005-10.org.freenas.ctl:ha-cluster
    dataset tank/ha/proxmox
    discovery_portal 192.168.100.10:3260
    portals 192.168.100.11:3260,192.168.100.12:3260,192.168.101.10:3260
    content images
    shared 1
    zvol_blocksize 128K
    tn_sparse 1
    use_multipath 1
    vmstate_storage local
    chap_user proxmox-ha
    chap_password very-secure-password
    force_delete_on_inuse 1
    api_retry_max 5
```

### NVMe/TCP with DH-CHAP Authentication
```ini
truenasplugin: truenas-nvme-secure
    api_host 192.168.10.100
    api_key 1-your-api-key
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-secure
    dataset tank/proxmox
    discovery_portal 192.168.10.100:4420
    nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
    api_transport ws
    api_scheme wss
    api_port 443
    content images
    shared 1
    zvol_blocksize 64K
```

### NVMe/TCP Multipath Configuration
```ini
truenasplugin: truenas-nvme-multipath
    api_host 192.168.10.100
    api_key 1-your-api-key
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-ha
    dataset tank/proxmox
    discovery_portal 192.168.10.100:4420
    portals 192.168.10.101:4420,192.168.10.102:4420
    api_transport ws
    content images
    shared 1
    zvol_blocksize 128K
    tn_sparse 1
```

### IPv6 Configuration
```ini
truenasplugin: truenas-ipv6
    api_host 2001:db8::100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:ipv6
    dataset tank/ipv6/proxmox
    discovery_portal [2001:db8::100]:3260
    portals [2001:db8::101]:3260,[2001:db8::102]:3260
    content images
    shared 1
    prefer_ipv4 0
    ipv6_by_path 1
    use_by_path 1
    zvol_blocksize 128K
    use_multipath 1
```

### Development/Testing Configuration
```ini
truenasplugin: truenas-dev
    api_host 192.168.1.50
    api_key 1-dev-api-key
    api_scheme http
    api_port 80
    api_insecure 1
    api_transport rest
    target_iqn iqn.2005-10.org.freenas.ctl:dev
    dataset tank/development
    discovery_portal 192.168.1.50:3260
    content images
    shared 0
    zvol_blocksize 64K
    tn_sparse 1
    use_multipath 0
    vmstate_storage shared
```

### Enterprise Production Configuration (All Features)

Complete configuration showing all available features for enterprise production environments:

```ini
truenasplugin: enterprise-storage
    # API Configuration
    api_host truenas-ha-vip.corp.com
    api_key 1-production-api-key-here
    api_transport ws
    api_scheme wss
    api_port 443
    api_insecure 0
    api_retry_max 5
    api_retry_delay 2
    prefer_ipv4 1

    # Storage Configuration
    dataset tank/production/proxmox
    zvol_blocksize 128K
    tn_sparse 1
    target_iqn iqn.2005-10.org.freenas.ctl:production-cluster

    # iSCSI Network Configuration
    discovery_portal 10.10.100.10:3260
    portals 10.10.100.11:3260,10.10.100.12:3260,10.10.101.10:3260,10.10.101.11:3260
    use_multipath 1
    use_by_path 0
    ipv6_by_path 0

    # Security
    chap_user production-proxmox
    chap_password very-long-secure-chap-password-here

    # iSCSI Behavior
    force_delete_on_inuse 1
    logout_on_free 0

    # Cluster & HA
    content images
    shared 1

    # Snapshot Configuration
    enable_live_snapshots 1
    snapshot_volume_chains 1
    vmstate_storage local

    # Performance Optimization
    enable_bulk_operations 1
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
- **Required Fields**: `api_host`, `api_key`, `dataset`, `target_iqn`, `discovery_portal` must be present
- **Retry Limits**: `api_retry_max` must be 0-10, `api_retry_delay` must be 0.1-60
- **Dataset Naming**: Must follow ZFS naming rules (alphanumeric, `_`, `-`, `.`, `/`)
- **Dataset Format**: No leading/trailing `/`, no `//`, no special characters
- **Security**: Warns if using insecure HTTP/WS transport

### Example Validation Errors
```
# Invalid retry value
api_retry_max must be between 0 and 10 (got 15)

# Invalid dataset name
dataset name contains invalid characters: 'tank/my storage'
  Allowed characters: a-z A-Z 0-9 _ - . /

# Missing required field
api_host is required
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
