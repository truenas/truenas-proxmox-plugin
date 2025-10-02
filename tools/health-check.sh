#!/bin/bash
# TrueNAS Plugin Health Check
# Quick health validation without running the full test suite
# Exit codes: 0=healthy, 1=warning, 2=critical
#
# Usage: ./health-check.sh [storage-name] [--quiet] [--json]

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
STORAGE=""
QUIET=0
JSON=0

for arg in "$@"; do
    case "$arg" in
        --quiet)
            QUIET=1
            ;;
        --json)
            JSON=1
            ;;
        *)
            if [ -z "$STORAGE" ]; then
                STORAGE="$arg"
            fi
            ;;
    esac
done

# If no storage specified, list available TrueNAS storages
if [ -z "$STORAGE" ]; then
    if [ $JSON -eq 0 ]; then
        echo -e "${CYAN}=== Available TrueNAS Storage ====${NC}"
        grep "^truenasplugin:" /etc/pve/storage.cfg | awk '{print $2}' || {
            echo -e "${RED}Error: No TrueNAS storage configured${NC}"
            exit 2
        }
        echo ""
        echo "Usage: $0 <storage-name> [--quiet] [--json]"
        echo ""
        echo "Options:"
        echo "  --quiet  Only show summary"
        echo "  --json   Output results in JSON format"
    fi
    exit 0
fi

# Counters
WARNINGS=0
ERRORS=0
CHECKS_PASSED=0
CHECKS_TOTAL=0

# Results array for JSON
declare -a RESULTS

# Check function
run_check() {
    local name="$1"
    local status="$2"
    local message="$3"
    local level="$4"  # OK, WARNING, CRITICAL, SKIP

    ((CHECKS_TOTAL++))

    if [ $JSON -eq 1 ]; then
        RESULTS+=("{\"check\":\"$name\",\"status\":\"$level\",\"message\":\"$message\"}")
    elif [ $QUIET -eq 0 ]; then
        printf "%-25s " "$name:"
        case "$level" in
            OK)
                echo -e "${GREEN}✓ $message${NC}"
                ;;
            WARNING)
                echo -e "${YELLOW}⚠ $message${NC}"
                ;;
            CRITICAL)
                echo -e "${RED}✗ $message${NC}"
                ;;
            SKIP)
                echo -e "${CYAN}- $message${NC}"
                ;;
        esac
    fi

    case "$level" in
        OK) ((CHECKS_PASSED++)) ;;
        WARNING) ((WARNINGS++)) ;;
        CRITICAL) ((ERRORS++)) ;;
    esac
}

# Header
if [ $JSON -eq 0 ] && [ $QUIET -eq 0 ]; then
    echo -e "${CYAN}=== TrueNAS Plugin Health Check ===${NC}"
    echo -e "Storage: ${GREEN}$STORAGE${NC}"
    echo ""
fi

# Check 1: Plugin file installed
if [ -f /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm ]; then
    VERSION=$(grep 'our $VERSION' /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm | grep -oP "[0-9.]+")
    run_check "Plugin file" "installed" "Installed v$VERSION" "OK"
else
    run_check "Plugin file" "missing" "Not installed" "CRITICAL"
fi

# Check 2: Storage configured
if grep -q "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg 2>/dev/null; then
    run_check "Storage configuration" "configured" "Configured" "OK"
else
    run_check "Storage configuration" "missing" "Not configured" "CRITICAL"
    # Exit early if storage not configured
    if [ $JSON -eq 0 ]; then
        echo ""
        echo -e "${RED}CRITICAL: Storage '$STORAGE' not configured${NC}"
    else
        echo "{\"storage\":\"$STORAGE\",\"status\":\"CRITICAL\",\"checks\":[${RESULTS[*]}],\"errors\":$ERRORS,\"warnings\":$WARNINGS,\"passed\":$CHECKS_PASSED,\"total\":$CHECKS_TOTAL}"
    fi
    exit 2
fi

# Check 3: Storage status
if pvesm status 2>/dev/null | grep -q "$STORAGE.*active"; then
    # Get space info
    SPACE=$(pvesm status 2>/dev/null | grep "$STORAGE" | awk '{print $5}')
    run_check "Storage status" "active" "Active (${SPACE}% free)" "OK"
else
    run_check "Storage status" "inactive" "Inactive" "WARNING"
fi

# Check 4: Storage content type
CONTENT=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "content" | awk '{print $2}' | head -1)
if [ "$CONTENT" = "images" ]; then
    run_check "Content type" "valid" "images" "OK"
elif [ -n "$CONTENT" ]; then
    run_check "Content type" "invalid" "$CONTENT (should be 'images')" "WARNING"
else
    run_check "Content type" "missing" "Not configured" "WARNING"
fi

# Check 5: TrueNAS API reachability
API_HOST=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "api_host" | awk '{print $2}' | head -1)
API_PORT=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "api_port" | awk '{print $2}' | head -1)
API_PORT=${API_PORT:-443}

if [ -n "$API_HOST" ]; then
    if timeout 5 bash -c ">/dev/tcp/$API_HOST/$API_PORT" 2>/dev/null; then
        run_check "TrueNAS API" "reachable" "Reachable on $API_HOST:$API_PORT" "OK"
    else
        run_check "TrueNAS API" "unreachable" "Cannot reach $API_HOST:$API_PORT" "CRITICAL"
    fi
else
    run_check "TrueNAS API" "not-configured" "API host not configured" "CRITICAL"
fi

# Check 6: Dataset configuration
DATASET=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "dataset" | awk '{print $2}' | head -1)
if [ -n "$DATASET" ]; then
    run_check "Dataset" "configured" "$DATASET" "OK"
else
    run_check "Dataset" "missing" "Not configured" "CRITICAL"
fi

# Check 7: Target IQN configuration
TARGET_IQN=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "target_iqn" | awk '{print $2}' | head -1)
if [ -n "$TARGET_IQN" ]; then
    run_check "Target IQN" "configured" "$TARGET_IQN" "OK"
else
    run_check "Target IQN" "missing" "Not configured" "CRITICAL"
fi

# Check 8: iSCSI discovery portal
DISCOVERY_PORTAL=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "discovery_portal" | awk '{print $2}' | head -1)
if [ -n "$DISCOVERY_PORTAL" ]; then
    run_check "Discovery portal" "configured" "$DISCOVERY_PORTAL" "OK"
else
    run_check "Discovery portal" "missing" "Not configured" "CRITICAL"
fi

# Check 9: iSCSI sessions
if [ -n "$TARGET_IQN" ]; then
    SESSION_COUNT=$(iscsiadm -m session 2>/dev/null | grep -c "$TARGET_IQN" || echo "0")
    if [ "$SESSION_COUNT" -gt 0 ]; then
        run_check "iSCSI sessions" "active" "$SESSION_COUNT active session(s)" "OK"
    else
        run_check "iSCSI sessions" "none" "No active sessions" "WARNING"
    fi
else
    run_check "iSCSI sessions" "skip" "Cannot check (no target IQN)" "SKIP"
fi

# Check 10: Multipath configuration
USE_MULTIPATH=$(grep -A10 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "use_multipath" | awk '{print $2}' | head -1)
if [ "$USE_MULTIPATH" = "1" ]; then
    if command -v multipath &> /dev/null; then
        MPATH_COUNT=$(multipath -ll 2>/dev/null | grep -c "dm-" || echo "0")
        if [ "$MPATH_COUNT" -gt 0 ]; then
            run_check "Multipath" "enabled" "$MPATH_COUNT device(s)" "OK"
        else
            run_check "Multipath" "enabled-no-devices" "Enabled but no devices" "WARNING"
        fi
    else
        run_check "Multipath" "not-installed" "Enabled but multipath-tools not installed" "WARNING"
    fi
else
    run_check "Multipath" "disabled" "Not enabled" "SKIP"
fi

# Check 11: Orphaned resources (if cleanup tool exists)
if [ -f "$(dirname "$0")/cleanup-orphans.sh" ]; then
    ORPHAN_OUTPUT=$($(dirname "$0")/cleanup-orphans.sh "$STORAGE" --dry-run 2>/dev/null | grep -oP "Found \K[0-9]+" || echo "0")
    if [ "$ORPHAN_OUTPUT" = "0" ]; then
        run_check "Orphaned resources" "none" "No orphans found" "OK"
    else
        run_check "Orphaned resources" "found" "$ORPHAN_OUTPUT orphan(s) found" "WARNING"
    fi
else
    run_check "Orphaned resources" "skip" "Cleanup tool not available" "SKIP"
fi

# Check 12: PVE daemon status
if systemctl is-active --quiet pvedaemon; then
    run_check "PVE daemon" "running" "Running" "OK"
else
    run_check "PVE daemon" "stopped" "Not running" "CRITICAL"
fi

# Summary
if [ $JSON -eq 1 ]; then
    # JSON output
    if [ $ERRORS -gt 0 ]; then
        STATUS="CRITICAL"
        EXIT_CODE=2
    elif [ $WARNINGS -gt 0 ]; then
        STATUS="WARNING"
        EXIT_CODE=1
    else
        STATUS="HEALTHY"
        EXIT_CODE=0
    fi

    echo "{\"storage\":\"$STORAGE\",\"status\":\"$STATUS\",\"checks\":[$(IFS=,; echo "${RESULTS[*]}")],\"errors\":$ERRORS,\"warnings\":$WARNINGS,\"passed\":$CHECKS_PASSED,\"total\":$CHECKS_TOTAL}"
    exit $EXIT_CODE
else
    echo ""
    echo -e "${CYAN}=== Health Summary ===${NC}"
    echo "Checks passed: $CHECKS_PASSED/$CHECKS_TOTAL"

    if [ $ERRORS -gt 0 ]; then
        echo -e "Status: ${RED}CRITICAL${NC} ($ERRORS error(s), $WARNINGS warning(s))"
        exit 2
    elif [ $WARNINGS -gt 0 ]; then
        echo -e "Status: ${YELLOW}WARNING${NC} ($WARNINGS warning(s))"
        exit 1
    else
        echo -e "Status: ${GREEN}HEALTHY${NC}"
        exit 0
    fi
fi
