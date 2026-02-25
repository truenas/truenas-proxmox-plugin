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

### Install via Official APT Repository

Use the APT repository if you want standard package install and upgrade workflows.

#### Option 1: Installer bootstrap (recommended)

Run the installer in non-interactive mode with APT setup and package install:

```bash
curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash -s -- --non-interactive --apt-install
```

Optional suite override:

```bash
curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash -s -- --non-interactive --apt-install --apt-suite trixie
```

Suite mapping:
- Proxmox VE 8 -> `bookworm`
- Proxmox VE 9 -> `trixie`

#### Option 2: Manual deb822 repository setup

Repository URL: `https://truenas.github.io/truenas-proxmox-plugin/apt/`
Key URL: `https://truenas.github.io/truenas-proxmox-plugin/apt/pubkey.gpg`

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/apt/pubkey.gpg -o /etc/apt/keyrings/truenas-proxmox-plugin.gpg

cat >/etc/apt/sources.list.d/truenas-proxmox-plugin.sources <<'EOF'
Types: deb
URIs: https://truenas.github.io/truenas-proxmox-plugin/apt/
Suites: bookworm
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/truenas-proxmox-plugin.gpg
EOF
```

If you are on Proxmox VE 9, set `Suites: trixie` in the `.sources` file.

Install and upgrade commands:

```bash
apt-get update
apt-get install -y truenas-proxmox-plugin

# Upgrade to newer plugin packages from the repository
apt-get update
apt-get install --only-upgrade -y truenas-proxmox-plugin
```

### Quick Start - One-Line Installation

Install the plugin with a single command:

```bash
wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash
```

Or using curl:
```bash
curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash
```

The installer will:
1. ✅ Check for required dependencies (curl/wget, perl)
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
  1) Update plugin
  2) Install specific version
  3) Configure storage
  4) Diagnostics
  5) Manage backups
  6) Rollback to previous version
  7) Uninstall plugin
  8) Exit

Choose an option:
```

#### Available Operations

**Installation & Updates**
- Install latest version from GitHub
- Install specific version (numbered version selection, no typing required)
- Update plugin with sub-menu for local or cluster-wide update
- Automatic update detection and notification

**Configuration Management**
- Interactive configuration wizard
- Add, edit, or delete storage configurations
- Delete storage with typed confirmation (storage name must be entered exactly)
- Transport mode selection (iSCSI or NVMe/TCP)
- Guided setup for all storage parameters
- Input validation (IP addresses, API keys, dataset names, NQNs)
- TrueNAS API connectivity testing
- Dataset verification via API
- Automatic portal discovery for multipath configuration
- Transport-specific checks (nvme-cli for NVMe/TCP, multipath-tools for iSCSI)
- Automatic backup of storage.cfg

**Diagnostics Menu**
- Unified diagnostics menu for troubleshooting and maintenance
- 12-point comprehensive health validation
  - Transport-aware validation (iSCSI and NVMe/TCP)
  - Plugin file verification and syntax check
  - Storage configuration validation
  - TrueNAS API connectivity test
  - iSCSI session monitoring or NVMe connection verification
  - Multipath status check (dm-multipath for iSCSI, native for NVMe)
  - Orphaned resource detection (iSCSI only)
  - Service verification (pvedaemon, pveproxy)
- Integrated orphan cleanup functionality
  - Detects orphaned iSCSI extents, zvols, and target-extent mappings
  - Displays detailed orphan list with reasons
  - Typed "DELETE" confirmation required for safety
  - Ordered deletion (mappings, then extents, then zvols)
- Integrated plugin function testing
  - 8 core tests validating plugin operations (storage, volumes, snapshots, clones, resize, VM lifecycle)
  - Interactive confirmation with typed "ACCEPT"
  - Storage selection from configured TrueNAS storages
  - Health-check style display with spinners and inline status
  - Automatic cleanup of test VMs
  - Dynamic VM ID selection (990+)
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
- Cluster-wide installation from single command
- SSH connectivity validation
- Sequential remote installation with progress tracking
- Automatic retry logic for failed nodes
- Per-node success/failure reporting

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
wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash -s -- --non-interactive
```

Or download first:
```bash
# Download installer
wget https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh
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
wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash

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

# Choose option 1: "Update plugin"
# Sub-menu will present:
#   1) Update this node only
#   2) Update all cluster nodes (if cluster detected)
#   0) Cancel

# After selecting update target, installer will:
# 1. Create backup of v1.0.6
# 2. Download and install v1.0.7
# 3. Validate syntax
# 4. Restart services
# 5. Offer to run health check
```

#### Configuration Wizard
```bash
# From main menu, choose "Configure storage"

# If existing storages found, sub-menu appears:
#   1) Edit an existing storage
#   2) Add a new storage
#   3) Delete a storage
#   0) Cancel

# === Adding New Storage ===
# Wizard will prompt for:
Storage name (e.g., 'truenas-storage'): truenas-prod
TrueNAS IP address: 192.168.1.100
TrueNAS API key: 1-abc123def456...
ZFS dataset path: tank/proxmox

# Transport mode selection:
Select transport protocol:
  1) iSCSI (traditional, widely compatible)
  2) NVMe/TCP (modern, lower latency)
Transport mode (1-2) [1]: 1

# === If iSCSI selected ===
iSCSI target IQN: iqn.2005-10.org.freenas.ctl:proxmox
Portal IP (optional, press Enter to use TrueNAS IP): 192.168.1.100
Block size [16K]: 16K
Enable sparse volumes? (0/1) [1]: 1

# Advanced Options:
Enable multipath I/O for redundancy/load balancing? (y/N): y

# If multipath enabled, wizard will:
# ✓ Check for multipath-tools package installation (iSCSI)
# ✓ Discover available portal IPs from TrueNAS network interfaces
# ✓ Present selectable list of discovered portals
# ✓ Allow manual portal entry if discovery fails
# ✓ Warn if no additional portals configured

# === If NVMe/TCP selected ===
# ✓ Checks for nvme-cli package (offers to install if missing)
# ✓ Auto-populates host NQN from /etc/nvme/hostnqn (or generates one)
NVMe subsystem NQN (e.g., nqn.2005-10.org.freenas.ctl:proxmox): nqn.2005-10.org.freenas.ctl:proxmox-nvme
Portal IP (default: 192.168.1.100:4420): 192.168.1.100:4420
Block size [16K]: 16K
Enable sparse volumes? (0/1) [1]: 1

# NVMe/TCP uses native kernel multipath:
# ✓ Detects native NVMe multipath status
# ✓ Discovers available portals (port 4420)
# ✓ No dm-multipath required

# Example multipath portal selection:
Discovering available portals from TrueNAS...
Found available portal IPs:
  1) 192.168.1.101
  2) 192.168.1.102
  3) 192.168.2.100

Select additional portals for multipath (space-separated numbers, e.g., '1 2')
Note: Portals should be on different subnets for proper multipath operation
Portal numbers (or press Enter to skip): 1 2

# Wizard then:
# ✓ Tests TrueNAS API connectivity
# ✓ Verifies dataset exists
# ✓ Generates configuration block with transport-specific settings
# ✓ Shows preview for review
# ✓ Backs up /etc/pve/storage.cfg
# ✓ Appends new configuration
# ✓ Confirms success
# ✓ Provides transport-specific verification commands

# === Deleting Storage ===
# Select "Delete a storage" from configuration menu
# Choose storage from numbered list
# Warning displayed about implications (VMs will lose disk access)
# Type exact storage name to confirm deletion
# Storage block removed from /etc/pve/storage.cfg
# Optionally run orphan cleanup if iSCSI storage
```

#### Diagnostics Menu
```bash
# From main menu, choose "Diagnostics"

# Diagnostics sub-menu:
#   1) Run health check
#   2) Create diagnostics bundle
#   3) Cleanup orphaned resources
#   4) Run plugin function test
#   0) Back to main menu

# === Option 1: Health Check ===
# Select storage from list
# Screen clears and displays "Health Check" header
# Shows "Running health check on storage: X" message
# Health check validates (with spinners and 30-character label formatting):
# Plugin file:                   ✓ Installed v1.1.3
# Storage configuration:         ✓ Configured
# Storage status:                ✓ Active (space usage shown)
# Content type:                  ✓ images
# TrueNAS API:                   ✓ Reachable on IP:port
# Dataset:                       ✓ dataset/path
# Target IQN/Subsystem NQN:      ✓ (transport-specific)
# Discovery portal:              ✓ IP:port
# iSCSI sessions/NVMe connections: ✓ (transport-specific)
# Orphaned resources:            ✓ None detected (iSCSI only)
# Service pvedaemon:             ✓ Running
# Service pveproxy:              ✓ Running
# Multipath configuration:       ✓ (dm-multipath or native NVMe, if enabled)

# Summary: 12/12 checks passed (0 warnings, 0 critical)

# Note: Health checks automatically detect transport mode and perform
# transport-specific validation (iSCSI vs NVMe/TCP)
# All labels use 30-character fixed width for consistent alignment

# === Option 2: Create Diagnostics Bundle ===
# Type "CAPTURE" (in caps) to start capture
# Validates pvestatd is running
# Starts 10-minute strace capture of pvestatd
# Monitors pvestatd status during capture
# Collects 13 diagnostic sections (plugin info, environment, storage config,
# process state, logs, crash dumps, etc.)
# Creates compressed tarball at /tmp/truenas-diag-TIMESTAMP.tar.gz
# Shows file size and output location

# === Option 3: Cleanup Orphaned Resources ===
# Select storage from list
# Scans for orphaned iSCSI resources:
#   - Extents pointing to deleted zvols
#   - Zvols without corresponding extents
#   - Target-extent mappings without extents
# Displays detailed orphan list with reasons
# Type "DELETE" (in caps) to confirm cleanup
# Deletes orphans in safe order (mappings → extents → zvols)
# Note: iSCSI only - NVMe/TCP shows unsupported message

# === Option 4: Run Plugin Function Test ===
# Displays "Plugin Function Test" header after storage selection
# Shows test description and requirements
# Shows what operations will be performed
# Type "ACCEPT" (in caps) to confirm
# Select storage to test from configured list
# Screen clears and shows "Running plugin function test on storage: X"
# Displays detected transport mode (iSCSI or NVMe/TCP)
# Runs 8 comprehensive tests with 30-character label formatting:
#   Storage accessibility         ✓ Storage active and accessible
#   Volume creation                ✓ Created 4GB disk successfully
#   Volume listing                 ✓ Retrieved volume configuration
#   Snapshot operations            ✓ Snapshot created and verified
#   Clone operations               ✓ Cloned VM from snapshot
#   Volume resize                  ✓ Expanded disk by 1GB
#   VM start/stop lifecycle        ✓ VM started and stopped
#   Volume deletion                ✓ Cleaned up test resources
# Summary: "Plugin Function Test Summary: 8/8 tests passed" (or failure count)
# All test VMs automatically cleaned up
# Note: Uses health-check style display with spinners and inline status updates
# Ctrl+C gracefully interrupts with cleanup and user-friendly message
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

For Proxmox clusters, the installer can deploy to all nodes simultaneously:

#### Option 1: Cluster-Wide Installation (Recommended)

Run the installer interactively on any cluster node:

```bash
# On any cluster node
wget https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh
chmod +x install.sh
./install.sh

# The installer will:
# 1. Detect cluster membership automatically
# 2. Offer "Install latest version (all cluster nodes)" in menu
# 3. Validate SSH connectivity to all nodes
# 4. Install on local node first
# 5. Deploy to all remote nodes sequentially
# 6. Show per-node success/failure status
# 7. Offer retry for any failed nodes
```

**Features**:
- ✅ Single command deploys to entire cluster
- ✅ Pre-flight SSH validation
- ✅ Automatic backup on each node
- ✅ Progress tracking ([1/3], [2/3], [3/3])
- ✅ Detailed failure reporting
- ✅ Automatic retry with 5-second backoff

**Requirements**:
- Passwordless SSH between cluster nodes (automatically configured by Proxmox)
- Interactive mode (cluster-wide installation not available in --non-interactive)

**Example Output**:
```
Installing TrueNAS Plugin (Cluster-Wide)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Current node: pve-m920x-1
Remote nodes: 2
  • pve-m920x-2 (10.15.14.196)
  • pve-m920x-3 (10.15.14.197)

Validating SSH connectivity to cluster nodes...
  Testing pve-m920x-2 (10.15.14.196)... ✓ Reachable
  Testing pve-m920x-3 (10.15.14.197)... ✓ Reachable

All cluster nodes are reachable via SSH

Installing on local node (pve-m920x-1)...
✓ Local node installation completed

Installing on remote cluster nodes...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1/2] pve-m920x-2 (10.15.14.196): ✓ Success
[2/2] pve-m920x-3 (10.15.14.197): ✓ Success

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Successfully updated 3 of 3 nodes:
  ✓ pve-m920x-1
  ✓ pve-m920x-2
  ✓ pve-m920x-3
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### Option 2: Manual Installation on Each Node

If you prefer manual installation:

```bash
# On first node
wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash

# On remaining nodes
ssh root@node2 "wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash"
ssh root@node3 "wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash"
```

### Cluster Installation Troubleshooting

**SSH Connectivity Issues**

If cluster installation fails SSH validation:

```bash
# Test SSH manually from current node
ssh root@<node-ip> hostname

# Should return the node hostname without prompting for password
# If it prompts for password, Proxmox cluster SSH keys may not be set up

# Check SSH key distribution
ls -la /root/.ssh/authorized_keys

# Verify cluster membership
cat /etc/pve/.members

# Check cluster status
pvecm status
```

**Partial Installation Failures**

If some nodes succeed and others fail:

1. Review the failure reason shown in the summary
2. Use the automatic retry option when prompted
3. Check logs on failed nodes: `ssh root@<failed-node> 'tail /var/log/truenas-installer.log'`
4. Fix the issue (network, disk space, permissions)
5. Re-run cluster installation - already-updated nodes are skipped

**Non-Interactive Mode Limitation**

Cluster-wide installation requires interactive mode:

```bash
# This will NOT install cluster-wide
./install.sh --non-interactive

# Use interactive mode for cluster deployment
./install.sh
# Then select cluster-wide option from menu
```

**Manual Verification**

After cluster installation, verify on each node:

```bash
# Check plugin installed on all nodes
for node in node1 node2 node3; do
  ssh root@$node "ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
done

# Verify version on all nodes
for node in node1 node2 node3; do
  echo -n "$node: "
  ssh root@$node "perl -ne 'print \$1 if /VERSION\s*=\s*['\''\"]\([0-9.]+\)/' /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
done

# Check services running
for node in node1 node2 node3; do
  echo "$node:"
  ssh root@$node "systemctl is-active pvedaemon pveproxy"
done
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

# Check remote installation logs
grep "Remote installation" /var/log/truenas-installer.log
```

### Installer Troubleshooting

**Missing Dependencies**
```bash
# Installer checks for: curl or wget, perl
# If missing, installer will display clear error:

ERROR: Required dependency 'curl' or 'wget' not found
Please install: apt-get install curl wget

# Install dependencies:
apt-get update
apt-get install curl perl
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
- **TrueNAS SCALE** - 25.10 or later (required)

- **Perl** - 5.36 or later (included with Proxmox VE)

### Network Requirements
- **iSCSI Connectivity** - TCP/3260 between Proxmox nodes and TrueNAS
- **TrueNAS API Access** - HTTPS/443 for WebSocket API (HTTP is not supported)
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
Note: `STORAGE_ID` should be an existing TrueNAS plugin storage ID in `/etc/pve/storage.cfg`.
```bash
# Replace STORAGE_ID with your storage name
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"iscsi.target.query\", [[]]); my $count = ref($res) eq \"ARRAY\" ? scalar(@$res) : 0; print \"targets=\$count\\n\";'"

# Should report a non-zero target count
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
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"system.info\", []); print $res->{version}, \"\\n\" if ref($res) eq \"HASH\" && $res->{version}; print \"\\n\";'"

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
