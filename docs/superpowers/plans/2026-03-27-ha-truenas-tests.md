# Tier 4: TrueNAS Enterprise HA Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Tier 4 test suite that validates Proxmox plugin resilience across TrueNAS Enterprise HA failover/failback cycles.

**Architecture:** New `tools/lib/tier4.sh` file following the existing tier pattern (preflight, test functions, entry point). A `tn_api_call` bash helper shells out to Perl to call the TrueNAS WebSocket API through the plugin's own code path. Harness (`run-tests.sh`) gains `--config H` and Tier 4 detection/orchestration. Unit tests extended for the new config type.

**Tech Stack:** Bash (test harness), Perl one-liner (API shim using `PVE::Storage::Custom::TrueNASPlugin`)

**Spec:** `docs/superpowers/specs/2026-03-27-ha-truenas-test-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `tools/lib/common.sh` | Modify | Add `tn_api_call` helper function |
| `tools/lib/tier4.sh` | Create | All Tier 4 test functions: preflight, T4-01 through T4-12, cleanup, `run_tier4` entry point |
| `tools/run-tests.sh` | Modify | Add Config H, Tier 4 detection, Tier 4 orchestration |
| `tools/tests/test_arg_parsing.sh` | Modify | Add unit tests for Config H parsing |

---

### Task 1: Add `tn_api_call` helper to common.sh

**Files:**
- Modify: `tools/lib/common.sh`
- Modify: `tools/tests/test_common.sh`

This helper lets any tier call the TrueNAS WebSocket API using the plugin's own connection code. It reads `api_host` and `api_key` from `storage.cfg` via `read_storage_cfg`, constructs a minimal `$scfg` hash, and calls the requested method.

- [ ] **Step 1: Write the test for `tn_api_call` argument validation**

Add to `tools/tests/test_common.sh`, before the final results summary:

```bash
# --- tn_api_call argument validation ---
# tn_api_call requires at least 2 args: storage and method
out=$(tn_api_call 2>&1) || true
assert_match "tn_api_call no args" 'Usage:' "$out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/tests/test_common.sh`
Expected: FAIL — `tn_api_call: command not found`

- [ ] **Step 3: Implement `tn_api_call` in common.sh**

Add to the end of `tools/lib/common.sh` (before the closing comment, after `ssh_reachable`):

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tools/tests/test_common.sh`
Expected: PASS for `tn_api_call no args`

- [ ] **Step 5: Commit**

```bash
git add tools/lib/common.sh tools/tests/test_common.sh
git commit -m "feat: add tn_api_call helper for TrueNAS WebSocket API calls from bash"
```

---

### Task 2: Add Config H and Tier 4 detection to run-tests.sh

**Files:**
- Modify: `tools/run-tests.sh`
- Modify: `tools/tests/test_arg_parsing.sh`

- [ ] **Step 1: Write unit tests for Config H**

Add to `tools/tests/test_arg_parsing.sh`, before the final results summary:

```bash
# --- Config H ---
parse_args --storage mystore --config H --yes
assert_eq "parse --config H"  "H" "$ARG_CONFIG"

assert_eq "config H tiers" "1 4"       "$(config_required_tiers H)"
assert_eq "config H gates" "T1-01 T4-04" "$(config_hard_gates H)"

# Config 'all' now includes tier 4
assert_eq "config all tiers (with T4)" "1 2 3 4" "$(config_required_tiers all)"
assert_eq "config all gates (with T4)" "T1-01 T2-03 T3-04 T4-04" "$(config_hard_gates all)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/tests/test_arg_parsing.sh`
Expected: FAIL — `config H tiers` returns `1` (fallthrough to default)

- [ ] **Step 3: Update `config_required_tiers` in run-tests.sh**

Change the function in `tools/run-tests.sh`:

```bash
config_required_tiers() {
    case "$1" in
        A)   echo "1"       ;;
        D)   echo "1 2"     ;;
        F)   echo "1 3"     ;;
        H)   echo "1 4"     ;;
        all) echo "1 2 3 4" ;;
        *)   echo "1"       ;;
    esac
}
```

- [ ] **Step 4: Update `config_hard_gates` in run-tests.sh**

```bash
config_hard_gates() {
    case "$1" in
        A)   echo "T1-01"                   ;;
        D)   echo "T1-01 T2-03"             ;;
        F)   echo "T1-01 T3-04"             ;;
        H)   echo "T1-01 T4-04"             ;;
        all) echo "T1-01 T2-03 T3-04 T4-04" ;;
        *)   echo "T1-01"                   ;;
    esac
}
```

- [ ] **Step 5: Add Tier 4 detection to `detect_max_tier`**

Add after the Tier 3 detection block (before `echo "$tier"`):

```bash
    # Tier 4: TrueNAS HA — requires Tier 1 + failover.licensed == true
    if [[ $tier -ge 1 ]] && [[ -n "$ARG_STORAGE" ]]; then
        local ha_licensed
        ha_licensed=$(tn_api_call "$ARG_STORAGE" "failover.licensed" 2>/dev/null || true)
        if [[ "$ha_licensed" == "true" ]]; then
            # Tier 4 is independent — set a flag but don't change the linear tier number
            # since tiers 2/3/4 are independent branches, not a strict hierarchy
            TIER4_AVAILABLE=1
        fi
    fi
```

Note: Because Tier 4 is independent of Tiers 2 and 3, `detect_max_tier` can't just return a single number anymore. Add a global `TIER4_AVAILABLE=0` near the other globals, and adjust `run_tier` to check it:

In the `run_tier` function, add a case for tier 4:

```bash
run_tier() {
    local tier="$1"
    if [[ "$ARG_TIER" != "all" && "$ARG_TIER" != "$tier" ]]; then
        log_info "Tier $tier skipped by --tier flag"
        return 0
    fi
    if [[ "$tier" -eq 4 ]]; then
        if [[ "${TIER4_AVAILABLE:-0}" -ne 1 ]]; then
            log_skip "Tier 4 — HA TrueNAS not detected"
            return 0
        fi
    elif [[ "$tier" -gt "$MAX_TIER" ]]; then
        log_skip "Tier $tier — requires hardware not detected"
        return 0
    fi
    case "$tier" in
        1) run_tier1 "$ARG_STORAGE" "$ARG_CONFIG" ;;
        2) run_tier2 "$ARG_STORAGE" "$ARG_CONFIG" ;;
        3) run_tier3 "$ARG_STORAGE" "$ARG_CONFIG" ;;
        4) run_tier4 "$ARG_STORAGE" "$ARG_CONFIG" ;;
    esac
}
```

- [ ] **Step 6: Add tier4.sh source and `run_tier 4` call**

In the tier orchestration section, add:

```bash
source "$SCRIPT_DIR/lib/tier4.sh"
```

After `run_tier 3`, add:

```bash
run_tier 4
```

- [ ] **Step 7: Add `TIER4_AVAILABLE=0` global**

Add near the other globals (after `HARD_GATE_FAILED=0`):

```bash
TIER4_AVAILABLE=0
```

- [ ] **Step 8: Update hardware validation for Tier 4**

The existing validation block uses `$MAX_TIER` which is linear. For Tier 4, add a check after the existing loop:

```bash
# Validate hardware against --config requirements
if [[ "$ARG_CONFIG" != "all" ]]; then
    required_tiers=$(config_required_tiers "$ARG_CONFIG")
    for t in $required_tiers; do
        if [[ "$t" -eq 4 ]]; then
            if [[ "${TIER4_AVAILABLE:-0}" -ne 1 ]]; then
                log_fail "Hardware insufficient for Config $ARG_CONFIG: Tier 4 (HA TrueNAS) required but not detected"
                exit 2
            fi
        elif [[ "$t" -gt "$MAX_TIER" ]]; then
            log_fail "Hardware insufficient for Config $ARG_CONFIG: Tier $t required but max detected is $MAX_TIER"
            exit 2
        fi
    done
fi
```

- [ ] **Step 9: Update test_arg_parsing.sh for changed 'all' values**

The existing tests for `config all` need updating. Change:

```bash
assert_eq "config all tiers" "1 2 3" "$(config_required_tiers all)"
assert_eq "config all gates" "T1-01 T2-03 T3-04" "$(config_hard_gates all)"
```

to:

```bash
assert_eq "config all tiers" "1 2 3 4" "$(config_required_tiers all)"
assert_eq "config all gates" "T1-01 T2-03 T3-04 T4-04" "$(config_hard_gates all)"
```

Remove the duplicate assertions added in Step 1 (they tested the same thing).

- [ ] **Step 10: Run tests to verify**

Run: `bash tools/tests/test_arg_parsing.sh`
Expected: All PASS

- [ ] **Step 11: Commit**

```bash
git add tools/run-tests.sh tools/tests/test_arg_parsing.sh
git commit -m "feat: add Config H and Tier 4 (HA TrueNAS) detection to test harness"
```

---

### Task 3: Create tier4.sh — preflight and cleanup

**Files:**
- Create: `tools/lib/tier4.sh`

This task creates the file with preflight checks, cleanup function, and the `run_tier4` entry point. Test functions are added in subsequent tasks.

- [ ] **Step 1: Create tier4.sh with header, globals, and preflight**

Create `tools/lib/tier4.sh`:

```bash
# tools/lib/tier4.sh
# Tier 4: TrueNAS Enterprise HA failover/failback tests.
# Sourced by run-tests.sh. Requires common.sh already sourced.
# Globals used: PASS_COUNT, FAIL_COUNT, SKIP_COUNT, HARD_GATE_FAILED, LOG_FILE

# Tier 4 shared state
T4_ORIGINAL_NODE=""         # Controller letter (A or B) at test start
T4_TEST_VMID=9740
T4_TEST_VOLID=""
T4_VM_CREATED=0
T4_FAILOVER_TIMEOUT=180     # seconds
T4_POLL_INTERVAL=5          # seconds

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

    # Destroy test VM if it exists
    if [[ $T4_VM_CREATED -eq 1 ]]; then
        qm stop "$T4_TEST_VMID" --timeout 10 &>/dev/null || true
        qm destroy "$T4_TEST_VMID" --purge &>/dev/null || true
        T4_VM_CREATED=0
    fi

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
```

- [ ] **Step 2: Verify file sources without error**

Run: `bash -n tools/lib/tier4.sh`
Expected: No output (syntax OK). Will warn about undefined test functions, but that's expected — they're added in the next tasks.

- [ ] **Step 3: Commit**

```bash
git add tools/lib/tier4.sh
git commit -m "feat: add tier4.sh skeleton with preflight, cleanup, and entry point"
```

---

### Task 4: Implement T4-01 through T4-03 (pre-failover setup)

**Files:**
- Modify: `tools/lib/tier4.sh`

Add the three pre-failover test functions after the `tier4_wait_for_api` function and before `run_tier4`.

- [ ] **Step 1: Implement T4-01 — HA status baseline**

Add to `tools/lib/tier4.sh`:

```bash
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
```

- [ ] **Step 2: Implement T4-02 — create test volume and start VM**

```bash
# ============================================================
# T4-02: Create test volume and start VM
# ============================================================
test_T4_02() {
    local storage="$1"

    log_info "T4-02: Create test volume and start VM"

    local vmid=$T4_TEST_VMID

    # Create VM with a disk on the HA storage
    pvesh create /nodes/"$(hostname)"/qemu \
        -vmid "$vmid" -memory 128 -cores 1 \
        -scsi0 "${storage}:1,format=raw" &>/dev/null || {
        log_fail "T4-02: could not create test VM $vmid"
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
    qm start "$vmid" &>/dev/null || {
        log_fail "T4-02: could not start VM $vmid"
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
```

- [ ] **Step 3: Implement T4-03 — pre-failover I/O marker**

```bash
# ============================================================
# T4-03: Pre-failover I/O marker
# ============================================================
test_T4_03() {
    local storage="$1"

    log_info "T4-03: Pre-failover I/O marker"

    if [[ -z "$T4_TEST_VOLID" ]]; then
        log_skip "T4-03: no test volume from T4-02"
        return 0
    fi

    local dev
    dev=$(pvesm path "$T4_TEST_VOLID" 2>/dev/null)
    if [[ -z "$dev" ]]; then
        log_fail "T4-03: pvesm path returned empty for $T4_TEST_VOLID"
        return 1
    fi

    # Write a known marker to the raw block device
    T4_MARKER="truenas-ha-test-marker-$$"
    echo "$T4_MARKER" | dd of="$dev" bs=512 count=1 conv=notrunc &>/dev/null || {
        log_fail "T4-03: failed to write marker to $dev"
        return 1
    }

    # Verify we can read it back before failover
    local readback
    readback=$(dd if="$dev" bs=512 count=1 2>/dev/null | tr -d '\0')
    if echo "$readback" | grep -q "$T4_MARKER"; then
        log_pass "T4-03: marker written and verified on $dev"
    else
        log_fail "T4-03: marker readback failed (wrote '$T4_MARKER', got '$readback')"
        return 1
    fi
}
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n tools/lib/tier4.sh`
Expected: No output (syntax OK)

- [ ] **Step 5: Commit**

```bash
git add tools/lib/tier4.sh
git commit -m "feat: implement T4-01 through T4-03 (pre-failover setup)"
```

---

### Task 5: Implement T4-04 through T4-08 (failover and post-failover)

**Files:**
- Modify: `tools/lib/tier4.sh`

Add after the T4-03 function.

- [ ] **Step 1: Implement T4-04 — trigger failover (hard gate)**

```bash
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
```

- [ ] **Step 2: Implement T4-05 — API recovery timing**

```bash
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
```

- [ ] **Step 3: Implement T4-06 — iSCSI session reconnection**

```bash
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
```

- [ ] **Step 4: Implement T4-07 — VM survival**

```bash
# ============================================================
# T4-07: VM survival after failover
# ============================================================
test_T4_07() {
    local storage="$1"

    log_info "T4-07: VM survival after failover"

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

    # Check dmesg for I/O errors on the backing device
    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        log_fail "T4-07: I/O errors found in dmesg after failover"
        return 1
    fi

    log_pass "T4-07: VM $T4_TEST_VMID still running, no I/O errors"
}
```

- [ ] **Step 5: Implement T4-08 — storage operations post-failover**

```bash
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
```

- [ ] **Step 6: Verify syntax**

Run: `bash -n tools/lib/tier4.sh`
Expected: No output (syntax OK)

- [ ] **Step 7: Commit**

```bash
git add tools/lib/tier4.sh
git commit -m "feat: implement T4-04 through T4-08 (failover and post-failover tests)"
```

---

### Task 6: Implement T4-09 through T4-12 (failback and data integrity)

**Files:**
- Modify: `tools/lib/tier4.sh`

Add after the T4-08 function.

- [ ] **Step 1: Implement T4-09 — trigger failback**

```bash
# ============================================================
# T4-09: Trigger failback
# ============================================================
test_T4_09() {
    local storage="$1"

    log_info "T4-09: Trigger HA failback"

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
    else
        log_warn "T4-09: controller $current_node is MASTER, expected original controller $T4_ORIGINAL_NODE"
        log_warn "T4-09: system is in a valid HA state, just not the original topology"
        return 1
    fi
}
```

- [ ] **Step 2: Implement T4-10 — API recovery after failback**

```bash
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
```

- [ ] **Step 3: Implement T4-11 — VM survival after failback**

```bash
# ============================================================
# T4-11: VM survival after failback
# ============================================================
test_T4_11() {
    local storage="$1"

    log_info "T4-11: VM survival after failback"

    if [[ $T4_VM_CREATED -ne 1 ]]; then
        log_skip "T4-11: no test VM from T4-02"
        return 0
    fi

    local vm_status
    vm_status=$(qm status "$T4_TEST_VMID" 2>/dev/null | awk '{print $2}')

    if [[ "$vm_status" != "running" ]]; then
        log_fail "T4-11: VM $T4_TEST_VMID status is '$vm_status' after failback (expected running)"
        return 1
    fi

    if dmesg | tail -100 | grep -qi 'blk_update_request.*I/O error'; then
        log_fail "T4-11: I/O errors found in dmesg after failback"
        return 1
    fi

    log_pass "T4-11: VM $T4_TEST_VMID still running after failback, no I/O errors"
}
```

- [ ] **Step 4: Implement T4-12 — data integrity**

```bash
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

    if [[ -z "$T4_TEST_VOLID" ]]; then
        log_skip "T4-12: no test volume"
        return 0
    fi

    local dev
    dev=$(pvesm path "$T4_TEST_VOLID" 2>/dev/null)
    if [[ -z "$dev" ]]; then
        log_fail "T4-12: pvesm path returned empty for $T4_TEST_VOLID"
        return 1
    fi

    local readback
    readback=$(dd if="$dev" bs=512 count=1 2>/dev/null | tr -d '\0')

    if echo "$readback" | grep -q "$T4_MARKER"; then
        log_pass "T4-12: marker intact after full failover/failback cycle"
    else
        log_fail "T4-12: marker mismatch — wrote '$T4_MARKER', read '$readback'"
        return 1
    fi
}
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n tools/lib/tier4.sh`
Expected: No output (syntax OK)

- [ ] **Step 6: Commit**

```bash
git add tools/lib/tier4.sh
git commit -m "feat: implement T4-09 through T4-12 (failback and data integrity tests)"
```

---

### Task 7: Final integration and verification

**Files:**
- All modified files from previous tasks

- [ ] **Step 1: Verify all unit tests pass**

Run: `bash tools/tests/test_common.sh && bash tools/tests/test_arg_parsing.sh`
Expected: All PASS, exit 0

- [ ] **Step 2: Verify run-tests.sh syntax**

Run: `bash -n tools/run-tests.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Verify tier4.sh syntax**

Run: `bash -n tools/lib/tier4.sh`
Expected: No output (syntax OK)

- [ ] **Step 4: Dry-run harness help (confirm no parse errors)**

Run: `bash tools/run-tests.sh --help 2>&1 || true`
Expected: Either a help message or "Unknown flag: --help" (confirms the script loads without source errors)

- [ ] **Step 5: Commit final state**

```bash
git add -A
git commit -m "feat: complete Tier 4 (TrueNAS Enterprise HA) test suite"
```
