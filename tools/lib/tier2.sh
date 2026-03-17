# tools/lib/tier2.sh
# Tier 2: Multipath and ALUA tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.

# ============================================================
# Pre-flight checks for Tier 2
# Aborts Tier 2 only on failure; remaining tiers continue.
# ============================================================
tier2_preflight() {
    local storage="$1"
    local ok=0

    log_info "Tier 2 pre-flight checks..."

    if ! dpkg -l multipath-tools &>/dev/null; then
        log_warn "Tier 2 pre-flight: multipath-tools not installed — skipping Tier 2"
        return 1
    fi

    if ! systemctl is-active multipathd &>/dev/null; then
        log_warn "Tier 2 pre-flight: multipathd not active — skipping Tier 2"
        return 1
    fi

    if ! grep -q 'use_multipath 1' /etc/pve/storage.cfg 2>/dev/null; then
        log_warn "Tier 2 pre-flight: use_multipath 1 not set in storage.cfg — skipping Tier 2"
        return 1
    fi

    if ! grep -q 'portals' /etc/pve/storage.cfg 2>/dev/null; then
        log_warn "Tier 2 pre-flight: no 'portals' key in storage.cfg — skipping Tier 2"
        return 1
    fi

    # Both portals reachable
    local portals
    portals=$(read_storage_cfg "$storage" "portals")
    for portal_ip in $(echo "$portals" | tr ',' ' '); do
        if ! nc -zv "$portal_ip" 3260 &>/dev/null; then
            log_warn "Tier 2 pre-flight: portal $portal_ip:3260 unreachable — skipping Tier 2"
            return 1
        fi
    done

    log_info "Tier 2 pre-flight: OK"
    return 0
}

# ============================================================
# T2-01: dm-multipath map creation
# ============================================================
test_T2_01() {
    local storage="$1"

    log_info "T2-01: dm-multipath map creation"

    local vmid=9710
    pvesh create /nodes/localhost/storage/"$storage"/content \
        -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G &>/dev/null || {
        log_skip "T2-01: could not create volume"
        return 0
    }

    sleep 3  # Allow multipathd to discover new LUN

    if multipath -ll 2>/dev/null | grep -q '/dev/mapper/mpath'; then
        log_pass "T2-01: LUN appears as /dev/mapper/mpathX with paths listed"
    else
        log_fail "T2-01: LUN not found in multipath -ll output"
        pvesm free "${storage}:vm-${vmid}-disk-0" &>/dev/null || true
        return 1
    fi

    # Leave volume for T2-02
    T2_TEST_VOLID="${storage}:vm-${vmid}-disk-0"
    T2_TEST_VMID="$vmid"
}

# ============================================================
# T2-02: Plugin returns mapper device path
# ============================================================
test_T2_02() {
    local storage="$1"
    local volid="${T2_TEST_VOLID:-}"

    log_info "T2-02: pvesm path returns /dev/mapper device"

    if [[ -z "$volid" ]]; then
        log_skip "T2-02: no volume from T2-01 — skipping"
        return 0
    fi

    local dev
    dev=$(pvesm path "$volid" 2>/dev/null)

    if [[ "$dev" =~ ^/dev/mapper/mpath[0-9]+ ]]; then
        log_pass "T2-02: pvesm path returned mapper device: $dev"
    else
        log_fail "T2-02: expected /dev/mapper/mpathX, got '$dev'"
        return 1
    fi
}

# ============================================================
# T2-03: ALUA hardware handler active — HARD GATE
# ============================================================
test_T2_03() {
    local storage="$1"

    log_info "T2-03: ALUA hardware handler (hard gate)"

    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)

    if echo "$mp_output" | grep -q "hwhandler='1 alua'"; then
        log_pass "T2-03: hwhandler='1 alua' present in multipath -ll"
    else
        log_fail "T2-03: HARD GATE — hwhandler='1 alua' not found. Add the TrueNAS device block to /etc/multipath.conf (see wiki/Testing-Requirements.md Section 3.2)."
        HARD_GATE_FAILED=1
        return 2
    fi
}

# ============================================================
# T2-04: Optimized path carries I/O (manual-only)
# ============================================================
test_T2_04() {
    local storage="$1"

    log_info "T2-04: ALUA optimized path I/O distribution (MANUAL)"
    log_warn "T2-04: This test requires manual operator verification."
    log_warn "T2-04: Run: fio on /dev/mapper/mpathX + capture 'iostat -x 1 5' per path device."
    log_warn "T2-04: Pass criterion: Active Optimized path >=90% of write ops; Active Non-Optimized <=10%."
    log_warn "T2-04: Record raw iostat output in the test log before marking pass/fail."
    log_skip "T2-04: automated execution not possible — manual verification required"
}

# ============================================================
# T2-05: Path failure — I/O continues with one path down
# ============================================================
test_T2_05() {
    local storage="$1"
    local portal1_ip
    portal1_ip=$(read_storage_cfg "$storage" "portals" | cut -d',' -f1)

    log_info "T2-05: Path failure — I/O continues"

    if [[ -z "$portal1_ip" ]]; then
        log_skip "T2-05: could not determine primary portal IP"
        return 0
    fi

    local vmid="${T2_TEST_VMID:-9711}"
    # Start a VM if not already running
    if ! qm status "$vmid" 2>/dev/null | grep -q running; then
        qm start "$vmid" &>/dev/null || {
            log_skip "T2-05: could not start VM $vmid"
            return 0
        }
        sleep 5
    fi

    # Block primary portal
    iptables_block "$portal1_ip" 3260
    sleep 30

    local vm_status
    vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')

    if [[ "$vm_status" == "running" ]]; then
        log_pass "T2-05: VM remains running after primary portal blocked for 30s"
    else
        log_fail "T2-05: VM not running (status: $vm_status) — failover did not work"
        iptables_unblock "$portal1_ip" 3260
        return 1
    fi

    if dmesg | tail -50 | grep -qi 'disk.*error\|blk_update_request.*I/O error'; then
        log_fail "T2-05: I/O errors found in dmesg during path failure"
        iptables_unblock "$portal1_ip" 3260
        return 1
    fi

    # Leave portal blocked for T2-06
    T2_BLOCKED_PORTAL="$portal1_ip"
}

# ============================================================
# T2-06: Failback to optimized path after portal restored
# ============================================================
test_T2_06() {
    local storage="$1"
    local portal_ip="${T2_BLOCKED_PORTAL:-}"

    log_info "T2-06: Failback to optimized path"

    if [[ -z "$portal_ip" ]]; then
        log_skip "T2-06: no blocked portal from T2-05"
        return 0
    fi

    iptables_unblock "$portal_ip" 3260

    local recovered=0
    for i in $(seq 1 12); do
        sleep 5
        if multipath -ll 2>/dev/null | grep -A5 "prio=50" | grep -q "active ready"; then
            recovered=1
            break
        fi
    done

    if [[ $recovered -eq 1 ]]; then
        log_pass "T2-06: Active Optimized path restored within 60s of portal unblock"
    else
        log_fail "T2-06: Active Optimized path not restored within 60s"
        return 1
    fi
}

# ============================================================
# T2-07: Stale map cleanup after volume deletion
# ============================================================
test_T2_07() {
    local storage="$1"
    local volid="${T2_TEST_VOLID:-}"

    log_info "T2-07: Stale multipath map cleanup"

    if [[ -z "$volid" ]]; then
        log_skip "T2-07: no test volume available"
        return 0
    fi

    # Get WWID before deletion
    local dev
    dev=$(pvesm path "$volid" 2>/dev/null)
    local wwid=""
    if [[ "$dev" =~ /dev/mapper/(mpath[0-9a-z]+) ]]; then
        wwid="${BASH_REMATCH[1]}"
    fi

    pvesm free "$volid" &>/dev/null
    sleep 5

    if [[ -n "$wwid" ]] && multipath -ll 2>/dev/null | grep -q "$wwid"; then
        log_fail "T2-07: multipath map for $wwid still present after volume deletion"
        return 1
    else
        log_pass "T2-07: multipath map removed after volume deletion"
    fi

    T2_TEST_VOLID=""
}

# ============================================================
# T2-08: Silent fallback detection
# ============================================================
test_T2_08() {
    local storage="$1"

    log_info "T2-08: Silent fallback detection when dm map removed"

    local vmid=9712
    pvesh create /nodes/localhost/storage/"$storage"/content \
        -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G &>/dev/null || {
        log_skip "T2-08: could not create volume"
        return 0
    }

    local volid="${storage}:vm-${vmid}-disk-0"
    local dev
    dev=$(pvesm path "$volid" 2>/dev/null)

    local wwid=""
    if [[ "$dev" =~ /dev/mapper/(mpath[^[:space:]]+) ]]; then
        wwid="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$wwid" ]]; then
        log_skip "T2-08: volume has no dm map — skipping"
        pvesm free "$volid" &>/dev/null || true
        return 0
    fi

    # Remove the map and WWID entry
    multipath -f "$wwid" &>/dev/null || true
    sed -i "/$wwid/d" /etc/multipath/wwids 2>/dev/null || true
    multipath -r &>/dev/null || true

    local fallback_dev
    fallback_dev=$(pvesm path "$volid" 2>/dev/null)

    local warned=0
    if journalctl -u pvedaemon --since "30 seconds ago" --no-pager 2>/dev/null | \
       grep -qi 'multipath.*not found\|multipath map\|warning'; then
        warned=1
    fi

    if [[ "$fallback_dev" =~ ^/dev/mapper/ ]]; then
        log_fail "T2-08: pvesm path still returning mapper device after map removal"
    elif [[ $warned -eq 1 ]]; then
        log_pass "T2-08: pvesm path fell back to by-path device and pvedaemon logged warning"
    else
        log_fail "T2-08: pvesm path fell back silently — no warning logged in pvedaemon journal"
    fi

    pvesm free "$volid" &>/dev/null || true
}

# ============================================================
# T2-09: replacement_timeout value check
# ============================================================
test_T2_09() {
    local storage="$1"
    local iscsid_conf=/etc/iscsi/iscsid.conf

    log_info "T2-09: iSCSI replacement_timeout value"

    if [[ ! -f "$iscsid_conf" ]]; then
        log_skip "T2-09: $iscsid_conf not found"
        return 0
    fi

    local timeout
    timeout=$(grep 'node.session.timeo.replacement_timeout' "$iscsid_conf" \
              | awk '{print $3}' | head -1)

    if [[ -z "$timeout" ]]; then
        log_warn "T2-09: replacement_timeout not set in $iscsid_conf (using kernel default, which may be >15s)"
        return 0
    fi

    if [[ "$timeout" -le 15 ]]; then
        log_pass "T2-09: replacement_timeout=${timeout} (<=15s)"
    else
        log_fail "T2-09: replacement_timeout=${timeout} exceeds 15s. Set node.session.timeo.replacement_timeout = 15 in $iscsid_conf"
        return 1
    fi
}

# ============================================================
# Entry point
# ============================================================
run_tier2() {
    local storage="$1" config="$2"

    # Tier 2 not required for Config F (NVMe/TCP)
    if [[ "$config" == "F" ]]; then
        log_skip "Tier 2 — not required for Config F (NVMe/TCP uses kernel-native multipath)"
        return 0
    fi

    log_info "=== Tier 2: Multipath and ALUA Tests ==="
    local t2_start
    t2_start=$(date +%s)

    tier2_preflight "$storage" || {
        log_warn "Tier 2 pre-flight failed — skipping Tier 2 (does not affect overall exit code)"
        return 0
    }

    test_T2_01 "$storage"
    test_T2_02 "$storage"
    test_T2_03 "$storage"
    test_T2_04 "$storage"
    test_T2_05 "$storage"
    test_T2_06 "$storage"
    test_T2_07 "$storage"
    test_T2_08 "$storage"
    test_T2_09 "$storage"

    local t2_elapsed=$(( $(date +%s) - t2_start ))
    log_info "=== Tier 2 complete in ${t2_elapsed}s ==="
}
