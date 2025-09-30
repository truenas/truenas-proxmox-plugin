#!/bin/bash
# Update TrueNAS Plugin on all PVE cluster nodes
# Usage: ./update-cluster.sh [node1] [node2] [node3]
#        If no nodes specified, will prompt for them

set -e

PLUGIN_FILE="TrueNASPlugin.pm"
INSTALL_PATH="/usr/share/perl5/PVE/Storage/Custom/"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}TrueNAS Plugin Cluster Update Script${NC}"
echo "======================================"

# Check if plugin file exists
if [ ! -f "$SCRIPT_DIR/$PLUGIN_FILE" ]; then
    echo -e "${RED}Error: $PLUGIN_FILE not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Get nodes from arguments or prompt
if [ $# -eq 0 ]; then
    echo -e "${YELLOW}No nodes specified. Please enter node hostnames/IPs (space-separated):${NC}"
    read -r -a NODES
else
    NODES=("$@")
fi

# Confirm nodes
echo -e "\n${YELLOW}Will update plugin on the following nodes:${NC}"
for node in "${NODES[@]}"; do
    echo "  - $node"
done
echo -e "\n${YELLOW}Continue? (y/n)${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Update each node
for node in "${NODES[@]}"; do
    echo -e "\n${GREEN}===> Updating $node${NC}"

    # Copy plugin file
    echo "  Copying $PLUGIN_FILE..."
    if scp "$SCRIPT_DIR/$PLUGIN_FILE" "root@$node:$INSTALL_PATH" 2>/dev/null; then
        echo -e "  ${GREEN}✓ File copied${NC}"
    else
        echo -e "  ${RED}✗ Failed to copy file${NC}"
        continue
    fi

    # Restart services
    echo "  Restarting services..."
    if ssh "root@$node" "systemctl restart pvestatd pvedaemon pveproxy" 2>/dev/null; then
        echo -e "  ${GREEN}✓ Services restarted${NC}"
    else
        echo -e "  ${RED}✗ Failed to restart services${NC}"
        continue
    fi

    echo -e "  ${GREEN}✓ $node updated successfully${NC}"
done

echo -e "\n${GREEN}======================================"
echo "Update complete!"
echo -e "======================================${NC}"
echo -e "\n${YELLOW}Note: Check storage status in the PVE GUI to verify the update.${NC}"