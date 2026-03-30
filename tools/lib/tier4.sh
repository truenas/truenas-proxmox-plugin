# tools/lib/tier4.sh
# Tier 4: TrueNAS Enterprise HA failover/failback tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.
# Globals used: PASS_COUNT, FAIL_COUNT, SKIP_COUNT, HARD_GATE_FAILED, LOG_FILE

# Tier 4 shared state
T4_ORIGINAL_NODE=""         # Controller letter (A or B) at test start
T4_TEST_VMID=9740
T4_TEST_VOLID=""
T4_MARKER_VOLID=""          # Separate volume for data integrity marker (not attached to VM)
T4_VM_CREATED=0
T4_FAILOVER_TIMEOUT=180     # seconds
T4_POLL_INTERVAL=5          # seconds
T4_MARKER=""
T4_RECOVERY_ELAPSED=0
T4_IO_PID=""                # PID of background I/O workload
T4_IO_LOG=""                # Log file for I/O workload output
T4_STANDBY_TIMEOUT=300      # seconds to wait for standby to come back
T4_FAILBACK_TIMESTAMP=""    # dmesg reference timestamp for failback diagnostics

# ============================================================
# Pre-flight checks for Tier 4
# Returns 0 if all pass, 1 if any fail (aborts tier).
# ============================================================
tier4_preflight() {
    local storage="$1"
    local ok=0

    log_info "Tier 4 pre-flight checks..."

    # VIP reachable via API
    local licensed
    licensed=$(tn_api_call "$storage" "failover.licensed" 2>/dev/null) || {
        log_fail "Tier 4 pre-flight: cannot reach TrueNAS API via VIP"
        return 1
    }

    if [[ "$licensed" != "true" ]]; then
        log_fail "Tier 4 pre-flight: failover.licensed returned '$licensed' (expected 'true')"
        return 1
    fi
    log_info "Tier 4 pre-flight: HA license confirmed"

    # Both controllers healthy — failover.status returns MASTER or BACKUP
    local status
    status=$(tn_api_call "$storage" "failover.status" 2>/dev/null) || {
        log_fail "Tier 4 pre-flight: failover.status call failed"
        return 1
    }

    # Status is a JSON string like "MASTER" — strip quotes
    status=$(echo "$status" | tr -d '"')
    if [[ "$status" != "MASTER" && "$status" != "BACKUP" ]]; then
        log_fail "Tier 4 pre-flight: failover.status returned '$status' (expected MASTER or BACKUP)"
        return 1
    fi
    log_info "Tier 4 pre-flight: controller status is $status"

    # Verify API key can call failover.become_passive (dry check via failover.config)
    local config
    config=$(tn_api_call "$storage" "failover.config" 2>/dev/null) || {
        log_fail "Tier 4 pre-flight: failover.config call failed — API key may lack failover permissions"
        return 1
    }
    log_info "Tier 4 pre-flight: failover API accessible"

    return $ok
}

# ============================================================
# Cleanup — always runs at end of run_tier4
# ============================================================
tier4_cleanup() {
    local storage="$1"

    log_info "Tier 4 cleanup..."

    # Remove any stale regular files in by-path created by dd when the
    # iSCSI symlink disappeared during a failover
    for f in /dev/disk/by-path/*truenas*; do
        [[ -f "$f" ]] && rm -f "$f" && log_warn "Tier 4 cleanup: removed stale file $f"
    done

    # Stop background I/O if still running
    if [[ -n "$T4_IO_PID" ]] && kill -0 "$T4_IO_PID" 2>/dev/null; then
        kill "$T4_IO_PID" 2>/dev/null
        wait "$T4_IO_PID" 2>/dev/null || true
        T4_IO_PID=""
    fi

    # Destroy test VMs — always try, regardless of T4_VM_CREATED flag,
    # in case a previous run left stale VMs behind.
    # Try --purge first (cleans up volumes), fall back to plain destroy
    # (just removes config) if the volume is already gone.
    for vmid in $(seq 9740 9749); do
        if qm status "$vmid" &>/dev/null; then
            qm stop "$vmid" --timeout 10 &>/dev/null || true
            if ! qm destroy "$vmid" --purge &>/dev/null; then
                log_warn "Tier 4 cleanup: qm destroy $vmid --purge failed, retrying without --purge"
                qm destroy "$vmid" &>/dev/null || \
                    log_warn "Tier 4 cleanup: qm destroy $vmid failed — manual cleanup needed"
            fi
        fi
    done
    T4_VM_CREATED=0

    # Sweep any leftover volumes in the 9740-9749 range
    for vmid in $(seq 9740 9749); do
        pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${vmid}-disk" | \
            while read -r v; do pvesm free "$v" &>/dev/null || true; done
    done

    log_info "Tier 4 cleanup complete"
}

# ============================================================
# Helper: poll VIP until API responds or timeout
# Returns 0 on recovery, 1 on timeout. Sets T4_RECOVERY_ELAPSED.
# ============================================================
tier4_wait_for_api() {
    local storage="$1"
    local timeout="${2:-$T4_FAILOVER_TIMEOUT}"
    local start_time
    start_time=$(date +%s)
    T4_RECOVERY_ELAPSED=0

    while [[ $(( $(date +%s) - start_time )) -lt $timeout ]]; do
        if tn_api_call "$storage" "failover.status" &>/dev/null; then
            T4_RECOVERY_ELAPSED=$(( $(date +%s) - start_time ))
            return 0
        fi
        sleep "$T4_POLL_INTERVAL"
    done

    T4_RECOVERY_ELAPSED=$timeout
    return 1
}

# ============================================================
# Helper: start continuous I/O on a block device in the background.
# Writes sequential 4K blocks with a counter, logs errors.
# Usage: tier4_start_io <device>
# Sets T4_IO_PID and T4_IO_LOG.
# ============================================================
tier4_start_io() {
    local dev="$1"
    T4_IO_LOG=$(mktemp /tmp/t4-io-XXXXXX.log)

    # Background loop: write 4K blocks with a sequence number.
    # Each block has "SEQ=<n>" so we can verify ordering later.
    # Writes to offset 4096+ to avoid clobbering the marker at 500MB.
    # Uses oflag=direct to ensure writes go to the block device and dd
    # won't silently create a regular file if the by-path symlink
    # disappears during a failover.
    (
        local seq=0
        local offset=1  # start at block 1 (4096 bytes in)
        while true; do
            # Skip writes if the device isn't a block device (session dropped)
            if [[ ! -b "$dev" ]]; then
                echo "IO_SKIP: seq=$seq device_missing time=$(date '+%H:%M:%S')" >> "$T4_IO_LOG"
                sleep 1
                continue
            fi
            printf "SEQ=%08d\n" "$seq" | dd of="$dev" bs=4096 count=1 seek="$offset" conv=notrunc oflag=direct 2>/dev/null
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "IO_ERROR: seq=$seq offset=$offset rc=$rc time=$(date '+%H:%M:%S')" >> "$T4_IO_LOG"
            fi
            seq=$((seq + 1))
            offset=$(( (offset % 200) + 1 ))  # cycle through blocks 1-200 (~800K window)
            sleep 0.1  # ~10 writes/sec
        done
    ) &
    T4_IO_PID=$!
    log_info "Background I/O started on $dev (PID $T4_IO_PID, log $T4_IO_LOG)"
}

# ============================================================
# Helper: stop background I/O and report results.
# Returns 0 if no I/O errors, 1 if errors found.
# ============================================================
tier4_stop_io() {
    if [[ -n "$T4_IO_PID" ]] && kill -0 "$T4_IO_PID" 2>/dev/null; then
        kill "$T4_IO_PID" 2>/dev/null
        wait "$T4_IO_PID" 2>/dev/null || true
    fi

    local errors=0
    if [[ -f "$T4_IO_LOG" ]]; then
        errors=$(grep -c 'IO_ERROR' "$T4_IO_LOG" 2>/dev/null || true)
        if [[ "$errors" -gt 0 ]]; then
            log_warn "Background I/O recorded $errors errors (see $T4_IO_LOG)"
        fi
    fi

    T4_IO_PID=""
    return "$( [[ "$errors" -eq 0 ]] && echo 0 || echo 1 )"
}

# ============================================================
# Helper: wait for standby controller to become reachable.
# Polls failover.call_remote core.ping until it succeeds.
# Returns 0 on success, 1 on timeout.
# ============================================================
tier4_wait_for_standby() {
    local storage="$1"
    local timeout="${2:-$T4_STANDBY_TIMEOUT}"
    local start_time
    start_time=$(date +%s)

    log_info "Waiting for standby controller to become ready (timeout: ${timeout}s)..."

    while [[ $(( $(date +%s) - start_time )) -lt $timeout ]]; do
        # failover.call_remote pings the other controller
        local result
        result=$(tn_api_call "$storage" "failover.call_remote" '["core.ping"]' 2>/dev/null || true)
        if [[ "$result" == *"pong"* ]]; then
            local elapsed=$(( $(date +%s) - start_time ))
            log_info "Standby controller ready in ${elapsed}s"
            return 0
        fi
        sleep "$T4_POLL_INTERVAL"
    done

    log_warn "Standby controller not ready within ${timeout}s"
    return 1
}

# ============================================================
# T4-01: HA status baseline
# ============================================================
test_T4_01() {
    local storage="$1"

    log_info "T4-01: HA status baseline"

    local licensed
    licensed=$(tn_api_call "$storage" "failover.licensed" 2>/dev/null) || {
        log_fail "T4-01: failover.licensed call failed"
        return 1
    }

    if [[ "$licensed" != "true" ]]; then
        log_fail "T4-01: failover.licensed=$licensed (expected true)"
        return 1
    fi

    local status
    status=$(tn_api_call "$storage" "failover.status" 2>/dev/null) || {
        log_fail "T4-01: failover.status call failed"
        return 1
    }
    status=$(echo "$status" | tr -d '"')

    if [[ "$status" != "MASTER" ]]; then
        log_fail "T4-01: connected controller is $status (expected MASTER — VIP should point to active controller)"
        return 1
    fi

    # Record which physical controller (A or B) is currently active
    local node
    node=$(tn_api_call "$storage" "failover.node" 2>/dev/null) || {
        log_fail "T4-01: failover.node call failed"
        return 1
    }
    node=$(echo "$node" | tr -d '"')
    T4_ORIGINAL_NODE="$node"

    log_pass "T4-01: HA baseline — controller $node is MASTER, failover licensed"
}

# ============================================================
# T4-02: Create test volume and start VM
# ============================================================
test_T4_02() {
    local storage="$1"

    log_info "T4-02: Create test volume and start VM"

    local vmid=$T4_TEST_VMID

    # Create VM with a disk on the HA storage.
    local create_out
    create_out=$(pvesh create /nodes/"$(hostname)"/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:1,format=raw" 2>&1) || {
        log_fail "T4-02: could not create test VM $vmid: $create_out"
        return 1
    }
    T4_VM_CREATED=1

    # Capture the volume ID
    T4_TEST_VOLID=$(pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${vmid}-disk" | head -1)
    if [[ -z "$T4_TEST_VOLID" ]]; then
        log_fail "T4-02: volume created but not found in pvesm list"
        return 1
    fi

    # Start the VM
    local start_out
    start_out=$(qm start "$vmid" 2>&1) || {
        log_fail "T4-02: could not start VM $vmid: $start_out"
        return 1
    }
    sleep 5

    local vm_status
    vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$vm_status" != "running" ]]; then
        log_fail "T4-02: VM $vmid status is '$vm_status' (expected running)"
        return 1
    fi

    log_pass "T4-02: VM $vmid running with volume $T4_TEST_VOLID on $storage"
}

# ============================================================
# T4-03: Pre-failover I/O marker
# ============================================================
test_T4_03() {
    local storage="$1"

    log_info "T4-03: Pre-failover I/O marker"

    # Create a separate small volume for the marker — not attached to any VM,
    # so nothing can overwrite it except this test.
    local marker_vmid=9742
    pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${marker_vmid}-disk" | \
        while read -r v; do pvesm free "$v" &>/dev/null || true; done

    local marker_vol
    marker_vol=$(pvesh create /nodes/"$(hostname)"/storage/"$storage"/content \
        -vmid "$marker_vmid" -filename "vm-${marker_vmid}-disk-0" -size 1M 2>/dev/null) || {
        log_fail "T4-03: could not create marker volume"
        return 1
    }
    [[ "$marker_vol" != *:* ]] && marker_vol="${storage}:${marker_vol}"
    T4_MARKER_VOLID="$marker_vol"

    local marker_dev
    marker_dev=$(pvesm path "$T4_MARKER_VOLID" 2>/dev/null)
    if [[ -z "$marker_dev" || ! -b "$marker_dev" ]]; then
        log_fail "T4-03: marker volume device not found or not a block device ($marker_dev)"
        return 1
    fi

    # Write marker to the dedicated volume and force to stable storage
    T4_MARKER="truenas-ha-test-marker-$$"
    echo "$T4_MARKER" | dd of="$marker_dev" bs=512 count=1 conv=notrunc oflag=direct &>/dev/null || {
        log_fail "T4-03: failed to write marker to $marker_dev"
        return 1
    }
    # Ensure data reaches stable storage on TrueNAS before failover
    sync
    blockdev --flushbufs "$marker_dev" 2>/dev/null || true
    sleep 1

    # Verify readback (drop caches to confirm it's on disk, not in memory)
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local readback
    readback=$(dd if="$marker_dev" bs=512 count=1 iflag=direct 2>/dev/null | tr -d '\0')
    if ! echo "$readback" | grep -q "$T4_MARKER"; then
        log_fail "T4-03: marker readback failed (wrote '$T4_MARKER', got '$readback')"
        return 1
    fi

    # Start background I/O on the VM's volume (not the marker volume)
    if [[ -n "$T4_TEST_VOLID" ]]; then
        local io_dev
        io_dev=$(pvesm path "$T4_TEST_VOLID" 2>/dev/null)
        if [[ -n "$io_dev" && -b "$io_dev" ]]; then
            tier4_start_io "$io_dev"
        fi
    fi

    log_pass "T4-03: marker on dedicated volume, background I/O started"
}

# ============================================================
# T4-04: Trigger failover — HARD GATE
# ============================================================
test_T4_04() {
    local storage="$1"

    log_info "T4-04: Trigger HA failover"

    # Trigger the active controller to become passive
    log_info "T4-04: calling failover.become_passive..."
    tn_api_call "$storage" "failover.become_passive" &>/dev/null || true
    # The API call may fail/hang as the controller goes down — that's expected

    # Poll VIP until the API responds on the new active controller
    log_info "T4-04: waiting for API recovery on VIP (timeout: ${T4_FAILOVER_TIMEOUT}s)..."

    if ! tier4_wait_for_api "$storage" "$T4_FAILOVER_TIMEOUT"; then
        log_fail "T4-04: HARD GATE — API did not recover within ${T4_FAILOVER_TIMEOUT}s after failover"
        HARD_GATE_FAILED=1
        return 2
    fi

    log_info "T4-04: API responded after ${T4_RECOVERY_ELAPSED}s"

    # Confirm the controller has actually changed by checking failover.node
    local new_node
    new_node=$(tn_api_call "$storage" "failover.node" 2>/dev/null) || {
        log_fail "T4-04: HARD GATE — failover.node call failed after recovery"
        HARD_GATE_FAILED=1
        return 2
    }
    new_node=$(echo "$new_node" | tr -d '"')

    if [[ "$new_node" != "$T4_ORIGINAL_NODE" ]]; then
        log_pass "T4-04: failover complete — was controller $T4_ORIGINAL_NODE, now $new_node (${T4_RECOVERY_ELAPSED}s)"
    else
        log_fail "T4-04: HARD GATE — still on controller $new_node after failover (expected different controller)"
        HARD_GATE_FAILED=1
        return 2
    fi
}

# ============================================================
# T4-05: API recovery timing
# ============================================================
test_T4_05() {
    local storage="$1"

    log_info "T4-05: API recovery timing (pvesm list)"

    local retry_max retry_delay window
    retry_max=$(read_storage_cfg "$storage" "api_retry_max" "3")
    retry_delay=$(read_storage_cfg "$storage" "api_retry_delay" "1")
    window=$(retry_window_seconds "$retry_max" "$retry_delay")

    local start_time
    start_time=$(date +%s)
    local recovered=0

    while [[ $(( $(date +%s) - start_time )) -lt $window ]]; do
        if pvesm list "$storage" &>/dev/null; then
            recovered=1
            break
        fi
        sleep 2
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $recovered -eq 1 ]]; then
        log_pass "T4-05: pvesm list recovered in ${elapsed}s (window: ${window}s)"
    else
        log_fail "T4-05: pvesm list did not recover within ${window}s after failover"
        return 1
    fi
}

# ============================================================
# T4-06: iSCSI session reconnection
# ============================================================
test_T4_06() {
    local storage="$1"

    log_info "T4-06: iSCSI session reconnection"

    local transport_mode
    transport_mode=$(read_storage_cfg "$storage" "transport_mode" "iscsi")

    if [[ "$transport_mode" != "iscsi" ]]; then
        log_skip "T4-06: transport is $transport_mode, not iSCSI — skipping session check"
        return 0
    fi

    local target_iqn
    target_iqn=$(read_storage_cfg "$storage" "target_iqn")
    if [[ -z "$target_iqn" ]]; then
        log_skip "T4-06: no target_iqn configured — cannot verify sessions"
        return 0
    fi

    local retry_max retry_delay window
    retry_max=$(read_storage_cfg "$storage" "api_retry_max" "3")
    retry_delay=$(read_storage_cfg "$storage" "api_retry_delay" "1")
    window=$(retry_window_seconds "$retry_max" "$retry_delay")

    local start_time
    start_time=$(date +%s)
    local recovered=0

    while [[ $(( $(date +%s) - start_time )) -lt $window ]]; do
        if iscsiadm -m session 2>/dev/null | grep -q "$target_iqn"; then
            recovered=1
            break
        fi
        sleep 2
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $recovered -eq 1 ]]; then
        log_pass "T4-06: iSCSI session for $target_iqn re-established in ${elapsed}s"
    else
        log_fail "T4-06: iSCSI session for $target_iqn not found within ${window}s after failover"
        return 1
    fi
}

# ============================================================
# T4-07: VM survival after failover
# ============================================================
test_T4_07() {
    local storage="$1"

    log_info "T4-07: VM survival and I/O continuity after failover"

    if [[ $T4_VM_CREATED -ne 1 ]]; then
        log_skip "T4-07: no test VM from T4-02"
        return 0
    fi

    local vm_status
    vm_status=$(qm status "$T4_TEST_VMID" 2>/dev/null | awk '{print $2}')

    if [[ "$vm_status" != "running" ]]; then
        log_fail "T4-07: VM $T4_TEST_VMID status is '$vm_status' after failover (expected running)"
        return 1
    fi

    # Check that background I/O process is still alive
    if [[ -n "$T4_IO_PID" ]] && ! kill -0 "$T4_IO_PID" 2>/dev/null; then
        log_fail "T4-07: background I/O process (PID $T4_IO_PID) died during failover"
        return 1
    fi

    # Check I/O error log from background workload
    local io_errors=0
    if [[ -f "$T4_IO_LOG" ]]; then
        io_errors=$(grep -c 'IO_ERROR' "$T4_IO_LOG" 2>/dev/null || true)
    fi

    # Check dmesg for kernel-level I/O errors on the backing device
    local dmesg_errors=0
    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        dmesg_errors=1
    fi

    if [[ $io_errors -gt 0 ]]; then
        log_fail "T4-07: $io_errors I/O write errors during failover (see $T4_IO_LOG)"
        return 1
    elif [[ $dmesg_errors -gt 0 ]]; then
        log_fail "T4-07: kernel I/O errors in dmesg after failover"
        return 1
    fi

    log_pass "T4-07: VM $T4_TEST_VMID running, I/O process alive, no errors during failover"
}

# ============================================================
# T4-08: Storage operations post-failover
# ============================================================
test_T4_08() {
    local storage="$1"

    log_info "T4-08: Storage operations post-failover (CRUD)"

    local vmid=9741

    # Pre-cleanup
    pvesm list "$storage" 2>/dev/null | awk '{print $1}' | grep "vm-${vmid}-disk" | \
        while read -r v; do pvesm free "$v" &>/dev/null || true; done

    # Create
    local volid
    volid=$(pvesh create /nodes/"$(hostname)"/storage/"$storage"/content \
         -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G 2>/dev/null) || {
        log_fail "T4-08: volume creation failed post-failover"
        return 1
    }
    [[ "$volid" != *:* ]] && volid="${storage}:${volid}"
    log_info "T4-08: created $volid"

    # Snapshot
    local snapname="ha-test-snap-$$"
    if pvesm snapshot "$volid" "$snapname" &>/dev/null; then
        log_info "T4-08: snapshot $snapname created"
        pvesm delsnapshot "$volid" "$snapname" &>/dev/null || true
    else
        log_warn "T4-08: snapshot failed (may not be supported) — continuing"
    fi

    # Resize (grow by 1G)
    if pvesm resize "$volid" 2G &>/dev/null; then
        log_info "T4-08: resize to 2G succeeded"
    else
        log_warn "T4-08: resize failed — continuing"
    fi

    # Delete
    if pvesm free "$volid" &>/dev/null; then
        log_info "T4-08: volume deleted"
    else
        log_fail "T4-08: volume deletion failed post-failover"
        return 1
    fi

    log_pass "T4-08: create/snapshot/resize/delete all succeeded post-failover"
}

# ============================================================
# T4-09: Trigger failback
# ============================================================
test_T4_09() {
    local storage="$1"

    log_info "T4-09: Trigger HA failback"

    # Capture dmesg timestamp before failback so T4-11 can extract relevant messages
    T4_FAILBACK_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    log_info "T4-09: calling failover.become_passive to return to original controller..."
    tn_api_call "$storage" "failover.become_passive" &>/dev/null || true

    log_info "T4-09: waiting for API recovery on VIP (timeout: ${T4_FAILOVER_TIMEOUT}s)..."

    if ! tier4_wait_for_api "$storage" "$T4_FAILOVER_TIMEOUT"; then
        log_warn "T4-09: API did not recover within ${T4_FAILOVER_TIMEOUT}s after failback"
        log_warn "T4-09: original controller may not be MASTER — system is still in a valid HA state"
        return 1
    fi

    log_info "T4-09: API responded after ${T4_RECOVERY_ELAPSED}s"

    # Verify the original controller is back
    local current_node
    current_node=$(tn_api_call "$storage" "failover.node" 2>/dev/null) || {
        log_warn "T4-09: failover.node call failed after failback"
        return 1
    }
    current_node=$(echo "$current_node" | tr -d '"')

    if [[ "$current_node" == "$T4_ORIGINAL_NODE" ]]; then
        log_pass "T4-09: failback complete — controller $current_node is MASTER again (${T4_RECOVERY_ELAPSED}s)"

        # Warn if failback time is close to the iSCSI replacement_timeout —
        # VMs and data integrity checks are likely to fail when the outage
        # approaches or exceeds this threshold.
        local repl_timeout
        repl_timeout=$(grep -m1 'node.session.timeo.replacement_timeout' /etc/iscsi/iscsid.conf 2>/dev/null | awk '{print $3}')
        repl_timeout="${repl_timeout:-120}"
        local threshold=$(( repl_timeout * 75 / 100 ))  # warn at 75% of timeout
        if [[ "$T4_RECOVERY_ELAPSED" -gt "$threshold" ]]; then
            log_warn "T4-09: failback took ${T4_RECOVERY_ELAPSED}s — close to iSCSI replacement_timeout (${repl_timeout}s). VM survival and data integrity tests may fail. Consider increasing node.session.timeo.replacement_timeout in /etc/iscsi/iscsid.conf."
        fi
    else
        log_warn "T4-09: controller $current_node is MASTER, expected original controller $T4_ORIGINAL_NODE"
        log_warn "T4-09: system is in a valid HA state, just not the original topology"
        return 1
    fi
}

# ============================================================
# T4-10: API recovery after failback
# ============================================================
test_T4_10() {
    local storage="$1"

    log_info "T4-10: API recovery timing after failback (pvesm list)"

    local retry_max retry_delay window
    retry_max=$(read_storage_cfg "$storage" "api_retry_max" "3")
    retry_delay=$(read_storage_cfg "$storage" "api_retry_delay" "1")
    window=$(retry_window_seconds "$retry_max" "$retry_delay")

    local start_time
    start_time=$(date +%s)
    local recovered=0

    while [[ $(( $(date +%s) - start_time )) -lt $window ]]; do
        if pvesm list "$storage" &>/dev/null; then
            recovered=1
            break
        fi
        sleep 2
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $recovered -eq 1 ]]; then
        log_pass "T4-10: pvesm list recovered in ${elapsed}s after failback (window: ${window}s)"
    else
        log_fail "T4-10: pvesm list did not recover within ${window}s after failback"
        return 1
    fi
}

# ============================================================
# T4-11: VM survival after failback
# ============================================================
test_T4_11() {
    local storage="$1"

    log_info "T4-11: VM survival and I/O continuity after failback"

    if [[ $T4_VM_CREATED -ne 1 ]]; then
        log_skip "T4-11: no test VM from T4-02"
        return 0
    fi

    local vm_status
    vm_status=$(qm status "$T4_TEST_VMID" 2>/dev/null | awk '{print $2}')

    if [[ "$vm_status" != "running" ]]; then
        log_fail "T4-11: VM $T4_TEST_VMID status is '$vm_status' after failback (expected running)"
        # Dump relevant dmesg/SCSI errors to help diagnose why the VM stopped
        if [[ -n "${T4_FAILBACK_TIMESTAMP:-}" ]]; then
            local scsi_errors
            scsi_errors=$(dmesg --time-format iso 2>/dev/null | awk -v after="$T4_FAILBACK_TIMESTAMP" '$1 >= after' | \
                grep -iE 'scsi|iscsi|session|I/O error|abort|reset|target' | tail -20)
            if [[ -n "$scsi_errors" ]]; then
                log_info "T4-11: SCSI/iSCSI dmesg during failback:"
                while IFS= read -r line; do
                    log_info "T4-11:   $line"
                done <<< "$scsi_errors"
            fi
        fi
        return 1
    fi

    # Stop background I/O and check results — it's been running since T4-03
    # through both failover and failback
    local io_ok=1
    if [[ -n "$T4_IO_PID" ]]; then
        if ! kill -0 "$T4_IO_PID" 2>/dev/null; then
            log_fail "T4-11: background I/O process (PID $T4_IO_PID) died during failover/failback cycle"
            io_ok=0
        fi
        if ! tier4_stop_io; then
            local io_errors
            io_errors=$(grep -c 'IO_ERROR' "$T4_IO_LOG" 2>/dev/null || true)
            log_fail "T4-11: $io_errors I/O write errors during failover/failback cycle (see $T4_IO_LOG)"
            io_ok=0
        fi
    fi

    # Check dmesg for kernel-level I/O errors
    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        log_fail "T4-11: kernel I/O errors in dmesg after failback"
        return 1
    fi

    if [[ $io_ok -eq 1 ]]; then
        log_pass "T4-11: VM running, background I/O survived full failover/failback cycle with zero errors"
    else
        return 1
    fi
}

# ============================================================
# T4-12: Data integrity after failover/failback cycle
# ============================================================
test_T4_12() {
    local storage="$1"

    log_info "T4-12: Data integrity — verify marker survived failover/failback"

    if [[ -z "${T4_MARKER:-}" ]]; then
        log_skip "T4-12: no marker from T4-03"
        return 0
    fi

    if [[ -z "$T4_MARKER_VOLID" ]]; then
        log_skip "T4-12: no marker volume"
        return 0
    fi

    local dev
    dev=$(pvesm path "$T4_MARKER_VOLID" 2>/dev/null)
    if [[ -z "$dev" ]]; then
        log_fail "T4-12: pvesm path returned empty for $T4_MARKER_VOLID"
        return 1
    fi

    log_info "T4-12: reading marker from $dev (volid: $T4_MARKER_VOLID)"

    # Check if the device path actually exists after failover cycle
    if [[ ! -e "$dev" ]]; then
        log_info "T4-12: device $dev does not exist, triggering iSCSI rescan..."
        iscsiadm -m session -R &>/dev/null || true
        sleep 3
        udevadm settle &>/dev/null || true
        dev=$(pvesm path "$T4_MARKER_VOLID" 2>/dev/null)
        if [[ -z "$dev" || ! -e "$dev" ]]; then
            log_fail "T4-12: device still not available after rescan (volid: $T4_MARKER_VOLID)"
            return 1
        fi
        log_info "T4-12: device re-resolved to $dev after rescan"
    fi

    # Log device state for debugging
    local real_dev
    real_dev=$(readlink -f "$dev" 2>/dev/null || echo "unresolvable")
    log_info "T4-12: device $dev -> $real_dev (exists: $(test -e "$dev" && echo yes || echo no), blockdev: $(test -b "$dev" && echo yes || echo no))"

    # Flush page cache so we read from the actual device, not stale cache
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    blockdev --flushbufs "$dev" 2>/dev/null || true

    local readback
    readback=$(dd if="$dev" bs=512 count=1 iflag=direct 2>/dev/null | tr -d '\0')

    if echo "$readback" | grep -q "$T4_MARKER"; then
        log_pass "T4-12: marker intact after full failover/failback cycle"
    else
        local readback2
        readback2=$(dd if="$dev" bs=512 count=1 2>/dev/null | tr -d '\0')
        local hexdump
        hexdump=$(dd if="$dev" bs=512 count=1 2>/dev/null | xxd | head -3)
        log_fail "T4-12: marker mismatch — wrote '$T4_MARKER', direct='$readback', buffered='$readback2' (dev: $dev -> $real_dev)"
        log_info "T4-12: hex dump of first 48 bytes: $hexdump"
        return 1
    fi
}

# ============================================================
# Entry point
# ============================================================
run_tier4() {
    local storage="$1" config="$2"

    log_info "=== Tier 4: TrueNAS Enterprise HA Tests ==="
    local t4_start
    t4_start=$(date +%s)

    # Pre-cleanup stale resources from previous runs
    tier4_cleanup "$storage"

    tier4_preflight "$storage" || {
        log_fail "Tier 4 pre-flight failed — aborting Tier 4"
        return 2
    }

    # --- Pre-failover setup ---
    test_T4_01 "$storage"
    test_T4_02 "$storage"
    test_T4_03 "$storage"

    # --- Failover ---
    test_T4_04 "$storage"
    if [[ "$HARD_GATE_FAILED" -ne 0 ]]; then
        log_warn "Tier 4: T4-04 hard gate failed — skipping remaining Tier 4 tests"
        tier4_cleanup "$storage"
        return 2
    fi
    test_T4_05 "$storage"
    test_T4_06 "$storage"
    test_T4_07 "$storage"
    test_T4_08 "$storage"

    # --- Wait for standby before failback ---
    # The former active controller needs time to reboot and rejoin as standby.
    # Without this, failback will fail because there's no standby to fail over to.
    tier4_wait_for_standby "$storage" || {
        log_warn "Tier 4: standby controller not ready — failback tests may fail"
    }

    # --- Failback ---
    test_T4_09 "$storage"
    test_T4_10 "$storage"
    test_T4_11 "$storage"
    test_T4_12 "$storage"

    # --- Cleanup ---
    tier4_cleanup "$storage"

    local t4_elapsed=$(( $(date +%s) - t4_start ))
    log_info "=== Tier 4 complete in ${t4_elapsed}s ==="
}
