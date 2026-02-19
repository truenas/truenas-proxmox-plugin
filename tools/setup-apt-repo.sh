#!/bin/bash
# Setup script for TrueNAS Proxmox Plugin APT repository
# This script configures apt sources and GPG keys for the plugin repository

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Repository configuration
REPO_URL="https://truenas.github.io/truenas-proxmox-plugin"
REPO_KEY_URL="${REPO_URL}/gpg.key"
SOURCES_FILE="/etc/apt/sources.list.d/truenas-proxmox-plugin.list"
KEYRING_FILE="/usr/share/keyrings/truenas-proxmox-plugin.gpg"

# Print functions
print_step() {
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

print_info() {
    echo -e "${BLUE}Info:${NC} $1"
}

# Usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Setup the TrueNAS Proxmox Plugin APT repository.

OPTIONS:
    -h, --help              Show this help message
    -r, --remove            Remove repository configuration
    -c, --check             Check repository status
    -u, --update            Update repository after setup
    -b, --branch BRANCH     Use specific branch (default: main)
    -y, --yes               Skip confirmation prompts

EXAMPLES:
    $(basename "$0")                        # Setup repository
    $(basename "$0") --remove               # Remove repository
    $(basename "$0") --check                # Check status
    $(basename "$0") --branch alpha -y      # Setup alpha branch

EOF
    exit 0
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Run with: sudo $(basename "$0")"
        exit 1
    fi
}

# Check if Proxmox VE is installed
check_proxmox() {
    if ! command -v pvesm &> /dev/null; then
        print_warning "Proxmox VE tools not found"
        print_warning "This repository is designed for Proxmox VE systems"
        echo -n "Continue anyway? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Aborted"
            exit 0
        fi
    fi
}

# Confirm action
confirm() {
    if [[ $SKIP_CONFIRM -eq 1 ]]; then
        return 0
    fi

    echo -n "$1 [y/N] "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted"
        exit 0
    fi
}

# Setup repository
setup_repo() {
    print_step "Setting up TrueNAS Proxmox Plugin repository"

    # Create keyrings directory if it doesn't exist
    if [[ ! -d /usr/share/keyrings ]]; then
        mkdir -p /usr/share/keyrings
        echo "Created /usr/share/keyrings directory"
    fi

    # Download and install GPG key
    print_info "Downloading GPG key..."
    if ! curl -fsSL "$REPO_KEY_URL" -o "$KEYRING_FILE" 2>/dev/null; then
        print_warning "Could not download GPG key from $REPO_KEY_URL"
        print_info "Repository may not have GPG signing enabled yet"
        print_info "Proceeding without GPG verification"

        # Create sources file without signed-by option
        echo "deb [arch=all] ${REPO_URL}/${BRANCH} ./" > "$SOURCES_FILE"
    else
        # Dearmor the key if it's ASCII armored
        if grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$KEYRING_FILE" 2>/dev/null; then
            print_info "Converting ASCII armored key to GPG format..."
            gpg --dearmor < "$KEYRING_FILE" > "${KEYRING_FILE}.tmp"
            mv "${KEYRING_FILE}.tmp" "$KEYRING_FILE"
        fi

        echo "GPG key installed to $KEYRING_FILE"

        # Create sources file with signed-by option
        echo "deb [arch=all signed-by=${KEYRING_FILE}] ${REPO_URL}/${BRANCH} ./" > "$SOURCES_FILE"
    fi

    echo "Repository configuration written to $SOURCES_FILE"

    # Set proper permissions
    chmod 644 "$SOURCES_FILE"
    if [[ -f "$KEYRING_FILE" ]]; then
        chmod 644 "$KEYRING_FILE"
    fi

    print_step "Repository setup complete"
    echo ""
    echo "To install the plugin:"
    echo "  apt-get update"
    echo "  apt-get install truenas-proxmox-plugin"
}

# Remove repository
remove_repo() {
    print_step "Removing TrueNAS Proxmox Plugin repository"

    local removed=0

    if [[ -f "$SOURCES_FILE" ]]; then
        rm -f "$SOURCES_FILE"
        echo "Removed $SOURCES_FILE"
        removed=1
    fi

    if [[ -f "$KEYRING_FILE" ]]; then
        rm -f "$KEYRING_FILE"
        echo "Removed $KEYRING_FILE"
        removed=1
    fi

    if [[ $removed -eq 0 ]]; then
        print_info "Repository was not configured"
    else
        print_step "Repository removed successfully"
    fi
}

# Check repository status
check_status() {
    print_step "Checking repository status"

    echo ""
    echo "Sources file: $SOURCES_FILE"
    if [[ -f "$SOURCES_FILE" ]]; then
        echo -e "  ${GREEN}✓${NC} Exists"
        echo "  Content:"
        sed 's/^/    /' "$SOURCES_FILE"
    else
        echo -e "  ${YELLOW}✗${NC} Not configured"
    fi

    echo ""
    echo "GPG keyring: $KEYRING_FILE"
    if [[ -f "$KEYRING_FILE" ]]; then
        echo -e "  ${GREEN}✓${NC} Exists"
        local key_info=$(gpg --show-keys "$KEYRING_FILE" 2>/dev/null | head -n 5)
        if [[ -n "$key_info" ]]; then
            echo "  Key info:"
            echo "$key_info" | sed 's/^/    /'
        fi
    else
        echo -e "  ${YELLOW}✗${NC} Not configured"
    fi

    echo ""
    echo "Repository URL: $REPO_URL/$BRANCH"

    # Test repository connectivity
    echo ""
    echo "Testing repository connectivity:"
    if curl -fsSL -o /dev/null "$REPO_URL/$BRANCH/Packages" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Repository is accessible"
    else
        echo -e "  ${YELLOW}✗${NC} Repository not accessible (may not be published yet)"
    fi

    # Check if package is installed
    echo ""
    echo "Package installation status:"
    if dpkg -l truenas-proxmox-plugin 2>/dev/null | grep -q "^ii"; then
        local version=$(dpkg-query -W -f='${Version}' truenas-proxmox-plugin 2>/dev/null)
        echo -e "  ${GREEN}✓${NC} Installed (version $version)"
    else
        echo -e "  ${YELLOW}✗${NC} Not installed"
    fi
}

# Update apt cache
update_apt() {
    print_step "Updating APT package cache"

    if apt-get update 2>&1 | tee /tmp/apt-update.log | grep -q "truenas-proxmox-plugin"; then
        echo -e "${GREEN}Repository updated successfully${NC}"
    else
        if grep -q "truenas-proxmox-plugin" /tmp/apt-update.log; then
            echo -e "${YELLOW}Repository may have issues - check output above${NC}"
        else
            print_info "Repository configured but not yet in cache"
        fi
    fi

    rm -f /tmp/apt-update.log
}

# Main function
main() {
    local ACTION="setup"
    SKIP_CONFIRM=0
    local DO_UPDATE=0
    BRANCH="main"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -r|--remove)
                ACTION="remove"
                shift
                ;;
            -c|--check)
                ACTION="check"
                shift
                ;;
            -u|--update)
                DO_UPDATE=1
                shift
                ;;
            -b|--branch)
                BRANCH="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRM=1
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    echo -e "${BLUE}TrueNAS Proxmox Plugin - APT Repository Setup${NC}"
    echo ""

    # Check status doesn't require root
    if [[ "$ACTION" != "check" ]]; then
        check_root
    fi

    case $ACTION in
        setup)
            check_proxmox
            confirm "Setup TrueNAS Proxmox Plugin repository ($BRANCH branch)?"
            setup_repo
            if [[ $DO_UPDATE -eq 1 ]]; then
                echo ""
                update_apt
            fi
            ;;
        remove)
            confirm "Remove TrueNAS Proxmox Plugin repository?"
            remove_repo
            ;;
        check)
            check_status
            ;;
    esac

    echo ""
    echo -e "${GREEN}Done${NC}"
}

main "$@"
