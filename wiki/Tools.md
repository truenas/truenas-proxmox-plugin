# Tools and Utilities

Documentation for included tools and utilities to help manage the TrueNAS Proxmox VE Storage Plugin.

## Overview

The plugin includes several tools to simplify installation, testing, cluster management, and maintenance:

- **[Development Test Suite](#development-test-suite)** - **Development/testing only** - Comprehensive plugin testing
- **[Debug Logging System](#debug-logging-system)** - Diagnostic logging for troubleshooting
- **[Production Test Suite](#production-test-suite)** - Automated testing and validation for production
- **[Health Check Tool](#health-check-tool)** - Quick health validation for monitoring
- **[Orphan Cleanup Tool](#orphan-cleanup-tool)** - Find and remove orphaned iSCSI resources
- **[Version Check Script](#version-check-script)** - Check plugin version across cluster
- **[Cluster Update Script](#cluster-update-script)** - Deploy plugin to all cluster nodes
- **[Tools Directory](#tools-directory-structure)** - Location and organization

## Tools Directory Structure

```
tools/
├── truenas-plugin-test-suite.sh              # Production test suite
├── health-check.sh                            # Health validation tool
├── cleanup-orphans.sh                         # Orphan resource cleanup
├── update-cluster.sh                          # Cluster deployment script
├── check-version.sh                           # Version checker for cluster
└── dev-truenas-plugin-full-function-test.sh  # Development test suite (⚠️ DEV ONLY)
```

All tools are located in the `tools/` directory of the plugin repository.

---

## Development Test Suite

> ⚠️ **WARNING: DEVELOPMENT USE ONLY**
> This test suite is designed for **plugin development and debugging only**.
> **DO NOT run on production systems** - it creates/deletes test VMs and may interfere with running workloads.

### Overview

The Development Test Suite (`dev-truenas-plugin-full-function-test.sh`) is a comprehensive testing tool that validates the core functionality of the plugin, primarily used during plugin development to verify bug fixes and new features.

**Location**: `tools/dev-truenas-plugin-full-function-test.sh`

**Purpose**:
- Plugin development and debugging
- Regression testing after code changes
- Size allocation verification
- TrueNAS backend validation
- Generating diagnostic data for bug reports

### Features

- **Machine-Readable Output** - JSON + CSV logs for analysis
- **TrueNAS Size Verification** - Validates disk sizes on TrueNAS backend via API
- **API-Only Testing** - Uses Proxmox API exclusively (pvesh)
- **Detailed Timing** - Performance metrics for all operations
- **Color-Coded Output** - Clear visual status indicators

### Usage

> ⚠️ **IMPORTANT**: Only run in isolated test/development environments

```bash
# Navigate to tools directory
cd tools/

# Basic usage (development environment only!)
./dev-truenas-plugin-full-function-test.sh

# Specify storage and node
./dev-truenas-plugin-full-function-test.sh tnscale pve-test-node 9001

# View results
cat test-results-*.json | jq .
```

### Test Categories

#### Disk Allocation Tests

Tests disk creation via Proxmox API with various sizes (1GB, 10GB, 32GB, 100GB).

**Verifies**:
- Proxmox reports correct size (`pvesm list`)
- Block device has correct size (`blockdev --getsize64`)
- **TrueNAS zvol has correct size (via API)** ✓

#### Disk Deletion Tests

Tests disk deletion and verifies cleanup on TrueNAS backend.

**Verifies**:
- Zvol deleted from TrueNAS
- iSCSI extent removed
- No orphaned resources

### Output Files

**JSON Log** (`test-results-TIMESTAMP.json`):
```json
{
  "test_run": {
    "timestamp": "2025-10-08T07:15:00Z",
    "storage_id": "tnscale",
    "truenas_api": "10.15.14.172",
    "node": "pve-test-node"
  },
  "tests": [
    {
      "test_id": "alloc_001",
      "test_name": "Allocate 10GB disk via API",
      "category": "disk_allocation",
      "status": "PASS",
      "duration_ms": 2341,
      "results": {
        "requested_bytes": 10737418240,
        "truenas_bytes": 10737418240,
        "size_match": true
      }
    }
  ],
  "summary": {
    "total": 8,
    "passed": 8,
    "failed": 0
  }
}
```

**CSV Log** (`test-results-TIMESTAMP.csv`):
```csv
test_id,test_name,category,status,duration_ms,requested_bytes,actual_bytes,size_match,error_message
alloc_001,"Allocate 10GB disk via API",disk_allocation,PASS,2341,10737418240,10737418240,true,
```

### When to Use

**✅ Appropriate Use Cases**:
- Plugin development and testing
- Verifying bug fixes (e.g., size allocation bug)
- Regression testing after code changes
- Generating diagnostic data for bug reports
- CI/CD pipeline for plugin repository

**❌ Do NOT Use For**:
- Production environment validation (use Production Test Suite instead)
- Running on live systems with active VMs
- Routine health checks (use Health Check tool instead)

### Development Workflow

```bash
# 1. Make code changes to plugin
vim TrueNASPlugin.pm

# 2. Deploy to test node
scp TrueNASPlugin.pm root@pve-test:/usr/share/perl5/PVE/Storage/Custom/
ssh root@pve-test "systemctl restart pvedaemon"

# 3. Run development test suite
cd tools/
./dev-truenas-plugin-full-function-test.sh test-storage pve-test 9001

# 4. Review results
cat test-results-*.json | jq '.summary'

# 5. Fix any failures and repeat
```

### CI/CD Integration

```yaml
# .github/workflows/test.yml
name: Test Plugin

on: [push, pull_request]

jobs:
  test:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v3
      - name: Deploy to test node
        run: |
          scp TrueNASPlugin.pm root@pve-test:/usr/share/perl5/PVE/Storage/Custom/
          ssh root@pve-test "systemctl restart pvedaemon"
      - name: Run tests
        run: |
          cd tools/
          ./dev-truenas-plugin-full-function-test.sh test-storage pve-test 9001
      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: tools/test-results-*.json
```

### Limitations

- Creates test VMs (VMIDs 9001-9025 by default)
- Consumes storage space during tests
- May interfere with existing VMs in VMID range
- Requires API access to TrueNAS
- Not suitable for concurrent execution

### See Also

- [Production Test Suite](#production-test-suite) - For production validation
- [Debug Logging System](#debug-logging-system) - For detailed diagnostics
- [Health Check Tool](#health-check-tool) - For quick health validation

---

## Debug Logging System

### Overview

The plugin includes a 3-level debug logging system that can be enabled without code changes by modifying the storage configuration. This is useful for troubleshooting issues in both development and production environments.

**Debug Levels**:
- **Level 0** (default): Errors only - Production mode
- **Level 1**: Light diagnostic - Function calls and key operations
- **Level 2**: Verbose - Full API payloads and detailed traces

### Configuration

Edit `/etc/pve/storage.cfg` and add the `debug` parameter:

```ini
truenasplugin: tnscale
        api_host 10.15.14.172
        api_key xxxxx
        dataset pve_test/pve-storage
        target_iqn iqn.2005-10.org.freenas.ctl:proxmox
        discovery_portal 10.15.14.172
        debug 1
```

**Available Values**:
- `debug 0` - Production mode (errors only) - **default**
- `debug 1` - Light debugging (recommended for troubleshooting)
- `debug 2` - Verbose mode (for deep diagnosis)

### Viewing Debug Logs

All debug output goes to syslog:

```bash
# View all plugin logs in real-time
journalctl -t truenasplugin -f

# View recent logs
journalctl -t truenasplugin --since "5 minutes ago"

# Filter by priority
journalctl -t truenasplugin -p info
journalctl -t truenasplugin -p debug
```

### Debug Level Examples

#### Level 0 (Errors Only - Default)

```
Oct 08 07:15:23 pve-node truenasplugin[12345]: alloc_image pre-flight check failed for VM 100: API unreachable
```

Minimal logging - only critical errors. **Recommended for production.**

#### Level 1 (Light Diagnostic)

```
Oct 08 07:15:23 pve-node truenasplugin[12345]: alloc_image: vmid=100, name=undef, size=33554432 KiB
Oct 08 07:15:23 pve-node truenasplugin[12345]: alloc_image: running pre-flight checks for 34359738368 bytes
Oct 08 07:15:24 pve-node truenasplugin[12345]: alloc_image: pre-flight checks passed for 32.00 GB volume
Oct 08 07:15:25 pve-node truenasplugin[12345]: free_image: volname=vol-vm-100-disk-0-lun5
```

Shows function entry/exit and key operations. **Recommended for troubleshooting.**

#### Level 2 (Verbose)

```
Oct 08 07:15:23 pve-node truenasplugin[12345]: alloc_image: vmid=100, size=33554432 KiB
Oct 08 07:15:23 pve-node truenasplugin[12345]: alloc_image: converting 33554432 KiB → 34359738368 bytes
Oct 08 07:15:23 pve-node truenasplugin[12345]: _api_call: method=pool.dataset.create, transport=ws, params=[{"name":"pve_test/pve-storage/vm-100-disk-0","type":"VOLUME","volsize":34359738368}]
Oct 08 07:15:24 pve-node truenasplugin[12345]: _api_call: response from pool.dataset.create: {"id":"pve_test/pve-storage/vm-100-disk-0"}
Oct 08 07:15:24 pve-node truenasplugin[12345]: _api_call: method=iscsi.extent.create, params=[{"name":"vm-100-disk-0","disk":"zvol/pve_test/vm-100-disk-0"}]
```

Full API payloads and detailed traces. **Use for deep debugging only** (generates significant log volume).

### Changing Debug Level at Runtime

```bash
# Enable level 1 debugging
sed -i '/truenasplugin: tnscale/,/^$/s/debug [0-9]/debug 1/' /etc/pve/storage.cfg

# Or add debug line if it doesn't exist
sed -i '/truenasplugin: tnscale/a\        debug 1' /etc/pve/storage.cfg

# Changes take effect immediately - no restart required
```

### Performance Impact

**Level 0**: No performance impact
**Level 1**: Negligible impact (<1%)
**Level 2**: 10-20% slower due to JSON serialization, generates 1-10 MB per operation

**Recommendation**: Use level 1 for troubleshooting, level 2 only for specific issue diagnosis.

### Troubleshooting with Debug Logs

**Problem**: Disk allocation fails
```bash
# Enable debug logging
echo "        debug 1" >> /etc/pve/storage.cfg  # (add after storage entry)

# Attempt operation and capture logs
journalctl -t truenasplugin -f > debug.log &
pvesh create /nodes/$(hostname)/storage/tnscale/content --vmid 100 --filename vm-100-disk-0 --size 10G

# Review logs
grep -A 5 "alloc_image" debug.log
```

**Problem**: Size mismatch
```bash
# Enable verbose logging
sed -i '/truenasplugin: tnscale/a\        debug 2' /etc/pve/storage.cfg

# Check unit conversion in logs
journalctl -t truenasplugin | grep "converting"
# Should show: "converting X KiB → Y bytes"
```

### Log Rotation

With debug enabled, configure log rotation:

```bash
# /etc/logrotate.d/truenas-plugin
/var/log/syslog {
    rotate 7
    daily
    maxsize 100M
    compress
    delaycompress
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
```

---

## Production Test Suite

### Overview

The TrueNAS Plugin Test Suite (`truenas-plugin-test-suite.sh`) is a comprehensive automated testing tool that validates all major plugin functionality through the Proxmox API.

**Full documentation**: [Testing Guide](Testing.md)

### Quick Reference

**Location**: `tools/truenas-plugin-test-suite.sh`

**Basic Usage**:
```bash
# Navigate to tools directory
cd tools/

# Run test suite
./truenas-plugin-test-suite.sh your-storage-name

# Run with auto-confirmation
./truenas-plugin-test-suite.sh your-storage-name -y
```

**What It Tests**:
- Storage status and accessibility
- Volume creation and allocation
- Volume listing
- Snapshot operations
- Clone operations
- Volume resize
- VM start/stop operations
- Volume deletion and cleanup

**Requirements**:
- Root access
- Plugin installed and configured
- Active storage configuration
- ~10GB free space on TrueNAS

**Output**:
- Real-time console output with color-coded results
- Detailed log file in `/tmp/truenas-plugin-test-suite-*.log`
- Performance metrics for all operations
- Comprehensive summary report

### Common Commands

```bash
# Test default storage 'tnscale'
cd tools/
./truenas-plugin-test-suite.sh

# Test specific storage
./truenas-plugin-test-suite.sh production-storage

# Automated testing (no prompts)
./truenas-plugin-test-suite.sh production-storage -y

# View most recent test log
ls -lt /tmp/truenas-plugin-test-suite-*.log | head -1
tail -f /tmp/truenas-plugin-test-suite-$(date +%Y%m%d)-*.log
```

### Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

### See Also

Complete test suite documentation: [Testing Guide](Testing.md)

---

## Health Check Tool

### Overview

The health check tool (`health-check.sh`) performs quick validation of the plugin installation and storage health. It's designed for monitoring integration and troubleshooting.

**Location**: `tools/health-check.sh`

### Features

- **12 Comprehensive Checks** - Validates all critical components
- **Multiple Output Modes** - Normal, quiet, and JSON output
- **Monitoring Integration** - Standard exit codes for alerting systems
- **Orphan Detection** - Integrates with cleanup tool to detect issues
- **Color-coded Results** - Clear visual status indicators

### Usage

#### Basic Syntax

```bash
./health-check.sh [storage-name] [--quiet] [--json]
```

**Parameters**:
- `storage-name`: Name of TrueNAS storage to check
- `--quiet`: Minimal output (summary only)
- `--json`: JSON output for monitoring tools

**Exit Codes**:
- `0` - All checks passed (HEALTHY)
- `1` - Warnings detected (WARNING)
- `2` - Critical errors detected (CRITICAL)

#### Examples

**Normal Mode (Detailed)**:
```bash
cd tools/
./health-check.sh truenas-storage

# Output:
# === TrueNAS Plugin Health Check ===
# Storage: truenas-storage
#
# ✓ Plugin file: Installed v1.0.0
# ✓ Storage configuration: Configured
# ✓ Storage status: Active (264% free)
# ✓ Content type: images
# ✓ TrueNAS API: Reachable on 10.15.14.172:443
# ✓ Dataset: pve_test/pve-storage
# ✓ Target IQN: iqn.2005-10.org.freenas.ctl:proxmox
# ✓ Discovery portal: 10.15.14.172:3260
# ✓ iSCSI sessions: 1 active session(s)
# ⊘ Multipath: Not enabled
# ✓ Orphaned resources: No orphans found
# ✓ PVE daemon: Running
#
# === Health Summary ===
# Checks passed: 11/12
# Warnings: 0
# Errors: 0
# Status: HEALTHY
```

**Quiet Mode (Summary Only)**:
```bash
cd tools/
./health-check.sh truenas-storage --quiet

# Output:
# === Health Summary ===
# Checks passed: 11/12
# Status: HEALTHY
```

**JSON Mode (Monitoring)**:
```bash
cd tools/
./health-check.sh truenas-storage --json

# Output:
# {
#   "storage": "truenas-storage",
#   "status": "HEALTHY",
#   "checks": [
#     {"check": "Plugin file", "status": "OK", "message": "Installed v1.0.0"},
#     {"check": "Storage configuration", "status": "OK", "message": "Configured"},
#     ...
#   ],
#   "errors": 0,
#   "warnings": 0,
#   "passed": 11,
#   "total": 12
# }
```

### Health Checks Performed

The tool performs these 12 checks:

1. **Plugin File** - Verifies plugin is installed and detects version
2. **Storage Configuration** - Checks `/etc/pve/storage.cfg` has storage entry
3. **Storage Status** - Validates storage is active and reports free space
4. **Content Type** - Ensures content type is set to "images"
5. **TrueNAS API** - Tests API reachability and authentication
6. **Dataset** - Verifies dataset is configured
7. **Target IQN** - Validates iSCSI target IQN is set
8. **Discovery Portal** - Checks discovery portal is configured
9. **iSCSI Sessions** - Counts active iSCSI sessions to TrueNAS
10. **Multipath** - Checks multipath configuration (skip if disabled)
11. **Orphaned Resources** - Scans for orphaned iSCSI resources
12. **PVE Daemon** - Verifies pvedaemon is running

### Output Interpretation

**Status Indicators**:
- `✓` (Green) - Check passed (OK)
- `✗` (Red) - Check failed (CRITICAL)
- `⚠` (Yellow) - Check passed with warning (WARNING)
- `⊘` (Gray) - Check skipped (SKIP)

**Overall Status**:
- `HEALTHY` - All checks passed or skipped
- `WARNING` - One or more warnings detected
- `CRITICAL` - One or more critical errors detected

### When to Run

**Monitoring Integration**:
```bash
# Cron job for hourly health checks
0 * * * * /path/to/tools/health-check.sh truenas-storage --quiet || \
  echo "TrueNAS storage health issue" | mail -s "Storage Alert" admin@example.com
```

**Troubleshooting**:
- Before reporting issues - gather diagnostic info
- After configuration changes - verify everything works
- After network changes - validate connectivity
- After TrueNAS updates - ensure compatibility

**Pre-Operation Validation**:
- Before VM deployments
- Before storage migrations
- Before cluster maintenance
- Before plugin updates

### Monitoring Integration

#### Nagios/Icinga

```bash
#!/bin/bash
# /usr/lib/nagios/plugins/check_truenas_storage.sh
OUTPUT=$(/path/to/tools/health-check.sh truenas-storage --quiet)
EXIT_CODE=$?
echo "$OUTPUT"
exit $EXIT_CODE
```

**Nagios config**:
```
define service {
    service_description     TrueNAS Storage Health
    check_command           check_truenas_storage
    use                     generic-service
}
```

#### Zabbix

```bash
# UserParameter in zabbix_agentd.conf
UserParameter=truenas.health[*],/path/to/tools/health-check.sh $1 --json
```

**Zabbix item**:
- Key: `truenas.health[truenas-storage]`
- Type: Zabbix agent
- Value type: Text

#### Prometheus

```bash
#!/bin/bash
# /var/lib/node_exporter/textfile_collector/truenas_health.prom
OUTPUT=$(/path/to/tools/health-check.sh truenas-storage --json)
STATUS=$(echo "$OUTPUT" | jq -r '.status')
PASSED=$(echo "$OUTPUT" | jq -r '.passed')
TOTAL=$(echo "$OUTPUT" | jq -r '.total')

cat <<EOF > /var/lib/node_exporter/textfile_collector/truenas_health.prom
# HELP truenas_health_status TrueNAS storage health status (0=healthy, 1=warning, 2=critical)
# TYPE truenas_health_status gauge
truenas_health_status{storage="truenas-storage"} $([ "$STATUS" = "HEALTHY" ] && echo 0 || [ "$STATUS" = "WARNING" ] && echo 1 || echo 2)

# HELP truenas_health_checks_passed Number of health checks passed
# TYPE truenas_health_checks_passed gauge
truenas_health_checks_passed{storage="truenas-storage"} $PASSED

# HELP truenas_health_checks_total Total number of health checks
# TYPE truenas_health_checks_total gauge
truenas_health_checks_total{storage="truenas-storage"} $TOTAL
EOF
```

### Troubleshooting

**"Error: Storage 'name' not found"**:
- Storage name is incorrect
- Storage is not a TrueNAS plugin storage
- Check: `grep truenasplugin /etc/pve/storage.cfg`

**"Plugin file: Not installed"**:
- Plugin not installed
- Use: `ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- Fix: Run installation or `update-cluster.sh`

**"TrueNAS API: Not reachable"**:
- TrueNAS is offline
- Network connectivity issue
- Firewall blocking port 443
- Check: `ping TRUENAS_IP` and `curl -k https://TRUENAS_IP/api/v2.0/system/info`

**"Storage status: Inactive"**:
- Storage is disabled in Proxmox
- Fix: `pvesm set truenas-storage --disable 0`

**"iSCSI sessions: No active sessions"**:
- iSCSI connection lost
- Discovery portal unreachable
- Check: `iscsiadm -m session`
- Reconnect: `iscsiadm -m discovery -t st -p PORTAL_IP:3260`

**"Orphaned resources: Found X orphans"**:
- Orphaned iSCSI resources detected
- Fix: Run `./cleanup-orphans.sh truenas-storage`

### Best Practices

1. **Schedule Regular Checks**:
   ```bash
   # Hourly health check
   0 * * * * /path/to/tools/health-check.sh truenas-storage --quiet
   ```

2. **Integrate with Monitoring**:
   - Use JSON output for parsing
   - Alert on exit code 2 (CRITICAL)
   - Warn on exit code 1 (WARNING)

3. **Document Baselines**:
   ```bash
   # Capture healthy baseline
   ./health-check.sh truenas-storage > baseline-health.txt
   ```

4. **Run Before Changes**:
   ```bash
   # Pre-change validation
   ./health-check.sh truenas-storage || echo "WARNING: Starting with unhealthy storage"
   ```

5. **Combine with Other Tools**:
   ```bash
   # Comprehensive health check
   ./health-check.sh truenas-storage && \
   ./cleanup-orphans.sh truenas-storage --dry-run
   ```

---

## Cluster Update Script

### Overview

The cluster update script (`update-cluster.sh`) automates deployment of the TrueNAS plugin to all nodes in a Proxmox VE cluster. It copies the plugin file, installs it to the correct location, and restarts required services on each node.

**Location**: `tools/update-cluster.sh`

### Features

- **Automated Deployment** - Install plugin on multiple nodes simultaneously
- **Service Management** - Automatically restarts required Proxmox services
- **Error Handling** - Reports failures per-node
- **Verification** - Confirms successful installation on each node
- **Color-coded Output** - Clear success/failure indicators

### Usage

#### Basic Syntax

```bash
./update-cluster.sh <node1> <node2> <node3> ...
```

**Parameters**:
- `node1 node2 node3 ...` - Hostnames or IP addresses of cluster nodes

**Requirements**:
- SSH access to all cluster nodes (passwordless recommended)
- Plugin file `TrueNASPlugin.pm` in parent directory
- Root access on all nodes

#### Examples

**Deploy to Three-Node Cluster**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3
```

**Deploy to Nodes by IP**:
```bash
cd tools/
./update-cluster.sh 192.168.1.10 192.168.1.11 192.168.1.12
```

**Deploy Using Variable**:
```bash
cd tools/
NODES="pve1 pve2 pve3"
./update-cluster.sh $NODES
```

**Deploy to All Nodes (Dynamic)**:
```bash
cd tools/
# Get all cluster nodes
NODES=$(pvesh get /cluster/status --output-format json | jq -r '.[] | select(.type=="node") | .name')
./update-cluster.sh $NODES
```

### What the Script Does

For each node specified, the script performs these steps:

1. **Display Header** - Shows which node is being updated
2. **Copy Plugin File** - SCPs `TrueNASPlugin.pm` to node
3. **Install Plugin** - Moves file to `/usr/share/perl5/PVE/Storage/Custom/`
4. **Set Permissions** - Ensures correct file permissions (644)
5. **Restart Services** - Restarts `pvedaemon`, `pveproxy`, and `pvestatd`
6. **Report Status** - Shows success or failure for the node

### Script Output

**Successful Deployment**:
```
=== Updating Node: pve1 ===
Copying plugin to pve1...
Installing plugin on pve1...
Restarting services on pve1...
✓ Successfully updated pve1

=== Updating Node: pve2 ===
Copying plugin to pve2...
Installing plugin on pve2...
Restarting services on pve2...
✓ Successfully updated pve2

=== Updating Node: pve3 ===
Copying plugin to pve3...
Installing plugin on pve3...
Restarting services on pve3...
✓ Successfully updated pve3

All nodes updated successfully!
```

**Failure Example**:
```
=== Updating Node: pve2 ===
Copying plugin to pve2...
Error: Failed to update pve2
```

### Prerequisites

#### 1. SSH Access

Set up passwordless SSH to all cluster nodes:

```bash
# Generate SSH key (if not already done)
ssh-keygen -t ed25519 -C "proxmox-admin"

# Copy key to each cluster node
ssh-copy-id root@pve1
ssh-copy-id root@pve2
ssh-copy-id root@pve3

# Test passwordless access
ssh root@pve1 "hostname"
ssh root@pve2 "hostname"
ssh root@pve3 "hostname"
```

#### 2. Plugin File Location

The script expects `TrueNASPlugin.pm` in the parent directory:

```
truenasplugin/
├── TrueNASPlugin.pm          # Plugin file here
└── tools/
    └── update-cluster.sh      # Script here
```

**Verify**:
```bash
cd tools/
ls -la ../TrueNASPlugin.pm
```

### Advanced Usage

#### Deploy and Verify

```bash
#!/bin/bash
# deploy-and-verify.sh

cd tools/

# Deploy to all nodes
./update-cluster.sh pve1 pve2 pve3

# Verify installation on each node
for node in pve1 pve2 pve3; do
    echo "=== Verifying $node ==="
    ssh root@$node "ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "pvesm status | grep truenas"
done
```

#### Deploy Specific Version

```bash
#!/bin/bash
# deploy-version.sh

VERSION="$1"
NODES="pve1 pve2 pve3"

# Backup current version
for node in $NODES; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup-$(date +%Y%m%d)"
done

# Deploy new version
cd tools/
./update-cluster.sh $NODES

# Verify version (if version string in plugin)
for node in $NODES; do
    ssh root@$node "grep -i version /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm | head -1"
done
```

#### Rollback on Failure

```bash
#!/bin/bash
# deploy-with-rollback.sh

NODES="pve1 pve2 pve3"

# Backup on all nodes first
echo "Creating backups..."
for node in $NODES; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup"
done

# Deploy
cd tools/
if ./update-cluster.sh $NODES; then
    echo "Deployment successful"
else
    echo "Deployment failed, rolling back..."
    for node in $NODES; do
        ssh root@$node "cp /root/TrueNASPlugin.pm.backup \
                           /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
        ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
    done
fi
```

### Troubleshooting

#### SSH Connection Fails

**Problem**: Cannot connect to node
```
Error: Failed to update pve2
```

**Solutions**:
```bash
# Test SSH connection
ssh root@pve2 "echo OK"

# Check SSH key
ssh-copy-id root@pve2

# Verify hostname resolution
ping -c 1 pve2

# Try IP address instead
./update-cluster.sh 192.168.1.11
```

#### Plugin File Not Found

**Problem**: `TrueNASPlugin.pm` not found

**Solutions**:
```bash
# Check current directory
pwd
# Should be: /path/to/truenasplugin/tools

# Check parent directory for plugin
ls -la ../TrueNASPlugin.pm

# If in wrong location, cd to correct location
cd /path/to/truenasplugin/tools
```

#### Permission Denied

**Problem**: Cannot write to `/usr/share/perl5/PVE/Storage/Custom/`

**Solutions**:
```bash
# Ensure using root SSH access
ssh root@pve1 "whoami"
# Should output: root

# Check directory permissions on node
ssh root@pve1 "ls -ld /usr/share/perl5/PVE/Storage/Custom/"

# Create directory if missing
ssh root@pve1 "mkdir -p /usr/share/perl5/PVE/Storage/Custom/"
```

#### Service Restart Fails

**Problem**: Services fail to restart

**Solutions**:
```bash
# Check service status on node
ssh root@pve1 "systemctl status pvedaemon"

# Check for configuration errors
ssh root@pve1 "journalctl -u pvedaemon -n 50"

# Manual restart
ssh root@pve1 "systemctl restart pvedaemon pveproxy pvestatd"
```

### Script Source Code

**Location**: `tools/update-cluster.sh`

**View Source**:
```bash
cat tools/update-cluster.sh
```

**Key Features**:
- Simple bash script, easy to customize
- Uses standard tools: `scp`, `ssh`
- Color-coded output for clarity
- Error handling with exit codes

### Integration with CI/CD

#### GitLab CI Example

```yaml
# .gitlab-ci.yml
deploy-to-cluster:
  stage: deploy
  script:
    - cd tools/
    - ./update-cluster.sh pve1 pve2 pve3
    - ./truenas-plugin-test-suite.sh production-storage -y
  only:
    - main
```

#### Jenkins Pipeline Example

```groovy
// Jenkinsfile
pipeline {
    agent any
    stages {
        stage('Deploy to Cluster') {
            steps {
                sh 'cd tools && ./update-cluster.sh pve1 pve2 pve3'
            }
        }
        stage('Test Plugin') {
            steps {
                sh 'cd tools && ./truenas-plugin-test-suite.sh production-storage -y'
            }
        }
    }
}
```

### Manual Alternative

If you prefer not to use the script, deploy manually:

```bash
# For each node
for node in pve1 pve2 pve3; do
    scp TrueNASPlugin.pm root@$node:/usr/share/perl5/PVE/Storage/Custom/
    ssh root@$node "chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
done
```

### Best Practices

#### Before Deployment

1. **Test on One Node First**:
   ```bash
   # Deploy to single node for testing
   ./update-cluster.sh pve1

   # Verify it works
   ssh root@pve1 "pvesm status | grep truenas"

   # Then deploy to all nodes
   ./update-cluster.sh pve2 pve3
   ```

2. **Backup Current Version**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                           /root/TrueNASPlugin.pm.$(date +%Y%m%d)"
   done
   ```

3. **Check Cluster Health**:
   ```bash
   pvecm status
   ```

#### During Deployment

1. **Monitor Output**: Watch for errors during deployment
2. **One Node at a Time**: For critical systems, deploy sequentially
3. **Verify Each Node**: Check storage status after deployment

#### After Deployment

1. **Verify Installation**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "pvesm status | grep truenas"
   done
   ```

2. **Check Service Status**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "systemctl status pvedaemon pveproxy"
   done
   ```

3. **Test Storage Operations**:
   ```bash
   # Run test suite
   cd tools/
   ./truenas-plugin-test-suite.sh production-storage -y
   ```

4. **Monitor Logs**:
   ```bash
   for node in pve1 pve2 pve3; do
       ssh root@$node "journalctl -u pvedaemon -f" &
   done
   # Ctrl+C to stop monitoring
   ```

### Maintenance Workflows

#### Regular Update Workflow

```bash
# 1. Pull latest plugin version
git pull origin main

# 2. Create backup
for node in pve1 pve2 pve3; do
    ssh root@$node "cp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm \
                        /root/TrueNASPlugin.pm.backup"
done

# 3. Deploy to cluster
cd tools/
./update-cluster.sh pve1 pve2 pve3

# 4. Run tests
./truenas-plugin-test-suite.sh production-storage -y

# 5. Verify on all nodes
for node in pve1 pve2 pve3; do
    ssh root@$node "pvesm status | grep truenas"
done
```

#### Emergency Rollback

```bash
# Rollback to backup on all nodes
for node in pve1 pve2 pve3; do
    echo "Rolling back $node"
    ssh root@$node "cp /root/TrueNASPlugin.pm.backup \
                        /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    ssh root@$node "systemctl restart pvedaemon pveproxy pvestatd"
done
```

## Summary

### Quick Reference Table

| Tool | Purpose | Location | Documentation |
|------|---------|----------|---------------|
| Test Suite | Automated testing and validation | `tools/truenas-plugin-test-suite.sh` | [Testing Guide](Testing.md) |
| Health Check | Quick health validation for monitoring | `tools/health-check.sh` | This page |
| Cluster Update | Deploy plugin to cluster nodes | `tools/update-cluster.sh` | This page |
| Version Check | Check plugin version across cluster | `tools/check-version.sh` | This page |
| Orphan Cleanup | Find and remove orphaned iSCSI resources | `tools/cleanup-orphans.sh` | This page |

---

## Orphan Cleanup Tool

### Overview

The orphan cleanup tool (`cleanup-orphans.sh`) detects and removes orphaned iSCSI resources on TrueNAS that result from failed operations or interrupted workflows.

**Location**: `tools/cleanup-orphans.sh`

### What Are Orphaned Resources?

Orphaned resources occur when storage operations fail partway through:

1. **Orphaned Extents** - iSCSI extents pointing to deleted/missing zvols
2. **Orphaned Target-Extent Mappings** - Mappings referencing deleted extents
3. **Orphaned Zvols** - Zvols without corresponding iSCSI extents

**Common Causes**:
- VM deletion failures
- Network interruptions during volume creation
- Manual cleanup on TrueNAS without updating Proxmox
- Power failures during operations

### Usage

#### Basic Syntax
```bash
./cleanup-orphans.sh [storage-name] [--force] [--dry-run]
```

**Parameters**:
- `storage-name`: Name of TrueNAS storage to scan
- `--force`: Skip confirmation prompt
- `--dry-run`: Show what would be deleted without deleting

#### Examples

**List Available Storages**:
```bash
cd tools/
./cleanup-orphans.sh

# Output:
# === Available TrueNAS Storage ====
# truenas-storage
# truenas-backup
```

**Detect Orphans (Interactive)**:
```bash
cd tools/
./cleanup-orphans.sh truenas-storage

# Output:
# === TrueNAS Orphan Resource Detection ===
# Storage: truenas-storage
#
# Fetching iSCSI extents...
# Fetching zvols...
# Fetching target-extent mappings...
#
# === Analyzing Resources ===
# Checking for extents without zvols...
# Checking for target-extent mappings without extents...
# Checking for zvols without extents...
#
# Found 3 orphaned resource(s):
#
#   [EXTENT] vm-999-disk-0 (ID: 42)
#            Reason: zvol missing: tank/proxmox/vm-999-disk-0
#   [TARGET-EXTENT] mapping-15 (ID: 15)
#                   Reason: extent missing: 40 (target: 2)
#   [ZVOL] vm-998-disk-1
#          Reason: no extent pointing to this zvol
#
# WARNING: This will permanently delete these orphaned resources!
#
# Delete these orphaned resources? (yes/N):
```

**Dry Run (Preview Only)**:
```bash
cd tools/
./cleanup-orphans.sh truenas-storage --dry-run

# Shows what would be deleted without making changes
# Dry run complete. No resources were deleted.
```

**Automated Cleanup (No Prompt)**:
```bash
cd tools/
./cleanup-orphans.sh truenas-storage --force

# Deletes all orphaned resources without confirmation
```

### Output Interpretation

**Resource Types**:
- `[EXTENT]` - Orphaned iSCSI extent
- `[TARGET-EXTENT]` - Orphaned target-extent mapping
- `[ZVOL]` - Orphaned zvol dataset

**Status Messages**:
- `✓ Deleted` - Resource successfully removed
- `✗ Failed to delete` - Error during deletion (check permissions/API)

### Safety Features

1. **Interactive Confirmation** - Prompts before deletion (unless `--force`)
2. **Dry Run Mode** - Preview changes without modifying anything
3. **Dataset Isolation** - Only scans resources under configured dataset
4. **Ordered Deletion** - Removes dependencies first (mappings → extents → zvols)
5. **Error Logging** - Failed deletions are reported but don't stop cleanup

### When to Run

**Regular Maintenance**:
```bash
# Monthly check for orphans
0 0 1 * * /path/to/tools/cleanup-orphans.sh truenas-storage --force
```

**After Issues**:
- After failed VM deletions
- After network interruptions during storage operations
- After manual cleanup on TrueNAS
- When storage space doesn't match expectations

**Before Major Operations**:
- Before storage migrations
- Before cluster maintenance
- Before TrueNAS upgrades

### Troubleshooting

**"Error: Storage 'name' not found"**:
- Storage name is incorrect
- Storage is not a TrueNAS plugin storage
- Check: `grep truenasplugin /etc/pve/storage.cfg`

**"Error: Failed to fetch extents from TrueNAS API"**:
- TrueNAS is offline or unreachable
- API key is invalid or expired
- Check: `curl -k -H "Authorization: Bearer YOUR_KEY" https://TRUENAS_IP/api/v2.0/system/info`

**"Failed to cleanup orphaned extent"**:
- API key lacks permissions
- Resource is in use (shouldn't happen for true orphans)
- Check TrueNAS logs: System Settings → Shell → `tail -f /var/log/middlewared.log`

**No Orphans Found But Space Is Missing**:
- Snapshots may be consuming space (not considered orphans)
- Check snapshots: TrueNAS → Datasets → [dataset] → Snapshots
- Use: `zfs list -t snapshot -o name,used tank/proxmox`

### Best Practices

1. **Run with --dry-run first** - Always preview before deleting
2. **Schedule regular scans** - Monthly maintenance prevents accumulation
3. **Run after incidents** - Clean up after failed operations
4. **Backup before cleanup** - Snapshot TrueNAS pool before major cleanup
5. **Check logs** - Review syslog for cleanup results

**Example Maintenance Script**:
```bash
#!/bin/bash
# Monthly orphan cleanup with notification
cd /path/to/tools/
STORAGE="truenas-storage"

# Dry run to detect
ORPHANS=$(./cleanup-orphans.sh "$STORAGE" --dry-run | grep -c "Found.*orphaned")

if [ "$ORPHANS" -gt 0 ]; then
    echo "Found $ORPHANS orphaned resources on $STORAGE" | \
      mail -s "TrueNAS Orphan Alert" admin@example.com

    # Cleanup
    ./cleanup-orphans.sh "$STORAGE" --force
fi
```

---

## Version Check Script

### Overview

The version check script (`check-version.sh`) verifies plugin installation and version across cluster nodes.

**Location**: `tools/check-version.sh`

### Usage

#### Basic Syntax
```bash
./check-version.sh [node1] [node2] [node3] ...
```

**Parameters**:
- No arguments: Check local installation only
- `node1 node2 ...`: Check specified cluster nodes via SSH

#### Examples

**Check Local Installation**:
```bash
cd tools/
./check-version.sh

# Output:
# TrueNAS Plugin Version Check
# ============================
#
# Local: '1.0.0'
```

**Check Cluster Nodes**:
```bash
cd tools/
./check-version.sh pve1 pve2 pve3

# Output:
# TrueNAS Plugin Version Check
# ============================
#
# Local: '1.0.0'
#
# pve1: '1.0.0'
# pve2: '1.0.0'
# pve3: '0.9.5'  # Outdated!
```

### Output Interpretation

- **Green**: Plugin installed, version displayed
- **Yellow**: Plugin not installed or version not found
- **Cyan**: Section headers

### Troubleshooting

**"Plugin not installed"**:
- Plugin file missing from `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- Use `update-cluster.sh` to install

**"Version string not found"**:
- Plugin file exists but doesn't contain version marker
- Manually check: `grep 'our $VERSION' /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`

**SSH Connection Failed**:
- Ensure SSH access configured: `ssh root@node1 "hostname"`
- Set up passwordless SSH: `ssh-copy-id root@node1`

### Integration

**Pre-Deployment Verification**:
```bash
# Before update, check current versions
./check-version.sh pve1 pve2 pve3 > versions-before.txt

# Deploy update
./update-cluster.sh pve1 pve2 pve3

# Verify update successful
./check-version.sh pve1 pve2 pve3 > versions-after.txt

# Compare
diff versions-before.txt versions-after.txt
```

**Monitoring Script**:
```bash
#!/bin/bash
# Daily version verification
NODES="pve1 pve2 pve3"
./check-version.sh $NODES | grep -q "Plugin not installed" && \
  echo "WARNING: Plugin missing on one or more nodes" | mail -s "PVE Plugin Alert" admin@example.com
```

---

### Common Tasks

**Check Plugin Version**:
```bash
cd tools/
./check-version.sh pve1 pve2 pve3
```

**Test Plugin Installation**:
```bash
cd tools/
./truenas-plugin-test-suite.sh your-storage-name -y
```

**Deploy to Cluster**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3
```

**Deploy and Test**:
```bash
cd tools/
./update-cluster.sh pve1 pve2 pve3 && \
./truenas-plugin-test-suite.sh production-storage -y
```

## See Also

- [Installation Guide](Installation.md) - Initial plugin installation
- [Testing Guide](Testing.md) - Complete test suite documentation
- [Configuration Reference](Configuration.md) - Storage configuration
- [Troubleshooting Guide](Troubleshooting.md) - Common issues
