# Testing Guide

Comprehensive guide for testing the TrueNAS Proxmox VE Storage Plugin with the included suites.

## Overview

Testing has two layers. The installer's Diagnostics function test validates the main plugin operations through the Proxmox API against a real storage and cleans up after itself. The repository's Perl and shell suites cover narrower areas: portal parsing, SCRAM authentication, snapshot-import planning, rate limits, lifecycle events and a 46-phase end-to-end run.

### Key Features

- **API-Based Operations** - The installer test and development suite drive the plugin through `pvesh`/`pvesm`
- **Isolated and Self-Cleaning** - Both end-to-end suites use dedicated test VM IDs and clean up afterwards
- **Offline Unit Tests** - `t/nvme/`, `t/ipv6/`, `t/login/`, `t/scram/` and `t/import-snapshots/` need no TrueNAS
- **Timed Runs** - The development suite reports per-operation timings and writes `test-results-*.log`

## Test Suites and Locations

The repository contains several independent suites. They are not interchangeable: only the first two execute real operations against a TrueNAS storage.

| Suite | Path | Requires | Run |
|---|---|---|---|
| Installer function test | `install.sh` → Diagnostics | Proxmox node, TrueNAS storage, ~10GB free | `bash install.sh`, then Diagnostics → Run plugin function test |
| Development suite (46 phases) | `tools/dev-truenas-plugin-full-function-test.sh` | Proxmox node with the plugin installed; creates and destroys VMs | `./tools/dev-truenas-plugin-full-function-test.sh STORAGE_ID VMID_START` |
| API-loss resilience unit tests | `t/nvme/` | Perl deps only; `-I t/nvme/lib` supplies PVE stubs | `prove -v -I t/nvme/lib t/nvme/*.t` |
| IPv6 portal tests | `t/ipv6/` | Perl deps only; same stubs | `prove -v -I t/nvme/lib t/ipv6/01-portal-ipv6.t` |
| iSCSI login portal tests | `t/login/` | Perl deps only; same stubs | `prove -v -I t/nvme/lib t/login/01-login-configured-portals-only.t` |
| SCRAM unit tests | `t/scram/` | Perl deps (`Crypt::PBKDF2`, `MIME::Base64`) | `prove -v t/scram/` |
| Snapshot import planner tests | `t/import-snapshots/` | `libpve-storage-perl` (skips without it) | `prove -v t/import-snapshots/` |
| Rate-limit regression tests | `t/rate-limit/` | Real TrueNAS and a configured storage; see environment variables below | `sudo -E t/rate-limit/run.sh` |
| Lifecycle integration tests | `tools/lifecycle-tests/` | SSH root to a disposable PVE node (and to TrueNAS for scenario 07) | `./tools/lifecycle-tests/run-all.sh --node HOST --storage ID` |

`t/nvme/` builds a fixture sysfs tree rather than talking to any hardware; `-I t/nvme/lib` provides minimal `PVE::Tools`, `PVE::JSONSchema` and `PVE::Storage::Plugin` stand-ins. On a real Proxmox host drop `-I t/nvme/lib` to compile against the real modules.

### Rate-limit test environment variables

`t/rate-limit/run.sh` reads:

| Variable | Meaning |
|---|---|
| `TN_HOST` | TrueNAS management hostname or IP (required) |
| `TN_API_KEY` | API key with read access and write access for `audit.query` (required) |
| `STORAGE_ID` | PVE storage ID configured for that TrueNAS (required) |
| `TEST_VMID_BASE` | Starting VMID (default `99000`) |
| `TN_LOGIN_COUNT_METHOD` | `audit` (default) or `journal` |
| `TN_SSH_HOST`, `TN_SSH_USER`, `TN_SSH_KEY` | TrueNAS SSH access, needed only for `TN_LOGIN_COUNT_METHOD=journal` |
| `DRAIN_SECS` | Seconds to wait between tests for the limiter to reset (default `90`) |
| `KEEP_RESOURCES` | `1` skips cleanup on failure (default `0`) |

See `t/rate-limit/README.md` and `t/rate-limit/INSTALL.md` for setup.

### Lifecycle test arguments

`tools/lifecycle-tests/run-all.sh` and each scenario accept `--node`, `--storage`, `--vmid-start` (default `10100`), `--vm-count` (default `3`), `--settle-s` (default `30`) and `--keep-vms`. See `tools/lifecycle-tests/README.md` for the scenario list.

## Prerequisites

### Required
- **Root Access** - Test suite must run as root
- **Proxmox Node Execution** - Test suite must run on a Proxmox node
- **Plugin Installed** - TrueNAS plugin must be installed and configured
- **Storage Configured** - Storage must be active and accessible
- **Available VM IDs** - Provide `VMID_START`; the development suite uses `VMID_START`..`VMID_START+200` and has no default

### System Requirements
- Proxmox VE 8.x or 9.x
- TrueNAS SCALE with sufficient space (~10GB minimum)
- Working storage configuration in `/etc/pve/storage.cfg`

## Basic Usage

### Quick Start

```bash
# Make executable
chmod +x tools/dev-truenas-plugin-full-function-test.sh

# Run against storage 'tnscale' starting at VMID 9001
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001

# Run with a different storage and VMID range
./tools/dev-truenas-plugin-full-function-test.sh your-storage-name 5000

# Run with backup phases enabled
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --backup-store pbs
```

### Command Syntax

```bash
./tools/dev-truenas-plugin-full-function-test.sh STORAGE_ID VMID_START [OPTIONS]
```

**Arguments** (both required, no defaults):
- `STORAGE_ID` - TrueNAS storage ID from `/etc/pve/storage.cfg`
- `VMID_START` - Starting VMID for test VMs (numeric); the suite uses `VMID_START`..`VMID_START+200`

**Options**:
- `--backup-store STORAGE` - Backup storage ID for the backup phases (if not specified, those phases are skipped)
- `--phase N` - Run only phase N (same as `--start N --stop N`)
- `--start N` - Begin at phase N and run to the end
- `--stop M` - Stop after phase M

**Examples**:
```bash
# Test storage named 'truenas-storage' starting at VMID 5000
./tools/dev-truenas-plugin-full-function-test.sh truenas-storage 5000

# Run with backup phases using PBS storage
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --backup-store pbs

# Run only phase 2
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --phase 2

# Run phases 10-20
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --start 10 --stop 20
```

## What the Installer Function Test Checks

This section covers the Diagnostics function test (`bash install.sh` → Diagnostics → Run plugin function test). The development suite's 46 phases are listed in [Tools.md](Tools.md#test-phases).

The installer test performs 9 checks through the Proxmox API, plus VM migration and cross-node clone when run on a cluster node:

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
- Tests backend exposure (iSCSI extent/targetextent or NVMe namespace)

**Pass Criteria**: VM created with disk, volume appears in storage

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

### 4b. Multi-Disk Snapshot Check
**What it does**:
- Creates a VM with two disks on the same storage
- Creates a snapshot that must cover both disks atomically
- Deletes the snapshot and the VM

**Pass Criteria**: Snapshot created and deleted across both disks

### 5. Clone Operations Test
**What it does**:
- Clones VM from snapshot
- Creates independent VM clone
- Verifies clone has separate storage
- Tests network-based cloning (documented limitation)

**Pass Criteria**: Clone VM created with independent disks

**Note**: Clone uses network transfer as documented in [Known Limitations](Known-Limitations.md#clone-performance)

### 6. Volume Resize Test
**What it does**:
- Gets current disk size
- Grows disk by 1GB
- Verifies new size via API

**Pass Criteria**: Disk resized successfully, new size reflected

### 7. VM Start/Stop Test
**What it does**:
- Starts test VM
- Verifies VM running state
- Stops VM
- Verifies VM stopped state
- Tests disk accessibility during VM lifecycle

**Pass Criteria**: VM starts and stops successfully

### 8. Volume Deletion Test
**What it does**:
- Deletes clone VM with `--purge` flag
- Deletes base VM with `--purge` flag
- Verifies automatic cleanup of TrueNAS resources
- Checks for orphaned volumes
- Tests proper cleanup of zvols and their iSCSI/NVMe exposure

**Pass Criteria**: VMs deleted, no orphaned storage on TrueNAS

**Important**: This test validates that GUI-style deletion (using `--purge`) properly cleans up all TrueNAS resources, unlike `qm destroy` (see [Known Limitations](Known-Limitations.md#vm-deletion-qm-destroy))

## Test Execution Flow

### Installer Function Test Stages

1. The test description is shown; type `ACCEPT` to continue.
2. Select the storage to test from the configured `truenasplugin:` storages.
3. **VM ID selection**: the test starts at 990 and walks upward until it finds two consecutive free IDs (base and clone). The multi-disk check uses base + 100.
4. **Pre-flight**: `pvesh` must be available, then the storage-status check runs. A storage-status failure aborts the run.
5. **Volume creation**: a failure here aborts the run after cleaning up the test VMs.
6. **Remaining checks**: each failure is counted and the run continues.
7. **Cleanup**: test VMs are deleted with `--purge` and temporary state is removed.
8. **Summary**: totals, duration, storage, node, cluster mode and the installer log path are printed.

## Output and Logging

### Console Output

The installer test prints 30-character labels followed by a spinner and a status glyph:

- `✓` - check passed
- `✗` - check failed
- `⚠` - check completed with a warning

**Example Output**:
```
Storage accessibility         ✓ Storage active and accessible
Volume creation                ✓ Created 4GB disk successfully
Volume listing                 ✓ Retrieved volume configuration
Snapshot operations            ✓ Snapshot created and verified
Clone operations               ✓ Cloned VM from snapshot
Volume resize                  ✓ Expanded disk by 1GB
VM start/stop lifecycle        ✓ VM started and stopped
Volume deletion                ✓ Cleaned up test resources
```

### Log Files

The function test writes nothing to a log file of its own; its output is console-only. The installer's global log is `/var/log/truenas-installer.log`, which receives installer-level events, not test results.

The development suite is the one that writes a timestamped result log: `test-results-YYYYMMDD-HHMMSS.log` in the directory it is launched from. See [Tools.md](Tools.md#output-files).

### Performance Metrics

The installer test reports only the total run duration in its summary; it does not time individual operations. For per-operation timings and a performance summary table, use the development suite (phases 8 and 28) and read `test-results-*.log`.

## Test Results Summary

At the end of the run, the installer prints:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Plugin Function Test Summary

  Total tests run:    9
  Tests passed:       9
  Tests failed:       0
  Duration:           3m 12s

  Storage tested:     truenas-storage
  Node:               pve
  Cluster mode:       No

  Log file:           /var/log/truenas-installer.log
```

`Total tests run` includes the multi-disk snapshot check, so a standalone node reports 9 and a cluster node 11.

## Interpreting Results

The test function returns 0 when no test failed and 1 otherwise. Outside the installer, the status glyphs are the readable result: any `✗` line is a failed check.

### All Checks Passed

```
Plugin Function Test Summary: 9/9 tests passed
```

Exit status: 0. The plugin is functioning correctly.

### Failure

```
  Tests failed:       3
```

Exit status: 1. Review the `✗` lines; the storage-status and volume-creation failures abort the run early by design.

## Common Test Failures

### Storage Not Accessible

**Symptom**:
```
Storage accessibility         ✗ Failed
Storage status test failed - aborting test suite
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
Add 4GB disk to VM:           ✗ Failed
Volume creation test failed - attempting cleanup
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
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"iscsi.target.query\", [ [] ]); print \"ok\\n\";'"
```

### Clone Operation Is Slow

**Symptom**: the clone check takes minutes rather than seconds.

**Cause**: a full copy is streamed over the network; this is expected.

**Not a Failure**: Clone uses network transfer as documented in [Known Limitations](Known-Limitations.md#clone-performance)

**Expected Times**:
- 4GB disk over 1GbE: ~40-60s
- 4GB disk over 10GbE: ~5-10s

### VM Deletion Leaves Orphans

**Symptom**: `pvesm list <storage>` still shows `vm-990-*` or `vm-991-*` volumes after the run.

**If using `--purge`**: this shouldn't happen and indicates a cleanup issue.

**Solutions**:
```bash
# Check for orphaned volumes
pvesm list truenas-storage | grep -E "(990|991)"

# Manual cleanup if needed
pvesm free truenas-storage:vm-990-disk-0-lun1

# Or run: bash install.sh -> Diagnostics -> Cleanup orphaned resources

# Check TrueNAS side
ssh root@TRUENAS_IP "zfs list -t volume | grep proxmox"
```

## Advanced Usage

### Development Suite Phase Selection

Select phases with `--phase`, `--start` and `--stop`:

```bash
# Only phase 5
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --phase 5

# Phases 10 through 20
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001 --start 10 --stop 20
```

The test VM range is `VMID_START`..`VMID_START+200`. No environment variable changes it; choose the starting ID with the second positional argument.

### Installer Test VM IDs and Bridge

The installer test starts at 990 and walks upward until it finds two consecutive free IDs. It attaches the test VM NIC to `vmbr0` when that bridge exists, otherwise to the first `vmbr*` bridge, or to `TRUENAS_PLUGIN_TEST_BRIDGE` when that variable is set:

```bash
TRUENAS_PLUGIN_TEST_BRIDGE=vmbr1 bash install.sh
```

### API Timeout

The installer test uses `TEST_API_TIMEOUT=60` (seconds) for each `pvesh` call; change that variable in `install.sh` for slow systems. The development suite sets per-command timeouts inline (for example `timeout 60 pvesh create ...`) and has no single override variable.

## Continuous Integration

### Automated Testing

The development suite takes both positional arguments and has no auto-confirm flag:

```bash
#!/bin/bash
# CI test script

if ./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001; then
    echo "Tests passed"
    exit 0
else
    echo "Tests failed"
    # Upload the log file to artifact storage
    cp test-results-*.log ./test-artifacts/
    exit 1
fi
```

### Scheduled Testing

Add to cron for periodic validation:

```bash
# Daily test at 2 AM
0 2 * * * cd /root/truenas-proxmox-plugin/tools && ./dev-truenas-plugin-full-function-test.sh tnscale 9001 >> /var/log/truenas-plugin-test.log 2>&1
```

## Troubleshooting Test Suite

### Test Suite Won't Run

**Permission Denied**:
```bash
chmod +x tools/dev-truenas-plugin-full-function-test.sh
```

**Not Running as Root**: the development suite must run on a PVE node as root, with both arguments:
```bash
./tools/dev-truenas-plugin-full-function-test.sh tnscale 9001
```

### API Timeout Errors

The installer test uses `TEST_API_TIMEOUT=60` in `install.sh`; raise it there for slow systems. The development suite uses inline `timeout` values per command.

### Missing Dependencies

Install required tools:
```bash
# bc is used by the development suite's staggered concurrency phases
apt-get install bc

# Ensure pvesh is available (should come with Proxmox)
which pvesh
```

## Performance Benchmarking

Use the development suite to benchmark different configurations.

### Compare Block Sizes

```bash
# Test with 64K blocks
# Edit /etc/pve/storage.cfg: tn_zvol_blocksize 64K
# systemctl restart pvedaemon pveproxy
./tools/dev-truenas-plugin-full-function-test.sh test-64k 9001 > bench-64k.log

# Test with 128K blocks
# Edit /etc/pve/storage.cfg: tn_zvol_blocksize 128K
# systemctl restart pvedaemon pveproxy
./tools/dev-truenas-plugin-full-function-test.sh test-128k 9001 > bench-128k.log

# Compare the reported durations
grep -E "in [0-9]+s" bench-64k.log > compare-64k.txt
grep -E "in [0-9]+s" bench-128k.log > compare-128k.txt
```

### Network Performance

Test different network configurations (each storage ID configured with the portal layout under test):

```bash
# Test single portal
./tools/dev-truenas-plugin-full-function-test.sh single-portal 9001

# Test multipath with multiple portals
./tools/dev-truenas-plugin-full-function-test.sh multipath 9001
```

## Best Practices

### Before Testing

1. **Backup Configuration**: Save `/etc/pve/storage.cfg`
2. **Check Space**: Ensure adequate TrueNAS space (~10GB minimum)
3. **Verify Storage Active**: `pvesm status` shows storage active
4. **Review Test VMs**: the installer test needs two consecutive free VM IDs at or above 990 (it walks upward until it finds them)

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
