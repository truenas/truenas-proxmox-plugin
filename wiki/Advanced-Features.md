# Advanced Features

Advanced configuration, performance tuning, clustering, and security features of the TrueNAS Proxmox VE Storage Plugin.

## Table of Contents

- [Performance Tuning](#performance-tuning)
  - [ZFS Block Size Optimization](#zfs-block-size-optimization)
  - [Thin Provisioning](#thin-provisioning)
  - [Network Optimization](#network-optimization)
  - [Multipath I/O (MPIO)](#multipath-io-mpio)
  - [vmstate Storage Location](#vmstate-storage-location)
  - [API Performance](#api-performance)
  - [Rate Limiting Strategy](#rate-limiting-strategy)
- [Cluster Configuration](#cluster-configuration)
  - [Shared Storage Setup](#shared-storage-setup)
  - [Cluster Deployment Script](#cluster-deployment-script)
  - [High Availability (HA)](#high-availability-ha)
  - [Cluster Testing](#cluster-testing)
- [Security Configuration](#security-configuration)
  - [CHAP Authentication](#chap-authentication)
  - [API Security](#api-security)
  - [Network Security](#network-security)
  - [Audit Logging](#audit-logging)
- [Snapshot Features](#snapshot-features)
  - [Live Snapshots](#live-snapshots)
  - [Volume Snapshot Chains](#volume-snapshot-chains)
  - [Snapshot Best Practices](#snapshot-best-practices)
- [Pre-flight Validation](#pre-flight-validation)
- [Automatic Target Visibility](#automatic-target-visibility)
- [Storage Status and Health Monitoring](#storage-status-and-health-monitoring)
- [Advanced Troubleshooting](#advanced-troubleshooting)
  - [Force Delete on In-Use](#force-delete-on-inuse)
  - [Logout on Free](#logout-on-free)
- [Custom Configurations](#custom-configurations)
  - [IPv6 Setup](#ipv6-setup)
  - [Development Configuration](#development-configuration)

---

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

Multipath provides redundancy and load balancing across multiple network paths to your TrueNAS storage.

#### Quick Start

```ini
use_multipath 1
portals 192.168.10.101:3260,192.168.10.102:3260
```

#### Network Requirements (CRITICAL)

**Each iSCSI path MUST be on a different subnet** for multipath to work correctly.

✅ **Correct Configuration:**
```
TrueNAS:
  - Interface 1: 10.15.14.172/23  (subnet: 10.15.14.0/23)
  - Interface 2: 10.30.30.2/24    (subnet: 10.30.30.0/24)

Proxmox Node:
  - Interface 1: 10.15.14.89/23   (matches TrueNAS subnet)
  - Interface 2: 10.30.30.3/24    (matches TrueNAS subnet)
```

❌ **Incorrect Configuration:**
```
TrueNAS:
  - Interface 1: 10.1.101.10/24  (subnet: 10.1.101.0/24)
  - Interface 2: 10.1.101.20/24  (subnet: 10.1.101.0/24)  ← Same subnet!

Result: Only one path will be used (routing table limitation)
```

**Why different subnets are required**: If both interfaces are on the same subnet, the OS routing table will only send traffic out one interface, preventing multipath from functioning.

#### TrueNAS Portal Configuration

TrueNAS supports **two valid approaches** for configuring iSCSI portals for multipath:

##### Approach 1: Single Portal Group (Simpler, Recommended)

Configure all IPs in **one portal group**:

```
TrueNAS → Shares → Block Shares (iSCSI) → Portals → Add

Portal Configuration:
  Comment: "Proxmox Multipath"

  Listen Addresses:
    - IP: 10.15.14.172, Port: 3260  (Click Add to add second IP)
    - IP: 10.30.30.2, Port: 3260

  Discovery Authentication Method: None (or CHAP if required)

Result: Portal ID 1 with both IPs
```

**Pros:**
- Simpler configuration
- Single portal to manage
- Works reliably for multipath
- Easier troubleshooting

**Target Association:**
```
Target → Groups → Add:
  Portal Group: 1
  Initiator Group: (your initiator group)
```

##### Approach 2: Separate Portal Groups (Alternative)

Create **separate portal groups** for each network path:

```
Portal 1:
  Comment: "Proxmox Path 1"
  Listen: 10.15.14.172:3260

Portal 2:
  Comment: "Proxmox Path 2"
  Listen: 10.30.30.2:3260
```

**Pros:**
- Explicit path separation
- More granular control per path
- Can set different authentication per path

**Target Association:**
```
Target → Groups → Add both:
  Portal Group: 1
  Portal Group: 2
```

**Both approaches work correctly** - choose based on your preference and management needs.

#### Network Topology Best Practices

**Recommended Physical Setup:**
```
┌─────────────┐
│  TrueNAS    │
│             │
│ eth0: 10.15.14.172/23 ────────┐
│ eth1: 10.30.30.2/24 ───────┐  │
└─────────────┘              │  │
                             │  │
                  ┌──────────┘  │
                  │  ┌──────────┘
                  │  │
               ┌──▼──▼────────┐
               │  Switch(es)  │
               └──┬──┬────────┘
                  │  │
                  │  └──────────┐
                  └──────────┐  │
                             │  │
┌─────────────┐              │  │
│  Proxmox    │              │  │
│             │              │  │
│ eth2: 10.15.14.89/23 ◄─────┘  │
│ eth3: 10.30.30.3/24 ◄─────────┘
└─────────────┘
```

**Network Best Practices:**
- Use dedicated physical NICs for storage (not shared with VM/management traffic)
- Configure storage on dedicated VLANs for isolation
- Use at least 1GbE per path (**10GbE strongly recommended**)
- Enable jumbo frames (MTU 9000) on all storage interfaces and switches
- Ensure physical network redundancy (separate cables, switches if possible)
- Keep path bandwidths identical (don't mix 1GbE and 10GbE)

**VLAN Configuration Example:**
```
VLAN 10 (Storage Path 1): 10.15.14.0/23
VLAN 20 (Storage Path 2): 10.30.30.0/24

TrueNAS:
  - eth0: VLAN 10, IP 10.15.14.172
  - eth1: VLAN 20, IP 10.30.30.2

Proxmox:
  - eth2: VLAN 10, IP 10.15.14.89
  - eth3: VLAN 20, IP 10.30.30.3
```

#### Proxmox Host Configuration

**1. Install Multipath Tools**
```bash
apt-get update
apt-get install multipath-tools
```

**2. Configure Multipath** (`/etc/multipath.conf`):
```conf
defaults {
    user_friendly_names yes
    path_grouping_policy multibus
    path_selector "round-robin 0"
    rr_min_io_rq 1
    failback immediate
    no_path_retry queue
    find_multipaths no
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^sda"  # Exclude OS disk (adjust if needed)
}

# Optional: Specific device configuration for TrueNAS
devices {
    device {
        vendor "TrueNAS"
        product "iSCSI Disk"
        path_grouping_policy multibus
        path_selector "round-robin 0"
        hardware_handler "0"
        rr_weight uniform
        rr_min_io_rq 1
    }
}
```

**3. Enable and Start Multipath**
```bash
systemctl enable multipathd
systemctl start multipathd
systemctl status multipathd
```

**4. Network Interface Configuration**

Enable jumbo frames on storage interfaces:
```bash
# Edit /etc/network/interfaces
auto eth2
iface eth2 inet static
    address 10.15.14.89/23
    mtu 9000

auto eth3
iface eth3 inet static
    address 10.30.30.3/24
    mtu 9000

# Apply changes
ifdown eth2 && ifup eth2
ifdown eth3 && ifup eth3

# Verify MTU
ip link show eth2
ip link show eth3
```

**Verify jumbo frames end-to-end:**
```bash
# Test MTU 9000 (8972 bytes + 28 byte header)
ping -M do -s 8972 -c 3 10.15.14.172
ping -M do -s 8972 -c 3 10.30.30.2

# Should succeed without fragmentation
```

#### Storage Configuration

Add to `/etc/pve/storage.cfg`:

**For Single Portal Group (Approach 1):**
```ini
truenasplugin: truenas-storage
    api_host 10.15.14.172
    api_key YOUR_API_KEY
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    dataset tank/proxmox
    discovery_portal 10.15.14.172:3260
    portals 10.30.30.2:3260
    content images
    shared 1
    use_multipath 1
```

**For Separate Portal Groups (Approach 2):**
```ini
truenasplugin: truenas-storage
    api_host 10.15.14.172
    api_key YOUR_API_KEY
    target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    dataset tank/proxmox
    discovery_portal 10.15.14.172:3260
    portals 10.30.30.2:3260
    content images
    shared 1
    use_multipath 1
```

**Note**: The plugin configuration is identical for both approaches. `discovery_portal` specifies the primary portal for discovery, `portals` lists additional portals.

#### Verification and Testing

**1. Verify iSCSI Discovery**
```bash
# Discover targets from both portals
iscsiadm -m discovery -t sendtargets -p 10.15.14.172:3260
iscsiadm -m discovery -t sendtargets -p 10.30.30.2:3260

# Should show the same target from both IPs
```

**2. Verify iSCSI Sessions**
```bash
# Should show 2 sessions (one per portal)
iscsiadm -m session

# Expected output:
# tcp: [7] 10.15.14.172:3260,1 iqn.2005-10.org.freenas.ctl:proxmox (non-flash)
# tcp: [11] 10.30.30.2:3260,1 iqn.2005-10.org.freenas.ctl:proxmox (non-flash)
```

**3. Verify Multipath Devices**
```bash
# List all multipath devices
multipath -ll

# Expected output:
# mpathe (36589cfc000000xyz...) dm-5 TrueNAS,iSCSI Disk
# size=10G features='1 queue_if_no_path' hwhandler='0' wp=rw
# `-+- policy='round-robin 0' prio=1 status=active
#   |- 11:0:0:2 sdh 8:112 active ready running  ← Path 1
#   `- 7:0:0:2  sdf 8:80  active ready running  ← Path 2
```

**Key indicators:**
- Both paths show `active ready running`
- Policy is `round-robin 0` for load balancing
- Two different SCSI host numbers (7 and 11) indicate separate sessions

**4. Verify Path Usage**

Confirm both paths are actively used for I/O:
```bash
# Record initial stats
grep -E '(sdh|sdf)' /proc/diskstats > /tmp/before.txt

# Write test data (adjust device name to your multipath device)
dd if=/dev/zero of=/dev/mapper/mpathe bs=1M count=1024 oflag=direct

# Check stats again
grep -E '(sdh|sdf)' /proc/diskstats > /tmp/after.txt

# Both devices should show increased write sectors (field 10)
# Calculate difference:
awk 'NR==FNR{old[$3]=$10; next} {new=$10; dev=$3; print dev": sectors written =", new-old[dev]}' \
    /tmp/before.txt /tmp/after.txt

# Both should show roughly equal values (50/50 distribution)
```

**5. Performance Testing**

```bash
# Test write performance (should show ~100-110 MB/s on 2x 1GbE)
fio --name=write-test --filename=/dev/mapper/mpathe \
    --rw=write --bs=1M --size=2G --numjobs=4 --iodepth=16 \
    --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting

# Test read performance with parallel I/O
fio --name=read-test --filename=/dev/mapper/mpathe \
    --rw=read --bs=1M --size=2G --numjobs=4 --iodepth=16 \
    --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting
```

#### Performance Expectations

**Theoretical Maximum** (2x 1GbE):
- Raw bandwidth: 2 Gbps = 250 MB/s
- Realistic with TCP/IP overhead: ~200-220 MB/s

**Observed Performance** (2x 1GbE with multipath):

| Workload Type | Expected Performance | Notes |
|---------------|---------------------|-------|
| **Sequential Writes** | ~100-110 MB/s | Both paths utilized ✅ |
| **Parallel Writes (4 jobs)** | ~100-110 MB/s | Full aggregate bandwidth ✅ |
| **Sequential Reads** | ~50-100 MB/s | Limited by iSCSI protocol ⚠️ |
| **Parallel Reads (4 jobs)** | ~100-110 MB/s | Multiple I/O streams help ✅ |
| **Random I/O (mixed)** | ~80-100 MB/s | Natural parallelism ✅ |
| **Multiple VMs** | Scales well | Each VM can use different paths ✅ |

**With 10GbE** (2x 10GbE multipath):
- Write performance: ~800-1000 MB/s
- Read performance: ~800-1000 MB/s
- Significantly better for all workload types
- Bypasses most iSCSI protocol limitations

**Important Performance Note**:

Read performance may appear lower than expected in single-threaded benchmarks. This is due to TrueNAS SCALE's `MaxOutstandingR2T=1` setting, which limits read parallelism. **This is a platform limitation, not a configuration error.**

- Both paths ARE being used (verify with diskstats)
- Paths alternate rapidly (round-robin)
- Real-world multi-VM workloads perform better than benchmarks
- See [Known Limitations - Multipath Read Performance](Known-Limitations.md#multipath-read-performance-limitation) for detailed explanation

#### Failover Testing

**Test automatic failover:**

```bash
# Terminal 1: Monitor multipath status
watch -n 1 'multipath -ll'

# Terminal 2: Simulate path failure
# Disconnect cable, disable interface, or block traffic
ip link set eth2 down

# Observe in Terminal 1:
# - Failed path marked as "failed faulty"
# - I/O continues on remaining path
# - No VM disruption

# Restore path
ip link set eth2 up

# Observe:
# - Path automatically restored to "active ready running"
# - Load balancing resumes across both paths
```

**Monitor failover in logs:**
```bash
# Watch multipathd for failover events
journalctl -u multipathd -f

# Test path failure
ip link set eth2 down

# Should see messages like:
# "sdh: path down"
# "mpathe: Entering recovery mode"
# "mpathe: 1 path(s) remaining"

# Restore path
ip link set eth2 up

# Should see:
# "sdh: path up"
# "mpathe: Exiting recovery mode"
```

#### Troubleshooting

**Problem**: Only one path shows up in `multipath -ll`

**Diagnosis:**
```bash
# Check iSCSI discovery
iscsiadm -m discovery -t sendtargets -p 10.15.14.172:3260

# Should show target with both portal IPs
```

**Solutions:**
1. Verify both portals are configured on TrueNAS (either in one portal group or separate groups)
2. Ensure both networks are reachable from Proxmox:
   ```bash
   ping -c 3 10.15.14.172
   ping -c 3 10.30.30.2
   ```
3. Check routing table shows both subnets:
   ```bash
   ip route
   # Should show routes for both 10.15.14.0/23 and 10.30.30.0/24
   ```
4. Verify iSCSI login to both portals:
   ```bash
   iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:proxmox --login
   ```

**Problem**: Both paths present but only one is used

**Diagnosis:**
```bash
# Check if interfaces are on same subnet
ip addr show | grep inet

# Check routing table
ip route
```

**Solution:**
- **Both interfaces MUST be on different subnets**
- Reconfigure network to use separate subnets (e.g., 10.1.0.0/24 and 10.2.0.0/24)

**Problem**: Performance is poor despite both paths active

**Diagnosis:**
```bash
# Check MTU settings
ip link show | grep mtu

# Test jumbo frames
ping -M do -s 8972 -c 3 10.15.14.172

# Check for network errors
ip -s link show eth2
ip -s link show eth3
```

**Solutions:**
1. Enable jumbo frames (MTU 9000) on all interfaces:
   ```bash
   ip link set eth2 mtu 9000
   ip link set eth3 mtu 9000
   ```
2. Verify no packet loss:
   ```bash
   ping -c 100 -s 8972 10.15.14.172
   ```
3. Check multipath configuration uses round-robin:
   ```bash
   multipath -ll | grep policy
   # Should show: policy='round-robin 0'
   ```

**Problem**: Path failover is slow

**Diagnosis:**
```bash
# Check multipathd configuration
multipath -t
grep failback /etc/multipath.conf
```

**Solution:**
- Ensure `failback immediate` is set in `/etc/multipath.conf`
- Restart multipathd:
  ```bash
  systemctl restart multipathd
  ```

#### Common Mistakes to Avoid

❌ **Don't**: Configure both interfaces on the same subnet
✅ **Do**: Use different subnets for each path (e.g., 10.1.x.x and 10.2.x.x)

❌ **Don't**: Use network bonding/LACP on storage interfaces
✅ **Do**: Let multipath handle load balancing at the iSCSI layer

❌ **Don't**: Share storage network with VM/management traffic
✅ **Do**: Use dedicated VLANs for storage

❌ **Don't**: Mix different network speeds (1GbE + 10GbE)
✅ **Do**: Use identical NICs and speeds for all paths

❌ **Don't**: Expect sequential read benchmarks to show full aggregate bandwidth
✅ **Do**: Test with parallel I/O workloads or real-world VM usage

❌ **Don't**: Forget to enable jumbo frames
✅ **Do**: Set MTU 9000 on all storage interfaces and switches

❌ **Don't**: Assume multipath is working without verification
✅ **Do**: Verify both paths are active and load-balancing using `multipath -ll` and diskstats

#### Advanced: Monitoring Path Performance

**Real-time path monitoring script:**
```bash
#!/bin/bash
# /usr/local/bin/monitor-multipath.sh

MPATH=${1:-mpathe}
INTERVAL=${2:-2}

echo "Monitoring multipath device: $MPATH (Ctrl+C to stop)"
echo "=========================================="
echo ""

# Get path devices
PATHS=$(multipath -ll $MPATH | grep -E 'sd[a-z]' | awk '{print $3}')

while true; do
    clear
    echo "=== $(date) ==="
    echo ""

    # Show multipath status
    echo "Multipath Status:"
    multipath -ll $MPATH | head -6
    echo ""

    # Show per-path I/O stats
    echo "Path I/O Statistics:"
    printf "%-8s %10s %10s %10s %10s\n" "Device" "Reads" "Read MB" "Writes" "Write MB"
    echo "------------------------------------------------------------"

    for dev in $PATHS; do
        stats=$(grep " $dev " /proc/diskstats)
        reads=$(echo $stats | awk '{print $4}')
        read_sect=$(echo $stats | awk '{print $6}')
        writes=$(echo $stats | awk '{print $8}')
        write_sect=$(echo $stats | awk '{print $10}')

        read_mb=$((read_sect / 2048))
        write_mb=$((write_sect / 2048))

        printf "%-8s %10s %10s %10s %10s\n" "$dev" "$reads" "$read_mb" "$writes" "$write_mb"
    done

    echo ""
    echo "Press Ctrl+C to stop monitoring"
    sleep $INTERVAL
done
```

**Usage:**
```bash
chmod +x /usr/local/bin/monitor-multipath.sh
/usr/local/bin/monitor-multipath.sh mpathe 2
```

#### See Also
- [Configuration Reference - use_multipath](Configuration.md#use_multipath)
- [Configuration Reference - portals](Configuration.md#portals)
- [Known Limitations - Multipath Read Performance](Known-Limitations.md#multipath-read-performance-limitation)
- [Troubleshooting - Slow Multipath Read Performance](Troubleshooting.md#slow-multipath-read-performance)

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

## Automatic Target Visibility

The plugin automatically maintains iSCSI target visibility to prevent discovery issues when targets have no extents.

### The Problem

iSCSI targets without any mapped extents become **undiscoverable**:
- Target exists in TrueNAS but doesn't appear in `iscsiadm` discovery
- Proxmox storage shows errors: "Could not resolve iSCSI target ID"
- Occurs when all VM disks are deleted from a target
- Prevents new disk allocation until manually fixed

### Weight Zvol Solution

The plugin automatically creates a 1GB "weight" zvol to keep targets visible:

**Automatic Behavior**:
1. **Detection** - During storage activation, checks if target exists but isn't discoverable
2. **Weight Creation** - Creates `pve-plugin-weight` zvol (1GB) in storage dataset
3. **Extent Mapping** - Creates extent and maps it to target automatically
4. **Visibility Restored** - Target becomes discoverable again

**Implementation Details**:
- Runs in `activate_storage()` as a pre-flight check
- Only creates weight if target exists on TrueNAS but isn't discoverable
- Weight zvol uses same dataset as VM disks (e.g., `tank/proxmox/pve-plugin-weight`)
- Automatically creates extent named `pve-plugin-weight`
- Maps extent to configured target with next available LUN
- Logs all actions to syslog for audit trail

### Viewing Weight Zvol

The weight zvol appears in storage listings:

```bash
# List all storage content
pvesm list truenas-storage

# Output shows weight zvol with VMID 0
truenas-storage:vol-pve-plugin-weight-lun0    1GB    images    0
```

**Characteristics**:
- **VMID**: Always `0` (excluded from VM disk listings)
- **Size**: Fixed 1GB
- **Format**: `raw`
- **Persistent**: Remains until manually deleted
- **Automatic Recreation**: Recreated if deleted while target has no other extents

### Manual Management

**View Weight Zvol**:
```bash
# Check if weight exists
pvesm list truenas-storage | grep weight
```

**Delete Weight Zvol** (optional):
```bash
# Remove weight zvol
pvesm free truenas-storage:vol-pve-plugin-weight-lun0

# Warning: Will be recreated on next storage activation if target has no extents
```

**Prevent Recreation**:
The weight is only needed when the target would otherwise have no extents. To prevent recreation:
1. Create at least one VM disk on the storage, OR
2. Manually create a different extent mapped to the target

### Troubleshooting

**Weight Not Created**:
```bash
# Check logs
journalctl -u pvedaemon | grep -i "pre-flight"

# Common reasons:
# 1. Target doesn't exist on TrueNAS
# 2. Target already has other extents (weight not needed)
# 3. API connectivity issues
# 4. Insufficient permissions
```

**Target Still Not Discoverable**:
```bash
# Verify target exists
pvesh get /nodes/<nodename>/storage/<storageid>/iscsi-target

# Manual discovery test
iscsiadm -m discovery -t sendtargets -p <portal-ip>:<port>

# Check TrueNAS:
# 1. Navigate to Shares > Block Shares (iSCSI) > Targets
# 2. Verify target exists with correct name
# 3. Check Extents tab - should see pve-plugin-weight extent
# 4. Check Target/Extents tab - verify mapping exists
```

**Network Issues**:
- Weight creation requires API connectivity to TrueNAS
- Check network between Proxmox node and TrueNAS
- Verify API endpoint accessible: `curl -k https://<truenas-ip>/api/v2.0/system/info`

### Benefits

- **Zero Manual Intervention** - Automatic detection and resolution
- **Production Ready** - Handles edge cases gracefully
- **Minimal Overhead** - Only 1GB space used
- **Transparent Operation** - No impact on normal VM operations
- **Audit Trail** - All actions logged to syslog
- **Cluster Compatible** - Works correctly across all cluster nodes

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
