# TrueNAS Plugin Changelog

## Version 1.0.4 (October 2025)

### ✨ **Improvements**
- **Updated Storage API version** - Plugin now declares APIVER 12 (PVE 9.x) compatibility
  - Eliminates "implementing an older storage API" warning on PVE 9.x systems
  - Maintains backward compatibility with PVE 8.x (APIVER 11) via APIAGE window
  - Changed `api()` method from returning 11 to 12
  - No functional changes - purely version declaration update

### 📖 **Documentation**
- Updated API version comments to reflect PVE 9.x support

---

## Version 1.0.3 (October 2025)

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

## Version 1.0.2 (October 2025)

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

## Version 1.0.1 (October 2025)

### 🐛 **Bug Fixes**
- **Fixed syslog errors** - Changed all `syslog('error')` calls to `syslog('err')` (correct Perl Sys::Syslog priority)
- **Fixed syslog initialization** - Moved `openlog()` to BEGIN block for compile-time initialization
- **Fixed Perl taint mode security violations** - Added regex validation with capture groups to untaint device paths
- **Fixed race condition in volume deletion** - Added 2-second delay and `udevadm settle` after iSCSI logout
- **Fixed volume size calculation** - Corrected byte/KiB confusion in `_preflight_check_alloc` and `alloc_image`

### ⚠️ **Known Issues**
- **VM cloning size mismatch** - Clone operations fail due to size unit mismatch between `volume_size_info` and Proxmox expectations (investigation ongoing)

---

## Version 1.0.0 - Configuration Validation, Pre-flight Checks & Space Validation (October 2025)

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