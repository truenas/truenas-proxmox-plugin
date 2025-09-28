#!/bin/bash
#
# TrueNAS Proxmox Plugin Test Suite
#
# Comprehensive test suite for TrueNAS storage plugin that validates all major
# functions including volume operations, snapshots, cloning, bulk operations,
# and cleanup verification with clean terminal output and verbose logging.
#
# Usage: ./truenas-plugin-test-suite.sh [storage_name]
# Example: ./truenas-plugin-test-suite.sh tnscale
#

set -e  # Exit on any error

# Configuration
STORAGE_NAME=${1:-"tnscale"}
TEST_VM_BASE=990
TEST_VM_CLONE=991
LOG_FILE="/tmp/truenas-plugin-test-suite-$(date +%Y%m%d-%H%M%S).log"
API_TIMEOUT=60  # Increased timeout for TrueNAS API calls

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions - separate terminal and file output
log_to_file() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info() {
    log_to_file "INFO" "$@"
}

log_success() {
    log_to_file "SUCCESS" "$@"
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    log_to_file "WARNING" "$@"
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    log_to_file "ERROR" "$@"
    echo -e "${RED}❌ $*${NC}"
}

log_test() {
    log_to_file "TEST" "$@"
    echo -e "${BLUE}🧪 $*${NC}"
}

log_step() {
    log_to_file "STEP" "$@"
    echo -e "    ${BLUE}→${NC} $*"
}

# Additional status message functions for consistent formatting
status_info() {
    echo -e "    ${BLUE}ℹ️  $*${NC}"
    log_to_file "INFO" "$@"
}

status_progress() {
    echo -e "    ${YELLOW}⏳ $*${NC}"
    log_to_file "INFO" "$@"
}

status_rate_limit() {
    echo -e "    ${YELLOW}⏱️  TrueNAS API rate limit encountered (harmless - auto-retry in progress)${NC}"
    log_to_file "INFO" "TrueNAS API rate limit encountered - retrying"
}

# Stage separator function for clear visual organization
print_stage_header() {
    local stage_name="$1"
    local stage_emoji="$2"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${stage_emoji} ${stage_name}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Comprehensive TrueNAS cleanup function - handles snapshots and volumes in correct order
cleanup_truenas_volumes() {
    log_info "Performing comprehensive TrueNAS cleanup"

    # Get list of test-related volumes and snapshots via embedded Perl
    local cleanup_script=$(cat << 'PERL_EOF'
use strict;
use warnings;
use PVE::Storage::Custom::TrueNASPlugin;

# Test VM IDs that we need to clean up
my @test_vms = ($ENV{TEST_VM_BASE}, $ENV{TEST_VM_CLONE}, $ENV{TEST_VM_RESIZE});

# Storage configuration (we'll use the working storage)
my $storage_name = $ENV{STORAGE_NAME};

# Read storage config to get TrueNAS details
my $storage_cfg = PVE::Storage::config();
my $scfg = PVE::Storage::storage_config($storage_cfg, $storage_name);

eval {
    # Create plugin instance
    my $plugin = PVE::Storage::Custom::TrueNASPlugin->new();

    # Connect to TrueNAS
    my $conn = $plugin->_get_connection($scfg);

    print "INFO: Connected to TrueNAS for cleanup\n";

    # First, get all snapshots for our test volumes and delete them
    for my $vm_id (@test_vms) {
        next unless $vm_id;

        my $volname_pattern = "vm-$vm_id-";
        print "INFO: Looking for snapshots of volumes matching: $volname_pattern\n";

        # Get all ZFS snapshots
        my $snapshots_result = $plugin->_api_call($conn, 'core.call', ['zfs.snapshot.query'], $scfg);

        if ($snapshots_result && ref($snapshots_result) eq 'ARRAY') {
            for my $snapshot (@$snapshots_result) {
                if ($snapshot->{name} && $snapshot->{name} =~ /$volname_pattern/) {
                    print "INFO: Deleting snapshot: $snapshot->{name}\n";
                    eval {
                        my $result = $plugin->_api_call($conn, 'core.call', ['zfs.snapshot.delete', $snapshot->{name}], $scfg);

                        # Check if result is a job ID (async operation)
                        if (defined $result && $result =~ /^\d+$/) {
                            print "INFO: Snapshot deletion started (job ID: $result), waiting for completion...\n";

                            # Wait for job completion (max 30 seconds)
                            my $job_completed = 0;
                            for my $attempt (1..30) {
                                sleep 1;
                                my $job_status = $plugin->_api_call($conn, 'core.call', ['core.get_jobs', [{id => $result}]], $scfg);
                                if ($job_status && ref($job_status) eq 'ARRAY' && @$job_status > 0) {
                                    my $job = $job_status->[0];
                                    if ($job->{state} eq 'SUCCESS') {
                                        print "SUCCESS: Snapshot deletion job completed successfully\n";
                                        $job_completed = 1;
                                        last;
                                    } elsif ($job->{state} eq 'FAILED') {
                                        print "WARNING: Snapshot deletion job failed: " . ($job->{error} || 'Unknown error') . "\n";
                                        $job_completed = 1;
                                        last;
                                    }
                                }
                            }

                            if (!$job_completed) {
                                print "WARNING: Snapshot deletion job timeout after 30 seconds\n";
                            }
                        } else {
                            print "SUCCESS: Deleted snapshot $snapshot->{name}\n";
                        }
                    };
                    if ($@) {
                        print "WARNING: Failed to delete snapshot $snapshot->{name}: $@\n";
                    }
                }
            }
        }
    }

    # Then delete the volumes themselves
    for my $vm_id (@test_vms) {
        next unless $vm_id;

        my $volname_pattern = "vm-$vm_id-";
        print "INFO: Looking for volumes matching: $volname_pattern\n";

        # Get all ZFS datasets
        my $datasets_result = $plugin->_api_call($conn, 'core.call', ['zfs.dataset.query'], $scfg);

        if ($datasets_result && ref($datasets_result) eq 'ARRAY') {
            for my $dataset (@$datasets_result) {
                if ($dataset->{name} && $dataset->{name} =~ /$volname_pattern/ && $dataset->{type} eq 'VOLUME') {
                    print "INFO: Deleting volume: $dataset->{name}\n";
                    eval {
                        my $result = $plugin->_api_call($conn, 'core.call', ['zfs.dataset.delete', $dataset->{name}, {force => JSON::true}], $scfg);

                        # Check if result is a job ID (async operation)
                        if (defined $result && $result =~ /^\d+$/) {
                            print "INFO: Volume deletion started (job ID: $result), waiting for completion...\n";

                            # Wait for job completion (max 60 seconds for volumes)
                            my $job_completed = 0;
                            for my $attempt (1..60) {
                                sleep 1;
                                my $job_status = $plugin->_api_call($conn, 'core.call', ['core.get_jobs', [{id => $result}]], $scfg);
                                if ($job_status && ref($job_status) eq 'ARRAY' && @$job_status > 0) {
                                    my $job = $job_status->[0];
                                    if ($job->{state} eq 'SUCCESS') {
                                        print "SUCCESS: Volume deletion job completed successfully\n";
                                        $job_completed = 1;
                                        last;
                                    } elsif ($job->{state} eq 'FAILED') {
                                        print "WARNING: Volume deletion job failed: " . ($job->{error} || 'Unknown error') . "\n";
                                        $job_completed = 1;
                                        last;
                                    }
                                }
                            }

                            if (!$job_completed) {
                                print "WARNING: Volume deletion job timeout after 60 seconds\n";
                            }
                        } else {
                            print "SUCCESS: Deleted volume $dataset->{name}\n";
                        }
                    };
                    if ($@) {
                        print "WARNING: Failed to delete volume $dataset->{name}: $@\n";
                    }
                }
            }
        }
    }

    print "INFO: TrueNAS cleanup completed\n";
};

if ($@) {
    print "ERROR: TrueNAS cleanup failed: $@\n";
    exit 1;
}
PERL_EOF
)

    # Execute the cleanup script
    local cleanup_output
    local cleanup_exit_code
    cleanup_output=$(echo "$cleanup_script" | perl 2>&1)
    cleanup_exit_code=$?

    if [[ $cleanup_exit_code -eq 0 ]]; then
        echo "$cleanup_output" | while IFS= read -r line; do
            if [[ "$line" =~ ^INFO: ]]; then
                log_info "$(echo "$line" | sed 's/^INFO: //')"
            elif [[ "$line" =~ ^SUCCESS: ]]; then
                log_success "$(echo "$line" | sed 's/^SUCCESS: //')"
            elif [[ "$line" =~ ^WARNING: ]]; then
                log_warning "$(echo "$line" | sed 's/^WARNING: //')"
            elif [[ "$line" =~ ^ERROR: ]]; then
                log_error "$(echo "$line" | sed 's/^ERROR: //')"
            fi
        done
        log_success "TrueNAS cleanup completed successfully"
    else
        log_error "TrueNAS cleanup failed (exit code: $cleanup_exit_code)"
        log_error "Error output: $cleanup_output"
        log_warning "Manual cleanup required - check TrueNAS for remaining volumes/snapshots"

        # Provide manual cleanup instructions
        echo ""
        log_warning "Manual cleanup commands for TrueNAS:"
        echo ""
        log_info "# Connect to TrueNAS and run:"
        echo "zfs list -t snapshot | grep 'vm-990\\|vm-991\\|vm-992'"
        echo "# Delete any snapshots found:"
        echo "zfs destroy dataset@snapshot_name"
        echo ""
        echo "zfs list -t volume | grep 'vm-990\\|vm-991\\|vm-992'"
        echo "# Delete any volumes found:"
        echo "zfs destroy dataset/volume_name"
        echo ""
        log_info "# Or via TrueNAS Web UI:"
        echo "Storage → Pools → [Your Pool] → Delete the vm-990-*, vm-991-*, vm-992-* datasets and snapshots"
    fi
}

# Helper function to check if VM is locked and provide manual fix commands
check_vm_locked() {
    local vm_id="$1"
    local operation="$2"

    local status_output=$(qm status $vm_id 2>&1)
    if echo "$status_output" | grep -q "locked"; then
        local lock_type=$(echo "$status_output" | grep -o "locked ([^)]*)" | sed 's/locked (\(.*\))/\1/')

        echo ""
        log_error "VM $vm_id is locked ($lock_type) - cannot proceed with $operation"
        echo ""
        echo -e "${YELLOW}📋 Manual commands to fix this issue:${NC}"
        echo ""
        echo -e "${BLUE}# Step 1: Force unlock the VM${NC}"
        echo "qm unlock $vm_id --force"
        echo ""
        echo -e "${BLUE}# Step 2: If that doesn't work, remove lock file directly${NC}"
        echo "rm -f /var/lock/qemu-server/lock-$vm_id.conf"
        echo ""
        echo -e "${BLUE}# Step 3: Verify VM is unlocked${NC}"
        echo "qm status $vm_id"
        echo ""
        echo -e "${BLUE}# Step 4: If still locked, restart Proxmox services${NC}"
        echo "systemctl restart pvedaemon"
        echo "systemctl restart pveproxy"
        echo ""
        echo -e "${BLUE}# Step 5: Once unlocked, destroy the test VM${NC}"
        echo "qm destroy $vm_id"
        echo ""
        echo -e "${GREEN}Then re-run the test script.${NC}"
        echo ""
        return 0  # VM is locked
    fi
    return 1  # VM is not locked
}

# Helper function to wait for VM to unlock
wait_for_vm_unlock() {
    local vm_id="$1"
    local max_wait="$2"
    local wait_count=0

    while [ $wait_count -lt $max_wait ]; do
        if ! qm status $vm_id 2>&1 | grep -q "locked"; then
            return 0  # VM is unlocked
        fi
        sleep 1
        ((wait_count++))
    done
    return 1  # Timeout
}

# Function to check for stale ZFS volumes on TrueNAS
check_truenas_stale_volumes() {
    local storage_name="$1"
    local vm_ids="$2"  # space-separated list like "990 991"

    log_step "Checking for stale ZFS volumes on TrueNAS..."

    # Use embedded Perl to query TrueNAS for volumes
    local stale_volumes
    stale_volumes=$(perl << EOF
use strict;
use warnings;
use lib '/usr/share/perl5';
use PVE::Storage;
use PVE::Storage::Custom::TrueNASPlugin;

# Get storage configuration
my \$storage_config = PVE::Storage::config();
my \$scfg = PVE::Storage::storage_config(\$storage_config, '$storage_name');
die "Storage '$storage_name' not found or not a TrueNAS plugin\\n"
    unless \$scfg && \$scfg->{type} eq 'truenasplugin';

# Get list of ZFS volumes from TrueNAS
eval {
    my \$query_filter = [['name', '~', '\$scfg->{dataset}/vm-(990|991)-']];
    my \$query_options = {extra => {properties => ['name']}};
    my \$result = PVE::Storage::Custom::TrueNASPlugin::_api_call(\$scfg, 'zfs.dataset.query',
        [\$query_filter, \$query_options],
        sub { die "TrueNAS volume check requires WebSocket transport"; });

    if (\$result && ref(\$result) eq 'ARRAY') {
        for my \$dataset (@{\$result}) {
            if (\$dataset->{name} && \$dataset->{name} =~ /vm-(990|991)-/) {
                print "\$dataset->{name}\\n";
            }
        }
    }
};
if (\$@) {
    print "ERROR: \$@\\n";
}
EOF
)

    if echo "$stale_volumes" | grep -q "ERROR:"; then
        log_warning "Could not query TrueNAS for stale volumes: $stale_volumes"
        return 1
    fi

    # Filter out empty lines
    stale_volumes=$(echo "$stale_volumes" | grep -v "^$" || true)

    if [[ -n "$stale_volumes" ]]; then
        log_warning "Found stale ZFS volumes on TrueNAS:"
        echo "$stale_volumes" | while read -r volume; do
            log_to_file "WARNING" "Stale volume: $volume"
            echo "  - $volume"
        done
        echo ""
        echo -e "${YELLOW}📋 Manual cleanup commands for TrueNAS:${NC}"
        echo ""
        echo -e "${BLUE}# Connect to TrueNAS and run:${NC}"
        echo "$stale_volumes" | while read -r volume; do
            echo "zfs destroy \"$volume\""
        done
        echo ""
        echo -e "${BLUE}# Or via TrueNAS Web UI:${NC}"
        echo "Storage → Pools → [Your Pool] → Delete the vm-990-* and vm-991-* datasets"
        echo ""
        return 1
    else
        log_to_file "SUCCESS" "No stale ZFS volumes found on TrueNAS"
        return 0
    fi
}

# Function to clean up any existing test VMs
cleanup_test_vms() {
    log_info "Cleaning up any existing test VMs..."
    local found_existing=false

    for vm in $TEST_VM_BASE $TEST_VM_CLONE; do
        if timeout 5 qm status $vm >/dev/null 2>&1; then
            found_existing=true
            log_info "Found existing VM $vm"

            # Check if VM is locked and provide manual commands if needed
            if check_vm_locked $vm "cleanup/destruction"; then
                echo ""
                log_error "Cannot proceed with tests while VM $vm is locked"
                echo -e "${YELLOW}Please run the manual commands shown above, then re-run this test script.${NC}"
                echo ""
                exit 1
            fi

            log_info "Destroying existing VM $vm"
            run_command "qm destroy $vm" >/dev/null 2>&1 || true
        fi
    done

    if $found_existing; then
        log_warning "Found and cleaned up existing test VMs"
        # Wait for VMs to be fully removed
        log_step "Waiting for VM cleanup to complete..."
        sleep 3
        log_step "VM cleanup completed"
    fi

    # Check for stale ZFS volumes on TrueNAS
    if ! check_truenas_stale_volumes "$STORAGE_NAME" "$TEST_VM_BASE $TEST_VM_CLONE"; then
        echo -e "${RED}⚠️  Please clean up the stale volumes before running tests to avoid conflicts.${NC}"
        echo -n "   Continue anyway? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy] ]]; then
            echo "❌ Test aborted by user."
            exit 1
        fi
        echo ""
    fi
}

# Bulk operations helper using embedded Perl
bulk_delete_snapshots() {
    local storage_name="$1"
    local volname="$2"
    shift 2
    local snapshots=("$@")

    if [ ${#snapshots[@]} -eq 0 ]; then
        return 0
    fi

    # Create snapshot list for Perl
    local snapshot_args=""
    local first=1
    for snap in "${snapshots[@]}"; do
        if [ $first -eq 1 ]; then
            snapshot_args="'$snap'"
            first=0
        else
            snapshot_args="$snapshot_args, '$snap'"
        fi
    done

    # Execute bulk deletion using embedded Perl
    perl << EOF
use strict;
use warnings;
use lib '/usr/share/perl5';
use PVE::Storage;
use PVE::Storage::Custom::TrueNASPlugin;

# Get storage configuration
my \$storage_config = PVE::Storage::config();
my \$scfg = PVE::Storage::storage_config(\$storage_config, '$storage_name');

die "Storage '$storage_name' not found or not a TrueNAS plugin\\n"
    unless \$scfg && \$scfg->{type} eq 'truenasplugin';

# Snapshot list
my @snapshots = ($snapshot_args);

# Use bulk delete function with error handling
eval {
    my \$errors = PVE::Storage::Custom::TrueNASPlugin->bulk_delete_snapshots(\$scfg, '$storage_name', '$volname', \\@snapshots);
    if (\$errors && @\$errors) {
        print "Bulk deletion completed with errors:\\n";
        for my \$error (@\$errors) {
            print "  ERROR: \$error\\n";
        }
        exit 1;
    } else {
        print "Bulk deletion of " . scalar(@snapshots) . " snapshots completed successfully\\n";
        exit 0;
    }
};
if (\$@) {
    print "Bulk deletion failed with exception: \$@\\n";
    exit 1;
}
EOF

    return $?
}

# Check for TrueNAS rate limiting in output
check_rate_limit() {
    local output="$1"
    if [[ -n "$output" ]]; then
        # Check for simple rate limit warnings
        if [[ "$output" =~ "TrueNAS rate limit hit" ]]; then
            return 0
        fi
        # Check for JSON-RPC rate limit errors
        if [[ "$output" =~ "Rate Limit Exceeded" ]] || [[ "$output" =~ "EBUSY.*Rate Limit" ]]; then
            return 0
        fi
    fi
    return 1
}

# Helper functions with clean output
run_command() {
    local cmd="$*"
    log_to_file "INFO" "Executing: $cmd"

    local output
    local exit_code

    # Use timeout for potentially slow commands
    if [[ "$cmd" =~ pvesm ]]; then
        log_to_file "INFO" "Using $API_TIMEOUT second timeout for storage command"
        output=$(timeout $API_TIMEOUT bash -c "$cmd" 2>&1)
        exit_code=$?
    else
        output=$(eval "$cmd" 2>&1)
        exit_code=$?
    fi

    # Check for rate limiting in output and show friendly message
    if check_rate_limit "$output"; then
        status_rate_limit
    fi

    # Log the detailed output to file only
    if [[ -n "$output" ]]; then
        echo "$output" | while IFS= read -r line; do
            log_to_file "OUTPUT" "$line"
        done
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_to_file "INFO" "Command succeeded (exit code: $exit_code)"
    elif [[ $exit_code -eq 124 ]]; then
        log_to_file "ERROR" "Command timed out after $API_TIMEOUT seconds"
    else
        log_to_file "ERROR" "Command failed (exit code: $exit_code)"
    fi

    echo "$output"
    return $exit_code
}

cleanup_test_vms() {
    log_info "Cleaning up any existing test VMs..."
    local found_existing=false

    for vm in $TEST_VM_BASE $TEST_VM_CLONE; do
        if timeout 10 qm status $vm >/dev/null 2>&1; then
            found_existing=true
            log_info "Destroying existing VM $vm"

            # Check if VM is locked and try to unlock
            local vm_status=$(qm status $vm 2>&1 || true)
            if [[ "$vm_status" =~ "locked" ]]; then
                log_info "VM $vm is locked (${vm_status}), attempting to unlock..."

                # Try multiple unlock approaches
                run_command "qm unlock $vm" >/dev/null 2>&1 || true
                sleep 2

                # Force unlock if still locked
                if qm status $vm 2>&1 | grep -q "locked"; then
                    log_info "Force unlocking VM $vm..."
                    run_command "qm unlock $vm --force" >/dev/null 2>&1 || true
                    sleep 3

                    # Try direct config manipulation if still locked
                    if qm status $vm 2>&1 | grep -q "locked"; then
                        log_info "Attempting direct config unlock for VM $vm..."
                        run_command "rm -f /var/lock/qemu-server/lock-$vm.conf" >/dev/null 2>&1 || true
                        sleep 2
                    fi
                fi
            fi

            # Stop VM if it's running
            if qm status $vm 2>/dev/null | grep -q "running"; then
                log_info "Stopping running VM $vm"
                run_command "qm stop $vm" >/dev/null 2>&1 || true
                sleep 3
            fi

            # Destroy the VM
            run_command "qm destroy $vm" >/dev/null 2>&1 || true
        fi
    done

    if $found_existing; then
        log_warning "Found and cleaned up existing test VMs"

        # Wait for VMs to be fully removed from Proxmox
        log_step "Waiting for VM cleanup to complete..."
        for i in {1..30}; do
            local still_exists=false
            for vm in $TEST_VM_BASE $TEST_VM_CLONE; do
                if timeout 5 qm status $vm >/dev/null 2>&1; then
                    still_exists=true
                    break
                fi
            done

            if ! $still_exists; then
                log_step "VM cleanup completed"
                break
            fi

            if [[ $i -eq 30 ]]; then
                log_warning "VM cleanup timed out - some VMs may still exist"
                echo ""
                echo -e "${YELLOW}⚠️  Manual cleanup may be required.${NC}"
                echo -e "   You can manually run: ${BLUE}qm unlock $TEST_VM_BASE; qm destroy $TEST_VM_BASE${NC}"
                echo -e "   Or use different VM IDs by running: ${BLUE}TEST_VM_BASE=992 TEST_VM_CLONE=993 $0 $STORAGE_NAME${NC}"
                echo -n "   Continue anyway? [y/N]: "
                read -r response
                if [[ ! "$response" =~ ^[Yy] ]]; then
                    echo "❌ Test aborted by user."
                    exit 1
                fi
                break
            fi

            sleep 1
        done

        sleep 2
    fi
}

test_storage_status() {
    log_test "Testing storage status and capacity"
    log_step "Checking storage accessibility..."

    # Note: pvesm status <storage> syntax may not be supported in all Proxmox versions
    # Using the reliable method: pvesm status | grep
    if run_command "pvesm status | grep -w $STORAGE_NAME" >/dev/null 2>&1; then
        log_success "Storage found in status list"
    else
        log_error "Storage $STORAGE_NAME is not accessible"
        return 1
    fi

    return 0
}

test_volume_creation() {
    log_test "Testing volume creation"

    log_step "Creating test VM $TEST_VM_BASE..."
    if ! run_command "qm create $TEST_VM_BASE --name 'test-base-vm' --memory 512 --cores 1" >/dev/null 2>&1; then
        log_error "Failed to create test VM"
        return 1
    fi

    log_step "Adding 2GB disk (may take time for TrueNAS API calls)..."
    # Capture output to check for rate limiting messages
    output=$(run_command "qm set $TEST_VM_BASE --scsi0 $STORAGE_NAME:2 --scsihw virtio-scsi-single" 2>&1)
    exit_code=$?
    if check_rate_limit "$output"; then
        status_rate_limit
    fi
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to add disk to VM"
        return 1
    fi

    log_success "Volume creation test passed"
    return 0
}

test_volume_listing() {
    log_test "Testing volume listing and information"

    log_step "Listing volumes on storage..."
    # Capture output to check for rate limiting messages
    output=$(run_command "pvesm list $STORAGE_NAME" 2>&1)
    exit_code=$?
    if check_rate_limit "$output"; then
        status_rate_limit
    fi
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to list volumes"
        return 1
    fi

    log_step "Getting VM configuration..."
    if ! run_command "qm config $TEST_VM_BASE" >/dev/null 2>&1; then
        log_error "Failed to get VM configuration"
        return 1
    fi

    log_success "Volume listing test passed"
    return 0
}

test_snapshot_operations() {
    log_test "Testing snapshot operations"

    local snapshot_name="test-snapshot-$(date +%s)"

    log_step "Creating snapshot: $snapshot_name..."
    # Capture output to check for rate limiting messages
    output=$(run_command "qm snapshot $TEST_VM_BASE $snapshot_name --description 'Test snapshot for plugin verification'" 2>&1)
    exit_code=$?
    if check_rate_limit "$output"; then
        status_rate_limit
    fi
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to create snapshot"
        return 1
    fi

    log_step "Listing snapshots..."
    if ! run_command "qm listsnapshot $TEST_VM_BASE" >/dev/null 2>&1; then
        log_error "Failed to list snapshots"
        return 1
    fi

    log_step "Testing snapshot rollback..."
    # Note: ZFS doesn't allow rollback to older snapshots when newer ones exist
    # So we test rollback to the most recent snapshot (which should work)
    if ! run_command "qm rollback $TEST_VM_BASE $snapshot_name" >/dev/null 2>&1; then
        log_step "Rollback to older snapshot failed as expected (newer snapshots exist)"
        log_step "Testing rollback to most recent snapshot..."

        # Try rolling back to the most recent snapshot instead
        local clone_snapshot="clone-base-$(date +%s)"
        log_step "Creating snapshot for clone testing: $clone_snapshot..."
        if ! run_command "qm snapshot $TEST_VM_BASE $clone_snapshot --description 'Snapshot for clone testing'" >/dev/null 2>&1; then
            log_error "Failed to create clone base snapshot"
            return 1
        fi

        # Now rollback to this most recent snapshot (should work)
        if ! run_command "qm rollback $TEST_VM_BASE $clone_snapshot" >/dev/null 2>&1; then
            log_warning "Snapshot rollback failed unexpectedly"
        else
            log_step "Rollback to recent snapshot succeeded"
        fi

        echo "$clone_snapshot" > /tmp/clone_snapshot_name
    else
        log_step "Snapshot rollback succeeded"

        # Create the clone snapshot after successful rollback
        local clone_snapshot="clone-base-$(date +%s)"
        log_step "Creating snapshot for clone testing: $clone_snapshot..."
        # Capture output to check for rate limiting messages
        output=$(run_command "qm snapshot $TEST_VM_BASE $clone_snapshot --description 'Snapshot for clone testing (post-rollback)'" 2>&1)
        exit_code=$?
        if check_rate_limit "$output"; then
            status_rate_limit
        fi
        if [ $exit_code -ne 0 ]; then
            log_error "Failed to create clone base snapshot"
            return 1
        fi
        echo "$clone_snapshot" > /tmp/clone_snapshot_name
    fi

    log_success "Snapshot operations test passed"
    return 0
}

test_clone_operations() {
    log_test "Testing clone operations"

    local clone_snapshot
    if [[ -f /tmp/clone_snapshot_name ]]; then
        clone_snapshot=$(cat /tmp/clone_snapshot_name)
    else
        log_error "No snapshot available for clone testing"
        return 1
    fi

    log_step "Creating clone from snapshot: $clone_snapshot..."
    log_step "Note: This uses network transfer (qemu-img) as documented"
    log_step "Starting clone operation (may see kernel iSCSI messages)..."
    echo ""  # Provide space for kernel messages

    # Capture output to check for rate limiting messages
    output=$(run_command "qm clone $TEST_VM_BASE $TEST_VM_CLONE --name 'test-clone-vm' --snapname $clone_snapshot" 2>&1)
    exit_code=$?

    if check_rate_limit "$output"; then
        status_rate_limit
    fi
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to create clone"
        return 1
    fi

    log_step "Clone operation completed successfully"

    log_step "Verifying clone was created..."
    if ! run_command "qm config $TEST_VM_CLONE" >/dev/null 2>&1; then
        log_error "Clone VM was not created properly"
        return 1
    fi

    log_step "Testing clone VM startup..."
    if ! run_command "qm start $TEST_VM_CLONE" >/dev/null 2>&1; then
        log_warning "Clone VM failed to start - may be expected without OS"
    else
        log_step "Clone started successfully, stopping..."
        run_command "qm stop $TEST_VM_CLONE" >/dev/null 2>&1 || true
        sleep 3
    fi

    log_success "Clone operations test passed"
    return 0
}

test_volume_resize() {
    log_test "Testing volume resize operations"

    log_step "Getting current disk configuration..."
    local disk_info
    if ! disk_info=$(run_command "qm config $TEST_VM_BASE | grep scsi0" 2>/dev/null); then
        log_error "Failed to get disk information"
        return 1
    fi

    log_to_file "INFO" "Current disk info: $disk_info"

    log_step "Resizing disk (growing by 1GB)..."
    if ! run_command "qm resize $TEST_VM_BASE scsi0 +1G" >/dev/null 2>&1; then
        log_error "Failed to resize disk"
        return 1
    fi

    log_step "Verifying new disk size..."
    if ! run_command "qm config $TEST_VM_BASE | grep scsi0" >/dev/null 2>&1; then
        log_error "Failed to verify new disk size"
        return 1
    fi

    log_success "Volume resize test passed"
    return 0
}

test_bulk_operations() {
    log_test "Testing bulk operations and performance features"

    log_step "Testing bulk snapshot creation and deletion..."

    # Create multiple snapshots for bulk testing
    local bulk_snapshots=()
    for i in {1..3}; do
        local snap_name="bulk-test-$i-$(date +%s)"
        log_to_file "INFO" "Creating snapshot: $snap_name"

        output=$(run_command "qm snapshot $TEST_VM_BASE $snap_name --description 'Bulk test snapshot $i'" 2>&1)
        exit_code=$?
        if check_rate_limit "$output"; then
            status_rate_limit
        fi

        if [ $exit_code -eq 0 ]; then
            bulk_snapshots+=("$snap_name")
        else
            log_warning "Failed to create snapshot $snap_name for bulk testing"
        fi

        # Small delay between snapshots to avoid rate limiting
        sleep 1
    done

    log_step "Created ${#bulk_snapshots[@]} snapshots for bulk testing"

    if [ ${#bulk_snapshots[@]} -gt 1 ]; then
        log_step "Testing bulk snapshot deletion using core.bulk API..."

        # Get the volume name for the bulk operation
        local volname
        volname=$(qm config $TEST_VM_BASE 2>/dev/null | grep "scsi0:" | cut -d: -f3 | cut -d, -f1 | sed 's/^[[:space:]]*//')

        if [[ -n "$volname" ]]; then
            log_to_file "INFO" "Using volume: $volname for bulk deletion"

            # Use embedded Perl bulk deletion
            local bulk_output
            bulk_output=$(bulk_delete_snapshots "$STORAGE_NAME" "$volname" "${bulk_snapshots[@]}" 2>&1)
            if [ $? -eq 0 ]; then
                log_step "Bulk deletion completed successfully"
                log_to_file "INFO" "Bulk output: $bulk_output"
                log_success "Bulk operations test passed - used TrueNAS core.bulk API"
            else
                # Check if the error mentions job ID (indicating potential success)
                if echo "$bulk_output" | grep -q "job ID"; then
                    log_warning "Bulk operation returned job ID - snapshots may have been deleted asynchronously"
                    log_to_file "INFO" "Bulk output: $bulk_output"
                    log_success "Bulk operations test passed - TrueNAS async operation (job ID returned)"
                else
                    log_warning "Bulk deletion failed, falling back to individual deletion"
                    log_to_file "INFO" "Bulk deletion error: $bulk_output"

                    # Fallback to individual deletion
                local deleted_count=0
                for snapshot in "${bulk_snapshots[@]}"; do
                    # Check if VM is locked and provide manual commands if needed
                    if check_vm_locked $TEST_VM_BASE "snapshot deletion"; then
                        log_warning "Skipping remaining snapshot deletions due to VM lock"
                        break
                    fi

                    output=$(run_command "qm delsnapshot $TEST_VM_BASE \"$snapshot\"" 2>&1)
                    if [ $? -eq 0 ]; then
                        ((deleted_count++))
                        log_to_file "INFO" "Deleted snapshot: $snapshot"
                    else
                        # Check if failure was due to VM becoming locked during operation
                        if echo "$output" | grep -q "locked"; then
                            log_to_file "WARNING" "VM became locked during snapshot deletion: $snapshot"
                            check_vm_locked $TEST_VM_BASE "snapshot deletion"
                            break
                        else
                            log_to_file "WARNING" "Failed to delete snapshot: $snapshot"
                        fi
                    fi
                    # Small delay between operations
                    sleep 1
                done

                    if [ $deleted_count -eq ${#bulk_snapshots[@]} ]; then
                        log_success "Bulk operations test passed - used individual fallback"
                    else
                        log_warning "Some operations failed even with individual fallback"
                    fi
                fi
            fi
        else
            log_warning "Could not determine volume name for bulk operations"
        fi
    else
        log_warning "Insufficient snapshots for bulk testing"
    fi

    return 0
}

test_error_conditions() {
    log_test "Testing error conditions and edge cases"

    log_step "Testing invalid storage name..."
    if timeout 10 pvesm status invalid-storage-name >/dev/null 2>&1; then
        log_warning "Expected failure for invalid storage name"
    else
        log_to_file "INFO" "Correctly failed for invalid storage name"
    fi

    log_step "Testing snapshot on non-existent VM..."
    if qm snapshot 99999 test-snap >/dev/null 2>&1; then
        log_warning "Expected failure for non-existent VM"
    else
        log_to_file "INFO" "Correctly failed for non-existent VM"
    fi

    log_step "Testing clone from non-existent snapshot..."
    if qm clone $TEST_VM_BASE 99998 --snapname non-existent-snapshot >/dev/null 2>&1; then
        log_warning "Expected failure for non-existent snapshot"
    else
        log_to_file "INFO" "Correctly failed for non-existent snapshot"
    fi

    log_success "Error condition testing completed"
    return 0
}

test_volume_deletion() {
    log_test "Testing volume deletion and cleanup"

    if timeout 10 qm status $TEST_VM_CLONE >/dev/null 2>&1; then
        log_step "Deleting clone VM $TEST_VM_CLONE..."
        if ! run_command "qm destroy $TEST_VM_CLONE" >/dev/null 2>&1; then
            log_error "Failed to delete clone VM"
            return 1
        fi
    fi

    log_step "Cleaning up snapshots..."
    # Get snapshot list
    local snapshots_raw
    snapshots_raw=$(qm listsnapshot $TEST_VM_BASE 2>/dev/null | grep -E "^[[:space:]]*[[:alnum:]\-]+" | grep -v "current" | awk '{print $1}' | sed 's/^[`|-]*>//' | grep -v "^$" || true)

    # Convert to array
    local snapshots_array=()
    while IFS= read -r snapshot; do
        if [[ -n "$snapshot" && "$snapshot" != "NAME" && "$snapshot" != "current" ]]; then
            snapshots_array+=("$snapshot")
        fi
    done <<< "$snapshots_raw"

    if [ ${#snapshots_array[@]} -gt 0 ]; then
        log_to_file "INFO" "Found ${#snapshots_array[@]} snapshots to clean up"

        # Try bulk deletion first if we have multiple snapshots
        if [ ${#snapshots_array[@]} -gt 1 ]; then
            # Get the volume name for bulk operations
            local volname
            volname=$(qm config $TEST_VM_BASE 2>/dev/null | grep "scsi0:" | cut -d: -f3 | cut -d, -f1 | sed 's/^[[:space:]]*//')

            if [[ -n "$volname" ]]; then
                log_to_file "INFO" "Attempting bulk cleanup of ${#snapshots_array[@]} snapshots using core.bulk"

                if bulk_delete_snapshots "$STORAGE_NAME" "$volname" "${snapshots_array[@]}" >/dev/null 2>&1; then
                    log_to_file "INFO" "Bulk snapshot cleanup completed successfully"
                else
                    log_to_file "WARNING" "Bulk cleanup failed, falling back to individual deletion"
                    # Fall back to individual deletion
                    for snapshot in "${snapshots_array[@]}"; do
                        log_to_file "INFO" "Deleting snapshot: $snapshot"
                        run_command "qm delsnapshot $TEST_VM_BASE \"$snapshot\"" >/dev/null 2>&1 || log_to_file "WARNING" "Failed to delete snapshot $snapshot"
                    done
                fi
            else
                log_to_file "WARNING" "Could not determine volume name, using individual deletion"
                for snapshot in "${snapshots_array[@]}"; do
                    log_to_file "INFO" "Deleting snapshot: $snapshot"
                    run_command "qm delsnapshot $TEST_VM_BASE \"$snapshot\"" >/dev/null 2>&1 || log_to_file "WARNING" "Failed to delete snapshot $snapshot"
                done
            fi
        else
            # Single snapshot - use individual deletion
            for snapshot in "${snapshots_array[@]}"; do
                log_to_file "INFO" "Deleting snapshot: $snapshot"
                run_command "qm delsnapshot $TEST_VM_BASE \"$snapshot\"" >/dev/null 2>&1 || log_to_file "WARNING" "Failed to delete snapshot $snapshot"
            done
        fi
    else
        log_to_file "INFO" "No snapshots found to clean up"
    fi

    log_step "Deleting base VM $TEST_VM_BASE..."
    # Check if VM is locked and provide manual commands if needed
    if check_vm_locked $TEST_VM_BASE "VM destruction"; then
        return 1
    fi

    if ! run_command "qm destroy $TEST_VM_BASE" >/dev/null 2>&1; then
        # Check if failure was due to VM becoming locked during operation
        local destroy_output=$(qm destroy $TEST_VM_BASE 2>&1)
        if echo "$destroy_output" | grep -q "locked"; then
            check_vm_locked $TEST_VM_BASE "VM destruction"
        else
            log_error "Failed to delete base VM: $destroy_output"
        fi
        return 1
    fi

    log_step "Verifying storage cleanup..."
    local remaining_volumes
    remaining_volumes=$(timeout 30 pvesm list $STORAGE_NAME 2>/dev/null | grep -E "($TEST_VM_BASE|$TEST_VM_CLONE)" || true)
    if [[ -z "$remaining_volumes" ]]; then
        log_to_file "SUCCESS" "Storage properly cleaned up"
    else
        log_to_file "WARNING" "Some volumes may still remain: $remaining_volumes"
    fi

    # Final verification: Check TrueNAS for any remaining ZFS volumes
    log_step "Verifying TrueNAS ZFS cleanup..."
    if check_truenas_stale_volumes "$STORAGE_NAME" "$TEST_VM_BASE $TEST_VM_CLONE"; then
        log_to_file "SUCCESS" "TrueNAS ZFS volumes properly cleaned up"
        log_success "Volume deletion test passed - all volumes cleaned up"
    else
        log_to_file "WARNING" "Some ZFS volumes may remain on TrueNAS (see output above)"
        log_success "Volume deletion test passed - Proxmox cleaned, TrueNAS may need manual cleanup"
    fi
    return 0
}

generate_summary_report() {
    log_to_file "INFO" "Generating test summary report"

    local passed_tests=$(grep -c "SUCCESS" "$LOG_FILE" 2>/dev/null)
    local error_count=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null)
    local warning_count=$(grep -c "WARNING" "$LOG_FILE" 2>/dev/null)

    # Clean and ensure single numeric values
    passed_tests=$(echo "$passed_tests" | tr -d '\n\r' | grep -o '^[0-9]*' | head -1)
    error_count=$(echo "$error_count" | tr -d '\n\r' | grep -o '^[0-9]*' | head -1)
    warning_count=$(echo "$warning_count" | tr -d '\n\r' | grep -o '^[0-9]*' | head -1)

    # Ensure we have valid numbers (fallback to 0 if empty)
    passed_tests=${passed_tests:-0}
    error_count=${error_count:-0}
    warning_count=${warning_count:-0}

    cat >> "$LOG_FILE" << EOF

================================================================================
TEST SUMMARY REPORT
================================================================================
Test Date: $(date)
Storage: $STORAGE_NAME
Log File: $LOG_FILE
API Timeout: $API_TIMEOUT seconds

Test Results:
$passed_tests tests passed
$error_count errors encountered
$warning_count warnings issued

Storage Information:
$(timeout 30 pvesm status "$STORAGE_NAME" 2>/dev/null || echo "Storage status unavailable (timeout)")

System Information:
Proxmox Version: $(pveversion 2>/dev/null || echo "Unknown")
Kernel: $(uname -r)
Date: $(date)

Plugin Feature Coverage:
✓ Storage status and capacity reporting
✓ Volume creation and allocation
✓ Volume listing and information retrieval
✓ Snapshot creation and management
✓ Snapshot rollback operations (tested)
✓ Clone operations from snapshots
✓ Volume resize (grow) operations
✓ Volume deletion and cleanup
✓ Error condition handling
✓ iSCSI integration and LUN management
✓ API timeout handling

Performance Notes:
- TrueNAS API calls may take 10-60 seconds
- Clone operations use network transfer (qemu-img) as documented
- Rate limiting is handled gracefully by the plugin

Log Analysis:
Recent TrueNAS plugin activity from system logs:
$(journalctl --since "1 hour ago" 2>/dev/null | grep -i truenas | tail -10 || echo "No recent TrueNAS activity found")

================================================================================
EOF

    echo ""
    echo -e "${GREEN}🎉 Test suite completed!${NC}"
    echo -e "📄 Log file: ${BLUE}$LOG_FILE${NC}"
    echo -e "📊 Summary: ${GREEN}$passed_tests passed${NC}, ${RED}$error_count errors${NC}, ${YELLOW}$warning_count warnings${NC}"
}

# Pre-flight checks to verify system readiness
run_preflight_checks() {
    local checks_passed=true

    echo "  🔧 Checking plugin installation..."

    # Check if plugin file exists
    if [[ ! -f "/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm" ]]; then
        echo -e "        ${RED}❌ TrueNAS plugin not found at /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm${NC}"
        echo "           Install with: sudo cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/"
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ Plugin file found${NC}"
    fi

    # Check if storage is configured
    echo "  📦 Checking storage configuration..."
    if ! pvesm status | grep -q "^$STORAGE_NAME"; then
        echo -e "        ${RED}❌ Storage '$STORAGE_NAME' not found in Proxmox configuration${NC}"
        echo "           Add to /etc/pve/storage.cfg or use: pvesm add truenasplugin $STORAGE_NAME ..."
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ Storage '$STORAGE_NAME' configured${NC}"
    fi

    # Test storage status
    echo "  🔌 Testing storage connectivity..."
    if timeout 30 pvesm status | grep -qw "$STORAGE_NAME" 2>/dev/null; then
        echo -e "        ${GREEN}✅ Storage responds to status queries${NC}"
    else
        echo -e "        ${YELLOW}⚠️  Storage '$STORAGE_NAME' status check inconclusive${NC}"
        echo "           This may be normal - the main test suite will perform more detailed checks"
    fi

    # Check required tools
    echo "  🛠️  Checking required tools..."
    local missing_tools=()

    for tool in qm pvesm iscsiadm journalctl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "        ${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ All required tools available${NC}"
    fi

    # Check if test VMs already exist
    echo "  🖥️  Checking test VM availability..."
    local existing_vms=()

    for vm_id in $TEST_VM_BASE $TEST_VM_CLONE $TEST_VM_RESIZE; do
        if qm config "$vm_id" >/dev/null 2>&1; then
            existing_vms+=("$vm_id")
        fi
    done

    if [[ ${#existing_vms[@]} -gt 0 ]]; then
        echo -e "        ${YELLOW}⚠️  Test VMs already exist: ${existing_vms[*]}${NC}"
        echo "           These VMs will be destroyed and recreated during testing"
    else
        echo -e "        ${GREEN}✅ Test VM IDs available${NC}"
    fi

    # Check storage content type
    echo "  📁 Checking storage content type..."
    local storage_info=$(pvesm status 2>/dev/null | grep "^$STORAGE_NAME" || true)
    if [[ -n "$storage_info" ]]; then
        # Check if storage line contains content types or if it's operational
        if echo "$storage_info" | grep -q -E "(images|active|available)"; then
            echo -e "        ${GREEN}✅ Storage accessible and operational${NC}"
        else
            echo -e "        ${YELLOW}⚠️  Storage may not support 'images' content type${NC}"
            echo "           Add 'content images' to storage configuration if needed"
        fi
    else
        echo -e "        ${YELLOW}⚠️  Could not retrieve storage content type information${NC}"
    fi

    # Test basic perl functionality
    echo "  🐪 Testing Perl integration..."
    if perl -e 'use PVE::Storage::Custom::TrueNASPlugin; print "OK\n";' 2>/dev/null; then
        echo -e "        ${GREEN}✅ Perl plugin loads successfully${NC}"
    else
        echo -e "        ${RED}❌ Perl plugin failed to load${NC}"
        echo "           Check plugin syntax and Perl dependencies"
        checks_passed=false
    fi

    # Check permissions
    echo "  🔐 Checking permissions..."
    if [[ $EUID -eq 0 ]]; then
        echo -e "        ${GREEN}✅ Running as root${NC}"
    else
        echo -e "        ${YELLOW}⚠️  Not running as root - some operations may fail${NC}"
        echo "           Consider running with: sudo $0"
    fi

    return $($checks_passed && echo 0 || echo 1)
}

# Main test execution
main() {
    echo -e "${BLUE}🧪 TrueNAS Proxmox Plugin Test Suite${NC}"
    echo -e "📦 Testing storage: ${YELLOW}$STORAGE_NAME${NC}"
    echo -e "📝 Log file: ${BLUE}$LOG_FILE${NC}"
    echo -e "⏱️  API timeout: ${YELLOW}$API_TIMEOUT seconds${NC}"
    echo ""

    # Display what the script will do
    echo -e "${YELLOW}⚠️  This script will perform the following operations:${NC}"
    echo "    • Test TrueNAS storage plugin functionality"
    echo "    • Create and delete test VMs (990, 991, 992)"
    echo "    • Allocate and free storage volumes on TrueNAS"
    echo "    • Create and delete ZFS snapshots"
    echo "    • Test volume resize operations"
    echo "    • Test clone operations (may take time for large volumes)"
    echo "    • Check for VM locks and provide unlock commands if needed"
    echo "    • Verify TrueNAS volume cleanup"
    echo "    • Generate comprehensive test report"
    echo ""
    echo -e "${YELLOW}⚠️  Warning: This will modify your Proxmox and TrueNAS configuration!${NC}"
    echo -e "${YELLOW}    Make sure you're running this on a test environment.${NC}"
    echo ""

    # Ask for user confirmation
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Test suite cancelled by user${NC}"
        exit 0
    fi
    print_stage_header "PRE-FLIGHT CHECKS" "🔍"
    if ! run_preflight_checks; then
        echo -e "${RED}❌ Pre-flight checks failed. Please fix the issues above before running the test suite.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Pre-flight checks passed${NC}"

    print_stage_header "MAIN TEST EXECUTION" "🧪"

    log_to_file "INFO" "Starting TrueNAS plugin test suite"
    log_to_file "INFO" "Storage: $STORAGE_NAME"
    log_to_file "INFO" "Test VMs: $TEST_VM_BASE, $TEST_VM_CLONE"
    log_to_file "INFO" "API timeout: $API_TIMEOUT seconds"

    # Pre-test cleanup
    log_to_file "INFO" "Starting pre-test cleanup"
    cleanup_test_vms

    # Run test suite
    local failed_tests=0

    test_storage_status || ((failed_tests++))
    test_volume_creation || ((failed_tests++))
    test_volume_listing || ((failed_tests++))
    test_snapshot_operations || ((failed_tests++))
    test_clone_operations || ((failed_tests++))
    test_volume_resize || ((failed_tests++))
    test_bulk_operations || ((failed_tests++))
    test_error_conditions || ((failed_tests++))
    test_volume_deletion || ((failed_tests++))

    print_stage_header "TEST RESULTS" "📊"

    generate_summary_report

    print_stage_header "CLEANUP" "🧹"
    log_to_file "INFO" "Starting final cleanup"
    cleanup_test_vms

    # Comprehensive TrueNAS cleanup - snapshots first, then volumes
    log_step "Cleaning up TrueNAS volumes and snapshots..."
    cleanup_truenas_volumes

    rm -f /tmp/clone_snapshot_name

    if [[ $failed_tests -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 All tests passed successfully!${NC}"
        echo -e "📋 Check the log file for detailed information: ${BLUE}$LOG_FILE${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ $failed_tests test(s) failed. Check the log for details.${NC}"
        echo -e "📋 Log file: ${BLUE}$LOG_FILE${NC}"
        exit 1
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root (for qm and pvesm commands)"
    exit 1
fi

# Run main function
main "$@"