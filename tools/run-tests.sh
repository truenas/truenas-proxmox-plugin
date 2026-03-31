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

# Ensure iptables rules are cleaned up even if the harness is interrupted
trap 'iptables_cleanup_all' EXIT INT TERM

# Global state
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
HARD_GATE_FAILED=0
TIER4_AVAILABLE=0
TIER5_AVAILABLE=0
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
    ARG_STORAGE=""
    ARG_CONFIG="all"
    ARG_TIER="all"
    ARG_YES=0
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

# ============================================================
# Hardware detection
# ============================================================
detect_max_tier() {
    local tier=0

    # Tier 1: pvesh available and storage active
    if command -v pvesh &>/dev/null; then
        if [[ -n "$ARG_STORAGE" ]] && pvesm status 2>/dev/null | grep -q "^${ARG_STORAGE} "; then
            tier=1
        elif [[ -z "$ARG_STORAGE" ]]; then
            tier=1
        fi
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
# Guard: skip main execution when unit-testing
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

# Tier 4 detection runs separately since detect_max_tier runs in a subshell
# and cannot set globals in the parent.
if [[ $MAX_TIER -ge 1 ]] && [[ -n "$ARG_STORAGE" ]]; then
    _ha_licensed=$(tn_api_call "$ARG_STORAGE" "failover.licensed" 2>/dev/null || true)
    if [[ "$_ha_licensed" == "true" ]]; then
        TIER4_AVAILABLE=1
    fi
fi

# Tier 5 detection: HA + multipath + dual portals
if [[ "${TIER4_AVAILABLE:-0}" -eq 1 ]] && \
   grep -q 'use_multipath 1' /etc/pve/storage.cfg 2>/dev/null; then
    _portal_count=$(read_storage_cfg "$ARG_STORAGE" "portals" | tr ',' '\n' | grep -c '.' || true)
    if [[ "${_portal_count:-0}" -ge 2 ]]; then
        TIER5_AVAILABLE=1
    fi
fi

log_info "Detected max hardware tier: $MAX_TIER"

# Validate hardware against --config requirements
if [[ "$ARG_CONFIG" != "all" ]]; then
    required_tiers=$(config_required_tiers "$ARG_CONFIG")
    for t in $required_tiers; do
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
# Tier orchestration
# ============================================================
source "$SCRIPT_DIR/lib/tier1.sh"
source "$SCRIPT_DIR/lib/tier2.sh"
source "$SCRIPT_DIR/lib/tier3.sh"
source "$SCRIPT_DIR/lib/tier4.sh"
source "$SCRIPT_DIR/lib/tier5.sh"

START_TIME=$(date +%s)

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
    elif [[ "$tier" -eq 5 ]]; then
        if [[ "${TIER5_AVAILABLE:-0}" -ne 1 ]]; then
            log_skip "Tier 5 — ALUA + HA not detected"
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
        5) run_tier5 "$ARG_STORAGE" "$ARG_CONFIG" ;;
    esac
}

run_tier 1
run_tier 2
run_tier 3
run_tier 4
run_tier 5

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
