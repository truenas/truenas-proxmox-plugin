# TrueNAS Proxmox VE Plugin - Feature Ideas and Enhancements

This document contains suggested features, enhancements, and improvements for future development of the TrueNAS Proxmox VE Storage Plugin.

**Last Updated**: October 2025
**Status**: Planning and Ideas Collection

---

## 🎯 High-Impact Recommendations

### 1. Metrics and Monitoring Integration ⭐⭐⭐
**Priority**: High
**Effort**: Medium
**Impact**: High

**Description**: Add comprehensive metrics collection for production monitoring and observability.

**Suggested Implementation**:
```perl
# Add Prometheus-style metrics endpoint
sub get_metrics {
    my ($class, $storeid, $scfg) = @_;
    return {
        api_calls_total => $API_METRICS{calls} || 0,
        api_errors_total => $API_METRICS{errors} || 0,
        api_retries_total => $API_METRICS{retries} || 0,
        cache_hits => $API_METRICS{cache_hits} || 0,
        cache_misses => $API_METRICS{cache_misses} || 0,
        volume_create_duration_seconds => $API_METRICS{create_time} || 0,
        active_volumes => scalar(@{_list_volumes($scfg)}),
        orphaned_extents => scalar(@{_detect_orphaned_resources($scfg)}),
    };
}
```

**Metrics to Track**:
- API call counts (total, by method)
- API error rates (by error type)
- API retry counts
- Cache hit/miss ratios
- Operation durations (create, delete, snapshot, clone, resize)
- Active volume count
- Orphaned resource count
- Storage space utilization
- Network bandwidth usage

**Benefits**:
- Proactive issue detection (alert on high error rates)
- Performance trend analysis
- Capacity planning with historical data
- Integration with existing monitoring (Grafana/Prometheus/Zabbix)
- SLA tracking and reporting

**Implementation Notes**:
- Store metrics in memory with periodic export
- Add `/api2/json/storage/{storage}/metrics` endpoint
- Optional push to external metrics collector
- Include in `status` output for easy access

---

### 2. Automated Backup/Restore for Configuration ⭐⭐⭐
**Priority**: High
**Effort**: Low
**Impact**: High

**Description**: Automatically backup storage configuration with versioning to enable easy rollback and change tracking.

**Tool to Add**: `tools/config-backup.sh`
```bash
#!/bin/bash
# Backup TrueNAS plugin storage configuration with versioning
# Usage: ./config-backup.sh [backup|restore|list]

BACKUP_DIR="/var/backups/truenas-plugin"
DATE=$(date +%Y%m%d-%H%M%S)

backup_config() {
    mkdir -p "$BACKUP_DIR"

    # Backup all truenasplugin storage configs
    grep -A20 "^truenasplugin:" /etc/pve/storage.cfg > "$BACKUP_DIR/storage-$DATE.cfg"

    # Store metadata
    echo "Backup created: $DATE" > "$BACKUP_DIR/storage-$DATE.meta"
    echo "Hostname: $(hostname)" >> "$BACKUP_DIR/storage-$DATE.meta"
    echo "Plugin Version: $(grep 'our $VERSION' /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm)" >> "$BACKUP_DIR/storage-$DATE.meta"

    # Keep last 30 backups, delete older
    ls -t "$BACKUP_DIR"/storage-*.cfg | tail -n +31 | xargs rm -f
    ls -t "$BACKUP_DIR"/storage-*.meta | tail -n +31 | xargs rm -f

    echo "Backup saved: $BACKUP_DIR/storage-$DATE.cfg"
}

restore_config() {
    local backup_file="$1"
    if [ -z "$backup_file" ]; then
        echo "Available backups:"
        ls -lh "$BACKUP_DIR"/storage-*.cfg
        echo ""
        echo "Usage: $0 restore <backup-file>"
        exit 1
    fi

    # Backup current config before restore
    backup_config

    # Restore selected backup
    # (Interactive process - show diff, confirm, apply)
}

list_backups() {
    echo "Available configuration backups:"
    for backup in $(ls -t "$BACKUP_DIR"/storage-*.cfg 2>/dev/null); do
        echo "---"
        basename "$backup"
        cat "${backup%.cfg}.meta" 2>/dev/null
    done
}

case "$1" in
    backup) backup_config ;;
    restore) restore_config "$2" ;;
    list) list_backups ;;
    *) echo "Usage: $0 {backup|restore|list}"; exit 1 ;;
esac
```

**Features**:
- Automatic daily backups via cron
- 30-day retention policy
- Metadata tracking (date, hostname, plugin version)
- Interactive restore with diff preview
- Git-style versioning support

**Benefits**:
- Quick rollback after failed changes
- Configuration change auditing
- Disaster recovery capability
- Migration aid (export/import configs)

---

### 3. Health Check Endpoint/Command ⭐⭐
**Priority**: High
**Effort**: Low
**Impact**: Medium

**Description**: Quick health validation without running the full test suite. Useful for automated monitoring and rapid diagnostics.

**Tool to Add**: `tools/health-check.sh`
```bash
#!/bin/bash
# Quick health check for TrueNAS plugin
# Exit codes: 0=healthy, 1=warning, 2=critical

STORAGE="${1:-tnscale}"
WARNINGS=0
ERRORS=0

echo "=== TrueNAS Plugin Health Check ==="
echo "Storage: $STORAGE"
echo ""

# Check 1: Plugin file installed
echo -n "Plugin file: "
if [ -f /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm ]; then
    VERSION=$(grep 'our $VERSION' /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm | grep -oP "'[0-9.]+'")
    echo "OK ($VERSION)"
else
    echo "CRITICAL - Not installed"
    ((ERRORS++))
fi

# Check 2: Storage configured
echo -n "Storage config: "
if grep -q "^truenasplugin: $STORAGE" /etc/pve/storage.cfg; then
    echo "OK"
else
    echo "CRITICAL - Not configured"
    ((ERRORS++))
fi

# Check 3: Storage active
echo -n "Storage status: "
if pvesm status | grep -q "$STORAGE.*active"; then
    echo "OK (active)"
else
    echo "WARNING - Inactive"
    ((WARNINGS++))
fi

# Check 4: TrueNAS API reachable
echo -n "TrueNAS API: "
API_HOST=$(grep -A5 "^truenasplugin: $STORAGE" /etc/pve/storage.cfg | grep api_host | awk '{print $2}')
if [ -n "$API_HOST" ]; then
    if timeout 5 bash -c "</dev/tcp/$API_HOST/443" 2>/dev/null; then
        echo "OK (reachable)"
    else
        echo "CRITICAL - Unreachable"
        ((ERRORS++))
    fi
else
    echo "WARNING - API host not configured"
    ((WARNINGS++))
fi

# Check 5: iSCSI connectivity
echo -n "iSCSI sessions: "
SESSION_COUNT=$(iscsiadm -m session 2>/dev/null | wc -l)
if [ "$SESSION_COUNT" -gt 0 ]; then
    echo "OK ($SESSION_COUNT active)"
else
    echo "WARNING - No active sessions"
    ((WARNINGS++))
fi

# Check 6: Orphaned resources (if available)
echo -n "Orphaned resources: "
# (Would call actual orphan detection if implemented)
echo "SKIP (not implemented)"

# Summary
echo ""
echo "=== Health Summary ==="
if [ $ERRORS -gt 0 ]; then
    echo "Status: CRITICAL ($ERRORS errors, $WARNINGS warnings)"
    exit 2
elif [ $WARNINGS -gt 0 ]; then
    echo "Status: WARNING ($WARNINGS warnings)"
    exit 1
else
    echo "Status: HEALTHY"
    exit 0
fi
```

**Integration**:
- Nagios/Icinga check plugin
- Cron-based monitoring
- Cluster health dashboard
- Pre-deployment validation

**Benefits**:
- Fast validation (<5 seconds)
- Standard exit codes for monitoring
- No test VMs created
- Safe to run frequently

---

## 🚀 Feature Enhancements

### 4. Bandwidth Throttling ⭐⭐
**Priority**: Medium
**Effort**: Medium
**Impact**: Medium

**Description**: Prevent clone/migration operations from saturating network bandwidth.

**Configuration Addition**:
```ini
truenasplugin: storage
    api_host 192.168.1.100
    api_key xxx
    # ... existing config ...
    bandwidth_limit 100M    # Limit network operations to 100MB/s
    bandwidth_limit_clone 50M    # Separate limit for clones
```

**Implementation**:
- Use `pv` (pipe viewer) to throttle `dd` operations
- QoS integration with Linux traffic control
- Per-operation bandwidth limits
- Time-based limits (e.g., throttle during business hours)

**Use Cases**:
- Shared network environments
- WAN links
- Business hours restrictions
- Multi-tenant systems

---

### 5. Snapshot Lifecycle Management ⭐⭐⭐
**Priority**: High
**Effort**: Medium
**Impact**: High

**Description**: Automatic snapshot retention policies to prevent disk space exhaustion.

**Configuration Addition**:
```ini
truenasplugin: storage
    api_host 192.168.1.100
    api_key xxx
    # ... existing config ...
    snapshot_retention_days 7        # Delete snapshots older than 7 days
    snapshot_max_count 10            # Keep max 10 snapshots per volume
    snapshot_auto_cleanup 1          # Enable automatic cleanup
    snapshot_cleanup_schedule daily  # Cleanup schedule
```

**Features**:
- Time-based retention (keep snapshots for N days)
- Count-based retention (keep last N snapshots)
- GFS rotation (Grandfather-Father-Son)
- Protected snapshots (exclude from auto-cleanup)
- Cleanup notifications/logging

**Implementation**:
```perl
sub cleanup_old_snapshots {
    my ($scfg, $volname) = @_;

    return unless $scfg->{snapshot_auto_cleanup};

    my $retention_days = $scfg->{snapshot_retention_days} || 7;
    my $max_count = $scfg->{snapshot_max_count} || 10;
    my $cutoff_time = time() - ($retention_days * 86400);

    # Get all snapshots for volume
    my $snapshots = _list_snapshots($scfg, $volname);

    # Sort by creation time
    my @sorted = sort { $a->{ctime} <=> $b->{ctime} } @$snapshots;

    # Delete snapshots exceeding count limit
    while (scalar(@sorted) > $max_count) {
        my $old_snap = shift @sorted;
        _delete_snapshot($scfg, $volname, $old_snap->{name});
    }

    # Delete snapshots older than retention period
    for my $snap (@sorted) {
        next if $snap->{protected};  # Skip protected snapshots
        if ($snap->{ctime} < $cutoff_time) {
            _delete_snapshot($scfg, $volname, $snap->{name});
        }
    }
}
```

**Benefits**:
- Prevent uncontrolled space consumption
- Compliance with retention policies
- Automated maintenance
- Reduced manual cleanup

---

### 6. Multi-Storage Support in Tools ⭐
**Priority**: Low
**Effort**: Low
**Impact**: Low

**Description**: Test suite currently tests one storage at a time. Enable testing multiple storages for comparison and validation.

**Enhancement**:
```bash
# Test all configured TrueNAS storages
cd tools/
./truenas-plugin-test-suite.sh --all-storages

# Test specific storages
./truenas-plugin-test-suite.sh storage1 storage2 storage3

# Benchmark and compare performance
./truenas-plugin-test-suite.sh --benchmark storage1 storage2

# Output comparison table
```

**Output Example**:
```
=== Storage Performance Comparison ===
Operation          storage1    storage2    storage3
Volume Create      3.2s        2.8s        4.1s
Snapshot Create    0.9s        0.7s        1.2s
Clone Operation    45s         38s         52s
Volume Resize      2.1s        1.9s        2.4s
---
Overall Score      GOOD        BEST        FAIR
```

**Benefits**:
- Validate multiple configs simultaneously
- Performance comparison
- Migration planning
- Identify configuration issues

---

## 🔧 Operational Improvements

### 7. Dry-Run Mode ⭐⭐
**Priority**: Medium
**Effort**: Low
**Impact**: Medium

**Description**: Preview operations before execution to validate changes safely.

**Tool Enhancement**:
```bash
# Show what would be deployed without actually deploying
cd tools/
./update-cluster.sh --dry-run pve1 pve2 pve3

# Output:
# Would copy TrueNASPlugin.pm to:
#   - pve1:/usr/share/perl5/PVE/Storage/Custom/
#   - pve2:/usr/share/perl5/PVE/Storage/Custom/
#   - pve3:/usr/share/perl5/PVE/Storage/Custom/
# Would restart services on:
#   - pve1 (pvedaemon, pveproxy, pvestatd)
#   - pve2 (pvedaemon, pveproxy, pvestatd)
#   - pve3 (pvedaemon, pveproxy, pvestatd)

# Show what would be tested
./truenas-plugin-test-suite.sh --dry-run storage-name

# Output: Test plan without execution
```

**Benefits**:
- Safe validation before risky operations
- Change preview for approval
- Educational (show what tool does)
- CI/CD integration

---

### 8. Orphan Resource Cleanup Tool ⭐⭐⭐
**Priority**: High
**Effort**: Medium
**Impact**: High

**Description**: Find and clean up orphaned resources on TrueNAS (referenced in todo.md #4).

**Tool to Add**: `tools/cleanup-orphans.sh`
```bash
#!/bin/bash
# Find and clean up orphaned resources on TrueNAS
# Detects:
#   - iSCSI extents without corresponding zvols
#   - iSCSI targetextents without extents
#   - Empty/unused snapshots

STORAGE="${1:-tnscale}"
FORCE="${2}"

echo "=== TrueNAS Orphan Resource Detection ==="
echo "Storage: $STORAGE"
echo ""

# Detect orphaned extents
echo "Scanning for orphaned extents..."
# Call pvesh or API to list extents
# Cross-reference with zvols
# Report findings

# Interactive cleanup
if [ "$FORCE" != "--force" ]; then
    echo ""
    echo "Found 3 orphaned resources:"
    echo "  1. extent: vm-999-disk-0 (no zvol)"
    echo "  2. extent: vm-998-disk-1 (no zvol)"
    echo "  3. targetextent: mapping-123 (no extent)"
    echo ""
    read -p "Delete these orphaned resources? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
fi

# Perform cleanup
echo "Cleaning up orphaned resources..."
# Delete each orphan with error handling
```

**Detection Logic**:
```perl
sub detect_orphaned_resources {
    my ($scfg) = @_;
    my @orphans;

    # Get all extents
    my $extents = _tn_extents($scfg) || [];

    # Get all zvols under dataset
    my $zvols = _tn_zvols($scfg) || [];
    my %zvol_names = map { $_->{name} => 1 } @$zvols;

    # Find extents without zvols
    for my $extent (@$extents) {
        my $zvol_path = $extent->{disk};  # e.g., "zvol/tank/proxmox/vm-100-disk-0"
        my $zvol_name = $zvol_path;
        $zvol_name =~ s|^zvol/||;         # Remove "zvol/" prefix

        unless ($zvol_names{$zvol_name}) {
            push @orphans, {
                type => 'extent',
                name => $extent->{name},
                id => $extent->{id},
                reason => 'zvol missing'
            };
        }
    }

    # Get all targetextents
    my $targetextents = _tn_targetextents($scfg) || [];
    my %extent_ids = map { $_->{id} => 1 } @$extents;

    # Find targetextents without extents
    for my $te (@$targetextents) {
        unless ($extent_ids{$te->{extent}}) {
            push @orphans, {
                type => 'targetextent',
                name => "mapping-$te->{id}",
                id => $te->{id},
                reason => 'extent missing'
            };
        }
    }

    return \@orphans;
}
```

**Benefits**:
- Prevent resource leaks
- Reclaim wasted resources
- Better storage hygiene
- Automated maintenance

---

### 9. Migration Helper ⭐⭐
**Priority**: Medium
**Effort**: High
**Impact**: Medium

**Description**: Help users migrate VMs from other storage backends to TrueNAS.

**Tool to Add**: `tools/migrate-storage.sh`
```bash
#!/bin/bash
# Migrate VMs from LVM/Directory/Other storage to TrueNAS
# Usage: ./migrate-storage.sh <source-storage> <dest-storage> [vmid1 vmid2 ...]

SOURCE_STORAGE="$1"
DEST_STORAGE="$2"
shift 2
VMIDS="$@"

if [ -z "$VMIDS" ]; then
    # List all VMs on source storage
    echo "VMs on $SOURCE_STORAGE:"
    pvesm list "$SOURCE_STORAGE" --vmid
    exit 0
fi

for vmid in $VMIDS; do
    echo "=== Migrating VM $vmid ==="
    echo "  Source: $SOURCE_STORAGE"
    echo "  Dest: $DEST_STORAGE"

    # Stop VM if running
    # Clone disks to TrueNAS storage
    # Update VM config to use new storage
    # Validate migration
    # Optional: Remove from source storage
done
```

**Features**:
- Pre-migration validation
- Progress tracking
- Rollback on failure
- Post-migration verification
- Optional source cleanup

**Supported Sources**:
- LVM
- LVM-thin
- Directory
- NFS
- CIFS
- Other iSCSI

---

## 📊 Monitoring and Alerting

### 10. Alert Configuration Templates ⭐
**Priority**: Low
**Effort**: Low
**Impact**: Medium

**Description**: Pre-built monitoring templates for popular platforms.

**Add Directory**: `monitoring/`

**Prometheus Alerts**: `monitoring/prometheus-alerts.yml`
```yaml
groups:
  - name: truenas_plugin
    interval: 60s
    rules:
      - alert: TrueNASStorageInactive
        expr: truenas_storage_active == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "TrueNAS storage {{ $labels.storage }} is inactive"

      - alert: TrueNASHighErrorRate
        expr: rate(truenas_api_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High API error rate on {{ $labels.storage }}"

      - alert: TrueNASLowSpace
        expr: truenas_storage_available_bytes / truenas_storage_total_bytes < 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Low space on {{ $labels.storage }} (<10%)"
```

**Grafana Dashboard**: `monitoring/grafana-dashboard.json`
- Storage capacity graphs
- API call rates
- Error rates
- Operation durations
- Active volumes

**Zabbix Template**: `monitoring/zabbix-template.xml`
- Items for all metrics
- Triggers for critical conditions
- Graphs and screens

**Benefits**:
- Quick monitoring setup
- Best practices templates
- Consistent alerting
- Visual dashboards

---

### 11. Performance Baseline Tool ⭐⭐
**Priority**: Medium
**Effort**: Medium
**Impact**: Medium

**Description**: Establish performance baselines for troubleshooting and capacity planning.

**Tool to Add**: `tools/benchmark.sh`
```bash
#!/bin/bash
# Benchmark TrueNAS storage performance
# Generates performance report with expected vs actual values

STORAGE="${1:-tnscale}"
TEST_SIZE="10G"

echo "=== TrueNAS Storage Performance Benchmark ==="
echo "Storage: $STORAGE"
echo "Test Size: $TEST_SIZE"
echo ""

# Create test VM
TEST_VMID=9999
qm create $TEST_VMID --name "benchmark-test"
qm set $TEST_VMID --scsi0 "$STORAGE:$TEST_SIZE"

# Run fio benchmarks
echo "Running sequential write test..."
# fio sequential write

echo "Running sequential read test..."
# fio sequential read

echo "Running random IOPS test..."
# fio random IOPS

echo "Running snapshot creation test..."
SNAP_START=$(date +%s.%N)
qm snapshot $TEST_VMID bench-snap
SNAP_END=$(date +%s.%N)
SNAP_TIME=$(echo "$SNAP_END - $SNAP_START" | bc)

echo "Running clone test..."
CLONE_START=$(date +%s.%N)
qm clone $TEST_VMID 9998 --name "benchmark-clone"
CLONE_END=$(date +%s.%N)
CLONE_TIME=$(echo "$CLONE_END - $CLONE_START" | bc)

# Cleanup
qm destroy 9998 --purge
qm destroy $TEST_VMID --purge

# Generate report
cat > "/tmp/benchmark-$STORAGE-$(date +%Y%m%d).txt" << EOF
=== Performance Benchmark Report ===
Storage: $STORAGE
Date: $(date)
Test Size: $TEST_SIZE

Results:
Sequential Write: XXX MB/s (Expected: 100-500 MB/s)
Sequential Read:  XXX MB/s (Expected: 100-500 MB/s)
Random IOPS:      XXX IOPS (Expected: 1000-5000 IOPS)
Snapshot Create:  ${SNAP_TIME}s (Expected: <2s)
Clone Operation:  ${CLONE_TIME}s (Expected: <60s for 10G)

Status: PASS/WARN/FAIL
EOF
```

**Benefits**:
- Baseline for comparison
- Detect performance degradation
- Capacity planning
- Troubleshooting aid

---

## 🔐 Security Enhancements

### 12. API Key Rotation Helper ⭐⭐
**Priority**: Medium
**Effort**: Low
**Impact**: High

**Description**: Safely rotate TrueNAS API keys across cluster without downtime.

**Tool to Add**: `tools/rotate-api-key.sh`
```bash
#!/bin/bash
# Safely rotate TrueNAS API key across Proxmox cluster
# Zero-downtime rotation with validation

STORAGE="${1}"
NEW_API_KEY="${2}"
NODES="${@:3}"

if [ -z "$NEW_API_KEY" ]; then
    echo "Usage: $0 <storage-name> <new-api-key> <node1> <node2> ..."
    echo ""
    echo "Steps to rotate API key:"
    echo "1. Generate new API key in TrueNAS (don't revoke old one yet)"
    echo "2. Run this script with new key"
    echo "3. Script will update all nodes and validate"
    echo "4. After validation, manually revoke old key in TrueNAS"
    exit 1
fi

echo "=== API Key Rotation ==="
echo "Storage: $STORAGE"
echo "Nodes: $NODES"
echo ""

# Validate new key works
echo "Validating new API key..."
# Test API call with new key

# Update each node
for node in $NODES; do
    echo "Updating $node..."
    ssh root@$node "sed -i 's/api_key .*/api_key $NEW_API_KEY/' /etc/pve/storage.cfg"
    ssh root@$node "systemctl restart pvedaemon pveproxy"
    sleep 2

    # Validate storage still works
    ssh root@$node "pvesm status | grep $STORAGE"
done

echo ""
echo "✓ API key rotation complete"
echo "⚠ Don't forget to revoke old API key in TrueNAS!"
```

**Security Best Practices**:
- Regular rotation schedule (quarterly)
- Zero-downtime rotation
- Validation at each step
- Audit logging
- Old key revocation reminder

---

### 13. Audit Logging ⭐
**Priority**: Low
**Effort**: Medium
**Impact**: Low

**Description**: Comprehensive audit trail for compliance and security.

**Implementation**:
```perl
sub _audit_log {
    my ($operation, $details) = @_;

    my $user = $ENV{PVE_USER} || 'unknown';
    my $timestamp = time();
    my $iso_time = strftime("%Y-%m-%d %H:%M:%S", localtime($timestamp));

    my $log_entry = {
        timestamp => $timestamp,
        iso_time => $iso_time,
        user => $user,
        operation => $operation,
        %$details
    };

    # Log to syslog
    syslog('info', "AUDIT: $operation by $user: " . encode_json($log_entry));

    # Optional: Log to dedicated audit file
    if (open my $fh, '>>', '/var/log/truenas-plugin-audit.log') {
        print $fh encode_json($log_entry) . "\n";
        close $fh;
    }
}

# Usage throughout plugin:
_audit_log('volume_create', {
    vmid => $vmid,
    volname => $volname,
    size => $size,
    dataset => $scfg->{dataset}
});

_audit_log('volume_delete', {
    vmid => $vmid,
    volname => $volname
});

_audit_log('config_change', {
    storage => $storeid,
    old_config => $old_scfg,
    new_config => $scfg
});
```

**Logged Events**:
- Volume creation/deletion
- Snapshot creation/deletion/rollback
- Configuration changes
- Failed authentication attempts
- API errors
- Orphan resource cleanup
- Key rotation events

**Log Format** (JSON):
```json
{
  "timestamp": 1696204800,
  "iso_time": "2025-10-01 15:30:00",
  "user": "root@pam",
  "operation": "volume_create",
  "vmid": 100,
  "volname": "vm-100-disk-0",
  "size": 34359738368,
  "dataset": "tank/proxmox"
}
```

---

## 📚 Documentation Enhancements

### 14. Interactive Troubleshooting Guide ⭐⭐
**Priority**: Medium
**Effort**: Low
**Impact**: High

**Description**: Interactive CLI wizard to diagnose and fix common issues.

**Tool to Add**: `tools/troubleshoot.sh`
```bash
#!/bin/bash
# Interactive troubleshooting wizard
# Guides users through diagnosis and fixes

echo "=== TrueNAS Plugin Troubleshooter ==="
echo ""
echo "What problem are you experiencing?"
echo "1) Storage shows as inactive"
echo "2) Volume creation fails"
echo "3) VM won't start"
echo "4) Performance issues"
echo "5) Snapshot problems"
echo "6) Clone operation slow/failing"
echo "7) Other/Not sure"
echo ""
read -p "Select option (1-7): " choice

case $choice in
    1)
        echo ""
        echo "=== Diagnosing Inactive Storage ==="
        echo ""
        echo "Checking TrueNAS connectivity..."
        # Ping test
        # API test
        # iSCSI service check
        # Suggest fixes based on findings
        ;;
    2)
        echo ""
        echo "=== Diagnosing Volume Creation Failure ==="
        echo ""
        echo "Checking space availability..."
        # Space check
        # iSCSI target check
        # Dataset check
        # Permission check
        ;;
    # ... other cases
esac
```

**Features**:
- Step-by-step diagnosis
- Automatic checks
- Suggested fixes
- Links to documentation
- Log file analysis

---

### 15. Migration Guide from TrueNAS CORE ⭐
**Priority**: Low
**Effort**: Low
**Impact**: Low

**Description**: Guide for users upgrading from TrueNAS CORE to SCALE.

**Add**: `wiki/Migration-from-CORE.md`

**Contents**:
- CORE vs SCALE differences
- API compatibility notes
- Configuration migration steps
- Testing checklist
- Rollback procedures
- Common migration issues

---

### 16. Video Tutorial Links ⭐
**Priority**: Low
**Effort**: Very Low
**Impact**: Low

**Description**: Links to video tutorials for visual learners.

**Add to README.md**:
```markdown
## Video Tutorials

- [Initial Setup and Configuration](https://youtube.com/...)
- [Cluster Deployment](https://youtube.com/...)
- [Troubleshooting Common Issues](https://youtube.com/...)
- [Performance Tuning](https://youtube.com/...)
```

**Topics to Cover**:
- Initial TrueNAS setup
- Plugin installation
- Creating first VM
- Snapshot workflow
- Cluster configuration
- Troubleshooting walkthrough

---

## 🧪 Testing Improvements

### 17. Chaos Testing Mode ⭐⭐
**Priority**: Low
**Effort**: High
**Impact**: Medium

**Description**: Test plugin resilience to failures and edge cases.

**Enhancement to Test Suite**:
```bash
# Run test suite with simulated failures
cd tools/
./truenas-plugin-test-suite.sh --chaos storage-name

# Chaos scenarios:
# - Random network disconnects during operations
# - TrueNAS service stops mid-operation
# - Disk space exhaustion
# - API rate limiting
# - Concurrent operations conflicts
# - WebSocket connection drops

# Verify:
# - Graceful degradation
# - No data corruption
# - Proper error handling
# - Automatic recovery
```

**Chaos Scenarios**:
```perl
# Inject random failures
sub _chaos_inject {
    my $scenario = $CHAOS_SCENARIOS[rand @CHAOS_SCENARIOS];

    if ($scenario eq 'network_drop') {
        # Temporarily drop network
        system("iptables -A OUTPUT -d TRUENAS_IP -j DROP");
        sleep 5;
        system("iptables -D OUTPUT -d TRUENAS_IP -j DROP");
    }
    elsif ($scenario eq 'service_stop') {
        # Stop TrueNAS iSCSI service
        _api_call($scfg, 'service.stop', ['iscsitarget']);
        sleep 10;
        _api_call($scfg, 'service.start', ['iscsitarget']);
    }
    # ... more scenarios
}
```

---

### 18. Compatibility Matrix Testing ⭐
**Priority**: Low
**Effort**: High
**Impact**: Low

**Description**: Test against multiple Proxmox/TrueNAS version combinations.

**Tool to Add**: `tools/test-compatibility.sh`
```bash
#!/bin/bash
# Test plugin compatibility across versions
# Requires multiple TrueNAS instances or VMs

PROXMOX_VERSIONS=("8.0" "8.1" "8.2" "9.0")
TRUENAS_VERSIONS=("22.12" "23.10" "24.04" "25.04")

for pve_ver in "${PROXMOX_VERSIONS[@]}"; do
    for tn_ver in "${TRUENAS_VERSIONS[@]}"; do
        echo "Testing PVE $pve_ver with TrueNAS $tn_ver"
        # Run test suite
        # Record results
    done
done

# Generate compatibility matrix
```

**Output**:
```
Compatibility Matrix:
                TrueNAS
                22.12  23.10  24.04  25.04
Proxmox  8.0     ✓      ✓      ✓      ✓
         8.1     ✓      ✓      ✓      ✓
         8.2     ✓      ✓      ✓      ✓
         9.0     ⚠      ✓      ✓      ✓

✓ = Fully compatible
⚠ = Works with warnings
✗ = Not compatible
```

---

## 🔄 CI/CD Enhancements

### 19. GitHub Actions Workflows ⭐⭐
**Priority**: Medium
**Effort**: Medium
**Impact**: Medium

**Description**: Automated testing and releases via GitHub Actions.

**Add**: `.github/workflows/test.yml`
```yaml
name: Test Plugin

on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Perl
        run: sudo apt-get install -y perl libperl-critic-perl
      - name: Lint Perl Code
        run: perlcritic TrueNASPlugin.pm

  test:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v3
      - name: Verify plugin syntax
        run: perl -c TrueNASPlugin.pm
      - name: Check version updated
        run: |
          VERSION=$(grep 'our $VERSION' TrueNASPlugin.pm | grep -oP "'[0-9.]+'")
          echo "Plugin version: $VERSION"
```

**Add**: `.github/workflows/release.yml`
```yaml
name: Create Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Create Release
        uses: actions/create-release@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tag_name: ${{ github.ref }}
          release_name: Release ${{ github.ref }}
          draft: false
          prerelease: false
```

**Add**: `.github/workflows/docs.yml`
```yaml
name: Deploy Documentation

on:
  push:
    branches: [main]
    paths:
      - 'wiki/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./wiki
```

---

### 20. Pre-commit Hooks ⭐
**Priority**: Low
**Effort**: Low
**Impact**: Low

**Description**: Catch issues before commit.

**Add**: `.git/hooks/pre-commit`
```bash
#!/bin/bash
# Pre-commit hook for TrueNAS plugin

echo "Running pre-commit checks..."

# Check Perl syntax
echo "Checking Perl syntax..."
if ! perl -c TrueNASPlugin.pm; then
    echo "❌ Perl syntax error"
    exit 1
fi

# Check for TODO/FIXME in staged code
if git diff --cached | grep -E "TODO|FIXME"; then
    echo "⚠️  Warning: TODO/FIXME found in staged changes"
    read -p "Continue anyway? (y/N): " response
    [[ ! "$response" =~ ^[Yy]$ ]] && exit 1
fi

# Check if version was updated (if plugin modified)
if git diff --cached --name-only | grep -q "TrueNASPlugin.pm"; then
    if ! git diff --cached | grep -q "our \$VERSION"; then
        echo "⚠️  Plugin modified but version not updated"
        read -p "Continue anyway? (y/N): " response
        [[ ! "$response" =~ ^[Yy]$ ]] && exit 1
    fi
fi

echo "✓ Pre-commit checks passed"
```

---

## 🎨 User Experience

### 21. Web UI for Tool Management ⭐⭐⭐
**Priority**: High
**Effort**: High
**Impact**: High

**Description**: Web interface for users uncomfortable with CLI.

**Features**:
- Dashboard with storage health
- Run health checks
- View metrics/graphs
- Deploy to cluster (upload plugin file)
- Manage orphaned resources
- View audit logs
- Configuration editor

**Tech Stack Options**:
1. **Simple**: Static HTML + JavaScript calling pvesh API
2. **Medium**: Python Flask app with REST API
3. **Advanced**: Vue.js/React SPA with WebSocket updates

**Mockup**:
```
┌─────────────────────────────────────────┐
│ TrueNAS Plugin Manager                  │
├─────────────────────────────────────────┤
│                                         │
│ Storage: truenas-storage   [✓ Active]  │
│ Version: 1.0.0                          │
│                                         │
│ ┌─────────────┬─────────────────────┐  │
│ │ Health      │ Metrics             │  │
│ │ [✓] API     │ API Calls: 1,234    │  │
│ │ [✓] iSCSI   │ Errors: 5           │  │
│ │ [✓] Space   │ Volumes: 42         │  │
│ │ [⚠] Orphans │ Orphans: 3 [Clean]  │  │
│ └─────────────┴─────────────────────┘  │
│                                         │
│ [Run Health Check] [Deploy to Cluster] │
│ [View Logs] [Cleanup Orphans]          │
│                                         │
└─────────────────────────────────────────┘
```

---

### 22. Configuration Wizard ⭐⭐
**Priority**: Medium
**Effort**: Low
**Impact**: Medium

**Description**: Interactive setup wizard for first-time configuration.

**Tool to Add**: `tools/setup-wizard.sh`
```bash
#!/bin/bash
# Interactive configuration wizard

echo "=== TrueNAS Plugin Setup Wizard ==="
echo ""

# Gather information
read -p "Storage name: " STORAGE_NAME
read -p "TrueNAS IP address: " TRUENAS_IP
read -p "TrueNAS API key: " API_KEY
read -p "ZFS dataset (e.g., tank/proxmox): " DATASET
read -p "iSCSI target name (e.g., proxmox): " TARGET_NAME

# Advanced options
read -p "Configure advanced options? (y/N): " advanced
if [[ "$advanced" =~ ^[Yy]$ ]]; then
    # Additional prompts
    read -p "API transport (ws/rest) [ws]: " API_TRANSPORT
    read -p "Enable multipath? (y/N): " MULTIPATH
    # ... more options
fi

# Generate configuration
TARGET_IQN="iqn.2005-10.org.freenas.ctl:$TARGET_NAME"
cat > "/tmp/storage-$STORAGE_NAME.cfg" << EOF
truenasplugin: $STORAGE_NAME
    api_host $TRUENAS_IP
    api_key $API_KEY
    target_iqn $TARGET_IQN
    dataset $DATASET
    discovery_portal $TRUENAS_IP:3260
    content images
    shared 1
EOF

# Test configuration
echo ""
echo "Testing configuration..."
# Validate API connectivity
# Verify dataset exists
# Check iSCSI target

echo ""
echo "Configuration saved to: /tmp/storage-$STORAGE_NAME.cfg"
read -p "Add to /etc/pve/storage.cfg? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    cat "/tmp/storage-$STORAGE_NAME.cfg" >> /etc/pve/storage.cfg
    systemctl restart pvedaemon pveproxy
    echo "✓ Configuration applied"
fi
```

---

## 📦 Packaging and Distribution

### 23. Debian/RPM Package ⭐⭐⭐
**Priority**: High
**Effort**: Medium
**Impact**: High

**Description**: Proper packaging for easy installation via package manager.

**Create**: `debian/` directory
```
debian/
├── changelog
├── control
├── copyright
├── rules
├── install
└── postinst
```

**debian/control**:
```
Source: pve-storage-truenas
Section: admin
Priority: optional
Maintainer: Your Name <email@example.com>
Build-Depends: debhelper (>= 10)
Standards-Version: 4.5.0

Package: pve-storage-truenas
Architecture: all
Depends: pve-manager (>= 8.0), perl
Description: TrueNAS SCALE storage plugin for Proxmox VE
 Integrates TrueNAS SCALE with Proxmox VE via iSCSI with
 advanced features including live snapshots, ZFS integration,
 and cluster compatibility.
```

**Installation**:
```bash
# Build package
dpkg-buildpackage -us -uc

# Install
dpkg -i pve-storage-truenas_1.0.0_all.deb

# Or via apt repository
apt-get install pve-storage-truenas
```

**Benefits**:
- Standard installation method
- Automatic dependency resolution
- Easy updates
- Removal without manual cleanup

---

### 24. Docker Container for Testing ⭐⭐
**Priority**: Low
**Effort**: Medium
**Impact**: Low

**Description**: Containerized test environment.

**Add**: `Dockerfile`
```dockerfile
FROM debian:12

# Install Proxmox repository
RUN echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve.list

# Install dependencies
RUN apt-get update && apt-get install -y \
    pve-manager \
    perl \
    open-iscsi \
    multipath-tools

# Copy plugin
COPY TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Copy tools
COPY tools/ /opt/truenas-plugin/tools/

WORKDIR /opt/truenas-plugin

CMD ["/bin/bash"]
```

**Usage**:
```bash
# Build image
docker build -t truenas-plugin-test .

# Run tests
docker run -it --privileged truenas-plugin-test bash
# Inside container: run test suite
```

---

## 🔮 Advanced Features

### 25. Thin Provisioning Monitoring ⭐⭐
**Priority**: Medium
**Effort**: Low
**Impact**: High

**Description**: Monitor and alert on thin provisioning overcommitment.

**Implementation**:
```perl
sub check_thin_provisioning_ratio {
    my ($scfg) = @_;

    # Get total allocated (sum of all volume sizes)
    my $volumes = _list_volumes($scfg);
    my $total_allocated = 0;
    for my $vol (@$volumes) {
        $total_allocated += $vol->{size};
    }

    # Get physical available
    my $dataset_info = _tn_dataset_get($scfg);
    my $physical_available = $dataset_info->{available};

    my $ratio = $total_allocated / $physical_available;

    # Warn if overcommitted
    if ($ratio > 2.0) {
        syslog('warning', "High thin provisioning ratio on $scfg->{dataset}: " .
               sprintf("%.1f:1 (allocated: %s, physical: %s)",
                       $ratio,
                       _format_bytes($total_allocated),
                       _format_bytes($physical_available)));
    }

    return {
        allocated => $total_allocated,
        physical => $physical_available,
        ratio => $ratio,
        warning => $ratio > 2.0
    };
}
```

**Alerts**:
```
WARNING: Thin provisioning ratio on 'tank/proxmox' is 3.2:1
  Allocated: 1.6 TB
  Physical: 500 GB
  Actual Usage: 450 GB
  Recommend: Add storage or reduce allocation
```

---

### 26. Automatic Pool Selection ⭐
**Priority**: Low
**Effort**: High
**Impact**: Low

**Description**: Distribute load across multiple datasets/pools automatically.

**Configuration**:
```ini
truenasplugin: auto-storage
    api_host 192.168.1.100
    api_key xxx
    datasets tank/proxmox,pool2/proxmox,pool3/proxmox
    allocation_strategy round_robin  # or least_used, most_space
```

**Strategies**:
- `round_robin`: Alternate between datasets
- `least_used`: Choose dataset with lowest utilization
- `most_space`: Choose dataset with most free space
- `performance`: Choose based on historical performance

---

### 27. Snapshot Synchronization ⭐⭐
**Priority**: Low
**Effort**: High
**Impact**: Medium

**Description**: Replicate snapshots to backup TrueNAS for DR.

**Configuration**:
```ini
truenasplugin: storage
    # ... existing config ...
    snapshot_replication 1
    replication_target 192.168.2.100  # Backup TrueNAS
    replication_target_dataset pool/backup/proxmox
    replication_schedule hourly
```

**Features**:
- Automatic ZFS replication
- Incremental snapshot send/receive
- Verification and monitoring
- DR failover capability

---

## 🏆 Priority Matrix

### Quick Wins (High Impact, Low Effort)
1. ✅ **Version Counter** - COMPLETED
2. **Health Check Tool** (#3)
3. **Orphan Cleanup Tool** (#8)
4. **Config Backup Tool** (#2)
5. **Dry-Run Mode** (#7)

### High Value (High Impact, Medium Effort)
6. **Metrics Collection** (#1)
7. **Snapshot Lifecycle** (#5)
8. **Debian/RPM Packages** (#23)
9. **API Key Rotation** (#12)
10. **Performance Baseline** (#11)

### Strategic (High Impact, High Effort)
11. **Web UI** (#21)
12. **Migration Tools** (#9)
13. **Monitoring Templates** (#10)
14. **Chaos Testing** (#17)

### Nice to Have (Lower Priority)
- Configuration Wizard (#22)
- Multi-storage Testing (#6)
- Bandwidth Throttling (#4)
- Video Tutorials (#16)
- Documentation Improvements (#14, #15)

---

## 📝 Implementation Notes

### Development Guidelines
- Maintain backward compatibility
- Follow existing code style
- Add comprehensive tests
- Update documentation
- Version bump for features

### Testing Requirements
- Unit tests for new functions
- Integration tests for workflows
- Test on multiple PVE/TrueNAS versions
- Cluster testing for cluster features

### Documentation Updates
- Update wiki for new features
- Add configuration examples
- Update troubleshooting guide
- Add changelog entries

---

## 🤝 Contributing

These ideas are open for community contribution. Priority should be given to:
1. Features that improve reliability and robustness
2. Features that reduce operational burden
3. Features that improve user experience
4. Features requested by multiple users

---

**Status**: Open for community feedback and contributions
**Next Steps**: Prioritize based on user feedback and resource availability
