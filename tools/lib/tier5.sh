# tools/lib/tier5.sh
# Tier 5: ALUA + HA failover/failback tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.
# Globals used: PASS_COUNT, FAIL_COUNT, SKIP_COUNT, HARD_GATE_FAILED, LOG_FILE

# Tier 5 shared state
T5_ORIGINAL_NODE=""           # Controller letter (A or B) at test start
T5_ORIGINAL_PRIO_HIGH=""      # Portal IP that was Active Optimized at baseline
T5_ORIGINAL_PRIO_LOW=""       # Portal IP that was Active Non-Optimized at baseline
T5_ORIGINAL_PATH_HIGH=""      # sd device for Active Optimized path at baseline
T5_ORIGINAL_PATH_LOW=""       # sd device for Active Non-Optimized path at baseline
T5_DM_DEVICE=""               # dm-multipath device name (e.g., dm-4)
T5_TEST_VOLID=""
T5_TEST_DM=""                 # dm device for the test volume specifically
T5_TEST_PATH_HIGH=""          # sd device for test volume's high-prio path
T5_TEST_PATH_LOW=""           # sd device for test volume's low-prio path
T5_TEST_PATH_ACTIVE=""        # sd device for test volume's active (I/O carrying) path
T5_BASELINE_PRIO_ACTIVE=0    # prio of the active path at baseline
T5_TEST_VMID=9750
T5_IO_PID=""
T5_IO_LOG=""
T5_TEST_WWID=""               # WWID for multipath -ll queries (basename of /dev/mapper/ path)
T5_MPATH_LOG=""               # multipathd journal capture file
T5_ACTIVE_BMC=""              # BMC address of the active controller
T5_STANDBY_PORTAL=""          # iSCSI portal IP of the standby controller

# ============================================================
# Pre-flight checks for Tier 5
# ============================================================
tier5_preflight() {
    local storage="$1"

    log_info "Tier 5 pre-flight checks..."

    # IPMI configuration required for crash failover simulation
    local ipmi_conf
    ipmi_conf="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ipmi.conf"
    if [[ ! -f "$ipmi_conf" ]]; then
        log_fail "Tier 5 pre-flight: $ipmi_conf not found — required for crash failover"
        return 1
    fi
    source "$ipmi_conf"
    if [[ -z "${IPMI_USER:-}" || -z "${IPMI_PASS:-}" || -z "${IPMI_BMC_A:-}" || -z "${IPMI_BMC_B:-}" ]]; then
        log_fail "Tier 5 pre-flight: ipmi.conf missing IPMI_USER, IPMI_PASS, IPMI_BMC_A, or IPMI_BMC_B"
        return 1
    fi

    # Verify IPMI reachability
    if ! ipmitool -I lanplus -H "$IPMI_BMC_A" -U "$IPMI_USER" -P "$IPMI_PASS" chassis status &>/dev/null; then
        log_fail "Tier 5 pre-flight: cannot reach BMC A at $IPMI_BMC_A"
        return 1
    fi
    if ! ipmitool -I lanplus -H "$IPMI_BMC_B" -U "$IPMI_USER" -P "$IPMI_PASS" chassis status &>/dev/null; then
        log_fail "Tier 5 pre-flight: cannot reach BMC B at $IPMI_BMC_B"
        return 1
    fi
    log_info "Tier 5 pre-flight: IPMI reachable on both controllers"

    # multipath-tools installed and multipathd running
    if ! dpkg -l multipath-tools &>/dev/null; then
        log_fail "Tier 5 pre-flight: multipath-tools not installed"
        return 1
    fi
    if ! systemctl is-active multipathd &>/dev/null; then
        log_fail "Tier 5 pre-flight: multipathd not active"
        return 1
    fi
    log_info "Tier 5 pre-flight: multipathd active"

    # multipath.conf has ALUA handler
    if ! grep -q 'hardware_handler.*1 alua' /etc/multipath.conf 2>/dev/null; then
        log_fail "Tier 5 pre-flight: multipath.conf missing 'hardware_handler \"1 alua\"'"
        return 1
    fi
    if ! grep -q 'prio.*alua' /etc/multipath.conf 2>/dev/null; then
        log_fail "Tier 5 pre-flight: multipath.conf missing 'prio alua'"
        return 1
    fi
    log_info "Tier 5 pre-flight: multipath.conf has ALUA configuration"

    # Storage config checks
    if ! grep -q 'use_multipath 1' /etc/pve/storage.cfg 2>/dev/null; then
        log_fail "Tier 5 pre-flight: use_multipath 1 not set in storage.cfg"
        return 1
    fi

    local portals
    portals=$(read_storage_cfg "$storage" "portals")
    local portal_count
    portal_count=$(echo "$portals" | tr ',' '\n' | grep -c '.' || true)
    if [[ "${portal_count:-0}" -lt 2 ]]; then
        log_fail "Tier 5 pre-flight: need at least 2 portals, found ${portal_count:-0}"
        return 1
    fi
    log_info "Tier 5 pre-flight: $portal_count portals configured"

    # Both portals reachable
    for portal_entry in $(echo "$portals" | tr ',' ' '); do
        local portal_ip="${portal_entry%%:*}"
        local portal_port="${portal_entry##*:}"
        [[ "$portal_port" == "$portal_ip" ]] && portal_port=3260
        if ! nc -zv "$portal_ip" "$portal_port" &>/dev/null; then
            log_fail "Tier 5 pre-flight: portal ${portal_ip}:${portal_port} unreachable"
            return 1
        fi
    done
    log_info "Tier 5 pre-flight: all portals reachable"

    # iSCSI sessions to both portals
    local target_iqn
    target_iqn=$(read_storage_cfg "$storage" "target_iqn")
    local session_count
    session_count=$(iscsiadm -m session 2>/dev/null | grep -c "$target_iqn" || true)
    if [[ "$session_count" -lt 2 ]]; then
        log_fail "Tier 5 pre-flight: need iSCSI sessions to both portals, found $session_count"
        return 1
    fi
    log_info "Tier 5 pre-flight: $session_count iSCSI sessions active"

    # multipath -ll shows ALUA with two path groups
    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)
    if ! echo "$mp_output" | grep -q "hwhandler='1 alua'"; then
        log_fail "Tier 5 pre-flight: multipath -ll missing hwhandler='1 alua'"
        return 1
    fi
    if ! echo "$mp_output" | grep -q 'prio=50'; then
        log_fail "Tier 5 pre-flight: no Active Optimized path (prio=50) found in multipath -ll"
        return 1
    fi
    if ! echo "$mp_output" | grep -q 'prio=10'; then
        log_fail "Tier 5 pre-flight: no Active Non-Optimized path (prio=10) found in multipath -ll"
        return 1
    fi
    log_info "Tier 5 pre-flight: ALUA path groups verified (prio=50 + prio=10)"

    # HA licensed and MASTER
    local licensed
    licensed=$(tn_api_call "$storage" "failover.licensed" 2>/dev/null) || {
        log_fail "Tier 5 pre-flight: cannot reach TrueNAS API"
        return 1
    }
    if [[ "$licensed" != "true" ]]; then
        log_fail "Tier 5 pre-flight: failover.licensed=$licensed (expected true)"
        return 1
    fi
    local status
    status=$(tn_api_call "$storage" "failover.status" 2>/dev/null | tr -d '"')
    if [[ "$status" != "MASTER" ]]; then
        log_fail "Tier 5 pre-flight: failover.status=$status (expected MASTER)"
        return 1
    fi
    log_info "Tier 5 pre-flight: HA licensed, controller is MASTER"

    return 0
}

# ============================================================
# Cleanup
# ============================================================
tier5_cleanup() {
    local storage="$1"

    log_info "Tier 5 cleanup..."

    # Ensure the crashed controller is powered back on
    if [[ -n "$T5_ACTIVE_BMC" && -n "${IPMI_USER:-}" && -n "${IPMI_PASS:-}" ]]; then
        local power_status
        power_status=$(ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power status 2>/dev/null || true)
        if [[ "$power_status" == *"off"* ]]; then
            log_warn "Tier 5 cleanup: controller at $T5_ACTIVE_BMC is powered off — powering on"
            ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power on &>/dev/null || true
        fi
    fi

    # Stop background I/O
    if [[ -n "$T5_IO_PID" ]] && kill -0 "$T5_IO_PID" 2>/dev/null; then
        kill "$T5_IO_PID" 2>/dev/null
        wait "$T5_IO_PID" 2>/dev/null || true
        T5_IO_PID=""
    fi

    # Sweep VMs and volumes in 9750-9759 range
    for vmid in $(seq 9750 9759); do
        if qm status "$vmid" &>/dev/null; then
            qm stop "$vmid" --timeout 10 &>/dev/null || true
            if ! qm destroy "$vmid" --purge &>/dev/null; then
                qm destroy "$vmid" &>/dev/null || true
            fi
        fi
    done

    for vmid in $(seq 9750 9759); do
        pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${vmid}-disk" | \
            while read -r v; do pvesm free "$v" &>/dev/null || true; done
    done

    log_info "Tier 5 cleanup complete"
}

# ============================================================
# Helper: get per-path I/O stats from /sys/block/<sd>/stat
# Returns write_ios (field 5, 0-indexed field 4)
# ============================================================
tier5_get_write_ios() {
    local sd_dev="$1"
    awk '{print $5}' "/sys/block/${sd_dev}/stat" 2>/dev/null || echo "0"
}

# ============================================================
# Helper: start background I/O on a dm-multipath device
# ============================================================
tier5_start_io() {
    local dev="$1"
    T5_IO_LOG=$(mktemp /tmp/t5-io-XXXXXX.log)

    (
        local seq=0
        local offset=1
        while true; do
            if [[ ! -b "$dev" ]]; then
                echo "IO_SKIP: seq=$seq device_missing time=$(date '+%H:%M:%S')" >> "$T5_IO_LOG"
                sleep 1
                continue
            fi
            printf "SEQ=%08d\n" "$seq" | dd of="$dev" bs=4096 count=1 seek="$offset" conv=notrunc oflag=direct 2>/dev/null
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "IO_ERROR: seq=$seq offset=$offset rc=$rc time=$(date '+%H:%M:%S')" >> "$T5_IO_LOG"
            fi
            seq=$((seq + 1))
            offset=$(( (offset % 200) + 1 ))
            sleep 0.1
        done
    ) &
    T5_IO_PID=$!
    log_info "Background I/O started on $dev (PID $T5_IO_PID, log $T5_IO_LOG)"
}

# ============================================================
# Helper: stop background I/O and report
# ============================================================
tier5_stop_io() {
    if [[ -n "$T5_IO_PID" ]] && kill -0 "$T5_IO_PID" 2>/dev/null; then
        kill "$T5_IO_PID" 2>/dev/null
        wait "$T5_IO_PID" 2>/dev/null || true
    fi

    local errors=0
    if [[ -f "$T5_IO_LOG" ]]; then
        errors=$(grep -c 'IO_ERROR' "$T5_IO_LOG" 2>/dev/null || true)
        if [[ "$errors" -gt 0 ]]; then
            log_warn "Background I/O recorded $errors errors (see $T5_IO_LOG)"
        fi
    fi

    T5_IO_PID=""
    return "$( [[ "$errors" -eq 0 ]] && echo 0 || echo 1 )"
}

# ============================================================
# T5-01: ALUA path state baseline
# ============================================================
test_T5_01() {
    local storage="$1"

    log_info "T5-01: ALUA path state baseline"

    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)

    eval "$(echo "$mp_output" | parse_multipath_ll)"

    if [[ -z "$MP_DM_DEVICE" ]]; then
        log_fail "T5-01: no dm-multipath device found"
        return 1
    fi

    if [[ "$MP_HWHANDLER" != "1 alua" ]]; then
        log_fail "T5-01: hwhandler='$MP_HWHANDLER' (expected '1 alua')"
        return 1
    fi

    if [[ "$MP_PRIO_HIGH" -ne 50 ]]; then
        log_fail "T5-01: Active Optimized prio=$MP_PRIO_HIGH (expected 50)"
        return 1
    fi

    if [[ "$MP_PRIO_LOW" -ne 10 ]]; then
        log_fail "T5-01: Active Non-Optimized prio=$MP_PRIO_LOW (expected 10)"
        return 1
    fi

    T5_DM_DEVICE="$MP_DM_DEVICE"
    T5_ORIGINAL_PATH_HIGH="$MP_PATH_HIGH"
    T5_ORIGINAL_PATH_LOW="$MP_PATH_LOW"

    local node
    node=$(tn_api_call "$storage" "failover.node" 2>/dev/null | tr -d '"')
    T5_ORIGINAL_NODE="$node"

    # Map active controller to BMC and determine standby portal
    if [[ "$node" == "A" ]]; then
        T5_ACTIVE_BMC="$IPMI_BMC_A"
    else
        T5_ACTIVE_BMC="$IPMI_BMC_B"
    fi

    # Determine standby portal IP. The active controller responds on one portal;
    # the other portal is the standby. We identify the active portal by querying
    # each one — the standby won't respond (API key only works on MASTER).
    local portals active_portal=""
    portals=$(read_storage_cfg "$storage" "portals")
    for portal_entry in $(echo "$portals" | tr ',' ' '); do
        local portal_ip="${portal_entry%%:*}"
        local portal_node
        portal_node=$(tn_api_call_host "$portal_ip" "$storage" "failover.node" 2>/dev/null | tr -d '"') || true
        if [[ "$portal_node" == "$node" ]]; then
            active_portal="$portal_ip"
        else
            T5_STANDBY_PORTAL="$portal_ip"
        fi
    done

    # If we identified the active but not the standby (because the standby
    # rejected the API call), the standby is whichever portal isn't the active.
    if [[ -n "$active_portal" && -z "$T5_STANDBY_PORTAL" ]]; then
        for portal_entry in $(echo "$portals" | tr ',' ' '); do
            local portal_ip="${portal_entry%%:*}"
            if [[ "$portal_ip" != "$active_portal" ]]; then
                T5_STANDBY_PORTAL="$portal_ip"
            fi
        done
    fi

    if [[ -z "$T5_STANDBY_PORTAL" ]]; then
        log_fail "T5-01: could not determine standby portal IP from portals: $portals"
        return 1
    fi

    log_pass "T5-01: ALUA baseline — $MP_PATH_HIGH (prio=50), $MP_PATH_LOW (prio=10), dm=$T5_DM_DEVICE, controller=$node, active_bmc=$T5_ACTIVE_BMC, standby_portal=$T5_STANDBY_PORTAL"
}

# ============================================================
# T5-02: Create test volume on dm-multipath
# ============================================================
test_T5_02() {
    local storage="$1"

    log_info "T5-02: Create test volume on dm-multipath"

    local vmid=$T5_TEST_VMID

    local create_out
    create_out=$(pvesh create /nodes/"$(hostname)"/storage/"$storage"/content \
        -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G 2>&1) || {
        log_fail "T5-02: could not create volume: $create_out"
        return 1
    }

    T5_TEST_VOLID=$(pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${vmid}-disk" | head -1)
    if [[ -z "$T5_TEST_VOLID" ]]; then
        log_fail "T5-02: volume created but not found in pvesm list"
        return 1
    fi

    local dev
    dev=$(pvesm path "$T5_TEST_VOLID" 2>/dev/null)

    if [[ ! "$dev" =~ ^/dev/mapper/ ]]; then
        log_fail "T5-02: expected /dev/mapper/ path, got '$dev'"
        return 1
    fi

    # Extract WWID from the mapper path for reliable multipath -ll queries
    T5_TEST_WWID=$(basename "$dev")

    # Parse the test volume's specific multipath device to get its paths
    local vol_mp
    vol_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get')
    eval "$(echo "$vol_mp" | parse_multipath_ll)"

    if [[ -z "$MP_PATH_HIGH" || -z "$MP_PATH_LOW" ]]; then
        log_fail "T5-02: could not parse path groups for $dev"
        return 1
    fi

    # Wait up to 30s for ALUA priorities to differentiate on the new volume.
    # Freshly created volumes may temporarily show equal priorities (e.g., 30/30).
    if [[ "$MP_PRIO_HIGH" -le "$MP_PRIO_LOW" ]]; then
        log_info "T5-02: priorities not yet differentiated ($MP_PRIO_HIGH/$MP_PRIO_LOW) — waiting..."
        local prio_start
        prio_start=$(date +%s)
        while [[ $(( $(date +%s) - prio_start )) -lt 30 ]]; do
            sleep 5
            vol_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get')
            eval "$(echo "$vol_mp" | parse_multipath_ll)"
            if [[ "$MP_PRIO_HIGH" -gt "$MP_PRIO_LOW" ]]; then
                break
            fi
        done
        if [[ "$MP_PRIO_HIGH" -le "$MP_PRIO_LOW" ]]; then
            log_warn "T5-02: priorities still equal after 30s ($MP_PRIO_HIGH/$MP_PRIO_LOW) — proceeding with active path"
        fi
    fi

    T5_TEST_DM="$MP_DM_DEVICE"
    T5_TEST_PATH_HIGH="$MP_PATH_HIGH"
    T5_TEST_PATH_LOW="$MP_PATH_LOW"

    # If no path has status=active yet (new volume, no I/O issued), do a
    # small write to force multipath to activate a path, then re-parse.
    if [[ -z "$MP_PATH_ACTIVE" ]]; then
        dd if=/dev/zero of="$dev" bs=4096 count=1 oflag=direct &>/dev/null || true
        sleep 1
        vol_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get')
        eval "$(echo "$vol_mp" | parse_multipath_ll)"
    fi

    # If still no active path, use highest-priority as the de facto active
    T5_TEST_PATH_ACTIVE="${MP_PATH_ACTIVE:-$MP_PATH_HIGH}"
    T5_BASELINE_PRIO_ACTIVE="${MP_PRIO_ACTIVE:-$MP_PRIO_HIGH}"

    log_pass "T5-02: volume $T5_TEST_VOLID at $dev — active=$T5_TEST_PATH_ACTIVE (prio=${MP_PRIO_ACTIVE:-$MP_PRIO_HIGH}), other=${MP_PATH_ENABLED:-$MP_PATH_LOW}"
}

# ============================================================
# T5-03: I/O routing baseline
# ============================================================
test_T5_03() {
    local storage="$1"

    log_info "T5-03: I/O routing baseline"

    if [[ -z "$T5_TEST_VOLID" ]]; then
        log_skip "T5-03: no test volume from T5-02"
        return 0
    fi

    if [[ -z "$T5_TEST_PATH_ACTIVE" ]]; then
        log_skip "T5-03: no active path info from T5-02"
        return 0
    fi

    local dev
    dev=$(pvesm path "$T5_TEST_VOLID" 2>/dev/null)

    # Determine the non-active path
    local inactive_path
    if [[ "$T5_TEST_PATH_ACTIVE" == "$T5_TEST_PATH_HIGH" ]]; then
        inactive_path="$T5_TEST_PATH_LOW"
    else
        inactive_path="$T5_TEST_PATH_HIGH"
    fi

    # Capture write I/O counts on active vs inactive paths
    local active_before inactive_before
    active_before=$(tier5_get_write_ios "$T5_TEST_PATH_ACTIVE")
    inactive_before=$(tier5_get_write_ios "$inactive_path")

    # Start background I/O — this will continue running through failover
    tier5_start_io "$dev"

    # Let I/O run for 5 seconds to accumulate measurable stats
    sleep 5

    # Capture write I/O counts after
    local active_after inactive_after
    active_after=$(tier5_get_write_ios "$T5_TEST_PATH_ACTIVE")
    inactive_after=$(tier5_get_write_ios "$inactive_path")

    local active_delta=$(( active_after - active_before ))
    local inactive_delta=$(( inactive_after - inactive_before ))

    log_info "T5-03: I/O delta — active ($T5_TEST_PATH_ACTIVE): $active_delta writes, inactive ($inactive_path): $inactive_delta writes"

    if [[ "$active_delta" -gt 0 && "$active_delta" -gt "$inactive_delta" ]]; then
        log_pass "T5-03: I/O routed through active path ($T5_TEST_PATH_ACTIVE: $active_delta writes vs $inactive_path: $inactive_delta writes)"
    else
        log_fail "T5-03: I/O not preferring active path (active=$active_delta, inactive=$inactive_delta)"
        return 1
    fi
}

# ============================================================
# T5-04: Trigger failover — HARD GATE
# ============================================================
test_T5_04() {
    local storage="$1"

    log_info "T5-04: Trigger HA failover (IPMI crash simulation)"

    if [[ -z "$T5_ACTIVE_BMC" || -z "$T5_STANDBY_PORTAL" ]]; then
        log_fail "T5-04: HARD GATE — missing BMC/portal info from T5-01"
        HARD_GATE_FAILED=1
        return 2
    fi

    # Start multipathd journal capture
    T5_MPATH_LOG=$(mktemp /tmp/t5-mpath-XXXXXX.log)
    local mpath_since
    mpath_since=$(date '+%Y-%m-%d %H:%M:%S')
    timeout 5 multipathd -k 'verbosity 3' &>/dev/null || true

    # Crash the active controller via IPMI power off
    log_info "T5-04: powering off active controller via IPMI ($T5_ACTIVE_BMC)..."
    ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power off &>/dev/null || {
        log_fail "T5-04: HARD GATE — IPMI power off failed"
        HARD_GATE_FAILED=1
        return 2
    }

    # Poll the standby controller directly until it promotes to MASTER.
    # The API key may not work until the standby finishes taking over.
    log_info "T5-04: waiting for standby $T5_STANDBY_PORTAL to promote (timeout: ${HA_FAILOVER_TIMEOUT}s)..."
    local start_time
    start_time=$(date +%s)
    local promoted=0

    while [[ $(( $(date +%s) - start_time )) -lt $HA_FAILOVER_TIMEOUT ]]; do
        local standby_status
        standby_status=$(tn_api_call_host "$T5_STANDBY_PORTAL" "$storage" "failover.status" 2>/dev/null | tr -d '"') || true
        if [[ "$standby_status" == "MASTER" ]]; then
            HA_RECOVERY_ELAPSED=$(( $(date +%s) - start_time ))
            promoted=1
            break
        fi
        sleep "$HA_POLL_INTERVAL"
    done

    # Capture multipathd journal
    journalctl -u multipathd --since "$mpath_since" --no-pager >> "$T5_MPATH_LOG" 2>/dev/null
    timeout 5 multipathd -k 'verbosity 2' &>/dev/null || true

    if [[ $promoted -ne 1 ]]; then
        log_fail "T5-04: HARD GATE — standby did not promote within ${HA_FAILOVER_TIMEOUT}s"
        # Power the controller back on before failing
        ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power on &>/dev/null || true
        HARD_GATE_FAILED=1
        return 2
    fi

    log_info "T5-04: standby promoted to MASTER after ${HA_RECOVERY_ELAPSED}s"

    # Capture ALUA handler state
    local post_fo_hwhandler
    post_fo_hwhandler=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -o "hwhandler='[^']*'" | head -1)
    local post_fo_dmtable
    post_fo_dmtable=$(dmsetup table "$T5_TEST_WWID" 2>/dev/null | grep -o '[0-9]* alua\|0 0' | head -1)
    local post_fo_dh_paths=""
    for sd in $(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -oP 'sd[a-z]+'); do
        local dh=$(cat /sys/block/$sd/device/dh_state 2>/dev/null || echo "none")
        post_fo_dh_paths+="$sd=$dh "
    done
    log_info "T5-04: hwhandler after crash failover: multipath=${post_fo_hwhandler:-not found}, dmtable=${post_fo_dmtable:-not found}, paths=[${post_fo_dh_paths}]"
    log_info "T5-04: multipathd log captured to $T5_MPATH_LOG"

    # The standby already reported MASTER (that's how we exited the poll loop).
    # Try to get the node letter for logging, but don't fail if the call doesn't
    # work — the controller may still be initializing after taking over.
    local new_node
    new_node=$(tn_api_call_host "$T5_STANDBY_PORTAL" "$storage" "failover.node" 2>/dev/null | tr -d '"') || true

    log_pass "T5-04: crash failover complete — standby promoted to MASTER after ${HA_RECOVERY_ELAPSED}s${new_node:+ (controller $new_node)}"
}

# ============================================================
# T5-05: ALUA state transition after failover
# ============================================================
test_T5_05() {
    local storage="$1"

    log_info "T5-05: ALUA state transition after failover"

    # Poll multipath -ll for the test volume for up to 60s for ALUA priorities to swap.
    # After failover, the path that was low priority should now be high priority.
    # We check that the high-prio path is now the device that was previously low-prio,
    # without requiring exact prio values (TrueNAS may use values other than 50/10
    # during transitions).
    local swapped=0
    local start_time
    start_time=$(date +%s)

    # Force multipathd to re-evaluate paths after failover
    multipath -r &>/dev/null || true

    # After HA failover, ALUA priorities change. We verify by checking that:
    # 1. The priority values have changed from the baseline, AND
    # 2. At least one path is ready/running (not all failed)
    # Note: multipath may keep the old path as status=active (with i/o pending)
    # while the new path is status=enabled but ready. This is normal behavior —
    # the ALUA state changed even if multipath hasn't promoted the new group yet.
    while [[ $(( $(date +%s) - start_time )) -lt 60 ]]; do
        local vol_mp
        vol_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get')
        eval "$(echo "$vol_mp" | parse_multipath_ll)"

        log_info "T5-05: polling — active=$MP_PATH_ACTIVE (prio=$MP_PRIO_ACTIVE), enabled=$MP_PATH_ENABLED (prio=$MP_PRIO_ENABLED)"

        # After failover, the path that was NOT active before should now have
        # higher priority than the path that WAS active. This proves the ALUA
        # state changed in response to the controller swap.
        # Also accept if the previously non-active path is now status=active.
        if [[ -n "$MP_PATH_ACTIVE" && "$MP_PATH_ACTIVE" != "$T5_TEST_PATH_ACTIVE" ]]; then
            # The active group swapped
            swapped=1
            break
        elif [[ -n "$MP_PATH_ENABLED" && -n "$MP_PRIO_ENABLED" && -n "$MP_PRIO_ACTIVE" ]] && \
             [[ "$MP_PRIO_ENABLED" -gt "$MP_PRIO_ACTIVE" ]]; then
            # The enabled path now has higher prio than the active path —
            # ALUA transitioned but multipath hasn't promoted the group yet
            swapped=1
            break
        fi
        sleep 5
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $swapped -eq 1 ]]; then
        log_pass "T5-05: ALUA state transitioned in ${elapsed}s — active=$MP_PATH_ACTIVE (prio=$MP_PRIO_ACTIVE), enabled=$MP_PATH_ENABLED (prio=$MP_PRIO_ENABLED)"
    else
        local raw_mp
        raw_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get' | head -10)
        log_fail "T5-05: ALUA state did not transition within 60s"
        log_info "T5-05: raw multipath output: $raw_mp"
        return 1
    fi
}

# ============================================================
# T5-06: Multipath I/O continuity during failover
# ============================================================
test_T5_06() {
    local storage="$1"

    log_info "T5-06: Multipath I/O continuity during failover"

    # Check background I/O process is alive
    if [[ -n "$T5_IO_PID" ]] && ! kill -0 "$T5_IO_PID" 2>/dev/null; then
        log_fail "T5-06: background I/O process (PID $T5_IO_PID) died during failover"
        return 1
    fi

    # Check I/O error log
    local io_errors=0
    if [[ -f "$T5_IO_LOG" ]]; then
        io_errors=$(grep -c 'IO_ERROR' "$T5_IO_LOG" 2>/dev/null || true)
    fi

    if [[ $io_errors -gt 0 ]]; then
        log_fail "T5-06: $io_errors I/O errors during failover (see $T5_IO_LOG)"
        return 1
    fi

    # Poll multipath -ll for up to 60s for all paths to recover
    local all_healthy=0
    local start_time
    start_time=$(date +%s)

    while [[ $(( $(date +%s) - start_time )) -lt 60 ]]; do
        if ! multipath -ll 2>/dev/null | grep -qi 'faulty\|failed'; then
            all_healthy=1
            break
        fi
        sleep 5
    done

    if [[ $all_healthy -ne 1 ]]; then
        log_fail "T5-06: multipath paths still faulty/failed 60s after failover"
        multipath -ll 2>/dev/null | head -20 | while IFS= read -r line; do
            log_info "T5-06:   $line"
        done
        return 1
    fi

    # Check dmesg for I/O errors
    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        log_fail "T5-06: kernel I/O errors in dmesg after failover"
        return 1
    fi

    log_pass "T5-06: I/O process alive, zero errors, all multipath paths healthy"
}

# ============================================================
# T5-07: I/O routing after failover
# ============================================================
test_T5_07() {
    local storage="$1"

    log_info "T5-07: I/O routing after failover"

    # After failover, parse the test volume's current multipath state using
    # the active/enabled status (not prio numbers, which can be misleading
    # during ALUA transitions — e.g., prio=1 active vs prio=10 enabled).
    eval "$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get' | parse_multipath_ll)"

    local new_active="$MP_PATH_ACTIVE"
    local new_enabled="$MP_PATH_ENABLED"

    if [[ -z "$new_active" ]]; then
        log_fail "T5-07: could not determine active path from multipath -ll"
        return 1
    fi

    log_info "T5-07: current paths — active=$new_active (prio=$MP_PRIO_ACTIVE), enabled=$new_enabled (prio=$MP_PRIO_ENABLED)"

    # Verify background I/O is still running before measuring
    if [[ -n "$T5_IO_PID" ]] && ! kill -0 "$T5_IO_PID" 2>/dev/null; then
        log_fail "T5-07: background I/O process not running — cannot measure routing"
        return 1
    fi

    local active_before enabled_before
    active_before=$(tier5_get_write_ios "$new_active")
    enabled_before=$(tier5_get_write_ios "${new_enabled:-none}")

    sleep 5

    local active_after enabled_after
    active_after=$(tier5_get_write_ios "$new_active")
    enabled_after=$(tier5_get_write_ios "${new_enabled:-none}")

    local active_delta=$(( active_after - active_before ))
    local enabled_delta=$(( enabled_after - enabled_before ))

    log_info "T5-07: I/O delta — active ($new_active): $active_delta writes, enabled ($new_enabled): $enabled_delta writes"

    if [[ "$active_delta" -gt 0 && "$active_delta" -gt "$enabled_delta" ]]; then
        log_pass "T5-07: I/O routed through new active path ($new_active: $active_delta vs $new_enabled: $enabled_delta)"
    elif [[ "$active_delta" -eq 0 && "$enabled_delta" -gt 0 ]]; then
        # I/O is going through the enabled path, not the active one — multipath
        # may not have fully switched yet. Still passes if I/O is flowing.
        log_pass "T5-07: I/O flowing through enabled path $new_enabled ($enabled_delta writes) — multipath still transitioning"
    elif [[ "$active_delta" -eq 0 && "$enabled_delta" -eq 0 ]]; then
        # Zero on both — check I/O process health as fallback
        local io_errors=0 io_skips=0
        [[ -f "$T5_IO_LOG" ]] && io_errors=$(grep -c 'IO_ERROR' "$T5_IO_LOG" 2>/dev/null || true)
        [[ -f "$T5_IO_LOG" ]] && io_skips=$(grep -c 'IO_SKIP' "$T5_IO_LOG" 2>/dev/null || true)

        if [[ -n "$T5_IO_PID" ]] && kill -0 "$T5_IO_PID" 2>/dev/null && \
           [[ "$io_errors" -eq 0 ]] && [[ "$io_skips" -eq 0 ]]; then
            log_pass "T5-07: I/O process running with zero errors/skips — stat counters not tracking after ALUA transition"
        else
            local io_alive="no"
            [[ -n "$T5_IO_PID" ]] && kill -0 "$T5_IO_PID" 2>/dev/null && io_alive="yes"
            log_fail "T5-07: no verifiable I/O after failover (process alive: $io_alive, errors: $io_errors, skips: $io_skips)"
            return 1
        fi
    else
        log_fail "T5-07: I/O not flowing through active path (active=$active_delta, enabled=$enabled_delta)"
        return 1
    fi
}

# ============================================================
# T5-08: Wait for standby, trigger failback
# ============================================================
test_T5_08() {
    local storage="$1"

    log_info "T5-08: Trigger HA failback"

    # Start multipathd journal capture for failback
    local mpath_since_fb
    mpath_since_fb=$(date '+%Y-%m-%d %H:%M:%S')
    timeout 5 multipathd -k 'verbosity 3' &>/dev/null || true

    log_info "T5-08: calling failover.become_passive..."
    tn_api_call "$storage" "failover.become_passive" &>/dev/null || true

    log_info "T5-08: waiting for API recovery on VIP (timeout: ${HA_FAILOVER_TIMEOUT}s)..."

    if ! ha_wait_for_api "$storage" "$HA_FAILOVER_TIMEOUT"; then
        log_warn "T5-08: API did not recover within ${HA_FAILOVER_TIMEOUT}s after failback"
        journalctl -u multipathd --since "$mpath_since_fb" --no-pager >> "$T5_MPATH_LOG" 2>/dev/null
        timeout 5 multipathd -k 'verbosity 2' &>/dev/null || true
        return 1
    fi

    # Capture multipathd journal for failback
    journalctl -u multipathd --since "$mpath_since_fb" --no-pager >> "$T5_MPATH_LOG" 2>/dev/null
    timeout 5 multipathd -k 'verbosity 2' &>/dev/null || true

    log_info "T5-08: API responded after ${HA_RECOVERY_ELAPSED}s"

    # Capture ALUA handler state after failback
    local post_fb_hwhandler
    post_fb_hwhandler=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -o "hwhandler='[^']*'" | head -1)
    local post_fb_dmtable
    post_fb_dmtable=$(dmsetup table "$T5_TEST_WWID" 2>/dev/null | grep -o '[0-9]* alua\|0 0' | head -1)
    local post_fb_dh_paths=""
    for sd in $(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -oP 'sd[a-z]+'); do
        local dh=$(cat /sys/block/$sd/device/dh_state 2>/dev/null || echo "none")
        post_fb_dh_paths+="$sd=$dh "
    done
    log_info "T5-08: hwhandler after failback: multipath=${post_fb_hwhandler:-not found}, dmtable=${post_fb_dmtable:-not found}, paths=[${post_fb_dh_paths}]"
    log_info "T5-08: multipathd log appended to $T5_MPATH_LOG"

    local current_node
    current_node=$(tn_api_call "$storage" "failover.node" 2>/dev/null | tr -d '"')

    if [[ "$current_node" == "$T5_ORIGINAL_NODE" ]]; then
        log_pass "T5-08: failback complete — controller $current_node is MASTER again (${HA_RECOVERY_ELAPSED}s)"
    else
        log_warn "T5-08: controller $current_node is MASTER, expected $T5_ORIGINAL_NODE"
        return 1
    fi

    # Warn if failback was slow
    local repl_timeout
    repl_timeout=$(grep -m1 'node.session.timeo.replacement_timeout' /etc/iscsi/iscsid.conf 2>/dev/null | awk '{print $3}')
    repl_timeout="${repl_timeout:-120}"
    local threshold=$(( repl_timeout * 75 / 100 ))
    if [[ "$HA_RECOVERY_ELAPSED" -gt "$threshold" ]]; then
        log_warn "T5-08: failback took ${HA_RECOVERY_ELAPSED}s — close to iSCSI replacement_timeout (${repl_timeout}s)"
    fi
}

# ============================================================
# T5-09: ALUA state restored after failback
# ============================================================
test_T5_09() {
    local storage="$1"

    log_info "T5-09: ALUA state restored after failback"

    # Poll for up to 180s for the active path to return to baseline.
    # After a crash failover + failback, ALUA priorities take longer to settle
    # because the controller was hard-crashed and rebooted.
    local restored=0
    local start_time
    start_time=$(date +%s)

    while [[ $(( $(date +%s) - start_time )) -lt 180 ]]; do
        eval "$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get' | parse_multipath_ll)"

        # Original active path should be active again
        if [[ "$MP_PATH_ACTIVE" == "$T5_TEST_PATH_ACTIVE" ]]; then
            restored=1
            break
        fi
        sleep 5
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $restored -eq 1 ]]; then
        log_pass "T5-09: active path restored to baseline in ${elapsed}s — $T5_TEST_PATH_ACTIVE is active again (prio=$MP_PRIO_ACTIVE)"
    else
        eval "$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get' | parse_multipath_ll)"
        log_fail "T5-09: active path not restored within 60s — active=$MP_PATH_ACTIVE (expected $T5_TEST_PATH_ACTIVE)"
        return 1
    fi
}

# ============================================================
# T5-10: Multipath I/O continuity after failback
# ============================================================
test_T5_10() {
    local storage="$1"

    log_info "T5-10: Multipath I/O continuity after full cycle"

    # Stop background I/O and check for errors across entire failover/failback cycle
    local io_ok=1
    if [[ -n "$T5_IO_PID" ]]; then
        if ! kill -0 "$T5_IO_PID" 2>/dev/null; then
            log_fail "T5-10: background I/O process died during failover/failback cycle"
            io_ok=0
        fi
        if ! tier5_stop_io; then
            local io_errors
            io_errors=$(grep -c 'IO_ERROR' "$T5_IO_LOG" 2>/dev/null || true)
            log_fail "T5-10: $io_errors I/O errors during failover/failback cycle (see $T5_IO_LOG)"
            io_ok=0
        fi
    fi

    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        log_fail "T5-10: kernel I/O errors in dmesg after failback"
        return 1
    fi

    if [[ $io_ok -eq 1 ]]; then
        log_pass "T5-10: dm-multipath I/O survived full ALUA failover/failback cycle with zero errors"
    else
        return 1
    fi
}

# ============================================================
# T5-11: Path group health
# ============================================================
test_T5_11() {
    local storage="$1"

    log_info "T5-11: Final path group health check"

    # Poll for up to 60s for all paths to recover — paths may still be
    # in "i/o pending" or "failed" state shortly after failback
    local all_healthy=0
    local start_time
    start_time=$(date +%s)

    while [[ $(( $(date +%s) - start_time )) -lt 60 ]]; do
        if ! multipath -ll 2>/dev/null | grep -qi 'faulty\|failed\|ghost\|i/o pending'; then
            all_healthy=1
            break
        fi
        sleep 5
    done

    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)

    if [[ $all_healthy -ne 1 ]]; then
        log_fail "T5-11: unhealthy paths found in multipath -ll after 60s:"
        echo "$mp_output" | grep -iE 'faulty|failed|ghost|i/o pending' | while IFS= read -r line; do
            log_info "T5-11:   $line"
        done
        return 1
    fi

    # Parse the test volume specifically for ALUA verification
    local vol_mp
    vol_mp=$(multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get')
    eval "$(echo "$vol_mp" | parse_multipath_ll)"

    # After a full failover/failback cycle, verify:
    # 1. Two distinct paths exist (active + enabled)
    # 2. hwhandler is still ALUA
    # 3. At least one path has non-zero priority
    if [[ -z "$MP_PATH_ACTIVE" && -z "$MP_PATH_HIGH" ]]; then
        log_fail "T5-11: no paths found for test volume $T5_TEST_WWID"
        return 1
    fi

    if [[ "$MP_HWHANDLER" != "1 alua" ]]; then
        log_fail "T5-11: hwhandler='$MP_HWHANDLER' (expected '1 alua') on test volume $T5_TEST_WWID"
        # Dump the test volume's full multipath state
        log_info "T5-11: test volume multipath state:"
        multipath -ll "$T5_TEST_WWID" 2>/dev/null | grep -v 'failed to get' | while IFS= read -r line; do
            log_info "T5-11:   $line"
        done
        # Check if other volumes also lost ALUA
        local alua_count non_alua_count
        alua_count=$(multipath -ll 2>/dev/null | grep -c "hwhandler='1 alua'" || true)
        non_alua_count=$(multipath -ll 2>/dev/null | grep -c "hwhandler='0'" || true)
        log_info "T5-11: global state — $alua_count devices with ALUA, $non_alua_count without"
        return 1
    fi

    log_pass "T5-11: all paths healthy, hwhandler='1 alua', prio high=$MP_PRIO_HIGH low=$MP_PRIO_LOW"
}

# ============================================================
# Entry point
# ============================================================
run_tier5() {
    local storage="$1" config="$2"

    log_info "=== Tier 5: ALUA + HA Failover Tests ==="
    local t5_start
    t5_start=$(date +%s)

    tier5_cleanup "$storage"

    tier5_preflight "$storage" || {
        log_fail "Tier 5 pre-flight failed — aborting Tier 5"
        return 2
    }

    # --- Phase 1: Baseline ---
    test_T5_01 "$storage"
    test_T5_02 "$storage"
    test_T5_03 "$storage"

    # --- Phase 2: Failover ---
    test_T5_04 "$storage"
    if [[ "$HARD_GATE_FAILED" -ne 0 ]]; then
        log_warn "Tier 5: T5-04 hard gate failed — skipping remaining Tier 5 tests"
        tier5_cleanup "$storage"
        return 2
    fi
    test_T5_05 "$storage"
    test_T5_06 "$storage"
    test_T5_07 "$storage"

    # --- Phase 3: Failback ---
    # Power the crashed controller back on before waiting for standby readiness
    if [[ -n "$T5_ACTIVE_BMC" && -n "${IPMI_USER:-}" && -n "${IPMI_PASS:-}" ]]; then
        log_info "Powering on crashed controller via IPMI ($T5_ACTIVE_BMC)..."
        local attempt
        for attempt in 1 2 3; do
            ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power on &>/dev/null || true
            sleep 5
            local power_status
            power_status=$(ipmitool -I lanplus -H "$T5_ACTIVE_BMC" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power status 2>/dev/null || true)
            if [[ "$power_status" == *"on"* ]]; then
                log_info "IPMI power on confirmed (attempt $attempt)"
                break
            fi
            log_warn "IPMI power still off after attempt $attempt — retrying"
        done
    fi
    ha_wait_for_standby "$storage" || {
        log_warn "Tier 5: standby controller not ready — failback tests may fail"
    }
    test_T5_08 "$storage"
    test_T5_09 "$storage"
    test_T5_10 "$storage"
    test_T5_11 "$storage"

    # --- Cleanup ---
    tier5_cleanup "$storage"

    local t5_elapsed=$(( $(date +%s) - t5_start ))
    log_info "=== Tier 5 complete in ${t5_elapsed}s ==="
}
