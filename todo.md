# TrueNAS Plugin Robustness Improvements TODO

This document contains suggested improvements to make the TrueNAS Proxmox Plugin more robust and reliable.

---

## 1. Configuration Validation on Load ⭐ HIGH PRIORITY

**Goal**: Validate critical configuration parameters at startup to catch misconfigurations early.

**Implementation Location**: `check_config` function (currently around line 247)

**Changes**:
```perl
sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;
    my $opts = $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);

    # Existing: Always set shared=1
    $opts->{shared} = 1;

    # NEW: Validate retry configuration
    if (defined $opts->{api_retry_max}) {
        die "api_retry_max must be between 0 and 10\n"
            if $opts->{api_retry_max} < 0 || $opts->{api_retry_max} > 10;
    }
    if (defined $opts->{api_retry_delay}) {
        die "api_retry_delay must be between 0.1 and 60 seconds\n"
            if $opts->{api_retry_delay} < 0.1 || $opts->{api_retry_delay} > 60;
    }

    # NEW: Validate that dataset doesn't contain invalid characters
    if ($opts->{dataset} && $opts->{dataset} =~ /[^a-zA-Z0-9_\-\/]/) {
        die "dataset name contains invalid characters\n";
    }

    # NEW: Warn if using insecure transport
    if ($opts->{api_scheme} && $opts->{api_scheme} =~ /^(ws|http)$/i) {
        syslog('warning', "Storage '$sectionId' using insecure transport: $opts->{api_scheme}");
    }

    return $opts;
}
```

**Benefits**:
- Catch configuration errors immediately instead of at first use
- Prevent invalid retry values that could cause issues
- Warn about security concerns (insecure transport)
- Validate dataset naming conventions

---

## 2. Connection Health Check ⭐ MEDIUM PRIORITY

**Goal**: Add a lightweight health check to verify TrueNAS connectivity.

**Implementation Location**: New function after `_clear_cache`

**Changes**:
```perl
sub _check_connection_health {
    my ($scfg) = @_;

    # Quick ping to verify TrueNAS is reachable
    eval {
        _api_call($scfg, 'core.ping', [],
            sub { _rest_call($scfg, 'GET', '/core/ping') });
    };

    if ($@) {
        syslog('warning', "TrueNAS connection health check failed: $@");
        return 0;
    }
    return 1;
}
```

**Benefits**:
- Early detection of connectivity issues
- Can be used in status checks to mark storage as inactive
- Lightweight operation (simple ping)

**Usage**:
- Call before expensive operations
- Add to status function for better health reporting

---

## 3. Dataset Space Check Before Allocation ✅ COMPLETED

**Goal**: Prevent volume allocation when insufficient space is available.

**Status**: Implemented in `alloc_image` function (lines 1700-1742)

**Implementation Location**: `alloc_image` function before zvol creation

**Implementation Details**:
- Added `_format_bytes()` helper function (lines 66-80) for human-readable size formatting
- Pre-allocation check runs before disk name allocation (lines 1700-1742)
- Checks available space from parent dataset via `_tn_dataset_get()`
- Requires 20% overhead for ZFS metadata and snapshots
- Detailed error message shows requested size, required size with overhead, available space, and shortfall
- Logs successful space checks to syslog for auditing

**Error Message Format**:
```
Insufficient space on dataset 'tank/proxmox':
  Requested: 10.00 GB (with 20% ZFS overhead: 12.00 GB)
  Available: 8.50 GB
  Shortfall: 3.50 GB
```

**Benefits**:
✅ Fail fast when space is insufficient
✅ Better error messages for users with exact calculations
✅ Prevents partial allocations that could fail later
✅ Includes 20% headroom for ZFS overhead
✅ Logs space check results for monitoring

---

## 4. Orphaned Resource Detection ⭐ MEDIUM PRIORITY

**Goal**: Detect and report orphaned iSCSI extents without corresponding datasets.

**Implementation Location**: New helper function, can be called from `status` or as a maintenance command

**Changes**:
```perl
sub _detect_orphaned_resources {
    my ($scfg) = @_;

    my @orphans;

    # Get all extents
    my $extents = eval { _tn_extents($scfg) } || [];

    # Get all datasets
    my $datasets = eval {
        _api_call($scfg, 'pool.dataset.query',
            [[ ["name", "^", "$scfg->{dataset}/"] ]],
            sub { _rest_call($scfg, 'GET', '/pool/dataset') })
    } || [];

    my %dataset_names = map { $_->{name} => 1 } @$datasets;

    # Find extents without corresponding datasets
    for my $extent (@$extents) {
        my $extent_name = $extent->{name};
        my $dataset_name = "$scfg->{dataset}/$extent_name";

        if (!$dataset_names{$dataset_name}) {
            push @orphans, {
                type => 'extent',
                name => $extent_name,
                id => $extent->{id}
            };
        }
    }

    return \@orphans;
}

# Optional: Add cleanup function
sub cleanup_orphaned_extents {
    my ($class, $storeid, $scfg) = @_;

    my $orphans = _detect_orphaned_resources($scfg);

    for my $orphan (@$orphans) {
        syslog('info', "Cleaning up orphaned extent: $orphan->{name} (id: $orphan->{id})");
        eval {
            _api_call($scfg, 'iscsi.extent.delete', [$orphan->{id}],
                sub { _rest_call($scfg, 'DELETE', "/iscsi/extent/id/$orphan->{id}") });
        };
        if ($@) {
            syslog('warning', "Failed to cleanup orphaned extent $orphan->{name}: $@");
        }
    }

    return scalar(@$orphans);
}
```

**Benefits**:
- Detect leaked resources from failed operations
- Optional automated cleanup
- Better storage hygiene
- Can be exposed as a CLI command

---

## 5. LUN Conflict Detection ⭐ MEDIUM PRIORITY

**Goal**: Check for LUN conflicts before creating iSCSI target mappings.

**Implementation Location**: `alloc_image` before creating targetextent (around line 1740)

**Changes**:
```perl
# Before creating targetextent in alloc_image:
my $existing_maps = _tn_targetextents($scfg) || [];
my %used_luns;

for my $map (@$existing_maps) {
    next if $map->{target} != $target_id;
    $used_luns{$map->{lunid}} = 1 if defined $map->{lunid};
}

# Verify our LUN isn't taken (if we're specifying one)
if (defined $tx_payload->{lunid} && $used_luns{$tx_payload->{lunid}}) {
    die "LUN $tx_payload->{lunid} already in use on target\n";
}

# Log LUN assignment for debugging
syslog('info', "Creating targetextent mapping with LUN " .
    ($tx_payload->{lunid} // 'auto-assigned'));
```

**Benefits**:
- Prevents LUN conflicts
- Better logging for troubleshooting
- Clearer error messages when conflicts occur

---

## 6. WebSocket Connection Staleness Check ⭐ LOW PRIORITY

**Goal**: Refresh WebSocket connections that are too old to prevent issues with long-lived connections.

**Implementation Location**: `_ws_get_persistent` function (around line 530)

**Changes**:
```perl
sub _ws_get_persistent($scfg) {
    my $key = _ws_connection_key($scfg);
    my $conn = $_ws_connections{$key};

    # Test if existing connection is still alive
    if ($conn && $conn->{sock}) {
        # NEW: Check connection age
        if ($conn->{created} && (time() - $conn->{created}) > 3600) {
            # Connection older than 1 hour, refresh it
            syslog('info', "Refreshing stale WebSocket connection for $key");
            eval { $conn->{sock}->close() };
            delete $_ws_connections{$key};
            $conn = undef;
        }

        # Existing ping test
        if ($conn) {
            eval {
                _ws_rpc($conn, {
                    jsonrpc => "2.0", id => 999999, method => "core.ping", params => [],
                });
            };
            if ($@) {
                # Connection is dead, remove it
                delete $_ws_connections{$key};
                $conn = undef;
            }
        }
    }

    # Create new connection if needed
    if (!$conn) {
        $conn = _ws_open($scfg);
        $conn->{created} = time(); # NEW: Track creation time
        $_ws_connections{$key} = $conn if $conn;
    }

    return $conn;
}
```

**Benefits**:
- Prevents issues with stale connections
- Proactive connection refresh
- Better connection lifecycle management

---

## 7. Rate Limit Backoff Improvement ⭐ LOW PRIORITY

**Goal**: Better detection and handling of rate limiting errors.

**Implementation Location**: `_is_retryable_error` function (around line 66)

**Changes**:
```perl
# In _is_retryable_error function:

# Retry on network errors, timeouts, connection issues
return 1 if $error =~ /timeout|timed out/i;
return 1 if $error =~ /connection refused|connection reset|broken pipe/i;
return 1 if $error =~ /network is unreachable|host is unreachable/i;
return 1 if $error =~ /temporary failure|service unavailable/i;
return 1 if $error =~ /502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout/i;
return 1 if $error =~ /rate limit|too many requests|429/i;  # UPDATED: More comprehensive
return 1 if $error =~ /ssl.*error/i;
return 1 if $error =~ /connection.*failed/i;
```

**Benefits**:
- Better detection of HTTP 429 errors
- Catches "too many requests" messages
- More resilient to rate limiting

---

## 8. Timeout Configuration ⭐ MEDIUM PRIORITY

**Goal**: Allow users to configure API timeouts for different network conditions.

**Implementation Location**:
1. Add to `properties` function (around line 146)
2. Use in `_ua` function (around line 339)

**Changes**:
```perl
# In properties():
api_timeout => {
    description => "API call timeout in seconds.",
    type => 'integer', optional => 1, default => 30,
},

# In options():
api_timeout => { optional => 1 },

# In _ua() function:
sub _ua($scfg) {
    my $ua = LWP::UserAgent->new(
        timeout   => $scfg->{api_timeout} // 30,  # UPDATED: Use config value
        keep_alive=> 1,
        ssl_opts  => {
            verify_hostname => !$scfg->{api_insecure},
            SSL_verify_mode => $scfg->{api_insecure} ? 0x00 : 0x02,
        }
    );
    return $ua;
}

# Also update WebSocket timeout in _ws_open:
my $sock;
my $timeout = $scfg->{api_timeout} // 30;  # NEW
if ($scheme eq 'wss') {
    $sock = IO::Socket::SSL->new(
        PeerHost => $peer,
        PeerPort => $port,
        SSL_verify_mode => $scfg->{api_insecure} ? 0x00 : 0x02,
        SSL_hostname    => $host,
        Timeout => $timeout,  # UPDATED
    ) or die "wss connect failed: $SSL_ERROR\n";
}
```

**Benefits**:
- Configurable for slow/fast networks
- Better timeout control
- User can tune for their environment

**Example Usage**:
```ini
truenasplugin: tnscale
    api_host 192.168.1.100
    api_key xxx
    api_timeout 60  # For slower networks
    ...
```

---

## 9. Detailed Error Context ⭐ HIGH PRIORITY

**Goal**: Provide actionable error messages with troubleshooting hints.

**Implementation Location**: Throughout the plugin, replace generic error messages

**Examples**:

```perl
# Old: die "failed to create extent for $zname\n"
# New:
die sprintf(
    "Failed to create iSCSI extent for %s\n" .
    "  Dataset: %s\n" .
    "  zvol path: %s\n\n" .
    "Common causes:\n" .
    "  1. TrueNAS iSCSI service not running\n" .
    "  2. Dataset creation failed or incomplete\n" .
    "  3. API key lacks 'Sharing' permissions\n" .
    "  4. Extent name conflict\n\n" .
    "Check TrueNAS logs: /var/log/middlewared.log\n",
    $zname, $full_ds, $zvol_path
);

# Old: die "could not resolve target id for IQN $want\n"
# New:
die sprintf(
    "Could not resolve iSCSI target ID for IQN: %s\n\n" .
    "Found %d target(s) in TrueNAS, but none match.\n\n" .
    "Troubleshooting steps:\n" .
    "  1. Verify target exists: TrueNAS GUI -> Shares -> iSCSI -> Targets\n" .
    "  2. Check target_iqn in /etc/pve/storage.cfg matches exactly\n" .
    "  3. Ensure iSCSI service is running\n" .
    "  4. Check API key has 'Sharing' read permissions\n\n" .
    "Expected IQN: %s\n" .
    "Available IQNs: %s\n",
    $want, scalar(@$targets), $want,
    join(", ", map { $_->{name} // 'unnamed' } @$targets)
);

# Old: die "unable to find free disk name\n"
# New:
die sprintf(
    "Unable to find free disk name after %d attempts\n\n" .
    "This usually means:\n" .
    "  1. Storage is full (no available LUN numbers)\n" .
    "  2. Name conflicts with existing volumes\n" .
    "  3. Dataset query failed\n\n" .
    "Current VM ID: %d\n" .
    "Attempted pattern: vm-%d-disk-*\n",
    $attempts, $vmid, $vmid
);
```

**Benefits**:
- Users can self-diagnose common issues
- Reduces support burden
- Faster problem resolution
- Better user experience

---

## 10. Pre-flight Checks on Critical Operations ✅ COMPLETED

**Goal**: Validate prerequisites before expensive operations to fail fast.

**Status**: Implemented in `_preflight_check_alloc()` (lines 1403-1500) and integrated into `alloc_image` (lines 1801-1814)

**Validation Checks Performed:**
1. **TrueNAS API connectivity** - Tests `core.ping` to verify API is reachable
2. **iSCSI service status** - Queries `service.query` to ensure iSCSI is RUNNING
3. **Space availability** - Checks dataset space with 20% overhead via `_tn_dataset_get()`
4. **Target existence** - Validates iSCSI target via `_resolve_target_id()`
5. **Dataset existence** - Confirms parent dataset exists

**Error Message Format:**
```
Pre-flight validation failed:
  - TrueNAS iSCSI service is not running (state: STOPPED)
    Start the service in TrueNAS: System Settings > Services > iSCSI
  - Insufficient space on dataset 'tank/proxmox': need 120.00 GB (with 20% overhead), have 80.00 GB available
```

**Performance:**
- ~200ms overhead on successful operations (5-10% of total time)
- <1 second fast-fail on validation errors (vs 2-4 seconds wasted work)
- 3 of 5 checks leverage existing API calls that would be made anyway

**Benefits:**
✅ Fast failure with clear error messages
✅ Prevents partial operations and orphaned resources
✅ Validates all prerequisites upfront
✅ Actionable troubleshooting guidance
✅ Comprehensive audit logging

---

## Additional Considerations

### Documentation Improvements
- Add troubleshooting section to README
- Document common error patterns and solutions
- Add example configurations for different scenarios

### Testing Improvements
- Add test cases for each new validation
- Create integration tests for error scenarios
- Add performance regression tests

### Monitoring Improvements
- Add metrics collection for retry counts
- Track API call latencies
- Monitor orphaned resource counts

---

## Implementation Priority

### Phase 1 (Critical - Implement First)
1. ⏸️ Configuration Validation on Load (#1) - Basic implementation exists, needs enhancement
2. ✅ Dataset Space Check Before Allocation (#3) - **COMPLETED** (integrated into #10)
3. ⏸️ Detailed Error Context (#9) - Needs implementation
4. ✅ Pre-flight Checks on Critical Operations (#10) - **COMPLETED**

### Phase 2 (Important - Implement Soon)
5. ⏸️ Connection Health Check (#2)
6. ⏸️ Timeout Configuration (#8)
7. ⏸️ Orphaned Resource Detection (#4)
8. ⏸️ LUN Conflict Detection (#5)

### Phase 3 (Nice to Have - Implement Later)
9. ⏸️ Rate Limit Backoff Improvement (#7)
10. ⏸️ WebSocket Connection Staleness Check (#6)

---

## Notes

- All changes should maintain backward compatibility
- Each improvement should be tested individually
- Consider creating a separate branch for each major improvement
- Update README.md with new configuration options
- Add migration notes if configuration changes are required

---

**Generated**: 2025-10-01
**Last Updated**: 2025-10-01
**Status**: Planning Phase
