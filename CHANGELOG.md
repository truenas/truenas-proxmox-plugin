# TrueNAS Plugin Changelog

## Configuration Validation, Pre-flight Checks & Space Validation (October 2025)

### 🔒 **Configuration Validation at Storage Creation**
- **Required field validation** - Ensures `api_host`, `api_key`, `dataset`, `target_iqn` are present
- **Retry parameter validation** - `api_retry_max` (0-10) and `api_retry_delay` (0.1-60s) bounds checking
- **Dataset naming validation** - Validates ZFS naming conventions (alphanumeric, `_`, `-`, `.`, `/`)
- **Dataset format validation** - Prevents leading/trailing slashes, double slashes, invalid characters
- **Security warnings** - Logs warnings when using insecure HTTP or WS transport instead of HTTPS/WSS
- **Implementation**: Enhanced `check_config()` function (lines 338-416)

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