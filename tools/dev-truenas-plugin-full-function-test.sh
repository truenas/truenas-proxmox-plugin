#!/usr/bin/env bash
#
# TrueNAS Plugin Comprehensive Test Suite
# Tests all plugin functions with structured output
#
# Test Phases:
#   1. Pre-flight Cleanup - Remove orphaned resources
#   2. Disk Allocation - Test disk creation with multiple sizes (1GB, 10GB, 32GB, 100GB)
#   3. TrueNAS Size Verification - Verify disk sizes match on TrueNAS backend
#   4. Disk Deletion - Test VM and disk deletion with cleanup verification
#   5. Clone & Snapshot - Test VM cloning, snapshots, and deletion
#   6. Disk Resize - Test expanding disk from 10GB to 20GB
#   7. Concurrent Operations - Test parallel disk allocations and deletions
#   12. Performance - Benchmark disk allocation and deletion timing
#   13. Multiple Disks - Test VMs with multiple disk attachments
#
# Usage: ./dev-truenas-plugin-full-function-test.sh [STORAGE_ID] [VMID_START]
# Example: ./dev-truenas-plugin-full-function-test.sh tnscale 9001
#
# NOTE: This script must be run directly on a Proxmox VE node.
#       It will auto-detect the local node name.
#       ⚠️  WARNING: FOR DEVELOPMENT USE ONLY - NOT FOR PRODUCTION!
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

STORAGE_ID="${1:-tnscale}"
VMID_START="${2:-9001}"
NODE=$(hostname)
VMID_END=$((VMID_START + 24))
TEST_SIZES=(1 10 32 100)  # GB sizes to test

# Clone/Snapshot test VMIDs (at end of range)
CLONE_BASE_VMID=$((VMID_START + 20))
CLONE_VMID=$((CLONE_BASE_VMID + 1))

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="test-results-${TIMESTAMP}.log"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Timing
START_TIME=$(date +%s)

# Test results array
declare -a TEST_RESULTS

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

# ============================================================================
# Phase 1: Cleanup Functions
# ============================================================================

cleanup_test_vms() {
    local vmid_start="$1"
    local vmid_end="$2"

    log_info "Pre-flight cleanup: checking for orphaned resources in VMID range $vmid_start-$vmid_end (cluster-wide)..."

    local cleaned=0
    for vmid in $(seq "$vmid_start" "$vmid_end"); do
        # Check if VM exists on ANY node in the cluster
        local vm_info
        vm_info=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r ".[] | select(.vmid == $vmid) | .node" || echo "")

        if [[ -n "$vm_info" ]]; then
            log_warning "Found existing test VM $vmid on node $vm_info, removing..."
            pvesh delete "/nodes/$vm_info/qemu/$vmid" >/dev/null 2>&1 || true
            cleaned=$((cleaned + 1))
            sleep 1
        fi

        # Check for orphaned disks in storage
        local disks
        disks=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 || echo "")
        if [[ -n "$disks" ]]; then
            while read -r line; do
                local volid
                volid=$(echo "$line" | awk '{print $1}')
                if [[ -n "$volid" ]]; then
                    log_warning "Found orphaned disk $volid, removing..."
                    pvesm free "$volid" >/dev/null 2>&1 || true
                    cleaned=$((cleaned + 1))
                    sleep 1
                fi
            done <<< "$disks"
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_success "Cleaned up $cleaned orphaned resources"
        sleep 3  # Give systems time to fully cleanup
    else
        log_success "No orphaned resources found"
    fi
}

# ============================================================================
# Phase 2: Disk Allocation Tests
# ============================================================================

test_disk_allocation() {
    local size_gb="$1"
    local vmid="$2"
    local test_num="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Allocate ${size_gb}GB disk (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)
    local expected_bytes=$((size_gb * 1024 * 1024 * 1024))

    # Create VM
    if ! pvesh create /nodes/$NODE/qemu -vmid $vmid -name "test-alloc-${size_gb}gb" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid $vmid \
        -filename "vm-$vmid-disk-0" \
        -size "${size_gb}G" \
        --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')

    if [[ -z "$volid" ]] || [[ "$volid" == *"error"* ]]; then
        log_error "Failed to allocate disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep 2

    # Verify size
    local actual_size
    actual_size=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1 || echo "0")

    local duration=$(($(date +%s) - start_time))

    if [[ "$actual_size" == "$expected_bytes" ]]; then
        log_success "Disk allocated: $volid ($actual_size bytes) in ${duration}s"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        log_error "Size mismatch: expected $expected_bytes, got $actual_size"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 3: TrueNAS Size Verification Tests
# ============================================================================

test_truenas_size_verification() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Verify size on TrueNAS (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Get TrueNAS API credentials
    local api_host api_key dataset
    api_host=$(pvesh get /storage --output-format json 2>/dev/null | jq -r ".[] | select(.storage == \"$STORAGE_ID\") | .api_host // empty")
    api_key=$(grep -A 20 "^truenasplugin: $STORAGE_ID" /etc/pve/storage.cfg | grep "api_key" | awk '{print $2}')
    dataset=$(grep -A 20 "^truenasplugin: $STORAGE_ID" /etc/pve/storage.cfg | grep "dataset" | awk '{print $2}')

    if [[ -z "$api_host" ]] || [[ -z "$api_key" ]] || [[ -z "$dataset" ]]; then
        log_error "Failed to read storage configuration"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Get size from Proxmox
    local pvesm_size
    pvesm_size=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1 || echo "0")

    if [[ "$pvesm_size" == "0" ]]; then
        log_error "No disk found for VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Get size from TrueNAS
    local dataset_path="${dataset}/vm-${vmid}-disk-0"
    local encoded_path
    encoded_path=$(echo -n "$dataset_path" | jq -sRr @uri)

    local truenas_size
    truenas_size=$(curl -sk -H "Authorization: Bearer $api_key" \
        "https://$api_host/api/v2.0/pool/dataset/id/$encoded_path" 2>/dev/null | \
        jq -r '.volsize.parsed // .volsize // 0')

    if [[ "$truenas_size" == "0" ]]; then
        log_error "Failed to get zvol size from TrueNAS"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))

    if [[ "$pvesm_size" == "$truenas_size" ]]; then
        log_success "Sizes match: Proxmox=$pvesm_size, TrueNAS=$truenas_size (${duration}s)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        log_error "Size mismatch: Proxmox=$pvesm_size, TrueNAS=$truenas_size"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 4: Disk Deletion Tests
# ============================================================================

test_disk_deletion() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete disk and verify cleanup (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Check disk exists
    local disks_before
    disks_before=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 || echo "")
    if [[ -z "$disks_before" ]]; then
        log_error "No disks found for VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local volid
    volid=$(echo "$disks_before" | awk '{print $1}' | head -1)

    # Attach disk to VM config so it will be automatically removed
    if ! qm set $vmid -scsi0 "$volid" >/dev/null 2>&1; then
        log_warning "Could not attach disk (might already be attached)"
    fi

    # Delete VM
    if ! pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1; then
        log_error "Failed to delete VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep 3

    # Verify cleanup
    local disks_after
    disks_after=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 || echo "")

    local duration=$(($(date +%s) - start_time))

    if [[ -z "$disks_after" ]]; then
        log_success "VM and disk deleted, cleanup verified (${duration}s)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        log_error "Orphaned disks remain: $disks_after"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 5: Clone and Snapshot Tests
# ============================================================================

test_create_base_vm_for_clone() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create base VM for cloning tests (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Create VM
    if ! pvesh create /nodes/$NODE/qemu -vmid $vmid -name "test-clone-base" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create base VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid $vmid \
        -filename "vm-$vmid-disk-0" \
        -size "10G" \
        --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')

    if [[ -z "$volid" ]] || [[ "$volid" == *"error"* ]]; then
        log_error "Failed to allocate disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Attach disk to VM
    if ! qm set $vmid -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk to VM"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Base VM created with disk $volid (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

test_create_snapshot() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create snapshot (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)
    local snapshot_name="test-snapshot-$(date +%s)"

    # Create snapshot
    if ! qm snapshot $vmid "$snapshot_name" --description "Test snapshot" >/dev/null 2>&1; then
        log_error "Failed to create snapshot"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Verify snapshot exists
    local snaplist
    snaplist=$(qm listsnapshot $vmid 2>/dev/null | grep "$snapshot_name" || echo "")

    if [[ -z "$snaplist" ]]; then
        log_error "Snapshot not found in list"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Snapshot '$snapshot_name' created and verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")

    # Store snapshot name for later tests
    echo "$snapshot_name" > "/tmp/test-snapshot-name-${vmid}.txt"
    return 0
}

test_full_clone() {
    local base_vmid="$1"
    local clone_vmid="$2"
    local test_num="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create full clone (VMID $base_vmid → $clone_vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Create full clone
    if ! qm clone $base_vmid $clone_vmid --name "test-full-clone" --full --storage "$STORAGE_ID" >/dev/null 2>&1; then
        log_error "Failed to create full clone"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep 2

    # Verify clone exists
    if ! pvesh get "/nodes/$NODE/qemu/$clone_vmid" >/dev/null 2>&1; then
        log_error "Clone VM does not exist"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Verify clone has disk
    local clone_disks
    clone_disks=$(pvesm list "$STORAGE_ID" --vmid $clone_vmid 2>/dev/null | tail -n +2 || echo "")

    if [[ -z "$clone_disks" ]]; then
        log_error "Clone VM has no disk"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local disk_size
    disk_size=$(echo "$clone_disks" | awk '{print $4}' | head -1)

    local duration=$(($(date +%s) - start_time))
    log_success "Full clone created (disk size: $disk_size bytes) (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

test_delete_snapshot() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete snapshot (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Read snapshot name
    local snapshot_name
    if [[ -f "/tmp/test-snapshot-name-${vmid}.txt" ]]; then
        snapshot_name=$(cat "/tmp/test-snapshot-name-${vmid}.txt")
    else
        log_error "Snapshot name not found"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Delete snapshot
    if ! qm delsnapshot $vmid "$snapshot_name" >/dev/null 2>&1; then
        log_error "Failed to delete snapshot"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep 2

    # Verify snapshot is gone
    local snaplist
    snaplist=$(qm listsnapshot $vmid 2>/dev/null | grep "$snapshot_name" || echo "")

    if [[ -n "$snaplist" ]]; then
        log_error "Snapshot still exists after deletion"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Cleanup temp file
    rm -f "/tmp/test-snapshot-name-${vmid}.txt"

    local duration=$(($(date +%s) - start_time))
    log_success "Snapshot deleted and cleanup verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 6: Disk Resize
# ============================================================================

test_disk_resize() {
    local vmid=$1
    local test_num=$2
    local test_name="Test ${test_num}: Disk Resize (10GB → 20GB)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    log_info "$test_name"
    local start_time=$(date +%s)

    # Create VM with 10GB disk
    log_info "Creating VM with 10GB disk"
    if ! qm create "$vmid" -name "test-resize-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "10G" \
        --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    log_success "Created VM with disk: $volid"
    sleep 2

    # Verify original size
    local orig_size
    orig_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1)
    log_info "Original size: $orig_size bytes (10GB = 10737418240)"

    # Resize disk to 20GB
    log_info "Resizing disk to 20GB"
    if ! qm resize "$vmid" scsi0 "20G" >/dev/null 2>&1; then
        log_error "Resize command failed"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Resize failed")
        return 1
    fi

    sleep 3

    # Verify new size
    local new_size
    new_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1)
    local expected=21474836480

    log_info "New size: $new_size bytes (expected: $expected)"

    if [[ "$new_size" != "$expected" ]]; then
        log_error "Size mismatch: got $new_size, expected $expected"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Size verification failed")
        return 1
    fi

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep 2

    local duration=$(($(date +%s) - start_time))
    log_success "Disk resize verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 7: Concurrent Operations
# ============================================================================

test_concurrent_operations() {
    local base_vmid=$1
    local test_num=$2
    local test_name="Test ${test_num}: Concurrent Operations (2 VMs in parallel)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    log_info "$test_name"
    local start_time=$(date +%s)

    # Initial cleanup
    for i in {0..1}; do
        local vmid_cleanup=$((base_vmid + i))
        pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
    done
    sleep 2

    # Test concurrent allocations
    log_info "Allocating 2 VMs in parallel"
    local pids=()
    local failed=0

    for i in {0..1}; do
        local vmid=$((base_vmid + i))
        (
            # Stagger start
            sleep $(echo "scale=1; $i * 0.5" | bc)

            # Create VM
            qm create "$vmid" -name "test-concurrent-$i" -memory 512 >/dev/null 2>&1 || exit 1
            sleep 3

            # Allocate disk with retries
            local volid=""
            for attempt in {1..5}; do
                local output
                output=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
                    -vmid "$vmid" \
                    -filename "vm-${vmid}-disk-0" \
                    -size "5G" \
                    --output-format=json 2>&1)

                volid=$(echo "$output" | grep -v "older storage API" | grep -v "trying to acquire" | grep -v "cfs-lock" | tr -d '"')

                [[ -n "$volid" && "$volid" =~ ^$STORAGE_ID:vol- ]] && break
                volid=""
                sleep 5
            done

            [[ -n "$volid" ]] || exit 1

            # Attach disk
            qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1 || exit 1

        ) &
        pids+=($!)
    done

    # Wait for completions
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed VM(s) failed to create"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Concurrent allocation failed")
        return 1
    fi

    log_success "All 2 VMs created successfully"
    sleep 3

    # Verify disks
    log_info "Verifying disks exist"
    local disk_count
    disk_count=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep -E "vm-($base_vmid|$((base_vmid+1)))" || true; } | wc -l)

    if [[ $disk_count -ne 2 ]]; then
        log_error "Expected 2 disks, found $disk_count"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk verification failed")
        return 1
    fi

    log_success "All disks verified"

    # Test concurrent deletions
    log_info "Deleting 2 VMs in parallel"
    pids=()
    failed=0

    for i in {0..1}; do
        local vmid=$((base_vmid + i))
        (
            pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed VM(s) failed to delete"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Concurrent deletion failed")
        return 1
    fi

    log_success "All 2 VMs deleted successfully"
    sleep 3

    # Verify cleanup
    local remaining
    remaining=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep -E "vm-($base_vmid|$((base_vmid+1)))" || true; } | wc -l)

    if [[ $remaining -ne 0 ]]; then
        log_error "$remaining disk(s) remain after deletion"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Cleanup verification failed")
        return 1
    fi

    log_success "All disks cleaned up"

    local duration=$(($(date +%s) - start_time))
    log_success "Concurrent operations verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 12: Performance
# ============================================================================

test_performance() {
    local base_vmid=$1
    local test_num=$2
    local test_name="Test ${test_num}: Performance Benchmarks"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    log_info "$test_name"
    local start_time=$(date +%s)

    # Cleanup
    for i in {0..2}; do
        pvesh delete "/nodes/$NODE/qemu/$((base_vmid + i))" >/dev/null 2>&1 || true
    done
    sleep 2

    # Test 1: 5GB allocation
    log_info "Timing 5GB disk allocation"
    local vmid=$base_vmid
    qm create "$vmid" -name "perf-test-5g" -memory 512 >/dev/null 2>&1

    local alloc_start=$(date +%s%3N)
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')
    local alloc_end=$(date +%s%3N)
    local elapsed=$((alloc_end - alloc_start))

    qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1
    log_success "5GB allocation: ${elapsed}ms (threshold: <30s)"

    if [[ $elapsed -ge 30000 ]]; then
        log_warning "Allocation slower than expected (>30s)"
    fi

    sleep 2

    # Test 2: 20GB allocation
    log_info "Timing 20GB disk allocation"
    vmid=$((base_vmid + 1))
    qm create "$vmid" -name "perf-test-20g" -memory 512 >/dev/null 2>&1

    alloc_start=$(date +%s%3N)
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "20G" \
        --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')
    alloc_end=$(date +%s%3N)
    elapsed=$((alloc_end - alloc_start))

    qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1
    log_success "20GB allocation: ${elapsed}ms (threshold: <60s)"

    if [[ $elapsed -ge 60000 ]]; then
        log_warning "Allocation slower than expected (>60s)"
    fi

    sleep 2

    # Test 3: Deletion performance
    log_info "Timing VM deletion"
    vmid=$base_vmid

    local del_start=$(date +%s%3N)
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    local del_end=$(date +%s%3N)
    elapsed=$((del_end - del_start))

    log_success "VM deletion: ${elapsed}ms (threshold: <15s)"

    if [[ $elapsed -ge 15000 ]]; then
        log_warning "Deletion slower than expected (>15s)"
    fi

    # Cleanup remaining
    for i in {0..2}; do
        pvesh delete "/nodes/$NODE/qemu/$((base_vmid + i))" >/dev/null 2>&1 || true
    done
    sleep 2

    local duration=$(($(date +%s) - start_time))
    log_success "Performance benchmarks completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 13: Multiple Disks
# ============================================================================

test_multiple_disks() {
    local vmid=$1
    local test_num=$2
    local test_name="Test ${test_num}: Multiple Disks (3 disks per VM)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    log_info "$test_name"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep 2

    # Create VM
    log_info "Creating VM"
    if ! qm create "$vmid" -name "test-multi-disk-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate 3 disks
    log_info "Allocating 3 disks"
    for i in {0..2}; do
        local volid
        volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
            -vmid "$vmid" \
            -filename "vm-${vmid}-disk-${i}" \
            -size "5G" \
            --output-format=json 2>&1 | grep -v "older storage API" | tr -d '"')

        if ! qm set "$vmid" -scsi${i} "$volid" >/dev/null 2>&1; then
            log_error "Failed to attach disk $i"
            pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
            FAILED_TESTS=$((FAILED_TESTS + 1))
            TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
            return 1
        fi

        sleep 1
    done

    log_success "All 3 disks allocated"
    sleep 2

    # Verify disks in VM config
    log_info "Verifying disks in VM config"
    local config
    config=$(qm config "$vmid")
    local disk_count=0

    for i in {0..2}; do
        if echo "$config" | grep -q "^scsi${i}:"; then
            disk_count=$((disk_count + 1))
        fi
    done

    if [[ $disk_count -ne 3 ]]; then
        log_error "Expected 3 disks in config, found $disk_count"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Config verification failed")
        return 1
    fi

    log_success "All disks in VM config"

    # Verify disks in storage
    log_info "Verifying disks in storage"
    local storage_disk_count
    storage_disk_count=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | wc -l)

    if [[ $storage_disk_count -ne 3 ]]; then
        log_error "Expected 3 disks in storage, found $storage_disk_count"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Storage verification failed")
        return 1
    fi

    log_success "All disks in storage"

    # Delete VM and verify all disks deleted
    log_info "Verifying all disks deleted with VM"
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    sleep 3

    local remaining
    remaining=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep "vm-${vmid}-disk" || true; } | wc -l)

    if [[ $remaining -ne 0 ]]; then
        log_error "$remaining disk(s) not deleted"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Cleanup verification failed")
        return 1
    fi

    log_success "All disks deleted"

    local duration=$(($(date +%s) - start_time))
    log_success "Multiple disks test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Main Test Execution
# ============================================================================

main() {
    echo "╔════════════════════════════════════════════════════════════════════╗" | tee "$LOG_FILE"
    echo "║        TrueNAS Plugin Comprehensive Test Suite v1.0               ║" | tee -a "$LOG_FILE"
    echo "╚════════════════════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    log_info "Configuration:"
    log_info "  Storage ID:    $STORAGE_ID"
    log_info "  Node:          $NODE"
    log_info "  VMID Range:    $VMID_START-$VMID_END"
    log_info "  Test Sizes:    ${TEST_SIZES[*]} GB"
    echo | tee -a "$LOG_FILE"

    # Phase 1: Cleanup
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 1: Pre-flight Cleanup" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    cleanup_test_vms "$VMID_START" "$VMID_END"
    echo | tee -a "$LOG_FILE"

    # Phase 2: Disk Allocation
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 2: Disk Allocation Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    local vmid=$VMID_START
    local test_num=1
    for size in "${TEST_SIZES[@]}"; do
        test_disk_allocation "$size" "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 3: TrueNAS Size Verification
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 3: TrueNAS Size Verification Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$VMID_START
    for size in "${TEST_SIZES[@]}"; do
        test_truenas_size_verification "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 4: Disk Deletion
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 4: Disk Deletion Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$VMID_START
    for size in "${TEST_SIZES[@]}"; do
        test_disk_deletion "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 5: Clone and Snapshot Tests
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 5: Clone and Snapshot Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    # Create base VM for cloning
    test_create_base_vm_for_clone "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Create snapshot
    test_create_snapshot "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Create full clone
    test_full_clone "$CLONE_BASE_VMID" "$CLONE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete full clone
    test_disk_deletion "$CLONE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete snapshot
    test_delete_snapshot "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete base VM
    test_disk_deletion "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 6: Disk Resize
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 6: Disk Resize Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 10))
    test_disk_resize "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 7: Concurrent Operations
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 7: Concurrent Operations Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 11))
    test_concurrent_operations "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 12: Performance
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 12: Performance Benchmarks" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 13))
    test_performance "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 13: Multiple Disks
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 13: Multiple Disks Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 16))
    test_multiple_disks "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Summary
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  TEST SUMMARY" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    echo "Total Tests:  $TOTAL_TESTS" | tee -a "$LOG_FILE"
    echo "Passed:       $PASSED_TESTS ✓" | tee -a "$LOG_FILE"
    echo "Failed:       $FAILED_TESTS ✗" | tee -a "$LOG_FILE"
    echo "Duration:     ${total_duration}s" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    echo "Results:" | tee -a "$LOG_FILE"
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == PASS:* ]]; then
            echo "  ✓ ${result#PASS: }" | tee -a "$LOG_FILE"
        else
            echo "  ✗ ${result#FAIL: }" | tee -a "$LOG_FILE"
        fi
    done
    echo | tee -a "$LOG_FILE"
    echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    if [[ $FAILED_TESTS -gt 0 ]]; then
        echo "Status: FAILED" | tee -a "$LOG_FILE"
        exit 1
    else
        echo "Status: ALL TESTS PASSED" | tee -a "$LOG_FILE"
        exit 0
    fi
}

# Run main function
main "$@"
