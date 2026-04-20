#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_VERSION="1.3.0"

# Globals
TEMP_DIR=""
TEMP_FILES=()
FIO_BIN=""
DEVICE=""
ENABLE_WRITE=0
QUICK_MODE=0
OUTPUT_FORMAT="text"
TEST_DURATION=60
RAMP_TIME=10
NUM_JOBS=1
FORCE_MODE=0
VERBOSE=0
LIST_ONLY=0

# Storage provisioning globals
PVE_STORAGE=""
DISK_SIZE="10G"
PROV_VMID=""
PROV_VOLID=""
PROV_DEVICE=""
PROV_CLEANUP_NEEDED=0

# Test definitions (name:rw:bs:qd[:mixread])
STD_TESTS=(
    # Sequential read - bandwidth scaling with queue depth
    "seq_read_1M_qd1:read:1M:1"
    "seq_read_1M_qd4:read:1M:4"
    "seq_read_1M_qd16:read:1M:16"
    "seq_read_1M_qd32:read:1M:32"
    # Sequential write - bandwidth scaling with queue depth
    "seq_write_1M_qd1:write:1M:1"
    "seq_write_1M_qd4:write:1M:4"
    "seq_write_1M_qd16:write:1M:16"
    "seq_write_1M_qd32:write:1M:32"
    # Sequential read at different block sizes (QD=16)
    "seq_read_64K_qd16:read:64K:16"
    "seq_read_256K_qd16:read:256K:16"
    "seq_read_512K_qd16:read:512K:16"
    # Sequential write at different block sizes (QD=16)
    "seq_write_64K_qd16:write:64K:16"
    "seq_write_256K_qd16:write:256K:16"
    "seq_write_512K_qd16:write:512K:16"
    # Random 4K read - IOPS scaling with queue depth
    "rand_read_4K_qd1:randread:4K:1"
    "rand_read_4K_qd4:randread:4K:4"
    "rand_read_4K_qd8:randread:4K:8"
    "rand_read_4K_qd16:randread:4K:16"
    "rand_read_4K_qd32:randread:4K:32"
    "rand_read_4K_qd64:randread:4K:64"
    # Random 4K write - IOPS scaling with queue depth
    "rand_write_4K_qd1:randwrite:4K:1"
    "rand_write_4K_qd4:randwrite:4K:4"
    "rand_write_4K_qd8:randwrite:4K:8"
    "rand_write_4K_qd16:randwrite:4K:16"
    "rand_write_4K_qd32:randwrite:4K:32"
    "rand_write_4K_qd64:randwrite:4K:64"
    # Random read at different block sizes (QD=16)
    "rand_read_8K_qd16:randread:8K:16"
    "rand_read_16K_qd16:randread:16K:16"
    "rand_read_64K_qd16:randread:64K:16"
    # Random write at different block sizes (QD=16)
    "rand_write_8K_qd16:randwrite:8K:16"
    "rand_write_16K_qd16:randwrite:16K:16"
    "rand_write_64K_qd16:randwrite:64K:16"
    # Mixed workloads
    "mixed_70_30_4K_qd16:randrw:4K:16:70"
    "mixed_70_30_8K_qd16:randrw:8K:16:70"
    "mixed_50_50_4K_qd16:randrw:4K:16:50"
    "mixed_90_10_4K_qd16:randrw:4K:16:90"
    "mixed_70_30_64K_qd16:randrw:64K:16:70"
)

QUICK_TESTS=(
    "seq_read_1M_qd1:read:1M:1"
    "seq_write_1M_qd1:write:1M:1"
    "rand_read_4K_qd16:randread:4K:16"
    "rand_write_4K_qd16:randwrite:4K:16"
)

# Result storage
declare -a RESULTS=()
declare -a DEVICE_INFO=()
declare -a CURRENT_RESULT=()

# ── Utility Functions ──

die() {
    local msg=$1
    local code=${2:-1}
    printf "ERROR: %s\n" "$msg" >&2
    exit "$code"
}

warn() {
    printf "WARNING: %s\n" "$1" >&2
}

info() {
    if [[ "$OUTPUT_FORMAT" =~ ^(json|html)$ ]]; then
        printf "[INFO] %s\n" "$1" >&2
    else
        printf "[INFO] %s\n" "$1"
    fi
}

section() {
    local title=$1
    local width=${2:-60}
    local line=$(printf '%*s' "$width" '' | tr ' ' '=')
    if [[ "$OUTPUT_FORMAT" =~ ^(json|html)$ ]]; then
        printf "\n%s\n%s\n%s\n" "$line" "$title" "$line" >&2
    else
        printf "\n%s\n%s\n%s\n" "$line" "$title" "$line"
    fi
}

# ── Storage Provisioning ──

# Pick a free VMID in the 990000-990999 range
pick_free_vmid() {
    local existing
    existing=$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n) || true
    for id in $(seq 990000 990999); do
        if ! echo "$existing" | grep -qx "$id"; then
            printf '%d' "$id"
            return 0
        fi
    done
    die "No free VMID in range 990000-990999" 1
}

# Find local hostname for pvesh node parameter
get_local_node() {
    hostname
}

provision_disk() {
    local storage=$1
    local size=$2
    local node
    node=$(get_local_node)

    info "Provisioning disk on storage '$storage' ($size)..."

    # Verify storage exists
    if ! pvesm status -storage "$storage" &>/dev/null; then
        die "Storage '$storage' not found. Run 'pvesm status' to list available storage." 1
    fi

    # Pick a free VMID
    PROV_VMID=$(pick_free_vmid)
    info "Using VMID $PROV_VMID"

    # Create a minimal VM (no disks, no ISO)
    info "Creating temporary VM $PROV_VMID..."
    if ! qm create "$PROV_VMID" \
        --name "fio-bench-tmp" \
        --memory 128 \
        --cores 1 \
        --ostype l26 \
        2>&1; then
        die "Failed to create VM $PROV_VMID" 1
    fi

    # Allocate disk on the target storage
    info "Allocating ${size} disk on $storage..."
    local volid
    volid=$(pvesh create "/nodes/${node}/storage/${storage}/content" \
        --vmid "$PROV_VMID" \
        --filename "vm-${PROV_VMID}-disk-0" \
        --size "$size" \
        2>/dev/null) || die "Failed to allocate disk on storage '$storage'" 1

    # pvesh may return "TASKID:UPID:..." or just the volid
    # Give the storage backend a moment to settle
    sleep 2

    # Look up the actual volid
    PROV_VOLID=$(pvesm list "$storage" --vmid "$PROV_VMID" 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ -z "$PROV_VOLID" ]]; then
        die "Disk was allocated but volid not found in storage '$storage'" 1
    fi
    info "Allocated: $PROV_VOLID"

    # Activate the volume to ensure device appears
    info "Activating volume..."
    pvesm activate "$PROV_VOLID" 2>/dev/null || true
    sleep 1

    # Wait for device to appear and detect multipath
    info "Detecting device (waiting for multipath)..."
    local found_device=""
    local attempts=0
    local max_attempts=40  # 20 seconds

    while [[ $attempts -lt $max_attempts ]]; do
        udevadm settle 2>/dev/null || true

        # Check if the volume has a dm-* device (multipath)
        # Parse volid to find the LUN and look for by-path devices
        # The volid format is typically: STORAGE:vm-VMID-disk-N
        local vol_name="${PROV_VOLID#*:}"

        # Find the most recently appeared dm-* multipath device
        local newest_dm=""
        local newest_time=0
        for dm in /sys/block/dm-*/slaves; do
            [[ -d "$dm" ]] || continue
            local slaves_count
            slaves_count=$(ls "$dm" 2>/dev/null | wc -l) || continue
            # Only consider multipath devices (2+ slaves)
            [[ $slaves_count -ge 2 ]] || continue
            local dm_name
            dm_name=$(basename "$(dirname "$dm")")
            local dm_path="/sys/block/$dm_name"
            local dm_mtime
            dm_mtime=$(stat -c %Y "$dm_path" 2>/dev/null) || continue
            if [[ $dm_mtime -gt $newest_time ]]; then
                newest_time=$dm_mtime
                newest_dm="/dev/$dm_name"
            fi
        done
        [[ -n "$newest_dm" ]] && found_device="$newest_dm"

        if [[ -n "$found_device" && -b "$found_device" ]]; then
            break
        fi

        # Trigger rescan
        iscsiadm -m session -R 2>/dev/null || true
        multipath -r 2>/dev/null || true
        sleep 0.5
        attempts=$((attempts + 1))
    done

    if [[ -z "$found_device" || ! -b "$found_device" ]]; then
        die "Timed out waiting for device to appear. Check 'multipath -ll' and 'pvesm list $storage'" 1
    fi

    PROV_DEVICE="$found_device"
    PROV_CLEANUP_NEEDED=1

    # Check if multipath
    local dm_name="${PROV_DEVICE#/dev/}"
    dm_name="${dm_name#mapper/}"
    if [[ "$PROV_DEVICE" =~ /dev/dm- ]]; then
        local slaves=()
        mapfile -t slaves < <(get_dm_slaves "$(basename "$PROV_DEVICE")")
        if [[ ${#slaves[@]} -ge 2 ]]; then
            info "Multipath device detected: $PROV_DEVICE (${#slaves[@]} paths: ${slaves[*]})"
        else
            info "Device: $PROV_DEVICE (single path)"
        fi
    else
        info "Device: $PROV_DEVICE"
    fi

    DEVICE="$PROV_DEVICE"
}

cleanup_provisioned() {
    if [[ $PROV_CLEANUP_NEEDED -eq 0 ]]; then
        return 0
    fi

    info "Cleaning up provisioned resources..."

    # Get VMID from global
    local vmid="$PROV_VMID"

    if [[ -n "$vmid" ]]; then
        # Destroy VM (this also frees disks)
        info "Destroying VM $vmid..."
        if ! qm destroy "$vmid" --purge 2>/dev/null; then
            # Fallback: try to free disk manually then destroy
            if [[ -n "$PROV_VOLID" ]]; then
                warn "VM destroy failed, attempting manual disk cleanup..."
                pvesm free "$PROV_VOLID" 2>/dev/null || true
            fi
            qm destroy "$vmid" --purge 2>/dev/null || true
        fi
    fi

    # Flush any orphaned multipath maps
    multipath -r 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    PROV_CLEANUP_NEEDED=0
    info "Cleanup complete."
}

# ── Cleanup ──

cleanup() {
    local exit_code=$?

    # Kill any running fio processes
    pkill -9 -P $$ fio 2>/dev/null || true

    # Remove temp files
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done

    # Remove temp dir
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rmdir "$TEMP_DIR" 2>/dev/null || true
    fi

    # Clean up provisioned VM/disk if applicable
    cleanup_provisioned 2>/dev/null || true

    exit $exit_code
}

trap cleanup EXIT INT TERM HUP

# ── Multipath Detection ──

detect_multipath_devices() {
    local devices=()

    for dm in /sys/block/dm-*/slaves; do
        [[ -d "$dm" ]] || continue
        local dm_name=$(basename "$(dirname "$dm")")
        devices+=("$dm_name")
    done

    printf '%s\n' "${devices[@]}"
}

get_dm_slaves() {
    local dm_device=$1
    local slaves_path="/sys/block/$dm_device/slaves"

    [[ -d "$slaves_path" ]] || return 1

    for slave in "$slaves_path"/*; do
        [[ -e "$slave" ]] && basename "$slave"
    done
}

get_dm_name() {
    local dm_device=$1
    local name_file="/sys/block/$dm_device/dm/name"

    if [[ -f "$name_file" ]]; then
        cat "$name_file"
    else
        return 1
    fi
}

get_dm_uuid() {
    local dm_device=$1
    local uuid_file="/sys/block/$dm_device/dm/uuid"

    if [[ -f "$uuid_file" ]]; then
        cat "$uuid_file"
    else
        return 1
    fi
}

get_multipath_topology() {
    local device=$1
    local dm_device=""

    # Convert device to dm-X format
    if [[ "$device" =~ /dev/dm-([0-9]+) ]]; then
        dm_device="dm-${BASH_REMATCH[1]}"
    elif [[ "$device" =~ /dev/mapper/(.+) ]]; then
        # Resolve mapper name to dm-X
        for dm in /sys/block/dm-*/dm/name; do
            if [[ -f "$dm" && "$(cat "$dm")" == "${BASH_REMATCH[1]}" ]]; then
                dm_device=$(basename "$(dirname "$(dirname "$dm")")")
                break
            fi
        done
    elif [[ "$device" =~ ^dm-([0-9]+)$ ]]; then
        dm_device="$device"
    fi

    [[ -z "$dm_device" ]] && return 1

    local name
    name=$(get_dm_name "$dm_device") || name="unknown"
    local uuid
    uuid=$(get_dm_uuid "$dm_device") || uuid="unknown"

    # Try to get multipath -ll output
    local mp_output=""
    if command -v multipath &>/dev/null; then
        mp_output=$(multipath -ll "$name" 2>/dev/null || echo "")
    fi

    # Parse policy from multipath output
    local policy=""
    if [[ "$mp_output" =~ policy[:[:space:]]+([^\n]+) ]]; then
        policy="${BASH_REMATCH[1]}"
    fi

    # Get slaves
    local slaves=()
    mapfile -t slaves < <(get_dm_slaves "$dm_device")

    # Build topology info
    DEVICE_INFO=(
        "device:$device"
        "dm_device:$dm_device"
        "name:$name"
        "uuid:$uuid"
        "policy:$policy"
        "num_paths:${#slaves[@]}"
    )

    for slave in "${slaves[@]}"; do
        DEVICE_INFO+=("path:$slave")
    done
}

check_nvme_multipath() {
    # Check if NVMe native multipath is enabled
    local mp_param="/sys/module/nvme_core/parameters/multipath"

    if [[ -f "$mp_param" && "$(cat "$mp_param")" == "Y" ]]; then
        return 0
    fi
    return 1
}

list_devices() {
    section "Detected Multipath Devices"

    local found=0
    for dm in /sys/block/dm-*/slaves; do
        [[ -d "$dm" ]] || continue
        ((found++)) || true

        local dm_name=$(basename "$(dirname "$dm")")
        local map_name
        map_name=$(get_dm_name "$dm_name") 2>/dev/null || map_name="unknown"
        local uuid
        uuid=$(get_dm_uuid "$dm_name") 2>/dev/null || uuid="unknown"

        printf "\nDevice: /dev/%s (/dev/mapper/%s)\n" "$dm_name" "$map_name" >&2
        printf "  UUID: %s\n" "$uuid" >&2

        # Get slaves
        local slaves=()
        mapfile -t slaves < <(get_dm_slaves "$dm_name")

        printf "  Paths (%d):\n" "${#slaves[@]}" >&2
        for slave in "${slaves[@]}"; do
            local major_minor=$(cat "/sys/block/$slave/dev" 2>/dev/null || echo "?")
            printf "    - %s (%s)\n" "$slave" "$major_minor" >&2
        done

        # Try to get multipath info
        if command -v multipath &>/dev/null; then
            local mp_info
            mp_info=$(multipath -ll "$map_name" 2>/dev/null || echo "")
            if [[ -n "$mp_info" ]]; then
                printf "  Multipath: %s\n" "$mp_info" | head -1 >&2
            fi
        fi
    done

    if [[ $found -eq 0 ]]; then
        printf "\nNo multipath devices detected.\n" >&2
        if check_nvme_multipath; then
            printf "NVMe native multipath is enabled.\n" >&2
            printf "NVMe subsystems:\n" >&2
            for sub in /sys/class/nvme-subsystem/*/nvme*; do
                [[ -d "$sub" ]] || continue
                local sub_name=$(basename "$(dirname "$sub")")
                local ctrl=$(basename "$sub")
                printf "  - %s (%s)\n" "$sub_name" "$ctrl" >&2
            done
        fi
    fi

    return 0
}

# ── Device Validation ──

resolve_device() {
    local input=$1

    # Already a device node
    if [[ -b "$input" ]]; then
        printf '%s' "$input"
        return 0
    fi

    # Mapper name
    if [[ -b "/dev/mapper/$input" ]]; then
        printf '/dev/mapper/%s' "$input"
        return 0
    fi

    # dm-X name
    if [[ "$input" =~ ^dm-[0-9]+$ && -b "/dev/$input" ]]; then
        printf '/dev/%s' "$input"
        return 0
    fi

    # Try to resolve from by-id
    for id in /dev/disk/by-id/*; do
        [[ -e "$id" ]] || continue
        local target=$(readlink -f "$id")
        local base=$(basename "$target")
        if [[ "$base" == "$input" || "$target" == "/dev/$input" ]]; then
            printf '%s' "$target"
            return 0
        fi
    done

    return 1
}

validate_device() {
    local device=$1

    [[ -b "$device" ]] || die "Not a block device: $device" 2

    # Check if mounted - try both direct path and resolved device
    local resolved=$(readlink -f "$device")
    local mounted=0

    # Check if device or its resolved path is in /proc/mounts
    if grep -q "^$device " /proc/mounts 2>/dev/null; then
        mounted=1
    elif [[ -n "$resolved" && "$resolved" != "$device" ]] && grep -q "^$resolved " /proc/mounts 2>/dev/null; then
        mounted=1
    fi

    if [[ $mounted -eq 1 ]]; then
        if [[ $FORCE_MODE -eq 0 ]]; then
            die "Device is mounted: $device (use --force to override)" 2
        else
            warn "Device is mounted but proceeding due to --force"
        fi
    fi

    # Check writable if write tests enabled
    if [[ $ENABLE_WRITE -eq 1 && ! -w "$device" ]]; then
        die "Device not writable: $device" 2
    fi

    return 0
}

# ── FIO Test Execution ──

check_fio() {
    if ! command -v fio &>/dev/null; then
        die "fio not found. Please install: apt-get install fio" 3
    fi

    FIO_BIN=$(command -v fio)

    # Check for JSON support
    if ! "$FIO_BIN" --version | grep -q "fio-3"; then
        warn "fio version may not support JSON output"
    fi
}

parse_fio_json() {
    local json_file=$1
    local test_name=$2

    CURRENT_RESULT=()

    # Try jq first
    if command -v jq &>/dev/null; then
        local bw iops lat_avg lat_min lat_max lat_p95 lat_p99

        # Pick the stats section with actual I/O: mixed > write > read
        local stats_sel
        stats_sel=$(jq -r '
          if (.jobs[0].mixed.io_bytes // 0) > 0 then "mixed"
          elif (.jobs[0].write.io_bytes // 0) > 0 then "write"
          else "read" end
        ' "$json_file" 2>/dev/null)

        bw=$(jq -r ".jobs[0].${stats_sel}.bw_bytes // 0" "$json_file" 2>/dev/null)
        iops=$(jq -r ".jobs[0].${stats_sel}.iops // 0" "$json_file" 2>/dev/null)
        lat_avg=$(jq -r ".jobs[0].${stats_sel}.lat_ns.mean // .jobs[0].${stats_sel}.clat_ns.mean // 0" "$json_file" 2>/dev/null)
        lat_min=$(jq -r ".jobs[0].${stats_sel}.lat_ns.min // .jobs[0].${stats_sel}.clat_ns.min // 0" "$json_file" 2>/dev/null)
        lat_max=$(jq -r ".jobs[0].${stats_sel}.lat_ns.max // .jobs[0].${stats_sel}.clat_ns.max // 0" "$json_file" 2>/dev/null)

        # Percentiles from the selected stats section
        lat_p95=$(jq -r ".jobs[0].${stats_sel}.clat_ns.percentile // .jobs[0].${stats_sel}.lat_ns.percentile // {} | to_entries | map(select(.key | tonumber >= 95 and tonumber < 96)) | .[0].value // 0" "$json_file" 2>/dev/null)
        lat_p99=$(jq -r ".jobs[0].${stats_sel}.clat_ns.percentile // .jobs[0].${stats_sel}.lat_ns.percentile // {} | to_entries | map(select(.key | tonumber >= 99)) | .[0].value // 0" "$json_file" 2>/dev/null)

        # Convert from bytes/nanos to MB/ms
        bw_mb=$(awk "BEGIN {printf \"%.2f\", $bw/1048576}")
        lat_avg_ms=$(awk "BEGIN {printf \"%.2f\", $lat_avg/1000000}")
        lat_min_ms=$(awk "BEGIN {printf \"%.2f\", $lat_min/1000000}")
        lat_max_ms=$(awk "BEGIN {printf \"%.2f\", $lat_max/1000000}")
        lat_p95_ms=$(awk "BEGIN {printf \"%.2f\", $lat_p95/1000000}")
        lat_p99_ms=$(awk "BEGIN {printf \"%.2f\", $lat_p99/1000000}")

        CURRENT_RESULT=(
            "test_name:$test_name"
            "bw_bytes:$bw"
            "bw_mb:$bw_mb"
            "iops:${iops%.*}"
            "lat_avg_ms:$lat_avg_ms"
            "lat_min_ms:$lat_min_ms"
            "lat_max_ms:$lat_max_ms"
            "lat_p95_ms:$lat_p95_ms"
            "lat_p99_ms:$lat_p99_ms"
        )
        return 0
    fi

    # Fallback to Python
    if command -v python3 &>/dev/null; then
        local output
        output=$(python3 -c "
import json, sys
try:
    with open('$json_file', 'r') as f:
        data = json.load(f)
    job = data['jobs'][0]

    # Get read/write/mixed stats
    read_stats = job.get('read', {})
    write_stats = job.get('write', {})
    mixed_stats = job.get('mixed', {})

    # Use whichever has data (prefer mixed, then read, then write)
    stats = mixed_stats if mixed_stats.get('bw_bytes', 0) > 0 else read_stats
    if stats.get('bw_bytes', 0) == 0:
        stats = write_stats if write_stats.get('bw_bytes', 0) > 0 else read_stats

    bw = stats.get('bw_bytes', 0)
    iops = int(stats.get('iops', 0))

    lat_ns = stats.get('lat_ns', {})
    if not lat_ns:
        lat_ns = stats.get('clat_ns', {})
    if not lat_ns:
        lat_ns = stats.get('latency', {})

    lat_avg = int(lat_ns.get('mean', 0))
    lat_min = int(lat_ns.get('min', 0))
    lat_max = int(lat_ns.get('max', 0))

    # Percentiles - FIO returns them as key-value pairs like "95.000000": 180
    pct = lat_ns.get('percentile', {})
    if isinstance(pct, dict):
        # Find closest to 95th and 99th percentile
        p95_vals = {k: v for k, v in pct.items() if 94.9 <= float(k) <= 95.1}
        p99_vals = {k: v for k, v in pct.items() if float(k) >= 99}
        lat_p95 = int(list(p95_vals.values())[0]) if p95_vals else 0
        lat_p99 = int(list(p99_vals.values())[0]) if p99_vals else 0
    else:
        lat_p95 = 0
        lat_p99 = 0

    bw_mb = bw / 1048576
    lat_avg_ms = lat_avg / 1000000
    lat_min_ms = lat_min / 1000000
    lat_max_ms = lat_max / 1000000
    lat_p95_ms = lat_p95 / 1000000
    lat_p99_ms = lat_p99 / 1000000

    print(f'{bw}:{bw_mb:.2f}:{iops}:{lat_avg_ms:.3f}:{lat_min_ms:.3f}:{lat_max_ms:.3f}:{lat_p95_ms:.3f}:{lat_p99_ms:.3f}')
except Exception as e:
    print(f'0:0.0:0:0:0:0:0:0', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || {
            CURRENT_RESULT=("test_name:$test_name" "status:error")
            return 1
        }

        IFS=: read -r bw bw_mb iops lat_avg lat_min lat_max lat_p95 lat_p99 <<< "$output"
        CURRENT_RESULT=(
            "test_name:$test_name"
            "bw_bytes:$bw"
            "bw_mb:$bw_mb"
            "iops:$iops"
            "lat_avg_ms:$lat_avg"
            "lat_min_ms:$lat_min"
            "lat_max_ms:$lat_max"
            "lat_p95_ms:$lat_p95"
            "lat_p99_ms:$lat_p99"
        )
        return 0
    fi

    # Last resort: grep for values
    local bw iops lat
    bw=$(grep -o '"bw_bytes":[0-9]*' "$json_file" | head -1 | cut -d: -f2)
    iops=$(grep -o '"iops":[0-9.]*' "$json_file" | head -1 | cut -d: -f2)

    CURRENT_RESULT=(
        "test_name:$test_name"
        "bw_bytes:$bw"
        "bw_mb:$(awk "BEGIN {printf \"%.2f\", $bw/1048576}")"
        "iops:${iops%.*}"
        "lat_avg_ms:0"
        "lat_min_ms:0"
        "lat_max_ms:0"
        "lat_p95_ms:0"
        "lat_p99_ms:0"
    )
    return 0
}

run_fio_test() {
    local device=$1
    local test_name=$2
    local rw=$3
    local bs=$4
    local qd=$5
    local mixread=${6:-0}

    local temp_json="${TEMP_DIR}/fio_${test_name}_$$.json"
    TEMP_FILES+=("$temp_json")

    local fio_args=(
        --name="$test_name"
        --filename="$device"
        --rw="$rw"
        --bs="$bs"
        --iodepth="$qd"
        --numjobs="$NUM_JOBS"
        --direct=1
        --ioengine=libaio
        --time_based
        --runtime="$TEST_DURATION"
        --ramp_time="$RAMP_TIME"
        --norandommap=1
        --refill_buffers=1
        --group_reporting
        --output-format=json
        --output="$temp_json"
    )

    if [[ $mixread -gt 0 ]]; then
        fio_args+=(--rwmixread="$mixread")
    fi

    if [[ $VERBOSE -eq 1 ]]; then
        fio_args+=(--verbose=1)
    fi

    if [[ $ENABLE_WRITE -eq 0 && "$rw" =~ (write|randrw) ]]; then
        return 0
    fi

    info "Running: $test_name"

    if ! "$FIO_BIN" "${fio_args[@]}" 2>/dev/null; then
        warn "Test failed: $test_name"
        RESULTS+=("test_name:$test_name" "status:failed")
        return 1
    fi

    # Parse results
    parse_fio_json "$temp_json" "$test_name"

    # Store for output
    for entry in "${CURRENT_RESULT[@]}"; do
        RESULTS+=("$entry")
    done
    RESULTS+=("status:success") # Mark test as successful
    RESULTS+=("---") # Separator

    return 0
}

run_test_suite() {
    local device=$1

    section "Running FIO Benchmark" 60

    local -a tests=()
    if [[ $QUICK_MODE -eq 1 ]]; then
        tests=("${QUICK_TESTS[@]}")
    else
        tests=("${STD_TESTS[@]}")
    fi

    for test_spec in "${tests[@]}"; do
        IFS=: read -r name rw bs qd mixread <<< "$test_spec"

        # Skip write tests if not enabled
        if [[ $ENABLE_WRITE -eq 0 && "$rw" =~ (write|randrw) ]]; then
            continue
        fi

        run_fio_test "$device" "$name" "$rw" "$bs" "$qd" "$mixread" || true
    done
}

# ── Output Formatting ──

_topo_printf() {
    if [[ "$OUTPUT_FORMAT" =~ ^(json|html)$ ]]; then
        printf "$@" >&2
    else
        printf "$@"
    fi
}

print_topology() {
    section "Device Information" 60

    for entry in "${DEVICE_INFO[@]}"; do
        IFS=: read -r key value <<< "$entry"
        case "$key" in
            device) _topo_printf "Device: %s\n" "$value" ;;
            dm_device) _topo_printf "  Kernel node: %s\n" "$value" ;;
            name) _topo_printf "  Mapper name: %s\n" "$value" ;;
            uuid) _topo_printf "  UUID: %s\n" "$value" ;;
            policy) [[ -n "$value" ]] && _topo_printf "  Policy: %s\n" "$value" ;;
            num_paths) _topo_printf "  Paths: %s\n" "$value" ;;
            path)
                local path_name="$value"
                local major_minor
                major_minor=$(cat "/sys/block/$path_name/dev" 2>/dev/null || echo "?")
                _topo_printf "    - %s (%s)\n" "$path_name" "$major_minor"
                ;;
        esac
    done

    _topo_printf "  Test duration: %ds per test\n" "$TEST_DURATION"
    _topo_printf "  Ramp time: %ds\n" "$RAMP_TIME"
    local write_status="disabled"
    [[ $ENABLE_WRITE -eq 1 ]] && write_status="enabled"
    _topo_printf "  Write tests: %s\n" "$write_status"
}

print_text_results() {
    section "Benchmark Results" 60

    printf "\n%-22s %12s %12s %10s %10s %10s\n" \
        "Test Name" "BW(MB/s)" "IOPS" "Avg(ms)" "P95(ms)" "P99(ms)"
    printf "%s\n" "$(printf '%.0s-' {1..68})"

    local current_test=""
    local bw_mb iops lat_avg lat_p95 lat_p99

    for entry in "${RESULTS[@]}"; do
        IFS=: read -r key value <<< "$entry"

        case "$key" in
            ---)
                if [[ -n "$current_test" ]]; then
                    printf "%-22s %12s %12s %10s %10s %10s\n" \
                        "$current_test" "${bw_mb:-N/A}" "${iops:-N/A}" \
                        "${lat_avg:-N/A}" "${lat_p95:-N/A}" "${lat_p99:-N/A}"
                fi
                current_test=""
                bw_mb="" iops="" lat_avg="" lat_p95="" lat_p99=""
                ;;
            test_name)
                current_test="$value"
                ;;
            bw_mb)
                bw_mb="$value"
                ;;
            iops)
                # Format with commas
                iops=$(printf "%'d" "$value" 2>/dev/null || echo "$value")
                ;;
            lat_avg_ms)
                lat_avg="$value"
                ;;
            lat_p95_ms)
                lat_p95="$value"
                ;;
            lat_p99_ms)
                lat_p99="$value"
                ;;
            status)
                if [[ "$value" == "failed" ]]; then
                    printf "%-22s %12s\n" "$current_test" "FAILED"
                    current_test=""
                fi
                ;;
        esac
    done

    # Print last result
    if [[ -n "$current_test" ]]; then
        printf "%-22s %12s %12s %10s %10s %10s\n" \
            "$current_test" "${bw_mb:-N/A}" "${iops:-N/A}" \
            "${lat_avg:-N/A}" "${lat_p95:-N/A}" "${lat_p99:-N/A}"
    fi

    printf "\n"
}

print_json_results() {
    local json="{\n"
    json+="  \"metadata\": {\n"

    # Device info
    local dev_name="" dm_node="" wwid="" policy="" num_paths=0
    declare -a paths=()

    for entry in "${DEVICE_INFO[@]}"; do
        IFS=: read -r key value <<< "$entry"
        case "$key" in
            device) dev_name="$value" ;;
            dm_device) dm_node="$value" ;;
            uuid) wwid="$value" ;;
            policy) policy="$value" ;;
            num_paths) num_paths="$value" ;;
            path) paths+=("$value") ;;
        esac
    done

    json+="    \"device\": \"$dev_name\",\n"
    json+="    \"device_node\": \"$dm_node\",\n"
    json+="    \"wwid\": \"$wwid\",\n"
    [[ -n "$policy" ]] && json+="    \"multipath_policy\": \"$policy\",\n"
    json+="    \"num_paths\": $num_paths,\n"
    json+="    \"paths\": [\n"

    for i in "${!paths[@]}"; do
        local p="${paths[$i]}"
        local major_minor=$(cat "/sys/block/$p/dev" 2>/dev/null || echo "?")
        json+="      {\"name\": \"$p\", \"major:minor\": \"$major_minor\"}"
        [[ $i -lt $((${#paths[@]} - 1)) ]] && json+=","
        json+="\n"
    done

    json+="    ],\n"
    json+="    \"test_date\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\n"
    json+="    \"test_duration_seconds\": $TEST_DURATION\n"
    json+="  },\n"
    json+="  \"results\": [\n"

    # Build results array
    local current_test=""
    local result_count=0
    local bw_bytes bw_mb iops lat_avg lat_min lat_max lat_p95 lat_p99

    for entry in "${RESULTS[@]}"; do
        IFS=: read -r key value <<< "$entry"

        case "$key" in
            ---)
                if [[ -n "$current_test" ]]; then
                    [[ $result_count -gt 0 ]] && json+=",\n"
                    json+="    {\n"
                    json+="      \"test_name\": \"$current_test\",\n"
                    json+="      \"bandwidth_bytes_s\": ${bw_bytes:-0},\n"
                    json+="      \"bandwidth_mb_s\": ${bw_mb:-0},\n"
                    json+="      \"iops\": ${iops:-0},\n"
                    json+="      \"latency_ms\": {\n"
                    json+="        \"avg\": ${lat_avg:-0},\n"
                    json+="        \"min\": ${lat_min:-0},\n"
                    json+="        \"max\": ${lat_max:-0},\n"
                    json+="        \"p95\": ${lat_p95:-0},\n"
                    json+="        \"p99\": ${lat_p99:-0}\n"
                    json+="      }\n"
                    json+="    }"
                    result_count=$((result_count + 1))
                fi
                current_test=""
                bw_bytes="" bw_mb="" iops="" lat_avg="" lat_min="" lat_max="" lat_p95="" lat_p99=""
                ;;
            test_name)
                current_test="$value"
                ;;
            bw_bytes)
                bw_bytes="$value"
                ;;
            bw_mb)
                bw_mb="$value"
                ;;
            iops)
                iops="$value"
                ;;
            lat_avg_ms)
                lat_avg="$value"
                ;;
            lat_min_ms)
                lat_min="$value"
                ;;
            lat_max_ms)
                lat_max="$value"
                ;;
            lat_p95_ms)
                lat_p95="$value"
                ;;
            lat_p99_ms)
                lat_p99="$value"
                ;;
        esac
    done

    # Last result
    if [[ -n "$current_test" ]]; then
        [[ $result_count -gt 0 ]] && json+=",\n"
        json+="    {\n"
        json+="      \"test_name\": \"$current_test\",\n"
        json+="      \"bandwidth_bytes_s\": ${bw_bytes:-0},\n"
        json+="      \"bandwidth_mb_s\": ${bw_mb:-0},\n"
        json+="      \"iops\": ${iops:-0},\n"
        json+="      \"latency_ms\": {\n"
        json+="        \"avg\": ${lat_avg:-0},\n"
        json+="        \"min\": ${lat_min:-0},\n"
        json+="        \"max\": ${lat_max:-0},\n"
        json+="        \"p95\": ${lat_p95:-0},\n"
        json+="        \"p99\": ${lat_p99:-0}\n"
        json+="      }\n"
        json+="    }"
    fi

    json+="\n  ]\n}\n"

    printf '%b' "$json"
}

print_html_results() {
    local html_file="fio-results_$(date +%Y%m%d_%H%M%S).html"
    local device_display=""
    local dm_node="" wwid="" policy="" num_paths=0
    declare -a paths=()

    # Escape function for JSON/HTML safety
    escape_json() {
        printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/&/\\u0026/g; s/</\\u003c/g; s/>/\\u003e/g'
    }

    # Extract device info
    for entry in "${DEVICE_INFO[@]}"; do
        IFS=: read -r key value <<< "$entry"
        case "$key" in
            device) device_display=$(escape_json "$value") ;;
            dm_device) dm_node=$(escape_json "$value") ;;
            uuid) wwid=$(escape_json "$value") ;;
            policy) policy=$(escape_json "$value") ;;
            num_paths) num_paths="$value" ;;
            path) paths+=("$(escape_json "$value")") ;;
        esac
    done

    # Build results JSON for embedding
    local results_json="["
    local first_result=1

    local current_test=""
    local bw_bytes bw_mb iops lat_avg lat_min lat_max lat_p95 lat_p99

    for entry in "${RESULTS[@]}"; do
        IFS=: read -r key value <<< "$entry"

        case "$key" in
            ---)
                if [[ -n "$current_test" ]]; then
                    [[ $first_result -eq 0 ]] && results_json+=","
                    first_result=0
                    local escaped_test=$(escape_json "$current_test")
                    results_json+="{\"test_name\":\"${escaped_test}\",\"bw_bytes\":${bw_bytes:-0},\"bw_mb\":${bw_mb:-0},\"iops\":${iops:-0},\"lat_avg_ms\":${lat_avg:-0},\"lat_min_ms\":${lat_min:-0},\"lat_max_ms\":${lat_max:-0},\"lat_p95_ms\":${lat_p95:-0},\"lat_p99_ms\":${lat_p99:-0}}"
                fi
                current_test=""
                bw_bytes="" bw_mb="" iops="" lat_avg="" lat_min="" lat_max="" lat_p95="" lat_p99=""
                ;;
            test_name)
                current_test="$value"
                ;;
            bw_bytes)
                bw_bytes="$value"
                ;;
            bw_mb)
                bw_mb="$value"
                ;;
            iops)
                iops="$value"
                ;;
            lat_avg_ms)
                lat_avg="$value"
                ;;
            lat_min_ms)
                lat_min="$value"
                ;;
            lat_max_ms)
                lat_max="$value"
                ;;
            lat_p95_ms)
                lat_p95="$value"
                ;;
            lat_p99_ms)
                lat_p99="$value"
                ;;
        esac
    done

    # Last result
    if [[ -n "$current_test" ]]; then
        [[ $first_result -eq 0 ]] && results_json+=","
        local escaped_test=$(escape_json "$current_test")
        results_json+="{\"test_name\":\"${escaped_test}\",\"bw_bytes\":${bw_bytes:-0},\"bw_mb\":${bw_mb:-0},\"iops\":${iops:-0},\"lat_avg_ms\":${lat_avg:-0},\"lat_min_ms\":${lat_min:-0},\"lat_max_ms\":${lat_max:-0},\"lat_p95_ms\":${lat_p95:-0},\"lat_p99_ms\":${lat_p99:-0}}"
    fi

    results_json+="]"

    # Build paths array JSON
    local paths_json="["
    for i in "${!paths[@]}"; do
        [[ $i -gt 0 ]] && paths_json+=","
        paths_json+="\"${paths[$i]}\""
    done
    paths_json+="]"

    # Generate HTML
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FIO Benchmark - ${device_display} - $(date +%Y-%m-%d)</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        :root {
            --canvas: #0d1117;
            --surface-0: #161b22;
            --surface-1: #21262d;
            --surface-2: #30363d;
            --ink: #e6edf3;
            --ink-2: #8b949e;
            --ink-3: #6e7681;
            --border: rgba(240,246,252,0.1);
            --border-em: rgba(240,246,252,0.2);
            --accent-read: #f0a030;
            --accent-write: #f85149;
            --accent-mixed: #3fb950;
            --accent-blue: #58a6ff;
            --accent-lat: #d29922;
            --control-bg: #21262d;
            --control-border: #30363d;
            --row-even: rgba(110,118,129,0.05);
            --row-hover: rgba(110,118,129,0.15);
            --header-bg: #010409;
            --header-border: rgba(240,246,252,0.08);
            --chart-read: #f0a030;
            --chart-write: #f85149;
            --chart-mixed: #3fb950;
            --chart-blue: #58a6ff;
            --chart-grid: rgba(240,246,252,0.06);
            --chart-text: #8b949e;
        }
        [data-theme="light"] {
            --canvas: #f6f8fa;
            --surface-0: #ffffff;
            --surface-1: #f6f8fa;
            --surface-2: #eaeef2;
            --ink: #1f2328;
            --ink-2: #656d76;
            --ink-3: #8c959f;
            --border: rgba(31,35,40,0.12);
            --border-em: rgba(31,35,40,0.25);
            --control-bg: #f6f8fa;
            --control-border: #d0d7de;
            --row-even: rgba(175,184,193,0.06);
            --row-hover: rgba(175,184,193,0.12);
            --header-bg: #1f2328;
            --header-border: rgba(31,35,40,0.15);
            --chart-read: #8b5e00;
            --chart-write: #a02020;
            --chart-mixed: #1a6b2a;
            --chart-blue: #0356b0;
            --chart-grid: rgba(31,35,40,0.08);
            --chart-text: #4a5568;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--canvas);
            color: var(--ink);
            line-height: 1.5;
        }
        header {
            background: var(--header-bg);
            border-bottom: 1px solid var(--header-border);
            padding: 1rem 2rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        header h1 {
            font-size: 1rem;
            font-weight: 600;
            letter-spacing: -0.01em;
            color: var(--ink);
            font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
        }
        header .meta {
            font-size: 0.75rem;
            color: var(--ink-3);
            font-family: 'SF Mono', Monaco, monospace;
            margin-top: 0.2rem;
        }
        .theme-toggle {
            background: var(--surface-1);
            border: 1px solid var(--border);
            color: var(--ink-2);
            padding: 0.3rem 0.6rem;
            border-radius: 3px;
            cursor: pointer;
            font-size: 0.75rem;
            font-family: 'SF Mono', Monaco, monospace;
            transition: border-color 0.15s;
            white-space: nowrap;
        }
        .theme-toggle:hover { border-color: var(--border-em); color: var(--ink); }
        .container { max-width: 1400px; margin: 0 auto; padding: 1.5rem 2rem; }
        .section-title {
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--ink-2);
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.5rem;
            margin: 1.5rem 0 1rem;
            font-family: 'SF Mono', Monaco, monospace;
        }
        .mvp-cards {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 0.75rem;
            margin-bottom: 1.5rem;
        }
        @media (max-width: 900px) { .mvp-cards { grid-template-columns: repeat(2, 1fr); } }
        @media (max-width: 500px) { .mvp-cards { grid-template-columns: 1fr; } }
        .mvp-card {
            background: var(--surface-0);
            border: 1px solid var(--border);
            border-left: 3px solid var(--mvp-accent);
            border-radius: 3px;
            padding: 0.85rem 1rem;
        }
        .mvp-card-iops    { --mvp-accent: var(--accent-mixed); }
        .mvp-card-readbw  { --mvp-accent: var(--accent-read); }
        .mvp-card-writebw { --mvp-accent: var(--accent-write); }
        .mvp-card-latency { --mvp-accent: var(--accent-lat); }
        .mvp-label {
            font-size: 0.6rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--ink-3);
            margin-bottom: 0.3rem;
            font-family: 'SF Mono', Monaco, monospace;
        }
        .mvp-value {
            font-size: 1.3rem;
            font-weight: 700;
            color: var(--ink);
            font-variant-numeric: tabular-nums;
            font-family: 'SF Mono', Monaco, monospace;
            margin-bottom: 0.1rem;
        }
        .mvp-detail {
            font-size: 0.65rem;
            color: var(--ink-3);
            font-family: 'SF Mono', Monaco, monospace;
        }
        .charts {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 0.75rem;
        }
        @media (max-width: 900px) { .charts { grid-template-columns: 1fr; } }
        .chart-container {
            background: var(--surface-0);
            border: 1px solid var(--border);
            border-radius: 3px;
            padding: 0.85rem;
        }
        .chart-container h3 {
            font-size: 0.65rem;
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--ink-2);
            margin-bottom: 0.6rem;
            font-family: 'SF Mono', Monaco, monospace;
        }
        .chart-container canvas { max-height: 280px; }
        .table-container {
            background: var(--surface-0);
            border: 1px solid var(--border);
            border-radius: 3px;
            padding: 1rem;
            overflow-x: auto;
        }
        .table-controls {
            display: flex;
            gap: 0.5rem;
            margin-bottom: 0.75rem;
            align-items: center;
            flex-wrap: wrap;
        }
        .table-controls input {
            padding: 0.35rem 0.6rem;
            border: 1px solid var(--control-border);
            border-radius: 3px;
            background: var(--control-bg);
            color: var(--ink);
            font-size: 0.78rem;
            font-family: 'SF Mono', Monaco, monospace;
            min-width: 180px;
        }
        .table-controls input::placeholder { color: var(--ink-3); }
        .filter-btn {
            padding: 0.25rem 0.55rem;
            border: 1px solid var(--border);
            border-radius: 3px;
            background: transparent;
            color: var(--ink-2);
            cursor: pointer;
            font-size: 0.65rem;
            font-family: 'SF Mono', Monaco, monospace;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            transition: all 0.12s;
        }
        .filter-btn:hover { border-color: var(--border-em); color: var(--ink); }
        .filter-btn.active {
            background: var(--ink);
            color: var(--canvas);
            border-color: var(--ink);
        }
        table { width: 100%; border-collapse: collapse; font-size: 0.78rem; }
        th, td {
            padding: 0.45rem 0.7rem;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }
        th {
            font-weight: 500;
            font-size: 0.65rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--ink-2);
            position: sticky;
            top: 0;
            background: var(--surface-0);
            cursor: pointer;
            user-select: none;
        }
        th:hover { color: var(--ink); }
        tr:nth-child(even) { background: var(--row-even); }
        tr:hover { background: var(--row-hover); }
        td {
            font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
            font-size: 0.75rem;
            font-variant-numeric: tabular-nums;
            color: var(--ink);
        }
        .sort-icon::after {
            content: '\\2195';
            opacity: 0.5;
            margin-left: 3px;
            font-size: 0.6rem;
        }
        .sort-icon.asc::after { content: '\\2193'; opacity: 1; }
        .sort-icon.desc::after { content: '\\2191'; opacity: 1; }
        :focus-visible {
            outline: 2px solid var(--accent-read);
            outline-offset: 2px;
        }
        .filter-btn:focus-visible, .theme-toggle:focus-visible {
            outline-offset: 1px;
        }
        th:focus-visible {
            background: var(--surface-1);
        }
    </style>
</head>
<body>
    <header>
        <div class="header-left">
            <h1>fio benchmark</h1>
            <div class="meta">
                ${device_display} | ${num_paths} paths | $(date -u +"%Y-%m-%d %H:%M UTC") | ${TEST_DURATION}s/test
            </div>
        </div>
        <button class="theme-toggle" id="themeToggle" aria-label="Switch to light theme">light</button>
    </header>

    <div class="container">
        <section class="mvp-cards">
            <div class="mvp-card mvp-card-iops">
                <div class="mvp-label">Peak IOPS</div>
                <div class="mvp-value" id="mvpIops">--</div>
                <div class="mvp-detail" id="mvpIopsDetail"></div>
            </div>
            <div class="mvp-card mvp-card-readbw">
                <div class="mvp-label">Peak Read BW</div>
                <div class="mvp-value" id="mvpReadBW">--</div>
                <div class="mvp-detail" id="mvpReadBWDetail"></div>
            </div>
            <div class="mvp-card mvp-card-writebw">
                <div class="mvp-label">Peak Write BW</div>
                <div class="mvp-value" id="mvpWriteBW">--</div>
                <div class="mvp-detail" id="mvpWriteBWDetail"></div>
            </div>
            <div class="mvp-card mvp-card-latency">
                <div class="mvp-label">Lowest Avg Latency</div>
                <div class="mvp-value" id="mvpLatency">--</div>
                <div class="mvp-detail" id="mvpLatencyDetail"></div>
            </div>
        </section>

        <h2 class="section-title">Performance Charts</h2>
        <div class="charts">
            <div class="chart-container"><h3>Seq BW Scaling with Queue Depth (1M)</h3><canvas id="chartSeqQD"></canvas></div>
            <div class="chart-container"><h3>Seq Throughput by Block Size (QD=16)</h3><canvas id="chartSeqBS"></canvas></div>
            <div class="chart-container"><h3>Random IOPS vs Queue Depth (4K)</h3><canvas id="chartRandIOPS"></canvas></div>
            <div class="chart-container"><h3>Random Throughput by Block Size (QD=16)</h3><canvas id="chartRandBS"></canvas></div>
            <div class="chart-container"><h3>Seq vs Random BW (QD=16)</h3><canvas id="chartSeqRand"></canvas></div>
            <div class="chart-container"><h3>Latency vs Queue Depth (4K)</h3><canvas id="chartLatQD"></canvas></div>
            <div class="chart-container"><h3>Mixed Workload Analysis</h3><canvas id="chartMixed"></canvas></div>
            <div class="chart-container"><h3>Latency vs Throughput</h3><canvas id="chartScatter"></canvas></div>
        </div>

        <h2 class="section-title">Detailed Results</h2>
        <div class="table-container">
            <div class="table-controls">
                <input type="text" id="tableSearch" placeholder="Search tests..." aria-label="Search test results" />
                <div class="filter-buttons" role="group" aria-label="Filter results by category">
                    <button data-filter="all" class="filter-btn active" aria-pressed="true">All</button>
                    <button data-filter="seq" class="filter-btn" aria-pressed="false">Sequential</button>
                    <button data-filter="rand" class="filter-btn" aria-pressed="false">Random</button>
                    <button data-filter="mixed" class="filter-btn" aria-pressed="false">Mixed</button>
                    <button data-filter="read" class="filter-btn" aria-pressed="false">Read</button>
                    <button data-filter="write" class="filter-btn" aria-pressed="false">Write</button>
                </div>
            </div>
            <table id="resultsTable">
                <thead>
                    <tr>
                        <th data-sort="name">Test Name <span class="sort-icon"></span></th>
                        <th data-sort="bw">BW (MB/s) <span class="sort-icon"></span></th>
                        <th data-sort="iops">IOPS <span class="sort-icon"></span></th>
                        <th data-sort="latAvg">Avg Lat (ms) <span class="sort-icon"></span></th>
                        <th data-sort="latP95">P95 Lat (ms) <span class="sort-icon"></span></th>
                        <th data-sort="latP99">P99 Lat (ms) <span class="sort-icon"></span></th>
                    </tr>
                </thead>
                <tbody></tbody>
            </table>
        </div>
    </div>

    <script>
    var TEST_DATA = {
        metadata: {
            device: "${device_display}",
            device_node: "${dm_node}",
            wwid: "${wwid}",
            policy: "${policy}",
            num_paths: ${num_paths},
            paths: ${paths_json},
            test_date: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
            test_duration: ${TEST_DURATION}
        },
        results: ${results_json}
    };

    // ── Theme Management ──
    function getTheme() {
        var saved = localStorage.getItem('fio-bench-theme');
        if (saved) return saved;
        return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    }
    function applyTheme(theme) {
        document.documentElement.setAttribute('data-theme', theme);
        var btn = document.getElementById('themeToggle');
        if (btn) {
            btn.textContent = theme === 'dark' ? 'light' : 'dark';
            btn.setAttribute('aria-label', 'Switch to ' + (theme === 'dark' ? 'light' : 'dark') + ' theme');
        }
        updateChartTheme();
    }
    function toggleTheme() {
        var current = document.documentElement.getAttribute('data-theme') || 'dark';
        var next = current === 'dark' ? 'light' : 'dark';
        localStorage.setItem('fio-bench-theme', next);
        applyTheme(next);
    }
    function getChartColor(name) {
        return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    }
    function updateChartTheme() {
        var textColor = getChartColor('--chart-text');
        var gridColor = getChartColor('--chart-grid');
        Chart.helpers.each(Chart.instances, function(chart) {
            if (chart.options.scales) {
                Object.keys(chart.options.scales).forEach(function(axis) {
                    var s = chart.options.scales[axis];
                    if (s.ticks) s.ticks.color = textColor;
                    if (s.grid) s.grid.color = gridColor;
                    if (s.title) s.title.color = textColor;
                });
            }
            if (chart.options.plugins && chart.options.plugins.legend && chart.options.plugins.legend.labels) {
                chart.options.plugins.legend.labels.color = textColor;
            }
            chart.update('none');
        });
    }
    document.getElementById('themeToggle').addEventListener('click', toggleTheme);
    applyTheme(getTheme());

    // ── MVP Summary Cards ──
    (function() {
        var results = TEST_DATA.results;
        if (!results.length) return;

        var peakIops = results.reduce(function(best, r) {
            var val = parseInt(r.iops);
            return val > best.val ? {val: val, name: r.test_name} : best;
        }, {val: 0, name: ''});

        var peakReadBW = results.filter(function(r) { return r.test_name.indexOf('read') >= 0; })
            .reduce(function(best, r) {
                var val = parseFloat(r.bw_mb);
                return val > best.val ? {val: val, name: r.test_name} : best;
            }, {val: 0, name: ''});

        var peakWriteBW = results.filter(function(r) { return r.test_name.indexOf('write') >= 0; })
            .reduce(function(best, r) {
                var val = parseFloat(r.bw_mb);
                return val > best.val ? {val: val, name: r.test_name} : best;
            }, {val: 0, name: ''});

        var lowestLat = results.filter(function(r) { return parseFloat(r.lat_avg_ms) > 0; })
            .reduce(function(best, r) {
                var val = parseFloat(r.lat_avg_ms);
                return val < best.val ? {val: val, name: r.test_name} : best;
            }, {val: Infinity, name: ''});

        document.getElementById('mvpIops').textContent = peakIops.val.toLocaleString() + ' IOPS';
        document.getElementById('mvpIopsDetail').textContent = peakIops.name.replace(/_/g, ' ');

        document.getElementById('mvpReadBW').textContent = peakReadBW.val.toFixed(1) + ' MB/s';
        document.getElementById('mvpReadBWDetail').textContent = peakReadBW.name.replace(/_/g, ' ');

        if (peakWriteBW.name) {
            document.getElementById('mvpWriteBW').textContent = peakWriteBW.val.toFixed(1) + ' MB/s';
            document.getElementById('mvpWriteBWDetail').textContent = peakWriteBW.name.replace(/_/g, ' ');
        } else {
            document.getElementById('mvpWriteBW').textContent = 'N/A';
            document.getElementById('mvpWriteBWDetail').textContent = 'write tests not run';
        }

        if (lowestLat.name) {
            document.getElementById('mvpLatency').textContent = lowestLat.val.toFixed(3) + ' ms';
            document.getElementById('mvpLatencyDetail').textContent = lowestLat.name.replace(/_/g, ' ');
        }
    })();

    // ── Table Sort/Filter ──
    var TableManager = {
        sortCol: null, sortAsc: true, activeFilter: 'all', searchTerm: '',
        init: function() {
            var self = this;
            document.querySelectorAll('#resultsTable th[data-sort]').forEach(function(th) {
                th.addEventListener('click', function() {
                    var col = th.getAttribute('data-sort');
                    if (self.sortCol === col) { self.sortAsc = !self.sortAsc; }
                    else { self.sortCol = col; self.sortAsc = true; }
                    document.querySelectorAll('.sort-icon').forEach(function(s) { s.className = 'sort-icon'; });
                    var icon = th.querySelector('.sort-icon');
                    if (icon) icon.className = 'sort-icon ' + (self.sortAsc ? 'asc' : 'desc');
                    self.render();
                });
            });
            document.getElementById('tableSearch').addEventListener('input', function(e) {
                self.searchTerm = e.target.value.toLowerCase(); self.render();
            });
            document.querySelectorAll('.filter-btn').forEach(function(btn) {
                btn.addEventListener('click', function() {
                    document.querySelectorAll('.filter-btn').forEach(function(b) { b.classList.remove('active'); });
                    btn.classList.add('active');
                    self.activeFilter = btn.getAttribute('data-filter');
                    self.render();
                });
            });
            this.render();
        },
        classify: function(n) {
            if (n.indexOf('seq') >= 0) return 'seq';
            if (n.indexOf('rand') >= 0) return 'rand';
            if (n.indexOf('mixed') >= 0) return 'mixed';
            return 'other';
        },
        rwType: function(n) {
            if (n.indexOf('mixed') >= 0) return 'mixed';
            if (n.indexOf('read') >= 0) return 'read';
            if (n.indexOf('write') >= 0) return 'write';
            return 'other';
        },
        render: function() {
            var self = this;
            var filtered = TEST_DATA.results.filter(function(r) {
                var type = self.classify(r.test_name);
                var rw = self.rwType(r.test_name);
                var matchFilter = self.activeFilter === 'all' || type === self.activeFilter || rw === self.activeFilter;
                var matchSearch = !self.searchTerm || r.test_name.toLowerCase().indexOf(self.searchTerm) >= 0;
                return matchFilter && matchSearch;
            });
            if (self.sortCol) {
                filtered.sort(function(a, b) {
                    var va, vb;
                    switch (self.sortCol) {
                        case 'name': va = a.test_name; vb = b.test_name; break;
                        case 'bw': va = parseFloat(a.bw_mb); vb = parseFloat(b.bw_mb); break;
                        case 'iops': va = parseInt(a.iops); vb = parseInt(b.iops); break;
                        case 'latAvg': va = parseFloat(a.lat_avg_ms); vb = parseFloat(b.lat_avg_ms); break;
                        case 'latP95': va = parseFloat(a.lat_p95_ms); vb = parseFloat(b.lat_p95_ms); break;
                        case 'latP99': va = parseFloat(a.lat_p99_ms); vb = parseFloat(b.lat_p99_ms); break;
                    }
                    if (typeof va === 'string') return self.sortAsc ? va.localeCompare(vb) : vb.localeCompare(va);
                    return self.sortAsc ? va - vb : vb - va;
                });
            }
            var tbody = document.querySelector('#resultsTable tbody');
            tbody.innerHTML = '';
            filtered.forEach(function(r) {
                var row = tbody.insertRow();
                row.innerHTML = '<td>' + r.test_name + '</td>' +
                    '<td>' + parseFloat(r.bw_mb).toFixed(2) + '</td>' +
                    '<td>' + parseInt(r.iops).toLocaleString() + '</td>' +
                    '<td>' + parseFloat(r.lat_avg_ms).toFixed(2) + '</td>' +
                    '<td>' + parseFloat(r.lat_p95_ms).toFixed(2) + '</td>' +
                    '<td>' + parseFloat(r.lat_p99_ms).toFixed(2) + '</td>';
            });
        }
    };
    TableManager.init();

    // ── Chart Helpers ──
    function findTest(name) {
        return TEST_DATA.results.find(function(r) { return r.test_name === name; });
    }
    function findPartial(pattern) {
        return TEST_DATA.results.find(function(r) { return r.test_name.indexOf(pattern) >= 0; });
    }
    function gc(name) { return getChartColor(name); }

    Chart.defaults.font.family = "'SF Mono', Monaco, 'Cascadia Code', monospace";
    Chart.defaults.font.size = 11;

    var gridColor = gc('--chart-grid');
    var textColor = gc('--chart-text');

    function scaleOpts(yLabel) {
        return {
            responsive: true,
            plugins: { legend: { labels: { color: textColor, boxWidth: 10, padding: 8, font: {size: 10} } } },
            scales: {
                x: { ticks: {color: textColor}, grid: {color: gridColor}, title: {display: false} },
                y: { beginAtZero: true, ticks: {color: textColor}, grid: {color: gridColor}, title: {display: true, text: yLabel, color: textColor} }
            }
        };
    }

    // ── Chart 1: Seq BW Scaling with Queue Depth (1M) ──
    (function() {
        var qds = [1, 4, 16, 32];
        var readD = qds.map(function(qd) { var t = findTest('seq_read_1M_qd' + qd); return t ? parseFloat(t.bw_mb) : null; });
        var writeD = qds.map(function(qd) { var t = findTest('seq_write_1M_qd' + qd); return t ? parseFloat(t.bw_mb) : null; });
        var datasets = [{label: 'Seq Read', data: readD, borderColor: gc('--chart-read'), backgroundColor: gc('--chart-read'), tension: 0.15, pointRadius: 4}];
        if (writeD.some(function(v) { return v !== null; })) {
            datasets.push({label: 'Seq Write', data: writeD, borderColor: gc('--chart-write'), backgroundColor: gc('--chart-write'), tension: 0.15, pointRadius: 4});
        }
        new Chart(document.getElementById('chartSeqQD'), {
            type: 'line', data: { labels: qds.map(function(q) { return 'QD' + q; }), datasets: datasets },
            options: scaleOpts('MB/s')
        });
    })();

    // ── Chart 2: Seq Throughput by Block Size (QD=16) ──
    (function() {
        var bss = ['64K', '256K', '512K', '1M'];
        var readD = bss.map(function(bs) { var t = findTest('seq_read_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var writeD = bss.map(function(bs) { var t = findTest('seq_write_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var datasets = [{label: 'Seq Read', data: readD, backgroundColor: gc('--chart-read')}];
        if (writeD.some(function(v) { return v !== null; })) {
            datasets.push({label: 'Seq Write', data: writeD, backgroundColor: gc('--chart-write')});
        }
        new Chart(document.getElementById('chartSeqBS'), {
            type: 'bar', data: { labels: bss, datasets: datasets },
            options: scaleOpts('MB/s')
        });
    })();

    // ── Chart 3: Random IOPS vs Queue Depth (4K) ──
    (function() {
        var qds = [1, 4, 8, 16, 32, 64];
        var readD = qds.map(function(qd) { var t = findTest('rand_read_4K_qd' + qd); return t ? parseInt(t.iops) : null; });
        var writeD = qds.map(function(qd) { var t = findTest('rand_write_4K_qd' + qd); return t ? parseInt(t.iops) : null; });
        var datasets = [{label: 'Rand Read', data: readD, borderColor: gc('--chart-read'), tension: 0.15, pointRadius: 4}];
        if (writeD.some(function(v) { return v !== null; })) {
            datasets.push({label: 'Rand Write', data: writeD, borderColor: gc('--chart-write'), tension: 0.15, pointRadius: 4});
        }
        new Chart(document.getElementById('chartRandIOPS'), {
            type: 'line', data: { labels: qds.map(function(q) { return 'QD' + q; }), datasets: datasets },
            options: scaleOpts('IOPS')
        });
    })();

    // ── Chart 4: Random Throughput by Block Size (QD=16) ──
    (function() {
        var bss = ['4K', '8K', '16K', '64K'];
        var readD = bss.map(function(bs) { var t = findTest('rand_read_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var writeD = bss.map(function(bs) { var t = findTest('rand_write_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var datasets = [{label: 'Rand Read', data: readD, backgroundColor: gc('--chart-read')}];
        if (writeD.some(function(v) { return v !== null; })) {
            datasets.push({label: 'Rand Write', data: writeD, backgroundColor: gc('--chart-write')});
        }
        new Chart(document.getElementById('chartRandBS'), {
            type: 'bar', data: { labels: bss, datasets: datasets },
            options: scaleOpts('MB/s')
        });
    })();

    // ── Chart 5: Seq vs Random BW Comparison (QD=16) ──
    (function() {
        var bss = ['4K', '8K', '16K', '64K', '256K', '512K', '1M'];
        var seqReadD = bss.map(function(bs) { var t = findTest('seq_read_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var seqWriteD = bss.map(function(bs) { var t = findTest('seq_write_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var randReadD = bss.map(function(bs) { var t = findTest('rand_read_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var randWriteD = bss.map(function(bs) { var t = findTest('rand_write_' + bs + '_qd16'); return t ? parseFloat(t.bw_mb) : null; });
        var datasets = [{label: 'Seq Read', data: seqReadD, backgroundColor: gc('--chart-read')}];
        if (seqWriteD.some(function(v) { return v !== null; })) datasets.push({label: 'Seq Write', data: seqWriteD, backgroundColor: gc('--chart-write')});
        if (randReadD.some(function(v) { return v !== null; })) datasets.push({label: 'Rand Read', data: randReadD, backgroundColor: gc('--chart-read')});
        if (randWriteD.some(function(v) { return v !== null; })) datasets.push({label: 'Rand Write', data: randWriteD, backgroundColor: gc('--chart-write')});
        new Chart(document.getElementById('chartSeqRand'), {
            type: 'bar', data: { labels: bss, datasets: datasets },
            options: scaleOpts('MB/s')
        });
    })();

    // ── Chart 6: Latency vs Queue Depth (4K) ──
    (function() {
        var qds = [1, 4, 8, 16, 32, 64];
        var readAvg = qds.map(function(qd) { var t = findTest('rand_read_4K_qd' + qd); return t ? parseFloat(t.lat_avg_ms) : null; });
        var readP99 = qds.map(function(qd) { var t = findTest('rand_read_4K_qd' + qd); return t ? parseFloat(t.lat_p99_ms) : null; });
        var datasets = [
            {label: 'Read Avg', data: readAvg, borderColor: gc('--chart-read'), tension: 0.15, pointRadius: 4},
            {label: 'Read P99', data: readP99, borderColor: gc('--chart-read'), borderDash: [4,3], tension: 0.15, pointRadius: 3}
        ];
        var writeAvg = qds.map(function(qd) { var t = findTest('rand_write_4K_qd' + qd); return t ? parseFloat(t.lat_avg_ms) : null; });
        var writeP99 = qds.map(function(qd) { var t = findTest('rand_write_4K_qd' + qd); return t ? parseFloat(t.lat_p99_ms) : null; });
        if (writeAvg.some(function(v) { return v !== null; })) {
            datasets.push({label: 'Write Avg', data: writeAvg, borderColor: gc('--chart-write'), tension: 0.15, pointRadius: 4});
            datasets.push({label: 'Write P99', data: writeP99, borderColor: gc('--chart-write'), borderDash: [4,3], tension: 0.15, pointRadius: 3});
        }
        new Chart(document.getElementById('chartLatQD'), {
            type: 'line', data: { labels: qds.map(function(q) { return 'QD' + q; }), datasets: datasets },
            options: scaleOpts('Latency (ms)')
        });
    })();

    // ── Chart 7: Mixed Workload Analysis ──
    (function() {
        var mixed = TEST_DATA.results.filter(function(r) { return r.test_name.indexOf('mixed') >= 0; });
        if (!mixed.length) return;
        new Chart(document.getElementById('chartMixed'), {
            type: 'bar',
            data: {
                labels: mixed.map(function(r) { return r.test_name.replace(/_/g, ' ').replace('mixed ', ''); }),
                datasets: [
                    {label: 'Throughput (MB/s)', data: mixed.map(function(r) { return parseFloat(r.bw_mb); }), backgroundColor: gc('--chart-mixed'), yAxisID: 'y'},
                    {label: 'IOPS', data: mixed.map(function(r) { return parseInt(r.iops); }), backgroundColor: gc('--chart-blue'), yAxisID: 'y1'}
                ]
            },
            options: {
                responsive: true,
                plugins: { legend: { labels: {color: textColor, boxWidth: 10, padding: 8, font: {size: 10}} } },
                scales: {
                    x: { ticks: {color: textColor, font: {size: 9}}, grid: {color: gridColor} },
                    y: { type: 'linear', position: 'left', beginAtZero: true, ticks: {color: textColor}, grid: {color: gridColor}, title: {display: true, text: 'MB/s', color: textColor} },
                    y1: { type: 'linear', position: 'right', beginAtZero: true, ticks: {color: textColor}, grid: {drawOnChartArea: false}, title: {display: true, text: 'IOPS', color: textColor} }
                }
            }
        });
    })();

    // ── Chart 8: Latency vs Throughput Scatter ──
    (function() {
        function classify(name) {
            if (name.indexOf('seq_read') === 0) return 'seq_read';
            if (name.indexOf('seq_write') === 0) return 'seq_write';
            if (name.indexOf('rand_read') === 0) return 'rand_read';
            if (name.indexOf('rand_write') === 0) return 'rand_write';
            if (name.indexOf('mixed') === 0) return 'mixed';
            return 'other';
        }
        var catColors = {
            seq_read: gc('--chart-read'),
            seq_write: gc('--chart-write'),
            rand_read: gc('--chart-read'),
            rand_write: gc('--chart-write'),
            mixed: gc('--chart-mixed'),
            other: gc('--ink-3')
        };
        var catLabels = {
            seq_read: 'Seq Read', seq_write: 'Seq Write',
            rand_read: 'Rand Read', rand_write: 'Rand Write',
            mixed: 'Mixed', other: 'Other'
        };
        var categories = ['seq_read', 'seq_write', 'rand_read', 'rand_write', 'mixed', 'other'];
        var datasets = categories.filter(function(cat) {
            return TEST_DATA.results.some(function(r) { return classify(r.test_name) === cat; });
        }).map(function(cat) {
            return {
                label: catLabels[cat],
                data: TEST_DATA.results.filter(function(r) { return classify(r.test_name) === cat; }).map(function(r) {
                    return {x: parseFloat(r.lat_avg_ms), y: parseFloat(r.bw_mb), testName: r.test_name};
                }),
                backgroundColor: catColors[cat],
                pointRadius: 5,
                pointHoverRadius: 7
            };
        });
        new Chart(document.getElementById('chartScatter'), {
            type: 'scatter',
            data: { datasets: datasets },
            options: {
                responsive: true,
                plugins: {
                    legend: { labels: {color: textColor, boxWidth: 8, padding: 8, font: {size: 10}} },
                    tooltip: {
                        callbacks: {
                            label: function(ctx) {
                                var p = ctx.raw;
                                return p.testName.replace(/_/g, ' ') + ': ' + p.y.toFixed(1) + ' MB/s, ' + p.x.toFixed(2) + ' ms';
                            }
                        }
                    }
                },
                scales: {
                    x: { ticks: {color: textColor}, grid: {color: gridColor}, title: {display: true, text: 'Avg Latency (ms)', color: textColor} },
                    y: { ticks: {color: textColor}, grid: {color: gridColor}, title: {display: true, text: 'Throughput (MB/s)', color: textColor} }
                }
            }
        });
    })();
    </script>
</body>
</html>
EOF

    info "Results written to: $html_file"
}

# ── CLI ──

show_help() {
    cat << EOF
FIO Storage Benchmark Script v${SCRIPT_VERSION}

USAGE:
    fio-benchmark.sh [OPTIONS]

OPTIONS:
    --device DEV         Target block device (default: auto-detect)
    --storage NAME       PVE storage ID to provision a test disk on
    --disk-size SIZE     Disk size for provisioned disk (default: 10G)
    --list               List detected multipath devices and exit
    --quick              Run reduced test suite (smoke test)
    --write              Enable write tests (default: read-only)
    --output FORMAT      Output format: text, json, or html (default: text)
    --duration SECONDS   Per-test duration (default: 60)
    --ramp-time SECONDS  Ramp/warm-up time (default: 10)
    --numjobs N          Number of parallel jobs (default: 1)
    --force              Bypass mounted device warning
    --verbose            Enable verbose FIO output
    --help               Show this help message
    --version            Show version information

EXAMPLES:
    fio-benchmark.sh --list
    fio-benchmark.sh --device /dev/mapper/mpatha
    fio-benchmark.sh --storage truenas-iscsi --write --output html
    fio-benchmark.sh --storage truenas-nvme --quick --disk-size 20G
    fio-benchmark.sh --quick --output json

EXIT CODES:
    0    Success
    1    General error
    2    Device validation error
    3    FIO execution error
    4    Interrupted by signal
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="$2"
                shift 2
                ;;
            --list)
                LIST_ONLY=1
                shift
                ;;
            --quick)
                QUICK_MODE=1
                TEST_DURATION=30
                RAMP_TIME=5
                shift
                ;;
            --write)
                ENABLE_WRITE=1
                shift
                ;;
            --output)
                OUTPUT_FORMAT="$2"
                [[ "$OUTPUT_FORMAT" =~ ^(text|json|html)$ ]] || \
                    die "Invalid --output format '$OUTPUT_FORMAT': must be text, json, or html" 1
                shift 2
                ;;
            --duration)
                TEST_DURATION="$2"
                shift 2
                ;;
            --ramp-time)
                RAMP_TIME="$2"
                shift 2
                ;;
            --numjobs)
                NUM_JOBS="$2"
                shift 2
                ;;
            --force)
                FORCE_MODE=1
                shift
                ;;
            --storage)
                PVE_STORAGE="$2"
                shift 2
                ;;
            --disk-size)
                DISK_SIZE="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                printf "fio-benchmark.sh version %s\n" "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die "Unknown option: $1" 1
                ;;
        esac
    done
}

auto_select_device() {
    # Try to find TrueNAS iSCSI devices first
    for by_path in /dev/disk/by-path/*; do
        [[ -e "$by_path" ]] || continue
        if [[ "$by_path" =~ ip-.*iscsi-.*-lun- ]]; then
            local target=$(readlink -f "$by_path")
            if [[ "$target" =~ /dev/dm-[0-9]+ ]]; then
                printf '%s' "$target"
                return 0
            fi
        fi
    done

    # Fall back to first multipath device
    for dm in /sys/block/dm-*/slaves; do
        [[ -d "$dm" ]] || continue
        local dm_name=$(basename "$(dirname "$dm")")
        printf '/dev/%s' "$dm_name"
        return 0
    done

    # Check for NVMe devices
    for nvme in /dev/nvme*[0-9]n1; do
        [[ -b "$nvme" ]] || continue
        printf '%s' "$nvme"
        return 0
    done

    return 1
}

main() {
    parse_args "$@"

    # Create temp dir
    TEMP_DIR=$(mktemp -d)
    TEMP_FILES=()

    check_fio

    # Handle list mode
    if [[ $LIST_ONLY -eq 1 ]]; then
        list_devices
        return 0
    fi

    # Storage provisioning mode
    if [[ -n "$PVE_STORAGE" ]]; then
        if [[ -n "$DEVICE" ]]; then
            die "Cannot use --storage and --device together" 1
        fi
        provision_disk "$PVE_STORAGE" "$DISK_SIZE" || die "Failed to provision disk on storage '$PVE_STORAGE'" 1
    fi

    # Auto-select device if not specified
    if [[ -z "$DEVICE" ]]; then
        DEVICE=$(auto_select_device) || die "No suitable device found. Use --device or --storage to specify." 2
    fi

    # Resolve device path
    DEVICE=$(resolve_device "$DEVICE") || die "Cannot resolve device: $DEVICE" 2

    # Validate device (skip mount check for provisioned devices)
    if [[ $PROV_CLEANUP_NEEDED -eq 1 ]]; then
        FORCE_MODE=1
    fi
    validate_device "$DEVICE"

    # Get topology info
    get_multipath_topology "$DEVICE" || warn "Could not get device topology"

    # Run tests
    run_test_suite "$DEVICE"

    # Output results
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        print_json_results
    elif [[ "$OUTPUT_FORMAT" == "html" ]]; then
        print_html_results
    else
        print_topology
        print_text_results
    fi

    return 0
}

main "$@"
