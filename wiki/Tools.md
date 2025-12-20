# Tools and Utilities

Documentation for included tools and utilities to help manage the TrueNAS Proxmox VE Storage Plugin.

## Overview

The plugin includes several tools to simplify installation, testing, cluster management, and maintenance:

**Integrated Features** (via `install.sh` Diagnostics Menu):
- **[Integrated Plugin Test](#integrated-plugin-test)** - Quick function validation via installer
- **[FIO Storage Benchmark](#fio-storage-benchmark)** - Comprehensive I/O performance testing (30 tests)
- **[Health Check Tool](#health-check-tool)** - Quick health validation for monitoring
- **[Orphan Cleanup](#orphan-cleanup)** - Find and remove orphaned iSCSI resources

**Standalone Tools**:
- **[Development Test Suite](#development-test-suite)** - **Development/testing only** - Comprehensive plugin testing
- **[Debug Logging System](#debug-logging-system)** - Diagnostic logging for troubleshooting

**Note**: Cluster-wide updates and version checking are now integrated into the installer menu. Standalone scripts for these functions have been removed in favor of the interactive installer.

## Tools Directory Structure

```
tools/
└── dev-truenas-plugin-full-function-test.sh  # Development test suite (⚠️ DEV ONLY)
```

**Note**: Most tools are now integrated into the interactive installer (`install.sh`). The standalone development test suite remains for development purposes only.

Note: Health check, orphan cleanup, and plugin function testing are now integrated directly into the `install.sh` installer script via the Diagnostics menu.

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

# Specify storage and starting VMID
./dev-truenas-plugin-full-function-test.sh tnscale 9001

# Include backup tests (requires backup storage)
./dev-truenas-plugin-full-function-test.sh tnscale 9001 --backup-store pbs

# View results
tail -f test-results-*.log
```

**Command-line Arguments**:
- `STORAGE_ID` - TrueNAS storage ID (default: tnscale)
- `VMID_START` - Starting VMID for test VMs (default: 9001)
- `--backup-store STORAGE` - Backup storage for backup tests (optional)

**Examples**:
```bash
# Standalone node (skips cluster tests)
./dev-truenas-plugin-full-function-test.sh tnscale 9001

# Cluster environment with backup storage
./dev-truenas-plugin-full-function-test.sh tnscale 9001 --backup-store pbs

# Different VMID range
./dev-truenas-plugin-full-function-test.sh tnscale 8000 --backup-store local
```

**Cluster Detection**:
- Script automatically detects if running in a cluster
- If cluster detected with available nodes: runs migration and cross-node clone tests
- If standalone node: automatically skips cluster-only tests

**Backup Tests**:
- Requires `--backup-store` flag
- If not specified: automatically skips backup tests
- Tests both online (running VM) and offline (stopped VM) backups

### Test Phases

The Development Test Suite performs comprehensive testing across 16 test phases:

#### Phase 1-9: Core Plugin Functionality

1. **Pre-flight Cleanup** - Remove orphaned resources from previous test runs
2. **Disk Allocation** - Test disk creation with multiple sizes (1GB, 10GB, 32GB, 100GB)
3. **TrueNAS Size Verification** - Verify disk sizes match on TrueNAS backend via API
4. **Disk Deletion** - Test VM and disk deletion with cleanup verification
5. **Clone & Snapshot** - Test VM cloning, snapshots, and deletion
6. **Disk Resize** - Test expanding disk from 10GB to 20GB
7. **Concurrent Operations** - Test parallel disk allocations and deletions
8. **Performance Benchmarks** - Benchmark disk allocation and deletion timing
9. **Multiple Disks** - Test VMs with multiple disk attachments

#### Phase 10: EFI Boot Support

10. **EFI VM Creation** - Test VM creation with EFI BIOS and EFI disk configuration

**Verifies**:
- VM created with EFI BIOS (OVMF)
- EFI disk allocated and configured
- Data disk attached successfully
- VM configuration contains correct EFI settings

#### Phase 11-12: Live Migration (Cluster Only)

11. **Live Migration** - Test online VM migration between cluster nodes
12. **Offline Migration** - Test offline VM migration between cluster nodes

**Verifies**:
- VM successfully migrates to target node
- VM data remains intact
- Migration back to original node works
- Storage remains accessible on both nodes

**Requirements**:
- Proxmox cluster with multiple nodes
- All nodes must have access to TrueNAS storage
- Auto-skipped on standalone nodes

#### Phase 13-14: Backup Operations (Optional)

13. **Online Backup** - Test backup of running VM
14. **Offline Backup** - Test backup of stopped VM

**Verifies**:
- Backup completes successfully
- Backup file is created in backup storage
- Backup cleanup removes files properly

**Requirements**:
- Backup storage specified via `--backup-store` flag
- Auto-skipped if backup storage not provided

#### Phase 15-16: Cross-Node Cloning (Cluster Only)

15. **Cross-Node Clone (Online)** - Test cloning running VM to different node
16. **Cross-Node Clone (Offline)** - Test cloning stopped VM to different node

**Verifies**:
- VM successfully cloned to target node
- Clone has independent disks
- Both VMs can operate independently
- Cleanup removes both VMs correctly

**Requirements**:
- Proxmox cluster with multiple nodes
- All nodes must have access to TrueNAS storage
- Auto-skipped on standalone nodes

### Performance Summary Table

After all tests complete, the script displays a comprehensive performance summary:

```
════════════════════════════════════════════════════════════════════
  PERFORMANCE SUMMARY
════════════════════════════════════════════════════════════════════

Operation                        Count   Avg (s)   Min (s)   Max (s)
────────────────────────────────────────────────────────────────────
Disk Allocation                      4         3         2         5
Disk Deletion                        8         2         1         3
Clone Operation                      1         8         8         8
Efi Vm Creation                      1         6         6         6
Live Migration                       2        12        11        13
Offline Migration                    2         8         7         9
Online Backup                        1        45        45        45
Offline Backup                       1        32        32        32
Cross Node Clone Online              1        15        15        15
Cross Node Clone Offline             1        12        12        12
```

This table shows:
- **Count**: Number of times operation was performed
- **Avg (s)**: Average duration in seconds
- **Min (s)**: Fastest operation duration
- **Max (s)**: Slowest operation duration

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

- Creates test VMs (VMIDs 9001-9031 by default, expanded for new tests)
- Consumes storage space during tests
- May interfere with existing VMs in VMID range
- Requires API access to TrueNAS
- Not suitable for concurrent execution
- Cluster tests require at least 2 nodes with shared storage access
- Backup tests require backup storage to be configured and accessible

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

All debug output goes to syslog with the `[TrueNAS]` prefix for easy filtering:

```bash
# Best method: Search for [TrueNAS] prefix (works regardless of calling process)
journalctl --since '10 minutes ago' | grep '\[TrueNAS\]'

# Real-time monitoring
journalctl -f | grep '\[TrueNAS\]'

# Count log messages (useful for verifying debug level)
journalctl --since '5 minutes ago' | grep -c '\[TrueNAS\]'
```

**Note**: The syslog identifier varies based on the calling process (`pvesm`, `pvedaemon`, `pvestatd`, etc.), so filtering by the `[TrueNAS]` prefix is more reliable than filtering by syslog tag.

### Debug Level Examples

#### Level 0 (Errors Only - Default)

```
Nov 22 17:01:07 pve-node pvesm[12345]: [TrueNAS] alloc_image pre-flight check failed for VM 100: API unreachable
```

Minimal logging - only critical errors. **Recommended for production.**

#### Level 1 (Light Diagnostic)

```
Nov 22 17:01:07 pve-node pvesm[12345]: [TrueNAS] alloc_image: vmid=100, name=vm-100-disk-0, size=10485760 KiB
Nov 22 17:01:08 pve-node pvesm[12345]: [TrueNAS] Pre-flight: checking target visibility for iqn.2005-10.org.freenas.ctl:proxmox
Nov 22 17:01:09 pve-node pvesm[12345]: [TrueNAS] alloc_image: pre-flight checks passed for 10.00 GB volume
Nov 22 17:01:10 pve-node pvesm[12345]: [TrueNAS] free_image: volname=vm-100-disk-0-lun5
```

Shows function entry/exit and key operations. **Recommended for troubleshooting.**

#### Level 2 (Verbose)

```
Nov 22 17:01:07 pve-node pvesm[12345]: [TrueNAS] alloc_image: vmid=100, size=10485760 KiB
Nov 22 17:01:08 pve-node pvesm[12345]: [TrueNAS] _api_call: method=pool.dataset.create, transport=ws
Nov 22 17:01:08 pve-node pvesm[12345]: [TrueNAS] _api_call: params=[{"name":"tank/proxmox/vm-100-disk-0","type":"VOLUME","volsize":10737418240}]
Nov 22 17:01:09 pve-node pvesm[12345]: [TrueNAS] _api_call: response={"id":"tank/proxmox/vm-100-disk-0"}
Nov 22 17:01:09 pve-node pvesm[12345]: [TrueNAS] _api_call: method=iscsi.extent.create, transport=ws
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
journalctl -f | grep '\[TrueNAS\]' > debug.log &
pvesh create /nodes/$(hostname)/storage/tnscale/content --vmid 100 --filename vm-100-disk-0 --size 10G

# Review logs
grep "alloc_image" debug.log
```

**Problem**: Size mismatch
```bash
# Enable verbose logging
sed -i '/truenasplugin: tnscale/a\        debug 2' /etc/pve/storage.cfg

# Check API call parameters in logs
journalctl --since '5 minutes ago' | grep '\[TrueNAS\].*_api_call'
# Should show: [TrueNAS] _api_call: method=pool.dataset.create with volsize parameter
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

## Integrated Plugin Test

### Overview

The integrated plugin test functionality is built into the interactive installer (`install.sh`) and provides quick validation of core plugin operations. It's designed for production use and performs real operations on test VMs to verify all major plugin functions work correctly.

**Access Method**: Run `bash install.sh`, select "Diagnostics" from the main menu, then choose "Run plugin function test"

### Features

- **8 Core Tests** - Validates all essential plugin operations
- **Interactive Confirmation** - Requires typed "ACCEPT" to proceed
- **Storage Selection** - Choose from configured TrueNAS storages
- **Transport Detection** - Displays transport mode (iSCSI or NVMe/TCP)
- **Cluster Awareness** - Detects cluster for potential migration/clone tests (informational)
- **Health-Check Style Display** - Spinner animations with inline status updates
- **Automatic Cleanup** - Test VMs are removed after completion or on failure
- **Dynamic VM IDs** - Automatically selects available VM IDs (990+)
- **Safe Execution** - Non-destructive to production VMs

### Usage

#### Interactive Method (Recommended)

```bash
bash install.sh
# Select: "Diagnostics" from the main menu
# Select: "Run plugin function test" from the diagnostics menu
# Read the test description and warnings
# Type "ACCEPT" to confirm and proceed
# Select storage to test from the list
# Watch tests execute with real-time status updates
```

#### Test Workflow

1. **Pre-Test Information** - Displays what tests will perform and requirements
2. **Confirmation** - Requires typing "ACCEPT" (in caps) to continue
3. **Storage Selection** - Choose from available TrueNAS plugin storages
4. **Transport Display** - Shows detected transport mode (iSCSI/NVMe/TCP)
5. **Test Execution** - Runs 8 core tests with spinner animations
6. **Summary Report** - Shows passed/failed count and overall result
7. **Automatic Cleanup** - Removes test VMs and volumes

### Tests Performed

The integrated test performs 8 comprehensive tests:

The integrated test performs 8 comprehensive tests with 30-character label formatting for consistent output:

**Test 1: Storage Accessibility** - Validates storage is active and accessible via Proxmox API
- Format: `Storage accessibility         ✓ Storage active and accessible`

**Test 2: Volume Creation** - Creates test VM with 4GB disk
- Allocates disk on TrueNAS storage
- Verifies disk appears in VM configuration
- Format: `Volume creation                ✓ Created 4GB disk successfully`

**Test 3: Volume Listing** - Retrieves volume list and configuration
- Tests storage listing API
- Validates volume appears in storage
- Format: `Volume listing                 ✓ Retrieved volume configuration`

**Test 4: Snapshot Operations** - Creates snapshot and tests clone base
- Creates snapshot of test VM
- Prepares for clone operation
- Format: `Snapshot operations            ✓ Snapshot created and verified`

**Test 5: Clone Operations** - Clones VM from snapshot
- Creates linked clone from snapshot
- Verifies clone independence
- Format: `Clone operations               ✓ Cloned VM from snapshot`

**Test 6: Volume Resize** - Expands disk by +1GB
- Tests grow-only resize capability
- Validates new size
- Format: `Volume resize                  ✓ Expanded disk by 1GB`

**Test 7: VM Start/Stop Lifecycle** - Tests VM state operations
- Starts test VM
- Stops test VM
- Verifies state transitions
- Format: `VM start/stop lifecycle        ✓ VM started and stopped`

**Test 8: Volume Deletion and Cleanup** - Removes test resources
- Deletes test VMs (with --purge)
- Verifies cleanup on TrueNAS backend
- Format: `Volume deletion                ✓ Cleaned up test resources`

### Example Output

```
╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.1.0                        ║
╚══════════════════════════════════════════════════════════╝

Plugin Function Test

This test will perform the following operations:
  • Validate storage accessibility via Proxmox API
  • Create test VMs with dynamic ID selection
  • Test volume creation, snapshots, and clones
  • Test volume resize operations
  • Test VM start/stop lifecycle
  • Cleanup test VMs automatically

Important considerations:
  • Test VMs will be created with IDs automatically selected from available range (990+)
  • Storage must have at least 10GB free space
  • Tests will take approximately 2-5 minutes to complete
  • All test data will be cleaned up after completion
  • Tests are non-destructive to production VMs and data

Type ACCEPT to continue or any other input to return to menu
Confirmation: ACCEPT

Available TrueNAS storage:
  • truenas-iscsi
  • truenas-nvme

Enter storage name to test: truenas-nvme

╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.1.0                        ║
╚══════════════════════════════════════════════════════════╝

Plugin Function Test

Running plugin function test on storage: truenas-nvme

Testing storage: truenas-nvme (transport: nvme-tcp)

Storage accessibility         ✓ Storage active and accessible
Volume creation                ✓ Created 4GB disk successfully
Volume listing                 ✓ Retrieved volume configuration
Snapshot operations            ✓ Snapshot created and verified
Clone operations               ✓ Cloned VM from snapshot
Volume resize                  ✓ Expanded disk by 1GB
VM start/stop lifecycle        ✓ VM started and stopped
Volume deletion                ✓ Cleaned up test resources

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugin Function Test Summary: 8/8 tests passed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Requirements

- **Storage Space** - At least 10GB free on TrueNAS storage
- **VM ID Availability** - Free VM IDs in the 990+ range
- **API Access** - Valid TrueNAS API key and connectivity
- **Plugin Installed** - TrueNAS plugin must be installed and configured
- **Time** - Tests take approximately 2-5 minutes to complete

### When to Run

**After Installation**:
- Verify plugin works correctly after installation
- Validate storage configuration is functional

**After Updates**:
- Confirm plugin update didn't break functionality
- Regression testing after configuration changes

**Troubleshooting**:
- Validate plugin operations when experiencing issues
- Identify which operations fail vs succeed

**Pre-Production**:
- Test new storage before deploying production VMs
- Verify transport mode (iSCSI vs NVMe/TCP) works correctly

### Cluster Detection

If running on a cluster node, the test displays additional information:

```
Cluster detected - additional tests available:
  • VM migration to remote nodes
  • Cross-node VM cloning
```

**Note**: Cluster-specific tests (VM migration and cross-node cloning) are currently informational only and not yet implemented in the integrated test. For cluster testing, use the standalone Development Test Suite.

### Safety Features

1. **Typed Confirmation** - Requires "ACCEPT" (in caps) to proceed
2. **Dynamic VM IDs** - Automatically finds available VM IDs (990+)
3. **Isolated Testing** - Uses dedicated test VM IDs, doesn't affect production
4. **Automatic Cleanup** - Removes all test resources on completion or failure
5. **Non-Destructive** - Only creates/modifies test VMs, never touches production
6. **Failure Handling** - Stops on first failure and cleans up partial resources
7. **Interrupt Handling** - Ctrl+C gracefully stops tests, restores cursor, cleans up resources, and displays user-friendly message

### Troubleshooting

**"No TrueNAS storage configured"**:
- No storage entries found in `/etc/pve/storage.cfg`
- Configure storage first via installer's "Configure storage" menu

**"Storage 'name' not found in configuration"**:
- Typed storage name doesn't match available storages
- Check spelling (case-sensitive)
- List available: `grep truenasplugin /etc/pve/storage.cfg`

**Test fails at "Storage accessibility"**:
- Storage is disabled or misconfigured
- Check: `pvesm status | grep <storage-name>`
- Verify TrueNAS API connectivity

**Test fails at "Volume creation"**:
- Insufficient space on TrueNAS
- Dataset doesn't exist or is inaccessible
- API key lacks permissions

**Test fails at "VM start/stop lifecycle"**:
- VM configuration issue (normal, non-critical for storage testing)
- Storage operations are more important than VM boot capability

### Comparison with Other Test Tools

| Feature | Integrated Test | Production Test Suite | Development Test Suite |
|---------|----------------|----------------------|----------------------|
| **Access** | Via installer menu | Standalone script | Standalone script |
| **Purpose** | Quick validation | Comprehensive testing | Plugin development |
| **Test Count** | 8 core tests | 8 tests + metrics | 16 tests + cluster/backup |
| **Duration** | 2-5 minutes | 5-10 minutes | 10-20 minutes |
| **Confirmation** | Interactive (typed) | Yes (or -y flag) | Yes |
| **Output** | Health-check style (30-char labels) | Detailed console + log | Pastel colors + JSON/CSV |
| **Cleanup** | Automatic | Automatic | Automatic |
| **Cluster Tests** | Planned (not yet) | Planned (not yet) | Yes (migration/clone) |
| **Production Safe** | Yes | Yes | No (dev only) |
| **API Method** | pvesh | pvesh | pvesh |
| **Logging** | Silent (no log file) | Detailed log file | JSON + CSV logs |
| **Interrupt Handling** | Graceful with cleanup | Standard | Standard |

**Recommendation**:
- Use **Integrated Test** for quick validation after installation/updates
- Use **Production Test Suite** for scheduled testing or detailed diagnostics
- Use **Development Test Suite** only in isolated development environments

### Best Practices

1. **Run After Installation** - Validate plugin works before deploying production VMs

2. **Run After Updates** - Regression test after plugin updates or configuration changes

3. **Test Each Storage** - If multiple TrueNAS storages configured, test each one individually

4. **Check Space First** - Ensure adequate free space (10GB+) before running tests

5. **Review Failures** - If tests fail, note which test failed for troubleshooting
   - Test 1-2 failures: Configuration or connectivity issue
   - Test 3-5 failures: Storage backend or API issue
   - Test 6-8 failures: Plugin operation issue

6. **Compare Transports** - Test both iSCSI and NVMe/TCP storages if using both

### See Also

- [FIO Storage Benchmark](#fio-storage-benchmark) - For comprehensive I/O performance testing
- [Production Test Suite](#production-test-suite) - For detailed standalone testing
- [Health Check Tool](#health-check-tool) - For configuration validation
- [Development Test Suite](#development-test-suite) - For plugin development testing

---

## FIO Storage Benchmark

### Overview

The FIO Storage Benchmark suite is built into the interactive installer (`install.sh`) and provides comprehensive I/O performance testing for TrueNAS storage. It performs 30 different tests across multiple queue depths to characterize storage performance under various workload patterns.

**Access Method**: Run `bash install.sh`, select "Diagnostics" from the main menu, then choose "Run FIO storage benchmark"

### Features

- **30 Comprehensive Tests** - Sequential/random read/write bandwidth and IOPS
- **Multiple Queue Depths** - Tests at QD=1, 16, 32, 64, 128 for each workload type
- **Transport-Aware** - Supports both iSCSI and NVMe/TCP modes
- **Automatic Volume Management** - Creates 10GB test volume and cleans up automatically
- **Interactive Confirmation** - Requires typed "ACCEPT" to proceed (prevents accidental execution)
- **Storage Selection** - Choose from configured TrueNAS storages
- **FIO Version Validation** - Checks for FIO 3.0+ with JSON output support
- **Non-Destructive** - Tests are isolated to dedicated test volume
- **SIGINT Handling** - Graceful cleanup on Ctrl+C interruption

### Test Categories

The benchmark suite performs 6 categories of tests, each at 5 different queue depths (1, 16, 32, 64, 128):

1. **Sequential Read Bandwidth** (Tests 1-5)
   - Block size: 1M
   - Measures: MB/s throughput
   - Typical use: Large file reads, streaming

2. **Sequential Write Bandwidth** (Tests 6-10)
   - Block size: 1M
   - Measures: MB/s throughput
   - Typical use: Large file writes, backups

3. **Random Read IOPS** (Tests 11-15)
   - Block size: 4K
   - Measures: IOPS (I/O operations per second)
   - Typical use: Database reads, VM boot

4. **Random Write IOPS** (Tests 16-20)
   - Block size: 4K
   - Measures: IOPS
   - Typical use: Database writes, logging

5. **Mixed Random Workload** (Tests 21-25)
   - Block size: 4K
   - Ratio: 70% read, 30% write
   - Measures: IOPS
   - Typical use: General VM workloads

6. **Latency Tests** (Tests 26-30)
   - Block size: 4K
   - Measures: Average latency (µs)
   - Typical use: Latency-sensitive applications

### Usage

#### Interactive Method

```bash
bash install.sh
# Select: "Diagnostics" from the main menu
# Select: "Run FIO storage benchmark" from the diagnostics menu
# Read the benchmark description and warnings
# Type "ACCEPT" (in caps) to confirm and proceed
# Select storage to benchmark from the list
# Wait 25-30 minutes for all 30 tests to complete
```

#### Benchmark Workflow

1. **Pre-Benchmark Information** - Displays test plan, requirements, and warnings
2. **Confirmation** - Requires typing "ACCEPT" (in caps) to continue
3. **Storage Selection** - Choose from available TrueNAS plugin storages
4. **FIO Installation Check** - Validates FIO 3.0+ is installed with JSON support
5. **Storage Configuration Check** - Validates API connectivity and settings
6. **Test Volume Allocation** - Creates 10GB test volume on storage
7. **Device Activation** - Attaches volume and detects device path
8. **Benchmark Execution** - Runs 30 tests with progress indicators (25-30 minutes)
9. **Results Summary** - Displays performance metrics for all tests
10. **Automatic Cleanup** - Removes test volume and cleans up resources

### Requirements

**System Requirements**:
- FIO version 3.0 or higher installed (`apt install fio`)
- Root access on Proxmox node
- At least 10GB free space on TrueNAS storage
- 25-30 minutes available for test execution

**Storage Requirements**:
- Active TrueNAS storage configured in Proxmox
- API connectivity to TrueNAS
- Available VM ID in range 990-1090 for test volume allocation

### Example Output

```
╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.1.0                        ║
╚══════════════════════════════════════════════════════════╝

FIO Storage Benchmark Suite

This benchmark will perform the following operations:
  • Allocate a 10GB test volume directly on storage
  • Run 30 comprehensive I/O tests at multiple queue depths
  • Test sequential/random read/write bandwidth and IOPS
  • Test latency and mixed workload performance
  • Automatically cleanup test volume after completion

Important considerations:
  • Storage must have at least 10GB free space
  • Benchmarks will run for 25-30 minutes total (30 tests)
  • Each test type runs at 5 queue depths (QD=1, 16, 32, 64, 128)
  • Tests will generate heavy I/O load on the storage system
  • FIO must be installed on this system (will prompt if missing)
  • All test data will be cleaned up after completion
  • Benchmarks are non-destructive to production data

Type ACCEPT to continue or any other input to return to menu
Confirmation: ACCEPT

Available TrueNAS storage:
  • truenas-iscsi
  • truenas-nvme

Enter storage name to benchmark: truenas-nvme

╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.1.0                        ║
╚══════════════════════════════════════════════════════════╝

FIO Storage Benchmark

Running benchmark on storage: truenas-nvme

FIO installation:               ✓ fio-3.16
Storage configuration:          ✓ Valid (nvme-tcp mode)
Finding available VM ID:        ✓ Using VM ID 990
Allocating 10GB test volume:    ✓ Volume allocated
Device activation:              ✓ Device ready at /dev/nvme0n1

Transport mode: nvme-tcp (testing QD=1, 16, 32, 64, 128)

Sequential Read Bandwidth Tests: [1-5/30]
Queue Depth = 1:                ✓ 1,234 MB/s
Queue Depth = 16:               ✓ 3,456 MB/s
Queue Depth = 32:               ✓ 4,567 MB/s
Queue Depth = 64:               ✓ 5,123 MB/s
Queue Depth = 128:              ✓ 5,234 MB/s

Sequential Write Bandwidth Tests: [6-10/30]
Queue Depth = 1:                ✓ 987 MB/s
Queue Depth = 16:               ✓ 2,345 MB/s
Queue Depth = 32:               ✓ 3,456 MB/s
Queue Depth = 64:               ✓ 4,123 MB/s
Queue Depth = 128:              ✓ 4,234 MB/s

Random Read IOPS Tests: [11-15/30]
Queue Depth = 1:                ✓ 12,345 IOPS
Queue Depth = 16:               ✓ 98,765 IOPS
Queue Depth = 32:               ✓ 145,678 IOPS
Queue Depth = 64:               ✓ 198,765 IOPS
Queue Depth = 128:              ✓ 234,567 IOPS

Random Write IOPS Tests: [16-20/30]
Queue Depth = 1:                ✓ 8,765 IOPS
Queue Depth = 16:               ✓ 67,890 IOPS
Queue Depth = 32:               ✓ 98,765 IOPS
Queue Depth = 64:               ✓ 134,567 IOPS
Queue Depth = 128:              ✓ 167,890 IOPS

Mixed Random Workload Tests: [21-25/30]
Queue Depth = 1:                ✓ 10,234 IOPS
Queue Depth = 16:               ✓ 78,901 IOPS
Queue Depth = 32:               ✓ 112,345 IOPS
Queue Depth = 64:               ✓ 156,789 IOPS
Queue Depth = 128:              ✓ 189,012 IOPS

Latency Tests: [26-30/30]
Queue Depth = 1:                ✓ 81 µs
Queue Depth = 16:               ✓ 163 µs
Queue Depth = 32:               ✓ 227 µs
Queue Depth = 64:               ✓ 323 µs
Queue Depth = 128:              ✓ 547 µs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FIO Benchmark Complete: 30/30 tests completed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Cleaning up test volume...
Cleanup complete
```

### Understanding Results

**Sequential Bandwidth (MB/s)**:
- Higher values indicate better throughput for large files
- QD=1 shows single-thread performance
- Higher QD shows parallel I/O capability
- NVMe typically: 1,000-6,000 MB/s
- iSCSI typically: 500-2,000 MB/s (network limited)

**Random IOPS**:
- Higher values indicate better small I/O performance
- Critical for VMs, databases, and random access workloads
- QD=1 shows low-latency performance
- Higher QD shows sustained parallel load capability
- NVMe typically: 50,000-300,000 IOPS
- iSCSI typically: 10,000-100,000 IOPS

**Latency (µs)**:
- Lower values are better
- Sub-100µs is excellent for interactive workloads
- 100-500µs is good for most VM workloads
- >1000µs may indicate bottlenecks

**Mixed Workload**:
- Simulates real-world VM behavior (70% read, 30% write)
- Best indicator of general VM performance

### Best Practices

1. **Run During Maintenance Windows** - Tests generate heavy I/O load
2. **Test Both Transport Modes** - Compare iSCSI vs NVMe/TCP if available
3. **Establish Baselines** - Run benchmarks after initial setup for comparison
4. **Monitor Trends** - Re-run periodically to detect degradation
5. **Document Results** - Keep benchmark logs for capacity planning
6. **Test Network Impact** - Run from multiple nodes if in cluster
7. **Correlate with Backend** - Check TrueNAS metrics during tests

### Troubleshooting

**FIO Not Installed**:
```bash
apt update && apt install fio -y
```

**FIO Version Too Old** (< 3.0):
```bash
apt update && apt upgrade fio -y
```

**Benchmark Interrupted**:
- Press Ctrl+C to gracefully stop and cleanup
- Test volume will be automatically removed
- Re-run from Diagnostics menu to restart

**Low Performance Results**:
- Check TrueNAS system load and disk utilization
- Verify network throughput (iSCSI) or NVMe/TCP connectivity
- Check for multipath configuration issues
- Review TrueNAS ZFS pool health and fragmentation
- Ensure no other heavy I/O operations running

**Device Not Found**:
- Verify volume allocation succeeded
- Check iSCSI/NVMe/TCP session connectivity
- Ensure proper multipath configuration
- Review system logs: `journalctl -xe`

### Performance Comparison

Use the benchmark to compare:

1. **Transport Modes** - iSCSI vs NVMe/TCP performance characteristics
2. **Network Configurations** - Single vs multipath, 1GbE vs 10GbE vs 25GbE
3. **TrueNAS Tuning** - Before/after ZFS tuning or SSD upgrades
4. **Backend Storage** - HDD pools vs SSD pools vs NVMe pools
5. **Cluster Nodes** - Performance variation across cluster members

### See Also

- [Integrated Plugin Test](#integrated-plugin-test) - For functional validation
- [Health Check Tool](#health-check-tool) - For configuration validation
- [Testing Guide](Testing.md) - For complete testing documentation

---

## Production Test Suite

> **DEPRECATED**: This standalone script has been removed. Use the integrated **Plugin Function Test** feature via `install.sh` > Diagnostics > Run plugin function test instead.

### Overview

The plugin function test feature (integrated in the installer) validates all major plugin functionality through the Proxmox API.

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

The health check functionality is now integrated into the interactive installer (`install.sh`). It performs comprehensive validation of the plugin installation and storage health, supporting both iSCSI and NVMe/TCP transport modes.

**Access Method**: Run `bash install.sh`, select "Diagnostics" from the main menu, then choose "Run health check"

### Features

- **13 Comprehensive Checks** - Validates all critical components
- **Transport-Aware** - Adapts checks based on iSCSI or NVMe/TCP mode
- **Color-coded Results** - Clear visual status indicators
- **Exit Codes** - Standard return codes (0=healthy, 1=warning, 2=critical)
- **Multi-storage Support** - Can check any configured TrueNAS storage

### Usage

#### Interactive Method (Recommended)

```bash
bash install.sh
# Select: "Diagnostics" from the main menu
# Select: "Run health check" from the diagnostics menu
# Choose storage to check from the list
```

#### Example Output

```
╔══════════════════════════════════════════════════════════╗
║              TRUENAS PROXMOX VE PLUGIN                   ║
║                  Installer v1.1.0                        ║
╚══════════════════════════════════════════════════════════╝

Health Check

Running health check on storage: tn-nvme

Plugin file:                   ✓ Installed v1.1.3
Storage configuration:         ✓ Configured
Storage status:                ✓ Active (41.35GB / 1708.80GB used, 2.42%)
Content type:                  ✓ images
TrueNAS API:                   ✓ Reachable on 10.15.14.172:443
Dataset:                       ✓ flash/nvme-testing
nvme-cli:                      ✓ Installed
Subsystem NQN:                 ✓ nqn.2011-06.com.truenas:uuid:...:nvme-proxmox
Host NQN:                      ✓ nqn.2014-08.org.nvmexpress:uuid:...
Discovery portal:              ✓ 10.20.30.20:4420
NVMe connections:              ✓ Connected (2 path(s), 2 live)
Native multipath:              ✓ Enabled (kernel)
PVE daemon:                    ✓ Running

Health Summary:
Checks passed: 13/13
Status: HEALTHY
```

### Health Checks Performed

The tool performs up to 13 checks depending on transport mode:

**Common Checks (All Modes)**:
1. **Plugin File** - Verifies plugin is installed and detects version
2. **Storage Configuration** - Checks `/etc/pve/storage.cfg` has storage entry
3. **Storage Status** - Validates storage is active and reports space usage
4. **Content Type** - Ensures content type is set to "images"
5. **TrueNAS API** - Tests API reachability on configured host:port
6. **Dataset** - Verifies dataset is configured
7. **Discovery Portal** - Checks discovery portal is configured
8. **PVE Daemon** - Verifies pvedaemon is running

**iSCSI-Specific Checks**:
9. **Target IQN** - Validates iSCSI target IQN is set
10. **iSCSI Sessions** - Counts active iSCSI sessions to TrueNAS
11. **Multipath** (conditional) - Checks multipath-tools if enabled

**NVMe/TCP-Specific Checks**:
9. **nvme-cli** - Verifies nvme-cli package is installed
10. **Subsystem NQN** - Validates NVMe subsystem NQN is configured
11. **Host NQN** - Checks host NQN (configured or system default)
12. **NVMe Connections** - Counts TCP paths and live connections
13. **Native Multipath** (conditional) - Checks kernel NVMe multipath if multiple portals configured

### Output Interpretation

**Status Indicators**:
- `✓` (Green) - Check passed (OK)
- `✗` (Red) - Check failed (CRITICAL)
- `⚠` (Yellow) - Check passed with warning (WARNING)

**Overall Status**:
- `HEALTHY` - All checks passed
- `WARNING` - One or more warnings detected
- `CRITICAL` - One or more critical errors detected

### When to Run

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

### Programmatic Access

For automation or monitoring integration, you can extract and use the `run_health_check()` function from `install.sh`:

```bash
# Source the installer to access health check function
source install.sh

# Run health check programmatically
run_health_check "truenas-storage"
EXIT_CODE=$?

# Exit codes:
# 0 = HEALTHY
# 1 = WARNING
# 2 = CRITICAL
```

**Note**: The integrated health check does not currently support `--json` or `--quiet` output modes. For monitoring integration requiring these features, you may need to parse the standard output or implement a wrapper script.

### Troubleshooting

**"Storage 'name' not found"**:
- Storage name is incorrect
- Storage is not a TrueNAS plugin storage
- Check: `grep truenasplugin /etc/pve/storage.cfg`

**"Plugin file: Not installed"**:
- Plugin not installed
- Use: `ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- Fix: Run `bash install.sh` and install the plugin

**"TrueNAS API: Not reachable"**:
- TrueNAS is offline
- Network connectivity issue
- Firewall blocking the API port
- Check: `ping TRUENAS_IP` and `curl -k https://TRUENAS_IP/api/v2.0/system/info`

**"Storage status: Inactive"**:
- Storage is disabled in Proxmox
- Fix: `pvesm set truenas-storage --disable 0`

**"iSCSI sessions: No active sessions"** (iSCSI mode):
- iSCSI connection lost
- Discovery portal unreachable
- Check: `iscsiadm -m session`
- Reconnect: `iscsiadm -m discovery -t st -p PORTAL_IP:3260`

**"NVMe connections: Not connected"** (NVMe/TCP mode):
- NVMe subsystem not connected
- Discovery or portal configuration issue
- Check: `nvme list-subsys` and `nvme discover -t tcp -a PORTAL_IP -s 4420`
- Reconnect: See [NVMe Setup Guide](NVMe-Setup.md)

### Best Practices

1. **Run After Installation**:
   - Always run health check after installing or updating the plugin
   - Verify all components are working before deploying VMs

2. **Run After Configuration Changes**:
   - After modifying storage configuration
   - After network changes
   - After TrueNAS updates

3. **Document Results**:
   ```bash
   # Capture health check output for baseline
   bash install.sh # then select health check
   # Save output for comparison
   ```

4. **Check Before Troubleshooting**:
   - Run health check first when experiencing storage issues
   - Helps identify root cause quickly

---

## Cluster Update Script

> **DEPRECATED**: This standalone script has been removed. Use the integrated cluster-wide installation feature via `install.sh` > Install/Update options instead.

### Overview

Cluster-wide deployment is now available natively in the interactive installer. The installer automates deployment of the TrueNAS plugin to all nodes in a Proxmox VE cluster.

**How to Use**: Run `install.sh` and select the cluster-wide installation/update option from the main menu.

**Documentation**: See [Installation Guide - Cluster Installation](Installation.md#cluster-installation-with-installer)

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
| Plugin Function Test | Quick validation of core operations | Integrated in `install.sh` | This page |
| Health Check | Quick health validation for monitoring | Integrated in `install.sh` | This page |
| Cluster Update | Deploy plugin to cluster nodes | Integrated in `install.sh` | This page |
| Orphan Cleanup | Find and remove orphaned iSCSI resources | Integrated in `install.sh` | This page |

---

## Orphan Cleanup

### Overview

The orphan cleanup functionality is now integrated into the interactive installer (`install.sh`). It detects and removes orphaned iSCSI resources on TrueNAS that result from failed operations or interrupted workflows.

**Access Method**: Run `bash install.sh`, select "Diagnostics" from the main menu, then choose "Cleanup orphaned resources"

**Note**: The standalone script has been removed. All orphan cleanup functionality is now available through the installer's Diagnostics menu.

### What Are Orphaned Resources?

Orphaned resources occur when storage operations fail partway through:

1. **Orphaned Extents** - iSCSI extents pointing to deleted/missing zvols
2. **Orphaned Target-Extent Mappings** - Mappings referencing deleted extents
3. **Orphaned Zvols** - Zvols without corresponding iSCSI extents

> **Note**: Orphan detection currently supports **iSCSI transport only**. It does not yet detect orphaned NVMe/TCP namespaces or subsystems. Zvols created for NVMe/TCP will not be scanned or cleaned up by this tool.

**Common Causes**:
- VM deletion failures
- Network interruptions during volume creation
- Manual cleanup on TrueNAS without updating Proxmox
- Power failures during operations

### Usage

#### Interactive Method (Recommended)

```bash
bash install.sh
# Select: "Diagnostics" from the main menu
# Select: "Cleanup orphaned resources" from the diagnostics menu
# Choose storage from the list
# Review detected orphans
# Type "DELETE" (in caps) to confirm cleanup
```

The integrated cleanup will:
1. Scan for orphaned iSCSI resources (extents, zvols, target-extent mappings)
2. Display detailed list with reasons for each orphan
3. Require typed "DELETE" confirmation for safety
4. Delete orphans in safe order (mappings → extents → zvols)
5. Report success/failure for each deletion

**Example Output**:
```
Found 3 orphaned resource(s):

  [EXTENT] vm-999-disk-0 (ID: 42)
           Reason: zvol missing: tank/proxmox/vm-999-disk-0
  [TARGET-EXTENT] mapping-15 (ID: 15)
                  Reason: extent missing: 40 (target: 2)
  [ZVOL] vm-998-disk-1
         Reason: no extent pointing to this zvol

WARNING: This will permanently delete these orphaned resources!

Type "DELETE" to confirm cleanup:
```

#### Using the Integrated Feature

Access orphan cleanup through the installer:

1. Run `bash install.sh`
2. Select **"Diagnostics"** from main menu
3. Choose **"Cleanup orphaned resources"**
4. Select storage to scan
5. Review detected orphans
6. Type **DELETE** to confirm removal

The integrated feature provides the same functionality as the removed standalone script, with an improved interactive interface.

### Output Interpretation

**Resource Types**:
- `[EXTENT]` - Orphaned iSCSI extent
- `[TARGET-EXTENT]` - Orphaned target-extent mapping
- `[ZVOL]` - Orphaned zvol dataset

**Status Messages**:
- `✓ Deleted` - Resource successfully removed
- `✗ Failed to delete` - Error during deletion (check permissions/API)

### Safety Features

1. **Typed Confirmation** - Requires typing "DELETE" (in caps) to proceed
2. **Dataset Isolation** - Only scans resources under configured dataset
3. **Ordered Deletion** - Removes dependencies first (mappings → extents → zvols)
4. **Transport Limitation** - iSCSI only (NVMe/TCP shows unsupported message)
5. **Error Reporting** - Failed deletions are reported but don't stop cleanup
6. **Dry Run Mode** - Available in standalone script for preview without deletion

### When to Run

**After Issues**:
- After failed VM deletions
- After network interruptions during storage operations
- After manual cleanup on TrueNAS
- When storage space doesn't match expectations
- When health check reports orphaned resources

**Before Major Operations**:
- Before storage migrations
- Before cluster maintenance
- Before TrueNAS upgrades

**Regular Maintenance**:
Run orphan cleanup periodically through the installer's Diagnostics menu to maintain clean storage.

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

1. **Run health check first** - Health check will detect orphans and their count
2. **Use interactive cleanup** - The integrated installer version provides clear prompts and safety
3. **Review before confirming** - Carefully check the orphan list before typing "DELETE"
4. **Run after incidents** - Clean up after failed operations or storage issues
5. **Backup before cleanup** - Snapshot TrueNAS pool before major cleanup operations

**Example Automated Maintenance Script** (using standalone script):
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

    # Cleanup (automated)
    ./cleanup-orphans.sh "$STORAGE" --force
fi
```

---

## Version Check Script

> **DEPRECATED**: This standalone script has been removed. Version information is displayed in the installer menu when the plugin is installed.

### Overview

The installer now displays the current plugin version in the main menu. For cluster environments, version consistency is maintained through the cluster-wide update feature.

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
