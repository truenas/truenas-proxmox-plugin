#!/usr/bin/env bash
#
# TrueNAS Plugin Comprehensive Test Suite
# Tests all plugin functions with machine-readable output
#
# Usage: ./test-truenas-plugin.sh [--storage STORAGE_ID] [--node NODE] [--vmid-start N]
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

STORAGE_ID="${1:-tnscale}"
NODE="${2:-$(hostname)}"
VMID_START="${3:-9001}"
VMID_END=$((VMID_START + 24))
TEST_SIZES=(1 10 32 100)  # GB sizes to test

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JSON_LOG="test-results-${TIMESTAMP}.json"
CSV_LOG="test-results-${TIMESTAMP}.csv"

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
SKIPPED_TESTS=0

# Timing
START_TIME=$(date +%s)

# JSON accumulator
JSON_TESTS="[]"

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Get storage configuration from Proxmox
get_storage_config() {
    local storage_id="$1"
    pvesh get /storage --output-format=json | jq -r ".[] | select(.storage == \"$storage_id\")"
}

# Get TrueNAS API endpoint from storage config
get_truenas_api() {
    local config
    config=$(get_storage_config "$STORAGE_ID")
    echo "$config" | jq -r '.api_host // empty'
}

# Get TrueNAS API key from storage config
get_truenas_api_key() {
    local config
    config=$(get_storage_config "$STORAGE_ID")
    # API key is typically stored in a separate file or needs to be extracted from storage.cfg
    grep -A 20 "^truenasplugin: $STORAGE_ID" /etc/pve/storage.cfg | grep "api_key" | awk '{print $2}'
}

# Query TrueNAS zvol size via API
get_truenas_zvol_size() {
    local api_host="$1"
    local api_key="$2"
    local dataset_path="$3"  # e.g., "pool/dataset/vm-100-disk-0"

    local encoded_path
    encoded_path=$(echo -n "$dataset_path" | jq -sRr @uri)

    local response
    response=$(curl -sk -H "Authorization: Bearer $api_key" \
        "https://$api_host/api/v2.0/pool/dataset/id/$encoded_path" 2>/dev/null || echo '{}')

    echo "$response" | jq -r '.volsize.parsed // .volsize // 0'
}

# Create VM via Proxmox API
create_test_vm() {
    local vmid="$1"
    local name="$2"

    pvesh create /nodes/$NODE/qemu \
        -vmid "$vmid" \
        -name "$name" \
        -memory 512 \
        -net0 "virtio,bridge=vmbr0" \
        >/dev/null 2>&1
}

# Allocate disk via Proxmox API
allocate_disk_api() {
    local vmid="$1"
    local size_gb="$2"
    local filename="$3"

    pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "$filename" \
        -size "${size_gb}G" \
        --output-format=json 2>&1
}

# Get disk size from pvesm
get_disk_size_pvesm() {
    local vmid="$1"

    pvesm list "$STORAGE_ID" --vmid "$vmid" --output-format=json 2>/dev/null | \
        jq -r '.[0].size // 0'
}

# Get block device size
get_blockdev_size() {
    local volid="$1"

    # Get device path from volid
    local device
    device=$(pvesm path "$volid" 2>/dev/null | tail -1 || echo "")

    if [[ -n "$device" ]] && [[ -b "$device" ]]; then
        blockdev --getsize64 "$device" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Delete VM and all disks
delete_test_vm() {
    local vmid="$1"

    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
}

# Check if zvol exists on TrueNAS
check_zvol_exists() {
    local api_host="$1"
    local api_key="$2"
    local dataset_path="$3"

    local encoded_path
    encoded_path=$(echo -n "$dataset_path" | jq -sRr @uri)

    local response
    response=$(curl -sk -H "Authorization: Bearer $api_key" \
        "https://$api_host/api/v2.0/pool/dataset/id/$encoded_path" 2>/dev/null || echo '{}')

    if echo "$response" | jq -e '.id' >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Check if iSCSI extent exists on TrueNAS
check_extent_exists() {
    local api_host="$1"
    local api_key="$2"
    local extent_name="$3"

    local response
    response=$(curl -sk -H "Authorization: Bearer $api_key" \
        "https://$api_host/api/v2.0/iscsi/extent" 2>/dev/null || echo '[]')

    if echo "$response" | jq -e ".[] | select(.name == \"$extent_name\")" >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Add test result to JSON log
add_test_result() {
    local test_id="$1"
    local test_name="$2"
    local category="$3"
    local status="$4"
    local duration_ms="$5"
    shift 5
    local extra_json="$*"  # Additional JSON fields

    local result
    result=$(jq -n \
        --arg test_id "$test_id" \
        --arg test_name "$test_name" \
        --arg category "$category" \
        --arg status "$status" \
        --arg duration "$duration_ms" \
        --argjson extra "${extra_json:-{}}" \
        '{
            test_id: $test_id,
            test_name: $test_name,
            category: $category,
            status: $status,
            duration_ms: ($duration | tonumber),
            results: $extra
        }')

    JSON_TESTS=$(echo "$JSON_TESTS" | jq ". += [$result]")
}

# Add test result to CSV log
add_csv_result() {
    local test_id="$1"
    local test_name="$2"
    local category="$3"
    local status="$4"
    local duration_ms="$5"
    local requested_bytes="${6:-}"
    local actual_bytes="${7:-}"
    local size_match="${8:-}"
    local error_message="${9:-}"

    # Escape CSV fields
    test_name=$(echo "$test_name" | sed 's/"/""/g')
    error_message=$(echo "$error_message" | sed 's/"/""/g')

    echo "$test_id,\"$test_name\",$category,$status,$duration_ms,$requested_bytes,$actual_bytes,$size_match,\"$error_message\"" >> "$CSV_LOG"
}

# ============================================================================
# Test Functions
# ============================================================================

test_disk_allocation() {
    local size_gb="$1"
    local vmid="$2"
    local test_num="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_id="alloc_$(printf "%03d" "$test_num")"
    local test_name="Allocate ${size_gb}GB disk via API"

    local start_ms=$(($(date +%s%N) / 1000000))

    echo -n "[$test_num/$TOTAL_EXPECTED] $test_name "

    # Calculate expected size in bytes
    local requested_bytes=$((size_gb * 1024 * 1024 * 1024))

    # Create VM
    if ! create_test_vm "$vmid" "test-alloc-${size_gb}gb"; then
        local end_ms=$(($(date +%s%N) / 1000000))
        local duration=$((end_ms - start_ms))

        echo -e "${RED}✗ FAIL${NC} (${duration}ms)"
        echo "  └─ Failed to create VM $vmid"

        FAILED_TESTS=$((FAILED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" \
            "{\"error\": \"Failed to create VM\"}"
        add_csv_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" "" "" "" "Failed to create VM"
        return 1
    fi

    # Allocate disk
    local volid
    if ! volid=$(allocate_disk_api "$vmid" "$size_gb" "vm-${vmid}-disk-0" 2>&1); then
        local end_ms=$(($(date +%s%N) / 1000000))
        local duration=$((end_ms - start_ms))

        echo -e "${RED}✗ FAIL${NC} (${duration}ms)"
        echo "  └─ Failed to allocate disk: $volid"

        delete_test_vm "$vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" \
            "{\"error\": \"Failed to allocate disk\"}"
        add_csv_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" "$requested_bytes" "" "" "Failed to allocate disk"
        return 1
    fi

    # Give systems time to settle
    sleep 2

    # Get sizes from different sources
    local pvesm_size
    pvesm_size=$(get_disk_size_pvesm "$vmid")

    local blockdev_size
    blockdev_size=$(get_blockdev_size "${STORAGE_ID}:vol-vm-${vmid}-disk-0-lun"*)

    # Get TrueNAS zvol size
    local api_host api_key dataset_path truenas_size
    api_host=$(get_truenas_api)
    api_key=$(get_truenas_api_key)

    # Get dataset path from storage config
    local dataset
    dataset=$(grep -A 20 "^truenasplugin: $STORAGE_ID" /etc/pve/storage.cfg | grep "dataset" | awk '{print $2}')
    dataset_path="${dataset}/vm-${vmid}-disk-0"

    truenas_size=$(get_truenas_zvol_size "$api_host" "$api_key" "$dataset_path")

    # Verify all sizes match
    local all_match="true"
    if [[ "$pvesm_size" != "$requested_bytes" ]] || \
       [[ "$blockdev_size" != "0" && "$blockdev_size" != "$requested_bytes" ]] || \
       [[ "$truenas_size" != "$requested_bytes" ]]; then
        all_match="false"
    fi

    local end_ms=$(($(date +%s%N) / 1000000))
    local duration=$((end_ms - start_ms))

    if [[ "$all_match" == "true" ]]; then
        echo -e "${GREEN}✓ PASS${NC} (${duration}ms)"
        echo "  └─ Requested: $requested_bytes bytes (${size_gb}.00 GB)"
        echo "  └─ Proxmox:   $pvesm_size bytes"
        echo "  └─ BlockDev:  $blockdev_size bytes"
        echo "  └─ TrueNAS:   $truenas_size bytes ✓"

        PASSED_TESTS=$((PASSED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_allocation" "PASS" "$duration" \
            "{\"requested_bytes\": $requested_bytes, \"pvesm_bytes\": $pvesm_size, \"blockdev_bytes\": $blockdev_size, \"truenas_bytes\": $truenas_size, \"size_match\": true}"
        add_csv_result "$test_id" "$test_name" "disk_allocation" "PASS" "$duration" "$requested_bytes" "$truenas_size" "true" ""
    else
        echo -e "${RED}✗ FAIL${NC} (${duration}ms)"
        echo "  └─ Requested: $requested_bytes bytes (${size_gb}.00 GB)"
        echo "  └─ Proxmox:   $pvesm_size bytes"
        echo "  └─ BlockDev:  $blockdev_size bytes"
        echo "  └─ TrueNAS:   $truenas_size bytes ✗"

        FAILED_TESTS=$((FAILED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" \
            "{\"requested_bytes\": $requested_bytes, \"pvesm_bytes\": $pvesm_size, \"blockdev_bytes\": $blockdev_size, \"truenas_bytes\": $truenas_size, \"size_match\": false}"
        add_csv_result "$test_id" "$test_name" "disk_allocation" "FAIL" "$duration" "$requested_bytes" "$truenas_size" "false" "Size mismatch"
    fi
}

test_disk_deletion() {
    local vmid="$1"
    local test_num="$2"
    local disk_name="vm-${vmid}-disk-0"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_id="delete_$(printf "%03d" "$test_num")"
    local test_name="Delete disk and verify TrueNAS cleanup"

    local start_ms=$(($(date +%s%N) / 1000000))

    echo -n "[$test_num/$TOTAL_EXPECTED] $test_name "

    # Get API credentials
    local api_host api_key dataset_path
    api_host=$(get_truenas_api)
    api_key=$(get_truenas_api_key)
    local dataset
    dataset=$(grep -A 20 "^truenasplugin: $STORAGE_ID" /etc/pve/storage.cfg | grep "dataset" | awk '{print $2}')
    dataset_path="${dataset}/${disk_name}"

    # Check zvol exists before deletion
    local zvol_before
    zvol_before=$(check_zvol_exists "$api_host" "$api_key" "$dataset_path")

    # Check extent exists before deletion
    local extent_before
    extent_before=$(check_extent_exists "$api_host" "$api_key" "$disk_name")

    # Delete VM (which should delete all disks)
    if ! delete_test_vm "$vmid"; then
        local end_ms=$(($(date +%s%N) / 1000000))
        local duration=$((end_ms - start_ms))

        echo -e "${RED}✗ FAIL${NC} (${duration}ms)"
        echo "  └─ Failed to delete VM $vmid"

        FAILED_TESTS=$((FAILED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_deletion" "FAIL" "$duration" \
            "{\"error\": \"Failed to delete VM\"}"
        add_csv_result "$test_id" "$test_name" "disk_deletion" "FAIL" "$duration" "" "" "" "Failed to delete VM"
        return 1
    fi

    # Wait for cleanup
    sleep 3

    # Check zvol deleted
    local zvol_after
    zvol_after=$(check_zvol_exists "$api_host" "$api_key" "$dataset_path")

    # Check extent deleted
    local extent_after
    extent_after=$(check_extent_exists "$api_host" "$api_key" "$disk_name")

    local end_ms=$(($(date +%s%N) / 1000000))
    local duration=$((end_ms - start_ms))

    local cleanup_success="true"
    if [[ "$zvol_after" == "true" ]] || [[ "$extent_after" == "true" ]]; then
        cleanup_success="false"
    fi

    if [[ "$cleanup_success" == "true" ]]; then
        echo -e "${GREEN}✓ PASS${NC} (${duration}ms)"
        echo "  └─ Zvol before: $zvol_before → Zvol after: $zvol_after ✓"
        echo "  └─ Extent before: $extent_before → Extent after: $extent_after ✓"

        PASSED_TESTS=$((PASSED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_deletion" "PASS" "$duration" \
            "{\"zvol_before\": $zvol_before, \"zvol_after\": $zvol_after, \"extent_before\": $extent_before, \"extent_after\": $extent_after, \"cleanup_complete\": true}"
        add_csv_result "$test_id" "$test_name" "disk_deletion" "PASS" "$duration" "" "" "true" ""
    else
        echo -e "${RED}✗ FAIL${NC} (${duration}ms)"
        echo "  └─ Zvol before: $zvol_before → Zvol after: $zvol_after"
        echo "  └─ Extent before: $extent_before → Extent after: $extent_after"

        FAILED_TESTS=$((FAILED_TESTS + 1))
        add_test_result "$test_id" "$test_name" "disk_deletion" "FAIL" "$duration" \
            "{\"zvol_before\": $zvol_before, \"zvol_after\": $zvol_after, \"extent_before\": $extent_before, \"extent_after\": $extent_after, \"cleanup_complete\": false}"
        add_csv_result "$test_id" "$test_name" "disk_deletion" "FAIL" "$duration" "" "" "false" "Cleanup incomplete"
    fi
}

# ============================================================================
# Main Test Execution
# ============================================================================

main() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║        TrueNAS Plugin Comprehensive Test Suite v1.0               ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo

    log_info "Configuration:"
    log_info "  Storage ID:    $STORAGE_ID"
    log_info "  Node:          $NODE"
    log_info "  VMID Range:    $VMID_START-$VMID_END"
    log_info "  Test Sizes:    ${TEST_SIZES[*]} GB"
    echo

    # Initialize CSV log
    echo "test_id,test_name,category,status,duration_ms,requested_bytes,actual_bytes,size_match,error_message" > "$CSV_LOG"

    # Calculate total expected tests
    TOTAL_EXPECTED=$((${#TEST_SIZES[@]} * 2))  # Allocation + deletion for each size

    echo "════════════════════════════════════════════════════════════════════"
    echo "  CATEGORY: DISK ALLOCATION AND DELETION TESTS"
    echo "════════════════════════════════════════════════════════════════════"
    echo

    local test_num=1
    local vmid=$VMID_START

    # Test each size
    for size in "${TEST_SIZES[@]}"; do
        # Allocation test
        test_disk_allocation "$size" "$vmid" "$test_num"
        test_num=$((test_num + 1))

        # Deletion test
        test_disk_deletion "$vmid" "$test_num"
        test_num=$((test_num + 1))

        vmid=$((vmid + 1))
    done

    # Generate final JSON report
    local end_time
    end_time=$(date +%s)
    local total_duration_ms=$(( (end_time - START_TIME) * 1000 ))

    local api_host
    api_host=$(get_truenas_api)

    local final_json
    final_json=$(jq -n \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg storage_id "$STORAGE_ID" \
        --arg truenas_api "$api_host" \
        --arg node "$NODE" \
        --argjson tests "$JSON_TESTS" \
        --arg total "$TOTAL_TESTS" \
        --arg passed "$PASSED_TESTS" \
        --arg failed "$FAILED_TESTS" \
        --arg skipped "$SKIPPED_TESTS" \
        --arg duration "$total_duration_ms" \
        '{
            test_run: {
                timestamp: $timestamp,
                storage_id: $storage_id,
                truenas_api: $truenas_api,
                node: $node
            },
            tests: $tests,
            summary: {
                total: ($total | tonumber),
                passed: ($passed | tonumber),
                failed: ($failed | tonumber),
                skipped: ($skipped | tonumber),
                duration_total_ms: ($duration | tonumber)
            }
        }')

    echo "$final_json" > "$JSON_LOG"

    # Print summary
    echo
    echo "════════════════════════════════════════════════════════════════════"
    echo "  SUMMARY"
    echo "════════════════════════════════════════════════════════════════════"
    echo
    echo "  Total Tests:     $TOTAL_TESTS"
    echo -e "  Passed:          ${GREEN}$PASSED_TESTS ✓${NC}"

    if [[ $FAILED_TESTS -gt 0 ]]; then
        echo -e "  Failed:          ${RED}$FAILED_TESTS ✗${NC}"
    else
        echo "  Failed:          $FAILED_TESTS"
    fi

    echo "  Skipped:         $SKIPPED_TESTS ⊘"
    echo "  Duration:        $((total_duration_ms / 1000)).$((total_duration_ms % 1000))s"
    echo
    echo "  Logs saved:"
    echo "    - $JSON_LOG"
    echo "    - $CSV_LOG"
    echo

    if [[ $FAILED_TESTS -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main "$@"
