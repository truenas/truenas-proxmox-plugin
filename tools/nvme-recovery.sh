#!/usr/bin/env bash
# nvme-recovery.sh — NVMe subsystem namespace recovery tool
#
# Recovers VMs that were on a shared NVMe subsystem by reassigning
# namespaces to the correct per-storage subsystems and updating
# Proxmox VM configs with new UUIDs.
#
# Usage: ./nvme-recovery.sh            # dry run — show what would change
#        ./nvme-recovery.sh --accept   # apply changes with per-namespace confirmation
#
# See: https://github.com/truenas/truenas-proxmox-plugin/issues/10

set -eo pipefail

# --- Mode ---
DRY_RUN=1
if [[ "${1:-}" == "--accept" ]]; then
    DRY_RUN=0
fi

readonly STORAGE_CFG="/etc/pve/storage.cfg"
readonly PLUGIN_PATH="/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
readonly VM_CFG_BASE="/etc/pve/nodes"
readonly BACKUP_DIR="/tmp/nvme-recovery-backup-$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/nvme-recovery.log"

# --- Colors ---
c0='\033[0m'    # reset
c1='\033[31m'   # red
c2='\033[32m'   # green
c3='\033[33m'   # yellow
c4='\033[34m'   # blue
c5='\033[35m'   # magenta
c6='\033[36m'   # cyan
c8='\033[1m'    # bold

# --- Logging ---
log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

# --- Display helpers ---
info()    { printf '%b\n' "${c4}  ${*}${c0}"; log "INFO" "$*"; }
success() { printf '%b\n' "${c2}  ${*}${c0}"; log "INFO" "$*"; }
warning() { printf '%b\n' "${c3}  ${*}${c0}"; log "WARN" "$*"; }
error()   { printf '%b\n' "${c1}  ${*}${c0}" >&2; log "ERROR" "$*"; }

print_header() {
    local title="$1"
    printf '\n%b\n' "${c6}${c8}${title}${c0}"
    printf '%b\n\n' "${c6}$(printf '%*s' ${#title} '' | tr ' ' '-')${c0}"
}

print_banner() {
    printf '\n%b\n' "${c6}${c8}  NVMe Subsystem Recovery Tool${c0}"
    printf '%b\n'   "${c6}  Reassign namespaces and update VM configs${c0}"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%b\n' "${c3}  Mode: DRY RUN (use --accept to apply changes)${c0}"
    else
        printf '%b\n' "${c2}  Mode: APPLY${c0}"
    fi
    printf '%b\n\n' "${c6}  $(printf '%30s' '' | tr ' ' '-')${c0}"
    printf '%b\n'   "${c4}  Prerequisites:${c0}"
    printf '%b\n'   "${c4}  1. Each storage has its own subsystem on TrueNAS (unique NQN)${c0}"
    printf '%b\n'   "${c4}  2. Each subsystem has at least one TCP port configured${c0}"
    printf '%b\n'   "${c4}  3. storage.cfg updated with correct subsystem_nqn per storage${c0}"
    printf '%b\n'   "${c4}  4. All VMs on affected storages are stopped${c0}"
    echo ""
}

# --- API helpers ---
# Uses the same pattern as install.sh for WebSocket API calls
tn_api_call() {
    local host="$1"
    local api_key="$2"
    local method="$3"
    local params="${4:-[]}"
    local api_port="${5:-}"
    local api_insecure="${6:-1}"
    local api_scheme="${7:-}"

    log "INFO" "tn_api_call: method=$method"

    local result exit_code
    result=$(perl -e '
        use strict;
        use warnings;
        use lib "/usr/share/perl5";
        use PVE::Storage::Custom::TrueNASPlugin ();
        use JSON::PP;

        my ($host, $api_key, $method, $params_json, $api_port, $api_insecure, $api_scheme) = @ARGV;

        my $scfg = {
            api_host => $host,
            api_key => $api_key,
            api_insecure => int($api_insecure // 1),
        };
        $scfg->{api_port} = int($api_port) if $api_port;
        $scfg->{api_scheme} = $api_scheme if $api_scheme;

        my $params = eval { decode_json($params_json) } // [];

        my $result = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, $method, $params);
        };

        if ($@) {
            print STDERR "ERROR: $@";
            exit 1;
        }

        print encode_json($result) if defined $result;
    ' "$host" "$api_key" "$method" "$params" "$api_port" "$api_insecure" "$api_scheme" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        local error_msg
        error_msg=$(echo "$result" | grep -oP 'ERROR:\s*\K.*' || echo "$result")
        log "ERROR" "tn_api_call failed: $error_msg"
        echo "$error_msg" >&2
        return 1
    fi

    echo "$result"
    return 0
}

tn_api_call_write() {
    local host="$1"
    local api_key="$2"
    local method="$3"
    local params="${4:-[]}"
    local api_port="${5:-}"
    local api_insecure="${6:-1}"
    local api_scheme="${7:-}"

    log "INFO" "tn_api_call_write: method=$method"

    local result exit_code
    result=$(perl -e '
        use strict;
        use warnings;
        use lib "/usr/share/perl5";
        use PVE::Storage::Custom::TrueNASPlugin ();
        use JSON::PP;

        my ($host, $api_key, $method, $params_json, $api_port, $api_insecure, $api_scheme) = @ARGV;

        my $scfg = {
            api_host => $host,
            api_key => $api_key,
            api_insecure => int($api_insecure // 1),
        };
        $scfg->{api_port} = int($api_port) if $api_port;
        $scfg->{api_scheme} = $api_scheme if $api_scheme;

        my $params = eval { decode_json($params_json) };
        if ($@ || !defined $params) {
            print STDERR "ERROR: Failed to decode params JSON: $@\n";
            exit 1;
        }

        my $result = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call_write($scfg, $method, $params);
        };

        if ($@) {
            print STDERR "ERROR: $@";
            exit 1;
        }

        print encode_json($result) if defined $result;
    ' "$host" "$api_key" "$method" "$params" "$api_port" "$api_insecure" "$api_scheme" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        local error_msg
        error_msg=$(echo "$result" | grep -oP 'ERROR:\s*\K.*' || echo "$result")
        log "ERROR" "tn_api_call_write failed: $error_msg"
        echo "$error_msg" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# --- JSON helpers ---
# Extract field from a flat JSON object (no nesting)
parse_json_field() {
    local json="$1"
    local field="$2"
    local value
    value=$(echo "$json" | grep -oP "\"${field}\":\s*\K(\"[^\"]*\"|[0-9]+|true|false|null)" | head -1)
    value="${value%\"}"
    value="${value#\"}"
    echo "$value"
}

# --- Storage config helpers ---
list_nvme_storages() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi
    local all_storages
    all_storages=$(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}') || true
    local name
    for name in $all_storages; do
        local mode
        mode=$(get_storage_value "$name" "transport_mode")
        if [[ "$mode" == "nvme-tcp" ]]; then
            echo "$name"
        fi
    done
}

get_storage_value() {
    local storage_name="$1"
    local param_name="$2"
    awk "/^truenasplugin: ${storage_name}\$/{flag=1; next} /^truenasplugin:/{flag=0} flag" "$STORAGE_CFG" | \
        grep "^\s*${param_name}" | awk '{print $2}' | head -1 || true
}

# ============================================================
# Phase 1: Preflight Checks
# ============================================================
preflight_checks() {
    print_header "Phase 1: Preflight Checks"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    success "Running as root"

    # Plugin check
    if [[ ! -f "$PLUGIN_PATH" ]]; then
        error "Plugin not found at $PLUGIN_PATH"
        error "Install the TrueNAS plugin first"
        exit 1
    fi
    local version
    version=$(grep 'our $VERSION' "$PLUGIN_PATH" | grep -oP "'[^']+'" | tr -d "'")
    success "Plugin installed (v${version})"

    # nvme-cli check
    if ! command -v nvme &>/dev/null; then
        error "nvme-cli is not installed (apt install nvme-cli)"
        exit 1
    fi
    success "nvme-cli installed"

    # storage.cfg check
    if [[ ! -f "$STORAGE_CFG" ]]; then
        error "No storage.cfg found at $STORAGE_CFG"
        exit 1
    fi
    success "storage.cfg found"

    # Find NVMe-TCP storages
    local storages
    storages=$(list_nvme_storages)
    if [[ -z "$storages" ]]; then
        error "No NVMe-TCP storages found in storage.cfg"
        exit 1
    fi
    local count
    count=$(echo "$storages" | wc -l)
    success "Found ${count} NVMe-TCP storage(s)"

    # Check for running VMs on NVMe storages (scan all cluster nodes)
    local running_vms=()
    shopt -s nullglob
    local conf_files=("$VM_CFG_BASE"/*/qemu-server/*.conf)
    shopt -u nullglob
    for conf in "${conf_files[@]}"; do
        [[ -f "$conf" ]] || continue
        local vmid
        vmid=$(basename "$conf" .conf)
        # Check if this VM is running
        if pgrep -f "kvm.*-id ${vmid}" &>/dev/null; then
            # Check if any of its disks are on our NVMe storages
            while read -r storage_name; do
                if grep -q "${storage_name}:vol-.*-ns" "$conf" 2>/dev/null; then
                    running_vms+=("$vmid")
                    break
                fi
            done <<< "$storages"
        fi
    done

    if [[ ${#running_vms[@]} -gt 0 ]]; then
        error "The following VMs are running on NVMe storages and must be stopped first:"
        for vmid in "${running_vms[@]}"; do
            error "  VM $vmid"
        done
        error ""
        error "Stop them with: qm stop <vmid>"
        exit 1
    fi
    success "No running VMs on NVMe storages"
}

# ============================================================
# Phase 2: Discovery
# ============================================================

# Global arrays populated by discover()
declare -A STORAGE_HOST        # storage_name -> api_host
declare -A STORAGE_KEY         # storage_name -> api_key
declare -A STORAGE_NQN         # storage_name -> subsystem_nqn
declare -A STORAGE_DATASET     # storage_name -> dataset
declare -A STORAGE_PORT        # storage_name -> api_port
declare -A STORAGE_INSECURE    # storage_name -> api_insecure
declare -A STORAGE_SCHEME      # storage_name -> api_scheme
declare -a STORAGE_NAMES=()    # ordered list of storage names

# Namespace data (indexed by TrueNAS namespace ID)
declare -A NS_NSID             # ns_id -> nsid
declare -A NS_UUID             # ns_id -> device_uuid
declare -A NS_NGUID            # ns_id -> device_nguid
declare -A NS_PATH             # ns_id -> device_path
declare -A NS_SUBSYS_NAME      # ns_id -> subsystem name
declare -A NS_SUBSYS_ID        # ns_id -> subsystem id
declare -a NS_IDS=()           # ordered list of namespace IDs

# Subsystem data (indexed by subsystem name)
declare -A SUBSYS_ID           # subsys_name -> id
declare -A SUBSYS_NQN          # subsys_name -> subnqn

# VM config references (indexed by UUID)
declare -A VM_UUID_FILE        # uuid -> conf file path
declare -A VM_UUID_VMID        # uuid -> vmid
declare -A VM_UUID_STORAGE     # uuid -> storage name (from VM config)
declare -A VM_UUID_LINE        # uuid -> full config line

discover() {
    print_header "Phase 2: Discovery"

    # --- Parse storage configs ---
    info "Reading NVMe-TCP storage configurations..."
    while read -r name; do
        STORAGE_NAMES+=("$name")
        STORAGE_HOST["$name"]=$(get_storage_value "$name" "api_host")
        STORAGE_KEY["$name"]=$(get_storage_value "$name" "api_key")
        STORAGE_NQN["$name"]=$(get_storage_value "$name" "subsystem_nqn")
        STORAGE_DATASET["$name"]=$(get_storage_value "$name" "dataset")
        STORAGE_PORT["$name"]=$(get_storage_value "$name" "api_port")
        STORAGE_INSECURE["$name"]=$(get_storage_value "$name" "api_insecure")
        STORAGE_SCHEME["$name"]=$(get_storage_value "$name" "api_scheme")

        printf '  %b•%b %-25s dataset=%-30s nqn=%s\n' "$c6" "$c0" "$name" \
            "${STORAGE_DATASET[$name]}" "${STORAGE_NQN[$name]}"
    done < <(list_nvme_storages)
    echo ""

    # --- Check for duplicate NQNs ---
    declare -A nqn_storages
    for name in "${STORAGE_NAMES[@]}"; do
        local nqn="${STORAGE_NQN[$name]}"
        if [[ -n "${nqn_storages[$nqn]:-}" ]]; then
            nqn_storages["$nqn"]="${nqn_storages[$nqn]}, $name"
        else
            nqn_storages["$nqn"]="$name"
        fi
    done
    local has_dupes=0
    for nqn in "${!nqn_storages[@]}"; do
        if [[ "${nqn_storages[$nqn]}" == *","* ]]; then
            has_dupes=1
            error "Shared NQN detected: ${nqn_storages[$nqn]} share NQN:"
            error "  $nqn"
        fi
    done
    if [[ $has_dupes -eq 1 ]]; then
        echo ""
        error "Each storage MUST have its own unique subsystem NQN."
        error "Before running this script:"
        error "  1. Create a separate subsystem for each storage on TrueNAS"
        error "     (Sharing > NVMe-oF Targets > Subsystems)"
        error "  2. Update each storage's subsystem_nqn in /etc/pve/storage.cfg"
        error "  3. Re-run this script"
        exit 1
    fi

    # --- Pick API credentials (use first storage) ---
    local api_name="${STORAGE_NAMES[0]}"
    local api_host="${STORAGE_HOST[$api_name]}"
    local api_key="${STORAGE_KEY[$api_name]}"
    local api_port="${STORAGE_PORT[$api_name]:-}"
    local api_insecure="${STORAGE_INSECURE[$api_name]:-1}"
    local api_scheme="${STORAGE_SCHEME[$api_name]:-}"

    info "Testing API connectivity via storage '${api_name}'..."
    local ping_result
    if ! ping_result=$(tn_api_call "$api_host" "$api_key" "core.ping" "[]" "$api_port" "$api_insecure" "$api_scheme" 2>&1); then
        error "API connection failed: $ping_result"
        error "Check api_host and api_key for storage '${api_name}'"
        exit 1
    fi
    success "API connected to ${api_host}"

    # --- Query all namespaces ---
    info "Querying TrueNAS namespaces..."
    local ns_json
    if ! ns_json=$(tn_api_call "$api_host" "$api_key" "nvmet.namespace.query" "[[]]" "$api_port" "$api_insecure" "$api_scheme" 2>&1); then
        error "Failed to query namespaces: $ns_json"
        exit 1
    fi

    # Parse namespace JSON into arrays using Perl for reliable JSON handling
    # Pipe JSON via stdin to avoid command-line length limits
    local ns_eval
    ns_eval=$(echo "$ns_json" | perl -e '
        use JSON::PP;
        local $/;
        my $raw = <STDIN>;
        my $json = decode_json($raw);
        for my $ns (@$json) {
            my $id = $ns->{id};
            my $nsid = $ns->{nsid} // 0;
            my $uuid = $ns->{device_uuid} // "";
            my $nguid = $ns->{device_nguid} // "";
            my $path = $ns->{device_path} // "";
            my $sname = $ns->{subsys}{name} // "";
            my $sid = $ns->{subsys}{id} // 0;
            # Shell-safe quoting: replace single quotes
            s/\x27/\x27\\\x27\x27/g for ($uuid, $nguid, $path, $sname);
            print "NS_IDS+=($id)\n";
            print "NS_NSID[$id]=$nsid\n";
            printf "NS_UUID[%d]=\x27%s\x27\n", $id, $uuid;
            printf "NS_NGUID[%d]=\x27%s\x27\n", $id, $nguid;
            printf "NS_PATH[%d]=\x27%s\x27\n", $id, $path;
            printf "NS_SUBSYS_NAME[%d]=\x27%s\x27\n", $id, $sname;
            print "NS_SUBSYS_ID[$id]=$sid\n";
        }
    ') || true
    eval "$ns_eval"

    success "Found ${#NS_IDS[@]} namespace(s)"

    # --- Query all subsystems ---
    info "Querying TrueNAS subsystems..."
    local subsys_json
    if ! subsys_json=$(tn_api_call "$api_host" "$api_key" "nvmet.subsys.query" "[[]]" "$api_port" "$api_insecure" "$api_scheme" 2>&1); then
        error "Failed to query subsystems: $subsys_json"
        exit 1
    fi

    local subsys_eval
    subsys_eval=$(echo "$subsys_json" | perl -e '
        use JSON::PP;
        local $/;
        my $raw = <STDIN>;
        my $json = decode_json($raw);
        for my $s (@$json) {
            my $name = $s->{name} // "";
            my $id = $s->{id} // 0;
            my $nqn = $s->{subnqn} // "";
            s/\x27/\x27\\\x27\x27/g for ($name, $nqn);
            printf "SUBSYS_ID[\x27%s\x27]=%d\n", $name, $id;
            printf "SUBSYS_NQN[\x27%s\x27]=\x27%s\x27\n", $name, $nqn;
        }
    ') || true
    eval "$subsys_eval"

    success "Found ${#SUBSYS_ID[@]} subsystem(s)"

    # --- Verify target subsystems exist for all storages ---
    local missing_subsys=0
    for storage_name in "${STORAGE_NAMES[@]}"; do
        local nqn="${STORAGE_NQN[$storage_name]}"
        local found=0
        for sname in "${!SUBSYS_NQN[@]}"; do
            if [[ "${SUBSYS_NQN[$sname]}" == "$nqn" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            error "No subsystem found for storage '${storage_name}'"
            error "  Expected NQN: $nqn"
            error "  Create it in TrueNAS: Sharing > NVMe-oF Targets > Subsystems"
            error "  Ensure it has at least one TCP port configured."
            missing_subsys=$((missing_subsys + 1))
        fi
    done
    if [[ $missing_subsys -gt 0 ]]; then
        exit 1
    fi

    # --- Scan VM configs ---
    info "Scanning VM configurations..."
    local vm_count=0
    shopt -s nullglob
    local vm_conf_files=("$VM_CFG_BASE"/*/qemu-server/*.conf)
    shopt -u nullglob
    for conf in "${vm_conf_files[@]}"; do
        [[ -f "$conf" ]] || continue
        local vmid
        vmid=$(basename "$conf" .conf)

        while IFS= read -r line; do
            # Match lines like: scsi0: storage-name:vol-vm-102-disk-0-nsUUID,size=64G
            if [[ "$line" =~ ([a-zA-Z0-9_-]+):vol-([A-Za-z0-9:_.\-]+)-ns([a-f0-9-]+) ]]; then
                local storage="${BASH_REMATCH[1]}"
                local uuid="${BASH_REMATCH[3]}"

                VM_UUID_FILE["$uuid"]="$conf"
                VM_UUID_VMID["$uuid"]="$vmid"
                VM_UUID_STORAGE["$uuid"]="$storage"
                VM_UUID_LINE["$uuid"]="$line"
                vm_count=$((vm_count + 1))
            fi
        done < "$conf"
    done

    success "Found ${vm_count} NVMe disk reference(s) in VM configs"
}

# ============================================================
# Phase 3: Analysis
# ============================================================

# Analysis results
declare -a MISPLACED_NS_IDS=()    # namespace IDs that need moving
declare -A NS_EXPECTED_STORAGE     # ns_id -> storage name it should belong to
declare -A NS_EXPECTED_NQN         # ns_id -> NQN it should be on

analyze() {
    print_header "Phase 3: Analysis"

    info "Matching namespaces to storages by dataset prefix..."
    echo ""

    local misplaced=0
    local ok=0
    local orphan=0

    # Table header
    printf '  %-35s %-20s %-20s %s\n' "ZVOL PATH" "CURRENT SUBSYS" "EXPECTED SUBSYS" "STATUS"
    printf '  %-35s %-20s %-20s %s\n' "$(printf '%35s' '' | tr ' ' '-')" \
        "$(printf '%20s' '' | tr ' ' '-')" "$(printf '%20s' '' | tr ' ' '-')" \
        "$(printf '%10s' '' | tr ' ' '-')"

    for ns_id in "${NS_IDS[@]}"; do
        local path="${NS_PATH[$ns_id]}"
        local current_subsys="${NS_SUBSYS_NAME[$ns_id]}"
        local matched_storage=""
        local matched_nqn=""
        local multi_match=0

        # Match namespace to storage by dataset prefix
        # device_path is like "zvol/Pool/NVMe-oF/vm-102-disk-0"
        # dataset is like "Pool/NVMe-oF"
        for storage_name in "${STORAGE_NAMES[@]}"; do
            local dataset="${STORAGE_DATASET[$storage_name]}"
            if [[ "$path" == "zvol/${dataset}/"* ]]; then
                if [[ -n "$matched_storage" ]]; then
                    multi_match=1
                    break
                fi
                matched_storage="$storage_name"
                matched_nqn="${STORAGE_NQN[$storage_name]}"
            fi
        done

        # Determine the expected subsystem name from NQN
        local expected_subsys=""
        if [[ -n "$matched_nqn" ]]; then
            for sname in "${!SUBSYS_NQN[@]}"; do
                if [[ "${SUBSYS_NQN[$sname]}" == "$matched_nqn" ]]; then
                    expected_subsys="$sname"
                    break
                fi
            done
        fi

        # Determine status
        local status=""
        local status_color=""
        local short_path="${path#zvol/}"

        if [[ $multi_match -eq 1 ]]; then
            status="MULTI-MATCH"
            status_color="$c3"
            orphan=$((orphan + 1))
        elif [[ -z "$matched_storage" ]]; then
            status="ORPHAN"
            status_color="$c3"
            orphan=$((orphan + 1))
        elif [[ "$current_subsys" == "$expected_subsys" ]]; then
            status="OK"
            status_color="$c2"
            ok=$((ok + 1))
        else
            status="MISPLACED"
            status_color="$c5"
            MISPLACED_NS_IDS+=("$ns_id")
            NS_EXPECTED_STORAGE["$ns_id"]="$matched_storage"
            NS_EXPECTED_NQN["$ns_id"]="$matched_nqn"
            misplaced=$((misplaced + 1))
        fi

        printf '  %-35s %-20s %-20s %b%s%b\n' \
            "$short_path" \
            "$current_subsys" \
            "${expected_subsys:-"(none)"}" \
            "$status_color" "$status" "$c0"
    done

    echo ""
    success "Analysis complete: ${ok} OK, ${misplaced} misplaced, ${orphan} orphan/skipped"

    if [[ $misplaced -eq 0 ]]; then
        echo ""
        success "All namespaces are on the correct subsystems. Nothing to recover."
        exit 0
    fi

    echo ""
    warning "${misplaced} namespace(s) need to be reassigned."
    info "The underlying zvols (your data) will NOT be touched."
    info "Only the NVMe-oF publication will change."

    if [[ $DRY_RUN -eq 1 ]]; then
        # Show detailed plan of what would happen
        echo ""
        print_header "Recovery Plan (dry run)"

        for ns_id in "${MISPLACED_NS_IDS[@]}"; do
            local uuid="${NS_UUID[$ns_id]}"
            local path="${NS_PATH[$ns_id]}"
            local short_path="${path#zvol/}"
            local current_subsys="${NS_SUBSYS_NAME[$ns_id]}"
            local target_storage="${NS_EXPECTED_STORAGE[$ns_id]}"
            local target_nqn="${NS_EXPECTED_NQN[$ns_id]}"

            # Find target subsystem name
            local target_subsys_name="(unknown)"
            for sname in "${!SUBSYS_NQN[@]}"; do
                if [[ "${SUBSYS_NQN[$sname]}" == "$target_nqn" ]]; then
                    target_subsys_name="$sname"
                    break
                fi
            done

            printf '  %b•%b %s\n' "$c6" "$c0" "$short_path"
            printf '      %b%s%b  →  %b%s%b  (storage: %s)\n' \
                "$c5" "$current_subsys" "$c0" \
                "$c2" "$target_subsys_name" "$c0" \
                "$target_storage"

            if [[ -n "${VM_UUID_FILE[$uuid]:-}" ]]; then
                printf '      VM %s config will be updated with new UUID\n' "${VM_UUID_VMID[$uuid]}"
            fi
        done

        echo ""
        info "This was a dry run. No changes were made."
        info "To apply these changes, re-run with:"
        echo ""
        printf '    %b%s --accept%b\n' "$c8" "$0" "$c0"
        echo ""
        exit 0
    fi

    echo ""
    read -rp "  Proceed with recovery? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Recovery cancelled."
        exit 0
    fi
}

# ============================================================
# Phase 4: Per-Namespace Recovery
# ============================================================
recover() {
    print_header "Phase 4: Recovery"

    # Backup VM configs first
    info "Backing up VM configs to ${BACKUP_DIR}/ ..."
    mkdir -p "$BACKUP_DIR"
    local backed_up=0
    for ns_id in "${MISPLACED_NS_IDS[@]}"; do
        local uuid="${NS_UUID[$ns_id]}"
        if [[ -n "${VM_UUID_FILE[$uuid]:-}" ]]; then
            local conf="${VM_UUID_FILE[$uuid]}"
            if [[ ! -f "${BACKUP_DIR}/$(basename "$conf")" ]]; then
                cp "$conf" "$BACKUP_DIR/"
                backed_up=$((backed_up + 1))
            fi
        fi
    done
    success "Backed up ${backed_up} VM config file(s)"
    echo ""

    # Pick API credentials
    local api_name="${STORAGE_NAMES[0]}"
    local api_host="${STORAGE_HOST[$api_name]}"
    local api_key="${STORAGE_KEY[$api_name]}"
    local api_port="${STORAGE_PORT[$api_name]:-}"
    local api_insecure="${STORAGE_INSECURE[$api_name]:-1}"
    local api_scheme="${STORAGE_SCHEME[$api_name]:-}"

    local moved=0
    local skipped=0
    local failed=0

    for ns_id in "${MISPLACED_NS_IDS[@]}"; do
        local uuid="${NS_UUID[$ns_id]}"
        local path="${NS_PATH[$ns_id]}"
        local short_path="${path#zvol/}"
        local current_subsys="${NS_SUBSYS_NAME[$ns_id]}"
        local target_storage="${NS_EXPECTED_STORAGE[$ns_id]}"
        local target_nqn="${NS_EXPECTED_NQN[$ns_id]}"

        # Find target subsystem name and ID
        local target_subsys_name=""
        local target_subsys_id=""
        for sname in "${!SUBSYS_NQN[@]}"; do
            if [[ "${SUBSYS_NQN[$sname]}" == "$target_nqn" ]]; then
                target_subsys_name="$sname"
                target_subsys_id="${SUBSYS_ID[$sname]}"
                break
            fi
        done

        if [[ -z "$target_subsys_id" ]]; then
            error "Cannot find subsystem for NQN ${target_nqn}"
            error "Create the subsystem on TrueNAS first (Sharing > NVMe-oF Targets > Subsystems)"
            failed=$((failed + 1))
            continue
        fi

        # Show what will happen
        printf '\n%b\n' "${c6}  ── Namespace: ${short_path} ──${c0}"
        printf '  Current subsystem:  %b%s%b\n' "$c5" "$current_subsys" "$c0"
        printf '  Target subsystem:   %b%s%b (storage: %s)\n' "$c2" "$target_subsys_name" "$c0" "$target_storage"
        printf '  Device UUID:        %s\n' "$uuid"

        # Show VM config change if applicable
        if [[ -n "${VM_UUID_FILE[$uuid]:-}" ]]; then
            local vmid="${VM_UUID_VMID[$uuid]}"
            local conf_line="${VM_UUID_LINE[$uuid]}"
            printf '  VM config:          VM %s\n' "$vmid"
            printf '    %b(UUID will be updated after reassignment)%b\n' "$c3" "$c0"
        else
            printf '  VM config:          %b(no VM references this UUID)%b\n' "$c3" "$c0"
        fi

        echo ""
        read -rp "  Move this namespace? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            info "Skipped"
            skipped=$((skipped + 1))
            continue
        fi

        # --- Execute the move ---

        # Step 1: Delete from old subsystem
        info "Deleting namespace from '${current_subsys}'..."
        if ! tn_api_call_write "$api_host" "$api_key" "nvmet.namespace.delete" "[$ns_id]" "$api_port" "$api_insecure" "$api_scheme" &>/dev/null; then
            error "Failed to delete namespace $ns_id from ${current_subsys}"
            failed=$((failed + 1))
            continue
        fi
        success "Deleted from '${current_subsys}'"

        # Step 2: Create on target subsystem
        info "Creating namespace on '${target_subsys_name}'..."
        local create_params
        create_params=$(printf '[{"subsys_id": %s, "device_type": "ZVOL", "device_path": "%s", "enabled": true}]' \
            "$target_subsys_id" "$path")

        local create_result
        if ! create_result=$(tn_api_call_write "$api_host" "$api_key" "nvmet.namespace.create" "$create_params" "$api_port" "$api_insecure" "$api_scheme" 2>&1); then
            error "Failed to create namespace on '${target_subsys_name}': $create_result"
            warning "Attempting rollback: recreating on original subsystem '${current_subsys}'..."
            local rollback_params
            rollback_params=$(printf '[{"subsys_id": %s, "device_type": "ZVOL", "device_path": "%s", "enabled": true}]' \
                "${NS_SUBSYS_ID[$ns_id]}" "$path")
            if tn_api_call_write "$api_host" "$api_key" "nvmet.namespace.create" "$rollback_params" "$api_port" "$api_insecure" "$api_scheme" &>/dev/null; then
                warning "Rollback succeeded — namespace restored to '${current_subsys}'"
            else
                error "Rollback failed. Manual recovery needed:"
                error "  zvol path: $path"
                error "  original subsystem ID: ${NS_SUBSYS_ID[$ns_id]}"
                error "  target subsystem ID: $target_subsys_id"
            fi
            failed=$((failed + 1))
            continue
        fi

        local new_uuid
        new_uuid=$(parse_json_field "$create_result" "device_uuid")
        if [[ -z "$new_uuid" ]]; then
            error "Namespace created but could not extract new UUID from response"
            error "Response: $create_result"
            failed=$((failed + 1))
            continue
        fi
        success "Created on '${target_subsys_name}' with new UUID: ${new_uuid}"

        # Step 3: Update VM config
        if [[ -n "${VM_UUID_FILE[$uuid]:-}" ]]; then
            local conf="${VM_UUID_FILE[$uuid]}"
            local vmid="${VM_UUID_VMID[$uuid]}"

            info "Updating VM ${vmid} config..."

            # Show the exact change
            local old_fragment="ns${uuid}"
            local new_fragment="ns${new_uuid}"
            local old_line new_line
            old_line=$(grep "${old_fragment}" "$conf" | head -1)
            new_line="${old_line//${old_fragment}/${new_fragment}}"

            printf '    %b-%b %s\n' "$c1" "$c0" "$old_line"
            printf '    %b+%b %s\n' "$c2" "$c0" "$new_line"

            sed -i "s/${old_fragment}/${new_fragment}/g" "$conf"
            success "Updated VM ${vmid} config"
        fi

        moved=$((moved + 1))
        success "Namespace '${short_path}' recovered successfully"
    done

    echo ""
    print_header "Recovery Summary"
    printf '  Moved:    %b%d%b\n' "$c2" "$moved" "$c0"
    printf '  Skipped:  %b%d%b\n' "$c3" "$skipped" "$c0"
    printf '  Failed:   %b%d%b\n' "$c1" "$failed" "$c0"

    if [[ $failed -gt 0 ]]; then
        warning "Some namespaces failed. Check ${LOG_FILE} for details."
        warning "VM config backups are at: ${BACKUP_DIR}/"
    fi

    echo ""
    RECOVERED_COUNT=$moved
}

# ============================================================
# Phase 5: Reconnect
# ============================================================
reconnect() {
    local moved="$1"

    if [[ $moved -eq 0 ]]; then
        info "No namespaces were moved. Skipping reconnect."
        return
    fi

    print_header "Phase 5: Reconnect"

    info "Namespaces have been reassigned. NVMe sessions need to be refreshed."

    # Detect cluster nodes
    local -a cluster_nodes=()
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null 2>&1; then
        while IFS= read -r node_ip; do
            [[ -n "$node_ip" ]] && cluster_nodes+=("$node_ip")
        done < <(pvecm status 2>/dev/null | awk '/^0x/{print $NF}')
    fi

    if [[ ${#cluster_nodes[@]} -gt 1 ]]; then
        echo ""
        warning "Cluster detected with ${#cluster_nodes[@]} nodes."
        info "ALL cluster nodes need NVMe sessions refreshed."
    fi

    echo ""
    read -rp "  Disconnect NVMe sessions and restart PVE services? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        warning "Skipped. You will need to manually run on EACH cluster node:"
        info "  nvme disconnect-all"
        info "  systemctl restart pvedaemon pveproxy pvestatd"
        return
    fi

    info "Disconnecting NVMe sessions on this node..."
    nvme disconnect-all 2>/dev/null || true
    success "NVMe sessions disconnected"

    info "Restarting pvedaemon, pveproxy, pvestatd on this node..."
    systemctl restart pvedaemon pveproxy pvestatd
    success "Services restarted"

    info "Waiting for NVMe connections to re-establish..."
    sleep 5

    info "Current NVMe subsystem connections:"
    nvme list-subsys 2>/dev/null | head -30 || true

    echo ""
    success "Recovery complete on this node."
    if [[ ${#cluster_nodes[@]} -gt 1 ]]; then
        echo ""
        warning "IMPORTANT: Run the following on each OTHER cluster node:"
        info "  nvme disconnect-all && systemctl restart pvedaemon pveproxy pvestatd"
    fi
    info "Start your VMs one at a time to verify each one works."
    info "VM config backups are at: ${BACKUP_DIR}/"
}

# ============================================================
# Main
# ============================================================
RECOVERED_COUNT=0

main() {
    print_banner
    log "INFO" "=== NVMe Recovery Tool started ==="

    preflight_checks
    discover
    analyze
    recover
    reconnect "$RECOVERED_COUNT"

    log "INFO" "=== NVMe Recovery Tool finished ==="
}

main "$@"
