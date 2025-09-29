# TrueNAS Proxmox VE Storage Plugin

A high-performance storage plugin for Proxmox VE that integrates TrueNAS SCALE via iSCSI with advanced features including live snapshots, ZFS integration, and cluster compatibility.

## Features

### 🚀 Core Functionality
- **iSCSI Block Storage** - Direct integration with TrueNAS SCALE iSCSI targets
- **ZFS Snapshots** - Instant, space-efficient snapshots via TrueNAS ZFS
- **Live Snapshots** - Full VM state snapshots including RAM (vmstate)
- **Cluster Compatible** - Full support for Proxmox VE clusters
- **Automatic Volume Management** - Dynamic zvol creation and iSCSI extent mapping

### 🔧 Advanced Features
- **Dual API Support** - WebSocket (JSON-RPC) and REST API transports
- **Rate Limiting Protection** - Automatic retry with backoff for TrueNAS API limits
- **Storage Efficiency** - Thin provisioning and ZFS compression support
- **Flexible vmstate Storage** - Configurable local or shared vmstate storage
- **Multi-path Support** - Native support for iSCSI multipathing
- **CHAP Authentication** - Optional CHAP security for iSCSI connections

### 📊 Enterprise Features
- **Volume Resize** - Grow-only resize with 80% headroom preflight checks
- **Error Recovery** - Comprehensive error handling and automatic cleanup
- **Performance Optimization** - Configurable block sizes and sparse volumes
- **Monitoring Integration** - Full integration with Proxmox storage status

## Requirements

### Software
- **Proxmox VE** - 8.x or later (9.x recommended for volume chains)
- **TrueNAS SCALE** - 22.x or later (25.04+ recommended)
- **Perl** - 5.36 or later

### Network
- **iSCSI Connectivity** - TCP/3260 between Proxmox nodes and TrueNAS
- **TrueNAS API Access** - HTTPS/443 or HTTP/80 for management API
- **Cluster Networks** - Shared storage network for cluster deployments

### TrueNAS Configuration
- **iSCSI Service** - Enabled and configured
- **API Key** - User-linked API key with appropriate permissions
- **ZFS Dataset** - Parent dataset for Proxmox volumes
- **iSCSI Target** - Configured target with portal access

## Installation

### Proxmox VE Setup

#### 1. Install the Plugin

```bash
# Copy the plugin to Proxmox storage directory
sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set proper permissions
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

#### 2. Register the Plugin

Add to `/etc/pve/storage.cfg`:

```ini
truenasplugin: your-storage-name
    api_host 192.168.1.100
    api_key your-truenas-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:your-target
    dataset tank/proxmox
    discovery_portal 192.168.1.100:3260
    content images
    shared 1
```

#### 3. Restart Proxmox Services

```bash
sudo systemctl restart pvedaemon
sudo systemctl restart pveproxy
```

### TrueNAS SCALE Setup

#### 1. Create ZFS Dataset

```bash
# Create parent dataset for Proxmox volumes
sudo zfs create tank/proxmox
```

#### 2. Configure iSCSI Service

- **Enable iSCSI Service**: Navigate to **System Settings > Services** and enable the iSCSI service
- **Create Target**: Go to **Shares > Block Shares (iSCSI)** and create a new target
  - Set **Target Name**: `iqn.2005-10.org.freenas.ctl:your-target`
  - Configure **Target Global Configuration** as needed

#### 3. Configure iSCSI Portal

- **Create Portal**: In **Shares > Block Shares (iSCSI) > Portals**
  - Set **Discovery IP**: Your TrueNAS IP address
  - Set **Port**: 3260 (default)
  - Configure **Discovery Auth Method** if using CHAP

#### 4. Generate API Key

- **Create API Key**: Navigate to **Credentials > Local Users**
  - Select your admin user or create a dedicated user
  - Click **Edit** and scroll to **API Key**
  - Generate a new API key and save it securely
  - Ensure the user has appropriate permissions for storage management

## Configuration

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `api_host` | TrueNAS hostname or IP address | `192.168.1.100` |
| `api_key` | TrueNAS API key | `1-xxx...` |
| `target_iqn` | iSCSI target IQN | `iqn.2005-10.org.freenas.ctl:target1` |
| `dataset` | Parent ZFS dataset for volumes | `tank/proxmox` |
| `discovery_portal` | Primary iSCSI portal | `192.168.1.100:3260` |

### Optional Parameters

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `api_transport` | API transport method | `ws` | `ws`, `rest` |
| `api_scheme` | API scheme | `wss/https` | `wss`, `ws`, `https`, `http` |
| `api_port` | API port | `443/80` | Any valid port |
| `api_insecure` | Skip TLS verification | `0` | `0`, `1` |
| `prefer_ipv4` | Prefer IPv4 DNS resolution | `1` | `0`, `1` |
| `portals` | Additional iSCSI portals | - | `IP:PORT,IP:PORT` |
| `use_multipath` | Enable multipath | `1` | `0`, `1` |
| `use_by_path` | Use by-path device names | `0` | `0`, `1` |
| `ipv6_by_path` | Normalize IPv6 by-path names | `0` | `0`, `1` |
| `force_delete_on_inuse` | Force delete when target in use | `0` | `0`, `1` |
| `logout_on_free` | Logout target when no LUNs remain | `0` | `0`, `1` |
| `zvol_blocksize` | ZFS volume block size | - | `4K` to `1M` |
| `tn_sparse` | Create sparse volumes | `1` | `0`, `1` |
| `chap_user` | CHAP username | - | Any valid username |
| `chap_password` | CHAP password | - | Any valid password |
| `vmstate_storage` | vmstate storage location | `local` | `local`, `shared` |
| `enable_live_snapshots` | Enable live snapshots | `1` | `0`, `1` |
| `snapshot_volume_chains` | Use volume chains for snapshots | `1` | `0`, `1` |
| `enable_bulk_operations` | Enable bulk API operations | `1` | `0`, `1` |

## Usage Examples

### Basic Volume Operations

```bash
# Create a new VM disk (32GB)
pvesm alloc your-storage-name 100 vm-100-disk-0 34359738368

# List storage volumes
pvesm list your-storage-name

# Get volume information
pvesm status your-storage-name

# Free a volume
pvesm free your-storage-name:vol-vm-100-disk-0-lun1
```

### Snapshot Operations

```bash
# Create disk-only snapshot
qm snapshot 100 checkpoint1 --description "Before updates"

# Create live snapshot (includes RAM)
qm snapshot 100 live-backup --vmstate 1 --description "Live system state"

# List snapshots
qm listsnapshot 100

# Rollback to snapshot
qm rollback 100 checkpoint1

# Delete snapshot
qm delsnapshot 100 checkpoint1
```

### VM Management

```bash
# Create VM with TrueNAS storage
qm create 100 --name "test-vm" --memory 2048 --cores 2
qm set 100 --scsi0 your-storage-name:32G --scsihw virtio-scsi-single

# Resize VM disk (grow only)
qm resize 100 scsi0 +16G

# Start VM
qm start 100
```

## Performance Tuning

### Optimal Configuration

```ini
truenasplugin: production-storage
    # ... basic config ...
    zvol_blocksize 128K          # Optimal for VMs
    tn_sparse 1                  # Enable thin provisioning
    use_multipath 1              # Enable for redundancy
    vmstate_storage local        # Better performance
    api_transport ws             # Faster than REST
```

### Network Optimization

- **Dedicated Storage Network** - Use dedicated 10GbE+ network for iSCSI
- **Jumbo Frames** - Enable 9000 MTU for better throughput
- **Multiple Portals** - Configure multiple iSCSI portals for redundancy
- **MPIO** - Enable multipath I/O for better performance and availability

## Cluster Configuration

### Multi-Node Setup

```ini
# Configure on all cluster nodes
truenasplugin: shared-storage
    api_host 192.168.1.100
    api_key your-truenas-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:cluster-target
    dataset tank/cluster
    discovery_portal 192.168.1.100:3260
    portals 192.168.1.101:3260,192.168.1.102:3260
    shared 1
    content images
```

### High Availability

- **Multiple Portals** - Configure redundant iSCSI portals
- **Network Redundancy** - Use bonded network interfaces
- **TrueNAS HA** - Deploy TrueNAS in HA configuration
- **Cluster Quorum** - Ensure proper Proxmox cluster quorum

## Troubleshooting

### Connection Problems

```bash
# Test iSCSI connectivity
iscsiadm -m discovery -t sendtargets -p YOUR_TRUENAS_IP:3260

# Check iSCSI sessions
iscsiadm -m session

# Verify multipath status
multipath -ll
```

### API Issues

```bash
# Test TrueNAS API
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/iscsi/target

# Check rate limiting
tail -f /var/log/syslog | grep -i truenas
```

### Storage Issues

```bash
# Check storage status
pvesm status your-storage-name

# List volumes
pvesm list your-storage-name

# Check disk devices
ls -la /dev/disk/by-path/ | grep iscsi
```

## Security Considerations

### Network Security
- **VLAN Isolation** - Use dedicated VLANs for storage traffic
- **Firewall Rules** - Restrict access to iSCSI and API ports
- **CHAP Authentication** - Enable CHAP for iSCSI security

### API Security
- **API Key Rotation** - Regularly rotate TrueNAS API keys
- **Least Privilege** - Use API keys with minimal required permissions
- **TLS Verification** - Keep `api_insecure` disabled in production

### Access Control
- **User Permissions** - Limit TrueNAS user permissions
- **Network ACLs** - Use TrueNAS iSCSI authorized networks
- **Audit Logging** - Enable comprehensive audit logging

## Known Limitations

### ⚠️ Critical Workflow Limitations

#### VM Deletion Behavior
**Important**: Different VM deletion methods have different cleanup behaviors:

**✅ GUI Deletion (Recommended)**
- Deleting VMs through the Proxmox web interface properly calls storage plugin cleanup methods
- Achieves 100% cleanup of both Proxmox volumes and TrueNAS zvols/snapshots
- **This is the recommended method for production use**

**❌ CLI `qm destroy` Command**
- The `qm destroy` command does NOT call storage plugin cleanup methods
- Leaves orphaned zvols and snapshots on TrueNAS
- Proxmox removes internal references but TrueNAS storage remains

**Manual Cleanup Required**
When using `qm destroy`, you must manually clean up storage:

```bash
# After qm destroy, manually free remaining volumes
pvesm list your-storage-name | grep vm-ID
pvesm free your-storage-name:vol-vm-ID-disk-N-lunX
```

**Production Recommendation**: Use the Proxmox GUI for VM deletion, or implement cleanup procedures when using CLI automation.

#### Fast Clone Limitation
**VM cloning does not use instant ZFS clones**. Instead, Proxmox performs network-based copying using `qemu-img convert`.

**Why this happens:**
- Proxmox treats storage plugins that return block device paths (like iSCSI) as "generic block storage"
- For such storage, Proxmox bypasses storage plugin clone methods and uses `qemu-img convert` directly
- Our efficient `clone_image` and `copy_image` methods are never called during VM cloning operations

**Performance impact:**
- Clone operations transfer data over the network at your connection speed (e.g., 1GbE = ~100MB/s)
- Large VMs (32GB+) can take significant time to clone
- Network bandwidth is consumed during cloning

**Workaround:**
- Use smaller base images/templates for frequent cloning
- Ensure adequate network bandwidth between Proxmox and TrueNAS
- ZFS snapshots within TrueNAS are still instant and space-efficient

### Other Limitations
- **Shrink Operations** - Volume shrinking is not supported (ZFS limitation)
- **Live Migration** - Requires shared storage configuration
- **Backup Integration** - Snapshots are not included in Proxmox backups

### TrueNAS Specific
- **API Rate Limits** - TrueNAS limits API requests to 20 calls per 60 seconds with a 10-minute cooldown when exceeded. Automatic retry with backoff is implemented.
- **Persistent Connections** - WebSocket connections are cached and reused to minimize authentication overhead and reduce API calls
- **Bulk Operations** - When `enable_bulk_operations=1`, multiple operations are batched using TrueNAS core.bulk API for improved performance
- **WebSocket Stability** - REST fallback available for unreliable WebSocket connections
- **Version Compatibility** - Some features require TrueNAS SCALE 25.04+

## Contributing

### Reporting Issues
- **Bug Reports** - Include Proxmox and TrueNAS versions
- **Feature Requests** - Describe use case and benefits
- **Performance Issues** - Include storage and network configuration

---

**Version**: 1.0.0
**Last Updated**: September 2025
**Compatibility**: Proxmox VE 8.x+, TrueNAS SCALE 22.x+