# Installation Guide

Complete installation instructions for the TrueNAS Proxmox VE Storage Plugin.

## Table of Contents
- [Automated Installation (Recommended)](#automated-installation-recommended)
- [Manual Installation](#manual-installation)
- [Requirements](#requirements)
- [TrueNAS SCALE Setup](#truenas-scale-setup)
- [Post-Installation Verification](#post-installation-verification)
- [Troubleshooting Installation](#troubleshooting-installation)

## Automated Installation (Recommended)

The TrueNAS plugin includes a comprehensive automated installer that handles installation, updates, configuration, and management through an interactive menu system.

### Quick Start - One-Line Installation

Install the plugin with a single command:

```bash
wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash
```

Or using curl:
```bash
curl -sSL https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash
```

The installer will:
1. ✅ Check for required dependencies (curl/wget, jq, perl)
2. ✅ Download the latest plugin from GitHub
3. ✅ Validate plugin syntax before installation
4. ✅ Install to the correct directory with proper permissions
5. ✅ Restart Proxmox services automatically
6. ✅ Offer to configure storage immediately
7. ✅ Run optional health checks

### Installer Features

#### Interactive Menu System
After installation, the installer provides a full-featured management interface:

```
╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.0.0                        ║
╚══════════════════════════════════════════════════════════╝

Plugin Status: Installed (v1.0.6)
Update Available: v1.0.7

Main Menu:
  1) Update to latest version
  2) Install specific version
  3) Configure storage
  4) Run health check
  5) Manage backups
  6) Rollback to previous version
  7) Uninstall plugin
  8) Exit

Choose an option:
```

#### Available Operations

**Installation & Updates**
- Install latest version from GitHub
- Install specific version (version selection menu)
- Update to latest version (with backup)
- Automatic update detection and notification

**Configuration Management**
- Interactive configuration wizard
- Guided setup for all storage parameters
- Input validation (IP addresses, API keys, dataset names)
- TrueNAS API connectivity testing
- Dataset verification via API
- Automatic backup of storage.cfg

**Health Checking**
- 11-point comprehensive health validation
- Plugin file verification and syntax check
- Storage configuration validation
- TrueNAS API connectivity test
- iSCSI session monitoring
- Multipath status check
- Service verification (pvedaemon, pveproxy)
- Color-coded status indicators
- Animated spinners during checks

**Backup & Recovery**
- Automatic backup before any changes
- Timestamped backup files with version info
- View all backups with statistics
- Rollback to any previous version
- Backup management (delete old backups, keep latest N)
- Smart cleanup with age/count/size thresholds

**Cluster Support**
- Automatic cluster node detection
- Multi-node count display
- Warning messages for cluster deployments
- Instructions for cluster-wide updates
- Reference to cluster update tools

### Command-Line Options

```bash
# Display installer version
./install.sh --version

# Show help and usage information
./install.sh --help

# Non-interactive mode (for automation/scripts)
./install.sh --non-interactive
```

### Non-Interactive Installation

For automation or CI/CD pipelines:

```bash
# Download and install automatically
wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash -s -- --non-interactive
```

Or download first:
```bash
# Download installer
wget https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh
chmod +x install.sh

# Run in non-interactive mode
./install.sh --non-interactive
```

Non-interactive mode will:
- Install the latest plugin version automatically
- Skip all interactive prompts
- Use safe defaults for all options
- Log all actions to `/var/log/truenas-installer.log`
- Exit with appropriate status codes (0=success, 1=error)

### Installer Workflow Examples

#### First-Time Installation
```bash
# Run the one-liner
wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash

# Installer will:
# 1. Download and install plugin v1.0.7 (latest)
# 2. Prompt: "Would you like to configure storage now? (Y/n)"
# 3. If yes: Launch configuration wizard
# 4. Prompt: "Would you like to run a health check? (Y/n)"
# 5. If yes: Run 11-point health validation
# 6. Display next steps and documentation links
```

#### Updating Existing Installation
```bash
# Run the installer again
./install.sh

# Main menu will show:
# "Plugin Status: Installed (v1.0.6)"
# "Update Available: v1.0.7"

# Choose option 1: "Update to latest version"
# Installer will:
# 1. Create backup of v1.0.6
# 2. Download and install v1.0.7
# 3. Validate syntax
# 4. Restart services
# 5. Offer to run health check
```

#### Configuration Wizard
```bash
# From main menu, choose "Configure storage"

# Wizard will prompt for:
Storage name (e.g., 'truenas-storage'): truenas-prod
TrueNAS IP address: 192.168.1.100
TrueNAS API key: 1-abc123def456...
ZFS dataset path: tank/proxmox
iSCSI target IQN: iqn.2005-10.org.freenas.ctl:proxmox
Discovery portal (IP:PORT): 192.168.1.100:3260
Enable multipath? (y/N): n
Enable API insecure mode? (Y/n): y

# Wizard then:
# ✓ Tests TrueNAS API connectivity
# ✓ Verifies dataset exists
# ✓ Generates configuration block
# ✓ Shows preview for review
# ✓ Backs up /etc/pve/storage.cfg
# ✓ Appends new configuration
# ✓ Confirms success
```

#### Health Check
```bash
# From main menu, choose "Run health check"

# Health check validates (with spinners):
# ✓ Plugin file exists
# ✓ Plugin syntax valid
# ✓ Storage configuration found
# ✓ TrueNAS API connectivity
# ✓ Storage status active
# ✓ Dataset exists on TrueNAS
# ✓ iSCSI sessions established
# ✓ Service pvedaemon running
# ✓ Service pveproxy running
# ✓ Multipath configuration (if enabled)
# ✓ No critical errors in logs

# Summary: 11/11 checks passed (0 warnings, 0 critical)
```

#### Rollback to Previous Version
```bash
# From main menu, choose "Rollback to previous version"

# Displays available backups:
Available Backups:
  1) v1.0.7 - 2025-10-25 14:32:15 (2 hours ago) - 89.2 KB
  2) v1.0.6 - 2025-10-24 09:15:42 (1 day ago) - 88.8 KB
  3) v1.0.5 - 2025-10-20 11:22:03 (5 days ago) - 87.1 KB

Select backup to restore (1-3):
```

#### Backup Management
```bash
# From main menu, choose "Manage backups"

# Shows statistics:
Total backups: 12 files (1.1 MB)
Oldest: 2025-08-15 (70 days ago)
Newest: 2025-10-25 (2 hours ago)

# Options:
1) View all backups
2) Delete backups older than N days
3) Keep only latest N backups
4) Delete all backups
5) Return to main menu

# Example: Keep only latest 5
# Installer will:
# ✓ List backups to be deleted (7 files)
# ✓ Confirm deletion
# ✓ Delete old backups
# ✓ Log actions
# ✓ Show freed space
```

### Cluster Installation with Installer

For Proxmox clusters, install on each node:

```bash
# On first node
wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash

# Installer will detect cluster and show:
⚠ Cluster Detected: 3 nodes in cluster
⚠ Remember to install on all cluster nodes!

# On remaining nodes, run the same command:
ssh root@node2 "wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash"
ssh root@node3 "wget -qO- https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/install.sh | bash"

# Or use the cluster update script (see Tools and Utilities guide)
```

### Installer Logs

All installer operations are logged for troubleshooting:

```bash
# View installer logs
tail -f /var/log/truenas-installer.log

# Check for errors
grep ERROR /var/log/truenas-installer.log

# View recent operations
tail -n 100 /var/log/truenas-installer.log
```

### Installer Troubleshooting

**Missing Dependencies**
```bash
# Installer checks for: curl or wget, jq, perl
# If missing, installer will display clear error:

ERROR: Required dependency 'jq' not found
Please install: apt-get install jq

# Install dependencies:
apt-get update
apt-get install curl jq perl
```

**Permission Issues**
```bash
# Installer must run as root
# If not root, you'll see:

ERROR: This script must be run as root
Please run: sudo ./install.sh

# Fix:
sudo ./install.sh
```

**GitHub API Rate Limiting**
```bash
# If you hit GitHub rate limits:

ERROR: GitHub API rate limit exceeded
Please try again in 1 hour, or use a GitHub token

# Wait or use authentication:
export GITHUB_TOKEN=your_github_token
./install.sh
```

## Manual Installation

If you prefer manual installation or need more control over the process, follow these steps.

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
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set proper permissions
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

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
systemctl restart pvedaemon
systemctl restart pveproxy

# Verify services are running
systemctl status pvedaemon
systemctl status pveproxy
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
cd tools/
./update-cluster.sh node1 node2 node3
```

Or manually on each node:

```bash
# On each cluster node
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
systemctl restart pvedaemon pveproxy
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
zfs create tank/proxmox
zfs set compression=lz4 tank/proxmox
zfs set atime=off tank/proxmox
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
systemctl status iscsitarget

# Verify iSCSI is listening
netstat -tuln | grep 3260
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
# Allocate a small test volume (1GB)
pvesm alloc truenas-storage 999 test-disk-0 1G

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
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Restart services
systemctl restart pvedaemon pveproxy

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
iptables -L -n | grep 443

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
cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
  /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm.backup

# Copy new version
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Restart services
systemctl restart pvedaemon pveproxy
```

### Cluster Update
```bash
# Use the deployment script
cd tools/
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
rm /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Remove storage configuration from /etc/pve/storage.cfg
# (edit manually to remove truenasplugin entries)

# Restart services
systemctl restart pvedaemon pveproxy
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
