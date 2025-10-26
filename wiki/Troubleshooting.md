# Troubleshooting Guide

Common issues and solutions for the TrueNAS Proxmox VE Storage Plugin.

## Table of Contents

- [Installer Issues](#installer-issues)
  - [Installation Failed](#installation-failed)
  - [Missing Dependencies](#missing-dependencies)
  - [Permission Denied](#permission-denied)
  - [GitHub API Rate Limiting](#github-api-rate-limiting)
  - [Service Restart Failures](#service-restart-failures)
  - [Configuration Wizard Issues](#configuration-wizard-issues)
  - [Health Check Failures](#health-check-failures)
- [About Plugin Error Messages](#about-plugin-error-messages)
- [Storage Status Issues](#storage-status-issues)
  - [Storage Shows as Inactive](#storage-shows-as-inactive)
- [Connection and API Issues](#connection-and-api-issues)
  - ["Could not connect to TrueNAS API"](#could-not-connect-to-truenas-api)
  - [API Rate Limiting](#api-rate-limiting)
- [iSCSI Discovery and Connection Issues](#iscsi-discovery-and-connection-issues)
  - ["Could not discover iSCSI targets"](#could-not-discover-iscsi-targets)
  - ["Could not resolve iSCSI target ID for configured IQN"](#could-not-resolve-iscsi-target-id-for-configured-iqn)
  - [iSCSI Session Issues](#iscsi-session-issues)
- [Volume Creation Issues](#volume-creation-issues)
  - ["Failed to create iSCSI extent for disk"](#failed-to-create-iscsi-extent-for-disk)
  - ["Insufficient space on dataset"](#insufficient-space-on-dataset)
  - ["Unable to find free disk name after 1000 attempts"](#unable-to-find-free-disk-name-after-1000-attempts)
  - ["Volume created but device not accessible after 10 seconds"](#volume-created-but-device-not-accessible-after-10-seconds)
- [VM Deletion Issues](#vm-deletion-issues)
  - [Orphaned Volumes After VM Deletion](#orphaned-volumes-after-vm-deletion)
  - [Warnings During VM Deletion](#warnings-during-vm-deletion)
- [Snapshot Issues](#snapshot-issues)
  - [Snapshot Creation Fails](#snapshot-creation-fails)
  - [Snapshot Rollback Fails](#snapshot-rollback-fails)
- [Performance Issues](#performance-issues)
  - [Slow VM Disk Performance](#slow-vm-disk-performance)
  - [Slow Multipath Read Performance](#slow-multipath-read-performance)
  - [Slow VM Cloning](#slow-vm-cloning)
- [Cluster-Specific Issues](#cluster-specific-issues)
  - [Storage Not Shared Across Nodes](#storage-not-shared-across-nodes)
  - [VM Migration Fails](#vm-migration-fails)
- [Log Files and Debugging](#log-files-and-debugging)
  - [Proxmox Logs](#proxmox-logs)
  - [TrueNAS Logs](#truenas-logs)
  - [Storage Diagnostics](#storage-diagnostics)
  - [Enable Debug Logging](#enable-debug-logging)
- [Getting Help](#getting-help)

---

## Installer Issues

The automated installer ([install.sh](../install.sh)) handles most installation scenarios, but you may encounter issues. This section covers common installer problems and solutions.

### Installation Failed

**Symptom**: Installer exits with error during plugin installation

**Common Errors**:

**"Plugin syntax validation failed"**
```bash
ERROR: Plugin syntax validation failed
Perl compilation check returned errors

# This indicates the downloaded plugin file has syntax errors
```

**Solution**:
```bash
# Check if download was interrupted
ls -lh /tmp/TrueNASPlugin.pm.download

# Try downloading manually to verify file integrity
wget https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/TrueNASPlugin.pm

# Check syntax manually
perl -c TrueNASPlugin.pm

# If syntax is valid, try installer again
./install.sh
```

**"Failed to restart Proxmox services"**
```bash
ERROR: Failed to restart pvedaemon
Services could not be restarted properly

# Plugin was installed but services didn't restart
```

**Solution**:
```bash
# Check service status
systemctl status pvedaemon pveproxy

# Check for conflicts or errors
journalctl -u pvedaemon -n 50
journalctl -u pveproxy -n 50

# Try manual restart
systemctl restart pvedaemon
systemctl restart pveproxy

# If services won't start, check plugin syntax
perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Rollback if needed
./install.sh
# Choose: "Rollback to previous version"
```

### Missing Dependencies

**Symptom**: Installer exits with "Missing dependency" error

**Common Messages**:
```bash
ERROR: Required dependency 'jq' not found
Please install: apt-get install jq

ERROR: Required dependency 'curl' or 'wget' not found
Please install: apt-get install curl wget

ERROR: Required dependency 'perl' not found
Please install: apt-get install perl
```

**Solution**:
```bash
# Update package lists
apt-get update

# Install all common dependencies
apt-get install curl wget jq perl

# For minimal systems, install just what's needed
apt-get install jq  # JSON parsing (required)

# Either curl or wget (at least one required)
apt-get install curl
# OR
apt-get install wget

# Verify installations
which jq curl wget perl

# Run installer again
./install.sh
```

### Permission Denied

**Symptom**: "Permission denied" or "Must run as root"

**Error Messages**:
```bash
ERROR: This script must be run as root
Please run: sudo ./install.sh

ERROR: Permission denied: /usr/share/perl5/PVE/Storage/Custom/
Cannot write to plugin directory
```

**Solutions**:

**Not running as root**:
```bash
# Check current user
whoami

# If not root, use sudo
sudo ./install.sh

# Or switch to root
su -
./install.sh
```

**Directory permissions issue**:
```bash
# Check plugin directory permissions
ls -ld /usr/share/perl5/PVE/Storage/Custom/

# Should be: drwxr-xr-x root root

# Fix permissions if needed (as root)
mkdir -p /usr/share/perl5/PVE/Storage/Custom/
chown root:root /usr/share/perl5/PVE/Storage/Custom/
chmod 755 /usr/share/perl5/PVE/Storage/Custom/
```

### GitHub API Rate Limiting

**Symptom**: Cannot download plugin, GitHub API returns rate limit error

**Error Message**:
```bash
ERROR: GitHub API rate limit exceeded
API requests remaining: 0/60
Rate limit resets at: 2025-10-25 15:30:00

Please try again after the reset time, or use a GitHub token for higher limits
```

**Solutions**:

**Option 1: Wait for rate limit reset**
```bash
# Wait until the reset time shown in error message
# Default limit is 60 requests/hour for unauthenticated requests

# Check current rate limit status
curl -s https://api.github.com/rate_limit
```

**Option 2: Use GitHub token (higher limits)**
```bash
# Create GitHub personal access token:
# 1. Go to https://github.com/settings/tokens
# 2. Click "Generate new token (classic)"
# 3. Give it a name: "Proxmox Installer"
# 4. Select scopes: public_repo (read-only access)
# 5. Click "Generate token"
# 6. Copy the token

# Set token environment variable
export GITHUB_TOKEN="ghp_yourTokenHere"

# Run installer (will use token for API requests)
./install.sh

# Or pass inline
GITHUB_TOKEN="ghp_yourTokenHere" ./install.sh
```

**Option 3: Manual installation**
```bash
# Download plugin manually
wget https://raw.githubusercontent.com/WarlockSyno/truenasplugin/main/TrueNASPlugin.pm

# Install manually
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
systemctl restart pvedaemon pveproxy
```

### Service Restart Failures

**Symptom**: Plugin installed but Proxmox services won't restart

**Error Messages**:
```bash
ERROR: Service pvedaemon failed to start
Service status: failed (Result: exit-code)

WARNING: Service pveproxy is not running
Please check service status manually
```

**Diagnosis**:
```bash
# Check service status
systemctl status pvedaemon
systemctl status pveproxy

# View detailed errors
journalctl -u pvedaemon -n 100
journalctl -u pveproxy -n 100

# Check plugin syntax
perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Look for Perl module dependencies
grep -i "can't locate" /var/log/syslog
```

**Solutions**:

**Plugin syntax error**:
```bash
# If perl -c shows errors, rollback
./install.sh
# Choose: "Rollback to previous version"

# Report issue on GitHub if latest version has syntax errors
```

**Missing Perl modules**:
```bash
# Install common Perl modules
apt-get install libwww-perl libjson-perl libhttp-message-perl

# Restart services
systemctl restart pvedaemon pveproxy
```

**Configuration conflict**:
```bash
# Check storage configuration
cat /etc/pve/storage.cfg

# Look for syntax errors or invalid parameters
# Comment out problematic storage entries temporarily

# Restart services
systemctl restart pvedaemon pveproxy
```

### Configuration Wizard Issues

**Symptom**: Configuration wizard fails to save or validate settings

**Common Issues**:

**"TrueNAS API connectivity test failed"**
```bash
# Wizard shows:
✗ TrueNAS API connectivity test failed
Could not connect to https://192.168.1.100/api/v2.0/system/info

# Common causes:
# 1. TrueNAS IP incorrect or unreachable
# 2. API key invalid or expired
# 3. Firewall blocking port 443/80
# 4. TrueNAS API service not running
```

**Solutions**:
```bash
# Test connectivity manually
ping 192.168.1.100

# Test API access (replace IP and API key)
curl -k -H "Authorization: Bearer 1-YOUR-API-KEY" \
  https://192.168.1.100/api/v2.0/system/info

# Should return JSON with system info

# Check TrueNAS API service
# In TrueNAS web UI: System Settings → Services → Middleware (should be running)

# Verify API key is valid
# In TrueNAS web UI: Credentials → Local Users → [user] → Edit
# Check that API key section shows active key
```

**"Dataset does not exist on TrueNAS"**
```bash
# Wizard shows:
✗ Dataset 'tank/proxmox' not found on TrueNAS

# Dataset doesn't exist or API can't access it
```

**Solutions**:
```bash
# Check dataset exists on TrueNAS
ssh root@truenas-ip
zfs list tank/proxmox

# If dataset doesn't exist, create it
zfs create tank/proxmox
zfs set compression=lz4 tank/proxmox

# If dataset exists but wizard can't see it:
# - Verify API key has permissions
# - Check dataset name format (no trailing slashes)
# - Ensure pool is mounted
```

**"Failed to write to storage.cfg"**
```bash
ERROR: Failed to write configuration to /etc/pve/storage.cfg
Permission denied

# Installer can't modify storage configuration
```

**Solutions**:
```bash
# Verify running as root
whoami  # Should show "root"

# Check /etc/pve is mounted (cluster filesystem)
mount | grep /etc/pve

# Should show: pve-cluster on /etc/pve

# If not mounted (cluster issue):
systemctl status pve-cluster
systemctl restart pve-cluster

# Check storage.cfg permissions
ls -l /etc/pve/storage.cfg

# Manual configuration (if wizard fails)
nano /etc/pve/storage.cfg

# Add configuration manually:
truenasplugin: truenas-storage
    api_host 192.168.1.100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    dataset tank/proxmox
    discovery_portal 192.168.1.100:3260
    content images
    shared 1
```

### Health Check Failures

**Symptom**: Health check reports failures after installation

**Common Failures**:

**"Plugin file not found"**
```bash
✗ Plugin file exists
File not found: /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Plugin wasn't installed correctly
```

**Solution**:
```bash
# Verify installation
ls -l /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# If missing, reinstall
./install.sh
# Choose: "Install latest version"
```

**"No storage configuration found"**
```bash
✗ Storage configuration found
No 'truenasplugin' entries in /etc/pve/storage.cfg

# Storage not configured yet
```

**Solution**:
```bash
# Run configuration wizard
./install.sh
# Choose: "Configure storage"

# Or check if storage.cfg has entries
grep truenasplugin /etc/pve/storage.cfg
```

**"iSCSI sessions not established"**
```bash
⚠ iSCSI sessions established
Warning: No active iSCSI sessions found

# No volumes created yet, or iSCSI login failed
```

**Solution**:
```bash
# This is normal if no VMs are using TrueNAS storage yet
# Create a test volume to verify iSCSI:
pvesm alloc truenas-storage 999 test-disk-0 1G

# Check iSCSI sessions
iscsiadm -m session

# Should show session to TrueNAS IP

# Clean up test volume
pvesm free truenas-storage:vm-999-disk-0-lun1
```

**"Service not running"**
```bash
✗ Service pvedaemon running
Status: inactive (dead)

# Critical Proxmox service not running
```

**Solution**:
```bash
# Start service
systemctl start pvedaemon

# Check for errors
systemctl status pvedaemon
journalctl -u pvedaemon -n 50

# If won't start, check plugin syntax
perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Rollback if plugin is causing issues
./install.sh
# Choose: "Rollback to previous version"
```

### Installer Logs

**Location**: `/var/log/truenas-installer.log`

**Viewing logs**:
```bash
# View all logs
cat /var/log/truenas-installer.log

# View recent logs
tail -n 100 /var/log/truenas-installer.log

# Follow logs in real-time
tail -f /var/log/truenas-installer.log

# Search for errors
grep ERROR /var/log/truenas-installer.log

# Search for specific operation
grep "Installing plugin" /var/log/truenas-installer.log
```

**Log format**:
```
[2025-10-25 14:32:15] INFO: Installer started (v1.0.0)
[2025-10-25 14:32:16] INFO: Detected cluster: 3 nodes
[2025-10-25 14:32:17] INFO: Downloading plugin v1.0.7...
[2025-10-25 14:32:18] SUCCESS: Plugin installed successfully
[2025-10-25 14:32:20] ERROR: Failed to restart pvedaemon
```

---

## About Plugin Error Messages

**The plugin provides enhanced error messages** with built-in troubleshooting guidance. When an error occurs, the plugin includes:
- Specific cause of the failure
- Step-by-step troubleshooting instructions
- TrueNAS GUI navigation paths
- Relevant commands for diagnosis

**Example Enhanced Error**:
```
Failed to create iSCSI extent for disk 'vm-100-disk-0':

Common causes:
1. iSCSI service not running
   → Check: TrueNAS → System Settings → Services → iSCSI (should be RUNNING)

2. Zvol not accessible
   → Verify: zfs list tank/proxmox/vm-100-disk-0

3. API key lacks permissions
   → Check: TrueNAS → Credentials → Local Users → [your user] → Edit
   → Ensure user has full Sharing permissions

4. Extent name conflict
   → Check: TrueNAS → Shares → Block Shares (iSCSI) → Extents
   → Look for existing extent named 'vm-100-disk-0'
```

**This guide supplements those built-in messages** with additional context and solutions for common scenarios.

---

## Storage Status Issues

### Storage Shows as Inactive

**Symptom**: Storage appears as inactive in `pvesm status`

**Common Causes**:
1. TrueNAS unreachable (network issue, TrueNAS offline)
2. Dataset doesn't exist
3. API authentication failed
4. iSCSI service not running

**Diagnosis**:
```bash
# Check Proxmox logs for specific error
journalctl -u pvedaemon | grep "TrueNAS storage"

# Look for error classification:
# - INFO = connectivity issue (temporary)
# - ERROR = configuration problem (needs admin action)
# - WARNING = unknown issue (investigate)
```

**Solutions by Error Type**:

#### Connectivity Issues (INFO level)
```bash
# Test network connectivity
ping YOUR_TRUENAS_IP

# Test API port
curl -k https://YOUR_TRUENAS_IP/api/v2.0/system/info

# Check TrueNAS is online
# Access TrueNAS web UI to verify system is running
```

#### Configuration Errors (ERROR level)

**Dataset Not Found (ENOENT)**:
```bash
# Verify dataset exists on TrueNAS
zfs list tank/proxmox

# Create if missing
zfs create tank/proxmox

# Verify in /etc/pve/storage.cfg
grep dataset /etc/pve/storage.cfg
```

**Authentication Failed (401/403)**:
```bash
# Test API key manually
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/system/info

# If fails, regenerate API key in TrueNAS:
# Credentials > Local Users > Edit > API Key > Add

# Update /etc/pve/storage.cfg with new key
# Restart services
systemctl restart pvedaemon pveproxy
```

## Connection and API Issues

### "Could not connect to TrueNAS API"

**Symptom**: API connection failures in logs

**Solutions**:

#### 1. Test API Connectivity
```bash
# Test HTTPS API
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/system/info

# Should return JSON system info
```

#### 2. Check Firewall Rules
```bash
# On Proxmox node
iptables -L -n | grep 443

# On TrueNAS, verify firewall allows API port (443 or 80)
```

#### 3. Verify TLS Configuration
```bash
# If using self-signed cert, use api_insecure=1 (testing only)
# In /etc/pve/storage.cfg:
api_insecure 1

# Production: import TrueNAS cert or use valid CA cert
```

#### 4. Check API Transport
```bash
# Try REST fallback if WebSocket fails
# In /etc/pve/storage.cfg:
api_transport rest

# Restart services
systemctl restart pvedaemon pveproxy
```

### API Rate Limiting

**Symptom**: Errors mentioning rate limits or "too many requests"

**Explanation**: TrueNAS limits API requests to 20 calls per 60 seconds with 10-minute cooldown

**Solutions**:

#### 1. Wait for Cooldown
```bash
# If rate limited, wait 10 minutes before retrying
# Check TrueNAS logs
tail -f /var/log/middlewared.log | grep rate
```

#### 2. Increase Retry Delay
```ini
# In /etc/pve/storage.cfg
api_retry_max 5
api_retry_delay 3
```

#### 3. Enable Bulk Operations
```ini
# Batch multiple operations to reduce API calls
enable_bulk_operations 1
```

## iSCSI Discovery and Connection Issues

### "Could not discover iSCSI targets"

**Symptom**: iSCSI target discovery fails

**Diagnosis**:
```bash
# Manual discovery from Proxmox node
iscsiadm -m discovery -t sendtargets -p YOUR_TRUENAS_IP:3260

# Should list targets like:
# 192.168.1.100:3260,1 iqn.2005-10.org.freenas.ctl:proxmox
```

**Solutions**:

#### 1. Verify iSCSI Service Running
```bash
# On TrueNAS
systemctl status iscsitarget

# Via web UI: System Settings > Services > iSCSI (should show Running)

# Start if not running
systemctl start iscsitarget
```

#### 2. Check Network Connectivity
```bash
# Test iSCSI port
telnet YOUR_TRUENAS_IP 3260

# Should connect (Ctrl+C to exit)
```

#### 3. Verify Portal Configuration
```bash
# In TrueNAS web UI: Shares > Block Shares (iSCSI) > Portals
# Ensure portal exists on 0.0.0.0:3260 or specific IP:3260
```

### "Could not resolve iSCSI target ID for configured IQN"

**Symptom**: Plugin can't find the target IQN

**Example Error**:
```
Configured IQN: iqn.2005-10.org.freenas.ctl:mytar get
Available targets:
  - iqn.2005-10.org.freenas.ctl:proxmox (ID: 2)
```

**Solutions**:

#### 1. Verify Target Exists
```bash
# Via TrueNAS API
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/iscsi/target

# Via web UI: Shares > Block Shares (iSCSI) > Targets
```

#### 2. Check IQN Match
```bash
# In /etc/pve/storage.cfg, IQN must match exactly:
target_iqn iqn.2005-10.org.freenas.ctl:proxmox

# Copy IQN from TrueNAS target configuration
```

#### 3. Create Target if Missing
```bash
# In TrueNAS web UI:
# Shares > Block Shares (iSCSI) > Targets > Add
# Set Target Name (e.g., "proxmox")
# Save
```

### iSCSI Session Issues

**Symptom**: Cannot connect to iSCSI target

**Diagnosis**:
```bash
# Check active sessions
iscsiadm -m session

# Check session details
iscsiadm -m session -P 3
```

**Solutions**:

#### 1. Manual Login
```bash
# Login to target manually
iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:proxmox \
  -p YOUR_TRUENAS_IP:3260 --login

# Verify session
iscsiadm -m session
```

#### 2. Check Authentication
```bash
# If using CHAP, verify credentials match
# In /etc/pve/storage.cfg:
chap_user your-username
chap_password your-password

# Must match TrueNAS: Shares > iSCSI > Authorized Access
```

#### 3. Logout and Re-login
```bash
# Logout from all sessions for target
iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:proxmox --logout

# Re-login
iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:proxmox \
  -p YOUR_TRUENAS_IP:3260 --login
```

## Volume Creation Issues

### "Failed to create iSCSI extent for disk"

**Symptom**: Volume creation fails at extent creation step

**Common Causes**:
- iSCSI service not running
- Zvol exists but not accessible
- API key lacks permissions
- Extent name conflict

**Solutions**:

#### 1. Check iSCSI Service
```bash
# Verify service running on TrueNAS
# System Settings > Services > iSCSI (should be Running)

# Or via CLI:
systemctl status iscsitarget
```

#### 2. Verify Zvol Exists
```bash
# On TrueNAS
zfs list -t volume | grep proxmox

# Should show zvol like: tank/proxmox/vm-100-disk-0
```

#### 3. Check API Permissions
```bash
# API key user needs full Sharing permissions
# In TrueNAS: Credentials > Local Users > Edit user
# Verify permissions include iSCSI management
```

#### 4. Check for Extent Conflicts
```bash
# Via web UI: Shares > Block Shares (iSCSI) > Extents
# Look for duplicate extent names

# Delete conflicting extents or orphaned entries
```

### "Insufficient space on dataset"

**Symptom**: Pre-flight validation fails due to insufficient space

**Example Error**:
```
Insufficient space on dataset 'tank/proxmox':
need 120.00 GB (with 20% overhead), have 80.00 GB available
```

**Solutions**:

#### 1. Check Dataset Space
```bash
# On TrueNAS
zfs list tank/proxmox

# Shows available space
```

#### 2. Free Up Space
```bash
# Delete old snapshots
zfs list -t snapshot | grep tank/proxmox
zfs destroy tank/proxmox/vm-999-disk-0@snapshot1

# Delete unused zvols
zfs destroy tank/proxmox/vm-999-disk-0
```

#### 3. Expand Pool or Use Different Dataset
```bash
# Add more storage to pool or use larger pool
# Or change dataset in /etc/pve/storage.cfg:
dataset tank/larger-pool/proxmox
```

### "Unable to find free disk name after 1000 attempts"

**Symptom**: Cannot allocate disk name

**Causes**:
- VM has 1000+ disks (very unlikely)
- TrueNAS dataset queries failing
- Orphaned volumes preventing name assignment

**Solutions**:

#### 1. Check for Orphaned Volumes
```bash
# On TrueNAS, list all volumes
zfs list -t volume | grep tank/proxmox

# Look for orphaned vm-XXX-disk-* volumes
# Delete if no longer needed:
zfs destroy tank/proxmox/vm-999-disk-0
```

#### 2. Verify TrueNAS API Responding
```bash
# Test dataset query
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://YOUR_TRUENAS_IP/api/v2.0/pool/dataset/id/tank%2Fproxmox

# Should return dataset details
```

### "Volume created but device not accessible after 10 seconds"

**Symptom**: Zvol created on TrueNAS but Linux can't see the device

**Solutions**:

#### 1. Check iSCSI Session
```bash
# Verify session active
iscsiadm -m session

# If no session, login
iscsiadm -m node -T YOUR_TARGET_IQN -p YOUR_TRUENAS_IP:3260 --login
```

#### 2. Re-scan iSCSI Bus
```bash
# Force rescan
iscsiadm -m node --rescan

# Or rescan all sessions
iscsiadm -m session --rescan
```

#### 3. Check by-path Devices
```bash
# List iSCSI devices
ls -la /dev/disk/by-path/ | grep iscsi

# Should show device corresponding to LUN
```

#### 4. Verify Multipath (if enabled)
```bash
# Check multipath status
multipath -ll

# Should show device with multiple paths

# Reconfigure if needed
multipath -r
```

## VM Deletion Issues

### Orphaned Volumes After VM Deletion

**Symptom**: Volumes remain on TrueNAS after VM deletion

**Cause**: Using `qm destroy` command instead of GUI

**Explanation**:
- **GUI deletion** properly calls storage plugin cleanup (recommended)
- **CLI `qm destroy`** does NOT call plugin cleanup methods
- Proxmox removes internal references but TrueNAS storage remains

**Solutions**:

#### 1. Manual Cleanup
```bash
# List remaining volumes for deleted VM
pvesm list truenas-storage | grep vm-100

# Free each volume manually
pvesm free truenas-storage:vm-100-disk-0-lun1
pvesm free truenas-storage:vm-100-disk-1-lun2
```

#### 2. Direct ZFS Cleanup (if plugin fails)
```bash
# On TrueNAS, list zvols
zfs list -t volume | grep vm-100

# Destroy zvols (WARNING: deletes data)
zfs destroy tank/proxmox/vm-100-disk-0
zfs destroy tank/proxmox/vm-100-disk-1

# Clean up iSCSI extents via web UI:
# Shares > Block Shares (iSCSI) > Extents
# Delete extents for vm-100
```

#### 3. Prevention: Use GUI for Deletion
```bash
# Recommended: Always delete VMs via Proxmox web UI
# This ensures proper cleanup of all resources
```

### Warnings During VM Deletion

**Symptom**: Warnings about resources that don't exist

**Example**:
```
warning: delete targetextent id=115 failed: InstanceNotFound
warning: delete extent id=115 failed: does not exist
```

**Status**: This is normal and harmless if resources are already cleaned up

**Explanation**:
- Plugin attempts to delete resources in order (targetextent → extent → zvol)
- If a resource is already gone (from previous cleanup or bulk delete), ENOENT errors are suppressed
- Only actual failures (permissions, locks, etc.) generate warnings

**Action**: No action needed if deletion completes successfully

## Snapshot Issues

### Snapshot Creation Fails

**Symptom**: Cannot create VM snapshot

**Solutions**:

#### 1. Check ZFS Space
```bash
# Snapshots require free space for metadata
zfs list tank/proxmox

# Ensure adequate free space
```

#### 2. Verify vmstate Storage
```bash
# If using live snapshots, check vmstate storage
# In /etc/pve/storage.cfg:
vmstate_storage local

# Ensure local storage has space for RAM dump
df -h /var/lib/vz
```

#### 3. Check Snapshot Limits
```bash
# ZFS has no hard limit, but check dataset properties
zfs get all tank/proxmox | grep snapshot
```

### Snapshot Rollback Fails

**Symptom**: Cannot rollback to snapshot

**Solutions**:

#### 1. Stop VM First
```bash
# VM must be stopped for rollback
qm stop 100

# Then rollback
qm rollback 100 snapshot-name
```

#### 2. Check Snapshot Exists
```bash
# List snapshots
qm listsnapshot 100

# Verify on TrueNAS
zfs list -t snapshot | grep vm-100
```

## Performance Issues

### Slow VM Disk Performance

**Solutions**:

#### 1. Optimize ZFS Block Size
```ini
# In /etc/pve/storage.cfg
zvol_blocksize 128K
```

#### 2. Enable Multipath
```ini
# Use multiple portals for load balancing
portals 192.168.1.101:3260,192.168.1.102:3260
use_multipath 1
```

#### 3. Network Optimization
```bash
# Enable jumbo frames
ip link set eth1 mtu 9000

# Verify MTU
ip link show eth1
```

#### 4. Dedicated Storage Network
```bash
# Use dedicated 10GbE network for iSCSI
# Configure VLANs to isolate storage traffic
```

### Slow Multipath Read Performance

**Symptom**: Read performance with multipath is lower than expected, even though both paths are configured correctly

**Observed Behavior**:
- Write speeds: ~100-110 MB/s (both paths utilized) ✅
- Sequential read speeds: ~50-100 MB/s (lower than expected) ⚠️
- Network monitoring shows both interfaces active during reads
- Multipath configuration appears correct

**Root Cause**:
This is a **known limitation** of TrueNAS SCALE's iSCSI implementation. The `MaxOutstandingR2T` parameter is hardcoded to `1`, which limits read parallelism across multiple paths.

**Verification**:
```bash
# Check iSCSI session parameters
iscsiadm -m session -P 3 | grep MaxOutstandingR2T

# You'll see:
# MaxOutstandingR2T: 1

# Verify multipath is working (both paths should be active)
multipath -ll

# Check actual I/O distribution (both paths should show activity)
grep -E '(sdX|sdY)' /proc/diskstats  # Before test
# Run read test
grep -E '(sdX|sdY)' /proc/diskstats  # After test
# Both paths should show increased read sectors
```

**Important**:
- This is **NOT a configuration error** - your multipath setup is working correctly
- Both paths ARE being used, they just can't operate fully in parallel for reads
- Write performance is not affected by this limitation

**Solutions**:

#### 1. Upgrade to 10GbE (Recommended)
```bash
# Single 10GbE path provides ~1000 MB/s
# Eliminates the bottleneck entirely
# Best long-term solution
```

#### 2. Accept Current Performance
- ~100 MB/s read is reasonable for many workloads
- Real-world applications with multiple VMs perform better than single-threaded benchmarks
- Most production workloads issue parallel I/O naturally

#### 3. Test with Parallel I/O
```bash
# Verify performance improves with parallel workloads
fio --name=parallel-read --filename=/dev/mapper/mpathX \
    --rw=read --bs=1M --size=2G --numjobs=4 --iodepth=16 \
    --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting

# Should show better performance (~100-110 MB/s)
```

**For More Information**:
See [Known Limitations - Multipath Read Performance](Known-Limitations.md#multipath-read-performance-limitation) for detailed explanation, technical details, and additional workarounds.

### Slow VM Cloning

**Symptom**: VM cloning takes a long time

**Explanation**:
- Proxmox uses network-based `qemu-img convert` for iSCSI storage
- ZFS instant clones are not used (Proxmox limitation)
- Clone speed limited by network bandwidth

**Workarounds**:

#### 1. Use Smaller Base Images
```bash
# Create minimal templates for cloning
# Add data after clone completes
```

#### 2. Improve Network Bandwidth
```bash
# Use 10GbE or faster network
# Ensure no bandwidth limitations
```

#### 3. Use Templates with Thin Provisioning
```ini
# Enable sparse volumes
tn_sparse 1
```

## Cluster-Specific Issues

### Storage Not Shared Across Nodes

**Symptom**: Storage not accessible from all cluster nodes

**Solutions**:

#### 1. Verify shared=1
```bash
# In /etc/pve/storage.cfg
shared 1
```

#### 2. Check iSCSI Sessions on All Nodes
```bash
# On each cluster node
iscsiadm -m session

# All nodes should show active session
```

#### 3. Verify Multipath on All Nodes
```bash
# On each node
multipath -ll

# Should show same devices
```

### VM Migration Fails

**Symptom**: Cannot migrate VMs between nodes

**Solutions**:

#### 1. Ensure Shared Storage
```ini
# Must be shared storage
shared 1
```

#### 2. Check Storage Active on All Nodes
```bash
# On each node
pvesm status

# Storage should be active on all nodes
```

#### 3. Verify Network Connectivity
```bash
# All nodes must reach TrueNAS
# On each node:
ping YOUR_TRUENAS_IP
```

## Log Files and Debugging

### Proxmox Logs

```bash
# Daemon logs
journalctl -u pvedaemon -f

# Proxy logs
journalctl -u pveproxy -f

# Storage-specific logs
journalctl -u pvedaemon | grep TrueNAS

# System logs
tail -f /var/log/syslog | grep -i truenas
```

### TrueNAS Logs

```bash
# Middleware logs (API calls)
tail -f /var/log/middlewared.log

# iSCSI logs
journalctl -u iscsitarget -f

# System logs
tail -f /var/log/syslog | grep -i iscsi
```

### Storage Diagnostics

```bash
# Storage status
pvesm status

# List volumes
pvesm list truenas-storage

# iSCSI sessions
iscsiadm -m session -P 3

# Multipath status
multipath -ll

# Disk devices
ls -la /dev/disk/by-path/ | grep iscsi
lsblk
```

### Enable Debug Logging

```bash
# Increase Proxmox log verbosity
# Edit /etc/pve/datacenter.cfg
# Add:
# log: max=debug

# Restart services
systemctl restart pvedaemon pveproxy

# Watch logs
journalctl -u pvedaemon -f
```

## Getting Help

If troubleshooting doesn't resolve your issue:

1. **Gather Information**:
   - Proxmox VE version: `pveversion`
   - TrueNAS SCALE version
   - Plugin configuration from `/etc/pve/storage.cfg`
   - Relevant log entries from Proxmox and TrueNAS
   - Network configuration details

2. **Check Known Limitations**: Review [Known Limitations](Known-Limitations.md)

3. **Search Existing Issues**: Check GitHub issues for similar problems

4. **Report Issue**: Create new GitHub issue with all gathered information

## See Also
- [Configuration Reference](Configuration.md) - Configuration parameters
- [Known Limitations](Known-Limitations.md) - Known issues and workarounds
- [Advanced Features](Advanced-Features.md) - Performance tuning
