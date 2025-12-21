# TrueNAS Plugin Changelog

## Version 1.2.6 (December 20, 2025)

### 🐛 **Bug Fix: Improved Fork-Safety with NullDestructor Pattern**

#### **Fixed remaining edge cases in fork handling that could still cause segfaults**
- **Problem**: v1.2.5 InactiveDestroy pattern still caused crashes in some environments because setting `$conn->{sock} = undef` and clearing `%_ws_connections` triggers Perl's DESTROY chain, where underlying IO::Socket layers could still attempt cleanup on already-closed file descriptors
- **Root cause**: Even with `_SSL_object` removed, setting socket references to undef invokes the full DESTROY chain including IO::Socket::INET's destructor and Perl's internal IO layer cleanup
- **Solution**: Implemented **NullDestructor rebless pattern** - inherited sockets are reblessed into a dummy class with an empty DESTROY method, completely preventing any cleanup code from running

### 🔧 **Technical Details**
Fork detection now uses a more robust approach:
1. **Added `NullDestructor` package** with empty `DESTROY { }` method
2. **Rebless inherited sockets** into NullDestructor class - makes ALL destruction code no-op
3. **Do NOT clear references** - clearing triggers DESTROY which we want to avoid
4. **Clear connection hash** so child creates fresh connections on next call

### 📊 **Impact**
- **Eliminates edge-case segfaults**: No cleanup code runs at all on inherited sockets
- **Simpler implementation**: No need to manipulate internal IO::Socket::SSL state
- **Memory handling**: Neutered sockets remain in child's memory until exit (OS reclaims)
- **Based on analysis**: Gemini-assisted investigation identified the reference-clearing as root cause

---

## Version 1.2.5 (December 18, 2025)

### 🐛 **Bug Fix: Complete Resolution of Fork-Related pvestatd Crashes**

#### **Fixed remaining crashes using InactiveDestroy pattern**
- **Problem**: v1.2.4 orphan list approach still caused crashes because when child process **exits**, Perl's global destruction calls DESTROY on all objects including `@_ws_orphaned`, which calls `SSL_free()` and corrupts the parent's SSL state
- **Root cause**: Keeping socket references alive isn't enough - IO::Socket::SSL's DESTROY still runs when child exits, calling `Net::SSLeay::free()` which corrupts shared SSL context
- **Solution**: Implemented **InactiveDestroy pattern** (similar to DBI's fork handling) that completely disables DESTROY on inherited sockets

### 🔧 **Technical Details**
Fork detection now "lobotomizes" inherited sockets so DESTROY does nothing:
1. **Delete `_SSL_object`** from socket glob - makes IO::Socket::SSL's DESTROY a no-op
2. **Remove from `$IO::Socket::SSL::SSL_OBJECT`** hash - clears global tracking
3. **Close raw FD with `POSIX::close()`** - closes file descriptor without SSL protocol actions
4. **Clear all references** - allows Perl GC to clean up safely

### 📚 **Research Basis**
- IO::Socket::SSL documentation recommends `SSL_no_shutdown` for forking servers
- DBI uses `InactiveDestroy` attribute to prevent child cleanup affecting parent
- DBIx::Connector uses PID-based detection with automatic reconnection
- Pattern validated against industry-standard fork handling in Redis, PostgreSQL, and other connection pools

### 📊 **Impact**
- **Eliminates all fork-related crashes**: No more "Attempt to free unreferenced scalar" or SIGSEGV
- **Preserves performance**: Persistent connections still used for read operations (~30ms vs ~500ms ephemeral)
- **Production ready**: Based on proven patterns from DBI, DBIx::Connector, and IO::Socket::SSL documentation

---

## Version 1.2.4 (December 16, 2025)

### 🐛 **Bug Fix: Complete Fix for Fork-Related pvestatd Crashes**

#### **Fixed remaining "Attempt to free unreferenced scalar" crashes**
- **Problem**: v1.2.3 fix still caused crashes because `%_ws_connections = ()` triggered Perl's DESTROY on inherited IO::Socket::SSL objects
- **Root cause**: When clearing the connection hash, Perl decrements reference counts and calls DESTROY, which invokes `SSL_free()` on memory allocated in the parent process's address space - causing memory corruption
- **Solution**: Added orphan list (`@_ws_orphaned`) to keep inherited connection references alive, preventing DESTROY from ever being called on inherited sockets

### 🔧 **Technical Details**
- Added `@_ws_orphaned` array to hold inherited connections
- Fork detection now pushes connections to orphan list BEFORE clearing hash
- This keeps refcount > 0, preventing DESTROY from being called
- Orphaned connections stay in memory until child process exits (OS reclaims everything)

---

## Version 1.2.3 (December 12, 2025)

### 🐛 **Bug Fix: Fork-Related pvestatd Crashes**

#### **Fixed "Attempt to free unreferenced scalar" crashes caused by forked processes**
- **Problem**: pvestatd crashed with "Attempt to free unreferenced scalar" errors followed by SIGSEGV after variable periods of operation
- **Root cause**: When pvestatd forks child processes for monitoring tasks, both parent and child inherit references to the same WebSocket socket objects in `%_ws_connections`. Perl's reference counting treats these as independent references, causing double-free corruption when either process's garbage collector runs
- **Solution**: Added PID tracking (`$_ws_creator_pid`) to detect when a forked child process inherits parent connections. Child processes now silently discard inherited connection references (without closing sockets - parent owns them) and create fresh connections

### 🔧 **Technical Details**
- Added `$_ws_creator_pid` variable initialized to `$$` at module load
- `_ws_get_persistent()`: Added fork detection at function entry - if `$$ != $_ws_creator_pid`, clears `%_ws_connections` without closing sockets and updates creator PID
- Debug logging (level 2) when fork detection invalidates inherited connections

---

## Version 1.2.2 (December 9, 2025)

### 🐛 **Bug Fixes: Concurrent Operations & Multipath iSCSI**

#### **Fixed race condition for rapid disk deletes and creation**
- **Problem**: Rapid sequential disk operations (delete followed by create) could fail due to NVMe readdir operations returning tainted values
- **Root cause**: Device path iteration after deletions encountered stale or partially cleaned entries
- **Solution**: Enhanced device enumeration with proper taint handling and existence checks during rapid operations

#### **Fixed "free unreferenced scalar" WebSocket error causing pvestatd crashes**
- **Problem**: pvestatd crashed with "Attempt to free unreferenced scalar" followed by SIGSEGV after WebSocket connection failures
- **Root cause**: Dead connections were removed from cache without properly closing the socket first, causing IO::Socket::SSL cleanup issues
- **Solution**: Added explicit socket close before removing dead connections from the persistent connection cache in `_ws_get_persistent()`

#### **Fixed spurious iSCSI login warnings in multipath configurations**
- **Problem**: Disk operations generated repeated "iscsiadm: Could not log into all portals" warnings even when sessions were already active
- **Root cause**: Plugin attempted to log into ALL portals without checking which individual portals were already connected
- **Solution**: Added `_portal_connected()` helper function to check individual portal session status; `_iscsi_login_all()` now skips login for portals that already have active sessions

### 🔧 **Technical Details**
- `_ws_get_persistent()`: Now properly closes socket before removing dead connections from cache
- `_portal_connected()`: New helper function checks if a specific portal has an active iSCSI session
- `_all_portals_connected()`: Refactored to use `_portal_connected()` for efficiency
- `_iscsi_login_all()`: Gets session list once at start, skips login for already-connected portals

---

## Version 1.2.1 (December 8, 2025)

### 🐛 **Bug Fixes: pvestatd Stability and NVMe Taint Mode**

#### **Fixed pvestatd crashes (SIGSEGV) from truncated API responses**
- **Problem**: pvestatd crashed with SIGSEGV after 1-2 minutes when TrueNAS returned truncated JSON responses
- **Root cause**: `decode_json()` threw uncaught exceptions on malformed JSON, causing cascading failures
- **Solution**: Wrapped JSON decoding in `eval {}` with diagnostic logging (response length and preview) before re-throwing

#### **Fixed "Insecure dependency in exec" errors on NVMe storage**
- **Problem**: Moving disks to/from NVMe storage and creating EFI disks failed with Perl taint mode errors
- **Root cause**: Device names from `readdir()` were validated but not untainted before use in system calls
- **Solution**: Added capture groups to regex patterns to properly untaint `$entry` via `$1` assignment

#### **Fixed "Can't use string (DEFAULT) as SCALAR ref" errors**
- **Problem**: Status checks failed when TrueNAS returned string "DEFAULT" for inherited properties
- **Root cause**: Code attempted regex matching on property values that could be references instead of strings
- **Solution**: Added `!ref()` guard before regex matching in three locations (volume_snapshot_info, _list_images_iscsi, _list_images_nvme)

### 🔧 **Technical Details**
- `_ws_rpc()`: JSON decode now wrapped in eval with error logging
- `_rest_api_call()`: Same JSON decode error handling added for REST transport
- `_nvme_find_device_by_subsystem()`: Device name regex uses capture groups for untainting
- Extended untainting to all NVMe readdir operations (`_nvme_rescan_controllers`, `_nvme_device_for_uuid`)
- Property access hardening at lines 1953, 4019, 4157
- Test script now boots EFI VMs to exercise `activate_volume()` code path

---

## Version 1.2.0 (December 7, 2025)

### **Concurrent Operations Support**

#### **Fixed parallel disk allocation failures (30% → 100% success rate)**
- **Problem**: Parallel VM creation with disk allocation failed at ~30% success rate due to Proxmox CFS lock timeout
- **Root cause**: Default 10-second CFS lock timeout was insufficient for concurrent disk allocations that take ~12-15 seconds each
- **Solution implemented**:
  - **Extended CFS lock timeout**: Added `storage_lock_timeout` property (default 120s, range 10-600s)
  - **Ephemeral WebSocket connections**: Write operations now use isolated connections to prevent response interleaving
  - **RFC 6455 compliance**: WebSocket close frames now properly formatted

#### **New Configuration Options**
- `storage_lock_timeout` - Configurable Proxmox CFS lock timeout for bulk provisioning scenarios

#### **Technical Changes**
- Added `_ws_open_ephemeral()` and `_ws_close_ephemeral()` for isolated write connections
- Added `_api_call_write()` wrapper routing writes through ephemeral connections
- Updated all write helpers: dataset, extent, targetextent, snapshot, bulk operations
- Fixed `_delete_dataset_with_retry()` to use ephemeral connections for consistency

---

## Version 1.1.13 (December 2, 2025)

### 🐛 **Critical Bug Fix: Dataset Deletion Race Condition (Issue #45)**

#### **Fixed race condition causing "PoolDataset does not exist" errors and VM crashes**
- **Problem**: VM deletion operations failed with `[ENOENT] PoolDataset does not exist` errors, followed by kernel `access beyond end of device` errors that crashed all VMs on the node
- **Root cause**: Plugin attempted to delete datasets while kernel still had active device references, causing TrueNAS to report dataset as "busy" but return misleading "does not exist" error
- **Impact**: VM deletions would fail and corrupt SCSI subsystem state, causing IO errors on all active VMs
- **Solution implemented**:
  - **Inverted deletion sequence**: Devices are now fully disconnected BEFORE dataset deletion
  - **Device cleanup verification**: Added `_verify_devices_disconnected()` helper to ensure devices are gone before proceeding (TrueNASPlugin.pm:1190-1217)
  - **Dataset deletion with retry**: Added `_delete_dataset_with_retry()` helper with exponential backoff for transient "busy" errors (TrueNASPlugin.pm:1239-1287)
  - **Error differentiation**: Added `_parse_dataset_error()` to distinguish "not found" (idempotent) from "busy" (retryable) errors (TrueNASPlugin.pm:1219-1237)
  - **Faster job polling**: Enhanced `_wait_for_job_completion()` with 100ms polling for first 5 seconds, then 1s (TrueNASPlugin.pm:1109-1170)
  - **Increased timeout**: Dataset deletion timeout increased from 20s to 30s for better reliability under load

#### **iSCSI Deletion Flow (Lines 3529-3593)**
**Before (BROKEN)**:
```
Capture devices → Delete extent/mapping → Delete dataset (RACE!) → Cleanup devices → Rescan
```

**After (FIXED)**:
```
Capture devices → Delete extent/mapping → Logout & cleanup devices → Verify cleanup → Delete dataset with retry → Rescan
```

#### **NVMe Deletion Flow (Lines 3713-3747)**
**Before (BROKEN)**:
```
Delete namespace → Disconnect (if needed) → Delete dataset (RACE!) → udevadm settle
```

**After (FIXED)**:
```
Delete namespace → Disconnect & verify → udevadm settle → Delete dataset with retry → udevadm settle
```

### 🔧 **Technical Details**
- Modified `_free_image_iscsi()` (TrueNASPlugin.pm:3373-3637)
  - Moved SCSI device cleanup to BEFORE dataset deletion (phase 4)
  - Added device disconnect verification with 5-second timeout
  - Replaced manual dataset deletion with retry helper
  - Removed old "retry after logout" code (no longer needed)
- Modified `_free_image_nvme()` (TrueNASPlugin.pm:3713-3750)
  - Added explicit disconnect verification before dataset deletion
  - Replaced manual dataset deletion with retry helper
- New constants (TrueNASPlugin.pm:58-62):
  - `DEVICE_CLEANUP_VERIFY_TIMEOUT_S = 5` - Device cleanup verification timeout
  - `DATASET_DELETE_RETRY_COUNT = 3` - Max retries for dataset deletion
  - `DATASET_DELETE_TIMEOUT_S = 30` - Increased from 20s

### 📊 **Impact**
- **Eliminates VM crashes**: No more "access beyond end of device" kernel errors during VM deletion
- **Fixes misleading errors**: Correctly handles TrueNAS "busy" vs "not found" errors
- **Better reliability**: Retry logic handles transient failures gracefully
- **Multipath compatibility**: Works correctly in cluster environments with multiple active sessions
- **Both transports**: Fix applies to both iSCSI and NVMe/TCP modes
- **Slight latency increase**: Dataset deletion takes 2-5 seconds longer but eliminates race condition

### ✅ **Validation**
- Tested single disk deletion (iSCSI) - completed successfully without errors
- Tested single disk deletion (NVMe) - completed successfully without errors
- Tested sequential 3-disk deletion (iSCSI) - all deleted without kernel errors
- Verified no "access beyond end of device" errors in kernel log
- Verified no "io-error" states on active VMs during deletions
- Tested on TrueNAS SCALE 25.10.0 with Proxmox VE 9.x cluster

---

## Version 1.1.12 (December 2, 2025)

### 🔧 **NVMe/TCP Device Matching Improvements**

#### **Improved NVMe namespace device discovery reliability**
- **Implemented three-tier device matching strategy in `_nvme_find_device_by_subsystem()`**
  - **Tier 1: NGUID matching** (primary) - Matches devices by NVMe Namespace GUID from TrueNAS API against sysfs
  - **Tier 2: NSID matching** (fallback) - Falls back to Namespace ID matching if API fails or NGUID unavailable
  - **Tier 3: Single device** (safe fallback) - Returns single device when only one namespace exists on subsystem
  - **Eliminated unreliable "newest device" timestamp fallback** - Removed race-condition-prone mtime-based selection
  - Modified `_nvme_find_device_by_subsystem` (lines 2450-2606)

#### **Critical Bug Fix: Device Name NSID Parsing**
- **Fixed incorrect NSID extraction from device names**
  - **Problem**: Plugin parsed NSID from device name pattern (e.g., `nvme3n5` → NSID 5), but device name suffix doesn't always match NSID
  - **Root cause**: Linux kernel assigns device names independently of namespace IDs
  - **Impact**: Could select wrong device when multiple namespaces exist on same subsystem
  - **Solution**: Now reads NSID directly from sysfs (`/sys/block/nvmeXnY/nsid`) instead of parsing device name
  - **Example**: `nvme3n5` may have NSID=3 (not 5), `nvme3n10` may have NSID=8 (not 10)

### 🔧 **Technical Details**
- **NGUID validation**: Added format validation for API-returned NGUID (UUID format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
- **Enhanced logging**: Added debug logging for each matching tier with device details and failure reasons
- **Backward compatibility**: Gracefully falls back to NSID matching for older TrueNAS versions without `device_nguid` field
- **Multipath support**: NGUID and NSID are identical across all controllers, ensuring correct device selection

### 📊 **Impact**
- **Eliminates race conditions**: NGUID matching is unambiguous and doesn't rely on timing or device creation order
- **Fixes device selection bug**: Corrects NSID matching that could fail due to name parsing error
- **Better diagnostics**: Enhanced logging helps troubleshoot device discovery issues
- **Production-ready**: Tested with multiple simultaneous volumes on same subsystem

### ✅ **Validation**
- Tested single volume activation - NGUID matched correctly
- Tested 3 simultaneous volumes on same subsystem - all matched without confusion
- Verified NGUID from TrueNAS API matches sysfs NGUID exactly
- Confirmed no device selection errors with multiple namespaces

---

## Version 1.1.11 (December 1, 2025)

### 🐛 **Critical Bug Fix: Multi-Disk Clone Size Mismatch**

#### **Fixed race condition in clone operations causing size mismatches**
- **Fixed `_clone_image_nvme()` and `_clone_image_iscsi()` to wait for ZFS clone job completion**
  - **Problem**: Plugin created namespaces/extents immediately after calling clone API, before async job completed
  - **Impact**: Multi-disk VM clones failed with "output file is smaller than input file" on second and subsequent disks
  - **Root cause**: Namespace/extent creation proceeded while ZFS clone operation was still in progress
  - **Solution implemented**:
    - Added job completion waiting using existing `_wait_for_job_completion()` helper
    - 30-second timeout for clone operations
    - Verifies cloned zvol exists and has correct size before proceeding
    - Applies to both iSCSI and NVMe/TCP transport modes
    - Modified `_clone_image_nvme` (lines 4408-4424) and `_clone_image_iscsi` (lines 4260-4270)

### 🔧 **Technical Details**
- Captures return value from `_tn_dataset_clone()` instead of ignoring it
- Detects if return value is a job ID (numeric pattern matching)
- Waits for job completion with proper error handling and logging
- Pattern matches existing `alloc_image()` job completion handling
- Added zvol verification step to ensure clone is ready before exposure
- Minimal change approach - reuses existing proven helpers

### 📊 **Impact**
- **Eliminated multi-disk clone failures**: All disks now clone successfully regardless of count
- **Both transport modes**: Fix applies to both iSCSI and NVMe/TCP
- **Consistent behavior**: Both transport modes now handle async operations identically
- **No API changes**: Existing configurations continue to work without modification

### ✅ **Validation**
- Tested NVMe/TCP multi-disk clone (2 disks): Both disks cloned to 100% successfully
- Tested iSCSI multi-disk clone (2 disks): Both disks cloned to 100% successfully
- Dev test script #25 (Multi-Disk Advanced Operations: Clone): PASSED
- Verified no "output file is smaller than input file" errors
- Confirmed cloned VMs boot correctly with all disks accessible

---

## Version 1.1.10 (November 30, 2025)

### 🐛 **Critical Bug Fix: VM Migration Device Wait**

#### **Fixed VM Migration for Both iSCSI and NVMe-oF-TCP**
- **Modified `activate_volume` function to properly wait for block devices during migration** (GitHub Issue #44)
  - **Problem**: VM migrations failed because `activate_volume` only waited 250 microseconds for block devices to appear
  - **Impact**: All VM migrations to both iSCSI and NVMe-oF-TCP storage failed with "Could not locate device" errors
  - **Root cause**: Volume metadata was transferred to destination node, but QEMU tried to start before block device path existed
  - **Solution implemented** (lines 4155-4198):
    - Added `parse_volname` call to extract LUN (iSCSI) or device UUID (NVMe) metadata from volname
    - For iSCSI: Now calls `_device_for_lun()` which waits up to 5 seconds for `/dev/disk/by-path/` device to appear
    - For NVMe-oF-TCP: Now calls `_nvme_device_for_uuid()` which waits up to 5 seconds for namespace device to appear
    - Added proper error handling with detailed troubleshooting messages if device wait times out
    - Added debug logging at level 2 for device wait operations

### 🔧 **Technical Details**
- Reuses existing proven device wait helpers that work correctly during normal volume creation
- No new functions added - minimal change approach
- Progressive intervention during wait (udev settle, session rescan, controller rescan)
- Both online and offline migration scenarios validated
- Works with multipath configurations

### 📊 **Impact**
- **Migration reliability**: Enables reliable VM migration for both iSCSI and NVMe-oF-TCP storage
- **No breaking changes**: Backward compatible with existing configurations
- **Proper error reporting**: If device wait times out, provides detailed troubleshooting guidance
- **Test coverage**: Successfully tested on 3-node cluster with bidirectional migrations

### ✅ **Validation**
- Tested iSCSI offline migration (bidirectional)
- Tested NVMe-oF-TCP offline migration (bidirectional)
- Tested cross-transport migrations (iSCSI ↔ NVMe-oF-TCP)
- Tested 3-node migration circuit
- Verified device wait logic (up to 5 seconds, proper error propagation)
- Confirmed no regressions to normal volume creation workflow

### 🐛 **Critical Bug Fix: Volume Resize Race Condition**

#### **Fixed race condition in volume resize causing VM crashes**
- **Fixed `volume_resize()` function to wait for TrueNAS job completion** - Plugin now waits for resize operations to complete before rescanning iSCSI/NVMe sessions
  - **GitHub Issue**: [#45](https://github.com/WarlockSyno/TrueNAS-Proxmox-VE-Storage-Plugin/issues/45)
  - **Problem**: Plugin rescanned iSCSI/NVMe sessions immediately after calling TrueNAS resize API, before the async job completed
  - **Impact**: Caused "access beyond end of device" kernel errors, I/O errors, and VM crashes during disk resize operations in multipath configurations
  - **Root cause**: SCSI layer queried device size while TrueNAS was still processing the resize job, resulting in size mismatches
  - **Solution implemented**:
    - Added job completion waiting using existing `_handle_api_result_with_job_support()` helper (lines 1534-1539)
    - 60-second timeout for resize operations (matching snapshot/delete patterns)
    - Proper error handling with logging on job failures
    - Only rescans iSCSI/NVMe sessions after confirmed job completion
    - Applies to both iSCSI and NVMe/TCP transport modes

### 🔧 **Technical Details**
- Modified `volume_resize()` function in TrueNASPlugin.pm
  - Capture API call result instead of ignoring return value (line 1527)
  - Wait for async job completion before device rescan (lines 1534-1539)
  - Die with clear error message if resize job fails
  - Pattern follows established snapshot/delete implementations
  - 5 lines added, 1 line modified - minimal change approach

### 📊 **Impact**
- **Eliminated resize crashes**: No more "access beyond end of device" errors during resize operations
- **Multipath compatibility**: Resize operations now safe in multipath configurations
- **Both transport modes**: Fix applies to both iSCSI and NVMe/TCP
- **No API changes**: Existing configurations continue to work without modification
- **Production ready**: Tested on TrueNAS SCALE 25.10.0 with both transport modes

### ✅ **Validation**
- Tested iSCSI mode: Successfully resized 10GB → 20GB without errors
- Tested NVMe/TCP mode: Successfully resized 10GB → 20GB without errors
- Verified no kernel errors in `dmesg` during or after resize
- Confirmed no VM crashes or I/O errors with active workloads during resize
- Multipath systems handle resize correctly without path failures


---

## Version 1.1.9 (November 22, 2025)

### 🧹 **SCSI Device Cleanup After iSCSI Disk Deletion**

#### **Automatic Cleanup of Orphaned SCSI Devices**
- **Added automatic SCSI device cleanup to `_free_image_iscsi` function** - Prevents "ghost" SCSI devices after disk deletion
  - **Problem**: When disks are deleted via the plugin, the Linux SCSI layer retains stale device entries with size=0
  - **Impact**: Stale devices caused "Read Capacity failed" kernel errors on every iSCSI session rescan (10-20 log messages per stale device)
  - **Solution implemented**:
    - Captures by-path symlinks and resolves device names BEFORE any deletion/logout occurs (lines 3202-3226)
    - After TrueNAS deletion succeeds, writes `1` to `/sys/block/<dev>/device/delete` to remove orphaned SCSI devices (lines 3426-3443)
    - Best-effort cleanup - never fails the delete operation if SCSI cleanup fails
    - Handles multipath configurations (cleans up all path devices)
    - Debug logging at level 2 for cleanup operations

### 🔧 **Technical Details**
- Device capture occurs at function entry before any API calls
- Uses `Cwd::abs_path()` to resolve symlinks safely
- Validates device names match expected `sd[a-z]{1,4}` pattern
- Cleanup runs regardless of logout status (handles both logged-in and logged-out scenarios)
- All cleanup operations wrapped in `eval {}` for safety

### 📊 **Impact**
- **Cleaner kernel logs**: No more "Read Capacity failed" errors from deleted LUNs
- **Faster rescans**: iSCSI session rescans no longer delayed by stale device error handling
- **Test reliability**: Eliminates test failures caused by stale SCSI device interference
- **Transparent operation**: No configuration required, cleanup happens automatically

### ✅ **Validation**
- Tested disk deletion flow with SCSI device verification
- Confirmed no stale devices remain after deletion
- Verified kernel logs show no errors on subsequent session rescans

---

## Version 1.1.8 (November 22, 2025)

### 🔧 **Debug Logging Standardization**

#### **Consistent Debug Logging Coverage**
- **Standardized all debug logging to use `_log()` helper** with configurable verbosity levels
  - **Problem**: Inconsistent logging - some functions used direct `syslog()` calls bypassing debug level settings, others had no logging at all
  - **Solution implemented**:
    - Converted ~50 direct `syslog()` calls to `_log($scfg, $level, $priority, $message)`
    - Added `[TrueNAS]` prefix to all ~134 log messages for easy grep filtering
    - Added entry/completion logging to previously unlogged functions

### 📊 **Logging Level Assignments**
| Level | Usage | Examples |
|-------|-------|----------|
| 0 | Errors (always logged) | API failures, timeouts, authentication errors |
| 1 | Operations (debug=1) | Function entry, job completion, major operations |
| 2 | Verbose (debug=2) | API call details, internal state, polling status |

### 🆕 **Functions with New Logging**
- `volume_resize` - entry and completion logging
- `volume_snapshot_rollback` - entry and completion logging
- `volume_snapshot_info` - query logging (level 2)
- `clone_image`, `_clone_image_iscsi`, `_clone_image_nvme` - entry logging
- `activate_volume` - activation logging (level 2)

### 🔄 **Functions with Converted Logging**
- `_retry_with_backoff` - retry attempts and errors
- `_wait_for_job_completion` - job status polling
- `_handle_api_result_with_job_support` - async job handling
- `volume_snapshot`, `volume_snapshot_delete` - snapshot operations
- `_bulk_snapshot_delete` - bulk operations
- `_tn_dataset_delete` - dataset deletion
- `_free_image_iscsi`, `_free_image_nvme` - volume deletion
- `status`, `activate_storage` - storage status checks
- `_ensure_target_visible` - pre-flight checks
- `alloc_image` - volume allocation
- NVMe functions - connect, disconnect, namespace operations

### 📋 **Usage**
```bash
# Enable light debug logging
pvesm set <storage-id> --debug 1

# Enable verbose debug logging
pvesm set <storage-id> --debug 2

# Filter TrueNAS logs (works regardless of calling process)
journalctl --since '10 minutes ago' | grep '\[TrueNAS\]'
```

### ✅ **Validation**
- Perl syntax verified on Proxmox VE 9.x
- All log messages include `[TrueNAS]` prefix
- Appropriate debug levels assigned per message type

---

## Version 1.1.7 (November 22, 2025)

### 🔧 **Installer Improvements**

#### **Blocksize Default Case Fix**
- **Changed default blocksize from lowercase `16k` to uppercase `16K`** in installer
  - **Problem**: Installer used lowercase blocksize defaults which could cause issues with older plugin versions
  - **Locations fixed**:
    - `generate_storage_config()` function default parameter
    - `display_edit_config()` function default fallback
    - Interactive storage configuration prompt and default
  - **Impact**: New installations will use properly formatted uppercase blocksize values

---

## Version 1.1.6 (November 14, 2025)

### 🐛 **Critical Bug Fixes**

#### **Weight Volume Protection and Self-Healing**
- **Fixed weight zvol deletion vulnerability** - Plugin now prevents accidental deletion and automatically recreates weight volume
  - **Problem**: Weight volume (`pve-plugin-weight`) could be manually deleted, causing iSCSI target to become undiscoverable
  - **Root cause**: No safeguards prevented deletion of critical infrastructure volume that maintains target visibility
  - **Impact**: If weight volume was deleted and all VM volumes removed, iSCSI target would disappear from discovery, causing storage outages
  - **Solution implemented**:
    - Added deletion guard that dies with error when attempting to delete weight volume (line 3169)
    - Implemented self-healing operation that verifies weight volume after every volume deletion (lines 3408-3419)
    - Self-healing automatically recreates weight volume if missing via `_ensure_target_visible()`
    - Runs before `logout_on_free` to prevent race conditions
    - Non-fatal warning if self-healing fails (doesn't block volume deletion)

### 🔧 **Technical Details**
- Modified `free_image()` function (lines 3169-3171, 3408-3419)
  - Added weight volume deletion protection with explanatory error message
  - Integrated self-healing verification after successful volume deletion
  - Positioned self-healing before logout logic to ensure weight exists before session cleanup
- Enhanced error messages explain weight volume purpose and importance

### 📊 **Impact**
- **Storage reliability**: Prevents storage outages caused by missing weight volumes
- **Automatic recovery**: Self-healing recreates weight volume when needed, no manual intervention required
- **Safety**: Weight volume cannot be accidentally deleted through normal plugin operations
- **Graceful degradation**: Self-healing failures log warnings but don't block volume deletion operations

### ✅ **Validation**
- Tested weight volume deletion protection (properly rejects deletion attempts)
- Verified self-healing recreates weight volume after all VM volumes deleted
- Confirmed no race conditions between weight creation and session logout

---

## Version 1.1.5 (November 8, 2025)

### 🐛 **Critical Bug Fix: Snapshot Error Handling**

#### **Fixed silent snapshot creation failures on multi-disk VMs**
- **Fixed `volume_snapshot()` function to properly validate API responses** - Plugin now ensures snapshot creation succeeds before reporting success to Proxmox
  - **Problem**: Function ignored API call results and always returned success, causing VM lock states on multi-disk VMs
  - **Impact**: When snapshot creation failed on TrueNAS, Proxmox thought it succeeded, resulting in orphaned snapshots and locked VMs
  - **Root cause**: `volume_snapshot()` called `_api_call()` but ignored the return value completely
  - **Solution implemented**:
    - Captures the API call result
    - Validates result using `_handle_api_result_with_job_support()` for proper async operation handling
    - Dies with clear error message if snapshot creation fails (prevents silent failures)
    - Logs all snapshot operations to syslog for audit trails
    - Prevents VM lock states caused by inconsistent Proxmox/TrueNAS snapshot state

### 🔍 **Audit Trail Improvements**
- All snapshot operations now logged via syslog:
  - `Creating ZFS snapshot: <full-snapshot-name>`
  - `ZFS snapshot created successfully: <full-snapshot-name>`
  - `Failed to create snapshot <name>: <error-message>`
- Enables better troubleshooting of snapshot failures in production

### 📋 **Testing**
- Comprehensive multi-disk snapshot test integrated into plugin test suite
- Validates atomic snapshot operations across iSCSI and NVMe storage
- Snapshot creation/deletion verified on test environments

---

## Version 1.1.4 (November 8, 2025)

### 🐛 **Bug Fixes**

#### **WebSocket Message Fragmentation**
- **Fixed truncated API responses with WebSocket transport** - Plugin now properly handles fragmented WebSocket messages
  - **Error resolved**: Incomplete or truncated JSON responses causing API operation failures
  - **Issue**: Large API responses (lengthy dataset lists, extensive configuration data) were truncated when split across multiple WebSocket frames
  - **Root cause**: WebSocket receiver returned immediately after first frame without checking for continuation frames
  - **Impact**: Operations with large responses failed with JSON parse errors or incomplete data
  - **Solution**: Implemented proper WebSocket frame fragmentation handling
    - Accumulates continuation frames (opcode 0x00) until FIN bit is set
    - Supports both fragmented and unfragmented text frames
    - Only returns complete messages after all fragments received
    - Handles ping/pong and close frames during fragmented message reception

### 🔧 **Technical Details**
- Modified `_ws_recv_text()` function (lines 785-845)
  - Added message accumulator for multi-frame messages
  - Proper handling of continuation frames
  - FIN bit checking to detect message completion

---

## Version 1.1.3 (November 5, 2025)

### 🚀 **Major Performance Improvements**

#### **List Performance - N+1 Query Pattern Elimination**
- **Dramatic speed improvements for storage listing operations** - Up to 7.5x faster for large deployments
  - **10 volumes**: 2.3s → 1.7s (1.4x faster, 28% reduction)
  - **50 volumes**: 6.7s → 1.8s (3.7x faster, 73% reduction)
  - **100 volumes**: 18.2s → 2.4s (7.5x faster, 87% reduction)
  - **Per-volume cost**: 182ms → 24ms (87% reduction)
  - **Extrapolated 1000 volumes**: ~182s (3min) → ~24s (8x improvement)
- **Root cause**: `list_images` was making individual `_tn_dataset_get()` API calls for each volume (O(n) API requests)
- **Solution**: Implemented batch dataset fetching with single `pool.dataset.query` API call
  - Fetches all child datasets at once with TrueNAS query filter
  - Builds O(1) hash lookup table for dataset metadata
  - Falls back to individual API calls if batch fetch fails
- **Impact**:
  - Small deployments (10 volumes): Modest improvement due to batch fetch overhead
  - Large deployments (100+ volumes): Dramatic improvement as N+1 elimination fully realized
  - API efficiency: Changed from O(n) API calls to O(1) API call
  - Web UI responsiveness: Storage views load 7.5x faster for large environments
  - Reduced TrueNAS API load: 87% fewer API calls during list operations

#### **iSCSI Snapshot Deletion Optimization**
- **Brought iSCSI to parity with NVMe recursive deletion** - Consistent ~3 second deletion regardless of snapshot count
  - Previously: Sequential snapshot deletion loop (50+ API calls for volumes with many snapshots)
  - Now: Single recursive deletion (`recursive => true` flag) deletes all snapshots atomically
  - Matches NVMe transport behavior (already optimized)
  - Eliminates 50+ API calls for volumes with 50+ snapshots

### ✨ **Code Quality Improvements**

#### **Normalizer Utility Extraction**
- **Eliminated duplicate code across codebase** - Extracted `_normalize_value()` utility function
  - Removed 8 duplicate normalizer closures implementing identical logic
  - Single source of truth for TrueNAS API value normalization
  - Handles mixed response formats: scalars, hash with parsed/raw fields, undefined values
  - Bug fixes now apply consistently across all call sites
  - Reduced codebase by ~50 lines of duplicate code

#### **Performance Constants Documentation**
- **Documented timing parameters with rationale** - Defined 7 named constants for timeouts and delays
  - `UDEV_SETTLE_TIMEOUT_US` (250ms) - udev settle grace period
  - `DEVICE_READY_TIMEOUT_US` (100ms) - device availability check
  - `DEVICE_RESCAN_DELAY_US` (150ms) - device rescan stabilization
  - `DEVICE_SETTLE_DELAY_S` (1s) - post-connection/logout stabilization
  - `JOB_POLL_DELAY_S` (1s) - job status polling interval
  - `SNAPSHOT_DELETE_TIMEOUT_S` (15s) - snapshot deletion job timeout
  - `DATASET_DELETE_TIMEOUT_S` (20s) - dataset deletion job timeout
- **Impact**: Self-documenting code, easier performance tuning, prevents arbitrary value changes

### 🔧 **Technical Details**

**Modified functions**:
- `_list_images_iscsi()` (lines 3529-3592) - Batch dataset fetching with hash lookup
- `_list_images_nvme()` (lines 3650-3707) - Batch dataset fetching with hash lookup
- `_free_image_iscsi()` - Changed to recursive deletion (matches NVMe behavior)
- `_normalize_value()` (lines 35-44) - New utility function for API response normalization

**Performance testing**:
- Benchmark script created for automated testing with 10/50/100 volumes
- Baseline measurements established before optimization
- Post-optimization measurements confirmed 7.5x improvement for 100 volumes
- All tests validated on TrueNAS SCALE 25.10.0 with NVMe/TCP transport

### 📊 **Real-World Impact**

| Deployment Size | Before | After | Time Saved | Speedup |
|-----------------|--------|-------|------------|---------|
| Small (10 VMs) | 2.3s | 1.7s | 0.6s | 1.4x |
| Medium (50 VMs) | 6.7s | 1.8s | 4.9s | 3.7x |
| Large (100 VMs) | 18.2s | 2.4s | 15.8s | 7.5x |
| Enterprise (1000 VMs) | ~182s (3min) | ~24s | ~158s (2.6min) | ~8x |

**User experience improvements**:
- Proxmox Web UI storage view refreshes 7.5x faster for large deployments
- Reduced risk of timeouts in large environments
- Lower API load on TrueNAS servers (87% fewer API calls)
- Better responsiveness during storage operations

---

## Version 1.1.2 (November 4, 2025)

### 🐛 **Critical Bug Fixes**

#### **NVMe Device Detection - Support for Controller-Specific Naming**
- **Fixed NVMe device detection to support multipath controller-specific naming** - Device discovery now works with both standard and controller-specific NVMe device paths
  - **Error resolved**: "Could not locate NVMe device for UUID <uuid>"
  - **Issue**: Device detection only scanned `/sys/class/nvme-subsystem/` which doesn't contain controller-specific devices (`nvme3c3n1`, `nvme3c4n1`)
  - **Root cause**: When NVMe multipath is active, Linux creates controller-specific devices that exist in `/sys/block` but not in subsystem directory
  - **Impact**: NVMe disk creation failed to find newly created namespaces after TrueNAS NVMe-oF service created them
  - **Solution**: Rewrote device discovery to scan `/sys/block` directly
    - Matches both standard (`nvme3n1`) and controller-specific (`nvme3c3n1`) device naming patterns
    - Verifies each device belongs to our subsystem by checking subsystem NQN in sysfs
    - Tries to match by NSID from TrueNAS API first
    - Falls back to "newest device" detection (created within last 10 seconds) - **Note**: This fallback was improved in v1.1.12 with NGUID matching and eliminated timestamp-based selection
    - Returns actual device path like `/dev/nvme3n1` or `/dev/nvme3c3n1`
  - **Implementation**: See `_nvme_find_device_by_subsystem()` (TrueNASPlugin.pm lines 2450-2606 in v1.1.12+)

#### **Multipath Portal Login**
- **Fixed multipath failing to connect to all portals** - Storage now establishes sessions to ALL configured portals
  - **Issue**: `_iscsi_login_all()` short-circuited when ANY session existed, never connecting to additional portals
  - **Root cause**: Function returned early if `_target_sessions_active()` found any session, without checking if all configured portals were connected
  - **Impact**: Multipath configurations only connected to primary `discovery_portal`, never logged into additional portals in `portals` list, defeating multipath redundancy
  - **Solution**: Added `_all_portals_connected()` function
    - Checks each configured portal (discovery_portal + portals list) individually
    - Verifies active iSCSI session exists to each portal
    - Only skips login when ALL portals have active sessions
    - Ensures proper multipath setup with multiple paths for redundancy

### ✨ **Enhancements**

#### **NVMe/TCP Automatic Multipath Portal Login**
- **Added automatic portal login for NVMe/TCP multipath configurations** - NVMe storage now automatically connects to all configured portals, matching iSCSI behavior
  - **Feature**: Plugin ensures all NVMe portals are connected during storage and volume activation
  - **Benefit**: Provides true multipath redundancy for NVMe/TCP storage with multiple I/O paths
  - **Configuration**: Use `discovery_portal` for primary portal and `portals` for additional portals (comma-separated)
  - **Example**: `discovery_portal 10.20.30.20:4420` + `portals 10.20.30.20:4420,10.20.31.20:4420`
  - **Automatic activation**: NVMe portals connect when:
    - Storage is activated (`activate_storage`)
    - Volumes are activated (`activate_volume`)
    - Namespaces are created or accessed
  - **Multipath support**: Works with native NVMe multipath (ANA) for automatic failover and load balancing
  - **Validation**: Successfully tested with 2-portal configuration, both portals connect automatically after disconnect

### 🔧 **Technical Details**
- **New functions added**:
  - `_nvme_find_device_by_subsystem()` (lines 2450-2606 in v1.1.12+) - Scans `/sys/block` for NVMe devices matching subsystem NQN, handles both standard and controller-specific naming, uses three-tier matching (NGUID → NSID → single device)
  - `_nvme_get_namespace_info()` (lines 2469-2482) - Queries TrueNAS WebSocket API for namespace details by device_uuid
  - `_all_portals_connected()` (lines 2018-2047) - Validates that all configured portals have active iSCSI sessions
- **Modified `_nvme_device_for_uuid()`** (lines 2484-2565) - Now calls `_nvme_find_device_by_subsystem()` for device discovery instead of checking `/dev/disk/by-id/nvme-uuid.*`
- **Modified `_iscsi_login_all()`** (line 2052) - Changed from `_target_sessions_active()` to `_all_portals_connected()` for proper multipath portal checking

### 📊 **Impact**
- **NVMe storage**: Device allocation and detection now works correctly with multipath controllers
- **Multipath iSCSI**: All configured portals connect properly, providing true redundancy
- **Testing**: Successfully tested allocation, device detection, and deletion with TrueNAS SCALE 25.10.0
---

## Version 1.1.1 (November 1, 2025)

### 🔧 **Transport Enhancements: NVMe/iSCSI Feature Parity**

Significant improvements to both NVMe/TCP and iSCSI transports, bringing NVMe to feature parity with the mature iSCSI implementation.

#### **NVMe/TCP Improvements**
- **Added subsystem validation to pre-flight checks** - Validates subsystem existence before allocation, providing early error detection similar to iSCSI target validation
- **Fixed resize rescan bug** - Corrected critical bug where NVMe resize used subsystem NQN instead of device path for `nvme ns-rescan` command
- **Implemented force-delete retry logic** - Mirrors iSCSI's disconnect/retry behavior for "in use" errors, with intelligent multi-disk operation protection
- **Enhanced device readiness validation** - Progressive backoff strategy with block device checks (not just symlink existence), automatic controller rescans, and detailed troubleshooting output
- **Improved error messages** - Added comprehensive 5-step diagnostic guides with specific commands for troubleshooting device discovery failures

#### **iSCSI Improvements**
- **Added clone cleanup on failure** - Extent and target-extent mapping creation now properly clean up ZFS clone if operations fail, preventing orphaned resources

#### **Bug Fixes**
- Fixed NVMe resize using invalid NQN parameter for namespace rescan (now correctly uses controller device paths like `/dev/nvme3`)
- NVMe device validation now checks for actual block devices using `-b` flag, not just symlink existence
- Added proper progressive intervention during device wait (settle → rescan → trigger)

#### **Code Quality**
- Both transports now have equivalent robustness in error handling and retry logic
- Consistent cleanup patterns across clone operations in both iSCSI and NVMe
- Better multi-disk operation detection to avoid breaking concurrent tasks
- Enhanced logging with detailed operation context

---

## Version 1.1.0 (October 31, 2025)

### 🚀 **Major Feature: NVMe/TCP Transport Support**

Added native NVMe over TCP (NVMe/TCP) as an alternative transport mode to traditional iSCSI, providing significantly lower latency and reduced CPU overhead for modern infrastructures.

#### **Key Features**
- **Dual-transport architecture** - Choose between iSCSI (default, widely compatible) or NVMe/TCP (modern, high-performance)
- **Full lifecycle operations** - Complete support for volume create, delete, resize, list, clone, and snapshot operations
- **Native multipath** - NVMe/TCP native multipathing with multiple portal support
- **DH-HMAC-CHAP authentication** - Optional unidirectional or bidirectional authentication for secure connections
- **UUID-based device mapping** - Reliable device identification using `/dev/disk/by-id/nvme-uuid.*` paths
- **Automatic subsystem management** - Plugin creates and manages NVMe subsystems automatically via TrueNAS API

#### **Configuration**
New `transport_mode` parameter selects the storage protocol:
- `transport_mode iscsi` - Traditional iSCSI (default, backward compatible)
- `transport_mode nvme-tcp` - NVMe over TCP (requires TrueNAS SCALE 25.10+)

**NVMe/TCP-specific parameters:**
- `subsystem_nqn` - NVMe subsystem NQN (required, format: `nqn.YYYY-MM.domain:identifier`)
- `hostnqn` - NVMe host NQN (optional, auto-detected from `/etc/nvme/hostnqn`)
- `nvme_dhchap_secret` - Host authentication secret (optional DH-CHAP auth)
- `nvme_dhchap_ctrl_secret` - Controller authentication secret (optional bidirectional auth)

**Important notes:**
- `transport_mode` is **fixed** and cannot be changed after storage creation
- NVMe/TCP requires `api_transport ws` (WebSocket API transport)
- Different device naming: iSCSI uses `vol-<name>-lun<N>`, NVMe uses `vol-<name>-ns<UUID>`
- Default ports: iSCSI uses 3260, NVMe/TCP uses 4420

#### **Requirements**
- **TrueNAS**: SCALE 25.10.0 or later with NVMe-oF Target service enabled
- **Proxmox**: VE 9.x or later with `nvme-cli` package installed (`apt-get install nvme-cli`)
- **API Transport**: WebSocket required (`api_transport ws`) - REST API does not support NVMe operations

#### **Performance Characteristics**
Based on NVMe/TCP protocol advantages:
- **Lower latency**: 50-150μs vs iSCSI 200-500μs (typical)
- **Reduced CPU overhead**: No SCSI emulation layer
- **Better queue depth**: Native NVMe queuing (64K+ commands) vs iSCSI single queue
- **Native multipath**: Built-in multipathing without dm-multipath complexity

#### **📚 Documentation**
Comprehensive documentation added:
- **wiki/NVMe-Setup.md** - Complete setup guide with step-by-step TrueNAS and Proxmox configuration
- **wiki/Configuration.md** - Updated with NVMe/TCP parameter reference and examples
- **wiki/Troubleshooting.md** - Added NVMe-specific troubleshooting sections
- **storage.cfg.example** - Added NVMe/TCP configuration examples

#### **🔧 Technical Implementation**
- Lines 286-357: Configuration schema with transport mode and NVMe parameters
- Lines 540-598: Configuration validation with transport-specific checks
- Lines 2123-2424: NVMe helper functions (connection, device mapping, subsystem/namespace management)
- Lines 2782-2793: NVMe-specific volume allocation
- Lines 3084-3100: NVMe-specific volume deletion
- Lines 3298-3380: NVMe-specific volume listing

#### **Migration from iSCSI**
In-place migration is **not possible** due to:
- Volume naming format incompatibility (LUN numbers vs UUIDs)
- Device path differences (`/dev/disk/by-path/` vs `/dev/disk/by-id/nvme-uuid.*`)
- Transport mode marked as fixed in schema

**Migration path**: Create new NVMe storage with different storage ID, use `qm move-disk` to migrate VM disks individually.

#### **Validation and Testing**
- Verified on TrueNAS SCALE 25.10.0 with Proxmox VE 9.x
- Tested nvme-cli version 2.13 (git 2.13) with libnvme 1.13
- Validated DH-CHAP authentication (secret generation and configuration)
- Confirmed UUID-based device paths and multipath operation
- Verified all API endpoints (subsystem, namespace, port, host configuration)

---

## Version 1.0.8 (October 31, 2025)

### 🐛 **Bug Fix**
- **Fixed EFI VM creation with non-standard zvol blocksizes** - Plugin now automatically aligns volume sizes
  - **Error resolved**: "Volume size should be a multiple of volume block size"
  - **Issue**: EFI VMs require 528 KiB disks which don't align with common blocksizes (16K, 64K, 128K)
  - **Impact**: Users couldn't create UEFI/OVMF VMs when using custom `zvol_blocksize` configurations
  - **Affected operations**: Volume creation (`alloc_image`) for small disks like EFI variables

### 🔧 **Technical Details**
- Added `_parse_blocksize()` helper function (lines 91-105)
  - Converts blocksize strings (e.g., "128K", "64K") to bytes
  - Handles case-insensitive K/M/G suffixes
  - Returns 0 for invalid/undefined values
- Modified `alloc_image()` function (lines 2024-2038)
  - Automatically rounds up requested sizes to nearest blocksize multiple
  - Uses same modulo-based algorithm as existing `volume_resize()` function
  - Logs adjustments at info level: "alloc_image: size alignment: requested X bytes → aligned Y bytes"
- Maintains consistency with existing `volume_resize` alignment (lines 1307-1311)

### 📊 **Impact**
- **EFI/OVMF VM creation** - Now works seamlessly with any zvol blocksize configuration
- **Alignment is transparent** - No user intervention required, size adjustments logged automatically
- **No regression** - Standard disk sizes (1GB+) already aligned, no performance impact

### ✅ **Validation**
Tested with multiple blocksize configurations:
- 64K blocksize: 528 KiB → 576 KiB (aligned to 64K × 9)
- 128K blocksize: 528 KiB → 640 KiB (aligned to 128K × 5)

---

## Version 1.0.7 (October 23, 2025)

### 🐛 **Critical Bug Fix**
- **Fixed duplicate LUN mapping error** - Plugin now handles existing iSCSI configurations gracefully
  - **Error resolved**: "LUN ID is already being used for this target"
  - **Issue**: Plugin attempted to create duplicate target-extent mappings without checking for existing ones
  - **Impact**: Caused pvestatd crashes, prevented volume creation in environments with pre-existing iSCSI configs
  - **Affected operations**: Volume creation (`alloc_image`), volume cloning (`clone_image`), weight extent mapping
  - **Forum report**: https://forum.proxmox.com/threads/truenas-storage-plugin.174134/#post-810779

### 🔧 **Technical Details**
- Made all target-extent mapping operations **idempotent** (safe to call multiple times)
- Modified `alloc_image()` function (lines 2097-2130)
  - Now checks for existing mappings before attempting creation
  - Reuses existing mapping if found (with info logging)
  - Only creates new mapping when necessary
- Modified `clone_image()` function (lines 2973-3007)
  - Same idempotent logic applied to clone operations
  - Prevents duplicate mapping errors during VM cloning
- Enhanced `_tn_targetextent_create()` helper function (lines 1510-1531)
  - Returns existing mapping instead of attempting duplicate creation
  - Properly caches and invalidates mapping data
- Added debug logging for mapping creation decisions

### 📊 **Impact**
- **Environments with pre-existing iSCSI configurations** - No longer fail with validation errors
- **Systems with partial failed allocations** - Gracefully recover and reuse existing mappings
- **Multipath I/O setups** - Weight extent mapping now idempotent
- **Service stability** - Eliminates pvestatd crashes from duplicate mapping attempts

### ⚠️ **Deployment Notes**
- Update is backward compatible with existing configurations
- No manual cleanup required for existing mappings
- Recommended for all installations, especially those using shared TrueNAS systems

---

## Version 1.0.6 (October 11, 2025)

### 🚀 **Performance Improvements**
- **Optimized device discovery** - Progressive backoff strategy for faster iSCSI device detection
  - **Device discovery time: 10s → <1s** (typically finds device on first attempt)
  - Previously: Fixed 500ms intervals between checks, up to 10 seconds maximum wait
  - Now: Progressive delays (0ms, 100ms, 250ms) with immediate first check
  - More aggressive initial checks catch fast-responding devices immediately
  - Rescan frequency increased from every 2.5s (5 attempts) to every 1s (4 attempts)
  - Maximum wait time reduced from 10 seconds to 5 seconds
  - Real-world testing shows devices discovered on attempt 1 in typical scenarios

- **Faster disk deletion** - Reduced iSCSI logout wait times
  - **Per-deletion time savings: 2-4 seconds**
  - Logout settlement wait reduced from 2s to 1s (2 occurrences in deletion path)
  - Modern systems with faster udev settle times benefit immediately
  - Affects both extent deletion retry (line 2342) and dataset busy retry (line 2432)

### 🔧 **Technical Details**
- Modified device discovery loop in `alloc_image()` (lines 2154-2179)
  - Implements progressive backoff: immediate check → 100ms → 250ms intervals
  - First 3 attempts complete in 350ms instead of 1.5s
  - Rescans every 4 attempts (1s intervals) instead of every 5 attempts (2.5s intervals)
  - Attempt logging shows discovery speed for diagnostics
- Updated logout wait times in `free_image()` (lines 2342, 2432)
  - Reduced sleep(2) to sleep(1) in both extent deletion retry and dataset busy retry paths
  - Modern systems complete iSCSI logout and udev settlement faster than previous 2s assumption

### 📊 **Performance Impact**
- **Device discovery component**: 10s maximum → <1s typical (90%+ improvement)
- **Deletion operations**: 2-4s faster per operation
- **Best case**: Device appears immediately on first check (0ms wait vs 500ms minimum before)
- **Typical case**: Device discovered on attempt 1 within 100ms (was 2-3s on average)
- **Worst case**: Still bounded at 5 seconds maximum (was 10 seconds)

### ⚠️ **Important Notes**
- **Total allocation time** remains 7-8 seconds due to TrueNAS API operations (zvol creation ~2-3s, extent creation ~1-2s, LUN mapping ~1-2s, iSCSI login ~2s if needed)
- **Device discovery** is now effectively instant (attempt 1), removing what was previously a 2-10 second bottleneck
- **Further optimization** would require changes to TrueNAS API response times, which are outside plugin control

---

## Version 1.0.5 (October 10, 2025)

### 🐛 **Bug Fixes**
- **Fixed VMID filter in list_images** - Weight zvol and other non-VM volumes now properly excluded from VMID-specific queries
  - Previously: Volumes without VM naming pattern (e.g., pve-plugin-weight) appeared in ALL VMID filters
  - Root cause: Filter only checked `defined $owner` but skipped volumes where owner couldn't be determined
  - Now: When VMID filter is specified, skip volumes without detectable owner OR with non-matching owner
  - Impact: `pvesm list storage --vmid X` now only shows volumes belonging to VM X
  - Prevents test scripts and tools from accidentally operating on weight zvol

### 🔧 **Technical Details**
- Modified `list_images()` function (lines 2558-2562)
- Changed filter logic from `if (defined $vmid && defined $owner && $owner != $vmid)`
- To: `if (defined $vmid) { next MAPPING if !defined $owner || $owner != $vmid; }`
- Ensures volumes without vm-X-disk naming pattern are excluded when filtering by VMID

---

## Version 1.0.4 (October 9, 2025)

### ✨ **Improvements**
- **Dynamic Storage API version detection** - Plugin now automatically adapts to PVE version
  - Eliminates "implementing an older storage API" warning on PVE 9.x systems
  - Returns APIVER 12 on PVE 9.x, APIVER 11 on PVE 8.x
  - Safely detects system API version using eval to handle module loading
  - Prevents "newer than current" errors when running on older PVE versions
  - Seamless compatibility across PVE 8.x and 9.x without code changes

### 🐛 **Bug Fixes**
- **Fixed PVE 8.x compatibility** - Hardcoded APIVER 12 caused rejection on PVE 8.4
  - Plugin was returning version 12 on all systems, causing "newer than current (12 > 11)" error
  - Now dynamically returns appropriate version based on system capabilities

### 📖 **Documentation**
- Updated API version comments to reflect dynamic version detection

---

## Version 1.0.3 (October 8, 2025)

### ✨ **New Features**
- **Automatic target visibility management** - Plugin now automatically ensures iSCSI targets remain discoverable
  - Creates a 1GB "pve-plugin-weight" zvol when target exists but has no extents
  - Automatically creates extent and maps it to target to maintain visibility
  - Runs during storage activation as a pre-flight check
  - Implementation: `_ensure_target_visible()` function (lines 2627-2798)

### 🐛 **Bug Fixes**
- **Fixed Proxmox GUI display issues** - Added `ctime` (creation time) field to `list_images` output
  - Resolves epoch date display and "?" status marks in GUI
  - Extracts creation time from TrueNAS dataset properties
  - Includes multiple fallbacks for robust time extraction
  - Falls back to current time if no creation time available
  - Implementation: Enhanced `list_images()` function (lines 2554-2569)

### 📖 **Documentation**
- **Weight zvol behavior** - Documented automatic weight zvol creation to prevent target disappearance
- **GUI display fix** - Documented ctime field requirement for proper Proxmox GUI rendering

---

## Version 1.0.2 (October 7, 2025)

### 🐛 **Bug Fixes**
- **Fixed pre-flight check size calculation** - Corrected `_preflight_check_alloc` to treat size parameter as bytes instead of KiB, eliminating false "insufficient space" errors

### ✅ **Verification**
- **Confirmed all pre-flight checks working correctly**:
  - Space validation with 20% overhead calculation
  - API connectivity verification
  - iSCSI service status check
  - iSCSI target verification with detailed error messages
  - Parent dataset existence validation
- **Verified disk allocation accuracy** - 10GB disk request creates exactly 10,737,418,240 bytes on TrueNAS

---

## Version 1.0.1 (October 6, 2025)

### 🐛 **Bug Fixes**
- **Fixed syslog errors** - Changed all `syslog('error')` calls to `syslog('err')` (correct Perl Sys::Syslog priority)
- **Fixed syslog initialization** - Moved `openlog()` to BEGIN block for compile-time initialization
- **Fixed Perl taint mode security violations** - Added regex validation with capture groups to untaint device paths
- **Fixed race condition in volume deletion** - Added 2-second delay and `udevadm settle` after iSCSI logout
- **Fixed volume size calculation** - Corrected byte/KiB confusion in `_preflight_check_alloc` and `alloc_image`

### ⚠️ **Known Issues**
- **VM cloning size mismatch** - Clone operations fail due to size unit mismatch between `volume_size_info` and Proxmox expectations (investigation ongoing)

---

## Version 1.0.0 - Configuration Validation, Pre-flight Checks & Space Validation (October 5, 2025)

### 🔒 **Configuration Validation at Storage Creation**
- **Required field validation** - Ensures `api_host`, `api_key`, `dataset`, `target_iqn` are present
- **Retry parameter validation** - `api_retry_max` (0-10) and `api_retry_delay` (0.1-60s) bounds checking
- **Dataset naming validation** - Validates ZFS naming conventions (alphanumeric, `_`, `-`, `.`, `/`)
- **Dataset format validation** - Prevents leading/trailing slashes, double slashes, invalid characters
- **Security warnings** - Logs warnings when using insecure HTTP or WS transport instead of HTTPS/WSS
- **Implementation**: Enhanced `check_config()` function (lines 338-416)

### 📖 **Detailed Error Context & Troubleshooting**
- **Actionable error messages** - Every error includes specific causes and troubleshooting steps
- **Enhanced disk naming errors** - Shows attempted pattern, dataset, and orphan detection guidance
- **Enhanced extent creation errors** - Lists 4 common causes with TrueNAS GUI navigation paths
- **Enhanced LUN assignment errors** - Shows target/extent IDs and mapping troubleshooting
- **Enhanced target resolution errors** - Lists all available IQNs and exact match requirements
- **Enhanced device accessibility errors** - Provides iSCSI session commands and diagnostic steps
- **TrueNAS GUI navigation** - All errors include exact menu paths for verification
- **Implementation**: Enhanced error messages in `alloc_image`, `_resolve_target_id`, and related functions

### 🏥 **Intelligent Storage Health Monitoring**
- **Smart error classification** in `status` function distinguishes failure types
- **Connectivity issues** (timeouts, network errors) logged as INFO - temporary, auto-recovers
- **Configuration errors** (dataset not found, auth failures) logged as ERROR - needs admin action
- **Unknown failures** logged as WARNING for investigation
- **Graceful degradation** - Storage marked inactive vs throwing errors to GUI
- **No performance penalty** - Reuses existing dataset query, no additional API calls
- **Implementation**: Enhanced `status` function (lines 2517-2543)

### 🧹 **Cleanup Warning Suppression**
- **Intelligent ENOENT handling** in `free_image` suppresses spurious warnings
- **Idempotent cleanup** - Silently ignores "does not exist" errors for target-extents, extents, and datasets
- **Cleaner logs** - No false warnings during VM deletion when resources already cleaned up
- **Race condition safe** - Handles concurrent cleanup attempts gracefully
- **Implementation**: Enhanced error handling in `free_image` (lines 2190-2346)

### 🛡️ **Comprehensive Pre-flight Validation**
- **5-point validation system** runs before volume creation (~200ms overhead)
- **TrueNAS API connectivity check** - Verifies API is reachable via `core.ping`
- **iSCSI service validation** - Ensures iSCSI service is running before allocation
- **Space availability check** - Confirms sufficient space with 20% ZFS overhead margin
- **Target existence verification** - Validates iSCSI target is configured
- **Dataset validation** - Ensures parent dataset exists before operations

### 🔧 **Technical Implementation**
- New `_preflight_check_alloc()` function (lines 1403-1500) validates all prerequisites
- New `_format_bytes()` helper function for human-readable size display (lines 66-80)
- Integrated into `alloc_image()` at lines 1801-1814 before any expensive operations
- Returns array of errors with actionable troubleshooting steps
- Comprehensive logging to syslog for both success and failure cases

### 📊 **Impact**
- **Fast failure**: <1 second vs 2-4 seconds of wasted work on failures
- **Better UX**: Clear, actionable error messages with TrueNAS GUI navigation hints
- **No orphaned resources**: Prevents partial allocations (extents without datasets, etc.)
- **Minimal overhead**: Only ~200ms added to successful operations (~5-10%)
- **Production ready**: 3 of 5 checks leverage existing API calls (cached)

## Cluster Support Fix (September 2025)

### 🔧 **Cluster Environment Improvements**
- **Fixed storage status in PVE clusters**: Storage now correctly reports inactive status when TrueNAS API is unreachable from a node
- **Enhanced error handling**: Added syslog logging for failed status checks to aid troubleshooting
- **Proper cluster behavior**: Nodes without API access now show storage as inactive instead of displaying `?` in GUI

### 🛠️ **Tools**
- **Added `update-cluster.sh`**: Automated script to deploy plugin updates across all cluster nodes
- **Cluster deployment**: Simplifies plugin updates with automatic file copying and service restarts

### 📊 **Impact**
- **Multi-node clusters**: Storage status now displays correctly on all nodes
- **Diagnostics**: Failed status checks are logged to syslog for easier debugging
- **Deployment**: Faster plugin updates across cluster with automated script

## Performance & Reliability Improvements (September 2025)

### 🚀 **Major Performance Optimizations**
- **93% faster volume deletion**: 2m24s → 10s by eliminating unnecessary re-login after deletion
- **API result caching**: 60-second TTL cache for static data (targets, extents, global config)
- **Smart iSCSI session management**: Skip redundant logins when sessions already exist
- **Optimized timeouts**: Reduced aggressive timeout values from 90s+60s to 30s+20s+15s

### ✅ **Error Elimination**
- **Fixed iSCSI session rescan errors**: Added smart session detection before rescan operations
- **Eliminated VM startup failures**: Fixed race condition by verifying device accessibility after volume creation
- **Removed debug logging**: Cleaned up temporary debug output

### 🔧 **Technical Improvements**
- Added `_target_sessions_active()` function for intelligent session state detection
- Implemented automatic cache invalidation when extents/mappings are modified
- Enhanced device discovery with progressive retry logic (up to 10 seconds)
- Improved error handling with contextual information

### 📊 **Results**
- **Volume deletion**: 93% performance improvement
- **Volume creation**: Eliminated race condition causing VM startup failures
- **Error messages**: Removed spurious iSCSI rescan failure warnings
- **API efficiency**: Reduced redundant TrueNAS API calls through intelligent caching

### 🎯 **User Impact**
- **Administrators**: Dramatically faster storage operations with fewer error messages
- **Production environments**: More reliable VM management and storage workflows
- **Enterprise users**: Improved responsiveness and reduced operational friction