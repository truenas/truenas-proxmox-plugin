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
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh) --non-interactive --apt-install
```

Optional suite override:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh) --non-interactive --apt-install --apt-suite trixie
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

> **Note:** The APT repository only serves **stable releases**. Pre-release
> builds (`-alpha*`, `-beta*`, `-rc*`) are intentionally excluded so that
> `apt upgrade` on a production cluster never pulls in an unstable build.
> If a maintainer has asked you to try a beta, or if you need a newer
> release than what APT serves, use `install.sh`'s **"Install specific
> version"** menu entry (interactive mode) or the Debian package attached
> to the corresponding
> [GitHub release](https://github.com/truenas/truenas-proxmox-plugin/releases).
> See [Installing a specific pre-release build](#installing-a-specific-pre-release-build)
> below.

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
║                  Installer v2.0.0                        ║
╚══════════════════════════════════════════════════════════╝

Plugin Status: Installed (v2.1.23)
Update Available: v2.1.24

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

The update path follows the install path, and only a package install is
supported for 2.1.24. An APT- or dpkg-managed node is updated as a package.
A node installed by an older installer from a raw `.pm` pull is a legacy
state: the installer can replace that file, but a 2.1.24 `.pm` on its own
has no broker, so every call fails. Convert such a node to the package
(`apt-get install -y truenas-proxmox-plugin`, or `dpkg -i` the release
`.deb`) instead of copying another file. Check whether the node is
package-managed with `dpkg -s truenas-proxmox-plugin`.

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
- 13-point comprehensive health validation
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

### Installing a specific pre-release build

The APT repository only publishes stable releases. Pre-release builds
(`v*-alpha*`, `v*-beta*`, `v*-rc*`) are not pushed there, so running
`apt install truenas-proxmox-plugin` on a fresh system always lands on
the current stable (e.g. `2.1.23+deb1`), even when a newer beta is the
one tagged **Latest** on GitHub. This is intentional — it keeps
unattended upgrades on production clusters from pulling in a beta — but
it means you need to use `install.sh` or a direct download when a
maintainer asks you to try a specific build.

**Interactive (menu):**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh)
```

Select **"Install specific version"** from the main menu, then pick
the beta from the list (pre-releases are flagged in the version list).

**Direct `.deb` from the GitHub release page:**

Each release attaches a signed `.deb` plus `SHA256SUMS`. Open the
release page in a browser (e.g.
<https://github.com/truenas/truenas-proxmox-plugin/releases/tag/v2.1.24-beta8>),
right-click the `.deb` link to copy its URL, then from any cluster
node:

```bash
curl -sSL -O "<the .deb URL you copied>"
curl -sSL -O "<the SHA256SUMS URL from the same page>"
sha256sum -c SHA256SUMS --ignore-missing
dpkg -i truenas-proxmox-plugin_*.deb
```

(Note: GitHub converts `~` to `.` in asset filenames at upload time, so
the file you download is named `truenas-proxmox-plugin_2.1.24.beta8_all.deb`
while `SHA256SUMS` references the original `~beta8` form. `sha256sum -c
--ignore-missing` tolerates the mismatch; if you want strict
verification, verify the hash by hand with `sha256sum
truenas-proxmox-plugin_*.deb` and compare to the value in `SHA256SUMS`.)

When the beta you installed is later promoted to a stable release and
published to the APT repo, `apt upgrade` will catch up to it on its own
on the next run.

### Installer Workflow Examples

#### First-Time Installation
```bash
# Run the one-liner
wget -qO- https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh | bash

# Installer will:
# 1. Download and install plugin (latest)
# 2. Prompt: "Would you like to configure storage now? (Y/n)"
# 3. If yes: Launch configuration wizard
# 4. Prompt: "Would you like to run a health check? (Y/n)"
# 5. If yes: Run 13-point health validation
# 6. Display next steps and documentation links
```

#### Updating Existing Installation
```bash
# Run the installer again
./install.sh

# Main menu will show:
# "Plugin Status: Installed (v2.1.23)"
# "Update Available: v2.1.24"

# Choose option 1: "Update plugin"
# Sub-menu will present:
#   1) Update this node only
#   2) Update all cluster nodes (if cluster detected)
#   0) Cancel

# After selecting update target, installer will:
# 1. Create backup of v2.1.23
# 2. Download and install v2.1.24
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
# Plugin file:                   ✓ Installed v2.1.24
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
  1) v2.1.24 - 2026-03-31 14:32:15 (2 hours ago) - 89.2 KB
  2) v2.1.23 - 2026-03-28 09:15:42 (3 days ago) - 88.8 KB
  3) v2.1.22 - 2026-03-25 11:22:03 (6 days ago) - 87.1 KB

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

#### 1. Install the Package

The plugin is only supported as a Debian package. The package installs all
of its runtime pieces:

- `TrueNASPlugin.pm` and `TrueNAS/SCRAM.pm`
- `/usr/sbin/truenas-plugin-broker` and its systemd unit
- `/usr/sbin/truenas-plugin-lvm-filter`
- `/usr/share/truenas-proxmox-plugin/install.sh`

`postinst` enables and starts `truenas-plugin-broker`, waits for
`/run/truenas-plugin/broker.sock`, and restarts the PVE daemons that load
the plugin.

Install with the APT repository configured (see [Automated Installation](#automated-installation-recommended)):

```bash
apt-get update
apt-get install -y truenas-proxmox-plugin
```

Or install the `.deb` from the GitHub release page:

```bash
# See "Installing a specific pre-release build" for the download steps
dpkg -i truenas-proxmox-plugin_<version>_all.deb
```

Verify the install:

```bash
dpkg -l truenas-proxmox-plugin
systemctl is-active truenas-plugin-broker
ls -l /run/truenas-plugin/broker.sock
```

> **Do not install by copying `TrueNASPlugin.pm` alone.** A file-only copy
> leaves the broker binary and its unit absent, so
> `/run/truenas-plugin/broker.sock` never appears and every plugin call
> dies with `[TrueNAS] broker socket missing at
> /run/truenas-plugin/broker.sock`. Direct WebSocket mode exists only
> behind the unsupported `TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1` escape hatch.

#### 2. Configure Storage

Add storage configuration to `/etc/pve/storage.cfg`:

```ini
truenasplugin: truenas-storage
    tn_api_host 192.168.1.100
    tn_api_key 1-your-truenas-api-key-here
    tn_target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.1.100:3260
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

Use the installer's cluster-wide deployment feature:

```bash
# Run the installer on any cluster node
./install.sh

# Select "Install latest version (all cluster nodes)"
# The installer will automatically discover and deploy to all nodes
```

Or manually on each node:

```bash
# On each cluster node, with the plugin APT repository configured
for node in node1 node2 node3; do
  ssh root@$node "apt-get update && apt-get install -y truenas-proxmox-plugin"
done
```

Install the same package version on every node.

#### 3. Configure Shared Storage

The storage configuration in `/etc/pve/storage.cfg` is automatically shared across cluster nodes. Ensure `shared 1` is set:

```ini
truenasplugin: cluster-storage
    tn_api_host 192.168.10.100
    tn_api_key 1-your-api-key
    tn_target_iqn iqn.2005-10.org.freenas.ctl:cluster
    tn_dataset tank/cluster/proxmox
    tn_discovery_portal 192.168.10.100:3260
    tn_portals 192.168.10.101:3260,192.168.10.102:3260
    content images
    shared 1
    tn_use_multipath 1
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

Minimum TrueNAS SCALE version: **25.10** (Goldeye). Both iSCSI and
NVMe/TCP share this floor.

The TN UI changed between the 25.10 Goldeye and 26.0 release lines.
Section 2 below walks the 25.10 flow in detail; section 3 lists the
small deltas on 26.x. Dataset creation (section 1) and CHAP /
verification (sections 4-5) are identical on both.

### 1. Create a ZFS dataset

Navigate to **Datasets** → **Add Dataset**:
- **Name**: `proxmox` (or your preferred name)
- **Parent**: your storage pool (e.g. `tank`)
- **Dataset Preset**: Generic
- **Compression**: `lz4` (recommended)
- **Enable Atime**: Off (recommended for performance)

Via CLI:

```bash
zfs create tank/proxmox
zfs set compression=lz4 tank/proxmox
zfs set atime=off tank/proxmox
```

### 2. iSCSI setup — TrueNAS SCALE 25.10 (Goldeye)

#### 2a. Enable the iSCSI service

Nav: **System** → **Services**.
- In the **iSCSI** row, click the **play** button under the Status
  column to start it now.
- Toggle **Start Automatically** on so it comes up at boot.

Verify from a shell:

```bash
# On TrueNAS: confirm scst listening
netstat -tuln | grep 3260
```

#### 2b. Set the iSCSI Base Name

Nav: **System** → **Services** → **iSCSI** row → **pencil** (edit)
icon on the right end.

The right-side drawer titled **"iSCSI Global Configuration"** opens.
Fields in order:
- **Base Name\*** — the TN default is `iqn.2005-10.org.freenas.ctl`
  and it works fine. Any value is accepted as long as it starts
  with `iqn.`. A base name that does NOT start with `iqn.` (e.g.
  `TrueNAS`) produces invalid target IQNs and no initiator will
  connect — this is the shape of issue #117.
- **iSNS Servers** — leave empty unless you run an iSNS server.
- **Pool Available Space Threshold (%)** — optional free-space
  guard; leave empty for defaults.
- **iSCSI listen port\*** — default `3260`.
- **Enable iSCSI Extensions for RDMA (ISER)** — leave unchecked
  for standard iSCSI/TCP.

Click **Save**.

Note the Base Name value: the plugin needs it as `tn_target_iqn`
in `storage.cfg`, combined with the Target Name you pick next, as
`<Base Name>:<Target Name>` (for example
`iqn.2005-10.org.freenas.ctl:proxmox`).

#### 2c. Create target, extent, and portal via the iSCSI Wizard

Nav: **Shares** → find the **Block (iSCSI) Shares Targets** card →
click the **Wizard** button on the card.

The right-side drawer titled **"iSCSI Wizard"** opens with three
numbered steps.

**Step 1 — Target.**
- **Target\*** dropdown: leave on **Create New** (TN will prompt
  for the Target Name on Save).
- Click **Next**.

**Step 2 — Extent.**
- **Name\***: an extent name on TN (any string, used for
  bookkeeping).
- **Extent Type\***: **Device**.
- **Device\***: pick the zvol path on TN that you want to publish.
- **Sharing Platform\***: pick a modern-OS-style preset. The
  VMware-tuned default enables block-size optimizations that
  aren't what Proxmox expects.
- Click **Next**.

**Step 3 — Protocol Options.**
- **Portal\***: `Create New` to spin up a portal on
  `0.0.0.0:3260`, or pick an existing portal.
- **Initiators**: leave empty to allow any initiator to connect,
  or paste comma-separated initiator IQNs if you want to lock
  access down.
- Click **Save**.

> **Both Portal and the Initiator field on step 3 are what make
> the target reachable.** If either is left blank at Save time,
> `iscsiadm --mode discovery` from Proxmox returns empty and the
> plugin can only get as far as allocating zvols on TN. That's
> the most common first-install symptom and the shape of issue
> #117.

(A per-tab manual flow still exists at
`/ui/sharing/iscsi/targets` — tabs for Targets / Extents /
Initiators / Portals / Authorized Access, plus a **Global Target
Configuration** button that opens the same Base Name drawer as
2b. Use it only if you need per-field control the Wizard doesn't
expose.)

#### 2d. Create an API key for root

Nav: **top-right user menu** (person icon labeled "root") → **My
API Keys** → **Add**.

Enter a name (e.g. `proxmox-plugin`) and Save. **Copy the key
value immediately** — TN only shows it once. Paste it into
`tn_api_key` in `/etc/pve/storage.cfg`.

Alternative: a dedicated non-root user with a least-privilege API
key. See [Minimum API Permissions](API-Permissions.md) for the
exact role set, verified method-by-method against TrueNAS RBAC.

### 3. iSCSI setup — TrueNAS SCALE 26.0 and later

The 26.x UI is nearly identical to 25.10 for the setup covered in
section 2. Follow steps 2a through 2d above, with these cosmetic
deltas:

- **Shares page** has a 5th card for **WebShare**. Unrelated to
  this plugin; ignore it.
- **iSCSI Wizard → Extent step** has an extra **Read-only**
  checkbox. Leave it unchecked for Proxmox.
- **Top-right user menu** has an extra **Preferences** item. **My
  API Keys** is in the same place.
- **Services page** has an extra **WebShare** row (same as the
  Shares-page card). Ignore.

Everything else — service enable path, Base Name drawer location
and fields, Wizard flow and fields, API key page — matches 25.10.

### 4. Optional: Configure CHAP Authentication

If you want CHAP (one-way) on the iSCSI target, add an
**Authorized Access** entry under the manual flow at
`/ui/sharing/iscsi/targets` → **Authorized Access** tab:

- Click **Add**.
- **Group ID**: `1` (or next available).
- **User**: a CHAP username (any string).
- **Secret**: a 12-16 character CHAP password.
- Leave **Peer User** / **Peer Secret** empty.
- Click **Save**.

Then edit the **Portal** that the iSCSI Wizard created in step 2c:
- **Portals** tab → edit your portal.
- **Discovery Auth Method**: CHAP.
- **Discovery Auth Group**: pick the Group ID you just created.
- Click **Save**.

Update Proxmox's `/etc/pve/storage.cfg` entry:

```ini
truenasplugin: truenas-storage
    # ... other settings ...
    tn_chap_user your-chap-username
    tn_chap_password your-chap-password
```

### 5. Verify TrueNAS Configuration

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
# tn_api_retry_max must be 0-10
# tn_api_retry_delay must be 0.1-60

# Verify all required parameters present:
# - tn_api_host
# - tn_api_key
# - tn_dataset
# - tn_target_iqn
# - tn_discovery_portal
```

## Updating the Plugin

Update the package. Replacing the `.pm` by hand desyncs dpkg from the file
on disk on a package-managed node, and on a raw-file node it leaves the
broker missing; convert that node to the package instead of overwriting
the file.

### Single Node Update
```bash
# APT-managed install
apt-get update
apt-get install --only-upgrade -y truenas-proxmox-plugin

# dpkg-only install (no plugin APT source)
dpkg -i truenas-proxmox-plugin_<version>_all.deb
```

`postinst` restarts `pvedaemon`, `pvestatd`, `pvescheduler` and the HA
daemons immediately, and `pveproxy` after a short delay, so no manual
restart is needed. Set `TRUENAS_PLUGIN_NO_RESTART=1` on the `dpkg -i` run to
skip the PVE-side restarts.

Check the installed version with:

```bash
dpkg-query -W -f='${Version}\n' truenas-proxmox-plugin
```

### Cluster Update
```bash
# Run the installer and select "Update plugin" → "Update all cluster nodes"
./install.sh

# Or manually on each node
for node in node1 node2 node3; do
  ssh root@$node "apt-get install --only-upgrade -y truenas-proxmox-plugin"
done
```

## Uninstallation

### Remove Plugin
```bash
# Remove the package
apt-get remove -y truenas-proxmox-plugin

# Or, for a dpkg-only install
dpkg -r truenas-proxmox-plugin

# Remove storage configuration from /etc/pve/storage.cfg
# (edit manually to remove the truenasplugin: entries)

# Restart services
systemctl restart pvedaemon pveproxy
```

Package removal leaves `/etc/pve/storage.cfg` intact. Delete every
`truenasplugin:` entry as well, otherwise PVE keeps trying to load a storage
type that is no longer installed.

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
