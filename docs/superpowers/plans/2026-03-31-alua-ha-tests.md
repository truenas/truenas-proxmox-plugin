# Tier 5: ALUA + HA Failover Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Tier 5 test suite that validates ALUA path state transitions and dm-multipath I/O continuity during TrueNAS Enterprise HA failover/failback cycles.

**Architecture:** Shared HA helpers (`ha_wait_for_api`, `ha_wait_for_standby`) and a new `parse_multipath_ll` function move to `common.sh`. Tier 4 is refactored to use the renamed helpers. New `tools/lib/tier5.sh` implements 11 ALUA-focused tests. Harness gains `--config G` and Tier 5 detection.

**Tech Stack:** Bash (test harness), Perl one-liner (API shim via `tn_api_call` in common.sh)

**Spec:** `docs/superpowers/specs/2026-03-31-alua-ha-test-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `tools/lib/common.sh` | Modify | Add `ha_wait_for_api`, `ha_wait_for_standby`, `parse_multipath_ll`, HA globals |
| `tools/lib/tier4.sh` | Modify | Replace `T4_FAILOVER_TIMEOUT` etc. with `HA_*` globals, replace `tier4_wait_for_api`/`tier4_wait_for_standby` calls with `ha_*` equivalents, remove the moved functions |
| `tools/lib/tier5.sh` | Create | All Tier 5 test functions: preflight, T5-01 through T5-11, cleanup, `run_tier5` entry point |
| `tools/run-tests.sh` | Modify | Add Config G, `TIER5_AVAILABLE` flag, Tier 5 detection, Tier 5 orchestration |
| `tools/tests/test_arg_parsing.sh` | Modify | Add unit tests for Config G |
| `tools/tests/test_common.sh` | Modify | Add unit tests for `parse_multipath_ll` |

---

### Task 1: Move HA helpers from tier4.sh to common.sh

**Files:**
- Modify: `tools/lib/common.sh`
- Modify: `tools/lib/tier4.sh`
- Test: `tools/tests/test_common.sh`

- [ ] **Step 1: Add HA globals and `ha_wait_for_api` to common.sh**

Add to the end of `tools/lib/common.sh` (after `tn_api_call`):

```bash
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
```

- [ ] **Step 2: Remove the old helpers and globals from tier4.sh**

In `tools/lib/tier4.sh`, remove these lines (the globals):

```
T4_FAILOVER_TIMEOUT=180     # seconds
T4_POLL_INTERVAL=5          # seconds
T4_STANDBY_TIMEOUT=300      # seconds to wait for standby to come back
```

And `T4_RECOVERY_ELAPSED=0`.

Remove the entire `tier4_wait_for_api()` function (lines 120-137 approx).

Remove the entire `tier4_wait_for_standby()` function (lines 206-228 approx).

- [ ] **Step 3: Update all references in tier4.sh**

Replace throughout `tools/lib/tier4.sh`:
- `T4_FAILOVER_TIMEOUT` → `HA_FAILOVER_TIMEOUT`
- `T4_POLL_INTERVAL` → `HA_POLL_INTERVAL`
- `T4_STANDBY_TIMEOUT` → `HA_STANDBY_TIMEOUT`
- `T4_RECOVERY_ELAPSED` → `HA_RECOVERY_ELAPSED`
- `tier4_wait_for_api` → `ha_wait_for_api`
- `tier4_wait_for_standby` → `ha_wait_for_standby`

- [ ] **Step 4: Verify syntax and tests**

Run: `bash -n tools/lib/tier4.sh && bash -n tools/lib/common.sh && bash tools/tests/test_common.sh && bash tools/tests/test_arg_parsing.sh`
Expected: All syntax OK, all tests PASS

- [ ] **Step 5: Commit**

```bash
git add tools/lib/common.sh tools/lib/tier4.sh
git commit -m "refactor: move HA failover helpers from tier4.sh to common.sh

Renames tier4_wait_for_api -> ha_wait_for_api, tier4_wait_for_standby ->
ha_wait_for_standby, and T4_FAILOVER_TIMEOUT/T4_POLL_INTERVAL/etc to
HA_* globals. These are now shared infrastructure for any tier that
needs to trigger and wait for HA failover (Tier 4, upcoming Tier 5)."
```

---

### Task 2: Add `parse_multipath_ll` helper to common.sh

**Files:**
- Modify: `tools/lib/common.sh`
- Modify: `tools/tests/test_common.sh`

- [ ] **Step 1: Write the test for `parse_multipath_ll`**

Add to `tools/tests/test_common.sh`, before the final results summary:

```bash
# --- parse_multipath_ll ---
# Feed it sample multipath -ll output and verify it extracts the right fields
SAMPLE_MP='mpathb (36589cfc000000abc) dm-4 TrueNAS,iSCSI Disk
size=100G features='"'"'1 queue_if_no_path'"'"' hwhandler='"'"'1 alua'"'"' wp=rw
|-+- policy='"'"'service-time 0'"'"' prio=50 status=active
| `- 3:0:0:1 sdc 8:32 active ready running
`-+- policy='"'"'service-time 0'"'"' prio=10 status=enabled
  `- 4:0:0:1 sdd 8:48 active ready running'

eval "$(echo "$SAMPLE_MP" | parse_multipath_ll)"
assert_eq "mp dm_device"    "dm-4"      "$MP_DM_DEVICE"
assert_eq "mp hwhandler"    "1 alua"    "$MP_HWHANDLER"
assert_eq "mp prio_high"    "50"        "$MP_PRIO_HIGH"
assert_eq "mp prio_low"     "10"        "$MP_PRIO_LOW"
assert_eq "mp path_high"    "sdc"       "$MP_PATH_HIGH"
assert_eq "mp path_low"     "sdd"       "$MP_PATH_LOW"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/tests/test_common.sh`
Expected: FAIL — `parse_multipath_ll: command not found`

- [ ] **Step 3: Implement `parse_multipath_ll` in common.sh**

Add to `tools/lib/common.sh`, before the HA helpers section:

```bash
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
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tools/tests/test_common.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add tools/lib/common.sh tools/tests/test_common.sh
git commit -m "feat: add parse_multipath_ll helper for extracting ALUA path state"
```

---

### Task 3: Add Config G and Tier 5 detection to run-tests.sh

**Files:**
- Modify: `tools/run-tests.sh`
- Modify: `tools/tests/test_arg_parsing.sh`

- [ ] **Step 1: Write unit tests for Config G**

Add to `tools/tests/test_arg_parsing.sh`, before the final results summary:

```bash
# --- Config G ---
parse_args --storage mystore --config G --yes
assert_eq "parse --config G"  "G" "$ARG_CONFIG"

assert_eq "config G tiers" "1 5"         "$(config_required_tiers G)"
assert_eq "config G gates" "T1-01 T5-04" "$(config_hard_gates G)"

# Updated 'all' includes tier 5
assert_eq "config all tiers" "1 2 3 4 5"             "$(config_required_tiers all)"
assert_eq "config all gates" "T1-01 T2-03 T3-04 T4-04 T5-04" "$(config_hard_gates all)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/tests/test_arg_parsing.sh`
Expected: FAIL — Config G returns default, 'all' doesn't include tier 5

- [ ] **Step 3: Update `config_required_tiers` and `config_hard_gates` in run-tests.sh**

```bash
config_required_tiers() {
    case "$1" in
        A)   echo "1"         ;;
        D)   echo "1 2"       ;;
        F)   echo "1 3"       ;;
        H)   echo "1 4"       ;;
        G)   echo "1 5"       ;;
        all) echo "1 2 3 4 5" ;;
        *)   echo "1"         ;;
    esac
}

config_hard_gates() {
    case "$1" in
        A)   echo "T1-01"                         ;;
        D)   echo "T1-01 T2-03"                   ;;
        F)   echo "T1-01 T3-04"                   ;;
        H)   echo "T1-01 T4-04"                   ;;
        G)   echo "T1-01 T5-04"                   ;;
        all) echo "T1-01 T2-03 T3-04 T4-04 T5-04" ;;
        *)   echo "T1-01"                         ;;
    esac
}
```

- [ ] **Step 4: Update existing 'all' assertions in test_arg_parsing.sh**

Change the existing assertions:

```bash
assert_eq "config all tiers" "1 2 3 4 5" "$(config_required_tiers all)"
assert_eq "config all gates" "T1-01 T2-03 T3-04 T4-04 T5-04" "$(config_hard_gates all)"
```

Remove the duplicate 'all' assertions from the Config G block (Step 1 already tests them).

- [ ] **Step 5: Add `TIER5_AVAILABLE` global and detection**

In `tools/run-tests.sh`, add after `TIER4_AVAILABLE=0`:

```bash
TIER5_AVAILABLE=0
```

After the Tier 4 detection block (after `fi` on the TIER4_AVAILABLE block), add:

```bash
# Tier 5 detection: HA + multipath + dual portals
if [[ "${TIER4_AVAILABLE:-0}" -eq 1 ]] && \
   grep -q 'use_multipath 1' /etc/pve/storage.cfg 2>/dev/null; then
    local _portal_count
    _portal_count=$(read_storage_cfg "$ARG_STORAGE" "portals" | tr ',' '\n' | grep -c '.' || true)
    if [[ "${_portal_count:-0}" -ge 2 ]]; then
        TIER5_AVAILABLE=1
    fi
fi
```

- [ ] **Step 6: Update hardware validation for Tier 5**

In the hardware validation loop, add a case for tier 5 alongside the tier 4 case:

```bash
        if [[ "$t" -eq 4 ]]; then
            if [[ "${TIER4_AVAILABLE:-0}" -ne 1 ]]; then
                log_fail "Hardware insufficient for Config $ARG_CONFIG: Tier 4 (HA TrueNAS) required but not detected"
                exit 2
            fi
        elif [[ "$t" -eq 5 ]]; then
            if [[ "${TIER5_AVAILABLE:-0}" -ne 1 ]]; then
                log_fail "Hardware insufficient for Config $ARG_CONFIG: Tier 5 (ALUA + HA) required but not detected"
                exit 2
            fi
        elif [[ "$t" -gt "$MAX_TIER" ]]; then
```

- [ ] **Step 7: Add tier5.sh source, run_tier dispatch, and run_tier 5 call**

Add source line:

```bash
source "$SCRIPT_DIR/lib/tier5.sh"
```

Update `run_tier` to handle tier 5:

```bash
    if [[ "$tier" -eq 4 ]]; then
        if [[ "${TIER4_AVAILABLE:-0}" -ne 1 ]]; then
            log_skip "Tier 4 — HA TrueNAS not detected"
            return 0
        fi
    elif [[ "$tier" -eq 5 ]]; then
        if [[ "${TIER5_AVAILABLE:-0}" -ne 1 ]]; then
            log_skip "Tier 5 — ALUA + HA not detected"
            return 0
        fi
    elif [[ "$tier" -gt "$MAX_TIER" ]]; then
```

Add to the case statement:

```bash
        5) run_tier5 "$ARG_STORAGE" "$ARG_CONFIG" ;;
```

Add after `run_tier 4`:

```bash
run_tier 5
```

- [ ] **Step 8: Run tests**

Run: `bash tools/tests/test_arg_parsing.sh`
Expected: All PASS

- [ ] **Step 9: Commit**

```bash
git add tools/run-tests.sh tools/tests/test_arg_parsing.sh
git commit -m "feat: add Config G and Tier 5 (ALUA + HA) to test harness"
```

---

### Task 4: Create tier5.sh — preflight, helpers, and skeleton

**Files:**
- Create: `tools/lib/tier5.sh`

- [ ] **Step 1: Create tier5.sh with globals, preflight, cleanup, and entry point**

Create `tools/lib/tier5.sh`:

```bash
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
T5_TEST_VMID=9750
T5_IO_PID=""
T5_IO_LOG=""

# ============================================================
# Pre-flight checks for Tier 5
# ============================================================
tier5_preflight() {
    local storage="$1"

    log_info "Tier 5 pre-flight checks..."

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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tools/lib/tier5.sh`
Expected: No output (syntax OK — undefined test functions are called but bash doesn't check at parse time)

- [ ] **Step 3: Commit**

```bash
git add tools/lib/tier5.sh
git commit -m "feat: add tier5.sh skeleton with preflight, cleanup, I/O helpers, and entry point"
```

---

### Task 5: Implement T5-01 through T5-07 (baseline and failover)

**Files:**
- Modify: `tools/lib/tier5.sh`

Add all test functions between the `tier5_stop_io` helper and the `run_tier5` entry point.

- [ ] **Step 1: Implement T5-01 — ALUA path state baseline**

```bash
# ============================================================
# T5-01: ALUA path state baseline
# ============================================================
test_T5_01() {
    local storage="$1"

    log_info "T5-01: ALUA path state baseline"

    # Get first multipath device with ALUA
    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)

    # Parse the first ALUA device
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

    # Record which HA controller is MASTER
    local node
    node=$(tn_api_call "$storage" "failover.node" 2>/dev/null | tr -d '"')
    T5_ORIGINAL_NODE="$node"

    log_pass "T5-01: ALUA baseline — $MP_PATH_HIGH (prio=50), $MP_PATH_LOW (prio=10), dm=$T5_DM_DEVICE, controller=$node"
}
```

- [ ] **Step 2: Implement T5-02 — create test volume on dm-multipath**

```bash
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

    # Verify this device has two path groups in multipath -ll
    local vol_mp
    vol_mp=$(multipath -ll "$dev" 2>/dev/null)
    if ! echo "$vol_mp" | grep -q 'prio=50' || ! echo "$vol_mp" | grep -q 'prio=10'; then
        log_fail "T5-02: volume multipath device doesn't show two ALUA path groups"
        return 1
    fi

    log_pass "T5-02: volume $T5_TEST_VOLID at $dev with dual ALUA path groups"
}
```

- [ ] **Step 3: Implement T5-03 — I/O routing baseline**

```bash
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

    if [[ -z "$T5_ORIGINAL_PATH_HIGH" || -z "$T5_ORIGINAL_PATH_LOW" ]]; then
        log_skip "T5-03: no path info from T5-01"
        return 0
    fi

    local dev
    dev=$(pvesm path "$T5_TEST_VOLID" 2>/dev/null)

    # Capture write I/O counts before
    local high_before low_before
    high_before=$(tier5_get_write_ios "$T5_ORIGINAL_PATH_HIGH")
    low_before=$(tier5_get_write_ios "$T5_ORIGINAL_PATH_LOW")

    # Start background I/O — this will continue running through failover
    tier5_start_io "$dev"

    # Let I/O run for 5 seconds to accumulate measurable stats
    sleep 5

    # Capture write I/O counts after
    local high_after low_after
    high_after=$(tier5_get_write_ios "$T5_ORIGINAL_PATH_HIGH")
    low_after=$(tier5_get_write_ios "$T5_ORIGINAL_PATH_LOW")

    local high_delta=$(( high_after - high_before ))
    local low_delta=$(( low_after - low_before ))

    log_info "T5-03: I/O delta — optimized ($T5_ORIGINAL_PATH_HIGH): $high_delta writes, non-optimized ($T5_ORIGINAL_PATH_LOW): $low_delta writes"

    if [[ "$high_delta" -gt 0 && "$high_delta" -gt "$low_delta" ]]; then
        log_pass "T5-03: I/O routed through Active Optimized path ($T5_ORIGINAL_PATH_HIGH: $high_delta writes vs $T5_ORIGINAL_PATH_LOW: $low_delta writes)"
    else
        log_fail "T5-03: I/O not preferring Active Optimized path (high=$high_delta, low=$low_delta)"
        return 1
    fi
}
```

- [ ] **Step 4: Implement T5-04 — trigger failover (hard gate)**

```bash
# ============================================================
# T5-04: Trigger failover — HARD GATE
# ============================================================
test_T5_04() {
    local storage="$1"

    log_info "T5-04: Trigger HA failover"

    log_info "T5-04: calling failover.become_passive..."
    tn_api_call "$storage" "failover.become_passive" &>/dev/null || true

    log_info "T5-04: waiting for API recovery on VIP (timeout: ${HA_FAILOVER_TIMEOUT}s)..."

    if ! ha_wait_for_api "$storage" "$HA_FAILOVER_TIMEOUT"; then
        log_fail "T5-04: HARD GATE — API did not recover within ${HA_FAILOVER_TIMEOUT}s"
        HARD_GATE_FAILED=1
        return 2
    fi

    log_info "T5-04: API responded after ${HA_RECOVERY_ELAPSED}s"

    local new_node
    new_node=$(tn_api_call "$storage" "failover.node" 2>/dev/null | tr -d '"')

    if [[ "$new_node" != "$T5_ORIGINAL_NODE" ]]; then
        log_pass "T5-04: failover complete — was controller $T5_ORIGINAL_NODE, now $new_node (${HA_RECOVERY_ELAPSED}s)"
    else
        log_fail "T5-04: HARD GATE — still on controller $new_node (expected different)"
        HARD_GATE_FAILED=1
        return 2
    fi
}
```

- [ ] **Step 5: Implement T5-05 — ALUA state transition**

```bash
# ============================================================
# T5-05: ALUA state transition after failover
# ============================================================
test_T5_05() {
    local storage="$1"

    log_info "T5-05: ALUA state transition after failover"

    # Poll multipath -ll for up to 60s for ALUA priorities to swap
    local swapped=0
    local start_time
    start_time=$(date +%s)

    while [[ $(( $(date +%s) - start_time )) -lt 60 ]]; do
        local mp_output
        mp_output=$(multipath -ll 2>/dev/null)
        eval "$(echo "$mp_output" | parse_multipath_ll)"

        # The path that was low priority should now be high priority
        if [[ "$MP_PATH_HIGH" == "$T5_ORIGINAL_PATH_LOW" && "$MP_PRIO_HIGH" -eq 50 ]]; then
            swapped=1
            break
        fi
        sleep 5
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $swapped -eq 1 ]]; then
        log_pass "T5-05: ALUA priorities swapped in ${elapsed}s — $MP_PATH_HIGH now prio=50, $MP_PATH_LOW now prio=10"
    else
        eval "$(multipath -ll 2>/dev/null | parse_multipath_ll)"
        log_fail "T5-05: ALUA priorities did not swap within 60s — $MP_PATH_HIGH prio=$MP_PRIO_HIGH, $MP_PATH_LOW prio=$MP_PRIO_LOW"
        return 1
    fi
}
```

- [ ] **Step 6: Implement T5-06 — multipath I/O continuity**

```bash
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
```

- [ ] **Step 7: Implement T5-07 — I/O routing after failover**

```bash
# ============================================================
# T5-07: I/O routing after failover
# ============================================================
test_T5_07() {
    local storage="$1"

    log_info "T5-07: I/O routing after failover"

    # After failover, the originally Non-Optimized path should now carry I/O
    # Parse current multipath state to get the new high-priority path
    eval "$(multipath -ll 2>/dev/null | parse_multipath_ll)"

    local new_high="$MP_PATH_HIGH"
    local new_low="$MP_PATH_LOW"

    local high_before low_before
    high_before=$(tier5_get_write_ios "$new_high")
    low_before=$(tier5_get_write_ios "$new_low")

    sleep 5

    local high_after low_after
    high_after=$(tier5_get_write_ios "$new_high")
    low_after=$(tier5_get_write_ios "$new_low")

    local high_delta=$(( high_after - high_before ))
    local low_delta=$(( low_after - low_before ))

    log_info "T5-07: I/O delta — new optimized ($new_high): $high_delta writes, new non-optimized ($new_low): $low_delta writes"

    if [[ "$high_delta" -gt 0 && "$high_delta" -gt "$low_delta" ]]; then
        log_pass "T5-07: I/O routed through new Active Optimized path ($new_high: $high_delta vs $new_low: $low_delta)"
    else
        log_fail "T5-07: I/O not preferring new Active Optimized path (high=$high_delta, low=$low_delta)"
        return 1
    fi
}
```

- [ ] **Step 8: Verify syntax**

Run: `bash -n tools/lib/tier5.sh`
Expected: No output (syntax OK)

- [ ] **Step 9: Commit**

```bash
git add tools/lib/tier5.sh
git commit -m "feat: implement T5-01 through T5-07 (ALUA baseline and failover tests)"
```

---

### Task 6: Implement T5-08 through T5-11 (failback and health)

**Files:**
- Modify: `tools/lib/tier5.sh`

Add after T5-07, before `run_tier5`.

- [ ] **Step 1: Implement T5-08 — trigger failback**

```bash
# ============================================================
# T5-08: Wait for standby, trigger failback
# ============================================================
test_T5_08() {
    local storage="$1"

    log_info "T5-08: Trigger HA failback"

    log_info "T5-08: calling failover.become_passive..."
    tn_api_call "$storage" "failover.become_passive" &>/dev/null || true

    log_info "T5-08: waiting for API recovery on VIP (timeout: ${HA_FAILOVER_TIMEOUT}s)..."

    if ! ha_wait_for_api "$storage" "$HA_FAILOVER_TIMEOUT"; then
        log_warn "T5-08: API did not recover within ${HA_FAILOVER_TIMEOUT}s after failback"
        return 1
    fi

    log_info "T5-08: API responded after ${HA_RECOVERY_ELAPSED}s"

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
```

- [ ] **Step 2: Implement T5-09 — ALUA state restored**

```bash
# ============================================================
# T5-09: ALUA state restored after failback
# ============================================================
test_T5_09() {
    local storage="$1"

    log_info "T5-09: ALUA state restored after failback"

    # Poll for up to 60s for priorities to return to baseline
    local restored=0
    local start_time
    start_time=$(date +%s)

    while [[ $(( $(date +%s) - start_time )) -lt 60 ]]; do
        eval "$(multipath -ll 2>/dev/null | parse_multipath_ll)"

        if [[ "$MP_PATH_HIGH" == "$T5_ORIGINAL_PATH_HIGH" && "$MP_PRIO_HIGH" -eq 50 ]]; then
            restored=1
            break
        fi
        sleep 5
    done

    local elapsed=$(( $(date +%s) - start_time ))

    if [[ $restored -eq 1 ]]; then
        log_pass "T5-09: ALUA priorities restored to baseline in ${elapsed}s — $T5_ORIGINAL_PATH_HIGH back to prio=50"
    else
        eval "$(multipath -ll 2>/dev/null | parse_multipath_ll)"
        log_fail "T5-09: ALUA priorities not restored within 60s — $MP_PATH_HIGH prio=$MP_PRIO_HIGH, $MP_PATH_LOW prio=$MP_PRIO_LOW (expected $T5_ORIGINAL_PATH_HIGH at prio=50)"
        return 1
    fi
}
```

- [ ] **Step 3: Implement T5-10 — multipath I/O continuity after failback**

```bash
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
```

- [ ] **Step 4: Implement T5-11 — path group health**

```bash
# ============================================================
# T5-11: Path group health
# ============================================================
test_T5_11() {
    local storage="$1"

    log_info "T5-11: Final path group health check"

    local mp_output
    mp_output=$(multipath -ll 2>/dev/null)

    # No failed, faulty, or ghost paths
    if echo "$mp_output" | grep -qi 'faulty\|failed\|ghost'; then
        log_fail "T5-11: unhealthy paths found in multipath -ll:"
        echo "$mp_output" | grep -iE 'faulty|failed|ghost' | while IFS= read -r line; do
            log_info "T5-11:   $line"
        done
        return 1
    fi

    # Parse and verify structure
    eval "$(echo "$mp_output" | parse_multipath_ll)"

    if [[ "$MP_PRIO_HIGH" -ne 50 || "$MP_PRIO_LOW" -ne 10 ]]; then
        log_fail "T5-11: unexpected priorities — high=$MP_PRIO_HIGH (expected 50), low=$MP_PRIO_LOW (expected 10)"
        return 1
    fi

    if [[ "$MP_HWHANDLER" != "1 alua" ]]; then
        log_fail "T5-11: hwhandler='$MP_HWHANDLER' (expected '1 alua')"
        return 1
    fi

    log_pass "T5-11: all paths healthy, ALUA priorities correct (50/10), hwhandler='1 alua'"
}
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n tools/lib/tier5.sh`
Expected: No output (syntax OK)

- [ ] **Step 6: Run all unit tests**

Run: `bash tools/tests/test_common.sh && bash tools/tests/test_arg_parsing.sh`
Expected: All PASS

- [ ] **Step 7: Verify harness loads**

Run: `bash tools/run-tests.sh --help 2>&1 || true`
Expected: "Unknown flag: --help" (confirms script loads without source errors)

- [ ] **Step 8: Commit**

```bash
git add tools/lib/tier5.sh
git commit -m "feat: implement T5-08 through T5-11 (ALUA failback and path health tests)"
```
