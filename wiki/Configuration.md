# Configuration Reference

Complete reference for all TrueNAS Proxmox VE Storage Plugin configuration parameters.

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

Configure in TrueNAS: **Shares** → **Block Shares (iSCSI)** → **Targets**

```ini
target_iqn iqn.2005-10.org.freenas.ctl:proxmox
```

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
**Description**: Primary iSCSI portal for target discovery
**Type**: String (IP:PORT format)
**Default Port**: 3260
**Example**: `192.168.1.100:3260`

```ini
discovery_portal 192.168.1.100:3260
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

### Basic Single-Node Configuration
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
