# Tools and Utilities

Documentation for included tools and utilities to help manage the TrueNAS Proxmox VE Storage Plugin.

## Overview

The plugin includes several tools to simplify installation, testing, cluster management, and maintenance:

**Integrated Features** (via `install.sh` Diagnostics Menu):
- **[Integrated Plugin Test](#integrated-plugin-test)** - Quick function validation via installer
- **[Diagnostics Bundle](#diagnostics-bundle)** - 10-minute strace capture with system diagnostics for troubleshooting
- **[Health Check Tool](#health-check-tool)** - Quick health validation for monitoring
- **[Orphan Cleanup](#orphan-cleanup)** - Find and remove orphaned iSCSI resources

**Standalone Tools**:
- **[Test Harness](#test-harness)** - Primary multi-tier test runner (`run-tests.sh`)
- **[Development Test Suite](#development-test-suite)** - **Development/testing only** - Single-node functional testing
- **[NVMe Recovery](#nvme-recovery)** - NVMe namespace recovery utility
- **[Debug Logging System](#debug-logging-system)** - Diagnostic logging for troubleshooting

**Note**: Cluster-wide updates and version checking are now integrated into the installer menu. Standalone scripts for these functions have been removed in favor of the interactive installer.

## Tools Directory Structure

```
tools/
├── run-tests.sh                              # Primary test harness (5 tiers, hard gates)
├── dev-truenas-plugin-full-function-test.sh   # Legacy dev test suite (⚠️ DEV ONLY)
├── build-deb.sh                               # Build .deb package
├── nvme-recovery.sh                           # NVMe namespace recovery
├── diag-nvme-namespace-publish.sh             # NVMe namespace diagnostics
├── lib/
│   ├── common.sh                              # Shared utilities (logging, API, iptables, parsing)
│   ├── tier1.sh                               # Tier 1: Core functional tests
│   ├── tier2.sh                               # Tier 2: Multipath / ALUA tests
│   ├── tier3.sh                               # Tier 3: Cluster / migration tests
│   ├── tier4.sh                               # Tier 4: HA failover/failback tests
│   ├── tier5.sh                               # Tier 5: ALUA + HA crash failover tests
│   └── ipmi.conf                              # IPMI credentials for Tier 5 (not committed)
├── tests/
│   ├── test_common.sh                         # Unit tests for common.sh
│   └── test_arg_parsing.sh                    # Unit tests for CLI arg handling
└── apt-repo/                                  # APT repository tooling
```

**Note**: Most user-facing tools (health check, orphan cleanup, plugin function testing) are integrated into the `install.sh` installer via the Diagnostics menu. The tools above are for development and testing.

---

## Test Harness

The primary test tool. Runs five hardware tiers with hard gates that block releases.

**Location**: `tools/run-tests.sh`

```bash
# Run all tiers that hardware supports
tools/run-tests.sh --storage <name> --yes

# Run a specific config
tools/run-tests.sh --storage <name> --config G --yes
```

Configs: `A` (single-node iSCSI), `D` (multipath cluster), `F` (NVMe/TCP cluster), `H` (HA failover), `G` (ALUA + HA crash failover), `all`.

See [Test Plan](Test-Plan.md) for the full test case reference, [Test Harness Architecture](Test-Harness-Architecture.md) for internals, and [Config Types](Test-Harness-Config-Types.md) for hardware profiles.

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

- [Production Test Suite](#production-test-suite) - For detailed standalone testing
- [Health Check Tool](#health-check-tool) - For configuration validation
- [Development Test Suite](#development-test-suite) - For plugin development testing

---

## Diagnostics Bundle

### Overview

The Diagnostics Bundle feature is built into the interactive installer (`install.sh`) and captures a comprehensive snapshot of your Proxmox node for troubleshooting WebSocket connection issues, fork-related crashes, and pvestatd problems. It combines a 10-minute strace capture of pvestatd with 13 sections of system and plugin diagnostics.

**Access Method**: Run `bash install.sh`, select "Diagnostics" from the main menu, then choose "Create diagnostics bundle"

**Output**: Single compressed tarball (`truenas-diag-TIMESTAMP.tar.gz`) containing:
- `truenas-diag-TIMESTAMP.log` - Main diagnostic log with 13 sections
- `truenas-strace-TIMESTAMP.log` - 10-minute strace capture of pvestatd

### Bundle Contents

**Diagnostic Log Sections**:
1. Plugin version and MD5 checksum
2. Environment info (Perl version, IO::Socket::SSL, OpenSSL, Proxmox versions)
3. Storage configuration (all TrueNAS storages, API keys redacted)
4. pvestatd status at capture start
5. Open file descriptors and socket connections
6. Process tree snapshot
7. Existing coredumps (if any)
8. Kernel crash logs (last 7 days)
9. pvestatd error logs (last 7 days)
10. System info (uptime, memory, kernel, CPU)
11. Post-capture pvestatd status
12. New crash logs (if crash occurred during capture)
13. Recent pvestatd journal logs

**Strace Capture**: Monitors the following syscalls over 10 minutes:
- `clone`, `fork`, `vfork` - Process creation (fork-related issues)
- `socket`, `close`, `connect` - Connection management
- `read`, `write` - Data transfer
- `exit_group` - Process termination

### Use Cases

**When to Use**:
- Diagnosing WebSocket fork-related crashes or segfaults
- Investigating pvestatd hangs or crashes
- Capturing connection management patterns during failure
- Collecting data for plugin maintainers to debug issues
- Validating proper connection cleanup during fork events

**When Not to Use**:
- For simple configuration validation (use Health Check Tool instead)
- For performance testing during active production workload windows
- When pvestatd is not running

### Running the Bundle Capture

**Prerequisites**:
- Root access on Proxmox node
- pvestatd service running (`systemctl status pvestatd`)
- 10 minutes available (capture duration is fixed)

**Steps**:
1. Run `bash install.sh` on the Proxmox node
2. Select "Diagnostics" from the main menu
3. Select "Create diagnostics bundle"
4. Review the warnings about what will be captured
5. Type `CAPTURE` at the confirmation prompt (case-sensitive, prevents accidental 10-minute waits)
6. Wait while the bundle captures data
   - The progress display shows elapsed time and pvestatd status
   - If pvestatd crashes during capture, it's detected and noted
7. Bundle is automatically compressed and saved to `/tmp/`

**Example Output**:
```
Diagnostics Bundle

  This will capture the following for 10 minutes:
    - System and plugin information
    - All TrueNAS storage configurations (API keys redacted)
    - strace of pvestatd (captures fork/socket activity)
    - Crash logs and coredump info
    - pvestatd journal logs

  pvestatd found (PID: 12345)

  This capture will take 10 minutes.

  Type CAPTURE to start or any other input to cancel
Confirmation: CAPTURE

Starting strace capture (10 minutes)...
Collecting diagnostics: ✓ Complete
Monitoring pvestatd for 10 minutes...

  Capturing: 120/600 seconds (pvestatd running)

Collecting final state: ✓ Complete
Compressing bundle: ✓ Complete

Diagnostics bundle created successfully

  Output file: /tmp/truenas-diag-20231215-143022.tar.gz
  File size:   512K

  Please send this file for analysis.
```

### Requirements

**System Requirements**:
- Root access on Proxmox node
- pvestatd service running
- `strace` command available (usually pre-installed)
- Sufficient disk space in `/tmp/` (typically 300KB-1MB for tarball)

**Storage Requirements**: None (bundle is system-wide, not storage-specific)

### Troubleshooting

**"pvestatd is not running"**:
```bash
systemctl start pvestatd
```

**"strace: attach: ptrace(PTRACE_SEIZE, 12345): Operation not permitted"**:
- Ensure running as root: `sudo bash install.sh`
- Check SELinux restrictions: `getenforce`

**Bundle file not created**:
- Check `/tmp/` disk space: `df -h /tmp`
- Check file permissions on `/tmp/`
- Verify strace ran successfully (check console output)

### See Also

- [Health Check Tool](#health-check-tool) - For configuration and connectivity validation
- [Integrated Plugin Test](#integrated-plugin-test) - For function testing

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
- Check: `ping TRUENAS_IP`
- Verify API access from Proxmox with the plugin-based call:
  ```bash
  ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"system.info\", []); print \"ok\\n\";'"
  ```

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

> **DEPRECATED**: This standalone script has been removed. Cluster-wide deployment is now integrated into the interactive installer.

To deploy or update across all cluster nodes, run `install.sh` and select the cluster-wide option from the menu. The installer automatically discovers cluster nodes and handles deployment.

See [Installation Guide - Cluster Installation](Installation.md#cluster-installation-with-installer) for details.

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
- Check with the plugin-based call from Proxmox:
  ```bash
  ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"system.info\", []); print \"ok\\n\";'"
  ```

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

The installer shows the current plugin version in the main menu. For cluster environments, use the cluster-wide update feature to ensure version consistency across nodes.

## See Also

- [Installation Guide](Installation.md) - Initial plugin installation
- [Testing Guide](Testing.md) - Complete test suite documentation
- [Configuration Reference](Configuration.md) - Storage configuration
- [Troubleshooting Guide](Troubleshooting.md) - Common issues
