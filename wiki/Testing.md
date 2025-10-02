# Testing Guide

Comprehensive guide for testing the TrueNAS Proxmox VE Storage Plugin using the included test suite.

## Overview

The TrueNAS Plugin Test Suite is an automated testing tool that validates all major plugin functionality through the Proxmox API. It simulates real-world usage patterns including VM creation, snapshot operations, cloning, resizing, and cleanup.

### Key Features

- **API-Based Testing** - Uses Proxmox API (`pvesh`) to simulate GUI interactions
- **Comprehensive Coverage** - Tests all major plugin features
- **Performance Metrics** - Reports timing for all operations
- **Compatible** - Works with Proxmox VE 8.x and 9.x
- **Safe** - Uses isolated test VMs, automatic cleanup
- **Detailed Logging** - Creates timestamped log files for troubleshooting

## Test Suite Location

The test suite is included in the plugin repository:
```
tools/truenas-plugin-test-suite.sh
```

## Prerequisites

### Required
- **Root Access** - Test suite must run as root
- **Plugin Installed** - TrueNAS plugin must be installed and configured
- **Storage Configured** - Storage must be active and accessible
- **Available VM IDs** - Test suite auto-selects available VM IDs (default: 990-999 range)

### System Requirements
- Proxmox VE 8.x or 9.x
- TrueNAS SCALE with sufficient space (~10GB minimum)
- Working storage configuration in `/etc/pve/storage.cfg`

## Basic Usage

### Quick Start

```bash
# Make executable
chmod +x tools/truenas-plugin-test-suite.sh

# Run with default storage name 'tnscale'
./tools/truenas-plugin-test-suite.sh

# Run with custom storage name
./tools/truenas-plugin-test-suite.sh your-storage-name

# Run with auto-confirmation (skip prompt)
./tools/truenas-plugin-test-suite.sh your-storage-name -y
```

### Command Syntax

```bash
./tools/truenas-plugin-test-suite.sh [storage_name] [-y]
```

**Parameters**:
- `storage_name` - Name of TrueNAS storage from `/etc/pve/storage.cfg` (default: `tnscale`)
- `-y` or `--yes` - Auto-confirm without prompting

**Examples**:
```bash
# Test storage named 'truenas-storage'
./tools/truenas-plugin-test-suite.sh truenas-storage

# Test with auto-confirmation
./tools/truenas-plugin-test-suite.sh truenas-storage -y

# Test default storage 'tnscale'
./tools/truenas-plugin-test-suite.sh
```

## What Gets Tested

The test suite performs comprehensive validation of all major plugin features:

### 1. Storage Status Test
**What it does**:
- Verifies storage is accessible via Proxmox API
- Checks storage status and capacity reporting
- Validates API connectivity

**Pass Criteria**: Storage responds to API status queries

### 2. Volume Creation Test
**What it does**:
- Creates test VM (ID auto-selected from available IDs)
- Allocates 4GB disk on TrueNAS storage
- Verifies volume creation on TrueNAS side
- Tests iSCSI extent and targetextent creation

**Pass Criteria**: VM created with disk, volume appears in storage

**Performance Metric**: Reports disk allocation time

### 3. Volume Listing Test
**What it does**:
- Lists volumes on storage via API
- Retrieves VM configuration
- Verifies volume visibility

**Pass Criteria**: Created volumes appear in storage listing

### 4. Snapshot Operations Test
**What it does**:
- Creates ZFS snapshot via API
- Lists snapshots
- Creates second snapshot for clone testing
- Verifies snapshot metadata

**Pass Criteria**: Snapshots created successfully, appear in listings

**Performance Metric**: Reports snapshot creation time

### 5. Clone Operations Test
**What it does**:
- Clones VM from snapshot
- Creates independent VM clone
- Verifies clone has separate storage
- Tests network-based cloning (documented limitation)

**Pass Criteria**: Clone VM created with independent disks

**Performance Metric**: Reports clone operation time

**Note**: Clone uses network transfer as documented in [Known Limitations](Known-Limitations.md#no-fast-clone-support)

### 6. Volume Resize Test
**What it does**:
- Gets current disk size
- Grows disk by 1GB
- Verifies new size via API

**Pass Criteria**: Disk resized successfully, new size reflected

**Performance Metric**: Reports resize operation time

### 7. VM Start/Stop Test
**What it does**:
- Starts test VM
- Verifies VM running state
- Stops VM
- Verifies VM stopped state
- Tests iSCSI disk accessibility during VM lifecycle

**Pass Criteria**: VM starts and stops successfully

**Performance Metrics**: Reports start time and stop time

### 8. Volume Deletion Test
**What it does**:
- Deletes clone VM with `--purge` flag
- Deletes base VM with `--purge` flag
- Verifies automatic cleanup of TrueNAS resources
- Checks for orphaned volumes
- Tests proper cleanup of zvols, extents, targetextents

**Pass Criteria**: VMs deleted, no orphaned storage on TrueNAS

**Performance Metric**: Reports deletion time

**Important**: This test validates that GUI-style deletion (using `--purge`) properly cleans up all TrueNAS resources, unlike `qm destroy` (see [Known Limitations](Known-Limitations.md#vm-deletion-behavior))

## Test Execution Flow

### Execution Stages

The test suite runs in the following stages:

#### 1. Pre-Flight Checks
```
[CHECK] PRE-FLIGHT CHECKS
  [*]  Checking plugin installation...
  [*]  Checking storage configuration...
  [*]  Checking required tools...
  [*]  Checking permissions...
```

Validates:
- Plugin file exists at `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- Storage is accessible via API
- `pvesh` command available
- Running as root

**If any check fails, test suite aborts immediately**

#### 2. VM ID Selection
```
[TEST] Finding available VM IDs
[PASS] Selected test VM IDs: 990 (base), 991 (clone)
```

Automatically finds two consecutive available VM IDs in range 990-1090

#### 3. Cleanup Existing Test VMs
Removes any existing test VMs from previous runs to ensure clean test environment

#### 4. Main Test Execution
Runs all 8 test cases sequentially (listed above)

#### 5. Cleanup Stage
Deletes test VMs and verifies storage cleanup

#### 6. Results Summary
Generates comprehensive test report with:
- Pass/fail summary
- Error and warning counts
- Performance metrics for all operations
- System information

## Output and Logging

### Console Output

The test suite provides colorized, real-time console output:

**Status Indicators**:
- `[PASS]` - Green - Test passed
- `[FAIL]` - Red - Test failed
- `[WARN]` - Yellow - Warning issued
- `[TEST]` - Blue - Test starting
- `[INFO]` - Blue - Informational message

**Progress Steps**:
- `• Step description...` - In progress (blue)
- `✓ Step description...` - Completed (green checkmark)

**Example Output**:
```
[TEST] Testing volume creation (via API)
    ✓ Creating test VM 990...
    ✓ Adding 4GB disk to VM...
    [INFO] [TIME]  Volume Creation (4GB disk) completed in 3.45s
[PASS] Volume creation test passed (4.20s, disk: 3.45s)
```

### Log Files

Every test run creates a detailed log file:

**Location**: `/tmp/truenas-plugin-test-suite-YYYYMMDD-HHMMSS.log`

**Contents**:
- Timestamped entries for all operations
- API call details (method, path, parameters)
- API responses and errors
- Performance timing data
- Test results summary

**Example Log Entry**:
```
[2025-10-01 23:45:12] [API] POST /nodes/pve/qemu --vmid 990 --name test-base-vm --memory 512 --cores 1 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
[2025-10-01 23:45:13] [OUTPUT] UPID:pve:00001234:...
[2025-10-01 23:45:13] [API] Request succeeded
[2025-10-01 23:45:13] [TIMING] Creating test VM 990 completed in 1.23s
[2025-10-01 23:45:13] [SUCCESS] Test VM 990 created successfully
```

### Performance Metrics

Each operation reports timing:

**Individual Operations**:
```
[INFO] [TIME]  Volume Creation (4GB disk) completed in 3.45s
[INFO] [TIME]  First snapshot creation: 0.89s
[INFO] [TIME]  Clone operation: 45.67s
[INFO] [TIME]  Disk resize (+1GB): 2.34s
[INFO] [TIME]  VM start: 5.12s
[INFO] [TIME]  VM stop: 2.87s
[INFO] [TIME]  VM deletion with --purge: 8.91s
```

**Test Totals**:
```
[PASS] Volume creation test passed (4.20s, disk: 3.45s)
[PASS] Snapshot operations test passed (3.56s, snapshot: 0.89s)
[PASS] Clone operations test passed (52.34s, clone: 45.67s)
```

## Test Results Summary

At the end of execution, a comprehensive summary is generated:

```
================================================================================
TEST SUMMARY REPORT (API-based Testing)
================================================================================
Test Date: Mon Oct  1 23:45:00 UTC 2025
Storage: truenas-storage
Node: pve
Log File: /tmp/truenas-plugin-test-suite-20251001-234500.log
API Timeout: 60 seconds

Test Results:
8 tests passed
0 errors encountered
1 warnings issued

Performance Metrics:
[TIME]  Storage Status Check completed in 0.45s
[TIME]  Volume Creation (4GB disk) completed in 3.45s
[TIME]  Volume Creation Test total time: 4.20s
[TIME]  Volume Listing Test completed in 0.67s
[TIME]  First snapshot creation: 0.89s
[TIME]  Snapshot Operations Test total time: 3.56s
[TIME]  Clone operation: 45.67s
[TIME]  Clone Operations Test total time: 52.34s
[TIME]  Disk resize (+1GB): 2.34s
[TIME]  Volume Resize Test total time: 3.12s
[TIME]  VM start: 5.12s
[TIME]  VM stop: 2.87s
[TIME]  VM Start/Stop Test total time: 10.45s
[TIME]  VM deletion with --purge: 8.91s
[TIME]  Volume Deletion Test total time: 15.23s

System Information:
Proxmox Version: pve-manager/8.2.2/9355359cd7afbae4 (running kernel: 6.8.4-2-pve)
Kernel: 6.8.4-2-pve
Node: pve

Plugin Feature Coverage (via API):
[*]  Storage status and capacity reporting
[*]  Volume creation and allocation
[*]  Volume listing via API
[*]  Snapshot creation via API
[*]  Clone operations via API
[*]  Volume resize via API
[*]  VM start and stop operations
[*]  Volume deletion with --purge flag
[*]  PVE 8.x and 9.x compatibility

Notes:
- All operations performed via Proxmox API (pvesh)
- Simulates GUI interaction patterns
- Compatible with PVE 8.x and 9.x

================================================================================
```

## Interpreting Results

### Success Criteria

**All Tests Pass**:
```
[SUCCESS] Test suite completed!
[SUMMARY]  Summary: 8 passed, 0 errors, 0 warnings
```
Exit code: 0

Plugin is functioning correctly, all features working as expected.

### Partial Success

**Some Warnings**:
```
[SUCCESS] Test suite completed!
[SUMMARY]  Summary: 8 passed, 0 errors, 2 warnings
```
Exit code: 0

Tests passed but warnings issued (e.g., slow operations, minor issues). Review log file for details.

### Failure

**Test Failures**:
```
[FAIL]  3 test(s) failed
```
Exit code: 1

One or more tests failed. Review console output and log file to identify failures.

## Common Test Failures

### Storage Not Accessible

**Symptom**:
```
[FAIL]  Storage 'truenas-storage' not accessible via API
[FAIL]  Pre-flight checks failed
```

**Causes**:
- Storage name incorrect (doesn't match `/etc/pve/storage.cfg`)
- Storage inactive (TrueNAS offline, network issue)
- Plugin not installed or configured

**Solutions**:
```bash
# Check storage name
grep truenasplugin /etc/pve/storage.cfg

# Check storage status
pvesm status

# Verify plugin installed
ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

### Volume Creation Fails

**Symptom**:
```
[FAIL] Failed to add disk to VM
```

**Causes**:
- Insufficient space on TrueNAS
- iSCSI service not running
- API key lacks permissions
- Pre-flight checks should catch these

**Solutions**:
```bash
# Check TrueNAS space
ssh root@TRUENAS_IP "zfs list tank/proxmox"

# Check iSCSI service
ssh root@TRUENAS_IP "systemctl status iscsitarget"

# Test API key
curl -k -H "Authorization: Bearer YOUR_API_KEY" \
  https://TRUENAS_IP/api/v2.0/iscsi/target
```

### Clone Operation Timeout

**Symptom**:
```
[WARN]  Clone operation took 180s (slow network)
```

**Cause**: Large disk being copied over network (expected behavior)

**Not a Failure**: Clone uses network transfer as documented in [Known Limitations](Known-Limitations.md#no-fast-clone-support)

**Expected Times**:
- 4GB disk over 1GbE: ~40-60s
- 4GB disk over 10GbE: ~5-10s

### VM Deletion Leaves Orphans

**Symptom**:
```
[WARN]  Some volumes remain after VM deletion
```

**If using `--purge` flag**: This shouldn't happen, indicates cleanup issue

**Solutions**:
```bash
# Check for orphaned volumes
pvesm list truenas-storage | grep -E "(990|991)"

# Manual cleanup if needed
pvesm free truenas-storage:vm-990-disk-0-lun1

# Check TrueNAS side
ssh root@TRUENAS_IP "zfs list -t volume | grep proxmox"
```

## Advanced Usage

### Custom VM ID Range

Set `TEST_VM_BASE_HINT` to change starting ID search range:

```bash
# Search for available IDs starting from 500
TEST_VM_BASE_HINT=500 ./tools/truenas-plugin-test-suite.sh truenas-storage
```

### Extended Timeout

Modify timeout for slow networks/systems:

```bash
# Edit test suite
nano tools/truenas-plugin-test-suite.sh

# Change line:
API_TIMEOUT=60  # Increase to 120 for slow systems
```

### Selective Testing

Comment out tests you don't want to run:

```bash
# Edit main() function around line 920
# Comment out specific tests:
# test_clone_operations || ((failed_tests++))
```

## Continuous Integration

### Automated Testing

Run test suite in CI/CD pipelines:

```bash
#!/bin/bash
# CI test script

# Run test suite with auto-confirm
if ./tools/truenas-plugin-test-suite.sh production-storage -y; then
    echo "Tests passed"
    exit 0
else
    echo "Tests failed"
    # Upload log file to artifact storage
    cp /tmp/truenas-plugin-test-suite-*.log ./test-artifacts/
    exit 1
fi
```

### Scheduled Testing

Add to cron for periodic validation:

```bash
# Daily test at 2 AM
0 2 * * * /root/tools/truenas-plugin-test-suite.sh production-storage -y >> /var/log/truenas-plugin-test.log 2>&1
```

## Troubleshooting Test Suite

### Test Suite Won't Run

**Permission Denied**:
```bash
chmod +x tools/truenas-plugin-test-suite.sh
```

**Not Running as Root**:
```bash
./tools/truenas-plugin-test-suite.sh
```

### API Timeout Errors

Increase timeout in script:
```bash
API_TIMEOUT=120  # Increase from default 60
```

### Missing Dependencies

Install required tools:
```bash
# bc for timing calculations
apt-get install bc

# Ensure pvesh available (should be with Proxmox)
which pvesh
```

## Performance Benchmarking

Use test suite to benchmark different configurations:

### Compare Block Sizes

```bash
# Test with 64K blocks
# Edit /etc/pve/storage.cfg: zvol_blocksize 64K
# systemctl restart pvedaemon pveproxy
./tools/truenas-plugin-test-suite.sh test-64k -y > bench-64k.log

# Test with 128K blocks
# Edit /etc/pve/storage.cfg: zvol_blocksize 128K
# systemctl restart pvedaemon pveproxy
./tools/truenas-plugin-test-suite.sh test-128k -y > bench-128k.log

# Compare timing results
grep "TIMING" bench-64k.log > compare-64k.txt
grep "TIMING" bench-128k.log > compare-128k.txt
```

### Network Performance

Test different network configurations:

```bash
# Test single portal
./tools/truenas-plugin-test-suite.sh single-portal -y

# Test multipath with multiple portals
./tools/truenas-plugin-test-suite.sh multipath -y

# Compare clone operation times
```

## Best Practices

### Before Testing

1. **Backup Configuration**: Save `/etc/pve/storage.cfg`
2. **Check Space**: Ensure adequate TrueNAS space (~10GB minimum)
3. **Verify Storage Active**: `pvesm status` shows storage active
4. **Review Test VMs**: Ensure VM IDs 990-999 are available (or will be auto-selected)

### During Testing

1. **Don't Interrupt**: Let test suite complete fully
2. **Monitor Progress**: Watch console output for issues
3. **Check Logs**: Tail log file in another terminal if needed

### After Testing

1. **Review Results**: Check test summary for failures/warnings
2. **Analyze Performance**: Review timing metrics
3. **Save Logs**: Archive log files for future reference
4. **Cleanup**: Test suite auto-cleans, but verify with `pvesm list`

## See Also

- [Installation Guide](Installation.md) - Initial setup before testing
- [Configuration Reference](Configuration.md) - Storage configuration options
- [Troubleshooting Guide](Troubleshooting.md) - Resolving test failures
- [Known Limitations](Known-Limitations.md) - Expected behaviors in tests
- [Advanced Features](Advanced-Features.md) - Performance tuning based on test results
