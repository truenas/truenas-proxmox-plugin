# Troubleshooting Guide

Common issues and solutions for the TrueNAS Proxmox VE Storage Plugin.

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
