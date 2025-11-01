# TrueNAS Plugin Changelog

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