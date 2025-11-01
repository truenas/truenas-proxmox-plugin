# NVMe/TCP Setup Guide

This guide covers setting up NVMe over TCP (NVMe/TCP) storage with the TrueNAS Proxmox plugin. NVMe/TCP provides lower latency and reduced CPU overhead compared to traditional iSCSI.

## Table of Contents

- [Prerequisites](#prerequisites)
- [TrueNAS Configuration](#truenas-configuration)
  - [Enable NVMe-oF Target Service](#enable-nvme-of-target-service)
  - [Create NVMe Subsystem](#create-nvme-subsystem)
  - [Configure DH-CHAP Authentication (Optional)](#configure-dh-chap-authentication-optional)
- [Proxmox Configuration](#proxmox-configuration)
  - [Install nvme-cli](#install-nvme-cli)
  - [Configure Storage](#configure-storage)
  - [Verify Connection](#verify-connection)
- [Multipath Configuration](#multipath-configuration)
- [DH-CHAP Authentication Setup](#dh-chap-authentication-setup)
  - [Generate Secrets](#generate-secrets)
  - [Configure on TrueNAS](#configure-on-truenas)
  - [Configure on Proxmox](#configure-on-proxmox)
- [Migration from iSCSI](#migration-from-iscsi)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)

## Prerequisites

**TrueNAS Requirements:**
- TrueNAS SCALE 25.10.0 or later
- ZFS pool and dataset configured
- Network connectivity between TrueNAS and Proxmox hosts
- NVMe-oF Target service available

**Proxmox Requirements:**
- Proxmox VE 9.x or later
- `nvme-cli` package installed (version 2.0+)
- Host NQN configured (auto-generated or custom)
- TrueNAS Proxmox plugin installed

**Network Requirements:**
- TCP port 4420 accessible on TrueNAS (default NVMe/TCP port)
- Low-latency network recommended (1GbE minimum, 10GbE+ preferred)
- For multipath: Multiple network interfaces configured

## TrueNAS Configuration

### Enable NVMe-oF Target Service

1. **Via TrueNAS Web GUI:**
   - Navigate to **System Settings → Services**
   - Locate **NVMe-oF Target** service
   - Click the toggle to **Start** the service
   - (Optional) Check **Start Automatically** to enable on boot

2. **Via TrueNAS API:**
   ```bash
   curl -k -X PUT 'https://TRUENAS_IP/api/v2.0/service/id/nvmet' \
     -H 'Authorization: Bearer YOUR_API_KEY' \
     -H 'Content-Type: application/json' \
     -d '{"enable": true}'

   curl -k -X POST 'https://TRUENAS_IP/api/v2.0/service/start' \
     -H 'Authorization: Bearer YOUR_API_KEY' \
     -H 'Content-Type: application/json' \
     -d '{"service": "nvmet"}'
   ```

3. **Verify service is running:**
   ```bash
   curl -k -X GET 'https://TRUENAS_IP/api/v2.0/service?service=nvmet' \
     -H 'Authorization: Bearer YOUR_API_KEY'
   ```

   Expected output should show `"state": "RUNNING"`.

### Create NVMe Subsystem

The plugin automatically creates subsystems when needed, but you can create them manually:

1. **Via TrueNAS Web GUI:**
   - Navigate to **Shares → NVMe-oF**
   - Click **Add Subsystem**
   - Configure:
     - **Name**: Short identifier (e.g., `proxmox-nvme`)
     - **Subsystem NQN**: Full NQN (e.g., `nqn.2005-10.org.freenas.ctl:proxmox-nvme`)
     - **Allow Any Host**: Enable for testing, disable for production with DH-CHAP
   - Click **Save**

2. **Via TrueNAS API:**
   ```bash
   curl -k -X POST 'https://TRUENAS_IP/api/v2.0/nvmet/subsys' \
     -H 'Authorization: Bearer YOUR_API_KEY' \
     -H 'Content-Type: application/json' \
     -d '{
       "name": "proxmox-nvme",
       "subnqn": "nqn.2005-10.org.freenas.ctl:proxmox-nvme",
       "allow_any_host": true
     }'
   ```

**Important Notes:**
- The subsystem NQN must follow the format: `nqn.YYYY-MM.domain:identifier`
- The plugin automatically creates subsystems if they don't exist
- Once set in storage.cfg, the subsystem NQN cannot be changed (marked as `fixed`)

### Configure DH-CHAP Authentication (Optional)

See the [DH-CHAP Authentication Setup](#dh-chap-authentication-setup) section for detailed authentication configuration.

## Proxmox Configuration

### Install nvme-cli

The `nvme-cli` package provides the tools needed to connect to NVMe/TCP targets:

```bash
apt-get update
apt-get install nvme-cli
```

**Verify installation:**
```bash
nvme version
# Expected output: nvme version 2.x or later
```

**Check host NQN:**
```bash
cat /etc/nvme/hostnqn
# Example output: nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400
```

If no hostnqn file exists, generate one:
```bash
nvme gen-hostnqn > /etc/nvme/hostnqn
```

### Configure Storage

Edit `/etc/pve/storage.cfg` to add NVMe/TCP storage:

**Minimal Configuration:**
```ini
truenasplugin: truenas-nvme
    api_host 10.15.14.172
    api_key 2-YourAPIKeyHere
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    dataset tank/proxmox
    discovery_portal 10.15.14.172:4420
    api_transport ws
    content images
    shared 1
```

**With Optional Parameters:**
```ini
truenasplugin: truenas-nvme
    api_host 10.15.14.172
    api_key 2-YourAPIKeyHere
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    hostnqn nqn.2014-08.org.nvmexpress:uuid:custom-uuid
    dataset tank/proxmox
    discovery_portal 10.15.14.172:4420
    api_transport ws
    api_scheme wss
    api_port 443
    api_insecure 1
    zvol_blocksize 64K
    content images
    shared 1
```

**Parameter Explanations:**

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `transport_mode` | Yes | Must be `nvme-tcp` for NVMe/TCP | `iscsi` |
| `subsystem_nqn` | Yes | NVMe subsystem NQN (format: `nqn.YYYY-MM.domain:name`) | None |
| `hostnqn` | No | Override host NQN (if not using `/etc/nvme/hostnqn`) | Auto-detected |
| `discovery_portal` | Yes | Primary portal IP:port | None |
| `api_transport` | Yes | Must be `ws` for NVMe API calls | `rest` |
| `nvme_dhchap_secret` | No | Host authentication secret | None |
| `nvme_dhchap_ctrl_secret` | No | Controller authentication secret | None |

**Important Notes:**
- `api_transport ws` is **required** - REST API does not support NVMe operations
- The default port for NVMe/TCP is `4420` (different from iSCSI's `3260`)
- `subsystem_nqn` cannot be changed after creation (prevents orphaned volumes)

### Verify Connection

After configuring storage, verify the NVMe connection:

```bash
# List connected subsystems
nvme list-subsys

# Expected output includes:
# nvme-subsysX - NQN=nqn.2005-10.org.freenas.ctl:proxmox-nvme
#                hostnqn=nqn.2014-08.org.nvmexpress:uuid:...
# \
#  +- nvmeX tcp traddr=10.15.14.172,trsvcid=4420,src_addr=10.15.14.195 live
```

```bash
# List NVMe devices
nvme list

# Should show TrueNAS devices with Model containing "TrueNAS"
```

```bash
# Check device UUID mapping
ls -la /dev/disk/by-id/nvme-uuid.*

# Example output:
# lrwxrwxrwx ... nvme-uuid.6b165acc-1bdd-4ee6-9f19-fa5dab818c50 -> ../../nvme3n2
```

## Multipath Configuration

NVMe/TCP supports native multipath for high availability and increased bandwidth.

### TrueNAS Multipath Setup

1. **Configure multiple network interfaces** on TrueNAS with different IPs
   - Example: `10.15.14.172` (primary), `10.15.14.173` (secondary)

2. **Ensure NVMe-oF port listens on all interfaces:**
   - Default configuration uses `0.0.0.0:4420` (all IPv4 interfaces)
   - Verify with: `curl -k https://TRUENAS_IP/api/v2.0/nvmet/port`

### Proxmox Multipath Storage Configuration

Add additional portals using the `portals` parameter:

```ini
truenasplugin: truenas-nvme-multipath
    api_host 10.15.14.172
    api_key 2-YourAPIKeyHere
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-ha
    dataset tank/proxmox
    discovery_portal 10.15.14.172:4420
    portals 10.15.14.173:4420,10.15.14.174:4420
    api_transport ws
    content images
    shared 1
```

### Verify Multipath

```bash
nvme list-subsys | grep -A 10 "proxmox-ha"

# Expected output shows multiple paths:
# nvme-subsysX - NQN=nqn.2005-10.org.freenas.ctl:proxmox-ha
# \
#  +- nvmeX tcp traddr=10.15.14.172,trsvcid=4420 live
#  +- nvmeX tcp traddr=10.15.14.173,trsvcid=4420 live
#  +- nvmeX tcp traddr=10.15.14.174,trsvcid=4420 live
```

**Multipath Behavior:**
- Plugin connects to all configured portals during subsystem connection
- At least ONE portal must succeed for the connection to be established
- Individual portal failures are logged but don't fail the operation (resilience)
- NVMe native multipath handles path failover automatically

## DH-CHAP Authentication Setup

DH-HMAC-CHAP provides secure authentication between Proxmox hosts and TrueNAS:
- **Unidirectional**: Proxmox authenticates to TrueNAS (host secret only)
- **Bidirectional**: Mutual authentication (host + controller secrets)

### Generate Secrets

On the Proxmox host, generate authentication secrets:

**Generate host secret:**
```bash
nvme gen-dhchap-key /dev/nvme0 --key-length=32 --hmac=1
# Output: DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
```

**Generate controller secret (for bidirectional auth):**
```bash
nvme gen-dhchap-key /dev/nvme0 --key-length=32 --hmac=1
# Output: DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
```

**Secret Format:**
- `DHHC-1`: Protocol version
- `01`: Hash algorithm (01 = SHA-256)
- Base64-encoded secret data

**Key Length Options:**
- `32` bytes (256-bit) - Recommended
- `48` bytes (384-bit)
- `64` bytes (512-bit)

### Configure on TrueNAS

Configure host authentication on TrueNAS:

**Via TrueNAS API:**
```bash
curl -k -X POST 'https://TRUENAS_IP/api/v2.0/nvmet/host' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "hostnqn": "nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400",
    "dhchap_key": "DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:",
    "dhchap_ctrl_key": "DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:",
    "dhchap_hash": "SHA-256"
  }'
```

**Parameters:**
- `hostnqn`: The Proxmox host's NQN (from `/etc/nvme/hostnqn`)
- `dhchap_key`: Host secret (Proxmox authenticates to TrueNAS)
- `dhchap_ctrl_key`: Controller secret (TrueNAS authenticates to Proxmox) - optional
- `dhchap_hash`: Hash algorithm (`SHA-256`, `SHA-384`, or `SHA-512`)

**Update Subsystem for Authentication:**

Disable `allow_any_host` to require authentication:

```bash
curl -k -X PUT 'https://TRUENAS_IP/api/v2.0/nvmet/subsys/id/SUBSYS_ID' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"allow_any_host": false}'
```

Then link the host to the subsystem (exact API endpoint varies - consult TrueNAS docs).

### Configure on Proxmox

Add the secrets to Proxmox storage.cfg:

**Unidirectional Authentication (Host Only):**
```ini
truenasplugin: truenas-nvme-secure
    api_host 10.15.14.172
    api_key 2-YourAPIKeyHere
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-secure
    dataset tank/proxmox
    discovery_portal 10.15.14.172:4420
    nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    api_transport ws
    content images
    shared 1
```

**Bidirectional Authentication (Host + Controller):**
```ini
truenasplugin: truenas-nvme-mutual
    api_host 10.15.14.172
    api_key 2-YourAPIKeyHere
    transport_mode nvme-tcp
    subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-mutual
    dataset tank/proxmox
    discovery_portal 10.15.14.172:4420
    nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
    api_transport ws
    content images
    shared 1
```

**Verify Authentication:**

Connection attempts without correct secrets will fail:
```bash
nvme list-subsys
# Should show successful connection with authentication

# Check kernel logs for auth messages
dmesg | grep -i nvme | grep -i auth
```

## Migration from iSCSI

Migrating from iSCSI to NVMe/TCP requires creating new storage and moving VM disks.

### Why In-Place Migration Isn't Possible

- `transport_mode` is marked as `fixed` (cannot be changed after creation)
- Volume naming formats are incompatible:
  - iSCSI: `vol-<zname>-lun<LUN>`
  - NVMe: `vol-<zname>-ns<UUID>`
- Device paths are different:
  - iSCSI: `/dev/disk/by-path/ip-...-lun-X` or `/dev/mapper/mpath*`
  - NVMe: `/dev/disk/by-id/nvme-uuid.*`

### Migration Steps

1. **Create new NVMe/TCP storage** with a different storage ID:
   ```ini
   # Existing iSCSI storage
   truenasplugin: truenas-iscsi
       transport_mode iscsi
       ...

   # New NVMe/TCP storage
   truenasplugin: truenas-nvme
       transport_mode nvme-tcp
       ...
   ```

2. **For running VMs - Live migration:**
   ```bash
   # Migrate disk while VM is running
   qm move-disk <VMID> scsi0 truenas-nvme --delete
   ```

3. **For stopped VMs - Offline migration:**
   ```bash
   # Stop the VM
   qm stop <VMID>

   # Move each disk
   qm move-disk <VMID> scsi0 truenas-nvme --delete
   qm move-disk <VMID> scsi1 truenas-nvme --delete

   # Start the VM
   qm start <VMID>
   ```

4. **For cluster-wide migration:**
   - Stop all VMs using the iSCSI storage
   - Migrate all disks to NVMe storage
   - Verify all VMs start correctly
   - Remove old iSCSI storage configuration

5. **Verify performance improvements:**
   ```bash
   # Test disk latency
   fio --name=randread --ioengine=libaio --direct=1 --bs=4k --iodepth=64 \
       --rw=randread --runtime=60 --filename=/dev/disk/by-id/nvme-uuid.*
   ```

6. **Decommission old iSCSI storage** after confirming stability:
   - Remove from `/etc/pve/storage.cfg`
   - Delete iSCSI targets/extents from TrueNAS
   - Clean up ZFS datasets if desired

## Performance Tuning

### Expected Performance Characteristics

**NVMe/TCP vs iSCSI:**
- **Latency**: NVMe/TCP 50-150μs vs iSCSI 200-500μs
- **CPU Overhead**: NVMe lower (no SCSI emulation layer)
- **Queue Depth**: NVMe native queuing (64K+ commands) vs iSCSI single queue
- **Bandwidth**: Similar on same network, but NVMe scales better with multipath

### Optimal Configuration

**ZFS Block Size:**
```ini
zvol_blocksize 64K  # Default - good for general workloads
zvol_blocksize 16K  # Better for database workloads (small random I/O)
zvol_blocksize 128K # Better for sequential I/O (media, backups)
```

**Network Tuning:**
- Use dedicated network interfaces for storage traffic
- Enable jumbo frames (MTU 9000) on both TrueNAS and Proxmox
- Use 10GbE or faster for best performance
- Consider separate VLANs for storage network

**Proxmox Settings:**
- Use VirtIO SCSI controller for VMs (best NVMe performance)
- Enable `iothread` for disk devices
- Set `cache=none` or `cache=writeback` depending on workload

**TrueNAS Settings:**
- Disable sync writes for better performance (at risk of data loss):
  ```bash
  zfs set sync=disabled tank/proxmox
  # WARNING: Only use for non-critical data
  ```
- Use fast SSDs for special vdevs (metadata, L2ARC)
- Ensure adequate RAM for ARC caching

### When to Use NVMe/TCP vs iSCSI

**Use NVMe/TCP when:**
- You have modern infrastructure (TrueNAS 25.10+, Proxmox 9.x+)
- You need lower latency (databases, high-IOPS workloads)
- You want better queue depth and parallelism
- You have CPU constraints (NVMe has less overhead)

**Use iSCSI when:**
- You have older infrastructure (compatibility)
- You need proven stability (iSCSI more mature in plugin)
- You require specific legacy CHAP implementations
- You have existing iSCSI infrastructure to maintain

## Troubleshooting

### Connection Issues

**Error: "nvme-cli is not installed"**
```bash
apt-get install nvme-cli
```

**Error: "Could not determine host NQN"**
```bash
# Generate a host NQN
nvme gen-hostnqn > /etc/nvme/hostnqn

# Verify
cat /etc/nvme/hostnqn
```

**Error: "No portals configured for NVMe/TCP storage"**
- Check storage.cfg for `discovery_portal` parameter
- Verify format: `IP:PORT` (e.g., `10.15.14.172:4420`)

**Error: "Failed to connect to any NVMe/TCP portal"**

Check network connectivity:
```bash
ping 10.15.14.172
telnet 10.15.14.172 4420
```

Check TrueNAS service:
```bash
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/service?service=nvmet' \
  -H 'Authorization: Bearer YOUR_API_KEY'
# Should show "state": "RUNNING"
```

Check TrueNAS NVMe port:
```bash
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/nvmet/port' \
  -H 'Authorization: Bearer YOUR_API_KEY'
# Should show port 4420 with addr_traddr listening
```

**Error: "REST API not supported for NVMe-oF operations"**
- Set `api_transport ws` in storage.cfg (WebSocket required)

### Authentication Issues

**Error: Authentication failed during connection**

Verify secrets match:
```bash
# On TrueNAS - check configured host
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/nvmet/host' \
  -H 'Authorization: Bearer YOUR_API_KEY'

# Compare hostnqn and dhchap_key with Proxmox configuration
cat /etc/nvme/hostnqn
grep nvme_dhchap_secret /etc/pve/storage.cfg
```

Regenerate secrets if needed and update both sides.

### Device Discovery Issues

**Error: "Could not locate NVMe device for UUID"**

Check if subsystem is connected:
```bash
nvme list-subsys | grep -i <subsystem_nqn>
```

Check if namespace exists:
```bash
nvme list | grep TrueNAS
```

Trigger udev rescan:
```bash
udevadm settle
sleep 1
ls -la /dev/disk/by-id/nvme-uuid.*
```

Check kernel logs:
```bash
dmesg | grep -i nvme | tail -20
```

### Namespace Issues

**Namespace creation fails**

Verify NVMe-oF service is running on TrueNAS.

Check dataset exists and has space:
```bash
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/pool/dataset/id/tank%2Fproxmox' \
  -H 'Authorization: Bearer YOUR_API_KEY'
```

Ensure WebSocket API is used (`api_transport ws`).

### Validation Commands

```bash
# 1. Check nvme-cli version
nvme version

# 2. View host NQN
cat /etc/nvme/hostnqn

# 3. List connected subsystems
nvme list-subsys

# 4. List NVMe devices
nvme list

# 5. Check device UUID mapping
ls -la /dev/disk/by-id/nvme-uuid.*

# 6. Test specific namespace read
dd if=/dev/disk/by-id/nvme-uuid.XXXX of=/dev/null bs=4M count=10 iflag=direct

# 7. Check kernel logs
dmesg | grep -i nvme | tail -50

# 8. Verify TrueNAS service
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/service?service=nvmet' \
  -H 'Authorization: Bearer YOUR_API_KEY'

# 9. List TrueNAS subsystems
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/nvmet/subsys' \
  -H 'Authorization: Bearer YOUR_API_KEY'

# 10. List TrueNAS namespaces
curl -k -X GET 'https://TRUENAS_IP/api/v2.0/nvmet/namespace' \
  -H 'Authorization: Bearer YOUR_API_KEY'
```

## See Also

- [Configuration Reference](Configuration.md) - Detailed parameter documentation
- [Troubleshooting Guide](Troubleshooting.md) - Additional troubleshooting scenarios
- [Advanced Features](Advanced-Features.md) - Performance tuning and optimization
- [Installation Guide](Installation.md) - Plugin installation instructions
