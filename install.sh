#!/bin/bash

# TrueNAS Proxmox VE Plugin Installer
# Interactive installation, update, and configuration wizard
# Version: 1.0.0

set -euo pipefail

# ============================================================================
# CONSTANTS AND CONFIGURATION
# ============================================================================

readonly INSTALLER_VERSION="1.0.0"
readonly GITHUB_REPO="WarlockSyno/truenasplugin"
readonly PLUGIN_FILE="/usr/share/perl5/PVE/Storage/TrueNASPlugin.pm"
readonly STORAGE_CFG="/etc/pve/storage.cfg"
readonly BACKUP_DIR="/var/lib/truenas-plugin-backups"
readonly LOG_FILE="/var/log/truenas-installer.log"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_USER_CANCEL=2

# Colors for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# ============================================================================

# Initialize logging
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Warning: Cannot create log file at $LOG_FILE" >&2
        return 1
    }
    log "INFO" "Installer started (version $INSTALLER_VERSION)"
}

# Write to log file
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Print colored message
print_color() {
    local color="$1"
    shift
    echo -e "${color}$*${COLOR_RESET}"
}

# Info message (blue)
info() {
    print_color "$COLOR_BLUE" "ℹ  $*"
    log "INFO" "$*"
}

# Success message (green)
success() {
    print_color "$COLOR_GREEN" "✓ $*"
    log "SUCCESS" "$*"
}

# Warning message (yellow)
warning() {
    print_color "$COLOR_YELLOW" "⚠  $*"
    log "WARNING" "$*"
}

# Error message (red)
error() {
    print_color "$COLOR_RED" "✗ $*" >&2
    log "ERROR" "$*"
}

# Fatal error - print and exit
fatal() {
    error "$*"
    exit $EXIT_ERROR
}

# Print section header
print_header() {
    echo
    print_color "$COLOR_BOLD$COLOR_CYAN" "═══════════════════════════════════════════════════════════"
    print_color "$COLOR_BOLD$COLOR_CYAN" "  $*"
    print_color "$COLOR_BOLD$COLOR_CYAN" "═══════════════════════════════════════════════════════════"
    echo
}

# ============================================================================
# PRIVILEGE AND DEPENDENCY CHECKS
# ============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This installer must be run as root. Please use: sudo $0"
    fi
    log "INFO" "Root privilege check passed"
}

# Check required dependencies
check_dependencies() {
    local missing_deps=()
    local deps=("perl" "systemctl")

    # Check for wget or curl
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("wget or curl")
    fi

    # Check for jq (needed for GitHub API)
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    # Check other dependencies
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
        echo
        info "Please install missing dependencies:"
        echo "  apt-get update && apt-get install -y ${missing_deps[*]}"
        echo
        exit $EXIT_ERROR
    fi

    log "INFO" "All dependencies satisfied"
}

# ============================================================================
# INSTALLATION STATE DETECTION
# ============================================================================

# Get currently installed plugin version
get_installed_version() {
    if [[ ! -f "$PLUGIN_FILE" ]]; then
        echo ""
        return 1
    fi

    # Extract version from plugin file
    local version
    version=$(perl -ne 'print $1 if /VERSION\s*=\s*['\''"]([0-9]+\.[0-9]+\.[0-9]+)/' "$PLUGIN_FILE" 2>/dev/null || echo "")

    if [[ -z "$version" ]]; then
        # Try alternative version extraction
        version=$(perl -ne 'print $1 if /version:\s*([0-9]+\.[0-9]+\.[0-9]+)/' "$PLUGIN_FILE" 2>/dev/null || echo "")
    fi

    echo "$version"
}

# Check if plugin is installed
is_plugin_installed() {
    [[ -f "$PLUGIN_FILE" ]]
}

# Get installation state summary
get_install_state() {
    if is_plugin_installed; then
        local version
        version=$(get_installed_version)
        if [[ -n "$version" ]]; then
            echo "installed:$version"
        else
            echo "installed:unknown"
        fi
    else
        echo "not_installed"
    fi
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Cleanup on error
cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed with exit code $exit_code"
        log "ERROR" "Installation failed with exit code $exit_code"
    fi
}

# Set up error trap
trap cleanup_on_error EXIT

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

# Show help message
show_help() {
    cat << EOF
TrueNAS Proxmox VE Plugin Installer v${INSTALLER_VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    --version           Display installer version
    --non-interactive   Run in non-interactive mode with defaults
    --help              Show this help message

EXAMPLES:
    # Interactive installation (default)
    $0

    # Non-interactive installation
    $0 --non-interactive

    # One-liner installation from GitHub
    wget -qO- https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | bash

For more information, visit:
https://github.com/${GITHUB_REPO}

EOF
}

# Parse command line arguments
parse_arguments() {
    NON_INTERACTIVE=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                echo "TrueNAS Proxmox VE Plugin Installer v${INSTALLER_VERSION}"
                exit 0
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo
                show_help
                exit $EXIT_ERROR
                ;;
        esac
    done
}

# ============================================================================
# GITHUB API INTEGRATION
# ============================================================================

# Detect which download tool to use
get_download_tool() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        return 1
    fi
}

# Download file using available tool
download_file() {
    local url="$1"
    local output="$2"
    local tool
    tool=$(get_download_tool)

    log "INFO" "Downloading $url to $output using $tool"

    case "$tool" in
        curl)
            curl -fsSL -o "$output" "$url" || return 1
            ;;
        wget)
            wget -q -O "$output" "$url" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Download to stdout
download_stdout() {
    local url="$1"
    local tool
    tool=$(get_download_tool)

    case "$tool" in
        curl)
            curl -fsSL "$url" || return 1
            ;;
        wget)
            wget -q -O - "$url" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Fetch GitHub API data
github_api_call() {
    local endpoint="$1"
    local url="https://api.github.com/repos/${GITHUB_REPO}${endpoint}"

    log "INFO" "GitHub API call: $url"

    local response
    response=$(download_stdout "$url" 2>&1) || {
        log "ERROR" "GitHub API call failed: $url"
        return 1
    }

    # Check for rate limiting
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local message
        message=$(echo "$response" | jq -r '.message')
        if [[ "$message" == *"rate limit"* ]]; then
            error "GitHub API rate limit exceeded. Please try again later."
            log "ERROR" "GitHub API rate limit exceeded"
            return 1
        fi
    fi

    echo "$response"
}

# Get latest release from GitHub
get_latest_release() {
    local release_data
    release_data=$(github_api_call "/releases/latest") || {
        error "Failed to fetch latest release from GitHub"
        info "Please check your internet connection and try again"
        return 1
    }

    echo "$release_data"
}

# Get all releases from GitHub
get_all_releases() {
    local releases_data
    releases_data=$(github_api_call "/releases") || {
        error "Failed to fetch releases from GitHub"
        return 1
    }

    echo "$releases_data"
}

# Extract version from release data
get_release_version() {
    local release_data="$1"
    echo "$release_data" | jq -r '.tag_name' | sed 's/^v//'
}

# Get download URL for plugin file from release
get_plugin_download_url() {
    local release_data="$1"
    local plugin_url

    # Try to find TrueNASPlugin.pm in assets
    plugin_url=$(echo "$release_data" | jq -r '.assets[] | select(.name == "TrueNASPlugin.pm") | .browser_download_url' 2>/dev/null)

    if [[ -z "$plugin_url" || "$plugin_url" == "null" ]]; then
        # Fallback to raw GitHub URL
        local tag_name
        tag_name=$(echo "$release_data" | jq -r '.tag_name')
        plugin_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${tag_name}/TrueNASPlugin.pm"
    fi

    echo "$plugin_url"
}

# Compare two semantic versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    local IFS=.
    local i ver1=($v1) ver2=($v2)

    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done

    return 0
}

# Check if update is available
check_for_updates() {
    local current_version="$1"
    local latest_release
    latest_release=$(get_latest_release) || return 1

    local latest_version
    latest_version=$(get_release_version "$latest_release")

    log "INFO" "Current version: $current_version, Latest version: $latest_version"

    compare_versions "$current_version" "$latest_version"
    local result=$?

    if [[ $result -eq 2 ]]; then
        # Current version is older
        echo "$latest_version"
        return 0
    else
        # Current version is same or newer
        return 1
    fi
}

# Download plugin file with progress
download_plugin() {
    local url="$1"
    local output="$2"
    local show_progress="${3:-true}"

    if [[ "$show_progress" == "true" ]]; then
        info "Downloading plugin from GitHub..."
    fi

    # Create temporary file
    local temp_file="${output}.tmp"

    if download_file "$url" "$temp_file"; then
        mv "$temp_file" "$output"
        log "INFO" "Plugin downloaded successfully to $output"
        return 0
    else
        rm -f "$temp_file"
        log "ERROR" "Failed to download plugin from $url"
        return 1
    fi
}

# ============================================================================
# BACKUP AND ROLLBACK
# ============================================================================

# Create backup of plugin file
backup_plugin() {
    if [[ ! -f "$PLUGIN_FILE" ]]; then
        log "INFO" "No existing plugin to backup"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local version
    version=$(get_installed_version)
    local backup_file="${BACKUP_DIR}/TrueNASPlugin.pm.backup.${version:-unknown}.${timestamp}"

    cp "$PLUGIN_FILE" "$backup_file" || {
        error "Failed to create backup"
        return 1
    }

    success "Backup created: $backup_file"
    log "INFO" "Backup created: $backup_file"
    return 0
}

# List available backups
list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 1
    fi

    find "$BACKUP_DIR" -name "TrueNASPlugin.pm.backup.*" -type f | sort -r
}

# ============================================================================
# PLUGIN INSTALLATION
# ============================================================================

# Validate plugin syntax
validate_plugin() {
    local plugin_file="$1"

    info "Validating plugin syntax..."
    if perl -c "$plugin_file" >/dev/null 2>&1; then
        success "Plugin syntax is valid"
        return 0
    else
        error "Plugin syntax validation failed"
        perl -c "$plugin_file" 2>&1 | head -10
        return 1
    fi
}

# Install plugin file
install_plugin_file() {
    local source="$1"
    local backup="${2:-true}"

    # Create backup if requested and file exists
    if [[ "$backup" == "true" ]]; then
        backup_plugin || {
            error "Backup failed. Installation aborted for safety."
            return 1
        }
    fi

    # Validate plugin before installation
    if ! validate_plugin "$source"; then
        error "Plugin validation failed. Installation aborted."
        return 1
    fi

    # Install plugin
    info "Installing plugin to $PLUGIN_FILE..."
    cp "$source" "$PLUGIN_FILE" || {
        error "Failed to copy plugin file"
        return 1
    }

    # Set correct permissions
    chown root:root "$PLUGIN_FILE"
    chmod 644 "$PLUGIN_FILE"

    success "Plugin installed successfully"
    log "INFO" "Plugin installed to $PLUGIN_FILE"
    return 0
}

# Restart PVE services
restart_pve_services() {
    info "Restarting Proxmox services..."

    local services=("pvedaemon" "pveproxy")
    local failed=false

    for service in "${services[@]}"; do
        if systemctl restart "$service" 2>/dev/null; then
            success "Restarted $service"
        else
            error "Failed to restart $service"
            failed=true
        fi
    done

    if [[ "$failed" == "true" ]]; then
        warning "Some services failed to restart. Please check manually."
        return 1
    fi

    # Wait a moment and verify services are running
    sleep 2
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            success "$service is running"
        else
            error "$service is not running"
            failed=true
        fi
    done

    if [[ "$failed" == "true" ]]; then
        return 1
    fi

    success "All Proxmox services restarted successfully"
    return 0
}

# Full installation workflow
perform_installation() {
    local version="${1:-latest}"

    print_header "Installing TrueNAS Plugin"

    # Get release information
    local release_data
    if [[ "$version" == "latest" ]]; then
        info "Fetching latest release from GitHub..."
        release_data=$(get_latest_release) || return 1
    else
        info "Fetching release $version from GitHub..."
        release_data=$(github_api_call "/releases/tags/v${version}") || {
            error "Version $version not found"
            return 1
        }
    fi

    local install_version
    install_version=$(get_release_version "$release_data")
    info "Installing version: $install_version"

    # Get download URL
    local download_url
    download_url=$(get_plugin_download_url "$release_data")
    info "Download URL: $download_url"

    # Download to temporary location
    local temp_file="/tmp/TrueNASPlugin.pm.$$"
    if ! download_plugin "$download_url" "$temp_file"; then
        error "Failed to download plugin"
        rm -f "$temp_file"
        return 1
    fi

    # Install the plugin
    if ! install_plugin_file "$temp_file"; then
        error "Installation failed"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"

    # Restart services
    if ! restart_pve_services; then
        warning "Plugin installed but services may need manual restart"
    fi

    echo
    success "TrueNAS Plugin v${install_version} installed successfully!"
    return 0
}

# ============================================================================
# INTERACTIVE MENU SYSTEM
# ============================================================================

# Display menu and get user choice
show_menu() {
    local title="$1"
    shift
    local options=("$@")

    echo
    print_color "$COLOR_BOLD$COLOR_CYAN" "╔════════════════════════════════════════════════════════╗"
    print_color "$COLOR_BOLD$COLOR_CYAN" "  $title"
    print_color "$COLOR_BOLD$COLOR_CYAN" "╚════════════════════════════════════════════════════════╝"
    echo

    local i=1
    for option in "${options[@]}"; do
        echo "  $i) $option"
        ((i++))
    done
    echo "  0) Exit"
    echo
}

# Read user menu choice
read_choice() {
    local max="$1"
    local choice

    while true; do
        read -rp "Enter choice [0-${max}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 ]] && [[ "$choice" -le "$max" ]]; then
            echo "$choice"
            return 0
        else
            error "Invalid choice. Please enter a number between 0 and $max"
        fi
    done
}

# Main menu for when plugin is not installed
menu_not_installed() {
    while true; do
        # Check if backups exist
        local backups
        backups=$(list_backups 2>/dev/null | wc -l)
        local has_backups=false
        if [[ "$backups" -gt 0 ]]; then
            has_backups=true
        fi

        # Build menu options dynamically
        local menu_options=("Install latest version" "Install specific version" "View available versions")
        local max_choice=3

        if [[ "$has_backups" = true ]]; then
            menu_options+=("Restore from backup ($backups available)")
            max_choice=4
        fi

        show_menu "TrueNAS Plugin - Not Installed" "${menu_options[@]}"

        local choice
        choice=$(read_choice "$max_choice")

        case $choice in
            0)
                info "Exiting installer"
                exit $EXIT_SUCCESS
                ;;
            1)
                if perform_installation "latest"; then
                    # Prompt to configure storage after successful installation
                    if [[ "$NON_INTERACTIVE" != "true" ]]; then
                        echo
                        read -rp "Would you like to configure storage now? (y/n): " response
                        if [[ "$response" =~ ^[Yy] ]]; then
                            menu_configure_storage
                        else
                            info "You can configure storage later from the main menu"
                            read -rp "Press Enter to continue..."
                        fi
                    fi
                else
                    read -rp "Press Enter to continue..."
                fi
                return 0
                ;;
            2)
                menu_install_specific_version
                ;;
            3)
                menu_view_versions
                ;;
            4)
                if [[ "$has_backups" = true ]]; then
                    menu_rollback
                else
                    error "Invalid choice"
                fi
                ;;
        esac
    done
}

# Main menu for when plugin is installed
menu_installed() {
    local current_version="$1"

    while true; do
        # Check for updates
        local update_notice=""
        local latest_version
        if latest_version=$(check_for_updates "$current_version" 2>/dev/null); then
            update_notice=" (Update available: v${latest_version})"
        fi

        show_menu "TrueNAS Plugin v${current_version} - Installed${update_notice}" \
            "Update to latest version" \
            "Install specific version" \
            "Configure storage" \
            "View available versions" \
            "Rollback to backup" \
            "Uninstall plugin"

        local choice
        choice=$(read_choice 6)

        case $choice in
            0)
                info "Exiting installer"
                exit $EXIT_SUCCESS
                ;;
            1)
                perform_installation "latest"
                return 0
                ;;
            2)
                menu_install_specific_version
                ;;
            3)
                menu_configure_storage
                ;;
            4)
                menu_view_versions
                ;;
            5)
                menu_rollback
                ;;
            6)
                menu_uninstall
                return 0
                ;;
        esac
    done
}

# Menu: View available versions
menu_view_versions() {
    print_header "Available Versions"

    info "Fetching releases from GitHub..."
    local releases
    releases=$(get_all_releases) || {
        error "Failed to fetch releases"
        read -rp "Press Enter to continue..."
        return 1
    }

    echo
    echo "$releases" | jq -r '.[] | "  • v" + (.tag_name | ltrimstr("v")) + " - " + .name + " (" + (.published_at | split("T")[0]) + ")"' | head -20
    echo

    if [[ $(echo "$releases" | jq '. | length') -gt 20 ]]; then
        info "Showing latest 20 releases. Visit GitHub for full list."
    fi

    read -rp "Press Enter to continue..."
}

# Menu: Install specific version
menu_install_specific_version() {
    print_header "Install Specific Version"

    info "Fetching releases from GitHub..."
    local releases
    releases=$(get_all_releases) || {
        error "Failed to fetch releases"
        read -rp "Press Enter to continue..."
        return 1
    }

    echo
    echo "Available versions:"
    echo "$releases" | jq -r '.[] | "  • v" + (.tag_name | ltrimstr("v"))' | head -20
    echo

    read -rp "Enter version number (e.g., 1.0.7): " version

    if [[ -z "$version" ]]; then
        warning "Installation cancelled"
        return 1
    fi

    if perform_installation "$version"; then
        # Prompt to configure storage after successful installation
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            echo
            read -rp "Would you like to configure storage now? (y/n): " response
            if [[ "$response" =~ ^[Yy] ]]; then
                menu_configure_storage
            else
                info "You can configure storage later from the main menu"
                read -rp "Press Enter to continue..."
            fi
        fi
    else
        read -rp "Press Enter to continue..."
    fi
}

# ============================================================================
# CONFIGURATION WIZARD
# ============================================================================

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate storage name format
validate_storage_name() {
    local name="$1"
    # Storage name should be alphanumeric with hyphens/underscores, no spaces
    if [[ $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    return 1
}

# Check if storage name already exists
storage_name_exists() {
    local name="$1"
    if [[ -f "$STORAGE_CFG" ]]; then
        grep -q "^truenas: ${name}$" "$STORAGE_CFG"
    else
        return 1
    fi
}

# Test TrueNAS API connectivity
test_truenas_api() {
    local ip="$1"
    local apikey="$2"

    local url="https://${ip}/api/v2.0/system/info"
    local tool
    tool=$(get_download_tool)

    info "Testing connection to TrueNAS at $ip..."

    local response
    case "$tool" in
        curl)
            response=$(curl -sk -H "Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        wget)
            response=$(wget --no-check-certificate --quiet -O - --header="Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ -n "$response" ]] && echo "$response" | jq -e '.version' >/dev/null 2>&1; then
        local version
        version=$(echo "$response" | jq -r '.version' 2>/dev/null)
        success "Connected to TrueNAS successfully (version: $version)"
        return 0
    else
        error "Failed to connect to TrueNAS API"
        return 1
    fi
}

# Verify dataset exists
verify_dataset() {
    local ip="$1"
    local apikey="$2"
    local dataset="$3"

    local url="https://${ip}/api/v2.0/pool/dataset?id=${dataset}"
    local tool
    tool=$(get_download_tool)

    local response
    case "$tool" in
        curl)
            response=$(curl -sk -H "Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        wget)
            response=$(wget --no-check-certificate --quiet -O - --header="Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ -n "$response" ]] && echo "$response" | jq -e '.[0].id' >/dev/null 2>&1; then
        success "Dataset '$dataset' verified"
        return 0
    else
        warning "Dataset '$dataset' not found or not accessible"
        return 1
    fi
}

# Backup storage.cfg
backup_storage_cfg() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        log "INFO" "No storage.cfg to backup"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/storage.cfg.backup.${timestamp}"

    cp "$STORAGE_CFG" "$backup_file" || {
        error "Failed to create storage.cfg backup"
        return 1
    }

    success "Storage config backed up: $backup_file"
    log "INFO" "Storage config backed up: $backup_file"
    return 0
}

# Generate storage configuration block
generate_storage_config() {
    local name="$1"
    local ip="$2"
    local apikey="$3"
    local dataset="$4"
    local target="$5"
    local portal="${6:-}"
    local blocksize="${7:-16k}"
    local sparse="${8:-1}"

    cat <<EOF
truenasplugin: ${name}
	api_host ${ip}
	api_key ${apikey}
	dataset ${dataset}
	target_iqn ${target}
	api_insecure 1
	shared 1
EOF

    if [[ -n "$portal" ]]; then
        echo "	discovery_portal ${portal}"
    fi

    if [[ -n "$blocksize" ]]; then
        echo "	zvol_blocksize ${blocksize}"
    fi

    if [[ -n "$sparse" ]]; then
        echo "	tn_sparse ${sparse}"
    fi
}

# Add storage configuration to storage.cfg
add_storage_config() {
    local config="$1"

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    # Append configuration
    echo "" >> "$STORAGE_CFG"
    echo "$config" >> "$STORAGE_CFG"

    success "Storage configuration added to $STORAGE_CFG"
    log "INFO" "Storage configuration added"
    return 0
}

# Configuration wizard
menu_configure_storage() {
    print_header "Storage Configuration Wizard"

    info "This wizard will help you configure TrueNAS storage for Proxmox"
    echo

    # Storage name
    local storage_name
    while true; do
        read -rp "Storage name (e.g., truenas-main): " storage_name
        if [[ -z "$storage_name" ]]; then
            error "Storage name cannot be empty"
            continue
        fi
        if ! validate_storage_name "$storage_name"; then
            error "Invalid storage name. Use only letters, numbers, hyphens, and underscores"
            continue
        fi
        if storage_name_exists "$storage_name"; then
            error "Storage name '$storage_name' already exists in $STORAGE_CFG"
            read -rp "Choose a different name? (y/n): " choice
            [[ "$choice" =~ ^[Yy] ]] && continue || return 1
        fi
        break
    done

    # TrueNAS IP
    local truenas_ip
    while true; do
        read -rp "TrueNAS IP address: " truenas_ip
        if validate_ip "$truenas_ip"; then
            break
        else
            error "Invalid IP address format"
        fi
    done

    # API Key
    local api_key
    read -rp "TrueNAS API key: " api_key
    if [[ -z "$api_key" ]]; then
        error "API key cannot be empty"
        return 1
    fi

    # Test connectivity
    if ! test_truenas_api "$truenas_ip" "$api_key"; then
        error "Failed to connect to TrueNAS. Please check IP and API key."
        read -rp "Continue anyway? (y/n): " choice
        [[ "$choice" =~ ^[Yy] ]] || return 1
    fi

    # Dataset
    local dataset
    read -rp "ZFS dataset path (e.g., tank/proxmox): " dataset
    if [[ -z "$dataset" ]]; then
        error "Dataset cannot be empty"
        return 1
    fi

    # Verify dataset if API connection worked
    verify_dataset "$truenas_ip" "$api_key" "$dataset" || true

    # iSCSI Target
    local target
    read -rp "iSCSI target (e.g., iqn.2025-01.com.truenas:target0): " target
    if [[ -z "$target" ]]; then
        error "iSCSI target cannot be empty"
        return 1
    fi

    # Portal (optional)
    local portal
    read -rp "Portal IP (optional, press Enter to use TrueNAS IP): " portal
    if [[ -z "$portal" ]]; then
        portal="$truenas_ip"
    fi

    # Blocksize (optional)
    local blocksize
    read -rp "Block size [16k]: " blocksize
    blocksize="${blocksize:-16k}"

    # Sparse (optional)
    local sparse
    read -rp "Enable sparse volumes? (0/1) [1]: " sparse
    sparse="${sparse:-1}"

    # Generate configuration
    echo
    info "Configuration summary:"
    echo "─────────────────────────────────────────────────────────"
    local config
    config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target" "$portal" "$blocksize" "$sparse")
    echo "$config"
    echo "─────────────────────────────────────────────────────────"
    echo

    read -rp "Add this configuration to $STORAGE_CFG? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        warning "Configuration cancelled"
        return 1
    fi

    # Add configuration
    if add_storage_config "$config"; then
        echo
        success "Storage configured successfully!"
        info "You can now use '$storage_name' storage in Proxmox"
        echo
        info "Next steps:"
        echo "  1. Test the storage by creating a VM disk:"
        echo "     qm create 999 --name test-vm && qm set 999 --scsi0 ${storage_name}:10"
        echo "  2. Check storage status: pvesm status"
        echo "  3. View storage details: pvesm list ${storage_name}"
    else
        error "Failed to add configuration"
        return 1
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# ROLLBACK FUNCTIONALITY
# ============================================================================

# Restore from backup
restore_plugin_from_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        return 1
    fi

    info "Restoring plugin from backup..."

    # Validate backup before restoring
    if ! validate_plugin "$backup_file"; then
        error "Backup file validation failed"
        return 1
    fi

    # Create a backup of current version before rollback
    backup_plugin || warning "Could not backup current version"

    # Restore the backup
    cp "$backup_file" "$PLUGIN_FILE" || {
        error "Failed to restore backup"
        return 1
    }

    # Set correct permissions
    chown root:root "$PLUGIN_FILE"
    chmod 644 "$PLUGIN_FILE"

    success "Plugin restored from backup"
    log "INFO" "Plugin restored from: $backup_file"

    # Restart services
    restart_pve_services || warning "Services may need manual restart"

    return 0
}

# Menu: Rollback
menu_rollback() {
    print_header "Rollback to Previous Version"

    info "Searching for available backups..."
    local backups
    backups=$(list_backups)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        info "Backups are stored in: $BACKUP_DIR"
        read -rp "Press Enter to continue..."
        return 1
    fi

    echo
    echo "Available backups:"
    echo "─────────────────────────────────────────────────────────"

    local -a backup_array
    local index=1
    while IFS= read -r backup; do
        # Extract version and timestamp from filename
        local filename
        filename=$(basename "$backup")
        # Format: TrueNASPlugin.pm.backup.VERSION.TIMESTAMP
        # Remove prefix to get VERSION.TIMESTAMP
        local version_timestamp
        version_timestamp=$(echo "$filename" | sed 's/TrueNASPlugin\.pm\.backup\.//')
        # Split on last underscore (timestamp starts with YYYYMMDD_)
        local version
        version=$(echo "$version_timestamp" | sed 's/\.[0-9]*_[0-9]*$//')
        local timestamp
        timestamp=$(echo "$version_timestamp" | sed 's/.*\.\([0-9]*_[0-9]*\)$/\1/')

        # Format timestamp for display
        local display_time
        if [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
            display_time="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        else
            display_time="$timestamp"
        fi

        echo "  $index) Version $version - $display_time"
        backup_array+=("$backup")
        ((index++))
    done <<< "$backups"

    echo "  0) Cancel"
    echo "─────────────────────────────────────────────────────────"
    echo

    local choice
    choice=$(read_choice $((index - 1)))

    if [[ "$choice" -eq 0 ]]; then
        info "Rollback cancelled"
        return 0
    fi

    local selected_backup="${backup_array[$((choice - 1))]}"

    echo
    warning "This will replace the current plugin with the selected backup"
    read -rp "Continue with rollback? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Rollback cancelled"
        read -rp "Press Enter to continue..."
        return 0
    fi

    if restore_plugin_from_backup "$selected_backup"; then
        success "Rollback completed successfully"
    else
        error "Rollback failed"
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

# Remove storage configuration
remove_storage_config() {
    local storage_name="$1"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        info "No storage.cfg file found"
        return 0
    fi

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    info "Removing storage '$storage_name' from configuration..."

    # Create temporary file
    local temp_file="${STORAGE_CFG}.tmp"

    # Remove the storage block (truenas: line and all indented lines after it)
    awk -v storage="truenas: ${storage_name}" '
        $0 ~ "^" storage "$" { skip=1; next }
        /^[^ \t]/ { skip=0 }
        !skip { print }
    ' "$STORAGE_CFG" > "$temp_file"

    mv "$temp_file" "$STORAGE_CFG"
    success "Storage configuration removed"
    return 0
}

# List all TrueNAS storage entries
list_truenas_storage() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    grep "^truenas:" "$STORAGE_CFG" | sed 's/^truenas: //' || return 1
}

# Uninstall plugin
uninstall_plugin() {
    local remove_config="${1:-false}"

    print_header "Uninstalling TrueNAS Plugin"

    # Backup before removing
    backup_plugin || warning "Could not create backup before uninstallation"

    # Remove plugin file
    if [[ -f "$PLUGIN_FILE" ]]; then
        rm "$PLUGIN_FILE" || {
            error "Failed to remove plugin file"
            return 1
        }
        success "Plugin file removed"
    else
        info "Plugin file not found (already removed)"
    fi

    # Handle storage configuration
    if [[ "$remove_config" == "true" ]]; then
        local storages
        storages=$(list_truenas_storage)

        if [[ -n "$storages" ]]; then
            echo
            info "Found TrueNAS storage configurations:"
            echo "$storages" | while read -r storage; do
                echo "  • $storage"
            done
            echo

            read -rp "Remove all TrueNAS storage configurations? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
                echo "$storages" | while read -r storage; do
                    remove_storage_config "$storage"
                done
            fi
        fi
    fi

    # Restart services
    restart_pve_services || warning "Services may need manual restart"

    echo
    success "TrueNAS Plugin uninstalled successfully"
    echo
    info "Important notes:"
    echo "  • Plugin backup saved in: $BACKUP_DIR"
    echo "  • Data on TrueNAS is NOT affected"
    echo "  • iSCSI extents and targets remain on TrueNAS"
    echo "  • You can reinstall the plugin at any time"

    if [[ "$remove_config" != "true" ]]; then
        echo
        info "Storage configuration remains in $STORAGE_CFG"
        info "Remove manually if no longer needed"
    fi

    return 0
}

# Menu: Uninstall
menu_uninstall() {
    print_header "Uninstall TrueNAS Plugin"

    warning "This will remove the TrueNAS plugin from Proxmox"
    echo
    info "Important information:"
    echo "  • VMs using TrueNAS storage will lose disk access"
    echo "  • Data on TrueNAS will NOT be deleted"
    echo "  • A backup will be created before removal"
    echo "  • You can rollback using the backup if needed"
    echo

    read -rp "Are you sure you want to uninstall? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Uninstallation cancelled"
        return 0
    fi

    echo
    read -rp "Also remove storage configuration from $STORAGE_CFG? (y/n): " remove_config_choice

    local remove_config=false
    [[ "$remove_config_choice" =~ ^[Yy] ]] && remove_config=true

    if uninstall_plugin "$remove_config"; then
        success "Uninstallation complete"
    else
        error "Uninstallation failed"
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"

    # Initialize logging
    init_logging

    # Print banner
    print_header "TrueNAS Proxmox VE Plugin Installer v${INSTALLER_VERSION}"

    # Perform checks
    info "Checking system requirements..."
    check_root
    check_dependencies
    success "System requirements satisfied"

    # Get current installation state
    local install_state
    install_state=$(get_install_state)

    if [[ "$install_state" == "not_installed" ]]; then
        info "Plugin is not currently installed"

        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            # Non-interactive mode: install latest version
            info "Non-interactive mode: Installing latest version..."
            perform_installation "latest"
            exit $?
        else
            # Interactive mode: show menu
            menu_not_installed
        fi
    else
        # Plugin is installed
        local current_version="${install_state#installed:}"
        info "Plugin v${current_version} is currently installed"

        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            # Non-interactive mode: check for updates and install if available
            info "Non-interactive mode: Checking for updates..."
            if latest_version=$(check_for_updates "$current_version" 2>/dev/null); then
                info "Update available: v${latest_version}"
                perform_installation "latest"
                exit $?
            else
                success "Already on latest version"
                exit 0
            fi
        else
            # Interactive mode: show menu
            menu_installed "$current_version"
        fi
    fi

    log "INFO" "Installer completed successfully"
}

# Run main function
main "$@"
