# tools/lib/tier3.sh
# Tier 3: Cluster and migration tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.

# Cluster node list helper — returns peer node IPs (excluding local node)
cluster_peer_ips() {
    pvecm nodes 2>/dev/null | awk 'NR>1 {print $3}' | \
        grep -v "$(hostname -I | awk '{print $1}')" | head -2
}

# ============================================================
# Pre-flight checks for Tier 3
# ============================================================
tier3_preflight() {
    local storage="$1" config="$2"
    local ok=0

    log_info "Tier 3 pre-flight checks..."

    # Need >=3 nodes in cluster
    local node_count
    node_count=$(pvecm status 2>/dev/null | awk '/^Nodes:/ {print $2}')
    if [[ "${node_count:-0}" -lt 3 ]]; then
        log_warn "Tier 3 pre-flight: cluster has ${node_count:-0} nodes (need >=3) — skipping Tier 3"
        return 1
    fi

    # All peers SSH-reachable
    while IFS= read -r peer; do
        if ! ssh_reachable "$peer"; then
            log_warn "Tier 3 pre-flight: node $peer not SSH-reachable — skipping Tier 3"
            return 1
        fi
    done < <(cluster_peer_ips)

    # Plugin file checksum identical on all nodes
    local local_sum
    local_sum=$(md5sum /usr/share/perl5/PVE/Storage/TrueNASPlugin.pm 2>/dev/null | awk '{print $1}')
    while IFS= read -r peer; do
        local remote_sum
        remote_sum=$(ssh_run "$peer" md5sum /usr/share/perl5/PVE/Storage/TrueNASPlugin.pm 2>/dev/null | awk '{print $1}')
        if [[ "$local_sum" != "$remote_sum" ]]; then
            log_warn "Tier 3 pre-flight: plugin checksum mismatch on $peer — update plugin on all nodes before running Tier 3"
            return 1
        fi
    done < <(cluster_peer_ips)

    # Storage active on all nodes
    while IFS= read -r peer; do
        if ! ssh_run "$peer" pvesm status 2>/dev/null | grep -q "^${storage} "; then
            log_warn "Tier 3 pre-flight: storage '$storage' not active on $peer — skipping Tier 3"
            return 1
        fi
    done < <(cluster_peer_ips)

    # Config D: multipath config consistent
    if [[ "$config" == "D" || "$config" == "all" ]]; then
        local local_mp_sum
        local_mp_sum=$(md5sum /etc/multipath.conf 2>/dev/null | awk '{print $1}')
        while IFS= read -r peer; do
            local remote_mp
            remote_mp=$(ssh_run "$peer" md5sum /etc/multipath.conf 2>/dev/null | awk '{print $1}')
            if [[ "$local_mp_sum" != "$remote_mp" ]]; then
                log_warn "Tier 3 pre-flight: /etc/multipath.conf differs on $peer"
                # Advisory warning only — not a hard abort for pre-flight
            fi
        done < <(cluster_peer_ips)
    fi

    log_info "Tier 3 pre-flight: OK"
    return 0
}

# ============================================================
# T3-01: Shared storage visibility across nodes
# ============================================================
test_T3_01() {
    local storage="$1"

    log_info "T3-01: Shared storage visibility"

    local vmid=9720
    pvesh post /nodes/localhost/storage/"$storage"/content \
        -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size 1G &>/dev/null || {
        log_skip "T3-01: could not create volume"
        return 0
    }

    local volid="${storage}:vm-${vmid}-disk-0"
    local all_visible=1

    while IFS= read -r peer; do
        if ! ssh_run "$peer" pvesm list "$storage" 2>/dev/null | grep -q "vm-${vmid}-disk-0"; then
            log_fail "T3-01: volume vm-${vmid}-disk-0 not visible on $peer"
            all_visible=0
        fi
    done < <(cluster_peer_ips)

    if [[ $all_visible -eq 1 ]]; then
        log_pass "T3-01: volume visible on all cluster nodes"
    fi

    pvesm free "$volid" &>/dev/null || true
}

# ============================================================
# T3-02: Concurrent VM creation on two nodes
# ============================================================
test_T3_02() {
    local storage="$1"

    log_info "T3-02: Concurrent VM creation on two nodes"

    local peers=()
    while IFS= read -r peer; do
        peers+=("$peer")
    done < <(cluster_peer_ips)

    if [[ ${#peers[@]} -lt 2 ]]; then
        log_skip "T3-02: need at least 2 peer nodes"
        return 0
    fi

    local vmid1=9721 vmid2=9722
    local result1 result2

    # Launch simultaneously
    ssh_run "${peers[0]}" \
        pvesh post /nodes/"${peers[0]}"/qemu \
        -vmid "$vmid1" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null &
    local pid1=$!

    ssh_run "${peers[1]}" \
        pvesh post /nodes/"${peers[1]}"/qemu \
        -vmid "$vmid2" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null &
    local pid2=$!

    wait "$pid1"; result1=$?
    wait "$pid2"; result2=$?

    if [[ $result1 -eq 0 && $result2 -eq 0 ]]; then
        # Verify no lock timeout in journal
        if journalctl -u pvedaemon --since "2 minutes ago" --no-pager 2>/dev/null | \
           grep -qi 'lock timeout'; then
            log_fail "T3-02: lock timeout errors in pvedaemon journal during concurrent creation"
        else
            log_pass "T3-02: both VMs created concurrently without lock timeout"
        fi
    else
        log_fail "T3-02: concurrent VM creation failed (exit codes: $result1, $result2)"
    fi

    # Cleanup
    ssh_run "${peers[0]}" qm destroy "$vmid1" --purge &>/dev/null || true
    ssh_run "${peers[1]}" qm destroy "$vmid2" --purge &>/dev/null || true
}

# ============================================================
# T3-03: Live migration — iSCSI (skip for Config F)
# ============================================================
test_T3_03() {
    local storage="$1" config="$2"

    if [[ "$config" == "F" ]]; then
        log_skip "T3-03: live migration (iSCSI) — skipped for Config F"
        return 0
    fi

    log_info "T3-03: Live migration (iSCSI)"

    local peers=()
    while IFS= read -r peer; do peers+=("$peer"); done < <(cluster_peer_ips)
    local dest="${peers[0]:-}"
    if [[ -z "$dest" ]]; then
        log_skip "T3-03: no peer node available"
        return 0
    fi

    local vmid=9723
    pvesh post /nodes/localhost/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null
    qm start "$vmid" &>/dev/null
    sleep 5

    if qm migrate "$vmid" "$dest" --online; then
        local dev
        dev=$(ssh_run "$dest" pvesm path "${storage}:vm-${vmid}-disk-0" 2>/dev/null)
        if [[ "$dev" =~ /dev/mapper/mpath ]]; then
            log_pass "T3-03: VM migrated to $dest; disk path is mapper device on destination"
        else
            log_fail "T3-03: VM migrated but disk path on $dest is '$dev' (expected /dev/mapper/mpathX)"
        fi
    else
        log_fail "T3-03: qm migrate exited non-zero"
    fi

    ssh_run "$dest" qm destroy "$vmid" --purge &>/dev/null || true
    T3_LAST_DEST="$dest"
}

# ============================================================
# T3-04: Live migration — NVMe/TCP (skip for Config D) — HARD GATE
# ============================================================
test_T3_04() {
    local storage="$1" config="$2"

    if [[ "$config" == "D" ]]; then
        log_skip "T3-04: live migration (NVMe/TCP) — skipped for Config D"
        return 0
    fi

    log_info "T3-04: Live migration (NVMe/TCP) — hard gate"

    local peers=()
    while IFS= read -r peer; do peers+=("$peer"); done < <(cluster_peer_ips)
    local dest="${peers[0]:-}"
    if [[ -z "$dest" ]]; then
        log_skip "T3-04: no peer node available"
        return 0
    fi

    local vmid=9724
    pvesh post /nodes/localhost/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:8,format=raw" &>/dev/null
    qm start "$vmid" &>/dev/null
    sleep 5

    if qm migrate "$vmid" "$dest" --online; then
        local subsys
        subsys=$(ssh_run "$dest" nvme list-subsys 2>/dev/null)
        if echo "$subsys" | grep -q 'TrueNAS\|truenas'; then
            log_pass "T3-04: VM migrated; NVMe subsystem connected on $dest"
        else
            log_fail "T3-04: HARD GATE — VM migrated but NVMe subsystem not found on $dest"
            HARD_GATE_FAILED=1
            ssh_run "$dest" qm destroy "$vmid" --purge &>/dev/null || true
            return 2
        fi
    else
        log_fail "T3-04: HARD GATE — qm migrate (NVMe/TCP) exited non-zero"
        HARD_GATE_FAILED=1
        qm destroy "$vmid" --purge &>/dev/null || true
        return 2
    fi

    ssh_run "$dest" qm destroy "$vmid" --purge &>/dev/null || true
    T3_LAST_DEST="$dest"
}

# ============================================================
# T3-05: Multipath state post-migration (skip for Config F)
# ============================================================
test_T3_05() {
    local storage="$1" config="$2"

    if [[ "$config" == "F" ]]; then
        log_skip "T3-05: multipath post-migration — skipped for Config F"
        return 0
    fi

    local dest="${T3_LAST_DEST:-}"
    if [[ -z "$dest" ]]; then
        log_skip "T3-05: no migration destination from T3-03"
        return 0
    fi

    log_info "T3-05: Multipath state on destination node after migration"

    local mp_output
    mp_output=$(ssh_run "$dest" multipath -ll 2>/dev/null)

    if echo "$mp_output" | grep -qi 'failed\|ghost'; then
        log_fail "T3-05: failed or ghost paths found on $dest after migration: $mp_output"
        return 1
    else
        log_pass "T3-05: all paths active on $dest — no failed or ghost paths"
    fi
}

# ============================================================
# T3-06: Per-node config file consistency
# ============================================================
test_T3_06() {
    local storage="$1" config="$2"

    log_info "T3-06: Per-node config file consistency"

    local check_file
    if [[ "$config" == "F" ]]; then
        check_file=/etc/nvme/hostnqn
    else
        check_file=/etc/multipath.conf
    fi

    local local_sum
    local_sum=$(md5sum "$check_file" 2>/dev/null | awk '{print $1}')
    local all_match=1

    while IFS= read -r peer; do
        local remote_sum
        remote_sum=$(ssh_run "$peer" md5sum "$check_file" 2>/dev/null | awk '{print $1}')
        if [[ "$local_sum" != "$remote_sum" ]]; then
            log_fail "T3-06: $check_file differs on node $peer"
            all_match=0
        fi
    done < <(cluster_peer_ips)

    if [[ $all_match -eq 1 ]]; then
        log_pass "T3-06: $check_file checksums identical on all nodes"
    fi
}

# ============================================================
# T3-07: Cluster lock timeout — concurrent volume creation
# ============================================================
test_T3_07() {
    local storage="$1"

    log_info "T3-07: Cluster lock timeout under concurrent operations"

    local lock_timeout
    lock_timeout=$(read_storage_cfg "$storage" "storage_lock_timeout" "120")

    local peers=()
    while IFS= read -r peer; do peers+=("$peer"); done < <(cluster_peer_ips)
    if [[ ${#peers[@]} -lt 2 ]]; then
        log_skip "T3-07: need at least 2 peer nodes"
        return 0
    fi

    local vmid1=9725 vmid2=9726
    local wall_start
    wall_start=$(date +%s)

    # Trigger concurrent creates via SSH
    ssh_run "${peers[0]}" \
        pvesh post /nodes/"${peers[0]}"/storage/"$storage"/content \
        -vmid "$vmid1" -filename "vm-${vmid1}-disk-0" -size 1G &>/dev/null &
    local pid1=$!

    ssh_run "${peers[1]}" \
        pvesh post /nodes/"${peers[1]}"/storage/"$storage"/content \
        -vmid "$vmid2" -filename "vm-${vmid2}-disk-0" -size 1G &>/dev/null &
    local pid2=$!

    wait "$pid1"; local r1=$?
    wait "$pid2"; local r2=$?

    local wall_elapsed=$(( $(date +%s) - wall_start ))

    if [[ "$wall_elapsed" -gt "$lock_timeout" ]]; then
        log_fail "T3-07: operations took ${wall_elapsed}s, exceeding lock_timeout=${lock_timeout}s"
        return 1
    fi

    if [[ $r1 -ne 0 || $r2 -ne 0 ]]; then
        log_fail "T3-07: concurrent creates failed (exit: $r1, $r2)"
        return 1
    fi

    if journalctl -u pvedaemon --since "3 minutes ago" --no-pager 2>/dev/null | \
       grep -qi 'lock timeout'; then
        log_fail "T3-07: lock timeout errors in pvedaemon journal"
        return 1
    fi

    log_pass "T3-07: concurrent creates completed in ${wall_elapsed}s (timeout: ${lock_timeout}s)"

    # Cleanup
    ssh_run "${peers[0]}" pvesm free "${storage}:vm-${vmid1}-disk-0" &>/dev/null || true
    ssh_run "${peers[1]}" pvesm free "${storage}:vm-${vmid2}-disk-0" &>/dev/null || true
}

# ============================================================
# T3-08: Orphan scan on all nodes after clean deletion
# ============================================================
test_T3_08() {
    local storage="$1"

    log_info "T3-08: Orphan scan across all cluster nodes"

    local installer
    installer=$(find /opt /root /home -name install.sh -path "*/truenas*" 2>/dev/null | head -1)
    if [[ -z "$installer" ]]; then
        log_skip "T3-08: install.sh not found — cannot run orphan scan"
        return 0
    fi

    local all_clean=1

    # Local node
    local local_scan
    local_scan=$(bash "$installer" --health-check 2>&1)
    if ! echo "$local_scan" | grep -qiE 'orphan.*: ?0|no orphan'; then
        log_fail "T3-08: orphans found on local node: $local_scan"
        all_clean=0
    fi

    while IFS= read -r peer; do
        local remote_scan
        remote_scan=$(ssh_run "$peer" bash "$installer" --health-check 2>&1) || true
        if ! echo "$remote_scan" | grep -qiE 'orphan.*: ?0|no orphan'; then
            log_fail "T3-08: orphans found on $peer: $remote_scan"
            all_clean=0
        fi
    done < <(cluster_peer_ips)

    if [[ $all_clean -eq 1 ]]; then
        log_pass "T3-08: zero orphans on all cluster nodes"
    fi
}

# ============================================================
# T3-09: Plugin version consistency across nodes
# ============================================================
test_T3_09() {
    local storage="$1"

    log_info "T3-09: Plugin version consistency"

    local plugin_file=/usr/share/perl5/PVE/Storage/TrueNASPlugin.pm
    local local_sum
    local_sum=$(md5sum "$plugin_file" 2>/dev/null | awk '{print $1}')
    local all_match=1

    while IFS= read -r peer; do
        local remote_sum
        remote_sum=$(ssh_run "$peer" md5sum "$plugin_file" 2>/dev/null | awk '{print $1}')
        if [[ "$local_sum" != "$remote_sum" ]]; then
            log_fail "T3-09: plugin checksum differs on node $peer — deploy same version to all nodes"
            all_match=0
        fi
    done < <(cluster_peer_ips)

    if [[ $all_match -eq 1 ]]; then
        log_pass "T3-09: plugin file identical on all cluster nodes"
    fi
}

# ============================================================
# Entry point
# ============================================================
run_tier3() {
    local storage="$1" config="$2"

    log_info "=== Tier 3: Cluster and Migration Tests ==="
    local t3_start
    t3_start=$(date +%s)

    tier3_preflight "$storage" "$config" || {
        log_warn "Tier 3 pre-flight failed — skipping Tier 3 (does not affect overall exit code unless Config D or F required)"
        return 0
    }

    test_T3_01 "$storage"
    test_T3_02 "$storage"
    test_T3_03 "$storage" "$config"
    test_T3_04 "$storage" "$config"
    test_T3_05 "$storage" "$config"
    test_T3_06 "$storage" "$config"
    test_T3_07 "$storage"
    test_T3_08 "$storage"
    test_T3_09 "$storage"

    local t3_elapsed=$(( $(date +%s) - t3_start ))
    log_info "=== Tier 3 complete in ${t3_elapsed}s ==="
}
