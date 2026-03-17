# Test Harness Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a three-tier automated test harness (`tools/run-tests.sh`) that orchestrates the full TrueNAS Proxmox plugin test suite, auto-detects hardware tier, enforces release gate criteria, and produces a unified pass/fail summary.

**Architecture:** Shared utilities in `tools/lib/common.sh`; one library file per tier (`tier1.sh`, `tier2.sh`, `tier3.sh`) sourced by the entry point `tools/run-tests.sh`; a simple inline bash test runner in `tools/tests/` validates utility functions without external dependencies. The existing `tools/dev-truenas-plugin-full-function-test.sh` is called by `tier1.sh` unchanged.

**Tech Stack:** Bash 5, Proxmox CLI tools (`pvesh`, `pvesm`, `pvecm`, `qm`), `iptables`, `multipathd`/`multipath`, `nvme-cli`, standard Debian/Proxmox host environment.

---

## Chunk 1: Shared Utilities and Entry-Point Skeleton

### Task 1: `tools/lib/common.sh` — shared utilities

**Files:**
- Create: `tools/lib/common.sh`
- Create: `tools/tests/test_common.sh`

- [ ] **Step 1: Write the failing unit tests**

```bash
# tools/tests/test_common.sh
#!/usr/bin/env bash
# Standalone unit tests for tools/lib/common.sh — no external dependencies.
set -uo pipefail
PASS=0; FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "[PASS] $desc"; PASS=$((PASS+1))
    else
        echo "[FAIL] $desc — expected='$expected' got='$actual'"; FAIL=$((FAIL+1))
    fi
}

assert_match() {
    local desc="$1" pattern="$2" string="$3"
    if [[ "$string" =~ $pattern ]]; then
        echo "[PASS] $desc"; PASS=$((PASS+1))
    else
        echo "[FAIL] $desc — pattern='$pattern' did not match '$string'"; FAIL=$((FAIL+1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- log_* output format ---
out=$(LOG_FILE=/dev/null PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0 log_pass "hello")
assert_match "log_pass prefix"   '^\[PASS\]' "$out"

out=$(LOG_FILE=/dev/null PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0 log_fail "hello")
assert_match "log_fail prefix"   '^\[FAIL\]' "$out"

out=$(LOG_FILE=/dev/null PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0 log_skip "hello")
assert_match "log_skip prefix"   '^\[SKIP\]' "$out"

out=$(LOG_FILE=/dev/null PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0 log_warn "hello")
assert_match "log_warn prefix"   '^\[WARN\]' "$out"

out=$(LOG_FILE=/dev/null PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0 log_info "hello")
assert_match "log_info prefix"   '^\[INFO\]' "$out"

# --- read_storage_cfg ---
TMP=$(mktemp)
cat >"$TMP" <<'EOF'
: initial_pool_config_file
: 0

truenas-iscsi: TrueNASPlugin
	nodes localhost
	api_host 192.168.1.10
	api_insecure 1
	api_retry_max 5
	use_multipath 1
EOF

val=$(read_storage_cfg_file "$TMP" "truenas-iscsi" "api_host")
assert_eq "read_storage_cfg_file api_host"     "192.168.1.10" "$val"

val=$(read_storage_cfg_file "$TMP" "truenas-iscsi" "api_retry_max")
assert_eq "read_storage_cfg_file api_retry_max" "5" "$val"

val=$(read_storage_cfg_file "$TMP" "truenas-iscsi" "api_retry_delay" "2")
assert_eq "read_storage_cfg_file default"       "2" "$val"

val=$(read_storage_cfg_file "$TMP" "truenas-iscsi" "api_insecure")
assert_eq "read_storage_cfg_file api_insecure"  "1" "$val"

rm -f "$TMP"

# --- retry_window_seconds ---
# With api_retry_max=3, api_retry_delay=1:
#   window = (15 * 3) + (1 * 3) + 30 = 45 + 3 + 30 = 78
val=$(retry_window_seconds 3 1)
assert_eq "retry_window_seconds 3 1" "78" "$val"

# With api_retry_max=5, api_retry_delay=2:
#   window = (15 * 5) + (2 * 5) + 30 = 75 + 10 + 30 = 115
val=$(retry_window_seconds 5 2)
assert_eq "retry_window_seconds 5 2" "115" "$val"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /path/to/truenas-proxmox-plugin
bash tools/tests/test_common.sh
```
Expected: `source: tools/lib/common.sh: No such file or directory` or similar error.

- [ ] **Step 3: Implement `tools/lib/common.sh`**

```bash
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
    found=$(awk -v storage="$storage:" -v key="$key" '
        /^[^ \t]/ { in_section = ($1 == storage) }
        in_section && /^[ \t]/ {
            split($0, parts, /[ \t]+/)
            if (parts[2] == key) { print parts[3]; found=1; exit }
        }
        END { if (!found && default != "") print default }
    ' -v default="$default" "$cfg_file")
    echo "${found:-$default}"
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

# Block outbound TCP to host:port using iptables OUTPUT chain.
# Usage: iptables_block <host> <port>
iptables_block() {
    iptables -A OUTPUT -p tcp --destination "$1" --dport "$2" -j DROP
}

# Remove the OUTPUT chain block for host:port.
# Usage: iptables_unblock <host> <port>
iptables_unblock() {
    iptables -D OUTPUT -p tcp --destination "$1" --dport "$2" -j DROP 2>/dev/null || true
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
```

- [ ] **Step 4: Run unit tests to confirm they pass**

```bash
bash tools/tests/test_common.sh
```
Expected: `Results: N passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tools/lib/common.sh tools/tests/test_common.sh
git commit -m "feat: add common.sh utilities and unit tests for test harness"
```

---

### Task 2: `tools/run-tests.sh` — entry point (arg parsing + hardware detection)

**Files:**
- Create: `tools/run-tests.sh`
- Create: `tools/tests/test_arg_parsing.sh`

- [ ] **Step 1: Write failing tests for argument parsing and hardware detection logic**

```bash
# tools/tests/test_arg_parsing.sh
#!/usr/bin/env bash
# Tests for run-tests.sh argument parsing and helper functions.
set -uo pipefail
PASS=0; FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "[PASS] $desc"; PASS=$((PASS+1))
    else
        echo "[FAIL] $desc — expected='$expected' got='$actual'"; FAIL=$((FAIL+1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
# Source parse functions only — use a UNIT_TEST guard in run-tests.sh
UNIT_TEST=1 source "$SCRIPT_DIR/../run-tests.sh"

# --- parse_args ---
parse_args --storage mystore --config D --tier 2 --yes
assert_eq "parse --storage"  "mystore" "$ARG_STORAGE"
assert_eq "parse --config"   "D"       "$ARG_CONFIG"
assert_eq "parse --tier"     "2"       "$ARG_TIER"
assert_eq "parse --yes"      "1"       "$ARG_YES"

parse_args --storage s2
assert_eq "defaults --config" "all" "$ARG_CONFIG"
assert_eq "defaults --tier"   "all" "$ARG_TIER"
assert_eq "defaults --yes"    "0"   "$ARG_YES"

# --- config_required_tiers ---
assert_eq "config A tiers" "1"     "$(config_required_tiers A)"
assert_eq "config D tiers" "1 2"   "$(config_required_tiers D)"
assert_eq "config F tiers" "1 3"   "$(config_required_tiers F)"
assert_eq "config all tiers" "1 2 3" "$(config_required_tiers all)"

# --- config_hard_gates ---
assert_eq "config A gates" "T1-01"         "$(config_hard_gates A)"
assert_eq "config D gates" "T1-01 T2-03"   "$(config_hard_gates D)"
assert_eq "config F gates" "T1-01 T3-04"   "$(config_hard_gates F)"
assert_eq "config all gates" "T1-01 T2-03 T3-04" "$(config_hard_gates all)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
bash tools/tests/test_arg_parsing.sh
```
Expected: error — `run-tests.sh` does not exist yet.

- [ ] **Step 3: Implement `tools/run-tests.sh` skeleton**

```bash
#!/usr/bin/env bash
# TrueNAS Proxmox Plugin Test Harness
# Usage: tools/run-tests.sh [--storage <name>] [--config <A|D|F|all>] [--tier <1|2|3|all>] [--yes]
#
# Exit codes:
#   0 — all non-skipped required tests passed (including all hard gates)
#   1 — one or more required non-gate tests failed
#   2 — pre-flight abort, hardware insufficient for --config, or hard gate failed
#
# WARNING: Destructive test operations. Run only on a dedicated test environment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Global state
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
HARD_GATE_FAILED=0
LOG_FILE="/tmp/truenas-test-$(date '+%Y%m%d-%H%M%S').log"

# Argument defaults
ARG_STORAGE=""
ARG_CONFIG="all"
ARG_TIER="all"
ARG_YES=0

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --storage) ARG_STORAGE="$2"; shift 2 ;;
            --config)  ARG_CONFIG="$2";  shift 2 ;;
            --tier)    ARG_TIER="$2";    shift 2 ;;
            --yes)     ARG_YES=1;        shift   ;;
            *) echo "Unknown flag: $1" >&2; exit 2 ;;
        esac
    done
}

# ============================================================
# Config helpers
# ============================================================
config_required_tiers() {
    case "$1" in
        A)   echo "1"     ;;
        D)   echo "1 2"   ;;
        F)   echo "1 3"   ;;
        all) echo "1 2 3" ;;
        *)   echo "1"     ;;
    esac
}

config_hard_gates() {
    case "$1" in
        A)   echo "T1-01"             ;;
        D)   echo "T1-01 T2-03"       ;;
        F)   echo "T1-01 T3-04"       ;;
        all) echo "T1-01 T2-03 T3-04" ;;
        *)   echo "T1-01"             ;;
    esac
}

# ============================================================
# Hardware detection
# ============================================================
detect_max_tier() {
    local tier=0

    # Tier 1: pvesh available and storage active
    if command -v pvesh &>/dev/null && \
       pvesm status 2>/dev/null | grep -q "^${ARG_STORAGE:-} "; then
        tier=1
    elif command -v pvesh &>/dev/null && [[ -z "$ARG_STORAGE" ]]; then
        # Storage name not specified but pvesh is present — allow tier 1 with warning
        tier=1
    fi

    # Tier 2: multipath prerequisites
    if [[ $tier -ge 1 ]] && \
       systemctl is-active multipathd &>/dev/null && \
       grep -q 'use_multipath 1' /etc/pve/storage.cfg 2>/dev/null && \
       grep -q 'portals' /etc/pve/storage.cfg 2>/dev/null; then
        tier=2
    fi

    # Tier 3: 3-node cluster, all SSH-reachable
    if [[ $tier -ge 1 ]] && command -v pvecm &>/dev/null; then
        local node_count
        node_count=$(pvecm status 2>/dev/null | awk '/^Nodes:/ {print $2}')
        if [[ "${node_count:-0}" -ge 3 ]]; then
            local all_reach=1
            while IFS= read -r node_ip; do
                ssh_reachable "$node_ip" || { all_reach=0; break; }
            done < <(pvecm nodes 2>/dev/null | awk 'NR>1 {print $3}')
            [[ $all_reach -eq 1 ]] && tier=3
        fi
    fi

    echo "$tier"
}

# ============================================================
# Guard: skip if UNIT_TEST=1 (for unit test sourcing)
# ============================================================
[[ "${UNIT_TEST:-0}" == "1" ]] && return 0 2>/dev/null || true

# ============================================================
# Main
# ============================================================
parse_args "$@"

log_info "TrueNAS Proxmox Plugin Test Harness"
log_info "Log: $LOG_FILE"
log_info "Config: $ARG_CONFIG  Tier: $ARG_TIER  Storage: ${ARG_STORAGE:-<auto>}"

MAX_TIER=$(detect_max_tier)
log_info "Detected max hardware tier: $MAX_TIER"

# Validate hardware against --config requirements
if [[ "$ARG_CONFIG" != "all" ]]; then
    required_tiers=$(config_required_tiers "$ARG_CONFIG")
    for t in $required_tiers; do
        if [[ "$t" -gt "$MAX_TIER" ]]; then
            log_fail "Hardware insufficient for Config $ARG_CONFIG: Tier $t required but max detected is $MAX_TIER"
            exit 2
        fi
    done
fi

# Confirmation prompt (skipped with --yes)
if [[ "$ARG_YES" -ne 1 ]]; then
    echo ""
    echo "WARNING: This harness creates and destroys VMs and storage volumes."
    echo "Run only on a dedicated test environment."
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 2; }
fi

# ============================================================
# Tier orchestration (stubs — implemented in Tasks 3-6)
# ============================================================
source "$SCRIPT_DIR/lib/tier1.sh"
source "$SCRIPT_DIR/lib/tier2.sh"
source "$SCRIPT_DIR/lib/tier3.sh"

START_TIME=$(date +%s)

run_tier() {
    local tier="$1"
    # Determine if this tier should run
    if [[ "$ARG_TIER" != "all" && "$ARG_TIER" != "$tier" ]]; then
        log_info "Tier $tier skipped by --tier flag"
        return 0
    fi
    if [[ "$tier" -gt "$MAX_TIER" ]]; then
        log_skip "Tier $tier — requires hardware not detected"
        return 0
    fi
    case "$tier" in
        1) run_tier1 "$ARG_STORAGE" "$ARG_CONFIG" ;;
        2) run_tier2 "$ARG_STORAGE" "$ARG_CONFIG" ;;
        3) run_tier3 "$ARG_STORAGE" "$ARG_CONFIG" ;;
    esac
}

run_tier 1
run_tier 2
run_tier 3

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# ============================================================
# Summary
# ============================================================
echo ""
echo "======================================"
echo "  Test Summary"
echo "======================================"
echo "  PASS : $PASS_COUNT"
echo "  FAIL : $FAIL_COUNT"
echo "  SKIP : $SKIP_COUNT"
echo "  Time : ${ELAPSED}s"
echo "  Log  : $LOG_FILE"
if [[ "$HARD_GATE_FAILED" -ne 0 ]]; then
    echo "  HARD GATE FAILED — release blocked"
fi
echo "======================================"

if [[ "$HARD_GATE_FAILED" -ne 0 ]]; then
    exit 2
elif [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
bash tools/tests/test_arg_parsing.sh
```
Expected: `Results: N passed, 0 failed`

- [ ] **Step 5: Make harness executable and commit**

```bash
chmod +x tools/run-tests.sh
git add tools/run-tests.sh tools/tests/test_arg_parsing.sh
git commit -m "feat: add run-tests.sh entry point with arg parsing and hardware detection"
```

---

## Chunk 2: Tier 1 and Tier 2 Library Files

### Task 3: `tools/lib/tier1.sh` — core functional tests (T1-01 through T1-07)

**Files:**
- Create: `tools/lib/tier1.sh`

Each test function follows the signature `test_T1_NN()` and calls `log_pass`/`log_fail`/`log_skip`. The `run_tier1` entry point calls pre-flight checks, then the existing script wrapper, then T1-01 through T1-07.

- [ ] **Step 1: Write `tools/lib/tier1.sh`**

```bash
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
    local plugin_file="/usr/share/perl5/PVE/Storage/TrueNASPlugin.pm"
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
    # Run the existing script; capture output; translate [TEST] → [INFO]
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

    local start_time
    start_time=$(date +%s)

    # Trigger pvesm status in background
    ( pvesm status "$storage" &>/dev/null ) &
    local bg_pid=$!

    sleep 20  # Exceeds single connect timeout — ensures at least one retry fires

    # Unblock
    iptables_unblock "$api_host" 443

    # Wait for background job within the computed window
    local waited=0
    while kill -0 "$bg_pid" 2>/dev/null; do
        sleep 2
        waited=$(($(date +%s) - start_time))
        if [[ "$waited" -gt "$window" ]]; then
            kill "$bg_pid" 2>/dev/null || true
            log_fail "T1-02: pvesm status did not recover within ${window}s window"
            return 1
        fi
    done

    if wait "$bg_pid"; then
        local elapsed=$(( $(date +%s) - start_time ))
        log_pass "T1-02: pvesm status recovered after ${elapsed}s (window: ${window}s)"
        return 0
    else
        log_fail "T1-02: pvesm status exited non-zero after unblock"
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

    # Write a known marker (will not affect a running VM — volume is unmounted)
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
        # Insert 'debug 1' after the storage block header line
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
    done &

    wait

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
```

- [ ] **Step 2: Syntax-check the file**

```bash
bash -n tools/lib/tier1.sh
```
Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add tools/lib/tier1.sh
git commit -m "feat: implement tier1.sh — core functional tests T1-01 through T1-07"
```

---

### Task 4: `tools/lib/tier2.sh` — multipath and ALUA tests (T2-01 through T2-09)

**Files:**
- Create: `tools/lib/tier2.sh`

- [ ] **Step 1: Write `tools/lib/tier2.sh`**

```bash
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
    pvesh post /nodes/localhost/storage/"$storage"/content \
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
    log_warn "T2-04: Pass criterion: Active Optimized path ≥90% of write ops; Active Non-Optimized ≤10%."
    log_warn "T2-04: Record raw iostat output in the test log before marking pass/fail."
    log_skip "T2-04: automated execution not possible — manual verification required"
}

# ============================================================
# T2-05: Path failure — I/O continues with one path down
# ============================================================
test_T2_05() {
    local storage="$1"
    local portal1_ip
    portal1_ip=$(read_storage_cfg "$storage" "portal" | cut -d',' -f1)

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
    pvesh post /nodes/localhost/storage/"$storage"/content \
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
        log_pass "T2-09: replacement_timeout=${timeout} (≤15s)"
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
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n tools/lib/tier2.sh
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tools/lib/tier2.sh
git commit -m "feat: implement tier2.sh — multipath and ALUA tests T2-01 through T2-09"
```

---

## Chunk 3: Tier 3, Harness Wiring, and Test Plan Document

### Task 5: `tools/lib/tier3.sh` — cluster and migration tests (T3-01 through T3-09)

**Files:**
- Create: `tools/lib/tier3.sh`

- [ ] **Step 1: Write `tools/lib/tier3.sh`**

```bash
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

    # Need ≥3 nodes in cluster
    local node_count
    node_count=$(pvecm status 2>/dev/null | awk '/^Nodes:/ {print $2}')
    if [[ "${node_count:-0}" -lt 3 ]]; then
        log_warn "Tier 3 pre-flight: cluster has ${node_count:-0} nodes (need ≥3) — skipping Tier 3"
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
                # This is a warning, not a hard abort for pre-flight
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
        # Copy installer to remote and run (or assume it's already installed)
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
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n tools/lib/tier3.sh
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tools/lib/tier3.sh
git commit -m "feat: implement tier3.sh — cluster and migration tests T3-01 through T3-09"
```

---

### Task 6: End-to-end harness validation

**Files:**
- Modify: `tools/run-tests.sh` (stub tier source blocks already in place from Task 2)
- Verify wiring is correct

- [ ] **Step 1: Syntax-check all files together**

```bash
bash -n tools/run-tests.sh
bash -n tools/lib/common.sh
bash -n tools/lib/tier1.sh
bash -n tools/lib/tier2.sh
bash -n tools/lib/tier3.sh
```
Expected: no output from any file.

- [ ] **Step 2: Verify the unit test suite still passes**

```bash
bash tools/tests/test_common.sh && bash tools/tests/test_arg_parsing.sh
```
Expected: `Results: N passed, 0 failed` for both.

- [ ] **Step 3: Dry-run help output**

```bash
# Verify the harness at least starts and shows args before prompting
UNIT_TEST=0 bash tools/run-tests.sh --storage doesnotexist --config A --tier 1 <<< "n"
```
Expected: `[INFO] TrueNAS Proxmox Plugin Test Harness` followed by abort (user answered `n`).

- [ ] **Step 4: Commit**

```bash
git add tools/run-tests.sh
git commit -m "feat: wire tier orchestration and confirm end-to-end harness structure"
```

---

### Task 7: `wiki/Test-Plan.md` — operator-facing test plan document

**Files:**
- Create: `wiki/Test-Plan.md`

- [ ] **Step 1: Write `wiki/Test-Plan.md`**

```markdown
# TrueNAS Proxmox Plugin — Test Plan

> This is the executable test plan. For risk analysis and background on ALUA/multipath requirements, see `wiki/Testing-Requirements.md`.

---

## 1. Overview

This plan covers functional, multipath, and cluster testing for the TrueNAS Proxmox VE Storage Plugin. Tests are organized in three hardware tiers. The automated harness (`tools/run-tests.sh`) runs all tiers that the available hardware supports.

Three hardware configurations are required for every release:

| Config | Environment | Release Gate |
|--------|-------------|--------------|
| A | Single-node iSCSI, no multipath, Proxmox 8.x | Required |
| D | 3-node iSCSI cluster + multipath, Proxmox 9.x | Required |
| F | 3-node NVMe/TCP cluster, Proxmox 9.x | Required |

Configs B, C, and E are advisory — run them when hardware is available but they do not block a release.

---

## 2. Hardware Configuration Matrix

| ID | Transport | Multipath | Nodes | Proxmox | TrueNAS | Release Gate |
|----|-----------|-----------|-------|---------|---------|--------------|
| A  | iSCSI     | off       | 1     | 8.x     | 25.10+  | Required |
| B  | iSCSI     | on (2p)   | 1     | 8.x     | 25.10+  | Advisory |
| C  | iSCSI     | on (2p)   | 3     | 8.x     | 25.10+  | Advisory |
| D  | iSCSI     | on (2p)   | 3     | 9.x     | 25.10+  | Required |
| E  | NVMe/TCP  | kernel    | 1     | 9.x     | 25.10+  | Advisory |
| F  | NVMe/TCP  | kernel    | 3     | 9.x     | 25.10+  | Required |

---

## 3. Running the Harness

### Prerequisites

- Run as root on a Proxmox VE node
- Plugin installed: `/usr/share/perl5/PVE/Storage/TrueNASPlugin.pm`
- Storage configured and active in `pvesm status`
- **Test environment only** — the harness creates and destroys VMs and volumes

### Command Reference

```bash
# Run all tiers auto-detected from hardware, prompt before running
tools/run-tests.sh --storage <name>

# Run Config A gates only (Tier 1, single-node iSCSI)
tools/run-tests.sh --storage <name> --config A --yes

# Run Config D gates (Tier 1 + Tier 2, iSCSI cluster + multipath)
tools/run-tests.sh --storage <name> --config D --yes

# Run Config F gates (Tier 1 + Tier 3, NVMe/TCP cluster)
tools/run-tests.sh --storage <name> --config F --yes

# Run only Tier 2 tests regardless of config
tools/run-tests.sh --storage <name> --tier 2 --yes
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--storage <name>` | (required) | Proxmox storage ID configured for TrueNAS plugin |
| `--config <A\|D\|F\|all>` | `all` | Hardware config context; validates hardware and sets transport skip rules |
| `--tier <1\|2\|3\|all>` | `all` | Override tier selection; overrides `--config` tier logic |
| `--yes` | off | Skip confirmation prompt |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All non-skipped required tests passed |
| 1 | One or more required non-gate tests failed |
| 2 | Pre-flight abort, hardware insufficient for `--config`, or hard gate failed |

### Output Tokens

| Token | Meaning |
|-------|---------|
| `[PASS]` | Test passed |
| `[FAIL]` | Test failed — review and fix before release |
| `[SKIP]` | Test not applicable (hardware not present or transport mismatch) |
| `[WARN]` | Non-blocking advisory; log and investigate |
| `[INFO]` | Informational — no action required |

### Log File

Timestamped log written to `/tmp/truenas-test-YYYYMMDD-HHMMSS.log`. Submit with any bug reports.

---

## 4. Hardware Tiers

### Tier 1 — Core Functional (All Configs)

**Hardware:** Any single Proxmox node with active TrueNAS storage.
**Runtime:** ~5 minutes.

The harness detects Tier 1 when `pvesh` is available and the specified storage is active in `pvesm status`.

### Tier 2 — Multipath and ALUA (Configs B, C, D)

**Hardware:** Tier 1 + two NICs connected to separate TrueNAS iSCSI portals + `multipath-tools` installed.
**Runtime:** ~15 minutes additional.

The harness detects Tier 2 when `multipathd` is active, `use_multipath 1` is in `storage.cfg`, and a `portals` key is present.

Tier 2 is not required for Config F (NVMe/TCP uses kernel-native multipath, not `dm-multipath`).

### Tier 3 — Cluster and Migration (Configs C, D, F)

**Hardware:** Tier 1 + 3-node Proxmox cluster, all nodes SSH-reachable as root without a password prompt.
**Runtime:** ~20 minutes additional.

The harness detects Tier 3 when `pvecm status` shows ≥3 nodes and all peers are SSH-reachable.

**Prerequisite:** Set up passwordless SSH between all cluster nodes before running Tier 3:
```bash
# On each node, copy your root SSH key to all peers
ssh-copy-id root@<peer-node>
```

### Tier Override

`--tier` overrides `--config` tier logic. Use to run a single tier in isolation during development:
```bash
tools/run-tests.sh --storage mystore --tier 2 --yes
```

---

## 5. Test Case Reference

### Tier 1

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T1-core | Existing script: storage status, create/list/resize/delete, snapshot, clone, VM start/stop (8 sub-tests) | Yes | — |
| T1-01 | TLS config audit — `api_insecure 1` must not be present | Yes | **Exit 2** |
| T1-02 | API retry after connection loss — `pvesm status` recovers within computed window | Yes | — |
| T1-03 | Snapshot rollback data integrity | Yes | — |
| T1-04 | Orphan detection — clean deletion (`--purge`) leaves zero orphans | Yes | — |
| T1-05 | Orphan detection — `qm destroy` without `--purge` detected by health check | Yes | — |
| T1-06 | Debug logging — `debug 1` produces `[TrueNAS]` entries in `journald` | Yes | — |
| T1-07 | Volume naming uniqueness — 5 disks in rapid succession get distinct names | Yes | — |

### Tier 2

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T2-01 | dm-multipath map creation — LUN appears as `/dev/mapper/mpathX` | Yes | — |
| T2-02 | Plugin returns mapper device path from `pvesm path` | Yes | — |
| T2-03 | ALUA hardware handler — `hwhandler='1 alua'` in `multipath -ll` | Yes | **Exit 2** |
| T2-04 | Optimized path carries ≥90% of write I/O (iostat verification) | **Manual** | — |
| T2-05 | Path failure — VM stays running when primary portal is blocked | Yes | — |
| T2-06 | Failback — Active Optimized path restored within 60s of portal unblock | Yes | — |
| T2-07 | Stale map cleanup — dm map removed after volume deletion | Yes | — |
| T2-08 | Silent fallback detection — pvedaemon logs warning when dm map removed externally | Yes | — |
| T2-09 | `replacement_timeout` ≤ 15s in `/etc/iscsi/iscsid.conf` | Yes | — |

### Tier 3

| ID | Description | Automated | Hard Gate |
|----|-------------|-----------|-----------|
| T3-01 | Shared storage visibility — volume created on node 1 visible on nodes 2 and 3 | Yes | — |
| T3-02 | Concurrent VM creation on two nodes — no lock timeouts | Yes | — |
| T3-03 | Live migration (iSCSI) — VM migrates online; disk path is mapper device on destination | Yes (Config D) | — |
| T3-04 | Live migration (NVMe/TCP) — VM migrates online; NVMe subsystem connected on destination | Yes (Config F) | **Exit 2** |
| T3-05 | Multipath state post-migration — no failed or ghost paths on destination node | Yes (Config D) | — |
| T3-06 | Per-node config consistency — `/etc/multipath.conf` or `/etc/nvme/hostnqn` checksums match | Yes | — |
| T3-07 | Cluster lock timeout — concurrent creates complete within `storage_lock_timeout` | Yes | — |
| T3-08 | Orphan scan on all nodes after clean deletion | Yes | — |
| T3-09 | Plugin version consistency — identical checksums on all nodes | Yes | — |

---

## 6. Manual Procedures

Some tests require operator judgment and cannot be fully automated.

### T2-04: ALUA Path Distribution

The harness marks T2-04 as `[SKIP]` and logs instructions. To complete this test manually:

1. Identify the dm device: `multipath -ll` — note the `/dev/mapper/mpathX` name.
2. Run a write workload: `fio --filename=/dev/mapper/mpathX --rw=randwrite --bs=4k --iodepth=16 --numjobs=1 --runtime=10 --time_based --name=alua-test`
3. While fio runs, capture path stats: `iostat -x 1 5 /dev/sd*`
4. In the `multipath -ll` output, identify which `/dev/sdX` device is in the `prio=50` group (Active Optimized) and which is in the `prio=10` group (Active Non-Optimized).
5. Parse the `w/s` column from `iostat` for each device.

**Pass criterion:** Active Optimized path (`prio=50` group) carries ≥90% of total write operations. Active Non-Optimized path carries ≤10%.

Record the raw `iostat` output in the test log before signing off.

### Physical NIC Disconnection

`iptables` rules simulate path failure at the packet level. For a real hardware failure test (NIC pull), use T2-05 as a template but disconnect the physical interface instead of adding an `iptables` rule. The pass/fail criteria are the same.

### Debug Log Verification (T1-06)

The harness checks for `[TrueNAS]` in the journal. If the test fails, verify manually:
```bash
journalctl -u pvedaemon -f &
pvesm status <storage>
# Look for [TrueNAS] prefix lines
```

---

## 7. Release Gate Checklist

All three required configs must pass before a release tag is created. QA lead signs off after all rows show exit code 0 with hard gates passing.

| Config | Run date | Operator | Harness exit code | Hard gates | Result | Notes |
|--------|----------|----------|-------------------|------------|--------|-------|
| A | | | | T1-01 | | |
| D | | | | T1-01, T2-03 | | |
| F | | | | T1-01, T3-04 | | |

**Sign-off:** _________________________ Date: _____________

Commit this file (with the sign-off table filled in) to the repo before creating the release tag.

---

## 8. Developer Regression Rules

| Code area changed | Minimum required |
|---|---|
| Any plugin code change | Tier 1 full (Config A) |
| Multipath or ALUA code paths | Tier 1 + Tier 2 (Config D) |
| Cluster or migration code paths | Tier 1 + Tier 3 (Config F) |
| Installer only | T1-01 (TLS audit) + installer health check |
| Documentation only | No test run required |

Quick alias for developer Config A run:
```bash
tools/run-tests.sh --storage <name> --config A --tier 1 --yes
```
```

- [ ] **Step 2: Verify file was written**

```bash
wc -l wiki/Test-Plan.md
```
Expected: >100 lines.

- [ ] **Step 3: Commit**

```bash
git add wiki/Test-Plan.md
git commit -m "docs: add Test-Plan.md operator-facing test plan and harness reference"
```

---

### Task 8: Final integration commit

- [ ] **Step 1: Run all unit tests one final time**

```bash
bash tools/tests/test_common.sh && bash tools/tests/test_arg_parsing.sh
```
Expected: all pass.

- [ ] **Step 2: Syntax-check all shell files**

```bash
for f in tools/run-tests.sh tools/lib/common.sh tools/lib/tier1.sh tools/lib/tier2.sh tools/lib/tier3.sh; do
    bash -n "$f" && echo "OK: $f"
done
```
Expected: `OK: <file>` for each.

- [ ] **Step 3: Verify file structure**

```bash
ls -la tools/run-tests.sh tools/lib/ tools/tests/ wiki/Test-Plan.md
```
Expected: all files present; `run-tests.sh` is executable.

- [ ] **Step 4: Final commit with all test files**

```bash
git add tools/ wiki/Test-Plan.md
git commit -m "feat: complete test harness — run-tests.sh, tier1/2/3 libs, unit tests, Test-Plan.md"
```
