#!/bin/bash
# Check TrueNAS Plugin version across cluster nodes
# Usage: ./check-version.sh [node1] [node2] [node3]
#        If no nodes specified, checks local installation only

PLUGIN_PATH="/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}TrueNAS Plugin Version Check${NC}"
echo "============================"
echo ""

# Function to check version on a node
check_node_version() {
    local node=$1
    local is_local=$2

    if [ "$is_local" = "true" ]; then
        if [ -f "$PLUGIN_PATH" ]; then
            version=$(grep 'our $VERSION' "$PLUGIN_PATH" | grep -oP "'[0-9.]+'")
            echo -e "${GREEN}Local:${NC} $version"
        else
            echo -e "${YELLOW}Local: Plugin not installed${NC}"
        fi
    else
        echo -n "$node: "
        if ssh "root@$node" "test -f $PLUGIN_PATH" 2>/dev/null; then
            version=$(ssh "root@$node" "grep 'our \\\$VERSION' $PLUGIN_PATH" 2>/dev/null | grep -oP "'[0-9.]+'")
            if [ -n "$version" ]; then
                echo -e "${GREEN}$version${NC}"
            else
                echo -e "${YELLOW}Version string not found${NC}"
            fi
        else
            echo -e "${YELLOW}Plugin not installed${NC}"
        fi
    fi
}

# Check local installation first
check_node_version "local" "true"

# Check remote nodes if specified
if [ $# -gt 0 ]; then
    echo ""
    for node in "$@"; do
        check_node_version "$node" "false"
    done
else
    echo ""
    echo -e "${YELLOW}Tip: Specify node names to check cluster: ./check-version.sh pve1 pve2 pve3${NC}"
fi
