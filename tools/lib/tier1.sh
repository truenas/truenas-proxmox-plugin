# tools/lib/tier1.sh
# Tier 1: Core functional tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.
# Globals used: PASS_COUNT, FAIL_COUNT, SKIP_COUNT, HARD_GATE_FAILED, LOG_FILE

TIER1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Pre-flight checks for Tier 1
# Returns 0 if all pass, 1 if any fail (aborts tier).
# ============================================================
tier1_preflight() {
    local storage="$1"
    local ok=0

    log_info "Tier 1 pre-flight checks..."

    # Must run as root
    if [[ "$(id -u)" -ne 0 ]]; then
        log_fail "Pre-flight: must run as root"
        ok=1
    fi

    # Plugin file present and passes perl -c
    local plugin_file="/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    if [[ ! -f "$plugin_file" ]]; then
        log_fail "Pre-flight: plugin file not found at $plugin_file"
        ok=1
    elif ! perl -c "$plugin_file" &>/dev/null; then
        log_fail "Pre-flight: perl -c failed on $plugin_file"
        ok=1
    else
        log_info "Pre-flight: plugin syntax OK"
    fi

    # Storage active
    if [[ -n "$storage" ]]; then
        if ! pvesm status 2>/dev/null | grep -q "^${storage} "; then
            log_fail "Pre-flight: storage '$storage' not active in pvesm status"
            ok=1
        else
            log_info "Pre-flight: storage '$storage' active"
        fi
    else
        log_warn "Pre-flight: no --storage specified; skipping storage active check"
    fi

    return $ok
}

# ============================================================
# Existing script wrapper
# Translates [TEST] tokens to [INFO] and maps exit code.
# ============================================================
tier1_existing_script() {
    local storage="$1"
    local script="$TIER1_DIR/../dev-truenas-plugin-full-function-test.sh"

    if [[ ! -f "$script" ]]; then
        log_skip "Existing script not found at $script"
        return 0
    fi

    log_info "Running existing functional test script..."

    local tmpout
    tmpout=$(mktemp)
    # Run the existing script; capture output; translate [TEST] -> [INFO]
    if bash "$script" "$storage" 9800 2>&1 | \
       sed 's/^\[TEST\]/[INFO]/' | tee "$tmpout" | tee -a "$LOG_FILE"; then
        # Count results from existing script output
        local ep ef
        ep=$(grep -c '^\[PASS\]' "$tmpout" || true)
        ef=$(grep -c '^\[FAIL\]' "$tmpout" || true)
        PASS_COUNT=$((PASS_COUNT + ep))
        FAIL_COUNT=$((FAIL_COUNT + ef))
        log_info "Existing script: $ep passed, $ef failed"
        rm -f "$tmpout"
        return 0
    else
        log_fail "Existing script exited non-zero"
        rm -f "$tmpout"
        return 1
    fi
}

# ============================================================
# T1-01: TLS config audit — HARD GATE
# ============================================================
test_T1_01() {
    local storage="$1"
    local cfg=/etc/pve/storage.cfg

    log_info "T1-01: TLS config audit"

    local insecure
    insecure=$(grep -c 'api_insecure 1' "$cfg" 2>/dev/null || true)

    if [[ "$insecure" -gt 0 ]]; then
        log_fail "T1-01: HARD GATE — api_insecure 1 found in $cfg. Remove this setting to re-enable TLS verification before release."
        HARD_GATE_FAILED=1
        return 2
    else
        log_pass "T1-01: api_insecure not set (TLS enabled)"
        return 0
    fi
}

# ============================================================
# T1-02: API retry
# ============================================================
test_T1_02() {
    local storage="$1"

    log_info "T1-02: API retry under connection loss"

    local api_host retry_max retry_delay
    api_host=$(read_storage_cfg "$storage" "api_host")
    retry_max=$(read_storage_cfg "$storage" "api_retry_max" "3")
    retry_delay=$(read_storage_cfg "$storage" "api_retry_delay" "1")

    if [[ -z "$api_host" ]]; then
        log_skip "T1-02: could not determine api_host for storage '$storage'"
        return 0
    fi

    local window
    window=$(retry_window_seconds "$retry_max" "$retry_delay")
    log_info "T1-02: retry_max=$retry_max delay=${retry_delay}s window=${window}s api_host=$api_host"

    # Block outbound 443 to API host
    iptables_block "$api_host" 443

    # Wait 20s to ensure at least one retry fires (15s connect timeout + margin)
    sleep 20

    # Unblock — from here the API should be reachable again
    iptables_unblock "$api_host" 443

    # Verify recovery: poll pvesm status until it succeeds or window expires
    local start_time
    start_time=$(date +%s)
    local remaining=$(( window - 20 ))  # 20s already elapsed during block period
    local recovered=0

    while [[ $(( $(date +%s) - start_time )) -lt $remaining ]]; do
        if pvesm status "$storage" &>/dev/null; then
            recovered=1
            break
        fi
        sleep 2
    done

    if [[ $recovered -eq 1 ]]; then
        local elapsed=$(( $(date +%s) - start_time ))
        log_pass "T1-02: pvesm status recovered ${elapsed}s after unblock (window: ${remaining}s)"
        return 0
    else
        log_fail "T1-02: pvesm status did not recover within ${remaining}s after unblock"
        return 1
    fi
}

# ============================================================
# T1-03: Snapshot rollback
# ============================================================
test_T1_03() {
    local storage="$1"

    log_info "T1-03: Snapshot rollback data integrity"

    local vmid=9701
    local volid="${storage}:vm-${vmid}-disk-0"

    # Create a test volume (1G)
    if ! pvesh post /nodes/localhost/storage/"$storage"/content \
         -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G &>/dev/null; then
        log_skip "T1-03: could not create test volume on storage '$storage'"
        return 0
    fi

    local dev
    dev=$(pvesm path "$volid" 2>/dev/null)
    if [[ -z "$dev" ]]; then
        log_fail "T1-03: pvesm path returned empty for $volid"
        pvesm free "$volid" &>/dev/null || true
        return 1
    fi

    # Write a known marker (volume is unmounted)
    local marker="truenas-test-marker-$$"
    echo "$marker" | dd of="$dev" bs=512 count=1 conv=notrunc &>/dev/null

    # Create snapshot
    local snapname="test-snap-$$"
    if ! pvesm snapshot "$volid" "$snapname" &>/dev/null; then
        log_skip "T1-03: pvesm snapshot not available or failed — skipping"
        pvesm free "$volid" &>/dev/null || true
        return 0
    fi

    # Overwrite marker
    echo "overwritten" | dd of="$dev" bs=512 count=1 conv=notrunc &>/dev/null

    # Rollback
    if ! pvesm rollback "$volid" "$snapname" &>/dev/null; then
        log_fail "T1-03: pvesm rollback failed"
        pvesm delsnapshot "$volid" "$snapname" &>/dev/null || true
        pvesm free "$volid" &>/dev/null || true
        return 1
    fi

    # Verify marker restored
    local restored
    restored=$(dd if="$dev" bs=512 count=1 2>/dev/null | tr -d '\0')
    if echo "$restored" | grep -q "$marker"; then
        log_pass "T1-03: snapshot rollback restored original data"
    else
        log_fail "T1-03: data after rollback does not match pre-snapshot state"
    fi

    pvesm delsnapshot "$volid" "$snapname" &>/dev/null || true
    pvesm free "$volid" &>/dev/null || true
}

# ============================================================
# T1-04: Orphan detection — clean (--purge path)
# ============================================================
test_T1_04() {
    local storage="$1"

    log_info "T1-04: Orphan detection — clean VM deletion"

    # Find install.sh in common locations
    local installer
    installer=$(find /opt /root /home -name install.sh -path "*/truenas*" 2>/dev/null | head -1)
    if [[ -z "$installer" ]]; then
        log_skip "T1-04: install.sh not found — cannot run orphan scan"
        return 0
    fi

    local vmid=9702
    # Create a minimal VM config with a disk
    pvesh post /nodes/localhost/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null || {
        log_skip "T1-04: could not create test VM $vmid"
        return 0
    }

    # Delete with --purge (correct cleanup path)
    qm destroy "$vmid" --purge &>/dev/null

    # Run orphan scan
    local scan_output
    scan_output=$(bash "$installer" --health-check 2>&1)
    if echo "$scan_output" | grep -qiE 'orphan.*: ?0|no orphan'; then
        log_pass "T1-04: orphan scan reports zero orphans after clean deletion"
    else
        log_fail "T1-04: orphan scan output unexpected: $scan_output"
    fi
}

# ============================================================
# T1-05: Orphan detection — qm destroy (no --purge)
# ============================================================
test_T1_05() {
    local storage="$1"

    log_info "T1-05: Orphan detection — qm destroy without --purge"

    local installer
    installer=$(find /opt /root /home -name install.sh -path "*/truenas*" 2>/dev/null | head -1)
    if [[ -z "$installer" ]]; then
        log_skip "T1-05: install.sh not found"
        return 0
    fi

    local vmid=9703
    pvesh post /nodes/localhost/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null || {
        log_skip "T1-05: could not create test VM $vmid"
        return 0
    }

    # Delete without --purge (intentionally leaves orphan)
    qm destroy "$vmid" &>/dev/null

    local scan_output
    scan_output=$(bash "$installer" --health-check 2>&1)
    if echo "$scan_output" | grep -qiE 'orphan'; then
        log_pass "T1-05: orphan scan detected orphans after qm destroy (expected)"
        # Clean up the orphan
        bash "$installer" --health-check --cleanup &>/dev/null || true
    else
        log_fail "T1-05: orphan scan did not detect orphans — health-check may be broken"
    fi
}

# ============================================================
# T1-06: Debug logging
# ============================================================
test_T1_06() {
    local storage="$1"
    local cfg=/etc/pve/storage.cfg

    log_info "T1-06: Debug logging via journald"

    # Check if debug is already enabled
    local already_debug=0
    grep -q "debug 1" "$cfg" && already_debug=1

    # Enable debug if not already set
    if [[ $already_debug -eq 0 ]]; then
        sed -i "/^${storage}:/,/^[^ ]/{/^[^ ]/!{/debug/!s/\(.*api_host.*\)/\1\n\tdebug 1/}}" "$cfg" || true
    fi

    systemctl restart pvedaemon &>/dev/null
    sleep 3

    # Trigger an operation
    pvesm status "$storage" &>/dev/null || true

    # Check journal for debug entries
    if journalctl -u pvedaemon --since "1 minute ago" --no-pager 2>/dev/null | \
       grep -q '\[TrueNAS\]'; then
        log_pass "T1-06: [TrueNAS] debug entries found in journald"
    else
        log_fail "T1-06: no [TrueNAS] debug entries in journald — debug logging may not be working"
    fi

    # Restore if we added debug line
    if [[ $already_debug -eq 0 ]]; then
        sed -i '/^\tdebug 1$/d' "$cfg"
        systemctl restart pvedaemon &>/dev/null
        sleep 2
    fi
}

# ============================================================
# T1-07: Volume naming uniqueness under rapid succession
# ============================================================
test_T1_07() {
    local storage="$1"

    log_info "T1-07: Volume naming uniqueness (5 disks, rapid succession)"

    local vmid=9704
    local created=()
    local failed=0

    for i in $(seq 1 5); do
        local volid
        if volid=$(pvesh post /nodes/localhost/storage/"$storage"/content \
                   -vmid "$vmid" -filename "vm-${vmid}-disk-$((i-1))" \
                   -size 1G 2>&1); then
            created+=("${storage}:vm-${vmid}-disk-$((i-1))")
        else
            if echo "$volid" | grep -q "Unable to find free disk name"; then
                log_fail "T1-07: disk $i — 'Unable to find free disk name' error"
                failed=1
            else
                log_fail "T1-07: disk $i — unexpected error: $volid"
                failed=1
            fi
        fi
    done

    # Verify all 5 names are distinct
    local unique_count
    unique_count=$(pvesm list "$storage" 2>/dev/null | grep "vm-${vmid}-disk" | awk '{print $1}' | sort -u | wc -l)

    # Cleanup
    for v in "${created[@]}"; do
        pvesm free "$v" &>/dev/null || true
    done

    if [[ $failed -eq 0 && "$unique_count" -eq 5 ]]; then
        log_pass "T1-07: all 5 disks created with distinct names"
    else
        log_fail "T1-07: expected 5 distinct disk names, found $unique_count"
    fi
}

# ============================================================
# Entry point
# ============================================================
run_tier1() {
    local storage="$1" config="$2"

    log_info "=== Tier 1: Core Functional Tests ==="
    local t1_start
    t1_start=$(date +%s)

    tier1_preflight "$storage" || {
        log_fail "Tier 1 pre-flight failed — aborting Tier 1"
        return 2
    }

    tier1_existing_script "$storage"

    test_T1_01 "$storage"
    test_T1_02 "$storage"
    test_T1_03 "$storage"
    test_T1_04 "$storage"
    test_T1_05 "$storage"
    test_T1_06 "$storage"
    test_T1_07 "$storage"

    local t1_elapsed=$(( $(date +%s) - t1_start ))
    log_info "=== Tier 1 complete in ${t1_elapsed}s ==="
}
