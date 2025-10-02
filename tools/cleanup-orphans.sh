#!/bin/bash
# TrueNAS Orphan Resource Cleanup Tool
# Detects and removes orphaned iSCSI resources on TrueNAS
#
# Usage: ./cleanup-orphans.sh [storage-name] [--force] [--dry-run]
#
# Detects:
#   - iSCSI extents without corresponding zvols
#   - iSCSI targetextents without corresponding extents
#   - Zvols without corresponding extents (orphaned zvols)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
STORAGE=""
FORCE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        --dry-run)
            DRY_RUN=1
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
    echo -e "${CYAN}=== Available TrueNAS Storage ====${NC}"
    grep "^truenasplugin:" /etc/pve/storage.cfg | awk '{print $2}' || {
        echo -e "${RED}Error: No TrueNAS storage configured${NC}"
        exit 1
    }
    echo ""
    echo "Usage: $0 <storage-name> [--force] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --force    Skip confirmation prompt"
    echo "  --dry-run  Show what would be deleted without deleting"
    exit 0
fi

# Verify storage exists
if ! grep -q "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg; then
    echo -e "${RED}Error: Storage '$STORAGE' not found or not a TrueNAS plugin storage${NC}"
    exit 1
fi

echo -e "${CYAN}=== TrueNAS Orphan Resource Detection ===${NC}"
echo -e "Storage: ${GREEN}$STORAGE${NC}"
[ $DRY_RUN -eq 1 ] && echo -e "Mode: ${YELLOW}DRY RUN${NC}"
echo ""

# Temporary files
EXTENTS_FILE=$(mktemp)
ZVOLS_FILE=$(mktemp)
TARGETEXTENTS_FILE=$(mktemp)
ORPHANS_FILE=$(mktemp)

cleanup_temp() {
    rm -f "$EXTENTS_FILE" "$ZVOLS_FILE" "$TARGETEXTENTS_FILE" "$ORPHANS_FILE"
}
trap cleanup_temp EXIT

# Get storage configuration
API_HOST=$(grep -A20 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "api_host" | awk '{print $2}' | head -1)
API_KEY=$(grep -A20 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "api_key" | awk '{print $2}' | head -1)
DATASET=$(grep -A20 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "dataset" | awk '{print $2}' | head -1)
API_INSECURE=$(grep -A20 "^truenasplugin: $STORAGE$" /etc/pve/storage.cfg | grep "api_insecure" | awk '{print $2}' | head -1)

if [ -z "$API_HOST" ] || [ -z "$API_KEY" ] || [ -z "$DATASET" ]; then
    echo -e "${RED}Error: Could not parse storage configuration${NC}"
    exit 1
fi

# Set curl options
CURL_OPTS="-s"
[ "$API_INSECURE" = "1" ] && CURL_OPTS="$CURL_OPTS -k"

# Fetch iSCSI extents
echo -e "${CYAN}Fetching iSCSI extents...${NC}"
curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" "https://$API_HOST/api/v2.0/iscsi/extent" > "$EXTENTS_FILE" 2>/dev/null || {
    echo -e "${RED}Error: Failed to fetch extents from TrueNAS API${NC}"
    exit 1
}

# Fetch zvols under dataset
echo -e "${CYAN}Fetching zvols...${NC}"
curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" "https://$API_HOST/api/v2.0/pool/dataset" > "$ZVOLS_FILE" 2>/dev/null || {
    echo -e "${RED}Error: Failed to fetch zvols from TrueNAS API${NC}"
    exit 1
}

# Fetch target-extent mappings
echo -e "${CYAN}Fetching target-extent mappings...${NC}"
curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" "https://$API_HOST/api/v2.0/iscsi/targetextent" > "$TARGETEXTENTS_FILE" 2>/dev/null || {
    echo -e "${RED}Error: Failed to fetch targetextents from TrueNAS API${NC}"
    exit 1
}

echo ""
echo -e "${CYAN}=== Analyzing Resources ===${NC}"

# Parse and detect orphans
ORPHAN_COUNT=0

# Check extents without zvols
echo -e "${YELLOW}Checking for extents without zvols...${NC}"
for extent_id in $(jq -r '.[] | select(.disk != null and (.disk | startswith("zvol/"))) | .id' "$EXTENTS_FILE"); do
    extent_name=$(jq -r ".[] | select(.id == $extent_id) | .name" "$EXTENTS_FILE")
    extent_disk=$(jq -r ".[] | select(.id == $extent_id) | .disk" "$EXTENTS_FILE")

    # Extract zvol path (remove 'zvol/' prefix)
    zvol_path=$(echo "$extent_disk" | sed 's|^zvol/||')

    # Check if zvol exists and is under our dataset
    if echo "$zvol_path" | grep -q "^$DATASET/"; then
        if ! jq -e ".[] | select(.id == \"$zvol_path\")" "$ZVOLS_FILE" > /dev/null 2>&1; then
            echo "ORPHAN_EXTENT|$extent_id|$extent_name|zvol missing: $zvol_path" >> "$ORPHANS_FILE"
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        fi
    fi
done

# Check targetextents without extents
echo -e "${YELLOW}Checking for target-extent mappings without extents...${NC}"
for te_id in $(jq -r '.[].id' "$TARGETEXTENTS_FILE"); do
    extent_id=$(jq -r ".[] | select(.id == $te_id) | .extent" "$TARGETEXTENTS_FILE")

    # Check if extent exists
    if ! jq -e ".[] | select(.id == $extent_id)" "$EXTENTS_FILE" > /dev/null 2>&1; then
        target_id=$(jq -r ".[] | select(.id == $te_id) | .target" "$TARGETEXTENTS_FILE")
        echo "ORPHAN_TARGETEXTENT|$te_id|mapping-$te_id|extent missing: $extent_id (target: $target_id)" >> "$ORPHANS_FILE"
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    fi
done

# Check zvols without extents (orphaned zvols from failed operations)
echo -e "${YELLOW}Checking for zvols without extents...${NC}"
for zvol_id in $(jq -r ".[] | select((.id | type == \"string\") and (.id | startswith(\"$DATASET/\")) and (.type == \"VOLUME\")) | .id" "$ZVOLS_FILE"); do
    zvol_name=$(basename "$zvol_id")

    # Check if extent exists for this zvol
    zvol_disk="zvol/$zvol_id"
    if ! jq -e ".[] | select(.disk == \"$zvol_disk\")" "$EXTENTS_FILE" > /dev/null 2>&1; then
        echo "ORPHAN_ZVOL|$zvol_id|$zvol_name|no extent pointing to this zvol" >> "$ORPHANS_FILE"
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    fi
done

echo ""

# Report findings
if [ $ORPHAN_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ No orphaned resources found${NC}"
    exit 0
fi

echo -e "${RED}Found $ORPHAN_COUNT orphaned resource(s):${NC}"
echo ""

# Display orphans
EXTENT_ORPHANS=()
TE_ORPHANS=()
ZVOL_ORPHANS=()

while IFS='|' read -r type id name reason; do
    case "$type" in
        ORPHAN_EXTENT)
            echo -e "  ${YELLOW}[EXTENT]${NC} $name (ID: $id)"
            echo -e "           Reason: $reason"
            EXTENT_ORPHANS+=("$id")
            ;;
        ORPHAN_TARGETEXTENT)
            echo -e "  ${YELLOW}[TARGET-EXTENT]${NC} $name (ID: $id)"
            echo -e "                  Reason: $reason"
            TE_ORPHANS+=("$id")
            ;;
        ORPHAN_ZVOL)
            echo -e "  ${YELLOW}[ZVOL]${NC} $name"
            echo -e "         Reason: $reason"
            ZVOL_ORPHANS+=("$id")
            ;;
    esac
done < "$ORPHANS_FILE"

echo ""

# Exit if dry-run
if [ $DRY_RUN -eq 1 ]; then
    echo -e "${CYAN}Dry run complete. No resources were deleted.${NC}"
    exit 0
fi

# Confirmation
if [ $FORCE -eq 0 ]; then
    echo -e "${RED}WARNING: This will permanently delete these orphaned resources!${NC}"
    echo ""
    read -p "Delete these orphaned resources? (yes/N): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Cleanup cancelled.${NC}"
        exit 0
    fi
fi

echo ""
echo -e "${CYAN}=== Cleaning Up Orphaned Resources ===${NC}"

# Delete orphaned targetextents first (they reference extents)
for te_id in "${TE_ORPHANS[@]}"; do
    echo -e "${YELLOW}Deleting target-extent mapping ID: $te_id...${NC}"
    if curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" -X DELETE "https://$API_HOST/api/v2.0/iscsi/targetextent/id/$te_id" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Deleted${NC}"
    else
        echo -e "  ${RED}✗ Failed to delete${NC}"
    fi
done

# Delete orphaned extents
for extent_id in "${EXTENT_ORPHANS[@]}"; do
    echo -e "${YELLOW}Deleting extent ID: $extent_id...${NC}"
    if curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" -X DELETE "https://$API_HOST/api/v2.0/iscsi/extent/id/$extent_id" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Deleted${NC}"
    else
        echo -e "  ${RED}✗ Failed to delete${NC}"
    fi
done

# Delete orphaned zvols
for zvol_id in "${ZVOL_ORPHANS[@]}"; do
    echo -e "${YELLOW}Deleting zvol: $zvol_id...${NC}"
    # URL encode the zvol path
    zvol_encoded=$(echo "$zvol_id" | sed 's|/|%2F|g')
    if curl $CURL_OPTS -H "Authorization: Bearer $API_KEY" -X DELETE "https://$API_HOST/api/v2.0/pool/dataset/id/$zvol_encoded" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Deleted${NC}"
    else
        echo -e "  ${RED}✗ Failed to delete${NC}"
    fi
done

echo ""
echo -e "${GREEN}✓ Cleanup complete!${NC}"
