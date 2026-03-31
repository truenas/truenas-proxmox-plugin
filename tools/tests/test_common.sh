#!/usr/bin/env bash
# tools/tests/test_common.sh
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

# --- read_storage_cfg_file ---
TMP=$(mktemp)
cat >"$TMP" <<'EOF'
: initial_pool_config_file
: 0

truenasplugin: truenas-iscsi
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

# --- tn_api_call argument validation ---
# tn_api_call requires at least 2 args: storage and method
out=$(tn_api_call 2>&1) || true
assert_match "tn_api_call no args" 'Usage:' "$out"

# --- parse_multipath_ll ---
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
assert_eq "mp path_active"  "sdc"       "$MP_PATH_ACTIVE"
assert_eq "mp path_enabled" "sdd"       "$MP_PATH_ENABLED"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
