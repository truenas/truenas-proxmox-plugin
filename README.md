<h1 align="center">TrueNAS Proxmox VE Storage Plugin</h1>

<p align="center">A high-performance storage plugin for Proxmox VE that integrates TrueNAS SCALE via iSCSI or NVMe/TCP, featuring live snapshots, ZFS integration, and cluster compatibility.</p>

## Features

- **Dual Transport Support** - iSCSI (traditional) or NVMe/TCP (lower latency) block storage
- **iSCSI Block Storage** - Direct integration with TrueNAS SCALE via iSCSI targets
- **NVMe/TCP Support** - Modern NVMe over TCP for reduced latency and CPU overhead (TrueNAS SCALE 25.10+)
- **ZFS Snapshots** - Instant, space-efficient snapshots via TrueNAS ZFS
- **Live Snapshots** - Full VM state snapshots including RAM (vmstate)
- **Cluster Compatible** - Full support for Proxmox VE clusters with shared storage
- **Automatic Volume Management** - Dynamic zvol creation and iSCSI extent mapping
- **Configuration Validation** - Pre-flight checks and validation prevent misconfigurations
- **Dual API Support** - WebSocket (JSON-RPC) and REST API transports
- **Rate Limiting Protection** - Automatic retry with exponential backoff for TrueNAS API limits
- **Storage Efficiency** - Thin provisioning and ZFS compression support
- **Multi-path Support** - Native support for iSCSI multipathing
- **CHAP Authentication** - Optional CHAP security for iSCSI connections
- **Volume Resize** - Grow-only resize with preflight space checks
- **Error Recovery** - Comprehensive error handling with actionable error messages
- **Performance Optimization** - Configurable block sizes and sparse volumes

## Feature Comparison

| Feature | TrueNAS Plugin | Standard iSCSI | NFS |
|---------|:--------------:|:--------------:|:---:|
| **Snapshots** | ✅ | ⚠️ | ⚠️ |
| **VM State Snapshots (vmstate)** | ✅ | ✅ | ✅ |
| **Clones** | ✅ | ⚠️ | ⚠️ |
| **Thin Provisioning** | ✅ | ⚠️ | ⚠️ |
| **Block-Level Performance** | ✅ | ✅ | ❌ |
| **Shared Storage** | ✅ | ✅ | ✅ |
| **Automatic Volume Management** | ✅ | ❌ | ❌ |
| **Automatic Resize** | ✅ | ❌ | ❌ |
| **Pre-flight Checks** | ✅ | ❌ | ❌ |
| **Multi-path I/O** | ✅ | ✅ | ❌ |
| **ZFS Compression** | ✅ | ❌ | ❌ |
| **Container Storage** | ❌ | ⚠️ | ✅ |
| **Backup Storage** | ❌ | ❌ | ✅ |
| **ISO Storage** | ❌ | ❌ | ✅ |
| **Raw Image Format** | ✅ | ✅ | ✅ |

**Legend**: ✅ Native Support | ⚠️ Via Additional Layer | ❌ Not Supported

**Notes**:
- **Standard iSCSI**: Raw iSCSI lacks native snapshots/clones. Use LVM-thin on iSCSI for full snapshot/clone/thin-provisioning support, or volume chains (Proxmox VE 9+). Container storage available via LVM on iSCSI.
- **NFS**: Snapshots/clones require qcow2 format (performance overhead vs raw). Supports backups, ISOs, and containers natively.
- **TrueNAS Plugin**: Native ZFS features with raw image performance and automated zvol/iSCSI extent management via TrueNAS API.
- **VM State Snapshots**: All storage types supporting the 'images' content type can store vmstate files for live snapshots with RAM.

## Quick Start

### Installation

**Recommended: One-Line Automated Installer**

Install the plugin with a single command:

```bash
wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash
```

Or using curl:
```bash
curl -sSL https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash
```

The installer provides:
- ✅ Interactive menu-driven setup
- ✅ Automatic version detection and updates
- ✅ Built-in configuration wizard
- ✅ Health check validation
- ✅ Backup and rollback support
- ✅ Cluster node compatibility

**Alternative: Manual Installation**

If you prefer manual installation:

```bash
# Download the plugin
wget https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/TrueNASPlugin.pm

# Copy to plugin directory
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set permissions
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Restart Proxmox services
systemctl restart pvedaemon pveproxy
```

### Configuration

#### Configure Storage
Add to `/etc/pve/storage.cfg`:

```ini
truenasplugin: truenas-storage
    api_host 192.168.1.100
    api_key 1-your-truenas-api-key-here
    api_insecure 1
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    dataset tank/proxmox
    discovery_portal 192.168.1.100:3260
    content images
    shared 1
```

Replace:
- `192.168.1.100` with your TrueNAS IP
- `1-your-truenas-api-key-here` with your TrueNAS API key
- `tank/proxmox` with your ZFS dataset path

#### NVMe/TCP Configuration (Alternative)

For lower latency and reduced CPU overhead, use NVMe/TCP instead of iSCSI:

```ini
truenasplugin: truenas-nvme
    api_host 192.168.1.100
    api_key 1-your-truenas-api-key-here
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    dataset tank/proxmox
    discovery_portal 192.168.1.100:4420
    api_transport ws
    content images
    shared 1
```

**NVMe/TCP Requirements**:
- TrueNAS SCALE 25.10.0 or later
- Proxmox VE 9.x or later
- Install `nvme-cli` on Proxmox: `apt-get install nvme-cli`
- Enable **NVMe-oF Target** service in TrueNAS

**See [wiki/NVMe-Setup.md](wiki/NVMe-Setup.md) for complete NVMe/TCP setup guide.**

### TrueNAS SCALE Setup

#### 1. Create Dataset
Navigate to **Datasets** → Create new dataset:
- **Name**: `proxmox` (under existing pool like `tank`)
- **Dataset Preset**: Generic

#### 2. Enable iSCSI Service
Navigate to **System Settings** → **Services**:
- Enable **iSCSI** service
- Set to start automatically

#### 3. Create iSCSI Target
Navigate to **Shares** → **Block Shares (iSCSI)** → **Targets**:
- Click **Add**
- **Target Name**: `proxmox` (becomes `iqn.2005-10.org.freenas.ctl:proxmox`)
- **Target Mode**: iSCSI
- Click **Save**

#### 4. Create iSCSI Portal
Navigate to **Shares** → **Block Shares (iSCSI)** → **Portals**:
- Default portal should exist on `0.0.0.0:3260`
- If not, create one with your TrueNAS IP and port 3260

#### 5. Generate API Key
Navigate to **Credentials** → **Local Users**:
- Select **root** user (or create dedicated user)
- Click **Edit**
- Scroll to **API Key** section
- Click **Add** to generate new API key
- **Copy and save the API key securely** (you won't be able to see it again)

#### 6. Verify Configuration
The plugin will automatically:
- Create zvols under your dataset (`tank/proxmox/vm-XXX-disk-N`)
- Create iSCSI extents for each zvol
- Associate extents with your target
- Handle all iSCSI session management

## Basic Usage

### Create VM with TrueNAS Storage
```bash
# Create VM
qm create 100 --name "test-vm" --memory 2048 --cores 2

# Add disk from TrueNAS storage
qm set 100 --scsi0 truenas-storage:32

# Start VM
qm start 100
```

### Snapshot Operations
```bash
# Create snapshot
qm snapshot 100 backup1 --description "Before updates"

# Create live snapshot (with RAM state)
qm snapshot 100 live1 --vmstate 1

# List snapshots
qm listsnapshot 100

# Rollback to snapshot
qm rollback 100 backup1

# Delete snapshot
qm delsnapshot 100 backup1
```

### Storage Management
```bash
# Check storage status
pvesm status truenas-storage

# List all volumes
pvesm list truenas-storage

# Check available space
pvesm status
```

### Advanced Installation Options

The installer supports additional features:
- **Version management** - Install, update, or rollback to specific versions
- **Configuration wizard** - Interactive guided setup with validation
- **Health checks** - 11-point system validation
- **Cluster support** - Automatic cluster detection and warnings
- **Backup management** - Automatic backups with rollback capability

For detailed installation instructions and troubleshooting, see the [Installation Guide](wiki/Installation.md).

## Documentation

Comprehensive documentation is available in the [Wiki](wiki/):

- **[Installation Guide](wiki/Installation.md)** - Detailed installation steps for both Proxmox and TrueNAS
- **[Configuration Reference](wiki/Configuration.md)** - Complete parameter reference and examples
- **[Tools and Utilities](wiki/Tools.md)** - Test suite and cluster deployment scripts
- **[Troubleshooting Guide](wiki/Troubleshooting.md)** - Common issues and solutions
- **[Advanced Features](wiki/Advanced-Features.md)** - Performance tuning, clustering, security
- **[API Reference](wiki/API-Reference.md)** - Technical details on TrueNAS API integration
- **[Known Limitations](wiki/Known-Limitations.md)** - Important limitations and workarounds

## Important: TrueNAS API Changes

**TrueNAS SCALE 25.04+ Users**: The TrueNAS REST API has been deprecated as of version 25.04 and will be completely removed in version 26.04. This plugin supports both WebSocket (recommended) and REST transports. **Ensure you use WebSocket transport (`api_transport ws`) for TrueNAS 25.04+**.

For TrueNAS 26.04+, REST transport will no longer function.

## Requirements

- **Proxmox VE** 8.x or later (9.x recommended)
- **TrueNAS SCALE** 22.x or later (25.04+ recommended)
  - **For TrueNAS 25.04+**: Must use WebSocket transport (`api_transport ws`)
  - **For TrueNAS 26.04+**: REST API will not be available
- Network connectivity between Proxmox nodes and TrueNAS (iSCSI on port 3260, WebSocket API on port 443)

## Support

For issues, questions, or contributions:
- Review the [Troubleshooting Guide](wiki/Troubleshooting.md)
- Check [Known Limitations](wiki/Known-Limitations.md)
- Report bugs or request features via GitHub issues

## License

This project is provided as-is for use with Proxmox VE and TrueNAS SCALE.

---

**Version**: 1.1.0
**Last Updated**: October 23, 2025
**Compatibility**: Proxmox VE 8.x+, TrueNAS SCALE 22.x+
