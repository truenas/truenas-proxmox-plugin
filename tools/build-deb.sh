#!/bin/bash
# Build and test the truenas-proxmox-plugin debian package
# This script builds the package and optionally tests installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Build and test the truenas-proxmox-plugin debian package.

OPTIONS:
    -h, --help              Show this help message
    -c, --clean             Clean build artifacts before building
    -t, --test              Test package installation after building
    -i, --install           Install the package after building (requires root)
    -v, --verbose           Show detailed build output
    --no-lintian            Skip lintian checks
    --arch ARCH             Build for specific architecture (default: all)

EXAMPLES:
    $(basename "$0")                    # Build package
    $(basename "$0") --clean --test     # Clean build and test
    $(basename "$0") --install          # Build and install

EOF
    exit 0
}

# Parse command line arguments
CLEAN=0
TEST=0
INSTALL=0
VERBOSE=0
RUN_LINTIAN=1
ARCH="all"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -c|--clean)
            CLEAN=1
            shift
            ;;
        -t|--test)
            TEST=1
            shift
            ;;
        -i|--install)
            INSTALL=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --no-lintian)
            RUN_LINTIAN=0
            shift
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Print step
print_step() {
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
}

# Print error
print_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

# Print warning
print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# Check dependencies
check_dependencies() {
    print_step "Checking build dependencies"

    local missing_deps=()

    if ! command -v dpkg-deb &> /dev/null; then
        missing_deps+=("dpkg-dev")
    fi

    if [[ $RUN_LINTIAN -eq 1 ]] && ! command -v lintian &> /dev/null; then
        missing_deps+=("lintian")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        echo "Install with: apt-get install ${missing_deps[*]}"
        exit 1
    fi

    echo "All dependencies satisfied"
}

# Clean build artifacts
clean_build() {
    print_step "Cleaning build artifacts"

    cd "$PROJECT_ROOT"

    if [[ -d debian/truenas-proxmox-plugin ]]; then
        rm -rf debian/truenas-proxmox-plugin
        echo "Removed debian/truenas-proxmox-plugin/"
    fi

    if [[ -f debian/files ]]; then
        rm -f debian/files
        echo "Removed debian/files"
    fi

    if [[ -f debian/debhelper-build-stamp ]]; then
        rm -f debian/debhelper-build-stamp
        echo "Removed debian/debhelper-build-stamp"
    fi

    # Remove any .deb files in parent directory
    if ls ../*.deb &> /dev/null; then
        rm -f ../*.deb
        echo "Removed previous .deb files"
    fi
}

# Build package
build_package() {
    print_step "Building debian package"

    cd "$PROJECT_ROOT"

    # Verify debian directory exists
    if [[ ! -d debian ]]; then
        print_error "debian/ directory not found"
        exit 1
    fi

    # Build the package
    if [[ $VERBOSE -eq 1 ]]; then
        dpkg-deb --build debian/truenas-proxmox-plugin || {
            print_error "Package build failed"
            exit 1
        }
    else
        dpkg-deb --build debian/truenas-proxmox-plugin > /dev/null 2>&1 || {
            print_error "Package build failed (run with --verbose for details)"
            exit 1
        }
    fi

    # Find the generated .deb file
    DEB_FILE=$(find .. -maxdepth 1 -name "truenas-proxmox-plugin_*.deb" -type f | head -n 1)

    if [[ -z "$DEB_FILE" ]]; then
        print_error "Built .deb file not found"
        exit 1
    fi

    # Get package info
    DEB_SIZE=$(du -h "$DEB_FILE" | cut -f1)

    echo -e "${GREEN}Package built successfully:${NC}"
    echo "  File: $(basename "$DEB_FILE")"
    echo "  Size: $DEB_SIZE"
    echo "  Path: $DEB_FILE"
}

# Run lintian checks
run_lintian() {
    print_step "Running lintian checks"

    if [[ -z "$DEB_FILE" ]]; then
        print_error "No .deb file to check"
        return 1
    fi

    if [[ $VERBOSE -eq 1 ]]; then
        lintian "$DEB_FILE" || print_warning "Lintian found issues"
    else
        lintian "$DEB_FILE" 2>&1 | grep -E "^[EW]:" || echo "No errors or warnings"
    fi
}

# Test package
test_package() {
    print_step "Testing package contents"

    if [[ -z "$DEB_FILE" ]]; then
        print_error "No .deb file to test"
        exit 1
    fi

    echo "Package information:"
    dpkg-deb --info "$DEB_FILE" | grep -E "^\s*(Package|Version|Architecture|Depends|Maintainer|Description):"

    echo ""
    echo "Package contents:"
    dpkg-deb --contents "$DEB_FILE"

    echo ""
    echo "Control scripts:"
    dpkg-deb --control "$DEB_FILE"

    # Verify critical files exist in package
    echo ""
    echo "Verifying package contents:"

    local required_files=(
        "usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
        "usr/share/doc/truenas-proxmox-plugin/copyright"
        "usr/share/doc/truenas-proxmox-plugin/changelog.Debian.gz"
    )

    local missing_files=()
    for file in "${required_files[@]}"; do
        if dpkg-deb --contents "$DEB_FILE" | grep -q " ./$file$"; then
            echo -e "  ${GREEN}✓${NC} $file"
        else
            echo -e "  ${RED}✗${NC} $file"
            missing_files+=("$file")
        fi
    done

    if [[ ${#missing_files[@]} -gt 0 ]]; then
        print_error "Missing required files in package"
        exit 1
    fi

    echo -e "${GREEN}All required files present${NC}"
}

# Install package
install_package() {
    print_step "Installing package"

    if [[ $EUID -ne 0 ]]; then
        print_error "Installation requires root privileges"
        echo "Run with: sudo $(basename "$0") --install"
        exit 1
    fi

    if [[ -z "$DEB_FILE" ]]; then
        print_error "No .deb file to install"
        exit 1
    fi

    echo "Installing $DEB_FILE..."
    dpkg -i "$DEB_FILE" || {
        print_error "Installation failed"
        exit 1
    }

    echo -e "${GREEN}Package installed successfully${NC}"

    # Verify installation
    echo ""
    echo "Verifying installation:"

    if [[ -f /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm ]]; then
        echo -e "  ${GREEN}✓${NC} Plugin file installed"

        # Check file permissions
        local perms=$(stat -c "%a" /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm)
        if [[ "$perms" == "644" ]]; then
            echo -e "  ${GREEN}✓${NC} Permissions correct (644)"
        else
            print_warning "Unexpected permissions: $perms (expected 644)"
        fi
    else
        print_error "Plugin file not found after installation"
        exit 1
    fi

    # Check if pvedaemon needs restart
    if systemctl is-active --quiet pvedaemon; then
        echo ""
        print_warning "Remember to restart Proxmox services:"
        echo "  systemctl restart pvedaemon pveproxy"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}TrueNAS Proxmox Plugin - Package Builder${NC}"
    echo ""

    check_dependencies

    if [[ $CLEAN -eq 1 ]]; then
        clean_build
    fi

    build_package

    if [[ $RUN_LINTIAN -eq 1 ]]; then
        run_lintian
    fi

    if [[ $TEST -eq 1 ]]; then
        test_package
    fi

    if [[ $INSTALL -eq 1 ]]; then
        install_package
    fi

    echo ""
    echo -e "${GREEN}Build completed successfully${NC}"
}

main
