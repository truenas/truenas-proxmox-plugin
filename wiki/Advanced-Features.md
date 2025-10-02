# Advanced Features

Advanced configuration, performance tuning, clustering, and security features of the TrueNAS Proxmox VE Storage Plugin.

## Performance Tuning

### ZFS Block Size Optimization

The zvol block size significantly impacts performance:

**Workload Recommendations**:
- **VM Workloads (Random I/O)**: 128K (default recommended)
- **Database Servers**: 64K or 128K
- **Large Sequential I/O**: 256K or 512K
- **Small Random I/O**: 64K

```ini
# Optimal for general VM workloads
zvol_blocksize 128K
```

**Trade-offs**:
- Larger blocks: Better sequential throughput, more memory overhead
- Smaller blocks: Better for random I/O, less memory usage
- Cannot be changed after volume creation

### Thin Provisioning

Sparse (thin-provisioned) volumes only consume space as written:

```ini
# Enable thin provisioning (default)
tn_sparse 1
```

**Benefits**:
- Overprovisioning - allocate more virtual capacity than physical storage
- Space efficiency - only uses space for actual data
- Snapshots - minimal overhead for snapshots

**Considerations**:
- Monitor actual space usage to avoid pool exhaustion
- Set quotas/reservations in ZFS if needed
- Pre-flight checks include 20% safety margin for ZFS overhead

### Network Optimization

#### Dedicated Storage Network

Use dedicated network interfaces for iSCSI traffic:

```bash
# Example: 10GbE dedicated storage network
# Configure storage network on separate VLAN (e.g., VLAN 100)
# Use separate physical interface (e.g., ens1f1)

# In Proxmox networking configuration:
auto vmbr1
iface vmbr1 inet static
    address 10.0.100.10/24
    bridge-ports ens1f1
    bridge-stp off
    bridge-fd 0
    mtu 9000
```

#### Jumbo Frames

Enable jumbo frames (MTU 9000) for better throughput:

```bash
# On Proxmox nodes
ip link set ens1f1 mtu 9000

# Make persistent in /etc/network/interfaces:
iface ens1f1 inet manual
    mtu 9000

# On TrueNAS (via web UI or CLI)
ifconfig ix0 mtu 9000

# Verify
ip link show ens1f1 | grep mtu
```

**Requirements**:
- All devices in path must support jumbo frames (switches, NICs)
- Configure same MTU on all interfaces
- Test with: `ping -M do -s 8972 TARGET_IP`

#### Multiple iSCSI Portals

Configure multiple portals for redundancy and load balancing:

```ini
truenasplugin: truenas-storage
    discovery_portal 192.168.10.100:3260
    portals 192.168.10.101:3260,192.168.10.102:3260
    use_multipath 1
```

**Benefits**:
- Redundancy - automatic failover if portal fails
- Load balancing - traffic distributed across paths
- Higher throughput - aggregate bandwidth

**TrueNAS Configuration**:
Create multiple portals in **Shares** → **Block Shares (iSCSI)** → **Portals**:
- Portal 1: 192.168.10.100:3260 (primary interface)
- Portal 2: 192.168.10.101:3260 (secondary interface)
- Portal 3: 192.168.10.102:3260 (tertiary interface)

### Multipath I/O (MPIO)

Enable multipath for redundancy and performance:

```ini
use_multipath 1
portals 192.168.10.101:3260,192.168.10.102:3260
```

**Verify Multipath**:
```bash
# Check multipath devices
multipath -ll

# Example output:
# mpatha (360014056789abcd...) dm-0 FREENAS,iSCSI Disk
# size=100G features='0' hwhandler='0' wp=rw
# |-+- policy='service-time 0' prio=1 status=active
# | `- 3:0:0:0 sda 8:0 active ready running
# `-+- policy='service-time 0' prio=1 status=enabled
#   `- 4:0:0:0 sdb 8:16 active ready running
```

**Multipath Configuration** (`/etc/multipath.conf`):
```
defaults {
    user_friendly_names yes
    path_grouping_policy multibus
    failback immediate
    no_path_retry 12
}
```

### vmstate Storage Location

Choose where to store VM memory state during live snapshots:

```ini
# Local storage (better performance, default)
vmstate_storage local

# Shared storage (required for migration with snapshots)
vmstate_storage shared
```

**Recommendations**:
- **local**: Use for best snapshot performance (RAM written to local NVMe/SSD)
- **shared**: Use only if you need to migrate VMs with live snapshots preserved

### API Performance

#### WebSocket vs REST

WebSocket transport offers better performance:

```ini
# Recommended for production
api_transport ws
api_scheme wss
```

**WebSocket Benefits**:
- Persistent connection - no repeated TLS handshake
- Lower latency - ~20-30ms faster per operation
- Connection pooling - reused across calls

**REST Fallback**:
Use REST if WebSocket is unreliable:
```ini
api_transport rest
api_scheme https
```

#### Bulk Operations

Enable bulk API operations to batch multiple calls:

```ini
# Enabled by default
enable_bulk_operations 1
```

Batches multiple API calls into single `core.bulk` request, reducing:
- Network round trips
- API rate limit consumption
- Overall operation time

#### Connection Caching

WebSocket connections are automatically cached and reused:
- 60-second connection lifetime
- Automatic reconnection on failure
- Reduced authentication overhead

### Rate Limiting Strategy

Configure retry behavior for TrueNAS API rate limits (20 calls/60s):

```ini
# Aggressive retry (high-availability)
api_retry_max 5
api_retry_delay 2

# Conservative retry (development)
api_retry_max 3
api_retry_delay 1
```

**Retry Schedule** (with defaults):
- Attempt 1: immediate
- Attempt 2: after 1s + jitter
- Attempt 3: after 2s + jitter
- Attempt 4: after 4s + jitter

Jitter: Random 0-20% added to prevent thundering herd

## Cluster Configuration

### Shared Storage Setup

For Proxmox VE clusters, configure shared storage:

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

**Critical Settings**:
- `shared 1` - Required for cluster
- Multiple portals - For redundancy
- `use_multipath 1` - For failover

### Cluster Deployment Script

Use the included deployment script to install on all nodes:

```bash
# Deploy to specific nodes
./update-cluster.sh node1 node2 node3

# Script will:
# 1. Copy TrueNASPlugin.pm to each node
# 2. Install to /usr/share/perl5/PVE/Storage/Custom/
# 3. Restart pvedaemon, pveproxy, pvestatd on each node
# 4. Verify installation
```

Manual deployment:
```bash
# On each cluster node
for node in pve1 pve2 pve3; do
  scp TrueNASPlugin.pm root@$node:/usr/share/perl5/PVE/Storage/Custom/
  ssh root@$node "systemctl restart pvedaemon pveproxy"
done
```

### High Availability (HA)

Configure for HA environments:

```ini
truenasplugin: ha-storage
    api_host truenas-vip.company.com  # Use VIP for TrueNAS HA
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:ha-cluster
    dataset tank/ha/proxmox
    discovery_portal 192.168.100.10:3260
    portals 192.168.100.11:3260,192.168.100.12:3260
    shared 1
    use_multipath 1
    force_delete_on_inuse 1
    logout_on_free 0
    api_retry_max 5
```

**HA Considerations**:
- Use TrueNAS virtual IP (VIP) for `api_host`
- Configure multiple portals on different TrueNAS controllers
- Enable `force_delete_on_inuse` for HA VM failover
- Set `logout_on_free 0` to maintain persistent connections
- Increase retry limits for HA failover tolerance

### Cluster Testing

Verify cluster functionality:

```bash
# On each node, check storage active
pvesm status

# Create test VM on node1
qm create 100 --name test-ha
qm set 100 --scsi0 cluster-storage:32

# Migrate to node2 (online migration)
qm migrate 100 node2 --online

# Verify disk access on node2
qm start 100
```

## Security Configuration

### CHAP Authentication

Enable CHAP for iSCSI security:

#### 1. Configure TrueNAS CHAP

Navigate to **Shares** → **Block Shares (iSCSI)** → **Authorized Access** → **Add**:
- **Group ID**: 1
- **User**: `proxmox-chap`
- **Secret**: 12-16 character password
- **Save**

Update portal: **Portals** → Edit portal → **Discovery Auth Method**: CHAP

#### 2. Configure Proxmox Plugin

```ini
truenasplugin: secure-storage
    # ... other settings ...
    chap_user proxmox-chap
    chap_password your-secure-chap-password
```

#### 3. Restart Services

```bash
systemctl restart pvedaemon pveproxy
```

### API Security

#### Use HTTPS/WSS

Always use encrypted transport in production:

```ini
api_scheme wss      # For WebSocket
# or
api_scheme https    # For REST
api_insecure 0      # Verify TLS certificates
```

#### API Key Management

**Best Practices**:
- Use dedicated API user (not root)
- Rotate API keys regularly (quarterly)
- Limit API user permissions to minimum required
- Store API keys securely (not in version control)

**Create Dedicated API User** in TrueNAS:
1. **Credentials** → **Local Users** → **Add**
2. Username: `proxmox-api`
3. Grant permissions: Datasets (full), iSCSI Shares (full), System (read)
4. Generate API key
5. Use this key in plugin configuration

### Network Security

#### VLAN Isolation

Use dedicated VLAN for storage traffic:

```bash
# Example: VLAN 100 for storage
# On Proxmox node
auto vmbr1.100
iface vmbr1.100 inet static
    address 10.0.100.10/24
    vlan-raw-device vmbr1
```

Configure TrueNAS interface on same VLAN (10.0.100.100)

#### Firewall Rules

Restrict access to required ports:

**On Proxmox Nodes**:
```bash
# Allow iSCSI to TrueNAS only
iptables -A OUTPUT -p tcp -d TRUENAS_IP --dport 3260 -j ACCEPT

# Allow TrueNAS API
iptables -A OUTPUT -p tcp -d TRUENAS_IP --dport 443 -j ACCEPT

# Block other iSCSI traffic
iptables -A OUTPUT -p tcp --dport 3260 -j DROP
```

**On TrueNAS**:
Configure allowed initiators in **Shares** → **Block Shares (iSCSI)** → **Initiators**

### Audit Logging

Monitor storage operations:

```bash
# Enable detailed logging
journalctl -u pvedaemon -f | grep TrueNAS

# Monitor TrueNAS API calls
tail -f /var/log/middlewared.log | grep -i proxmox

# Track iSCSI connections
journalctl -u iscsitarget -f
```

## Snapshot Features

### Live Snapshots

Create snapshots of running VMs including RAM state:

```bash
# Create live snapshot
qm snapshot 100 backup-live --vmstate 1 --description "Live backup"

# Rollback restores full VM state including RAM
qm rollback 100 backup-live
qm start 100  # VM resumes exactly where it was
```

**Configuration**:
```ini
enable_live_snapshots 1
vmstate_storage local  # Or 'shared'
```

**Use Cases**:
- Development snapshots - save exact working state
- Pre-update backups - rollback if update fails
- Testing - snapshot before risky operations

### Volume Snapshot Chains

Proxmox 9.x+ supports volume-based snapshot chains:

```ini
snapshot_volume_chains 1
```

**Benefits**:
- Better snapshot management
- Improved rollback performance
- Native ZFS snapshot integration

### Snapshot Best Practices

**Space Management**:
```bash
# Monitor snapshot space usage
zfs list -t snapshot | grep tank/proxmox

# Delete old snapshots
qm delsnapshot 100 old-snapshot
```

**Snapshot Retention**:
- Keep recent snapshots (hourly, daily)
- Archive old snapshots or delete
- Monitor ZFS space usage

**Performance**:
- Snapshots are instant (ZFS copy-on-write)
- Minimal space overhead initially
- Space grows as data diverges from snapshot

## Pre-flight Validation

The plugin performs comprehensive pre-flight checks before volume operations:

### Validation Checks

Executed automatically before volume creation/resize (~200ms):

1. **TrueNAS API Connectivity** - Verifies API reachable
2. **iSCSI Service Status** - Ensures iSCSI service running
3. **Space Availability** - Confirms space with 20% ZFS overhead margin
4. **Target Configuration** - Validates iSCSI target exists
5. **Dataset Existence** - Verifies parent dataset present

### Benefits

- **Fast Failure** - Fails in <1s vs 2-4s wasted work
- **Clear Errors** - Shows exactly what's wrong
- **No Orphans** - Prevents partial resource creation
- **Actionable Messages** - Includes fix instructions

### Example Validation Output

**Failure**:
```
Pre-flight validation failed:
  - TrueNAS iSCSI service is not running (state: STOPPED)
    Start the service in TrueNAS: System Settings > Services > iSCSI
  - Insufficient space on dataset 'tank/proxmox': need 120.00 GB (with 20% overhead), have 80.00 GB available
```

**Success**:
```
Pre-flight checks passed for 10.00 GB volume allocation on 'tank/proxmox' (VM 100)
```

## Storage Status and Health Monitoring

The plugin provides intelligent health monitoring:

### Status Classification

Errors are automatically classified by type:

**Connectivity Issues** (INFO level - temporary):
- Network timeouts, connection refused
- SSL/TLS errors
- Storage marked inactive, auto-recovers when connection restored

**Configuration Errors** (ERROR level - requires admin action):
- Dataset not found (ENOENT)
- Authentication failures (401/403)
- Storage marked inactive until fixed

**Other Failures** (WARNING level - investigate):
- Unexpected errors requiring investigation

### Monitoring Commands

```bash
# Check storage status
pvesm status

# View detailed status logs
journalctl -u pvedaemon | grep "TrueNAS storage"

# Monitor real-time
journalctl -u pvedaemon -f | grep truenas-storage
```

### Graceful Degradation

When storage becomes inactive:
- VMs continue running on existing volumes
- New volume operations fail with clear errors
- Storage auto-recovers when issue resolved
- No manual intervention needed for transient issues

## Advanced Troubleshooting

### Force Delete on In-Use

Allow deletion of volumes even when target is in use:

```ini
force_delete_on_inuse 1
```

**Use Case**:
- VM crashed but iSCSI target still shows "in use"
- Force logout before deletion to clean up

**Caution**: Use only when necessary, may interrupt active I/O

### Logout on Free

Automatically logout from target when no LUNs remain:

```ini
logout_on_free 1
```

**Use Case**:
- Clean up iSCSI sessions automatically
- Reduce stale connections

**Caution**: May cause connection overhead if frequently creating/deleting volumes

## Custom Configurations

### IPv6 Setup

Configure for IPv6 environments:

```ini
truenasplugin: ipv6-storage
    api_host 2001:db8::100
    api_key 1-your-api-key
    target_iqn iqn.2005-10.org.freenas.ctl:ipv6
    dataset tank/ipv6/proxmox
    discovery_portal [2001:db8::100]:3260
    portals [2001:db8::101]:3260,[2001:db8::102]:3260
    content images
    shared 1
    prefer_ipv4 0
    ipv6_by_path 1
    use_by_path 1
    use_multipath 1
```

**Key Settings**:
- `prefer_ipv4 0` - Disable IPv4 preference
- `ipv6_by_path 1` - Normalize IPv6 in device paths
- `use_by_path 1` - Required for IPv6

### Development Configuration

Relaxed security for testing:

```ini
truenasplugin: dev-storage
    api_host 192.168.1.50
    api_key 1-dev-key
    api_scheme http
    api_port 80
    api_insecure 1
    api_transport rest
    target_iqn iqn.2005-10.org.freenas.ctl:dev
    dataset tank/dev
    discovery_portal 192.168.1.50:3260
    content images
    shared 0
    use_multipath 0
```

**Warning**: Never use in production

## See Also
- [Configuration Reference](Configuration.md) - All configuration parameters
- [Troubleshooting Guide](Troubleshooting.md) - Common issues
- [Known Limitations](Known-Limitations.md) - Important restrictions
