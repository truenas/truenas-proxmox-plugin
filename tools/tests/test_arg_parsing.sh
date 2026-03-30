#!/usr/bin/env bash
# tools/tests/test_arg_parsing.sh
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
assert_eq "config all tiers" "1 2 3 4" "$(config_required_tiers all)"

# --- Config H ---
parse_args --storage mystore --config H --yes
assert_eq "parse --config H"  "H" "$ARG_CONFIG"

assert_eq "config H tiers" "1 4"       "$(config_required_tiers H)"
assert_eq "config H gates" "T1-01 T4-04" "$(config_hard_gates H)"

# --- config_hard_gates ---
assert_eq "config A gates" "T1-01"         "$(config_hard_gates A)"
assert_eq "config D gates" "T1-01 T2-03"   "$(config_hard_gates D)"
assert_eq "config F gates" "T1-01 T3-04"   "$(config_hard_gates F)"
assert_eq "config all gates" "T1-01 T2-03 T3-04 T4-04" "$(config_hard_gates all)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
