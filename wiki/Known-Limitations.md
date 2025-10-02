# Known Limitations

Important limitations, restrictions, and workarounds for the TrueNAS Proxmox VE Storage Plugin.

## Critical Workflow Limitations

### VM Deletion Behavior

**Different VM deletion methods have different cleanup behaviors.**

#### ✅ GUI Deletion (Recommended)

**Method**: Delete VMs through Proxmox web interface

**Behavior**:
- Properly calls storage plugin cleanup methods
- Achieves 100% cleanup of Proxmox volumes AND TrueNAS zvols/snapshots
- Removes iSCSI extents and targetextents
- No orphaned resources

**Recommendation**: **This is the required method for production use**

#### ❌ CLI `qm destroy` Command

**Method**: Using `qm destroy VMID` command

**Behavior**:
- Does NOT call storage plugin cleanup methods
- Leaves orphaned zvols on TrueNAS
- Leaves orphaned iSCSI extents and targetextents
- Proxmox removes internal references but TrueNAS storage remains unconsumed

**Impact**:
- Wasted storage space on TrueNAS
- Orphaned iSCSI configuration
- Manual cleanup required

#### Manual Cleanup Required After `qm destroy`

If you used `qm destroy`, clean up manually:

```bash
# 1. List remaining volumes for deleted VM
pvesm list truenas-storage | grep vm-VMID

# 2. Free each volume
pvesm free truenas-storage:vm-VMID-disk-0-lunX
pvesm free truenas-storage:vm-VMID-disk-1-lunY

# 3. If plugin cleanup fails, manual TrueNAS cleanup:
# On TrueNAS:
zfs list -t volume | grep vm-VMID
zfs destroy tank/proxmox/vm-VMID-disk-0
zfs destroy tank/proxmox/vm-VMID-disk-1

# In TrueNAS web UI: Shares > Block Shares (iSCSI) > Extents
# Delete extents for vm-VMID manually
```

#### Automation Scripts

If you use automation scripts that call `qm destroy`, add cleanup:

```bash
#!/bin/bash
VMID=$1
STORAGE="truenas-storage"

# Get list of disks before deletion
DISKS=$(pvesm list $STORAGE | grep "vm-$VMID" | awk '{print $1}')

# Destroy VM
qm destroy $VMID

# Clean up storage
for disk in $DISKS; do
    echo "Cleaning up $disk"
    pvesm free "$disk" || echo "Warning: Failed to free $disk"
done
```

### Why This Happens

Proxmox's `qm destroy` command:
1. Removes VM configuration from `/etc/pve/qemu-server/`
2. Removes internal volume references
3. **Does NOT** call storage plugin's `free_image()` method
4. **Does NOT** perform storage-specific cleanup

The web UI delete button:
1. Calls `qm destroy` with proper cleanup flags
2. Explicitly calls storage plugin cleanup methods
3. Ensures complete resource deallocation

## Storage Feature Limitations

### No Fast Clone Support

**Limitation**: VM cloning does not use instant ZFS clones

**Explanation**:
- Proxmox treats iSCSI storage as "generic block storage"
- For block storage, Proxmox uses network-based `qemu-img convert`
- Plugin's efficient `clone_image()` and `copy_image()` methods are never called
- ZFS instant clone capability is unused during VM cloning

**Performance Impact**:
- Clone operations transfer data over network at connection speed (e.g., 1GbE = ~100MB/s)
- Large VMs (32GB+) can take significant time to clone
- Network bandwidth is consumed during cloning operation
- No space efficiency benefit from ZFS clones

**Workarounds**:

#### 1. Use Smaller Base Images
```bash
# Create minimal templates
# Add data/applications after cloning completes
# Smaller templates = faster clones
```

#### 2. Ensure Adequate Network Bandwidth
```bash
# Use 10GbE or faster network between Proxmox and TrueNAS
# Dedicated storage network
# Jumbo frames (MTU 9000)
```

#### 3. Leverage Thin Provisioning
```ini
# Sparse volumes reduce data to copy
tn_sparse 1
```

#### 4. Use ZFS Snapshots Instead
```bash
# ZFS snapshots ARE instant and space-efficient
qm snapshot 100 template-state

# Snapshots can be used for quick rollback
# But not for creating independent VM clones
```

**Note**: This is a Proxmox architectural limitation, not a plugin bug. Proxmox categorizes storage plugins that return block device paths as "external" storage and bypasses plugin clone methods.

### No Volume Shrinking

**Limitation**: Cannot reduce volume size, only grow

**Explanation**: ZFS does not support zvol shrinking

**Impact**:
- Can only use `qm resize VMID diskN +SIZE` (grow)
- Cannot use `qm resize VMID diskN SIZE` (set absolute size smaller)

**Workaround**:
```bash
# To "shrink" a disk:
# 1. Create new smaller volume
pvesm alloc truenas-storage 100 vm-100-disk-1 32G

# 2. Clone data from old disk to new disk (within VM or using rescue)
# 3. Detach old disk, attach new disk
qm set 100 --scsi1 truenas-storage:vm-100-disk-1

# 4. Delete old disk
pvesm free truenas-storage:vm-100-disk-0-lun1
```

### Resize Headroom Limit

**Limitation**: Can only resize volumes up to 80% of available dataset space

**Explanation**: Pre-flight checks enforce 20% safety margin for ZFS overhead

**Example**:
```
Dataset has 100GB free
Maximum resize: 80GB
Safety margin: 20GB (for ZFS metadata, snapshots, etc.)
```

**Impact**:
- Cannot resize volume to consume all available space
- Prevents pool exhaustion

**Workaround**:
```bash
# If you need more space:
# 1. Add storage to ZFS pool
# 2. Or free up space by deleting snapshots/volumes
# 3. Or use different dataset with more space
```

## Content Type Limitations

### Images Only

**Limitation**: Only `content images` (VM disk images) is supported

**Not Supported**:
- LXC containers (`rootdir`, `vztmpl`)
- ISO images (`iso`)
- Container templates (`vztmpl`)
- Backups (`backup`)
- Snippets (`snippets`)

**Explanation**:
- Plugin provides iSCSI block storage (perfect for VMs)
- LXC containers need filesystem-based storage (NFS, directory, etc.)
- ISOs and templates are file-based, not block devices

**Workaround**:
```bash
# Use separate storage for other content types:
# - Local storage for ISO images
# - NFS/CIFS for LXC containers
# - PBS (Proxmox Backup Server) for backups

# Example /etc/pve/storage.cfg:
truenasplugin: truenas-vms
    # ... config ...
    content images

dir: local
    path /var/lib/vz
    content iso,vztmpl,backup

nfs: truenas-lxc
    server 192.168.1.100
    export /mnt/tank/lxc
    content rootdir,vztmpl
```

## Snapshot Limitations

### No Backup Integration

**Limitation**: ZFS snapshots are not included in Proxmox backups

**Explanation**:
- Proxmox `vzdump` backup tool doesn't integrate with storage plugin snapshots
- ZFS snapshots remain on TrueNAS, not exported
- Backups capture current disk state only, not snapshot history

**Impact**:
- Snapshots are not portable
- Restoring VM from backup doesn't restore snapshots
- Snapshots must be managed separately

**Workaround**:
```bash
# For backups including snapshot history:
# 1. Use TrueNAS replication to replicate ZFS datasets
# 2. Or use Proxmox Backup Server for VM backups
# 3. Manage ZFS snapshots via TrueNAS (automated snapshot tasks)

# TrueNAS snapshot schedule:
# Storage > Snapshots > Add
# - Dataset: tank/proxmox
# - Schedule: Hourly/Daily/Weekly
# - Retention: As needed
```

### Snapshots Don't Enable Fast Clones

**Limitation**: VM snapshots don't enable ZFS clone-based VM cloning

**Explanation**:
- VM snapshots create ZFS snapshots on TrueNAS (instant, efficient)
- But VM cloning still uses network-based copy (see "No Fast Clone Support" above)
- Proxmox doesn't use ZFS clones for VM cloning, even from snapshots

**Impact**: Same as fast clone limitation

## Live Migration Limitations

### Requires Shared Storage

**Limitation**: Live migration requires `shared 1` configuration

**Configuration**:
```ini
# Required for live migration
shared 1
```

**Impact**:
- Cannot live migrate VMs between nodes if `shared 0`
- Offline migration still works (VM stopped during migration)

### vmstate Storage Considerations

**Limitation**: Live migration with existing snapshots requires `vmstate_storage shared`

**Explanation**:
- If VM has snapshots with vmstate on local storage
- Live migration fails (vmstate not accessible from target node)

**Workaround**:
```ini
# Use shared vmstate for environments requiring migration
vmstate_storage shared

# Or use local vmstate and delete snapshots before migration
# Or use offline migration (stop VM, migrate, start)
```

## TrueNAS Specific Limitations

### API Rate Limits

**Limitation**: TrueNAS limits API requests to 20 calls per 60 seconds

**Impact**:
- Exceeding limit triggers 10-minute cooldown
- Bulk operations (creating many VMs) may hit limit

**Plugin Mitigation**:
- Automatic retry with exponential backoff
- Bulk operations batching (when `enable_bulk_operations=1`)
- Connection caching and reuse

**User Mitigation**:
```ini
# Increase retry tolerance
api_retry_max 5
api_retry_delay 2

# Enable bulk operations
enable_bulk_operations 1
```

**Manual Recovery**:
```bash
# If rate limited, wait 10 minutes
# Check TrueNAS logs:
tail -f /var/log/middlewared.log | grep rate
```

### WebSocket Connection Stability

**Limitation**: WebSocket connections may be unstable in some network environments

**Symptoms**:
- Random connection drops
- "WebSocket closed unexpectedly" errors
- Increased latency

**Workaround**:
```ini
# Use REST transport instead
api_transport rest
api_scheme https
```

**Trade-off**: REST is more stable but ~20-30ms slower per operation

### Version Compatibility

**Limitation**: Some features require specific TrueNAS SCALE versions

**Feature Requirements**:
- **Basic functionality**: TrueNAS SCALE 22.x+
- **WebSocket API**: TrueNAS SCALE 22.12+
- **Bulk operations**: TrueNAS SCALE 23.x+
- **Optimal performance**: TrueNAS SCALE 25.04+

**Recommendation**: Use TrueNAS SCALE 25.04 or later for best experience

## Proxmox Specific Limitations

### Proxmox Version Requirements

**Limitation**: Some features require specific Proxmox VE versions

**Feature Requirements**:
- **Basic functionality**: Proxmox VE 8.x+
- **Volume snapshot chains**: Proxmox VE 9.x+
- **Optimal storage plugin API**: Proxmox VE 8.2+

**Recommendation**: Use Proxmox VE 8.2 or later (or Proxmox VE 9.x for volume chains)

### Custom Storage Plugin Directory

**Limitation**: Plugin must be in `/usr/share/perl5/PVE/Storage/Custom/`

**Impact**:
- Updates to Proxmox may require plugin reinstallation
- Manual installation required (not in Proxmox repositories)

**Mitigation**:
```bash
# Keep plugin source in safe location
cp TrueNASPlugin.pm /root/truenas-plugin-backup/

# Use cluster deployment script for easy reinstall
./update-cluster.sh node1 node2 node3
```

## Network Limitations

### No NFS/CIFS Support

**Limitation**: Plugin only supports iSCSI block storage

**Not Supported**:
- NFS file shares
- SMB/CIFS file shares
- Direct ZFS dataset mounting

**Explanation**: Plugin architecture designed specifically for iSCSI

**Workaround**:
```bash
# Use separate TrueNAS NFS/SMB shares for file-based storage
# Example /etc/pve/storage.cfg:

# iSCSI for VM disks
truenasplugin: truenas-vms
    content images
    # ... config ...

# NFS for LXC/backups
nfs: truenas-files
    server 192.168.1.100
    export /mnt/tank/nfs-share
    content rootdir,vztmpl,backup
```

### IPv6 Considerations

**Limitation**: IPv6 requires specific configuration

**Required Settings**:
```ini
prefer_ipv4 0
ipv6_by_path 1
use_by_path 1
```

**Portal Format**:
```ini
# Must use brackets for IPv6 addresses
discovery_portal [2001:db8::100]:3260
portals [2001:db8::101]:3260,[2001:db8::102]:3260
```

## Security Limitations

### No Mutual CHAP

**Limitation**: Only one-way CHAP authentication supported

**Explanation**:
- Plugin supports CHAP authentication (initiator → target)
- Mutual CHAP (target → initiator) not implemented

**Impact**: Slightly reduced security in high-security environments

**Mitigation**:
- Use network segmentation (VLANs)
- Firewall rules restricting iSCSI access
- Strong CHAP passwords

### API Key Storage

**Limitation**: API key stored in plaintext in `/etc/pve/storage.cfg`

**Impact**: Anyone with root access to Proxmox can read API key

**Mitigation**:
- Restrict TrueNAS API user permissions (least privilege)
- Use dedicated API user (not root)
- Monitor TrueNAS audit logs
- Rotate API keys regularly

**File Permissions**:
```bash
# /etc/pve/storage.cfg is readable by root only
ls -la /etc/pve/storage.cfg
# -rw-r----- 1 root www-data
```

## Performance Limitations

### Clone Performance

**Limitation**: See "No Fast Clone Support" above

**Impact**: Large VM clones are slow

### Snapshot Overhead

**Limitation**: Many snapshots can impact performance

**Explanation**:
- Each snapshot creates metadata overhead
- Write performance degrades with many snapshots
- Space usage increases as data diverges from snapshots

**Recommendation**:
```bash
# Manage snapshot lifecycle
# Delete old snapshots regularly
# TrueNAS automated snapshot retention policy

# Example: Keep 7 daily snapshots
# In TrueNAS: Storage > Snapshots > Add
# Lifetime: 1 week
```

### Network-Bound Performance

**Limitation**: Performance limited by network speed and latency

**Impact**:
- VM disk I/O limited by network bandwidth
- Latency affects random I/O performance

**Mitigation**:
- Use 10GbE or faster network
- Jumbo frames (MTU 9000)
- Dedicated storage network
- Multiple paths (multipath I/O)

## Platform Limitations

### Linux/Proxmox Only

**Limitation**: Plugin is Proxmox VE specific

**Not Supported**:
- Generic Linux systems
- Other hypervisors (VMware, Hyper-V, etc.)
- FreeBSD/BSD systems

**Explanation**: Plugin uses Proxmox storage plugin API

### ZFS Dependency

**Limitation**: Requires TrueNAS with ZFS

**Not Supported**:
- TrueNAS CORE (FreeBSD-based) - untested, may work
- Other iSCSI targets (not designed for them)
- Non-ZFS storage backends

**Explanation**: Plugin assumes ZFS dataset/zvol semantics

## Operational Limitations

### No Bulk Deletion

**Limitation**: Deleting many VMs sequentially may hit rate limits

**Explanation**: Each VM deletion makes multiple API calls

**Workaround**:
```bash
# Delete VMs with delays
for vm in 100 101 102 103; do
    qm destroy $vm --purge
    sleep 5
done

# Or delete zvols directly on TrueNAS after qm destroy
# (But loses automatic cleanup benefit)
```

### Configuration Changes Require Restart

**Limitation**: Changes to `/etc/pve/storage.cfg` require service restart

**Procedure**:
```bash
# After editing /etc/pve/storage.cfg
systemctl restart pvedaemon pveproxy
```

**Impact**: Brief interruption to API (web UI may disconnect)

### No Storage Overcommit Protection

**Limitation**: Plugin doesn't prevent overcommitting storage

**Explanation**:
- Thin provisioning allows allocating more virtual capacity than physical
- Plugin enforces 20% safety margin on individual operations
- But doesn't track total allocated vs available

**Mitigation**:
```bash
# Monitor actual space usage
zfs list tank/proxmox

# Set ZFS quotas/reservations if needed
zfs set quota=500G tank/proxmox
```

## Workarounds Summary

| Limitation | Recommended Workaround |
|------------|------------------------|
| No fast clones | Use smaller templates, faster network, accept limitation |
| No volume shrink | Create new smaller volume, migrate data, delete old |
| Images only | Use separate storage for LXC/ISO/backups |
| No backup integration | Use TrueNAS replication or Proxmox Backup Server |
| `qm destroy` orphans | Always use GUI deletion or add cleanup to scripts |
| API rate limits | Enable bulk operations, increase retry limits, pace operations |
| WebSocket instability | Use REST transport |
| Clone performance | Faster network, smaller images, accept limitation |

## See Also
- [Troubleshooting Guide](Troubleshooting.md) - Solutions to common issues
- [Advanced Features](Advanced-Features.md) - Performance optimization
- [Configuration Reference](Configuration.md) - All configuration options
