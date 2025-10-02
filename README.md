# TrueNAS Proxmox VE Storage Plugin

A high-performance storage plugin for Proxmox VE that integrates TrueNAS SCALE via iSCSI, featuring live snapshots, ZFS integration, and cluster compatibility.

## Features

- **iSCSI Block Storage** - Direct integration with TrueNAS SCALE via iSCSI targets
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

## Quick Start

### Proxmox VE Setup

#### 1. Install Plugin
```bash
# Copy the plugin file
sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set permissions
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Restart Proxmox services
sudo systemctl restart pvedaemon pveproxy
```

#### 2. Configure Storage
Add to `/etc/pve/storage.cfg`:

```ini
truenasplugin: truenas-storage
    api_host 192.168.1.100
    api_key 1-your-truenas-api-key-here
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

## Documentation

Comprehensive documentation is available in the [Wiki](wiki/):

- **[Installation Guide](wiki/Installation.md)** - Detailed installation steps for both Proxmox and TrueNAS
- **[Configuration Reference](wiki/Configuration.md)** - Complete parameter reference and examples
- **[Tools and Utilities](wiki/Tools.md)** - Test suite and cluster deployment scripts
- **[Troubleshooting Guide](wiki/Troubleshooting.md)** - Common issues and solutions
- **[Advanced Features](wiki/Advanced-Features.md)** - Performance tuning, clustering, security
- **[API Reference](wiki/API-Reference.md)** - Technical details on TrueNAS API integration
- **[Known Limitations](wiki/Known-Limitations.md)** - Important limitations and workarounds

## Requirements

- **Proxmox VE** 8.x or later (9.x recommended)
- **TrueNAS SCALE** 22.x or later (25.04+ recommended)
- Network connectivity between Proxmox nodes and TrueNAS (iSCSI on port 3260, API on port 443/80)

## Support

For issues, questions, or contributions:
- Review the [Troubleshooting Guide](wiki/Troubleshooting.md)
- Check [Known Limitations](wiki/Known-Limitations.md)
- Report bugs or request features via GitHub issues

## License

This project is provided as-is for use with Proxmox VE and TrueNAS SCALE.

---

**Version**: 1.0.0
**Last Updated**: October 2025
**Compatibility**: Proxmox VE 8.x+, TrueNAS SCALE 22.x+
