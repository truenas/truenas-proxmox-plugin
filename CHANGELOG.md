# TrueNAS Plugin Changelog

## Space Validation Enhancement (October 2025)

### 🛡️ **Pre-allocation Space Checks**
- **Added automatic space validation** before volume creation with 20% ZFS overhead margin
- **Detailed error messages** showing requested size, required size with overhead, available space, and shortfall
- **Audit logging** of all space check results for monitoring and capacity planning
- **Fail-fast behavior** prevents partial allocations when insufficient space exists

### 🔧 **Technical Implementation**
- New `_format_bytes()` helper function for human-readable size display
- Space check integrated into `alloc_image()` before disk name allocation
- Queries parent dataset available space via TrueNAS API
- Logs successful checks to syslog with detailed capacity information

### 📊 **Impact**
- **Better user experience**: Clear, actionable error messages instead of cryptic API failures
- **Prevents partial failures**: No more orphaned extents from failed dataset creation
- **Capacity planning**: Logged space checks provide historical usage data
- **Production ready**: 20% overhead accounts for ZFS metadata and snapshot space

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