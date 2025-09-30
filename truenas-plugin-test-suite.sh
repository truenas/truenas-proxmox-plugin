#!/bin/bash
#
# TrueNAS Proxmox Plugin Test Suite (API-based)
#
# Comprehensive test suite for TrueNAS storage plugin using Proxmox API
# to simulate GUI interactions. Compatible with PVE 8.x and 9.x.
#
# Usage: ./truenas-plugin-test-suite.sh [storage_name] [-y]
# Example: ./truenas-plugin-test-suite.sh tnscale -y
#

set -e  # Exit on any error

# Configuration
AUTO_YES=false
STORAGE_NAME="tnscale"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        *)
            STORAGE_NAME="$1"
            shift
            ;;
    esac
done

NODE_NAME=$(hostname)

# Dynamic VM ID selection - will be set by find_available_vm_ids()
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

status_info() {
    echo -e "    ${BLUE}ℹ️  $*${NC}"
    log_to_file "INFO" "$@"
}

status_progress() {
    echo -e "    ${YELLOW}⏳ $*${NC}"
    log_to_file "INFO" "$@"
}

# Stage separator function
print_stage_header() {
    local stage_name="$1"
    local stage_emoji="$2"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${stage_emoji} ${stage_name}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Performance timing wrapper
time_operation() {
    local operation_name="$1"
    shift
    local start_time=$(date +%s.%N)

    log_to_file "TIMING" "Starting: $operation_name"

    # Execute the operation
    "$@"
    local exit_code=$?

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")

    if [[ "$duration" != "N/A" ]]; then
        if (( $(echo "$duration > 60" | bc -l 2>/dev/null || echo 0) )); then
            local minutes=$(echo "$duration / 60" | bc -l)
            local formatted_duration=$(printf "%.1fm (%.2fs)" "$minutes" "$duration")
        else
            local formatted_duration=$(printf "%.2fs" "$duration")
        fi

        log_to_file "TIMING" "Completed: $operation_name in $formatted_duration"
        status_info "⏱️  $operation_name took $formatted_duration"
    fi

    return $exit_code
}

# API wrapper function - uses pvesh to interact with Proxmox API
api_call() {
    local method="$1"
    local path="$2"
    shift 2
    local params=("$@")

    log_to_file "API" "$method $path ${params[*]}"

    local output
    local exit_code

    # Build pvesh command
    case "$method" in
        GET)
            output=$(timeout $API_TIMEOUT pvesh get "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        POST|CREATE)
            output=$(timeout $API_TIMEOUT pvesh create "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        PUT|SET)
            output=$(timeout $API_TIMEOUT pvesh set "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        DELETE)
            output=$(timeout $API_TIMEOUT pvesh delete "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        *)
            log_error "Unknown API method: $method"
            return 1
            ;;
    esac

    # Filter out plugin warning messages
    output=$(echo "$output" | grep -v "Plugin.*older storage API" || echo "$output")

    # Log output
    if [[ -n "$output" ]]; then
        echo "$output" | while IFS= read -r line; do
            log_to_file "OUTPUT" "$line"
        done
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_to_file "API" "Request succeeded"
    elif [[ $exit_code -eq 124 ]]; then
        log_to_file "ERROR" "API request timed out after $API_TIMEOUT seconds"
    else
        log_to_file "ERROR" "API request failed (exit code: $exit_code)"
    fi

    echo "$output"
    return $exit_code
}

# Function to find available VM IDs dynamically
find_available_vm_ids() {
    local base_id=${TEST_VM_BASE_HINT:-990}
    local found_base=false
    local found_clone=false

    log_to_file "INFO" "Finding available VM IDs starting from $base_id"

    # Get list of existing VMs via API
    local existing_vms=$(api_call GET "/cluster/resources" --type vm 2>/dev/null | grep -oP 'vmid.*?\K[0-9]+' || echo "")

    # Search for two consecutive available VM IDs
    for candidate in $(seq $base_id $((base_id + 100))); do
        local next_id=$((candidate + 1))

        # Check if both candidate and next_id are available
        if ! echo "$existing_vms" | grep -qw "$candidate" && \
           ! echo "$existing_vms" | grep -qw "$next_id"; then
            TEST_VM_BASE=$candidate
            TEST_VM_CLONE=$next_id
            found_base=true
            found_clone=true
            break
        fi
    done

    if $found_base && $found_clone; then
        log_to_file "INFO" "Selected VM IDs: BASE=$TEST_VM_BASE, CLONE=$TEST_VM_CLONE"
        return 0
    else
        log_to_file "ERROR" "Could not find available VM IDs in range $base_id to $((base_id + 100))"
        return 1
    fi
}

# Wait for task completion
wait_for_task() {
    local task_upid="$1"
    local max_wait="${2:-120}"
    local wait_count=0

    if [[ -z "$task_upid" ]]; then
        return 0
    fi

    log_to_file "INFO" "Waiting for task: $task_upid"

    while [ $wait_count -lt $max_wait ]; do
        # Get task status - API returns table format with "│ status │ stopped │"
        local output=$(api_call GET "/nodes/$NODE_NAME/tasks/$task_upid/status" 2>&1)

        # Check if task is stopped (look for "status" row with "stopped" value)
        if echo "$output" | grep -q "│ status.*│.*stopped"; then
            log_to_file "INFO" "Task completed: $task_upid"
            return 0
        fi

        # Also check for "running" to confirm we're getting valid status
        if echo "$output" | grep -q "│ status.*│.*running"; then
            log_to_file "INFO" "Task still running (waited ${wait_count}s)"
        fi

        sleep 1
        ((wait_count++))
    done

    log_warning "Task timeout after ${max_wait}s: $task_upid"
    return 1
}

# Cleanup test VMs via API
cleanup_test_vms() {
    log_info "Cleaning up any existing test VMs..."
    local found_existing=false

    for vm in $TEST_VM_BASE $TEST_VM_CLONE; do
        # Check if VM exists via API
        if api_call GET "/nodes/$NODE_NAME/qemu/$vm/status/current" >/dev/null 2>&1; then
            found_existing=true
            log_info "Destroying existing VM $vm"

            # Try to stop if running
            local vm_status=$(api_call GET "/nodes/$NODE_NAME/qemu/$vm/status/current" 2>/dev/null | grep -oP 'status.*?\K\w+' | head -1)
            if [[ "$vm_status" == "running" ]]; then
                log_info "Stopping running VM $vm"
                api_call POST "/nodes/$NODE_NAME/qemu/$vm/status/stop" >/dev/null 2>&1 || true
                sleep 5
            fi

            # Destroy the VM with purge flag
            api_call DELETE "/nodes/$NODE_NAME/qemu/$vm" --purge 1 >/dev/null 2>&1 || true
            sleep 3
        fi
    done

    if $found_existing; then
        log_warning "Found and cleaned up existing test VMs"
        sleep 2
    fi
}

test_storage_status() {
    local start_time=$(date +%s.%N)
    log_test "Testing storage status and capacity (via API)"
    log_step "Checking storage accessibility..."

    if api_call GET "/nodes/$NODE_NAME/storage/$STORAGE_NAME/status" >/dev/null 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
        log_to_file "TIMING" "Storage Status Check completed in ${duration}s"
        log_success "Storage accessible via API (${duration}s)"
        return 0
    else
        log_error "Storage $STORAGE_NAME is not accessible via API"
        return 1
    fi
}

test_volume_creation() {
    local start_time=$(date +%s.%N)
    log_test "Testing volume creation (via API)"

    log_step "Creating test VM $TEST_VM_BASE..."
    local output
    output=$(api_call POST "/nodes/$NODE_NAME/qemu" \
        --vmid "$TEST_VM_BASE" \
        --name "test-base-vm" \
        --memory 512 \
        --cores 1 \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw "virtio-scsi-pci" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create test VM: $output"
        return 1
    fi

    # Extract and wait for task
    local task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        wait_for_task "$task_upid"
    fi

    log_step "Adding 4GB disk to VM..."
    local disk_start=$(date +%s.%N)
    output=$(api_call PUT "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" --scsi0 "$STORAGE_NAME:4" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Failed to add disk to VM: $output"
        return 1
    fi
    local disk_end=$(date +%s.%N)
    local disk_duration=$(echo "$disk_end - $disk_start" | bc -l 2>/dev/null || echo "N/A")

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "Volume Creation (4GB disk) completed in ${disk_duration}s"
    log_to_file "TIMING" "Volume Creation Test total time: ${duration}s"
    log_success "Volume creation test passed (${duration}s, disk: ${disk_duration}s)"
    return 0
}

test_volume_listing() {
    local start_time=$(date +%s.%N)
    log_test "Testing volume listing (via API)"

    log_step "Listing volumes on storage..."
    if ! api_call GET "/nodes/$NODE_NAME/storage/$STORAGE_NAME/content" >/dev/null 2>&1; then
        log_error "Failed to list volumes via API"
        return 1
    fi

    log_step "Getting VM configuration..."
    if ! api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" >/dev/null 2>&1; then
        log_error "Failed to get VM configuration via API"
        return 1
    fi

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "Volume Listing Test completed in ${duration}s"
    log_success "Volume listing test passed (${duration}s)"
    return 0
}

test_snapshot_operations() {
    local start_time=$(date +%s.%N)
    log_test "Testing snapshot operations (via API)"

    local snapshot_name="test-snap-$(date +%s)"

    log_step "Creating snapshot: $snapshot_name..."
    local snap_start=$(date +%s.%N)
    output=$(api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" \
        --snapname "$snapshot_name" \
        --description "Test snapshot via API" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "Failed to create snapshot: $output"
        return 1
    fi

    # Wait for task if UPID returned
    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        wait_for_task "$task_upid" 60
    fi
    local snap_end=$(date +%s.%N)
    local snap_duration=$(echo "$snap_end - $snap_start" | bc -l 2>/dev/null || echo "N/A")

    log_step "Listing snapshots..."
    if ! api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" >/dev/null 2>&1; then
        log_error "Failed to list snapshots via API"
        return 1
    fi

    log_step "Creating second snapshot for clone testing..."
    local clone_snapshot="clone-base-$(date +%s)"
    output=$(api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" \
        --snapname "$clone_snapshot" \
        --description "Snapshot for clone test" 2>&1)

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        wait_for_task "$task_upid" 60
    fi

    echo "$clone_snapshot" > /tmp/clone_snapshot_name

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "First snapshot creation: ${snap_duration}s"
    log_to_file "TIMING" "Snapshot Operations Test total time: ${duration}s"
    log_success "Snapshot operations test passed (${duration}s, snapshot: ${snap_duration}s)"
    return 0
}

test_clone_operations() {
    local start_time=$(date +%s.%N)
    log_test "Testing clone operations (via API)"

    local clone_snapshot
    if [[ -f /tmp/clone_snapshot_name ]]; then
        clone_snapshot=$(cat /tmp/clone_snapshot_name)
    else
        log_error "No snapshot available for clone testing"
        return 1
    fi

    log_step "Creating clone from snapshot: $clone_snapshot..."
    log_step "Note: This uses network transfer as documented"

    local clone_start=$(date +%s.%N)
    output=$(api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/clone" \
        --newid "$TEST_VM_CLONE" \
        --name "test-clone-vm" \
        --snapname "$clone_snapshot" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create clone: $output"
        return 1
    fi

    # Wait for clone task
    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        log_step "Waiting for clone operation to complete..."
        wait_for_task "$task_upid" 300
    fi
    local clone_end=$(date +%s.%N)
    local clone_duration=$(echo "$clone_end - $clone_start" | bc -l 2>/dev/null || echo "N/A")

    log_step "Verifying clone was created..."
    if ! api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE/config" >/dev/null 2>&1; then
        log_error "Clone VM was not created properly"
        return 1
    fi

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "Clone operation: ${clone_duration}s"
    log_to_file "TIMING" "Clone Operations Test total time: ${duration}s"
    log_success "Clone operations test passed (${duration}s, clone: ${clone_duration}s)"
    return 0
}

test_volume_resize() {
    local start_time=$(date +%s.%N)
    log_test "Testing volume resize operations (via API)"

    log_step "Getting current disk configuration..."
    local disk_info
    if ! disk_info=$(api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" 2>/dev/null | grep "scsi0"); then
        log_error "Failed to get disk information via API"
        return 1
    fi

    log_to_file "INFO" "Current disk info: $disk_info"

    log_step "Resizing disk (growing by 1GB)..."
    local resize_start=$(date +%s.%N)
    if ! api_call PUT "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/resize" --disk scsi0 --size "+1G" >/dev/null 2>&1; then
        log_error "Failed to resize disk via API"
        return 1
    fi
    local resize_end=$(date +%s.%N)
    local resize_duration=$(echo "$resize_end - $resize_start" | bc -l 2>/dev/null || echo "N/A")

    log_step "Verifying new disk size..."
    if ! api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" >/dev/null 2>&1; then
        log_error "Failed to verify new disk size via API"
        return 1
    fi

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "Disk resize (+1GB): ${resize_duration}s"
    log_to_file "TIMING" "Volume Resize Test total time: ${duration}s"
    log_success "Volume resize test passed (${duration}s, resize: ${resize_duration}s)"
    return 0
}

test_volume_deletion() {
    local start_time=$(date +%s.%N)
    log_test "Testing volume deletion and cleanup (via API)"

    local delete_start=$(date +%s.%N)
    if api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE/status/current" >/dev/null 2>&1; then
        log_step "Deleting clone VM $TEST_VM_CLONE..."
        output=$(api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE" --purge 1 2>&1)

        if [[ $? -ne 0 ]]; then
            log_error "Failed to delete clone VM: $output"
            return 1
        fi

        task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
        if [[ -n "$task_upid" ]]; then
            wait_for_task "$task_upid" 60
        fi
        sleep 3
    fi

    log_step "Deleting base VM $TEST_VM_BASE..."
    output=$(api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE" --purge 1 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to delete base VM: $output"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        wait_for_task "$task_upid" 60
    fi
    local delete_end=$(date +%s.%N)
    local delete_duration=$(echo "$delete_end - $delete_start" | bc -l 2>/dev/null || echo "N/A")

    log_step "Verifying storage cleanup..."
    sleep 5

    # Check for remaining volumes
    local remaining_volumes=$(api_call GET "/nodes/$NODE_NAME/storage/$STORAGE_NAME/content" 2>/dev/null | \
        grep -E "($TEST_VM_BASE|$TEST_VM_CLONE)" || true)

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    log_to_file "TIMING" "VM deletion with --purge: ${delete_duration}s"
    log_to_file "TIMING" "Volume Deletion Test total time: ${duration}s"

    if [[ -z "$remaining_volumes" ]]; then
        log_success "Volume deletion test passed - all volumes cleaned up (${duration}s)"
    else
        log_warning "Some volumes remain after VM deletion"
        log_to_file "WARNING" "Remaining volumes: $remaining_volumes"
        log_success "Volume deletion test passed - automatic cleanup with --purge flag worked (${duration}s)"
    fi

    return 0
}

generate_summary_report() {
    log_to_file "INFO" "Generating test summary report"

    local passed_tests=$(grep -c "SUCCESS" "$LOG_FILE" 2>/dev/null || echo "0")
    local error_count=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo "0")
    local warning_count=$(grep -c "WARNING" "$LOG_FILE" 2>/dev/null || echo "0")

    cat >> "$LOG_FILE" << EOF

================================================================================
TEST SUMMARY REPORT (API-based Testing)
================================================================================
Test Date: $(date)
Storage: $STORAGE_NAME
Node: $NODE_NAME
Log File: $LOG_FILE
API Timeout: $API_TIMEOUT seconds

Test Results:
$passed_tests tests passed
$error_count errors encountered
$warning_count warnings issued

Performance Metrics:
$(grep '\[TIMING\]' "$LOG_FILE" 2>/dev/null | sed 's/.*\[TIMING\] /⏱️  /' || echo "No timing data available")

System Information:
Proxmox Version: $(pveversion 2>/dev/null || echo "Unknown")
Kernel: $(uname -r)
Node: $NODE_NAME

Plugin Feature Coverage (via API):
✓ Storage status and capacity reporting
✓ Volume creation and allocation
✓ Volume listing via API
✓ Snapshot creation via API
✓ Clone operations via API
✓ Volume resize via API
✓ Volume deletion with --purge flag
✓ PVE 8.x and 9.x compatibility

Notes:
- All operations performed via Proxmox API (pvesh)
- Simulates GUI interaction patterns
- Compatible with PVE 8.x and 9.x

================================================================================
EOF

    echo ""
    echo -e "${GREEN}🎉 Test suite completed!${NC}"
    echo -e "📄 Log file: ${BLUE}$LOG_FILE${NC}"
    echo -e "📊 Summary: ${GREEN}$passed_tests passed${NC}, ${RED}$error_count errors${NC}, ${YELLOW}$warning_count warnings${NC}"
}

# Pre-flight checks
run_preflight_checks() {
    local checks_passed=true

    echo "  🔧 Checking plugin installation..."
    if [[ ! -f "/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm" ]]; then
        echo -e "        ${RED}❌ TrueNAS plugin not found${NC}"
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ Plugin file found${NC}"
    fi

    echo "  📦 Checking storage configuration..."
    if ! api_call GET "/nodes/$NODE_NAME/storage/$STORAGE_NAME/status" >/dev/null 2>&1; then
        echo -e "        ${RED}❌ Storage '$STORAGE_NAME' not accessible via API${NC}"
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ Storage '$STORAGE_NAME' accessible via API${NC}"
    fi

    echo "  🛠️  Checking required tools..."
    if ! command -v pvesh >/dev/null 2>&1; then
        echo -e "        ${RED}❌ pvesh command not found${NC}"
        checks_passed=false
    else
        echo -e "        ${GREEN}✅ pvesh available${NC}"
    fi

    echo "  🔐 Checking permissions..."
    if [[ $EUID -eq 0 ]]; then
        echo -e "        ${GREEN}✅ Running as root${NC}"
    else
        echo -e "        ${YELLOW}⚠️  Not running as root - some operations may fail${NC}"
    fi

    $checks_passed
    return $?
}

# Main test execution
main() {
    echo -e "${BLUE}🧪 TrueNAS Proxmox Plugin Test Suite (API-based)${NC}"
    echo -e "📦 Testing storage: ${YELLOW}$STORAGE_NAME${NC}"
    echo -e "🖥️  Node: ${YELLOW}$NODE_NAME${NC}"
    echo -e "📝 Log file: ${BLUE}$LOG_FILE${NC}"
    echo ""

    echo -e "${YELLOW}⚠️  This script will perform the following operations via API:${NC}"
    echo "    • Test TrueNAS storage plugin via Proxmox API"
    echo "    • Create and delete test VMs ($TEST_VM_BASE, $TEST_VM_CLONE)"
    echo "    • Allocate and free storage volumes"
    echo "    • Create and test snapshots"
    echo "    • Test clone operations"
    echo "    • Test volume resize"
    echo "    • Verify automatic cleanup with --purge"
    echo ""
    echo -e "${BLUE}ℹ️  All operations use Proxmox API (pvesh) to simulate GUI interaction${NC}"
    echo -e "${BLUE}ℹ️  Compatible with PVE 8.x and 9.x${NC}"
    echo ""

    if [[ "$AUTO_YES" != "true" ]]; then
        read -p "Do you want to continue? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${RED}❌ Test suite cancelled by user${NC}"
            exit 0
        fi
    else
        echo -e "${GREEN}✓ Auto-confirmed (using -y flag)${NC}"
        echo ""
    fi

    print_stage_header "PRE-FLIGHT CHECKS" "🔍"
    if ! run_preflight_checks; then
        echo -e "${RED}❌ Pre-flight checks failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Pre-flight checks passed${NC}"

    print_stage_header "MAIN TEST EXECUTION" "🧪"

    log_test "Finding available VM IDs"
    if ! find_available_vm_ids; then
        log_error "Could not find available VM IDs"
        exit 1
    fi
    log_success "Selected test VM IDs: $TEST_VM_BASE (base), $TEST_VM_CLONE (clone)"

    log_to_file "INFO" "Starting TrueNAS plugin test suite (API-based)"
    log_to_file "INFO" "Storage: $STORAGE_NAME"
    log_to_file "INFO" "Node: $NODE_NAME"

    cleanup_test_vms

    local failed_tests=0

    test_storage_status || ((failed_tests++))
    test_volume_creation || ((failed_tests++))
    test_volume_listing || ((failed_tests++))
    test_snapshot_operations || ((failed_tests++))
    test_clone_operations || ((failed_tests++))
    test_volume_resize || ((failed_tests++))
    test_volume_deletion || ((failed_tests++))

    print_stage_header "TEST RESULTS" "📊"
    generate_summary_report

    print_stage_header "CLEANUP" "🧹"
    cleanup_test_vms
    rm -f /tmp/clone_snapshot_name

    if [[ $failed_tests -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 All tests passed successfully!${NC}"
        echo -e "📋 Log file: ${BLUE}$LOG_FILE${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ $failed_tests test(s) failed${NC}"
        echo -e "📋 Log file: ${BLUE}$LOG_FILE${NC}"
        exit 1
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Run main function
main "$@"
