# tools/lib/common.sh
# Shared utilities for the TrueNAS Proxmox plugin test harness.
# Source this file; do not execute directly.

# Global counters — set by sourcing script before calling log_* functions.
# PASS_COUNT, FAIL_COUNT, SKIP_COUNT, HARD_GATE_FAILED must be declared by caller.
# LOG_FILE must be set by caller.

log_pass() {
    local msg="[PASS] $*"
    echo "$msg"
    echo "$(date '+%H:%M:%S') $msg" >> "${LOG_FILE:-/dev/null}"
    PASS_COUNT=$((${PASS_COUNT:-0}+1))
}

log_fail() {
    local msg="[FAIL] $*"
    echo "$msg"
    echo "$(date '+%H:%M:%S') $msg" >> "${LOG_FILE:-/dev/null}"
    FAIL_COUNT=$((${FAIL_COUNT:-0}+1))
}

log_skip() {
    local msg="[SKIP] $*"
    echo "$msg"
    echo "$(date '+%H:%M:%S') $msg" >> "${LOG_FILE:-/dev/null}"
    SKIP_COUNT=$((${SKIP_COUNT:-0}+1))
}

log_warn() {
    local msg="[WARN] $*"
    echo "$msg"
    echo "$(date '+%H:%M:%S') $msg" >> "${LOG_FILE:-/dev/null}"
}

log_info() {
    local msg="[INFO] $*"
    echo "$msg"
    echo "$(date '+%H:%M:%S') $msg" >> "${LOG_FILE:-/dev/null}"
}

# Read a value from a storage.cfg file for a given storage name and key.
# Usage: read_storage_cfg_file <cfg_file> <storage_name> <key> [default]
read_storage_cfg_file() {
    local cfg_file="$1" storage="$2" key="$3" default="${4:-}"
    local found=""
    found=$(awk -v storage="$storage" -v key="$key" -v dflt="$default" '
        /^[^ \t]/ { in_section = ($2 == storage) }
        in_section && /^[ \t]/ {
            split($0, parts, /[ \t]+/)
            if (parts[2] == key) { print parts[3]; found=1; exit }
        }
        END { if (!found) print dflt }
    ' "$cfg_file")
    echo "${found}"
}

# Read a value from the live Proxmox storage config.
# Usage: read_storage_cfg <storage_name> <key> [default]
read_storage_cfg() {
    read_storage_cfg_file /etc/pve/storage.cfg "$@"
}

# Compute the maximum wait window for the API retry test (T1-02).
# Usage: retry_window_seconds <api_retry_max> <api_retry_delay>
# Formula: (15 * retry_max) + (delay * retry_max) + 30
retry_window_seconds() {
    local max="$1" delay="$2"
    echo $(( (15 * max) + (delay * max) + 30 ))
}

# Track active iptables blocks so they can be cleaned up on exit
_IPTABLES_BLOCKS=()

# Block outbound TCP to host:port using iptables OUTPUT chain.
# Usage: iptables_block <host> <port>
iptables_block() {
    iptables -A OUTPUT -p tcp --destination "$1" --dport "$2" -j DROP
    _IPTABLES_BLOCKS+=("$1:$2")
}

# Remove the OUTPUT chain block for host:port.
# Usage: iptables_unblock <host> <port>
iptables_unblock() {
    iptables -D OUTPUT -p tcp --destination "$1" --dport "$2" -j DROP 2>/dev/null || true
    local new_blocks=()
    for b in "${_IPTABLES_BLOCKS[@]:-}"; do
        [[ "$b" != "$1:$2" ]] && new_blocks+=("$b")
    done
    _IPTABLES_BLOCKS=("${new_blocks[@]:-}")
}

# Remove all tracked iptables blocks. Called by EXIT trap in run-tests.sh.
iptables_cleanup_all() {
    for b in "${_IPTABLES_BLOCKS[@]:-}"; do
        local host="${b%:*}" port="${b##*:}"
        iptables -D OUTPUT -p tcp --destination "$host" --dport "$port" -j DROP 2>/dev/null || true
    done
    _IPTABLES_BLOCKS=()
}

# Run a command on a remote cluster node as root via SSH.
# Usage: ssh_run <node_ip_or_hostname> <command...>
ssh_run() {
    local node="$1"; shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "root@$node" "$@"
}

# Check if a remote node is SSH-reachable as root.
# Returns 0 if reachable, 1 otherwise.
ssh_reachable() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "root@$1" true 2>/dev/null
}

# Call a TrueNAS WebSocket API method via the plugin's Perl code path.
# Usage: tn_api_call <storage_name> <method> [json_params]
# Returns: JSON result on stdout, exits non-zero on failure.
# Requires: PVE::Storage::Custom::TrueNASPlugin installed, storage configured in storage.cfg.
tn_api_call() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: tn_api_call <storage_name> <method> [json_params]" >&2
        return 1
    fi
    local storage="$1" method="$2" params="${3:-[]}"

    local api_host api_key api_insecure
    api_host=$(read_storage_cfg "$storage" "api_host")
    api_key=$(read_storage_cfg "$storage" "api_key")
    api_insecure=$(read_storage_cfg "$storage" "api_insecure" "0")

    if [[ -z "$api_host" || -z "$api_key" ]]; then
        echo "tn_api_call: could not read api_host/api_key for storage '$storage'" >&2
        return 1
    fi

    perl -e '
        use strict; use warnings;
        use JSON::PP;
        # Minimal scfg hash — only what _ws_open and _api_call need
        my $scfg = {
            api_host     => $ARGV[0],
            api_key      => $ARGV[1],
            api_insecure => int($ARGV[2]),
            prefer_ipv4  => 1,
        };
        my $method = $ARGV[3];
        my $params = decode_json($ARGV[4]);

        require PVE::Storage::Custom::TrueNASPlugin;
        my $conn = PVE::Storage::Custom::TrueNASPlugin::_ws_open($scfg);
        my $result = PVE::Storage::Custom::TrueNASPlugin::_ws_rpc($conn, {
            jsonrpc => "2.0",
            id      => 1,
            method  => $method,
            params  => $params,
        });
        print encode_json($result) . "\n" if defined $result;
    ' "$api_host" "$api_key" "$api_insecure" "$method" "$params"
}

# Parse multipath -ll output for one device and emit shell variable assignments.
# Usage: eval "$(multipath -ll <dm_device> | parse_multipath_ll)"
# Sets: MP_DM_DEVICE, MP_HWHANDLER, MP_PRIO_HIGH, MP_PRIO_LOW,
#        MP_PATH_HIGH, MP_PATH_LOW, MP_STATUS_HIGH, MP_STATUS_LOW,
#        MP_SCSI_HIGH, MP_SCSI_LOW
# Reads from stdin. Parses the first device stanza only.
parse_multipath_ll() {
    local dm_device="" hwhandler=""
    local prio_high=0 prio_low=999 path_high="" path_low=""
    local status_high="" status_low="" scsi_high="" scsi_low=""
    local path_active="" prio_active=0 scsi_active=""
    local path_enabled="" prio_enabled=0 scsi_enabled=""
    local current_prio=0 current_status=""

    while IFS= read -r line; do
        # First line: mpathX (wwid) dm-N vendor,product
        if [[ -z "$dm_device" ]] && [[ "$line" =~ (dm-[0-9]+) ]]; then
            dm_device="${BASH_REMATCH[1]}"
        fi
        # hwhandler line
        if [[ "$line" =~ hwhandler=\'([^\']*)\' ]]; then
            hwhandler="${BASH_REMATCH[1]}"
        fi
        # Path group line: prio=NN status=XXX
        if [[ "$line" =~ prio=([0-9]+) ]]; then
            current_prio="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ status=([a-z]+) ]]; then
            current_status="${BASH_REMATCH[1]}"
        fi
        # Path line: H:C:T:L sdX M:m state1 state2 state3
        if [[ "$line" =~ ([0-9]+:[0-9]+:[0-9]+:[0-9]+)[[:space:]]+(sd[a-z]+) ]]; then
            local scsi_addr="${BASH_REMATCH[1]}"
            local sd_dev="${BASH_REMATCH[2]}"
            if [[ "$current_prio" -gt "$prio_high" ]]; then
                prio_high="$current_prio"
                path_high="$sd_dev"
                status_high="$current_status"
                scsi_high="$scsi_addr"
            fi
            if [[ "$current_prio" -lt "$prio_low" ]]; then
                prio_low="$current_prio"
                path_low="$sd_dev"
                status_low="$current_status"
                scsi_low="$scsi_addr"
            fi
            # Track path group by status (active = carrying I/O)
            if [[ "$current_status" == "active" ]]; then
                path_active="$sd_dev"
                prio_active="$current_prio"
                scsi_active="$scsi_addr"
            elif [[ "$current_status" == "enabled" ]]; then
                path_enabled="$sd_dev"
                prio_enabled="$current_prio"
                scsi_enabled="$scsi_addr"
            fi
        fi
    done

    echo "MP_DM_DEVICE='$dm_device'"
    echo "MP_HWHANDLER='$hwhandler'"
    echo "MP_PRIO_HIGH='$prio_high'"
    echo "MP_PRIO_LOW='$prio_low'"
    echo "MP_PATH_HIGH='$path_high'"
    echo "MP_PATH_LOW='$path_low'"
    echo "MP_STATUS_HIGH='$status_high'"
    echo "MP_STATUS_LOW='$status_low'"
    echo "MP_SCSI_HIGH='$scsi_high'"
    echo "MP_SCSI_LOW='$scsi_low'"
    echo "MP_PATH_ACTIVE='$path_active'"
    echo "MP_PRIO_ACTIVE='$prio_active'"
    echo "MP_SCSI_ACTIVE='$scsi_active'"
    echo "MP_PATH_ENABLED='$path_enabled'"
    echo "MP_PRIO_ENABLED='$prio_enabled'"
    echo "MP_SCSI_ENABLED='$scsi_enabled'"
}

# ============================================================
# Shared HA failover helpers — used by Tier 4 and Tier 5
# ============================================================
HA_FAILOVER_TIMEOUT=180     # seconds to wait for VIP API recovery
HA_POLL_INTERVAL=5          # seconds between poll attempts
HA_STANDBY_TIMEOUT=300      # seconds to wait for standby controller
HA_RECOVERY_ELAPSED=0       # set by ha_wait_for_api after successful recovery

# Poll TrueNAS VIP until the API responds or timeout expires.
# Usage: ha_wait_for_api <storage_name> [timeout]
# Returns 0 on recovery, 1 on timeout. Sets HA_RECOVERY_ELAPSED.
ha_wait_for_api() {
    local storage="$1"
    local timeout="${2:-$HA_FAILOVER_TIMEOUT}"
    local start_time
    start_time=$(date +%s)
    HA_RECOVERY_ELAPSED=0

    while [[ $(( $(date +%s) - start_time )) -lt $timeout ]]; do
        if tn_api_call "$storage" "failover.status" &>/dev/null; then
            HA_RECOVERY_ELAPSED=$(( $(date +%s) - start_time ))
            return 0
        fi
        sleep "$HA_POLL_INTERVAL"
    done

    HA_RECOVERY_ELAPSED=$timeout
    return 1
}

# Wait for the standby controller to become reachable.
# Polls failover.call_remote core.ping until success or timeout.
# Usage: ha_wait_for_standby <storage_name> [timeout]
# Returns 0 on success, 1 on timeout.
ha_wait_for_standby() {
    local storage="$1"
    local timeout="${2:-$HA_STANDBY_TIMEOUT}"
    local start_time
    start_time=$(date +%s)

    log_info "Waiting for standby controller to become ready (timeout: ${timeout}s)..."

    while [[ $(( $(date +%s) - start_time )) -lt $timeout ]]; do
        local result
        result=$(tn_api_call "$storage" "failover.call_remote" '["core.ping"]' 2>/dev/null || true)
        if [[ "$result" == *"pong"* ]]; then
            local elapsed=$(( $(date +%s) - start_time ))
            log_info "Standby controller ready in ${elapsed}s"
            return 0
        fi
        sleep "$HA_POLL_INTERVAL"
    done

    log_warn "Standby controller not ready within ${timeout}s"
    return 1
}
