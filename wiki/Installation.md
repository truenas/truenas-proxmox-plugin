# Installation Guide

Complete installation instructions for the TrueNAS Proxmox VE Storage Plugin.

## Requirements

### Software Requirements
- **Proxmox VE** - 8.x or later (9.x recommended for volume chains)
- **TrueNAS SCALE** - 22.x or later (25.04+ recommended)
- **Perl** - 5.36 or later (included with Proxmox VE)

### Network Requirements
- **iSCSI Connectivity** - TCP/3260 between Proxmox nodes and TrueNAS
- **TrueNAS API Access** - HTTPS/443 or HTTP/80 for management API
- **Cluster Networks** - Shared storage network for cluster deployments

### TrueNAS Prerequisites
Before installing the plugin, ensure TrueNAS is properly configured:
- iSCSI service enabled and running
- API key generated with appropriate permissions
- ZFS parent dataset created for Proxmox volumes
- iSCSI target configured with portal access

## Proxmox VE Installation

### Single Node Installation

#### 1. Install the Plugin File

```bash
# Copy the plugin to Proxmox storage directory
sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set proper permissions
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Verify installation
ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

#### 2. Configure Storage

Add storage configuration to `/etc/pve/storage.cfg`:

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

#### 3. Restart Proxmox Services

```bash
# Restart required services
sudo systemctl restart pvedaemon
sudo systemctl restart pveproxy

# Verify services are running
sudo systemctl status pvedaemon
sudo systemctl status pveproxy
```

#### 4. Verify Installation

```bash
# Check storage is recognized
pvesm status

# Verify TrueNAS storage appears
pvesm list truenas-storage
```

### Cluster Installation

For Proxmox VE clusters, install on all nodes:

#### 1. Install on First Node

Follow the single node installation steps above on your first cluster node.

#### 2. Deploy to Cluster Nodes

Use the included deployment script:

```bash
# Make the script executable
chmod +x update-cluster.sh

# Deploy to all nodes
./update-cluster.sh node1 node2 node3
```

Or manually on each node:

```bash
# On each cluster node
sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
sudo systemctl restart pvedaemon pveproxy
```

#### 3. Configure Shared Storage

The storage configuration in `/etc/pve/storage.cfg` is automatically shared across cluster nodes. Ensure `shared 1` is set:

```ini
truenasplugin: cluster-storage
    api_host 192.168.10.100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:cluster
    dataset tank/cluster/proxmox
    discovery_portal 192.168.10.100:3260
    portals 192.168.10.101:3260,192.168.10.102:3260
    content images
    shared 1
    use_multipath 1
```

#### 4. Verify Cluster Installation

```bash
# On each node, verify storage access
pvesm status

# Check iSCSI sessions on each node
iscsiadm -m session

# Verify multipath (if enabled)
multipath -ll
```

## TrueNAS SCALE Setup

### 1. Create ZFS Dataset

#### Via Web Interface
Navigate to **Datasets** → Click **Add Dataset**:
- **Name**: `proxmox` (or your preferred name)
- **Parent**: Select your storage pool (e.g., `tank`)
- **Dataset Preset**: Generic
- **Compression**: lz4 (recommended)
- **Enable Atime**: Off (recommended for performance)

#### Via CLI
```bash
# Create dataset with recommended settings
sudo zfs create tank/proxmox
sudo zfs set compression=lz4 tank/proxmox
sudo zfs set atime=off tank/proxmox
```

### 2. Configure iSCSI Service

#### Enable iSCSI Service
Navigate to **System Settings** → **Services**:
- Find **iSCSI** in the service list
- Toggle **Running** to ON
- Enable **Start Automatically**

#### Verify iSCSI Service
```bash
# Check service status
sudo systemctl status iscsitarget

# Verify iSCSI is listening
sudo netstat -tuln | grep 3260
```

### 3. Create iSCSI Target

Navigate to **Shares** → **Block Shares (iSCSI)** → **Targets** → **Add**:

**Basic Configuration:**
- **Target Name**: `proxmox` (becomes `iqn.2005-10.org.freenas.ctl:proxmox`)
- **Target Alias**: Proxmox Storage (optional)
- **Target Mode**: iSCSI

**Advanced Options:**
- **Auth Method**: None (or CHAP if needed)
- **Auth Group**: None (or configure for CHAP)

Click **Save**

### 4. Create/Verify iSCSI Portal

Navigate to **Shares** → **Block Shares (iSCSI)** → **Portals**:

**Default Portal Configuration:**
- TrueNAS creates a default portal on `0.0.0.0:3260`
- This is sufficient for basic configurations

**Custom Portal (for specific interfaces):**
- Click **Add** to create custom portal
- **IP Address**: Specific TrueNAS interface IP
- **Port**: 3260 (default)
- **Discovery Auth Method**: None (or CHAP)

### 5. Generate API Key

Navigate to **Credentials** → **Local Users**:

#### Option 1: Use Root User
- Find **root** user in the list
- Click **Edit**
- Scroll to **API Key** section
- Click **Add** to generate new API key
- **Important**: Copy the API key immediately (you won't see it again)
- Click **Save**

#### Option 2: Create Dedicated User (Recommended)
- Click **Add** to create new user
- **Username**: `proxmox-api` (or preferred name)
- **Password**: Set a secure password
- **Full Name**: Proxmox VE Storage Plugin
- Scroll to **API Key** section
- Click **Add** to generate API key
- **Copy the API key**
- Click **Save**

**Required Permissions:**
- Full access to datasets (create, modify, delete)
- Full access to iSCSI shares (create, modify, delete)
- Read access to system information

### 6. Optional: Configure CHAP Authentication

Navigate to **Shares** → **Block Shares (iSCSI)** → **Authorized Access**:

**Create Authorized Access:**
- Click **Add**
- **Group ID**: 1 (or next available)
- **User**: Choose username for CHAP
- **Secret**: Enter CHAP password (12-16 characters)
- **Peer User**: Leave empty (or set for mutual CHAP)
- **Peer Secret**: Leave empty
- Click **Save**

**Update Portal:**
- Go to **Portals** → Edit your portal
- **Discovery Auth Method**: CHAP
- **Discovery Auth Group**: Select the auth group you created
- Click **Save**

**Update Proxmox Configuration:**
```ini
truenasplugin: truenas-storage
    # ... other settings ...
    chap_user your-chap-username
    chap_password your-chap-password
```

### 7. Verify TrueNAS Configuration

#### Test API Access
```bash
# Replace with your values
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/iscsi/target

# Should return JSON list of targets
```

#### Verify Dataset
```bash
# Check dataset exists
zfs list tank/proxmox

# Check dataset properties
zfs get all tank/proxmox
```

#### Test iSCSI Discovery
```bash
# From Proxmox node
iscsiadm -m discovery -t sendtargets -p YOUR_TRUENAS_IP:3260

# Should show your target IQN
```

## Post-Installation Verification

### 1. Check Storage Status
```bash
# On Proxmox node
pvesm status

# Should show truenas-storage as active
```

### 2. Create Test Volume
```bash
# Allocate a small test volume
pvesm alloc truenas-storage 999 test-disk-0 1073741824

# List volumes
pvesm list truenas-storage

# Should show the test volume
```

### 3. Verify on TrueNAS
Check that the zvol was created:
```bash
# On TrueNAS
zfs list -t volume

# Should show tank/proxmox/vm-999-disk-0
```

Check that the iSCSI extent was created:
- Navigate to **Shares** → **Block Shares (iSCSI)** → **Extents**
- Should show extent for `vm-999-disk-0`

### 4. Clean Up Test Volume
```bash
# On Proxmox
pvesm free truenas-storage:vm-999-disk-0-lun1
```

## Troubleshooting Installation

### Plugin Not Recognized

**Symptom**: `pvesm status` doesn't show TrueNAS storage

**Solution**:
```bash
# Verify file location
ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Check permissions
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Restart services
sudo systemctl restart pvedaemon pveproxy

# Check for errors
journalctl -u pvedaemon -n 50
```

### API Connection Failed

**Symptom**: Storage shows as inactive

**Solution**:
```bash
# Test API connectivity
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/system/info

# Check firewall
sudo iptables -L -n | grep 443

# Verify TrueNAS API is accessible
ping YOUR_TRUENAS_IP
```

### iSCSI Discovery Failed

**Symptom**: Cannot discover iSCSI targets

**Solution**:
```bash
# Check iSCSI service on TrueNAS
# Via web UI: System Settings > Services > iSCSI (should be Running)

# Test discovery from Proxmox
iscsiadm -m discovery -t sendtargets -p YOUR_TRUENAS_IP:3260

# Check network connectivity
telnet YOUR_TRUENAS_IP 3260

# Verify iSCSI portal configuration in TrueNAS
```

### Configuration Validation Errors

**Symptom**: Storage configuration rejected with validation error

**Solution**:
```bash
# Check dataset name format
# Invalid: "tank/my storage" (spaces not allowed)
# Valid: "tank/my-storage" or "tank/mystorage"

# Check retry parameters
# api_retry_max must be 0-10
# api_retry_delay must be 0.1-60

# Verify all required parameters present:
# - api_host
# - api_key
# - dataset
# - target_iqn
# - discovery_portal
```

## Updating the Plugin

### Single Node Update
```bash
# Backup current version
sudo cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
  /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm.backup

# Copy new version
sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Restart services
sudo systemctl restart pvedaemon pveproxy
```

### Cluster Update
```bash
# Use the deployment script
./update-cluster.sh node1 node2 node3

# Or manually on each node
for node in node1 node2 node3; do
  scp TrueNASPlugin.pm root@$node:/usr/share/perl5/PVE/Storage/Custom/
  ssh root@$node "systemctl restart pvedaemon pveproxy"
done
```

## Uninstallation

### Remove Plugin
```bash
# Remove plugin file
sudo rm /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Remove storage configuration from /etc/pve/storage.cfg
# (edit manually to remove truenasplugin entries)

# Restart services
sudo systemctl restart pvedaemon pveproxy
```

### Clean Up TrueNAS
```bash
# Remove all zvols (WARNING: deletes all data)
zfs destroy -r tank/proxmox

# Remove iSCSI configuration via TrueNAS web UI:
# - Delete extents in Shares > Block Shares (iSCSI) > Extents
# - Delete target in Shares > Block Shares (iSCSI) > Targets
# - Revoke API key in Credentials > Local Users
```

## Next Steps

After successful installation:
- Review [Configuration Reference](Configuration.md) for advanced options
- Check [Advanced Features](Advanced-Features.md) for performance tuning
- Read [Known Limitations](Known-Limitations.md) for important restrictions
