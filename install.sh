#!/usr/bin/env bash
# vim: noai:ts=4:sw=4:expandtab
# shellcheck disable=SC2015,SC2016
#
# TrueNAS Proxmox VE Plugin Installer
# Interactive installation, update, and configuration wizard
#
# TODO: Orphan resource detection currently only supports iSCSI mode.
#       NVMe/TCP orphan detection requires WebSocket API support which is
#       not yet implemented in bash. Future enhancement should add WebSocket
#       client for nvmet.subsys.query and nvmet.namespace.query calls.

set -euo pipefail

# ============================================================================
# CONSTANTS AND CONFIGURATION
# ============================================================================

readonly INSTALLER_VERSION="1.3.0"
readonly GITHUB_REPO="WarlockSyno/truenasplugin"
readonly PLUGIN_FILE="/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
readonly STORAGE_CFG="/etc/pve/storage.cfg"
readonly BACKUP_DIR="/var/lib/truenas-plugin-backups"
readonly LOG_FILE="/var/log/truenas-installer.log"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_USER_CANCEL=2

# Escape sequence helper
esc() {
    case $1 in
        CUU) printf '\033[%sA' "${2:-1}" ;;      # cursor up
        CUD) printf '\033[%sB' "${2:-1}" ;;      # cursor down
        CUF) printf '\033[%sC' "${2:-1}" ;;      # cursor forward
        CUB) printf '\033[%sD' "${2:-1}" ;;      # cursor backward
        SCP) printf '\033[s' ;;                   # save cursor position
        RCP) printf '\033[u' ;;                   # restore cursor position
        SGR) printf '\033[%sm' "$2" ;;            # Select Graphic Rendition
    esac
}

# Detect terminal color support
detect_color_support() {
    # Check COLORTERM for truecolor support first (before TTY check)
    if [[ "${COLORTERM:-}" =~ (truecolor|24bit) ]]; then
        echo "truecolor"
        return
    fi

    # Check TERM environment variable for explicit color capability
    if [[ "$TERM" =~ 256color ]]; then
        echo "256"
        return
    elif [[ "$TERM" =~ (xterm-color|.*-256|xterm-16color) ]]; then
        echo "256"
        return
    fi

    # Try tput if available
    local colors
    colors=$(tput colors 2>/dev/null || echo 0)

    if [[ "$colors" -ge 256 ]]; then
        echo "256"
    elif [[ "$colors" -ge 16 ]]; then
        echo "16"
    elif [[ "$colors" -ge 8 ]]; then
        echo "8"
    else
        # Enhanced fallback logic
        # SSH sessions typically support 256 colors
        if [[ -n "$SSH_CLIENT" || -n "$SSH_TTY" || -n "$SSH_CONNECTION" ]]; then
            echo "256"
        elif [[ "$TERM" =~ (xterm|screen|tmux|rxvt|linux|ansi|vt) ]]; then
            echo "16"
        else
            # Check if we have a TTY - if so, assume basic colors
            if [[ -t 1 ]] || [[ -t 0 ]]; then
                echo "16"
            else
                echo "none"
            fi
        fi
    fi
}

# Color support level (can be overridden with INSTALLER_COLORS env var)
readonly COLOR_SUPPORT="${INSTALLER_COLORS:-$(detect_color_support)}"

# Debug: Show detected color support (comment out in production)
# Uncomment the line below to debug color detection:
# echo "DEBUG: COLOR_SUPPORT=$COLOR_SUPPORT TERM=$TERM SSH_CLIENT=${SSH_CLIENT:-none}" >&2

# Color definitions (Dylan Araps style)
c0=$(esc SGR 0)      # reset
c1=$(esc SGR 31)     # red
c2=$(esc SGR 32)     # green
c3=$(esc SGR 33)     # yellow
c4=$(esc SGR 34)     # blue
c5=$(esc SGR 35)     # magenta
c6=$(esc SGR 36)     # cyan
c7=$(esc SGR 37)     # white
c8=$(esc SGR 1)      # bold

# Legacy color compatibility
readonly COLOR_RESET="$c0"
readonly COLOR_RED="$c1"
readonly COLOR_GREEN="$c2"
readonly COLOR_YELLOW="$c3"
readonly COLOR_BLUE="$c4"
readonly COLOR_CYAN="$c6"
readonly COLOR_BOLD="$c8"

# 256-color palette generator
color256() {
    printf '\033[38;5;%dm' "$1"
}

# RGB color (truecolor) generator
rgb() {
    printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"
}

# Generate gradient color for line number (0-based)
# Uses cyan to blue gradient (Neofetch-inspired)
gradient_color() {
    local line_num="$1"
    local total_lines="${2:-15}"

    case "$COLOR_SUPPORT" in
        truecolor)
            # Smooth RGB gradient: cyan (0,255,255) -> blue (0,100,255) -> deep blue (0,50,200)
            local ratio=$((line_num * 100 / total_lines))
            local r=0
            local g=$((255 - ratio * 155 / 100))
            local b=$((255 - ratio * 55 / 100))
            rgb "$r" "$g" "$b"
            ;;
        256)
            # Use 256-color palette: cyan spectrum
            # Colors: 51(cyan) -> 45 -> 39 -> 33(blue)
            local colors=(51 50 49 48 45 44 39 38 33 32 27 26 21 20 19)
            local idx=$((line_num * ${#colors[@]} / total_lines))
            [[ $idx -ge ${#colors[@]} ]] && idx=$((${#colors[@]} - 1))
            color256 "${colors[$idx]}"
            ;;
        16|8)
            # Gradient using basic colors: cyan -> blue
            # Divide into thirds for smooth-ish transition
            local third=$((total_lines / 3))
            if [[ $line_num -lt $third ]]; then
                # First third: bright cyan
                printf '\033[1;36m'
            elif [[ $line_num -lt $((third * 2)) ]]; then
                # Middle third: cyan
                printf '%s' "$c6"
            else
                # Last third: blue
                printf '%s' "$c4"
            fi
            ;;
        *)
            # No color support - return empty string
            :
            ;;
    esac
}

# ============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# ============================================================================

# Global spinner control
SPINNER_PID=""

# Start spinner animation
start_spinner() {
    local spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spinner_pos=0

    # Hide cursor
    printf "\033[?25l" >&2

    # Create a wrapper script that runs spinner in its own process group
    # This ensures all children (including sleep) can be killed together
    local spinner_script="/tmp/.installer-spinner-$$.sh"
    cat > "$spinner_script" << 'SPINNER_EOF'
#!/bin/bash
# Create new process group
set -m

# Trap to kill entire process group on exit
cleanup() {
    # Kill all processes in this process group
    kill -- -$$ 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT HUP EXIT

# Spinner loop
spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_pos=0
max_iterations=3000
iterations=0

while [[ $iterations -lt $max_iterations ]]; do
    printf "\033[s%s\033[u" "${spinner_chars[$spinner_pos]}" >&2
    spinner_pos=$(( (spinner_pos + 1) % 10 ))
    iterations=$((iterations + 1))
    sleep 0.1
done
SPINNER_EOF

    chmod +x "$spinner_script"

    # Start spinner script in background
    "$spinner_script" &
    SPINNER_PID=$!

    # Give it a moment to set up its process group
    sleep 0.05
}

# Stop spinner animation
stop_spinner() {
    if [[ -n "$SPINNER_PID" ]] && [[ "$SPINNER_PID" != "0" ]]; then
        # Check if process exists
        if kill -0 "$SPINNER_PID" 2>/dev/null; then
            # Kill the entire process group (negative PID)
            # This kills the spinner script AND all its children (including sleep)
            kill -- -"$SPINNER_PID" 2>/dev/null || true

            # Also send to the process itself
            kill -TERM "$SPINNER_PID" 2>/dev/null || true

            # Wait briefly for termination (max 1 second)
            local wait_count=0
            while [[ $wait_count -lt 10 ]]; do
                if ! kill -0 "$SPINNER_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.1
                wait_count=$((wait_count + 1))
            done

            # Force kill if still alive
            if kill -0 "$SPINNER_PID" 2>/dev/null; then
                kill -9 "$SPINNER_PID" 2>/dev/null || true
                kill -9 -"$SPINNER_PID" 2>/dev/null || true
            fi

            # Final cleanup: kill any remaining children
            pkill -P "$SPINNER_PID" 2>/dev/null || true
        fi

        # Clean up temporary spinner script
        rm -f "/tmp/.installer-spinner-$$.sh" 2>/dev/null || true

        SPINNER_PID=""
    fi

    # Show cursor - calling code will overwrite spinner with \r
    printf "\033[?25h" >&2
}

# Clear screen
clear_screen() {
    printf '\033[2J\033[H'
}

# Clear from cursor to end of screen
clear_below() {
    printf '\033[0J'
}

# Display ASCII banner with gradient colors
print_banner() {
    # Banner lines array
    local -a lines=(
        "    "
        "   d8P                                                       "
        "d888888P                                                     "
        "  ?88'    88bd88b?88   d8P d8888b  88bd88b  d888b8b   .d888b,"
        "  88P     88P'  \`d88   88 d8b_,dP  88P' ?8bd8P' ?88   ?8b,   "
        "  88b    d88     ?8(  d88 88b     d88   88P88b  ,88b    \`?8b "
        "  \`?8b  d88'     \`?88P'?8b\`?888P'd88'   88b\`?88P'\`88b\`?888P' "
        "                                                              "
        "              d8b                      d8,          "
        "              88P                     \`8P           "
        "             d88                                    "
        "   ?88,.d88b,888  ?88   d8P d888b8b    88b  88bd88b "
        "   \`?88'  ?88?88  d88   88 d8P' ?88    88P  88P' ?8b"
        "     88b  d8P 88b ?8(  d88 88b  ,88b  d88  d88   88P"
        "     888888P'  88b\`?88P'?8b\`?88P'\`88bd88' d88'   88b"
        "     88P'                         )88               "
        "    d88                          ,88P     For Proxmox VE"
        "    ?8P                      \`?8888P                "
        " "
    )

    local total_lines=${#lines[@]}

    # Print each line with gradient color
    local i=0
    for line in "${lines[@]}"; do
        local color
        color=$(gradient_color "$i" "$total_lines")
        printf '%b%s%b\n' "$color" "$line" "$c0"
        i=$((i + 1))
    done
}

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

# Info message (blue)
info() {
    printf '%b\n' "${c4}  ${*}${c0}"
    log "INFO" "$*"
}

# Success message (green)
success() {
    printf '%b\n' "${c2}  ${*}${c0}"
    log "SUCCESS" "$*"
}

# Warning message (yellow)
warning() {
    printf '%b\n' "${c3}  ${*}${c0}"
    log "WARNING" "$*"
}

# Error message (red)
error() {
    printf '%b\n' "${c1}  ${*}${c0}" >&2
    log "ERROR" "$*"
}

# Fatal error - print and exit
fatal() {
    error "$*"
    exit $EXIT_ERROR
}

# Print section header
print_header() {
    printf '\n%b\n' "${c6}${c8}${*}${c0}"
    printf '%b\n\n' "${c6}$(printf '%*s' ${#1} '' | tr ' ' '-')${c0}"
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
# CLUSTER DETECTION
# ============================================================================

# Detect if running on a Proxmox cluster node
is_cluster_node() {
    # Check if /etc/pve directory exists and has cluster configuration
    if [[ -d "/etc/pve/nodes" ]] && [[ $(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
        return 0
    fi
    return 1
}

# Get cluster node count
get_cluster_node_count() {
    if [[ -d "/etc/pve/nodes" ]]; then
        find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

# Display cluster warning
show_cluster_warning() {
    local node_count
    node_count=$(get_cluster_node_count)

    if [[ "$node_count" -gt 1 ]]; then
        echo
        warning "⚠️  Proxmox Cluster Detected (${node_count} nodes)"
        echo
        info "This installer only updates the current node."
        info "To update all cluster nodes, use the cluster update script:"
        echo
        echo "  wget https://raw.githubusercontent.com/${GITHUB_REPO}/main/tools/update-cluster.sh"
        echo "  chmod +x update-cluster.sh"
        echo "  ./update-cluster.sh node1 node2 node3"
        echo
        return 0
    fi
    return 1
}

# Get current node name from cluster membership
get_current_node_name() {
    if [[ ! -f /etc/pve/.members ]]; then
        echo ""
        return 1
    fi

    # Extract nodename from JSON
    grep -Po '"nodename":\s*"\K[^"]+' /etc/pve/.members 2>/dev/null || echo ""
}

# Get list of all cluster nodes with their IPs
# Returns array of "nodename:ip" strings
get_cluster_nodes() {
    if [[ ! -f /etc/pve/.members ]]; then
        return 1
    fi

    local -a nodes=()
    local content
    content=$(cat /etc/pve/.members 2>/dev/null) || return 1

    # Validate basic JSON structure
    if [[ ! "$content" =~ \{.*nodelist.*\} ]]; then
        log "ERROR" "Invalid or corrupted /etc/pve/.members file - missing nodelist structure"
        return 1
    fi

    # Extract nodelist section and parse each node entry
    # Look for pattern: "nodename": { ... "ip": "x.x.x.x" ... }
    local in_nodelist=false
    local current_node=""

    while IFS= read -r line; do
        # Check if we're in the nodelist section
        if [[ "$line" =~ \"nodelist\" ]]; then
            in_nodelist=true
            continue
        fi

        if [[ "$in_nodelist" == true ]]; then
            # Extract node name from line like: "nodename": {
            # Supports any valid hostname (alphanumeric, dots, hyphens, underscores)
            if [[ "$line" =~ \"([a-zA-Z0-9._-]+)\":[[:space:]]*\{ ]]; then
                current_node="${BASH_REMATCH[1]}"
            fi

            # Extract IP from line like: "ip": "10.15.14.195"
            if [[ -n "$current_node" ]] && [[ "$line" =~ \"ip\":[[:space:]]*\"([0-9.]+)\" ]]; then
                local ip="${BASH_REMATCH[1]}"

                # Validate IP format (basic check for x.x.x.x pattern)
                if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    # Validate each octet is 0-255
                    local valid=true
                    IFS='.' read -ra octets <<< "$ip"
                    for octet in "${octets[@]}"; do
                        if [[ "$octet" -gt 255 ]]; then
                            valid=false
                            break
                        fi
                    done

                    if [[ "$valid" == true ]]; then
                        nodes+=("${current_node}:${ip}")
                    fi
                fi
                current_node=""
            fi

            # Exit nodelist section when we hit the closing brace for the nodelist object
            # Only exit if we have nodes and we're not in a node sub-object (current_node is empty)
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*(,)?[[:space:]]*$ ]]; then
                if [[ ${#nodes[@]} -gt 0 ]] && [[ -z "$current_node" ]]; then
                    break
                fi
            fi
        fi
    done <<< "$content"

    # Output the nodes array
    printf '%s\n' "${nodes[@]}"
    return 0
}

# Get list of remote cluster nodes (excludes current node)
# Returns array of "nodename:ip" strings
get_remote_cluster_nodes() {
    local current_node
    current_node=$(get_current_node_name)

    if [[ -z "$current_node" ]]; then
        return 1
    fi

    local -a all_nodes
    mapfile -t all_nodes < <(get_cluster_nodes)

    local -a remote_nodes=()
    for node in "${all_nodes[@]}"; do
        local name="${node%%:*}"
        if [[ "$name" != "$current_node" ]]; then
            remote_nodes+=("$node")
        fi
    done

    # Output the remote nodes array
    printf '%s\n' "${remote_nodes[@]}"
    return 0
}

# Validate SSH connectivity to a cluster node
# Args: $1 = node IP
# Returns: 0 on success, 1 on failure
validate_ssh_to_node() {
    local node_ip="$1"

    if [[ -z "$node_ip" ]]; then
        return 1
    fi

    # Test SSH with timeout and batch mode (no password prompts)
    if ssh -o ConnectTimeout=5 \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new \
           "root@${node_ip}" "echo test" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Validate SSH connectivity to all cluster nodes
# Populates arrays: ssh_reachable_nodes, ssh_unreachable_nodes
# Returns: 0 if all nodes reachable, 1 if any unreachable
validate_cluster_ssh() {
    local -a remote_nodes
    mapfile -t remote_nodes < <(get_remote_cluster_nodes)

    if [[ ${#remote_nodes[@]} -eq 0 ]]; then
        info "No remote cluster nodes found"
        return 0
    fi

    info "Validating SSH connectivity to cluster nodes..."
    echo

    ssh_reachable_nodes=()
    ssh_unreachable_nodes=()

    for node_info in "${remote_nodes[@]}"; do
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"

        printf "  Testing %s (%s)... " "$node_name" "$node_ip"

        if validate_ssh_to_node "$node_ip"; then
            echo "${c3}✓ Reachable${c0}"
            ssh_reachable_nodes+=("$node_info")
        else
            echo "${c5}✗ Unreachable${c0}"
            ssh_unreachable_nodes+=("$node_info")
        fi
    done

    echo

    if [[ ${#ssh_unreachable_nodes[@]} -gt 0 ]]; then
        warning "Some nodes are not reachable via SSH:"
        for node_info in "${ssh_unreachable_nodes[@]}"; do
            local node_name="${node_info%%:*}"
            local node_ip="${node_info##*:}"
            echo "  • $node_name ($node_ip)"
        done
        echo
        info "Ensure passwordless SSH is configured between cluster nodes"
        info "To test manually: ssh root@<node_ip> hostname"
        return 1
    fi

    success "All cluster nodes are reachable via SSH"
    return 0
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

# Get pre-release status for installed version
# Returns: "true" if pre-release, "false" otherwise
get_installed_prerelease_status() {
    local version="$1"

    if [[ -z "$version" ]]; then
        echo "false"
        return 0
    fi

    # Fetch release data from GitHub for this version
    local release_data
    release_data=$(github_api_call "/releases/tags/v${version}" 2>/dev/null) || {
        # If API call fails, assume not a pre-release
        echo "false"
        return 0
    }

    get_release_prerelease_status "$release_data"
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

# Cleanup all background processes
cleanup_all() {
    # Stop spinner first
    stop_spinner

    # Kill any remaining background jobs
    local jobs_pids
    jobs_pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$jobs_pids" ]]; then
        # shellcheck disable=SC2086
        kill $jobs_pids 2>/dev/null || true
    fi

    # Extra safety: kill any orphaned sleep 0.1 processes that belong to this script
    # This is a safety net for any edge cases
    pkill -f "sleep 0\.1" 2>/dev/null || true

    # Restore cursor visibility
    printf "\033[?25h" >&2

    # If interrupted (not normal exit), show user-friendly message
    if [[ "${1:-}" == "interrupted" ]]; then
        echo
        echo
        warning "Installation interrupted by user"
    fi
}

# Set up error trap and cleanup
trap 'cleanup_all; cleanup_on_error' EXIT
trap 'cleanup_all interrupted; exit 130' INT
trap 'cleanup_all; exit 143' TERM

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

    # One-liner installation from GitHub (auto-detects non-interactive)
    curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash

    # Or with wget
    wget -qO- https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash

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
    local timeout="${2:-5}"  # Default 5 second timeout
    local tool
    tool=$(get_download_tool)

    case "$tool" in
        curl)
            curl -fsSL --connect-timeout "$timeout" --max-time "$((timeout * 2))" "$url" || return 1
            ;;
        wget)
            wget -q -O - --connect-timeout="$timeout" --read-timeout="$((timeout * 2))" "$url" || return 1
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

    # Check for rate limiting - only check message field if response lacks expected success fields
    # GitHub success responses have tag_name, assets, etc. Error responses have message field.
    if ! echo "$response" | grep -q '"tag_name"\|"assets"\|"version"'; then
        # This looks like an error response, check for rate limit message
        if echo "$response" | grep -q '"message"'; then
            local message
            message=$(echo "$response" | grep -Po '"message":\s*"\K[^"]+')
            if [[ "$message" == *"rate limit"* ]]; then
                error "GitHub API rate limit exceeded. Please try again later."
                log "ERROR" "GitHub API rate limit exceeded"
                return 1
            fi
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
    echo "$release_data" | grep -Po '"tag_name":\s*"\K[^"]+' | sed 's/^v//'
}

# Check if release is a pre-release
# Returns: "true" if pre-release, "false" otherwise
get_release_prerelease_status() {
    local release_data="$1"
    local prerelease
    prerelease=$(echo "$release_data" | grep -Po '"prerelease":\s*\K(true|false)' | head -1)
    echo "${prerelease:-false}"
}

# Get download URL for plugin file from release
get_plugin_download_url() {
    local release_data="$1"
    local plugin_url

    # Try to find TrueNASPlugin.pm in assets
    # Use sed to extract assets section more reliably than grep -Pzo
    plugin_url=""

    # Check if the asset exists and extract its download URL
    if echo "$release_data" | grep -q '"name":\s*"TrueNASPlugin\.pm"'; then
        # Found the matching asset, extract the browser_download_url from context
        local context_lines
        context_lines=$(echo "$release_data" | grep -A 10 '"name":\s*"TrueNASPlugin\.pm"')
        plugin_url=$(echo "$context_lines" | grep -Po '"browser_download_url":\s*"\K[^"]+' | head -1)
    fi

    if [[ -z "$plugin_url" || "$plugin_url" == "null" ]]; then
        # Fallback to raw GitHub URL
        local tag_name
        tag_name=$(echo "$release_data" | grep -Po '"tag_name":\s*"\K[^"]+')
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
# Returns: "version:prerelease" (e.g., "1.1.3:true") if update available, empty otherwise
check_for_updates() {
    local current_version="$1"
    local latest_release
    latest_release=$(get_latest_release) || return 1

    local latest_version
    latest_version=$(get_release_version "$latest_release")

    local is_prerelease
    is_prerelease=$(get_release_prerelease_status "$latest_release")

    log "INFO" "Current version: $current_version, Latest version: $latest_version, Pre-release: $is_prerelease"

    compare_versions "$current_version" "$latest_version"
    local result=$?

    if [[ $result -eq 2 ]]; then
        # Current version is older
        echo "${latest_version}:${is_prerelease}"
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

# Human-readable file size
format_size() {
    local bytes="$1"
    local size

    if [[ "$bytes" -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ "$bytes" -lt $((1024 * 1024)) ]]; then
        size=$((bytes / 1024))
        echo "${size}KB"
    elif [[ "$bytes" -lt $((1024 * 1024 * 1024)) ]]; then
        size=$((bytes / 1024 / 1024))
        echo "${size}MB"
    else
        size=$((bytes / 1024 / 1024 / 1024))
        echo "${size}GB"
    fi
}

# Calculate backup age in days
backup_age_days() {
    local backup_file="$1"
    local file_time
    local current_time
    local age_seconds

    file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
    current_time=$(date +%s)
    age_seconds=$((current_time - file_time))
    echo $((age_seconds / 86400))
}

# Format age in human-readable form
format_age() {
    local days="$1"

    if [[ "$days" -eq 0 ]]; then
        echo "Today"
    elif [[ "$days" -eq 1 ]]; then
        echo "1 day ago"
    elif [[ "$days" -lt 30 ]]; then
        echo "${days} days ago"
    elif [[ "$days" -lt 365 ]]; then
        local months=$((days / 30))
        if [[ "$months" -eq 1 ]]; then
            echo "1 month ago"
        else
            echo "${months} months ago"
        fi
    else
        local years=$((days / 365))
        if [[ "$years" -eq 1 ]]; then
            echo "1 year ago"
        else
            echo "${years} years ago"
        fi
    fi
}

# Scan backups and return statistics
scan_backups() {
    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        echo "0:0:0:0"  # count:total_size:oldest_age:newest_age
        return
    fi

    local count=0
    local total_size=0
    local oldest_age=0
    local newest_age=999999

    while IFS= read -r backup; do
        ((count++))
        local size
        size=$(stat -c %s "$backup" 2>/dev/null || stat -f %z "$backup" 2>/dev/null)
        total_size=$((total_size + size))

        local age
        age=$(backup_age_days "$backup")

        if [[ "$age" -gt "$oldest_age" ]]; then
            oldest_age="$age"
        fi

        if [[ "$age" -lt "$newest_age" ]]; then
            newest_age="$age"
        fi
    done <<< "$backups"

    echo "${count}:${total_size}:${oldest_age}:${newest_age}"
}

# Check if backup cleanup should be offered
should_offer_cleanup() {
    local stats
    stats=$(scan_backups)

    IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

    # Thresholds (can be customized via env vars)
    local max_backups="${BACKUP_MAX_COUNT:-10}"
    local max_age_days="${BACKUP_MAX_AGE_DAYS:-90}"
    local max_size_mb="${BACKUP_MAX_SIZE_MB:-100}"

    local total_size_mb=$((total_size / 1024 / 1024))

    # Offer cleanup if any threshold is exceeded
    if [[ "$count" -gt "$max_backups" ]] || \
       [[ "$oldest_age" -gt "$max_age_days" ]] || \
       [[ "$total_size_mb" -gt "$max_size_mb" ]]; then
        return 0
    fi

    return 1
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

    # Ensure target directory exists
    local plugin_dir
    plugin_dir="$(dirname "$PLUGIN_FILE")"
    if [[ ! -d "$plugin_dir" ]]; then
        info "Creating plugin directory $plugin_dir..."
        mkdir -p "$plugin_dir" || {
            error "Failed to create plugin directory"
            return 1
        }
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

# Install plugin on a remote cluster node
# Args: $1 = node IP, $2 = local plugin file path, $3 = version string (for backup naming)
# Returns: 0 on success, 1 on failure, 2 on success with service restart failure
install_plugin_on_remote_node() {
    local node_ip="$1"
    local plugin_file="$2"
    local version="$3"

    if [[ -z "$node_ip" || ! -f "$plugin_file" ]]; then
        log "ERROR" "Remote installation: Invalid parameters (ip=$node_ip, file=$plugin_file)"
        return 1
    fi

    local temp_remote="/tmp/TrueNASPlugin.pm.$$"
    log "INFO" "Starting remote installation to $node_ip (version $version)"

    # Transfer plugin file to remote node
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${node_ip}" \
        "cat > ${temp_remote}" < "$plugin_file" 2>/dev/null; then
        log "ERROR" "Remote installation to $node_ip: SSH transfer failed"
        echo "SSH transfer failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: File transferred successfully"

    # Validate plugin syntax on remote node
    if ! ssh "root@${node_ip}" "perl -c ${temp_remote}" >/dev/null 2>&1; then
        ssh "root@${node_ip}" "rm -f ${temp_remote}" 2>/dev/null
        log "ERROR" "Remote installation to $node_ip: Syntax validation failed"
        echo "Syntax validation failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: Syntax validation passed"

    # Create backup directory on remote if it doesn't exist
    ssh "root@${node_ip}" "mkdir -p ${BACKUP_DIR}" 2>/dev/null

    # Create backup on remote node (if plugin exists) using remote timestamp
    local backup_result
    backup_result=$(ssh "root@${node_ip}" "
        if [[ -f ${PLUGIN_FILE} ]]; then
            remote_ts=\$(date +%Y%m%d_%H%M%S)
            if cp ${PLUGIN_FILE} ${BACKUP_DIR}/TrueNASPlugin.pm.backup.${version}.\${remote_ts} 2>&1; then
                echo 'success'
            else
                echo 'failed'
            fi
        else
            echo 'no-plugin'
        fi
    " 2>&1)

    if [[ "$backup_result" == "failed" ]]; then
        log "WARNING" "Remote installation to $node_ip: Backup creation failed (proceeding anyway)"
        echo "Backup creation failed (proceeding anyway)" >&2
    elif [[ "$backup_result" == "success" ]]; then
        log "INFO" "Remote installation to $node_ip: Backup created successfully"
    fi

    # Install plugin on remote node atomically with error handling
    if ! ssh "root@${node_ip}" "
        set -e
        mkdir -p \$(dirname ${PLUGIN_FILE})
        cp ${temp_remote} ${PLUGIN_FILE}
        chown root:root ${PLUGIN_FILE}
        chmod 644 ${PLUGIN_FILE}
        rm -f ${temp_remote}
    " 2>&1; then
        # Clean up temp file on failure
        ssh "root@${node_ip}" "rm -f ${temp_remote}" 2>/dev/null || true
        log "ERROR" "Remote installation to $node_ip: Installation failed"
        echo "Installation failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: Plugin installed successfully"

    # Restart services on remote node
    if ! ssh "root@${node_ip}" "systemctl restart pvedaemon pveproxy" 2>/dev/null; then
        log "WARNING" "Remote installation to $node_ip: Service restart failed"
        echo "Service restart failed - manual restart required"
        return 2  # Special return code: installed but needs manual service restart
    fi
    log "INFO" "Remote installation to $node_ip: Services restarted successfully"

    return 0
}

# Display cluster installation summary
# Args: arrays successful_nodes, failed_nodes, failure_reasons
show_cluster_install_summary() {
    local total=$((${#successful_nodes[@]} + ${#failed_nodes[@]}))

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#successful_nodes[@]} -gt 0 ]]; then
        success "Successfully updated ${#successful_nodes[@]} of $total nodes:"
        for node in "${successful_nodes[@]}"; do
            echo "  ${c3}✓${c0} $node"
        done
    fi

    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo
        warning "Failed to update ${#failed_nodes[@]} nodes:"
        for i in "${!failed_nodes[@]}"; do
            echo "  ${c5}✗${c0} ${failed_nodes[$i]}: ${failure_reasons[$i]}"
        done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Perform cluster-wide installation
# Args: $1 = version (e.g., "latest" or "1.0.7")
# Returns: 0 if any nodes succeeded, 1 if all failed
perform_cluster_wide_installation() {
    local version="${1:-latest}"
    local include_local="${2:-true}"

    print_header "Installing TrueNAS Plugin (Cluster-Wide)"

    # Check for non-interactive mode
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        error "Cluster-wide installation requires interactive mode"
        info "In non-interactive mode, the installer only updates the local node"
        return 1
    fi

    # Validate cluster and SSH connectivity
    if ! is_cluster_node; then
        error "This is not a cluster node"
        info "Cluster-wide installation is only available for clustered nodes"
        return 1
    fi

    # Get remote nodes
    local -a remote_nodes
    mapfile -t remote_nodes < <(get_remote_cluster_nodes)

    if [[ ${#remote_nodes[@]} -eq 0 ]]; then
        warning "No remote cluster nodes found"
        info "Falling back to local installation only"
        perform_installation "$version"
        return $?
    fi

    # Show cluster information
    local current_node
    current_node=$(get_current_node_name)
    info "Current node: $current_node"
    info "Remote nodes: ${#remote_nodes[@]}"
    for node_info in "${remote_nodes[@]}"; do
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"
        echo "  • $node_name ($node_ip)"
    done
    echo

    # Validate SSH connectivity
    declare -a ssh_reachable_nodes
    declare -a ssh_unreachable_nodes

    if ! validate_cluster_ssh; then
        echo
        read -rp "Continue with only reachable nodes? [y/N]: " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
            info "Cluster installation cancelled"
            return 1
        fi
        # Update remote_nodes to only include reachable ones
        remote_nodes=("${ssh_reachable_nodes[@]}")
    fi

    # Confirmation prompt before proceeding
    echo
    warning "This will install/update the TrueNAS plugin on all cluster nodes"
    info "Total nodes to update: $((${#remote_nodes[@]} + 1)) (1 local + ${#remote_nodes[@]} remote)"
    echo
    read -rp "Do you want to proceed? [y/N]: " confirm_choice
    if [[ ! "$confirm_choice" =~ ^[Yy] ]]; then
        info "Cluster installation cancelled"
        return 1
    fi

    # Download plugin from GitHub
    info "Fetching release from GitHub..."
    local release_data
    if [[ "$version" == "latest" ]]; then
        release_data=$(get_latest_release) || return 1
    else
        release_data=$(github_api_call "/releases/tags/v${version}") || {
            error "Version $version not found"
            return 1
        }
    fi

    local install_version
    install_version=$(get_release_version "$release_data")
    info "Installing version: $install_version"

    # Check if this is a pre-release and warn user
    local is_prerelease
    is_prerelease=$(get_release_prerelease_status "$release_data")
    if [[ "$is_prerelease" == "true" ]]; then
        echo
        warning "⚠️  This is a PRE-RELEASE version"
        info "Pre-release versions may contain bugs and are not recommended for production use"
        echo
        read -rp "Do you want to continue with cluster-wide installation? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            info "Installation cancelled"
            return 1
        fi
    fi

    local download_url
    download_url=$(get_plugin_download_url "$release_data")

    local temp_file="/tmp/TrueNASPlugin.pm.$$"
    if ! download_plugin "$download_url" "$temp_file"; then
        error "Failed to download plugin"
        rm -f "$temp_file"
        return 1
    fi

    # Initialize arrays for tracking installation results
    declare -a successful_nodes=()
    declare -a failed_nodes=()
    declare -a failure_reasons=()

    # Install on local node first if requested
    if [[ "$include_local" == "true" ]]; then
        echo
        info "Installing on local node ($current_node)..."

        if install_plugin_file "$temp_file"; then
            if restart_pve_services; then
                success "Local node installation completed"
                successful_nodes+=("$current_node")
            else
                warning "Local node installed but services may need manual restart"
                successful_nodes+=("$current_node (services need restart)")
            fi
        else
            error "Local node installation failed"
            rm -f "$temp_file"
            return 1
        fi
    fi

    # Install on remote nodes
    echo
    info "Installing on remote cluster nodes..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    local total_nodes=${#remote_nodes[@]}
    local current=0

    for node_info in "${remote_nodes[@]}"; do
        ((current++))
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"

        printf "[%d/%d] %s (%s): " "$current" "$total_nodes" "$node_name" "$node_ip"
        start_spinner

        local error_msg
        error_msg=$(install_plugin_on_remote_node "$node_ip" "$temp_file" "$install_version" 2>&1)
        local result=$?

        stop_spinner
        if [[ $result -eq 0 ]]; then
            printf "\r[%d/%d] %s (%s): ${c3}✓ Success${c0}\n" "$current" "$total_nodes" "$node_name" "$node_ip"
            successful_nodes+=("$node_name")
        elif [[ $result -eq 2 ]]; then
            printf "\r[%d/%d] %s (%s): ${c4}⚠ Success (restart needed)${c0}\n" "$current" "$total_nodes" "$node_name" "$node_ip"
            successful_nodes+=("$node_name (services need restart)")
        else
            printf "\r[%d/%d] %s (%s): ${c5}✗ Failed${c0}\n" "$current" "$total_nodes" "$node_name" "$node_ip"
            failed_nodes+=("$node_name")
            failure_reasons+=("${error_msg:-Unknown error}")
        fi
    done

    rm -f "$temp_file"

    # Show summary
    show_cluster_install_summary

    # Offer retry for failed nodes
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo
        read -rp "Retry failed nodes? [y/N]: " retry_choice
        if [[ "$retry_choice" =~ ^[Yy] ]]; then
            info "Waiting 5 seconds before retry..."
            sleep 5

            # Download plugin again for retry
            local retry_temp="/tmp/TrueNASPlugin.pm.retry.$$"
            if download_plugin "$download_url" "$retry_temp"; then
                echo
                info "Retrying failed nodes..."
                echo

                declare -a retry_successful=()
                declare -a retry_failed=()
                declare -a retry_reasons=()

                for i in "${!failed_nodes[@]}"; do
                    local node_name="${failed_nodes[$i]}"

                    # Find node IP from original list
                    local node_ip=""
                    for node_info in "${remote_nodes[@]}"; do
                        if [[ "${node_info%%:*}" == "$node_name" ]]; then
                            node_ip="${node_info##*:}"
                            break
                        fi
                    done

                    if [[ -z "$node_ip" ]]; then
                        continue
                    fi

                    printf "  %s (%s): " "$node_name" "$node_ip"

                    local retry_error
                    retry_error=$(install_plugin_on_remote_node "$node_ip" "$retry_temp" "$install_version" 2>&1)
                    local retry_result=$?

                    if [[ $retry_result -eq 0 ]]; then
                        echo "${c3}✓ Success${c0}"
                        retry_successful+=("$node_name")
                        # Move from failed to successful
                        successful_nodes+=("$node_name")
                    elif [[ $retry_result -eq 2 ]]; then
                        echo "${c4}⚠ Success (restart needed)${c0}"
                        retry_successful+=("$node_name (services need restart)")
                        successful_nodes+=("$node_name (services need restart)")
                    else
                        echo "${c5}✗ Failed${c0}"
                        retry_failed+=("$node_name")
                        retry_reasons+=("${retry_error:-Unknown error}")
                    fi
                done

                rm -f "$retry_temp"

                # Update failed lists
                failed_nodes=("${retry_failed[@]}")
                failure_reasons=("${retry_reasons[@]}")

                # Show updated summary
                show_cluster_install_summary
            fi
        fi
    fi

    echo

    if [[ ${#successful_nodes[@]} -gt 0 ]]; then
        success "Cluster-wide installation completed"

        if [[ "$include_local" == "true" ]]; then
            show_next_steps
        fi

        return 0
    else
        error "All cluster nodes failed to update"
        return 1
    fi
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

    # Check if this is a pre-release and warn user
    local is_prerelease
    is_prerelease=$(get_release_prerelease_status "$release_data")
    if [[ "$is_prerelease" == "true" ]] && [[ "$NON_INTERACTIVE" != "true" ]]; then
        echo
        warning "⚠️  This is a PRE-RELEASE version"
        info "Pre-release versions may contain bugs and are not recommended for production use"
        echo
        read -rp "Do you want to continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            info "Installation cancelled"
            return 1
        fi
    fi

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

    # Show cluster warning if applicable
    if is_cluster_node; then
        show_cluster_warning
    fi

    # Show next steps
    show_next_steps

    return 0
}

# Display next steps and helpful information
show_next_steps() {
    echo
    info "Next steps:"
    echo "  1. Configure TrueNAS storage (if not done yet)"
    echo "  2. Run health check to verify connectivity"
    echo "  3. Create test VM to validate storage"
    echo
    info "Useful commands:"
    echo "  • Check storage status:    pvesm status"
    echo "  • List TrueNAS storage:    pvesm list <storage-name>"
    echo "  • Check iSCSI sessions:    iscsiadm -m session"
    echo
    info "Documentation:"
    echo "  • GitHub: https://github.com/${GITHUB_REPO}"
    echo "  • Wiki: https://github.com/${GITHUB_REPO}/wiki"
    echo
    info "Example: Create a test VM"
    echo "  qm create 999 --name test-vm --memory 2048 --net0 virtio,bridge=vmbr0"
    echo "  qm set 999 --scsi0 <storage-name>:10"
    echo "  qm start 999"
    echo
}

# ============================================================================
# INTERACTIVE MENU SYSTEM
# ============================================================================

# Display menu and get user choice
show_menu() {
    local title="$1"
    shift
    local options=("$@")

    printf '\n%b\n' "${c6}${c8}${title}${c0}"
    printf '%b\n\n' "${c6}$(printf '%*s' ${#title} '' | tr ' ' '-')${c0}"

    local i=1
    for option in "${options[@]}"; do
        printf '  %b%s%b %s\n' "${c6}" "$i)" "${c0}" "$option"
        ((i++))
    done
    printf '  %b%s%b %s\n\n' "${c3}" "0)" "${c0}" "Exit"
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
            # Move cursor up, clear to end of screen, show error, then re-prompt
            printf "\033[1A\033[J"
            echo ""
            echo "  ${c5}✗${c0} Invalid choice. Please enter a number between 0 and $max"
            echo ""
        fi
    done
}

# Main menu for when plugin is not installed
menu_not_installed() {
    while true; do
        # Clear screen and show banner
        clear_screen
        print_banner

        # Check if backups exist
        local backups
        backups=$(list_backups 2>/dev/null | wc -l || echo "0")
        local has_backups=false
        if [[ "$backups" -gt 0 ]]; then
            has_backups=true
        fi

        # Build menu options dynamically
        local menu_options=("Install latest version" "Install specific version" "View available versions")
        local max_choice=3

        # Add cluster-wide option if in a cluster
        local cluster_option_position=0
        if is_cluster_node; then
            menu_options+=("Install latest version (all cluster nodes)")
            max_choice=4
            cluster_option_position=4
        fi

        if [[ "$has_backups" = true ]]; then
            menu_options+=("Restore from backup ($backups available)")
            max_choice=$((max_choice + 1))
        fi

        # Check if backup cleanup should be offered
        local should_manage_backups=false
        if should_offer_cleanup; then
            should_manage_backups=true
            menu_options+=("Manage backups")
            max_choice=$((max_choice + 1))
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
                        read -rp "Would you like to configure storage now? [y/N]: " response
                        if [[ "$response" =~ ^[Yy] ]]; then
                            menu_configure_storage
                            # Offer health check after configuration
                            echo
                            read -rp "Would you like to run a health check now? [y/N]: " hc_response
                            if [[ "$hc_response" =~ ^[Yy] ]]; then
                                echo
                                menu_health_check
                            fi
                        fi
                    fi
                    read -rp "Press Enter to return to main menu..."
                    # After successful installation, break out to re-detect state
                    return 0
                else
                    read -rp "Press Enter to return to main menu..."
                fi
                ;;
            2)
                if menu_install_specific_version; then
                    # After successful installation, break out to re-detect state
                    return 0
                fi
                read -rp "Press Enter to return to main menu..."
                ;;
            3)
                menu_view_versions
                ;;
            4)
                # Check if this is cluster-wide option or backup/manage option
                if [[ "$cluster_option_position" -eq 4 ]]; then
                    # Cluster-wide installation
                    if perform_cluster_wide_installation "latest"; then
                        read -rp "Press Enter to return to main menu..."
                        return 0
                    else
                        read -rp "Press Enter to return to main menu..."
                    fi
                elif [[ "$has_backups" = true ]]; then
                    menu_rollback
                elif [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
            5)
                if [[ "$has_backups" = true ]]; then
                    menu_rollback
                elif [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
            6)
                if [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
        esac
    done
}

# Sub-menu for choosing update target (local or cluster-wide)
menu_update_choice() {
    local current_version="$1"

    clear_screen
    print_banner
    echo

    # Build menu options
    local -a menu_items=("Update this node only")
    local max_choice=1

    # Add cluster-wide option if in a cluster
    if is_cluster_node; then
        menu_items+=("Update all cluster nodes")
        max_choice=2
    fi

    show_menu "Select update target" "${menu_items[@]}"

    local choice
    choice=$(read_choice "$max_choice")

    case $choice in
        0)
            return 0
            ;;
        1)
            # Update local node only
            if perform_installation "latest"; then
                # Offer to run health check after successful update
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    echo
                    read -rp "Would you like to run a health check now? [y/N]: " response
                    if [[ "$response" =~ ^[Yy] ]]; then
                        echo
                        menu_health_check
                    fi
                fi
                return 0
            else
                return 1
            fi
            ;;
        2)
            # Update all cluster nodes
            if is_cluster_node; then
                if perform_cluster_wide_installation "latest"; then
                    return 0
                else
                    return 1
                fi
            else
                error "Not running in a cluster"
                return 1
            fi
            ;;
    esac
}

# Main menu for when plugin is installed
menu_installed() {
    local current_version="$1"

    while true; do
        # Refresh current version in case it was updated
        local latest_installed_version
        latest_installed_version=$(get_installed_version)
        if [[ -n "$latest_installed_version" ]]; then
            current_version="$latest_installed_version"
        fi

        # Clear screen and show banner
        clear_screen
        print_banner

        # Check if current version is a pre-release
        local current_prerelease_tag=""
        local current_is_prerelease
        current_is_prerelease=$(get_installed_prerelease_status "$current_version" 2>/dev/null)
        if [[ "$current_is_prerelease" == "true" ]]; then
            current_prerelease_tag=" ${c3}(Pre-Release)${c0}"
        fi

        # Check for updates
        local update_notice=""
        local update_info
        if update_info=$(check_for_updates "$current_version" 2>/dev/null); then
            local latest_version="${update_info%%:*}"
            local latest_prerelease="${update_info##*:}"
            local prerelease_tag=""

            if [[ "$latest_prerelease" == "true" ]]; then
                prerelease_tag=" ${c3}(Pre-Release)${c0}"
            fi

            update_notice=" (Update available: v${latest_version}${prerelease_tag})"
        fi

        # Check if backup cleanup should be offered
        local should_manage_backups=false
        if should_offer_cleanup; then
            should_manage_backups=true
        fi

        # Build menu dynamically
        local -a menu_items=("Update plugin" "Install specific version" "Configure storage" "Diagnostics" "Rollback to backup")
        local max_choice=5

        if [[ "$should_manage_backups" = true ]]; then
            menu_items+=("Manage backups")
            max_choice=$((max_choice + 1))
        fi

        menu_items+=("Uninstall plugin")
        max_choice=$((max_choice + 1))

        show_menu "TrueNAS Plugin v${current_version}${current_prerelease_tag} - Installed${update_notice}" "${menu_items[@]}"

        local choice
        choice=$(read_choice "$max_choice")

        case $choice in
            0)
                info "Exiting installer"
                exit $EXIT_SUCCESS
                ;;
            1)
                # Update plugin (shows sub-menu for local vs cluster)
                menu_update_choice "$current_version"
                read -rp "Press Enter to return to main menu..."
                ;;
            2)
                # Install specific version
                menu_install_specific_version
                ;;
            3)
                # Configure storage
                menu_configure_storage
                ;;
            4)
                # Diagnostics
                menu_diagnostics
                ;;
            5)
                # Rollback to backup
                menu_rollback
                ;;
            6)
                # Manage backups OR Uninstall (depends on should_manage_backups)
                if [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    menu_uninstall
                    read -rp "Press Enter to return to main menu..."
                    return 0
                fi
                ;;
            7)
                # Uninstall plugin (when manage backups is also present)
                menu_uninstall
                read -rp "Press Enter to return to main menu..."
                return 0
                ;;
        esac
    done
}

# Menu: Diagnostics
menu_diagnostics() {
    while true; do
        clear_screen
        print_banner
        echo

        show_menu "Select diagnostic action" \
            "Run health check" \
            "Create diagnostics bundle" \
            "Cleanup orphaned resources" \
            "Run plugin function test" \
            "Run FIO storage benchmark"

        local choice
        local raw_choice

        # Read choice allowing both numeric and special inputs
        while true; do
            read -rp "Enter choice [0-5]: " raw_choice

            # Check for special extended benchmark mode
            if [[ "$raw_choice" == "5+" ]]; then
                EXTENDED_BENCHMARK=true
                choice=5
                break
            elif [[ "$raw_choice" =~ ^[0-9]+$ ]] && [[ "$raw_choice" -ge 0 ]] && [[ "$raw_choice" -le 5 ]]; then
                EXTENDED_BENCHMARK=false
                choice="$raw_choice"
                break
            else
                # Move cursor up, clear to end of screen, show error, then re-prompt
                printf "\\033[1A\\033[J"
                echo ""
                echo "  ${c5}✗${c0} Invalid choice. Please enter a number between 0 and 5"
                echo ""
            fi
        done

        case $choice in
            0)
                return 0
                ;;
            1)
                # Run health check
                menu_health_check
                read -rp "Press Enter to return to diagnostics menu..."
                ;;
            2)
                # Create diagnostics bundle
                menu_create_diagnostics_bundle
                read -rp "Press Enter to return to diagnostics menu..."
                ;;
            3)
                # Cleanup orphans
                menu_cleanup_orphans
                read -rp "Press Enter to return to diagnostics menu..."
                ;;
            4)
                # Run plugin function test
                menu_plugin_test
                read -rp "Press Enter to return to diagnostics menu..."
                ;;
            5)
                # Run FIO benchmark (normal or extended based on EXTENDED_BENCHMARK flag)
                menu_fio_benchmark
                read -rp "Press Enter to return to diagnostics menu..."
                ;;
        esac
    done
}

# Menu: Plugin function test
menu_plugin_test() {
    clear_screen
    print_banner
    echo

    # Show description and warnings
    info "Plugin Function Test Suite"
    echo
    warning "This test will perform the following operations:"
    echo "  • Validate storage accessibility via Proxmox API"
    echo "  • Create test VMs with dynamic ID selection"
    echo "  • Test volume creation, snapshots, and clones"
    echo "  • Test volume resize operations"
    echo "  • Test VM start/stop lifecycle"
    echo "  • Cleanup test VMs automatically"
    echo

    if is_cluster_node; then
        info "Cluster detected - additional tests available:"
        echo "  • VM migration to remote nodes"
        echo "  • Cross-node VM cloning"
        echo
    fi

    warning "Important considerations:"
    echo "  • Test VMs will be created with IDs automatically selected from available range (990+)"
    echo "  • Storage must have at least 10GB free space"
    echo "  • Tests will take approximately 2-5 minutes to complete"
    echo "  • All test data will be cleaned up after completion"
    echo "  • Tests are non-destructive to production VMs and data"
    echo

    # Require typed confirmation
    info "Type ${c8}ACCEPT${c0} to continue or any other input to return to menu"
    local confirmation
    read -rp "Confirmation: " confirmation

    if [[ "$confirmation" != "ACCEPT" ]]; then
        warning "Test cancelled by user"
        return 0
    fi

    # Clear screen and show banner again for storage selection
    clear_screen
    print_banner
    echo

    # Show header
    info "Plugin Function Test"
    echo

    # List available TrueNAS storage
    info "Detecting TrueNAS storage configurations..."
    echo

    if [[ ! -f "$STORAGE_CFG" ]]; then
        error "Storage configuration file not found: $STORAGE_CFG"
        return 1
    fi

    local storages
    storages=$(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}')

    if [[ -z "$storages" ]]; then
        warning "No TrueNAS storage configured"
        info "Please configure storage first from the main menu"
        return 1
    fi

    # Prompt for storage selection with retry loop
    local storage_name=""
    local storage_error=""
    local first_try=true

    while true; do
        # On retry, clear screen and reshow banner
        if [[ "$first_try" == "false" ]]; then
            clear_screen
            print_banner
            echo
            info "Plugin Function Test"
            echo
            info "Detecting TrueNAS storage configurations..."
            echo
        fi
        first_try=false

        # Show error if validation failed
        if [[ -n "$storage_error" ]]; then
            error "$storage_error"
            echo
            storage_error=""
        fi

        info "Available TrueNAS storage:"
        while IFS= read -r storage; do
            echo "  • $storage"
        done <<< "$storages"
        echo

        read -rp "Enter storage name to test (or press Enter for first): " storage_name

        if [[ -z "$storage_name" ]]; then
            storage_name=$(echo "$storages" | head -1)
            info "Using: $storage_name"
            break
        fi

        # Validate storage exists
        if echo "$storages" | grep -q "^${storage_name}$"; then
            break
        else
            storage_error="Storage '$storage_name' not found in configuration"
        fi
    done

    # Clear screen and show header for test execution
    clear_screen
    print_banner
    echo

    info "Plugin Function Test"
    echo

    info "Running plugin function test on storage: $storage_name"
    echo

    # Run the test suite
    run_plugin_test "$storage_name" || true

    return 0
}

# Menu: FIO storage benchmark
menu_fio_benchmark() {
    clear_screen
    print_banner
    echo

    # Show description and warnings (adjust based on extended mode)
    info "FIO Storage Benchmark Suite"
    echo

    # Adjust warnings based on extended benchmark mode
    local test_count=30
    local runtime="25-30 minutes"
    if [[ "${EXTENDED_BENCHMARK:-false}" == "true" ]]; then
        test_count=90
        runtime="75-90 minutes"
        info "${c3}Extended Mode Activated:${c0} Running with numjobs variations (1, 4, 8)"
        echo
    fi

    warning "This benchmark will perform the following operations:"
    echo "  • Allocate a 10GB test volume directly on storage"
    echo "  • Run $test_count comprehensive I/O tests at multiple queue depths"
    echo "  • Test sequential/random read/write bandwidth and IOPS"
    echo "  • Test latency and mixed workload performance"
    echo "  • Automatically cleanup test volume after completion"
    echo

    warning "Important considerations:"
    echo "  • Storage must have at least 10GB free space"
    echo "  • Benchmarks will run for $runtime total ($test_count tests)"
    echo "  • Each test type runs at 5 queue depths (QD=1, 16, 32, 64, 128)"
    if [[ "${EXTENDED_BENCHMARK:-false}" == "true" ]]; then
        echo "  • Each queue depth tested with 3 numjobs values (1, 4, 8)"
    fi
    echo "  • Tests will generate heavy I/O load on the storage system"
    echo "  • FIO must be installed on this system (will prompt if missing)"
    echo "  • All test data will be cleaned up after completion"
    echo "  • Benchmarks are non-destructive to production data"
    echo

    # Require typed confirmation
    info "Type ${c8}ACCEPT${c0} to continue or any other input to return to menu"
    local confirmation
    read -rp "Confirmation: " confirmation

    if [[ "$confirmation" != "ACCEPT" ]]; then
        warning "Benchmark cancelled by user"
        return 0
    fi

    # Clear screen and show banner again for storage selection
    clear_screen
    print_banner
    echo

    # Show header
    info "FIO Storage Benchmark"
    echo

    # List available TrueNAS storage
    info "Detecting TrueNAS storage configurations..."
    echo

    if [[ ! -f "$STORAGE_CFG" ]]; then
        error "Storage configuration file not found: $STORAGE_CFG"
        return 1
    fi

    local storages
    storages=$(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}')

    if [[ -z "$storages" ]]; then
        warning "No TrueNAS storage configured"
        info "Please configure storage first from the main menu"
        return 1
    fi

    # Prompt for storage selection with retry loop
    local storage_name=""
    local storage_error=""
    local first_try=true

    while true; do
        # On retry, clear screen and reshow banner
        if [[ "$first_try" == "false" ]]; then
            clear_screen
            print_banner
            echo
            info "FIO Storage Benchmark"
            echo
            info "Detecting TrueNAS storage configurations..."
            echo
        fi
        first_try=false

        # Show error if validation failed
        if [[ -n "$storage_error" ]]; then
            error "$storage_error"
            echo
            storage_error=""
        fi

        info "Available TrueNAS storage:"
        while IFS= read -r storage; do
            echo "  • $storage"
        done <<< "$storages"
        echo

        read -rp "Enter storage name to benchmark (or press Enter for first): " storage_name

        if [[ -z "$storage_name" ]]; then
            storage_name=$(echo "$storages" | head -1)
            info "Using: $storage_name"
            break
        fi

        # Validate storage exists
        if echo "$storages" | grep -q "^${storage_name}$"; then
            break
        else
            storage_error="Storage '$storage_name' not found in configuration"
        fi
    done

    # Clear screen and show header for benchmark execution
    clear_screen
    print_banner
    echo

    info "FIO Storage Benchmark"
    echo

    info "Running benchmark on storage: $storage_name"
    echo

    # Run the benchmark suite (pass extended flag)
    run_fio_benchmark "$storage_name" "${EXTENDED_BENCHMARK:-false}" || true

    return 0
}

# ============================================================================
# Diagnostics Bundle Functions
# ============================================================================

# Menu: Create diagnostics bundle
menu_create_diagnostics_bundle() {
    clear_screen
    print_banner
    echo

    print_header "Diagnostics Bundle"
    echo

    warning "This will capture the following for 10 minutes:"
    echo "  - System and plugin information"
    echo "  - All TrueNAS storage configurations (API keys redacted)"
    echo "  - strace of pvestatd (captures fork/socket activity)"
    echo "  - Crash logs and coredump info"
    echo "  - pvestatd journal logs"
    echo

    # Check pvestatd is running
    local pvestatd_pid
    pvestatd_pid=$(cat /var/run/pvestatd.pid 2>/dev/null)

    if [[ -z "$pvestatd_pid" ]] || [[ ! -d "/proc/$pvestatd_pid" ]]; then
        error "pvestatd is not running. Please start it first:"
        echo "  systemctl start pvestatd"
        return 1
    fi

    info "pvestatd found (PID: $pvestatd_pid)"
    echo

    warning "This capture will take 10 minutes."
    echo

    info "Type ${c8}CAPTURE${c0} to start or any other input to cancel"
    local confirmation
    read -rp "Confirmation: " confirmation

    if [[ "$confirmation" != "CAPTURE" ]]; then
        warning "Operation cancelled by user"
        return 0
    fi

    # Clear screen and show banner for capture phase
    clear_screen
    print_banner
    echo

    info "Diagnostics Bundle Capture"
    echo

    run_diagnostics_bundle "$pvestatd_pid"
}

# Run diagnostics bundle capture
run_diagnostics_bundle() {
    local pvestatd_pid="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local logfile="/tmp/truenas-diag-${timestamp}.log"
    local strace_file="/tmp/truenas-strace-${timestamp}.log"
    local tarball="/tmp/truenas-diag-${timestamp}.tar.gz"
    local strace_duration=600  # 10 minutes
    local strace_pid=""
    local cleanup_done=false

    # Cleanup function for interrupts
    cleanup_diagnostics() {
        local sig="${1:-EXIT}"

        if [[ "${cleanup_done:-false}" == "true" ]]; then
            return 0
        fi
        cleanup_done=true

        # Disable further interrupts during cleanup
        trap '' INT TERM

        # Stop spinner if running
        stop_spinner 2>/dev/null || true

        # Kill strace if still running
        if [[ -n "${strace_pid:-}" ]] && kill -0 "$strace_pid" 2>/dev/null; then
            kill "$strace_pid" 2>/dev/null || true
            wait "$strace_pid" 2>/dev/null || true
        fi

        # Clean up temp files on interrupt (but not on normal exit)
        if [[ "$sig" == "INT" ]] || [[ "$sig" == "TERM" ]]; then
            rm -f "$logfile" "$strace_file" 2>/dev/null || true
            echo
            warning "Diagnostics bundle creation interrupted by user (CTRL+C)"
        fi

        # Restore traps
        trap - EXIT INT TERM
    }

    # Set traps for cleanup
    trap 'cleanup_diagnostics INT' INT
    trap 'cleanup_diagnostics TERM' TERM
    trap 'cleanup_diagnostics EXIT' EXIT

    # Start strace in background
    timeout ${strace_duration} strace -f -tt -o "$strace_file" \
        -e trace=clone,fork,vfork,socket,close,connect,read,write,exit_group \
        -p "$pvestatd_pid" 2>/dev/null &
    strace_pid=$!

    sleep 2  # Let strace attach

    # Collect diagnostics to log file
    printf "%-30s " "Gathering system info:"
    start_spinner

    # Use subshell to disable pipefail for diagnostic collection
    # (prevents SIGPIPE errors when head/tail close pipes early)
    (
        set +o pipefail
        echo "========================================"
        echo "  TrueNAS Proxmox Plugin Diagnostics"
        echo "  Generated: $(date)"
        echo "========================================"
        echo

        # Section 1: Plugin version + MD5 checksum
        echo "=== Plugin Information ==="
        if [[ -f "$PLUGIN_FILE" ]]; then
            echo "Plugin path: $PLUGIN_FILE"
            plugin_version=$(grep -E "^our \\\$VERSION" "$PLUGIN_FILE" 2>/dev/null | head -1 || echo "unknown")
            echo "Version: $plugin_version"
            echo "MD5: $(md5sum "$PLUGIN_FILE" 2>/dev/null | awk '{print $1}')"
            echo "Size: $(ls -lh "$PLUGIN_FILE" 2>/dev/null | awk '{print $5}')"
        else
            echo "Plugin not found at $PLUGIN_FILE"
        fi
        echo

        # Section 2: Environment
        echo "=== Environment ==="
        echo "--- Perl Version ---"
        timeout 10 perl -v 2>&1 | head -5
        echo
        echo "--- IO::Socket::SSL ---"
        timeout 10 perl -MIO::Socket::SSL -e 'print "IO::Socket::SSL version: $IO::Socket::SSL::VERSION\n"' 2>&1 || echo "Not installed"
        echo
        echo "--- OpenSSL ---"
        timeout 10 openssl version 2>&1 || echo "Not available"
        echo
        echo "--- Proxmox Version ---"
        timeout 10 pveversion -v 2>&1 || echo "pveversion not available"
        echo

        # Section 3: Storage config (all TrueNAS storages, API keys redacted)
        echo "=== Storage Configuration (API keys redacted) ==="
        if [[ -f "$STORAGE_CFG" ]]; then
            grep -A 20 "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | sed 's/api_key .*/api_key [REDACTED]/g' || echo "No TrueNAS storages configured"
        else
            echo "Storage config not found at $STORAGE_CFG"
        fi
        echo

        # Section 4: pvestatd status at start
        echo "=== pvestatd Status (Start) ==="
        timeout 10 systemctl status pvestatd --no-pager 2>&1 | head -20
        echo
        echo "PID file: $(cat /var/run/pvestatd.pid 2>/dev/null || echo 'not found')"
        echo "Process check: $(timeout 5 ps -p "$pvestatd_pid" -o pid,ppid,stat,etime,cmd --no-headers 2>/dev/null || echo 'process not found')"
        echo

        # Section 5: Open file descriptors + socket connections
        echo "=== Open File Descriptors (pvestatd) ==="
        timeout 10 ls -la /proc/"$pvestatd_pid"/fd 2>/dev/null | head -50 || echo "Cannot read fd info"
        echo
        echo "--- Socket Connections ---"
        timeout 10 ss -tunap 2>/dev/null | grep -E "pvestatd|:443|:8006" | head -30 || echo "No relevant sockets found"
        echo

        # Section 6: Process tree
        echo "=== Process Tree ==="
        timeout 10 pstree -p "$pvestatd_pid" 2>/dev/null || echo "pstree not available"
        echo

        # Section 7: Existing coredumps
        echo "=== Existing Coredumps ==="
        timeout 10 coredumpctl list --no-pager 2>/dev/null | grep -E "pvestatd|perl" | tail -10 || echo "No relevant coredumps found"
        echo

        # Section 8: Kernel crash logs (last 7 days)
        echo "=== Kernel Crash Logs (last 7 days) ==="
        timeout 10 journalctl -k --no-pager --since "7 days ago" 2>/dev/null | grep -iE "segfault|oops|bug|panic|killed" | tail -20 || echo "No kernel crash logs found"
        echo

        # Section 9: pvestatd error logs (last 7 days)
        echo "=== pvestatd Error Logs (last 7 days) ==="
        timeout 10 journalctl -u pvestatd --no-pager --since "7 days ago" 2>/dev/null | grep -iE "error|fail|die|crash|segfault|warn" | tail -50 || echo "No error logs found"
        echo

        # Section 10: System info
        echo "=== System Information ==="
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "Uptime: $(uptime)"
        echo "Memory:"
        timeout 10 free -h 2>/dev/null || echo "free not available"
        echo
        echo "CPU:"
        timeout 10 lscpu 2>/dev/null | grep -E "Model name|CPU\(s\)|Thread|Core" | head -5 || echo "lscpu not available"
        echo

    ) > "$logfile" 2>&1 || true

    stop_spinner
    echo -e "\r$(printf "%-30s " "Gathering system info:")${c2}✓${c0} Complete"

    # Wait for strace with progress bar
    local elapsed=0
    local crashed=false
    local bar_width=20

    # Show initial progress bar
    printf "%-30s " "Capturing strace (10 min):"

    while kill -0 $strace_pid 2>/dev/null && [[ $elapsed -lt $strace_duration ]]; do
        if [[ ! -d "/proc/$pvestatd_pid" ]]; then
            echo
            warning "*** PVESTATD CRASHED OR RESTARTED ***"
            info "Capturing post-crash state..."
            crashed=true
            break
        fi

        # Calculate progress
        local percent=$((elapsed * 100 / strace_duration))
        local filled=$((elapsed * bar_width / strace_duration))
        local empty=$((bar_width - filled))

        # Build progress bar
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done

        # Display progress bar with percentage
        printf "\r%-30s %s %3d%%" "Capturing strace (10 min):" "$bar" "$percent"

        sleep 10
        elapsed=$((elapsed + 10))
    done

    # Show completion (spaces clear residual progress bar characters)
    printf "\r%-30s ${c2}✓${c0} Complete                    \n" "Capturing strace (10 min):"

    # Collect post-capture state
    printf "%-30s " "Collecting final state:"
    start_spinner

    # Use subshell to disable pipefail for diagnostic collection
    (
        set +o pipefail
        echo
        echo "========================================"
        echo "  Post-Capture State"
        echo "  Captured at: $(date)"
        echo "========================================"
        echo

        # Section 11: Post-capture pvestatd status
        echo "=== pvestatd Status (End) ==="
        timeout 10 systemctl status pvestatd --no-pager 2>&1 | head -20
        echo
        new_pid=$(cat /var/run/pvestatd.pid 2>/dev/null || echo 'not found')
        echo "PID file: $new_pid"
        if [[ "$new_pid" != "$pvestatd_pid" ]]; then
            echo "*** WARNING: PID changed from $pvestatd_pid to $new_pid ***"
        fi
        echo

        # Section 12: New crash logs (if crash occurred during capture)
        if [[ "$crashed" == "true" ]]; then
            echo "=== Crash Detected During Capture ==="
            echo "--- Recent Coredumps ---"
            timeout 10 coredumpctl list --no-pager 2>/dev/null | tail -5 || echo "No coredumps"
            echo
            echo "--- Recent Kernel Messages ---"
            timeout 10 dmesg 2>/dev/null | tail -30 || timeout 10 journalctl -k --no-pager -n 30 2>/dev/null || echo "Cannot read kernel logs"
            echo
        fi

        # Section 13: Recent pvestatd logs
        echo "=== Recent pvestatd Logs ==="
        timeout 10 journalctl -u pvestatd --since "15 minutes ago" --no-pager 2>&1 | tail -100 || echo "No recent logs"
        echo

    ) >> "$logfile" 2>&1 || true

    stop_spinner
    echo -e "\r$(printf "%-30s " "Collecting final state:")${c2}✓${c0} Complete"

    # Wait for strace to finish if still running
    if kill -0 $strace_pid 2>/dev/null; then
        kill "$strace_pid" 2>/dev/null || true
        wait "$strace_pid" 2>/dev/null || true
    fi

    # Compress
    printf "%-30s " "Compressing bundle:"
    start_spinner

    cd /tmp
    tar -czf "$tarball" \
        "$(basename "$logfile")" \
        "$(basename "$strace_file")" \
        2>/dev/null

    rm -f "$logfile" "$strace_file" 2>/dev/null

    stop_spinner
    echo -e "\r$(printf "%-30s " "Compressing bundle:")${c2}✓${c0} Complete"

    # Clear the cleanup trap since we completed successfully
    trap - EXIT INT TERM

    echo
    success "Diagnostics bundle created successfully"
    echo
    echo "  Output file: ${c8}${tarball}${c0}"
    echo "  File size:   $(du -h "$tarball" 2>/dev/null | cut -f1)"
    echo
    info "Please send this file for analysis."

    return 0
}

# ============================================================================
# Plugin Test Suite Functions
# ============================================================================

# Global test variables
NODE_NAME=$(hostname)
TEST_VM_BASE=990
TEST_VM_CLONE=991
TEST_API_TIMEOUT=60

# API wrapper function - uses pvesh to interact with Proxmox API
test_api_call() {
    local method="$1"
    local path="$2"
    shift 2
    local params=("$@")

    local output
    local exit_code

    # Build pvesh command
    case "$method" in
        GET)
            output=$(timeout $TEST_API_TIMEOUT pvesh get "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        POST|CREATE)
            output=$(timeout $TEST_API_TIMEOUT pvesh create "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        PUT|SET)
            output=$(timeout $TEST_API_TIMEOUT pvesh set "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        DELETE)
            output=$(timeout $TEST_API_TIMEOUT pvesh delete "$path" "${params[@]}" 2>&1)
            exit_code=$?
            ;;
        *)
            return 1
            ;;
    esac

    # Filter out plugin warning messages
    output=$(echo "$output" | grep -v "Plugin.*older storage API" || echo "$output")

    echo "$output"
    return $exit_code
}

# Function to find available VM IDs dynamically
test_find_available_vm_ids() {
    local base_id=${1:-990}
    local found_base=false
    local found_clone=false

    # Get list of existing VMs via API
    local existing_vms=$(test_api_call GET "/cluster/resources" --type vm 2>/dev/null | grep -oP 'vmid.*?\K[0-9]+' || echo "")

    # Search for two consecutive available VM IDs
    for candidate in $(seq $base_id $((base_id + 100))); do
        local next_id=$((candidate + 1))

        # Check if both candidate and next_id are available
        if ! echo "$existing_vms" | grep -qw "$candidate" && \
           ! echo "$existing_vms" | grep -qw "$next_id"; then
            TEST_VM_BASE=$candidate
            TEST_VM_CLONE=$next_id
            found_base=true
            found_clone=true
            break
        fi
    done

    if $found_base && $found_clone; then
        return 0
    else
        return 1
    fi
}

# Wait for task completion
test_wait_for_task() {
    local task_upid="$1"
    local max_wait="${2:-120}"
    local wait_count=0

    if [[ -z "$task_upid" ]]; then
        return 0
    fi

    while [ $wait_count -lt $max_wait ]; do
        # Get task status - API returns table format with "│ status │ stopped │"
        local output=$(test_api_call GET "/nodes/$NODE_NAME/tasks/$task_upid/status" 2>&1)

        # Check if task is stopped (look for "status" row with "stopped" value)
        if echo "$output" | grep -q "│ status.*│.*stopped"; then
            return 0
        fi

        sleep 1
        ((wait_count++))
    done

    return 1
}

# Test result formatter (matches health check style)
test_result() {
    local name="$1"
    local status="$2"
    local message="$3"

    printf "%-30s " "${name}:"
    case "$status" in
        PASS)
            echo -e "${c2}✓${c0} $message"
            ;;
        FAIL)
            echo -e "${c1}✗${c0} $message"
            ;;
        SKIP)
            echo -e "${c6}-${c0} $message"
            ;;
    esac
}

# Test 1: Storage Status
test_storage_status() {
    local storage_name="$1"

    printf "%-30s " "Storage accessibility:"
    start_spinner

    if test_api_call GET "/nodes/$NODE_NAME/storage/$storage_name/status" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Storage accessibility:")${c2}✓${c0} API responsive"
        return 0
    else
        stop_spinner
        echo -e "\r$(printf "%-30s " "Storage accessibility:")${c1}✗${c0} Not accessible"
        return 1
    fi
}

# Test 2: Volume Creation
test_volume_creation() {
    local storage_name="$1"

    printf "%-30s " "Create test VM:"
    start_spinner

    local output
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu" \
        --vmid "$TEST_VM_BASE" \
        --name "test-base-vm" \
        --memory 512 \
        --cores 1 \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw "virtio-scsi-pci" 2>&1)

    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Create test VM:")${c1}✗${c0} Failed"
        return 1
    fi

    local task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Create test VM:")${c2}✓${c0} VM $TEST_VM_BASE created"

    printf "%-30s " "Add 4GB disk to VM:"
    start_spinner
    output=$(test_api_call PUT "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" --scsi0 "$storage_name:4" 2>&1)
    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Add 4GB disk to VM:")${c1}✗${c0} Failed"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Add 4GB disk to VM:")${c2}✓${c0} Disk provisioned"
    return 0
}

# Test 3: Volume Listing
test_volume_listing() {
    local storage_name="$1"

    printf "%-30s " "List volumes on storage:"
    start_spinner
    if ! test_api_call GET "/nodes/$NODE_NAME/storage/$storage_name/content" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "List volumes on storage:")${c1}✗${c0} Failed"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "List volumes on storage:")${c2}✓${c0} Listed successfully"

    printf "%-30s " "Get VM configuration:"
    start_spinner
    if ! test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Get VM configuration:")${c1}✗${c0} Failed"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Get VM configuration:")${c2}✓${c0} Retrieved successfully"
    return 0
}

# Test 4: Snapshot Operations
test_snapshot_operations() {
    local snapshot_name="test-snap-$(date +%s)"

    printf "%-30s " "Create VM snapshot:"
    start_spinner
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" \
        --snapname "$snapshot_name" \
        --description "Test snapshot via API" 2>&1)

    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Create VM snapshot:")${c1}✗${c0} Failed"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Create VM snapshot:")${c2}✓${c0} Snapshot created"

    printf "%-30s " "List VM snapshots:"
    start_spinner
    if ! test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "List VM snapshots:")${c1}✗${c0} Failed"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "List VM snapshots:")${c2}✓${c0} Listed successfully"

    printf "%-30s " "Create clone base snapshot:"
    start_spinner
    local clone_snapshot="clone-base-$(date +%s)"
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/snapshot" \
        --snapname "$clone_snapshot" \
        --description "Snapshot for clone test" 2>&1)

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Create clone base snapshot:")${c2}✓${c0} Clone base ready"

    # Save snapshot name for clone test
    echo "$clone_snapshot" > /tmp/clone_snapshot_name

    return 0
}

# Test 4b: Multi-disk Snapshot Operations (tests snapshot consistency with multiple disks)
test_multidisk_snapshot_operations() {
    # This test creates a VM with multiple disks on the same storage and verifies
    # that snapshot creation properly validates all disks (fixes silent failures)
    local storage_name="$1"
    local multidisk_vm_id=$((TEST_VM_BASE + 100))
    local snapshot_name="multidisk-snap-$(date +%s)"

    printf "%-30s " "Create multi-disk VM:"
    start_spinner

    # Create VM with 2 disks on the same storage
    if ! test_api_call POST "/nodes/$NODE_NAME/qemu" \
        --vmid "$multidisk_vm_id" \
        --name "test-multidisk-vm" \
        --memory 512 \
        --cores 1 \
        --scsihw "virtio-scsi-pci" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Create multi-disk VM:")${c1}✗${c0} Failed"
        return 1
    fi

    # Add first disk
    if ! test_api_call PUT "/nodes/$NODE_NAME/qemu/$multidisk_vm_id/config" \
        --scsi0 "${storage_name}:5" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Create multi-disk VM:")${c1}✗${c0} Failed to add disk 0"
        return 1
    fi

    # Add second disk
    if ! test_api_call PUT "/nodes/$NODE_NAME/qemu/$multidisk_vm_id/config" \
        --scsi1 "${storage_name}:5" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Create multi-disk VM:")${c1}✗${c0} Failed to add disk 1"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Create multi-disk VM:")${c2}✓${c0} VM created with 2 disks"

    printf "%-30s " "Snapshot multi-disk VM:"
    start_spinner

    # Create snapshot - both disks must succeed or fail atomically
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$multidisk_vm_id/snapshot" \
        --snapname "$snapshot_name" \
        --description "Multi-disk snapshot test" 2>&1)

    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Snapshot multi-disk VM:")${c1}✗${c0} Snapshot creation failed"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Snapshot multi-disk VM:")${c2}✓${c0} Snapshot created"

    printf "%-30s " "Delete multi-disk snapshot:"
    start_spinner

    # Verify deletion works correctly on both disks
    output=$(test_api_call DELETE "/nodes/$NODE_NAME/qemu/$multidisk_vm_id/snapshot/$snapshot_name" 2>&1)
    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Delete multi-disk snapshot:")${c1}✗${c0} Failed"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Delete multi-disk snapshot:")${c2}✓${c0} Deleted successfully"

    printf "%-30s " "Cleanup multi-disk VM:"
    start_spinner

    # Delete the test VM
    output=$(test_api_call DELETE "/nodes/$NODE_NAME/qemu/$multidisk_vm_id" 2>&1)
    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Cleanup multi-disk VM:")${c1}⚠${c0} Could not delete VM"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Cleanup multi-disk VM:")${c2}✓${c0} VM cleaned up"

    return 0
}

# Test 5: Clone Operations
test_clone_operations() {
    local clone_snapshot
    if [[ -f /tmp/clone_snapshot_name ]]; then
        clone_snapshot=$(cat /tmp/clone_snapshot_name)
    else
        test_result "Clone VM from snapshot" "FAIL" "No snapshot available"
        return 1
    fi

    printf "%-30s " "Clone VM from snapshot:"
    start_spinner

    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/clone" \
        --newid "$TEST_VM_CLONE" \
        --name "test-clone-vm" \
        --snapname "$clone_snapshot" 2>&1)

    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Clone VM from snapshot:")${c1}✗${c0} Failed to create"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 300 >/dev/null 2>&1
    fi

    if ! test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE/config" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Clone VM from snapshot:")${c1}✗${c0} Clone not verified"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Clone VM from snapshot:")${c2}✓${c0} VM $TEST_VM_CLONE created"
    return 0
}

# Test 6: Volume Resize
test_volume_resize() {
    printf "%-30s " "Resize volume (+1GB):"
    start_spinner

    if ! test_api_call PUT "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/resize" --disk scsi0 --size "+1G" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Resize volume (+1GB):")${c1}✗${c0} Failed"
        return 1
    fi

    if ! test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/config" >/dev/null 2>&1; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Resize volume (+1GB):")${c1}✗${c0} Verification failed"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Resize volume (+1GB):")${c2}✓${c0} Resized successfully"
    return 0
}

# Test 7: VM Start/Stop
test_vm_start_stop() {
    printf "%-30s " "Start VM:"
    start_spinner

    local output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/status/start" 2>&1)
    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Start VM:")${c1}✗${c0} Failed to start"
        return 1
    fi

    local task_upid=$(echo "$output" | grep "UPID:" | head -1 | awk '{print $1}')
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi

    sleep 2
    output=$(test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/status/current" 2>&1)
    if ! echo "$output" | grep -q "│ status.*│.*running"; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Start VM:")${c1}✗${c0} Not running"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Start VM:")${c2}✓${c0} VM started successfully"

    printf "%-30s " "Stop VM:"
    start_spinner
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/status/stop" 2>&1)
    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Stop VM:")${c1}✗${c0} Failed to stop"
        return 1
    fi

    task_upid=$(echo "$output" | grep "UPID:" | head -1 | awk '{print $1}')
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi

    sleep 2
    output=$(test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/status/current" 2>&1)
    if ! echo "$output" | grep -q "│ status.*│.*stopped"; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Stop VM:")${c1}✗${c0} Not stopped"
        return 1
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Stop VM:")${c2}✓${c0} VM stopped successfully"
    return 0
}

# Test 8: Volume Deletion
test_volume_deletion() {
    printf "%-30s " "Delete test VMs (--purge):"
    start_spinner

    if test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE/status/current" >/dev/null 2>&1; then
        output=$(test_api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE" --purge 1 2>&1)

        if [[ $? -ne 0 ]]; then
            stop_spinner
            echo -e "\r$(printf "%-30s " "Delete test VMs (--purge):")${c1}✗${c0} Failed to delete clone"
            return 1
        fi

        task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
        if [[ -n "$task_upid" ]]; then
            test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
        fi
        sleep 3
    fi

    output=$(test_api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE" --purge 1 2>&1)

    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Delete test VMs (--purge):")${c1}✗${c0} Failed to delete base"
        return 1
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi

    sleep 3
    stop_spinner
    echo -e "\r$(printf "%-30s " "Delete test VMs (--purge):")${c2}✓${c0} Volumes cleaned up"
    return 0
}

# Cluster Test 1: VM Migration
test_vm_migration() {
    local remote_nodes
    if ! remote_nodes=$(get_remote_cluster_nodes 2>/dev/null); then
        test_result "Migrate VM to remote node" "SKIP" "No remote nodes"
        return 0
    fi

    local target_node_info=$(echo "$remote_nodes" | head -1)
    local target_node="${target_node_info%%:*}"
    local target_ip="${target_node_info##*:}"

    if ! validate_ssh_to_node "$target_ip" 2>/dev/null; then
        test_result "Migrate VM to remote node" "SKIP" "SSH unavailable"
        return 0
    fi

    printf "%-30s " "Migrate VM to remote node:"
    start_spinner

    local migrate_vm_id=$((TEST_VM_BASE + 10))
    local existing_vms=$(test_api_call GET "/cluster/resources" --type vm 2>/dev/null | grep -oP 'vmid.*?\K[0-9]+' || echo "")
    while echo "$existing_vms" | grep -qw "$migrate_vm_id"; do
        migrate_vm_id=$((migrate_vm_id + 1))
    done

    local output
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu" \
        --vmid "$migrate_vm_id" \
        --name "test-migrate-vm" \
        --memory 256 \
        --cores 1 \
        --net0 "virtio,bridge=vmbr0" 2>&1)

    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Migrate VM to remote node:")${c6}-${c0} VM creation failed"
        return 0
    fi

    local task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" >/dev/null 2>&1
    fi

    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$migrate_vm_id/migrate" \
        --target "$target_node" \
        --online 0 2>&1)

    if [[ $? -ne 0 ]]; then
        test_api_call DELETE "/nodes/$NODE_NAME/qemu/$migrate_vm_id" --purge 1 >/dev/null 2>&1
        stop_spinner
        echo -e "\r$(printf "%-30s " "Migrate VM to remote node:")${c6}-${c0} Migration failed"
        return 0
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 120 >/dev/null 2>&1
    fi

    test_api_call DELETE "/nodes/$target_node/qemu/$migrate_vm_id" --purge 1 >/dev/null 2>&1
    stop_spinner
    echo -e "\r$(printf "%-30s " "Migrate VM to remote node:")${c2}✓${c0} Migrated to $target_node"
    return 0
}

# Cluster Test 2: Cross-node Clone
test_cross_node_clone() {
    local storage_name="$1"

    local remote_nodes
    if ! remote_nodes=$(get_remote_cluster_nodes 2>/dev/null); then
        test_result "Clone VM to remote node" "SKIP" "No remote nodes"
        return 0
    fi

    local target_node_info=$(echo "$remote_nodes" | head -1)
    local target_node="${target_node_info%%:*}"
    local target_ip="${target_node_info##*:}"

    if ! validate_ssh_to_node "$target_ip" 2>/dev/null; then
        test_result "Clone VM to remote node" "SKIP" "SSH unavailable"
        return 0
    fi

    printf "%-30s " "Clone VM to remote node:"
    start_spinner

    local clone_source_vm=$((TEST_VM_BASE + 20))
    local existing_vms=$(test_api_call GET "/cluster/resources" --type vm 2>/dev/null | grep -oP 'vmid.*?\K[0-9]+' || echo "")
    while echo "$existing_vms" | grep -qw "$clone_source_vm"; do
        clone_source_vm=$((clone_source_vm + 1))
    done

    local output
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu" \
        --vmid "$clone_source_vm" \
        --name "test-clone-source" \
        --memory 256 \
        --cores 1 \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw "virtio-scsi-pci" 2>&1)

    if [[ $? -ne 0 ]]; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Clone VM to remote node:")${c6}-${c0} VM creation failed"
        return 0
    fi

    local task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" >/dev/null 2>&1
    fi

    test_api_call PUT "/nodes/$NODE_NAME/qemu/$clone_source_vm/config" --scsi0 "$storage_name:1" >/dev/null 2>&1

    local snapshot_name="cross-node-snap-$(date +%s)"
    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$clone_source_vm/snapshot" \
        --snapname "$snapshot_name" \
        --description "Cross-node clone test" 2>&1)

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 60 >/dev/null 2>&1
    fi

    local clone_vm_id=$((clone_source_vm + 1))
    while echo "$existing_vms" | grep -qw "$clone_vm_id"; do
        clone_vm_id=$((clone_vm_id + 1))
    done

    output=$(test_api_call POST "/nodes/$NODE_NAME/qemu/$clone_source_vm/clone" \
        --newid "$clone_vm_id" \
        --name "test-clone-remote" \
        --snapname "$snapshot_name" \
        --target "$target_node" 2>&1)

    if [[ $? -ne 0 ]]; then
        test_api_call DELETE "/nodes/$NODE_NAME/qemu/$clone_source_vm" --purge 1 >/dev/null 2>&1
        stop_spinner
        echo -e "\r$(printf "%-30s " "Clone VM to remote node:")${c6}-${c0} Clone failed"
        return 0
    fi

    task_upid=$(echo "$output" | grep -oP 'UPID[^ ]*' | head -1)
    if [[ -n "$task_upid" ]]; then
        test_wait_for_task "$task_upid" 300 >/dev/null 2>&1
    fi

    test_api_call DELETE "/nodes/$NODE_NAME/qemu/$clone_source_vm" --purge 1 >/dev/null 2>&1
    test_api_call DELETE "/nodes/$target_node/qemu/$clone_vm_id" --purge 1 >/dev/null 2>&1
    stop_spinner
    echo -e "\r$(printf "%-30s " "Clone VM to remote node:")${c2}✓${c0} Cloned to $target_node"
    return 0
}

# Cleanup test VMs function
cleanup_test_vms() {
    info "Cleaning up any remaining test VMs..."

    # Try to delete both test VMs if they exist
    if test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE/status/current" >/dev/null 2>&1; then
        echo "  Removing test VM $TEST_VM_CLONE..."
        test_api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_CLONE" --purge 1 >/dev/null 2>&1
    fi

    if test_api_call GET "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE/status/current" >/dev/null 2>&1; then
        echo "  Removing test VM $TEST_VM_BASE..."
        test_api_call DELETE "/nodes/$NODE_NAME/qemu/$TEST_VM_BASE" --purge 1 >/dev/null 2>&1
    fi

    # Clean up temp files
    rm -f /tmp/clone_snapshot_name 2>/dev/null

    success "Cleanup complete"
}

# Main test execution function
run_plugin_test() {
    local storage_name="$1"
    local start_time=$(date +%s)

    # Track test results
    local tests_passed=0
    local tests_failed=0
    local tests_total=0

    # Pre-flight checks (silent)
    if ! command -v pvesh &> /dev/null; then
        error "pvesh command not found - cannot run tests"
        return 1
    fi

    if ! test_find_available_vm_ids; then
        error "Failed to find available VM IDs"
        return 1
    fi

    # Run local tests

    # Test 1: Storage Status
    ((tests_total++))
    if test_storage_status "$storage_name"; then
        ((tests_passed++))
    else
        ((tests_failed++))
        error "Storage status test failed - aborting test suite"
        return 1
    fi

    # Test 2: Volume Creation
    ((tests_total++))
    if test_volume_creation "$storage_name"; then
        ((tests_passed++))
    else
        ((tests_failed++))
        error "Volume creation test failed - attempting cleanup"
        cleanup_test_vms
        return 1
    fi

    # Test 3: Volume Listing
    ((tests_total++))
    if test_volume_listing "$storage_name"; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 4: Snapshot Operations
    ((tests_total++))
    if test_snapshot_operations; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 4b: Multi-disk Snapshot Operations
    ((tests_total++))
    if test_multidisk_snapshot_operations "$storage_name"; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 5: Clone Operations
    ((tests_total++))
    if test_clone_operations; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 6: Volume Resize
    ((tests_total++))
    if test_volume_resize; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 7: VM Start/Stop
    ((tests_total++))
    if test_vm_start_stop; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Test 8: Volume Deletion
    ((tests_total++))
    if test_volume_deletion; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi

    # Run cluster tests if in cluster
    if is_cluster_node; then
        echo
        info "Running cluster-specific tests..."
        echo

        # Cluster Test 1: VM Migration
        ((tests_total++))
        if test_vm_migration; then
            ((tests_passed++))
        else
            ((tests_failed++))
        fi

        # Cluster Test 2: Cross-node Clone
        ((tests_total++))
        if test_cross_node_clone "$storage_name"; then
            ((tests_passed++))
        else
            ((tests_failed++))
        fi
    fi

    # Generate summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    info "${c8}Plugin Function Test Summary${c0}"
    echo
    echo "  Total tests run:    $tests_total"
    echo "  Tests passed:       ${c2}$tests_passed${c0}"
    echo "  Tests failed:       ${c1}$tests_failed${c0}"
    echo "  Duration:           ${minutes}m ${seconds}s"
    echo
    echo "  Storage tested:     $storage_name"
    echo "  Node:               $NODE_NAME"
    if is_cluster_node; then
        echo "  Cluster mode:       Yes"
    else
        echo "  Cluster mode:       No"
    fi
    echo
    echo "  Log file:           $LOG_FILE"
    echo

    if [[ $tests_failed -eq 0 ]]; then
        success "All tests passed! ✓"
        echo
    else
        error "Some tests failed. Please check the log file for details."
        echo
    fi

    # Return status based on test results
    [[ $tests_failed -eq 0 ]] && return 0 || return 1
}

# Menu: Cleanup orphaned resources
menu_cleanup_orphans() {
    local storage_name

    clear_screen
    print_banner
    echo

    # List available TrueNAS storage
    info "Detecting TrueNAS storage configurations..."
    echo

    if [[ ! -f "$STORAGE_CFG" ]]; then
        warning "No storage.cfg found - please configure storage first"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Build array of storage names
    local -a storage_list=()
    while IFS= read -r storage; do
        [[ -n "$storage" ]] && storage_list+=("$storage")
    done < <(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}')

    if [[ ${#storage_list[@]} -eq 0 ]]; then
        warning "No TrueNAS storage configured"
        info "Please configure storage first from the main menu"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Auto-select if only one storage exists
    if [[ ${#storage_list[@]} -eq 1 ]]; then
        storage_name="${storage_list[0]}"
        info "Using storage: $storage_name"
        echo
    else
        # Show numbered list for selection
        info "Select storage for orphan cleanup:"
        echo
        local i=1
        for storage in "${storage_list[@]}"; do
            local mode
            mode=$(get_storage_config_value "$storage" "transport_mode" || true)
            [[ -z "$mode" ]] && mode="iscsi"
            echo "  $i) $storage ($mode)"
            ((i++))
        done
        echo "  0) Cancel"
        echo

        # Prompt for selection
        local choice
        while true; do
            read -rp "Enter choice [0-$((${#storage_list[@]}))]: " choice

            # Handle cancel
            if [[ "$choice" == "0" ]]; then
                info "Returning to main menu"
                return 0
            fi

            # Validate numeric input
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#storage_list[@]} ]]; then
                storage_name="${storage_list[$((choice-1))]}"
                break
            fi

            warning "Invalid choice - please enter a number between 0 and ${#storage_list[@]}"
        done
    fi

    # Clear screen after valid storage selection
    clear_screen
    print_banner
    echo

    # Get storage configuration
    local api_host api_key dataset api_insecure transport_mode
    api_host=$(get_storage_config_value "$storage_name" "api_host" || true)
    api_key=$(get_storage_config_value "$storage_name" "api_key" || true)
    dataset=$(get_storage_config_value "$storage_name" "dataset" || true)
    api_insecure=$(get_storage_config_value "$storage_name" "api_insecure" || true)
    transport_mode=$(get_storage_config_value "$storage_name" "transport_mode" || true)

    # Default to iscsi if not specified
    [[ -z "$transport_mode" ]] && transport_mode="iscsi"

    echo
    info "Detecting orphaned resources for storage '$storage_name' (transport: $transport_mode)..."
    echo

    # Arrays to store orphan IDs
    # iSCSI uses local arrays populated within this function
    local -a iscsi_extent_orphans=()
    local -a iscsi_te_orphans=()
    local -a iscsi_zvol_orphans=()
    # NVMe uses global arrays populated by _detect_orphaned_resources_nvme
    declare -ga nvme_ns_orphans=()
    declare -ga zvol_orphans=()
    declare -ga nvme_subsys_orphans=()
    local orphan_count=0

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # NVMe/TCP mode - use WebSocket API via tn_api_call
        # Note: Call directly (not via $(...)) to preserve global array modifications
        # Temporarily disable errexit to capture non-zero orphan count without exiting
        info "Fetching NVMe namespaces and zvols..."
        set +e
        _detect_orphaned_resources_nvme "$api_host" "$api_key" "$dataset"
        orphan_count=$?
        set -e
        if [[ $orphan_count -eq 255 ]]; then
            error "Failed to detect orphaned NVMe resources"
            return 1
        fi
        echo
        info "Analyzing resources..."
        echo
    else
        # iSCSI mode - use WebSocket API via tn_api_call
        # Fetch data from TrueNAS API
        info "Fetching iSCSI extents..."
        local extents
        extents=$(tn_api_call "$api_host" "$api_key" "iscsi.extent.query" '[[]]' 2>&1) || {
            error "Failed to fetch extents from TrueNAS API"
            return 1
        }

        info "Fetching zvols..."
        local zvols
        zvols=$(tn_api_call "$api_host" "$api_key" "pool.dataset.query" '[[["type", "=", "VOLUME"]]]' 2>&1) || {
            error "Failed to fetch zvols from TrueNAS API"
            return 1
        }

        info "Fetching target-extent mappings..."
        local targetextents
        targetextents=$(tn_api_call "$api_host" "$api_key" "iscsi.targetextent.query" '[[]]' 2>&1) || {
            error "Failed to fetch targetextents from TrueNAS API"
            return 1
        }

        echo
        info "Analyzing resources..."
        echo

        # Check extents without zvols
        local extent_data
        extent_data=$(echo "$extents" | grep -o '"id": *[0-9]*' | sed 's/"id": *//' || true)

        for extent_id in $extent_data; do
            local extent_disk
            extent_disk=$(echo "$extents" | sed -n "/{/,/}/{ /\"id\": *${extent_id}/,/}/p }" | \
                         grep -o '"disk": *"zvol/[^"]*"' | sed 's/"disk": *"zvol\///' | sed 's/"$//' | head -1 || true)

            [[ -z "$extent_disk" ]] && continue

            # Check if zvol is under our dataset and exists
            if [[ "$extent_disk" == "$dataset/"* ]]; then
                # Use grep -c and capture first line only to avoid newline issues
                local zvol_match_count
                zvol_match_count=$(echo "$zvols" | grep -c "\"id\": *\"${extent_disk}\"" 2>/dev/null | head -1) || zvol_match_count=0
                if [[ "${zvol_match_count:-0}" -eq 0 ]]; then
                    iscsi_extent_orphans+=("$extent_id")
                    orphan_count=$((orphan_count + 1))
                fi
            fi
        done

        # Check targetextents without extents
        local te_data
        te_data=$(echo "$targetextents" | grep -o '"id": *[0-9]*' | sed 's/"id": *//' || true)

        for te_id in $te_data; do
            local extent_ref
            extent_ref=$(echo "$targetextents" | sed -n "/{/,/}/{ /\"id\": *${te_id}/,/}/p }" | \
                        grep -o '"extent": *[0-9]*' | sed 's/"extent": *//' | head -1 || true)

            [[ -z "$extent_ref" ]] && continue

            # Use grep -c and capture first line only to avoid newline issues
            local extent_match_count
            extent_match_count=$(echo "$extents" | grep -c "\"id\": *${extent_ref}" 2>/dev/null | head -1) || extent_match_count=0
            if [[ "${extent_match_count:-0}" -eq 0 ]]; then
                iscsi_te_orphans+=("$te_id")
                orphan_count=$((orphan_count + 1))
            # Also check if this target-extent references an orphan extent (zvol missing)
            elif [[ " ${iscsi_extent_orphans[*]} " == *" ${extent_ref} "* ]]; then
                iscsi_te_orphans+=("$te_id")
                orphan_count=$((orphan_count + 1))
            fi
        done

        # Check zvols without extents
        local zvol_ids
        zvol_ids=$(echo "$zvols" | { grep -B2 -A2 "\"type\": *\"VOLUME\"" || true; } | \
                  { grep "\"id\": *\"${dataset}/" || true; } | sed 's/.*"id": *"\([^"]*\)".*/\1/' || true)

        for zvol_id in $zvol_ids; do
            local zvol_disk="zvol/${zvol_id}"
            # Use grep -c and capture first line only to avoid newline issues
            local match_count
            match_count=$(echo "$extents" | grep -c "\"disk\": *\"${zvol_disk}\"" 2>/dev/null | head -1) || match_count=0
            if [[ "${match_count:-0}" -eq 0 ]]; then
                iscsi_zvol_orphans+=("$zvol_id")
                orphan_count=$((orphan_count + 1))
            fi
        done
    fi

    # Calculate storage-scoped vs global orphan counts
    local storage_orphan_count=0
    local global_orphan_count=0

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        storage_orphan_count=$((${#nvme_ns_orphans[@]} + ${#zvol_orphans[@]}))
        global_orphan_count=${#nvme_subsys_orphans[@]}
    else
        storage_orphan_count=$((${#iscsi_extent_orphans[@]} + ${#iscsi_te_orphans[@]} + ${#iscsi_zvol_orphans[@]}))
        global_orphan_count=0
    fi

    # Report findings
    if [[ $orphan_count -eq 0 ]]; then
        success "No orphaned resources found"
        read -rp "Press Enter to continue..."
        return 0
    fi

    # Display orphans grouped by category with reasoning headers
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # Storage-scoped orphans section
        if [[ $storage_orphan_count -gt 0 ]]; then
            info "Storage Orphans for '$storage_name' ($storage_orphan_count):"
            echo "  Scoped to dataset: $dataset"
            echo

            if [[ ${#nvme_ns_orphans[@]} -gt 0 ]]; then
                echo "  Orphaned Namespaces (${#nvme_ns_orphans[@]}):"
                echo "    These namespaces reference zvols that no longer exist."
                for ns_entry in "${nvme_ns_orphans[@]}"; do
                    local ns_id="${ns_entry%%:*}"
                    local ns_path="${ns_entry#*:}"
                    echo "    • ID: $ns_id, Path: $ns_path"
                done
                echo
            fi

            if [[ ${#zvol_orphans[@]} -gt 0 ]]; then
                echo "  Orphaned Zvols (${#zvol_orphans[@]}):"
                echo "    These zvols exist but have no NVMe namespace exposing them."
                for zvol_id in "${zvol_orphans[@]}"; do
                    echo "    • $zvol_id"
                done
                echo
            fi
        fi

        # Global orphans section (subsystems)
        if [[ ${#nvme_subsys_orphans[@]} -gt 0 ]]; then
            warning "Global Orphans (${#nvme_subsys_orphans[@]}):"
            echo "  These affect ALL storages on this TrueNAS server."
            echo

            echo "  Orphaned Subsystems (${#nvme_subsys_orphans[@]}):"
            echo "    Empty subsystems not referenced by any storage configuration."
            for subsys_entry in "${nvme_subsys_orphans[@]}"; do
                local subsys_id="${subsys_entry%%|*}"
                local rest="${subsys_entry#*|}"
                local subsys_name="${rest%%|*}"
                echo "    • ID: $subsys_id, Name: $subsys_name"
            done
            echo
        fi
    else
        # iSCSI orphans - all storage-scoped
        info "Storage Orphans for '$storage_name' ($storage_orphan_count):"
        echo "  Scoped to dataset: $dataset"
        echo

        if [[ ${#iscsi_extent_orphans[@]} -gt 0 ]]; then
            echo "  Orphaned Extents (${#iscsi_extent_orphans[@]}):"
            echo "    These extents reference zvols that no longer exist."
            for extent_id in "${iscsi_extent_orphans[@]}"; do
                echo "    • ID: $extent_id"
            done
            echo
        fi

        if [[ ${#iscsi_te_orphans[@]} -gt 0 ]]; then
            echo "  Orphaned Target-Extents (${#iscsi_te_orphans[@]}):"
            echo "    These target-extent mappings reference extents that no longer exist."
            for te_id in "${iscsi_te_orphans[@]}"; do
                echo "    • ID: $te_id"
            done
            echo
        fi

        if [[ ${#iscsi_zvol_orphans[@]} -gt 0 ]]; then
            echo "  Orphaned Zvols (${#iscsi_zvol_orphans[@]}):"
            echo "    These zvols exist but have no iSCSI extent exposing them."
            for zvol_id in "${iscsi_zvol_orphans[@]}"; do
                echo "    • $zvol_id"
            done
            echo
        fi
    fi

    # DRYRUN/DELETE prompt
    local action
    read -rp "Type DRYRUN to preview deletion details, or DELETE to remove now: " action

    if [[ "$action" == "DRYRUN" ]]; then
        # Show detailed dry run preview
        clear_screen
        print_banner
        echo
        info "=== DRY RUN PREVIEW ==="
        echo

        local op_num=0

        if [[ "$transport_mode" == "nvme-tcp" ]]; then
            # Storage-scoped operations
            if [[ $storage_orphan_count -gt 0 ]]; then
                echo "Storage-scoped operations (dataset: $dataset):"
                echo

                for ns_entry in "${nvme_ns_orphans[@]}"; do
                    local ns_id="${ns_entry%%:*}"
                    local ns_path="${ns_entry#*:}"
                    ((++op_num))
                    echo "  [$op_num] Delete NVMe namespace ID: $ns_id"
                    echo "      Reason: References $ns_path which no longer exists"
                    echo
                done

                for zvol_id in "${zvol_orphans[@]}"; do
                    ((++op_num))
                    echo "  [$op_num] Delete zvol: $zvol_id"
                    echo "      Reason: No NVMe namespace exposes this zvol"
                    echo
                done
            fi

            # Global operations (subsystems)
            if [[ ${#nvme_subsys_orphans[@]} -gt 0 ]]; then
                echo "Global operations (affects ALL storages on this TrueNAS):"
                echo

                for subsys_entry in "${nvme_subsys_orphans[@]}"; do
                    local subsys_id="${subsys_entry%%|*}"
                    local rest="${subsys_entry#*|}"
                    local subsys_name="${rest%%|*}"
                    ((++op_num))
                    echo "  [$op_num] Delete NVMe subsystem: $subsys_name (ID: $subsys_id)"
                    echo "      Reason: Subsystem is empty and not referenced in any storage.cfg"
                    echo
                done
            fi
        else
            # iSCSI - all storage-scoped
            echo "Storage-scoped operations (dataset: $dataset):"
            echo

            for te_id in "${iscsi_te_orphans[@]}"; do
                ((++op_num))
                echo "  [$op_num] Delete target-extent mapping ID: $te_id"
                echo "      Reason: References an extent that no longer exists"
                echo
            done

            for extent_id in "${iscsi_extent_orphans[@]}"; do
                ((++op_num))
                echo "  [$op_num] Delete extent ID: $extent_id"
                echo "      Reason: References a zvol that no longer exists"
                echo
            done

            for zvol_id in "${iscsi_zvol_orphans[@]}"; do
                ((++op_num))
                echo "  [$op_num] Delete zvol: $zvol_id"
                echo "      Reason: No iSCSI extent exposes this zvol"
                echo
            done
        fi

        info "=== END DRY RUN ($op_num operations) ==="
        echo

        # Post-preview prompt
        local confirm_action
        read -rp "Type DELETE to proceed, or press Enter to cancel: " confirm_action

        if [[ "$confirm_action" != "DELETE" ]]; then
            info "Cleanup cancelled - returning to main menu"
            return 0
        fi
        # Fall through to deletion
    elif [[ "$action" != "DELETE" ]]; then
        # Invalid option - return to menu
        info "Invalid option - returning to main menu"
        read -rp "Press Enter to continue..."
        return 0
    fi

    # Clear screen before deletion
    clear_screen
    print_banner
    echo
    info "Deleting Orphaned Resources"
    echo

    local delete_success=0
    local delete_failed=0

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # NVMe/TCP cleanup using WebSocket API with spinner progress

        # Storage-scoped deletions
        if [[ $storage_orphan_count -gt 0 ]]; then
            echo "Storage-scoped (dataset: $dataset):"

            # Delete namespaces first
            for ns_entry in "${nvme_ns_orphans[@]}"; do
                local ns_id="${ns_entry%%:*}"
                local ns_path="${ns_entry#*:}"
                printf "%-40s " "  Namespace $ns_id:"
                start_spinner
                local result rc=0
                result=$(tn_api_call_write "$api_host" "$api_key" "nvmet.namespace.delete" "[$ns_id]" 2>&1) || rc=$?
                stop_spinner
                if [[ $rc -eq 0 ]]; then
                    echo -e "\r\033[K$(printf "%-40s " "  Namespace $ns_id:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                    ((++delete_success))
                else
                    echo -e "\r\033[K$(printf "%-40s " "  Namespace $ns_id:")${COLOR_RED}✗${COLOR_RESET} Failed"
                    ((++delete_failed))
                fi
            done

            # Delete orphaned zvols
            for zvol_id in "${zvol_orphans[@]}"; do
                local short_zvol="${zvol_id##*/}"
                printf "%-40s " "  Zvol $short_zvol:"
                start_spinner
                local result rc=0
                result=$(tn_api_call_write "$api_host" "$api_key" "pool.dataset.delete" "[\"$zvol_id\"]" 2>&1) || rc=$?
                stop_spinner
                if [[ $rc -eq 0 ]]; then
                    echo -e "\r\033[K$(printf "%-40s " "  Zvol $short_zvol:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                    ((++delete_success))
                else
                    echo -e "\r\033[K$(printf "%-40s " "  Zvol $short_zvol:")${COLOR_RED}✗${COLOR_RESET} Failed"
                    ((++delete_failed))
                fi
            done
            echo
        fi

        # Global deletions (subsystems)
        if [[ ${#nvme_subsys_orphans[@]} -gt 0 ]]; then
            echo "Global (affects all storages):"

            for subsys_entry in "${nvme_subsys_orphans[@]}"; do
                local subsys_id="${subsys_entry%%|*}"
                local rest="${subsys_entry#*|}"
                local subsys_name="${rest%%|*}"
                printf "%-40s " "  Subsystem $subsys_name:"
                start_spinner
                local result rc=0
                # Use force=true to also remove port associations (subsystem is already empty per orphan detection)
                result=$(tn_api_call_write "$api_host" "$api_key" "nvmet.subsys.delete" "[$subsys_id, {\"force\": true}]" 2>&1) || rc=$?
                stop_spinner
                if [[ $rc -eq 0 ]]; then
                    echo -e "\r\033[K$(printf "%-40s " "  Subsystem $subsys_name:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                    ((++delete_success))
                else
                    echo -e "\r\033[K$(printf "%-40s " "  Subsystem $subsys_name:")${COLOR_RED}✗${COLOR_RESET} Failed"
                    ((++delete_failed))
                fi
            done
        fi
    else
        # iSCSI cleanup using WebSocket API with spinner progress
        echo "Storage-scoped (dataset: $dataset):"

        # Delete targetextents first (they reference extents)
        for te_id in "${iscsi_te_orphans[@]}"; do
            printf "%-40s " "  Target-extent $te_id:"
            start_spinner
            local result rc=0
            result=$(tn_api_call_write "$api_host" "$api_key" "iscsi.targetextent.delete" "[$te_id]" 2>&1) || rc=$?
            stop_spinner
            if [[ $rc -eq 0 ]]; then
                echo -e "\r\033[K$(printf "%-40s " "  Target-extent $te_id:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                ((++delete_success))
            else
                echo -e "\r\033[K$(printf "%-40s " "  Target-extent $te_id:")${COLOR_RED}✗${COLOR_RESET} Failed"
                ((++delete_failed))
            fi
        done

        # Delete extents
        for extent_id in "${iscsi_extent_orphans[@]}"; do
            printf "%-40s " "  Extent $extent_id:"
            start_spinner
            local result rc=0
            result=$(tn_api_call_write "$api_host" "$api_key" "iscsi.extent.delete" "[$extent_id]" 2>&1) || rc=$?
            stop_spinner
            if [[ $rc -eq 0 ]]; then
                echo -e "\r\033[K$(printf "%-40s " "  Extent $extent_id:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                ((++delete_success))
            else
                echo -e "\r\033[K$(printf "%-40s " "  Extent $extent_id:")${COLOR_RED}✗${COLOR_RESET} Failed"
                ((++delete_failed))
            fi
        done

        # Delete zvols
        for zvol_id in "${iscsi_zvol_orphans[@]}"; do
            local short_zvol="${zvol_id##*/}"
            printf "%-40s " "  Zvol $short_zvol:"
            start_spinner
            local result rc=0
            result=$(tn_api_call_write "$api_host" "$api_key" "pool.dataset.delete" "[\"$zvol_id\"]" 2>&1) || rc=$?
            stop_spinner
            if [[ $rc -eq 0 ]]; then
                echo -e "\r\033[K$(printf "%-40s " "  Zvol $short_zvol:")${COLOR_GREEN}✓${COLOR_RESET} Deleted"
                ((++delete_success))
            else
                echo -e "\r\033[K$(printf "%-40s " "  Zvol $short_zvol:")${COLOR_RED}✗${COLOR_RESET} Failed"
                ((++delete_failed))
            fi
        done
    fi

    echo
    if [[ $delete_failed -eq 0 ]]; then
        success "Cleanup complete! Deleted $delete_success resource(s)"
    else
        warning "Cleanup finished with errors: $delete_success deleted, $delete_failed failed"
    fi
    read -rp "Press Enter to continue..."
    return 0
}

# Menu: Run health check
menu_health_check() {
    clear_screen
    print_banner
    echo

    # Show header
    info "Health Check"
    echo

    # List available TrueNAS storage
    info "Detecting TrueNAS storage configurations..."
    echo

    if [[ ! -f "$STORAGE_CFG" ]]; then
        warning "No storage.cfg found - please configure storage first"
        read -rp "Press Enter to continue..."
        return 1
    fi

    local storages
    storages=$(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}')

    if [[ -z "$storages" ]]; then
        warning "No TrueNAS storage configured"
        info "Please configure storage first from the main menu"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Show available storage
    info "Available TrueNAS storage:"
    echo "$storages" | while read -r storage; do
        echo "  • $storage"
    done
    echo

    # Prompt for storage name
    local storage_name
    read -rp "Enter storage name to check (or press Enter for first): " storage_name

    if [[ -z "$storage_name" ]]; then
        storage_name=$(echo "$storages" | head -1)
        info "Using: $storage_name"
    fi

    # Verify storage exists
    if ! echo "$storages" | grep -q "^${storage_name}$"; then
        error "Storage '$storage_name' not found"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Clear screen and show header for health check execution
    clear_screen
    print_banner
    echo

    info "Health Check"
    echo

    info "Running health check on storage: $storage_name"
    echo

    # Run health check and capture exit code
    # Don't let non-zero returns trigger error trap
    run_health_check "$storage_name" || true
}

# Extract storage configuration block safely
get_storage_config_value() {
    local storage_name="$1"
    local param_name="$2"
    local config_block

    # Extract only the configuration block for this storage (stop at next storage entry)
    config_block=$(awk "/^truenasplugin: ${storage_name}\$/{flag=1; next} /^truenasplugin:/{flag=0} flag" "$STORAGE_CFG")

    # Extract parameter from block
    echo "$config_block" | grep "^\s*${param_name}" | awk '{print $2}' | head -1
}

# Detect orphaned resources (transport-aware)
detect_orphaned_resources() {
    local storage_name="$1"
    local transport_mode="$2"
    local api_host="$3"
    local api_key="$4"
    local dataset="$5"
    local api_insecure="$6"

    local orphan_count=0

    if [[ "$transport_mode" == "iscsi" ]]; then
        # iSCSI orphan detection using WebSocket API

        # Fetch extents
        local extents
        extents=$(tn_api_call "$api_host" "$api_key" "iscsi.extent.query" '[[]]' 2>&1) || return 1

        # Fetch zvols
        local zvols
        zvols=$(tn_api_call "$api_host" "$api_key" "pool.dataset.query" '[[["type", "=", "VOLUME"]]]' 2>&1) || return 1

        # Extract extent IDs and disks using grep/sed
        # Parse JSON: look for "id": <number> and "disk": "zvol/..."
        local extent_data
        extent_data=$(echo "$extents" | grep -o '"id": *[0-9]*' | sed 's/"id": *//')

        for extent_id in $extent_data; do
            # Extract disk path for this extent ID
            local extent_disk
            extent_disk=$(echo "$extents" | sed -n "/{/,/}/{ /"'"'"id"'"'": *${extent_id}/,/}/p }" | \
                         grep -o '"disk": *"zvol/[^"]*"' | sed 's/"disk": *"zvol\///' | sed 's/"$//' | head -1)

            [[ -z "$extent_disk" ]] && continue

            # Check if zvol is under our dataset and exists
            if [[ "$extent_disk" == "$dataset/"* ]]; then
                if ! echo "$zvols" | grep -q "\"id\": *\"${extent_disk}\""; then
                    ((orphan_count++))
                fi
            fi
        done

        # Check for orphaned zvols (zvols without extents)
        # Extract zvol IDs that match our dataset and type VOLUME
        local zvol_ids
        zvol_ids=$(echo "$zvols" | grep -B2 -A2 "\"type\": *\"VOLUME\"" | \
                  grep "\"id\": *\"${dataset}/" | sed 's/.*"id": *"\([^"]*\)".*/\1/')

        for zvol_id in $zvol_ids; do
            local zvol_disk="zvol/${zvol_id}"
            if ! echo "$extents" | grep -q "\"disk\": *\"${zvol_disk}\""; then
                ((orphan_count++))
            fi
        done

    else
        # NVMe/TCP mode - delegate to NVMe-specific detection
        orphan_count=$(_detect_orphaned_resources_nvme "$api_host" "$api_key" "$dataset")
    fi

    echo "$orphan_count"
}

# Detect orphaned NVMe resources (namespaces without zvols, zvols without namespaces)
# Parameters: api_host, api_key, dataset
# Returns: Count of orphaned resources
# Side effects: Populates global arrays nvme_ns_orphans and zvol_orphans
_detect_orphaned_resources_nvme() {
    local api_host="$1"
    local api_key="$2"
    local dataset="$3"

    # Reset arrays (declared in menu_cleanup_orphans)
    nvme_ns_orphans=()
    zvol_orphans=()
    nvme_subsys_orphans=()
    local orphan_count=0

    # Fetch all zvols from the dataset
    log "INFO" "_detect_orphaned_resources_nvme: Fetching zvols from dataset $dataset"
    local zvols_response
    zvols_response=$(tn_api_call "$api_host" "$api_key" "pool.dataset.query" '[[["type", "=", "VOLUME"]]]' 2>&1)
    if [[ $? -ne 0 || -z "$zvols_response" ]]; then
        log "ERROR" "_detect_orphaned_resources_nvme: Failed to fetch zvols"
        return 255
    fi

    # Extract zvol IDs that are under our dataset and match plugin pattern (vm-XXX-disk-YYY)
    local zvol_ids=()
    while IFS= read -r zvol_id; do
        [[ -n "$zvol_id" ]] && zvol_ids+=("$zvol_id")
    done < <(echo "$zvols_response" | grep -oP '"id"\s*:\s*"'"$dataset"'/vm-[0-9]+-disk-[0-9]+"' | \
             sed 's/"id"\s*:\s*"//;s/"$//')

    log "INFO" "_detect_orphaned_resources_nvme: Found ${#zvol_ids[@]} plugin-managed zvols"

    # Fetch all NVMe namespaces
    log "INFO" "_detect_orphaned_resources_nvme: Fetching NVMe namespaces"
    local ns_response
    ns_response=$(tn_api_call "$api_host" "$api_key" "nvmet.namespace.query" '[[]]' 2>&1)
    if [[ $? -ne 0 || -z "$ns_response" ]]; then
        log "ERROR" "_detect_orphaned_resources_nvme: Failed to fetch namespaces"
        return 255
    fi

    # Parse namespaces into arrays using Perl for proper JSON handling
    # (regex-based parsing fails on nested objects like "subsys": {"id": ...})
    # Output format: ns_id TAB device_path TAB subsys_id
    local ns_ids=()
    local ns_device_paths=()
    local ns_subsys_ids=()
    local ns_parsed
    ns_parsed=$(echo "$ns_response" | perl -MJSON::PP -e '
        my $json = do { local $/; <STDIN> };
        my $data = eval { decode_json($json) } // [];
        for my $ns (@$data) {
            next unless ref($ns) eq "HASH" && defined $ns->{id} && defined $ns->{device_path};
            my $subsys_id = (ref($ns->{subsys}) eq "HASH") ? ($ns->{subsys}{id} // "") : "";
            print "$ns->{id}\t$ns->{device_path}\t$subsys_id\n";
        }
    ' 2>/dev/null)

    while IFS=$'\t' read -r ns_id ns_path ns_subsys; do
        [[ -n "$ns_id" && -n "$ns_path" ]] || continue
        ns_ids+=("$ns_id")
        ns_device_paths+=("$ns_path")
        ns_subsys_ids+=("$ns_subsys")
    done <<< "$ns_parsed"

    log "INFO" "_detect_orphaned_resources_nvme: Found ${#ns_ids[@]} namespaces"

    # Check for orphaned namespaces (namespace points to zvol that doesn't exist)
    for i in "${!ns_ids[@]}"; do
        local ns_id="${ns_ids[$i]}"
        local ns_path="${ns_device_paths[$i]:-}"

        # Skip if no device path
        [[ -z "$ns_path" ]] && continue

        # Extract zvol path from device_path (remove 'zvol/' prefix)
        local zvol_path="${ns_path#zvol/}"

        # Only check namespaces pointing to our dataset
        [[ "$zvol_path" != "$dataset/"* ]] && continue

        # Check if zvol exists in our zvol list
        local zvol_found=false
        for zvol_id in "${zvol_ids[@]}"; do
            if [[ "$zvol_id" == "$zvol_path" ]]; then
                zvol_found=true
                break
            fi
        done

        if [[ "$zvol_found" == "false" ]]; then
            # Namespace points to missing zvol - orphan
            nvme_ns_orphans+=("$ns_id:$ns_path")
            ((orphan_count++))
            log "INFO" "_detect_orphaned_resources_nvme: Orphan namespace id=$ns_id path=$ns_path"
        fi
    done

    # Check for orphaned zvols (zvol exists but no namespace points to it)
    for zvol_id in "${zvol_ids[@]}"; do
        local zvol_path="zvol/$zvol_id"
        local ns_found=false

        for ns_path in "${ns_device_paths[@]}"; do
            if [[ "$ns_path" == "$zvol_path" ]]; then
                ns_found=true
                break
            fi
        done

        if [[ "$ns_found" == "false" ]]; then
            # Zvol has no namespace pointing to it - orphan
            zvol_orphans+=("$zvol_id")
            ((orphan_count++))
            log "INFO" "_detect_orphaned_resources_nvme: Orphan zvol $zvol_id"
        fi
    done

    # Fetch all NVMe subsystems and detect orphans (empty subsystems not in storage.cfg)
    log "INFO" "_detect_orphaned_resources_nvme: Fetching NVMe subsystems"
    local subsys_response
    subsys_response=$(tn_api_call "$api_host" "$api_key" "nvmet.subsys.query" '[[]]' 2>&1)
    if [[ $? -eq 0 && -n "$subsys_response" ]]; then
        # Get list of subsystem NQNs configured in storage.cfg
        local configured_nqns=()
        while IFS= read -r nqn; do
            [[ -n "$nqn" ]] && configured_nqns+=("$nqn")
        done < <(grep -h "subsystem_nqn" /etc/pve/storage.cfg 2>/dev/null | awk '{print $2}')

        log "INFO" "_detect_orphaned_resources_nvme: ${#configured_nqns[@]} subsystems configured in storage.cfg"

        # Get unique subsystem IDs that have namespaces (from earlier Perl parsing)
        local subsys_ids_with_ns=()
        for subsys_id in "${ns_subsys_ids[@]}"; do
            [[ -z "$subsys_id" ]] && continue
            # Check if already in array (dedup)
            local already_added=false
            for existing in "${subsys_ids_with_ns[@]}"; do
                [[ "$existing" == "$subsys_id" ]] && { already_added=true; break; }
            done
            [[ "$already_added" == "false" ]] && subsys_ids_with_ns+=("$subsys_id")
        done

        # Validate: if namespaces exist but no subsystem mappings found, skip subsystem orphan detection
        # This prevents false positives if the JSON structure changes or parsing fails
        if [[ ${#ns_ids[@]} -gt 0 && ${#subsys_ids_with_ns[@]} -eq 0 ]]; then
            log "WARN" "_detect_orphaned_resources_nvme: Found ${#ns_ids[@]} namespaces but could not map to subsystems, skipping subsystem orphan detection"
        else

        # Parse subsystems using Perl and check for orphans
        local subsys_parsed
        subsys_parsed=$(echo "$subsys_response" | perl -MJSON::PP -e '
            my $json = do { local $/; <STDIN> };
            my $data = eval { decode_json($json) } // [];
            for my $s (@$data) {
                next unless ref($s) eq "HASH" && defined $s->{id} && defined $s->{subnqn};
                my $name = $s->{name} // "";
                print "$s->{id}\t$name\t$s->{subnqn}\n";
            }
        ' 2>/dev/null)

        while IFS=$'\t' read -r subsys_id subsys_name subsys_nqn; do
            [[ -z "$subsys_id" || -z "$subsys_nqn" ]] && continue

            # Check if subsystem has any namespaces
            local has_namespaces=false
            for used_id in "${subsys_ids_with_ns[@]}"; do
                if [[ "$used_id" == "$subsys_id" ]]; then
                    has_namespaces=true
                    break
                fi
            done

            # Check if subsystem is configured in storage.cfg
            local is_configured=false
            for cfg_nqn in "${configured_nqns[@]}"; do
                if [[ "$cfg_nqn" == "$subsys_nqn" ]]; then
                    is_configured=true
                    break
                fi
            done

            # Orphan: no namespaces AND not configured
            if [[ "$has_namespaces" == "false" && "$is_configured" == "false" ]]; then
                nvme_subsys_orphans+=("$subsys_id|$subsys_name|$subsys_nqn")
                ((orphan_count++))
                log "INFO" "_detect_orphaned_resources_nvme: Orphan subsystem id=$subsys_id name=$subsys_name nqn=$subsys_nqn"
            fi
        done <<< "$subsys_parsed"
        fi  # End of namespace-to-subsystem mapping validation
    else
        log "WARN" "_detect_orphaned_resources_nvme: Failed to query subsystems, skipping subsystem orphan detection"
    fi

    log "INFO" "_detect_orphaned_resources_nvme: Found $orphan_count orphans (${#nvme_ns_orphans[@]} namespaces, ${#zvol_orphans[@]} zvols, ${#nvme_subsys_orphans[@]} subsystems)"
    # Return orphan count as exit code (0-254 valid, 255 = error)
    return "$orphan_count"
}

# ============================================================================
# FIO Benchmark Functions
# ============================================================================

# FIO benchmark orchestration function
run_fio_benchmark() {
    local storage_name="$1"
    local extended="${2:-false}"
    local allocated_volume=""
    local test_device=""
    local cleanup_done=false
    local current_fio_pid=""

    # Global flag so fio_run_test can check it
    declare -g benchmark_interrupted=false

    # Cleanup function for benchmark
    cleanup_benchmark() {
        local sig="${1:-EXIT}"

        # Check if cleanup already done (variable may not exist if interrupted early)
        if [[ "${cleanup_done:-false}" == "true" ]]; then
            return 0
        fi
        cleanup_done=true

        # Set interrupt flag to break out of any running polling loops
        benchmark_interrupted=true

        # Disable further interrupts during cleanup to prevent corruption
        trap '' INT TERM

        # Stop spinner if running
        stop_spinner 2>/dev/null || true

        # Kill specific FIO process if running
        if [[ -n "${current_fio_pid:-}" ]] && kill -0 "${current_fio_pid:-}" 2>/dev/null; then
            log "INFO" "Terminating FIO process with PID ${current_fio_pid:-}"
            kill "${current_fio_pid:-}" 2>/dev/null || true
            sleep 1
            # If still running, force kill
            if kill -0 "${current_fio_pid:-}" 2>/dev/null; then
                log "WARNING" "FIO process ${current_fio_pid:-} not responding, using SIGKILL"
                kill -9 "${current_fio_pid:-}" 2>/dev/null || true
            fi
        fi

        if [[ -n "${allocated_volume:-}" ]]; then
            echo
            info "Cleaning up test volume..."

            # Free the allocated volume
            pvesm free "$allocated_volume" &>/dev/null || true
            sleep 2

            success "Cleanup complete"
        fi

        # Re-enable interrupts and unset traps before returning
        trap - EXIT INT TERM

        # If interrupted, show message and return to menu
        if [[ "$sig" == "INT" ]]; then
            echo
            warning "Benchmark interrupted by user (CTRL+C)"
            return 130
        elif [[ "$sig" == "TERM" ]]; then
            echo
            warning "Benchmark terminated"
            return 143
        fi
    }

    # Set trap for cleanup on exit/interrupt
    trap 'cleanup_benchmark INT' INT
    trap 'cleanup_benchmark TERM' TERM
    trap 'cleanup_benchmark EXIT' EXIT

    # Check 1: FIO installation and version validation
    printf "%-30s " "FIO installation:"
    if command -v fio &>/dev/null; then
        local fio_version fio_major fio_minor
        fio_version=$(fio --version 2>/dev/null | head -1 || echo "unknown")

        # Extract version number (format: fio-3.16 or fio-3.x)
        if [[ "$fio_version" =~ fio-([0-9]+)\.([0-9]+) ]]; then
            fio_major="${BASH_REMATCH[1]}"
            fio_minor="${BASH_REMATCH[2]}"

            # Minimum version requirement: 3.0 (for reliable JSON output)
            if [[ $fio_major -lt 3 ]]; then
                echo -e "${COLOR_RED}✗${COLOR_RESET} $fio_version (too old)"
                echo
                error "FIO version 3.0 or higher is required for JSON output support"
                info "Current version: $fio_version"
                info "Please upgrade FIO using: apt install fio"
                return 1
            fi
        fi

        echo -e "${COLOR_GREEN}✓${COLOR_RESET} $fio_version"

        # Validate JSON output support
        local json_test
        json_test=$(fio --output-format=json --version 2>&1)
        if [[ $? -ne 0 ]] || echo "$json_test" | grep -qi "unknown.*format"; then
            echo
            warning "FIO JSON output format may not be supported"
            info "Benchmark results parsing may fail"
            echo
            read -rp "Continue anyway? [y/N]: " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
                return 1
            fi
        fi
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET} Not installed"
        echo
        error "FIO is not installed on this system"
        info "Please install FIO using: apt install fio"
        return 1
    fi

    # Check 2: Storage configuration
    printf "%-30s " "Storage configuration:"
    start_spinner

    local api_host api_key dataset transport_mode
    api_host=$(get_storage_config_value "$storage_name" "api_host")
    api_key=$(get_storage_config_value "$storage_name" "api_key")
    dataset=$(get_storage_config_value "$storage_name" "dataset")
    transport_mode=$(get_storage_config_value "$storage_name" "transport_mode")

    # Default to iSCSI if transport_mode not specified
    if [[ -z "$transport_mode" ]]; then
        transport_mode="iscsi"
    fi

    stop_spinner

    if [[ -z "$api_host" || -z "$api_key" || -z "$dataset" ]]; then
        echo -e "\r$(printf "%-30s " "Storage configuration:")${COLOR_RED}✗${COLOR_RESET} Incomplete configuration"
        return 1
    fi

    echo -e "\r$(printf "%-30s " "Storage configuration:")${COLOR_GREEN}✓${COLOR_RESET} Valid ($transport_mode mode)"

    # Check 3: Find available VM ID for volume allocation
    printf "%-30s " "Finding available VM ID:"
    start_spinner

    # Find two consecutive available VM IDs starting from 990
    if ! test_find_available_vm_ids 990; then
        stop_spinner
        echo -e "\r$(printf "%-30s " "Finding available VM ID:")${COLOR_RED}✗${COLOR_RESET} No available VM IDs"
        error "Cannot find available VM ID in range 990-1090"
        return 1
    fi

    # Use the first available ID for the FIO benchmark volume
    local benchmark_vm_id=$TEST_VM_BASE
    stop_spinner
    echo -e "\r$(printf "%-30s " "Finding available VM ID:")${COLOR_GREEN}✓${COLOR_RESET} Using VM ID $benchmark_vm_id"

    # Check 4: Allocate test volume directly on storage
    printf "%-30s " "Allocating 10GB test volume:"
    start_spinner

    # Generate unique volume name with timestamp to avoid conflicts
    local timestamp
    timestamp=$(date +%s)
    local unique_name="fio-bench-${timestamp}"

    local alloc_result volume_name
    alloc_result=$(pvesm alloc "$storage_name" "$benchmark_vm_id" "$unique_name" 10G 2>&1)
    local alloc_exit=$?

    stop_spinner

    if [[ $alloc_exit -ne 0 ]]; then
        echo -e "\r$(printf "%-30s " "Allocating 10GB test volume:")${COLOR_RED}✗${COLOR_RESET} Allocation failed"
        error "Failed to allocate volume: $alloc_result"
        return 1
    fi

    # Extract volume name from result (format: storage:volumename)
    volume_name=$(echo "$alloc_result" | grep -oP "successfully created '\K[^']+")
    if [[ -z "$volume_name" ]]; then
        # Parsing failed - try to get volume list from storage
        volume_name=$(pvesm list "$storage_name" 2>/dev/null | grep "$unique_name" | awk '{print $1}' | head -1)
    fi

    if [[ -z "$volume_name" ]]; then
        echo -e "\r$(printf "%-30s " "Allocating 10GB test volume:")${COLOR_RED}✗${COLOR_RESET} Cannot determine volume name"
        error "Volume was created but name could not be determined"
        error "Output was: $alloc_result"
        return 1
    fi

    allocated_volume="$volume_name"

    # Verify the volume actually exists
    if ! pvesm list "$storage_name" 2>/dev/null | grep -q "$volume_name"; then
        echo -e "\r$(printf "%-30s " "Allocating 10GB test volume:")${COLOR_RED}✗${COLOR_RESET} Volume verification failed"
        error "Volume $volume_name was not found in storage"
        return 1
    fi

    echo -e "\r$(printf "%-30s " "Allocating 10GB test volume:")${COLOR_GREEN}✓${COLOR_RESET} $volume_name"

    # Wait for device to appear (sufficient for both iSCSI and NVMe/TCP)
    printf "%-30s " "Waiting for device (5s):"
    start_spinner
    sleep 5
    stop_spinner
    echo -e "\r$(printf "%-30s " "Waiting for device (5s):")${COLOR_GREEN}✓${COLOR_RESET} Ready"

    # Check 5: Detect device path
    printf "%-30s " "Detecting device path:"
    start_spinner

    # Try pvesm path first (authoritative source)
    test_device=$(pvesm path "$volume_name" 2>/dev/null)

    # Resolve symlinks to get canonical device path
    # IMPORTANT: FIO interprets colons (:) as filename separators, so by-path symlinks like
    # /dev/disk/by-path/ip-10.15.14.172:3260-iscsi-iqn.2005-10.org.freenas.ctl:proxmox-lun-5
    # would be parsed as 3 separate files. Resolving to /dev/sdX avoids this issue.
    if [[ -n "$test_device" ]]; then
        local resolved_device
        resolved_device=$(readlink -f "$test_device" 2>/dev/null)
        if [[ -n "$resolved_device" && -b "$resolved_device" ]]; then
            test_device="$resolved_device"
        fi
    fi

    # If pvesm path didn't work, fall back to detection logic
    if [[ -z "$test_device" || ! -b "$test_device" ]]; then
        test_device=$(fio_detect_device_path "$storage_name" "$volume_name")
    fi

    stop_spinner

    if [[ -z "$test_device" || ! -b "$test_device" ]]; then
        echo -e "\r$(printf "%-30s " "Detecting device path:")${COLOR_RED}✗${COLOR_RESET} Device not found"
        error "Could not detect block device for test volume"
        info "Volume name: $volume_name"
        info "Available devices: $(ls -1 /dev/sd* /dev/nvme* /dev/mapper/mpath* 2>/dev/null | head -5 | tr '\n' ' ')"
        cleanup_benchmark
        return 1
    fi

    echo -e "\r$(printf "%-30s " "Detecting device path:")${COLOR_GREEN}✓${COLOR_RESET} $test_device"

    # Check 6: Validate device is not in use
    printf "%-30s " "Validating device is unused:"
    start_spinner

    # Check if device has filesystem
    local has_fs
    has_fs=$(blkid "$test_device" 2>/dev/null)

    # Check if device is mounted
    local is_mounted
    is_mounted=$(mount | grep -q "$test_device" && echo "yes" || echo "no")

    stop_spinner

    if [[ -n "$has_fs" ]]; then
        echo -e "\r$(printf "%-30s " "Validating device is unused:")${COLOR_RED}✗${COLOR_RESET} Device has filesystem"
        error "Device $test_device has a filesystem: $has_fs"
        cleanup_benchmark
        return 1
    fi

    if [[ "$is_mounted" == "yes" ]]; then
        echo -e "\r$(printf "%-30s " "Validating device is unused:")${COLOR_RED}✗${COLOR_RESET} Device is mounted"
        error "Device $test_device is currently mounted"
        cleanup_benchmark
        return 1
    fi

    # Note: VM ID check removed - volumes created with pvesm alloc are not attached to VMs
    # The filesystem and mount checks above, plus lsof checks in fio_run_test, are sufficient

    echo -e "\r$(printf "%-30s " "Validating device is unused:")${COLOR_GREEN}✓${COLOR_RESET} Device is safe to test"

    echo
    # Adjust message based on extended mode
    if [[ "$extended" == "true" ]]; then
        info "Starting FIO benchmarks (90 tests, 75-90 minutes total)..."
    else
        info "Starting FIO benchmarks (30 tests, 25-30 minutes total)..."
    fi
    echo

    # Run benchmark tests (pass extended flag)
    fio_run_benchmark_suite "$test_device" "$transport_mode" "$extended"

    # EXIT trap will handle cleanup automatically
    return 0
}

# Detect device path for benchmark test disk
fio_detect_device_path() {
    local storage_name="$1"
    local volume_name="$2"
    local device_path=""

    # Extract just the volume part (after storage name)
    local vol_id
    vol_id=$(echo "$volume_name" | sed "s/${storage_name}://")

    # Detect transport mode
    local transport_mode use_multipath
    transport_mode=$(get_storage_config_value "$storage_name" "transport_mode")
    use_multipath=$(get_storage_config_value "$storage_name" "use_multipath")

    # Default to iSCSI if not specified
    if [[ -z "$transport_mode" ]]; then
        transport_mode="iscsi"
    fi

    # Wait for device to appear and retry up to 40 times (40 seconds after initial 10 second wait = 50 total)
    local max_retries=40
    local retry_count=0

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # NVMe-TCP: Look for device in nvme list
        # The volume ID should match the NVMe namespace
        while [[ $retry_count -lt $max_retries ]]; do
            # Get list of all NVMe devices with their details
            local nvme_devices
            nvme_devices=$(nvme list 2>/dev/null | tail -n +3)

            # Look for the most recently added device
            # For NVMe-TCP, we'll find the newest device by checking timestamps
            local newest_nvme
            newest_nvme=$(ls -t /dev/nvme*n1 2>/dev/null | head -1)

            if [[ -n "$newest_nvme" && -b "$newest_nvme" ]]; then
                device_path="$newest_nvme"
                break
            fi

            sleep 1
            ((retry_count++))
        done

    else
        # iSCSI: Check for multipath or standard device
        if [[ "$use_multipath" == "1" ]]; then
            # Multipath enabled: Look for /dev/mapper/mpathX
            while [[ $retry_count -lt $max_retries ]]; do
                # Rescan multipath to pick up new devices
                multipath -r &>/dev/null || true

                # Get the most recently added multipath device
                local newest_mpath
                newest_mpath=$(ls -t /dev/mapper/mpath* 2>/dev/null | head -1)

                if [[ -n "$newest_mpath" && -b "$newest_mpath" ]]; then
                    device_path="$newest_mpath"
                    break
                fi

                sleep 1
                ((retry_count++))
            done

        else
            # Standard iSCSI: Look for /dev/sdX
            # Get baseline of existing SCSI devices before allocation
            while [[ $retry_count -lt $max_retries ]]; do
                # Rescan SCSI bus to pick up new devices
                echo "- - -" > /proc/scsi/scsi 2>/dev/null || true

                # Find the most recently added SCSI device
                local newest_sd
                newest_sd=$(ls -t /dev/sd* 2>/dev/null | grep -E "sd[a-z]+$" | head -1)

                if [[ -n "$newest_sd" && -b "$newest_sd" ]]; then
                    # Verify it's roughly the right size (around 10GB)
                    local size_gb
                    size_gb=$(lsblk -b -dn -o SIZE "$newest_sd" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')

                    if [[ -n "$size_gb" && $size_gb -ge 9 && $size_gb -le 11 ]]; then
                        device_path="$newest_sd"
                        break
                    fi
                fi

                sleep 1
                ((retry_count++))
            done
        fi
    fi

    echo "$device_path"
}

# Progress is now shown in section headers instead of bottom progress bar

# Run FIO benchmark suite on a device
fio_run_benchmark_suite() {
    local device="$1"
    local transport_mode="$2"
    local extended="${3:-false}"

    # Define queue depths to test - same for both transport modes
    info "Transport mode: ${transport_mode} (testing QD=1, 16, 32, 64, 128)"
    if [[ "$extended" == "true" ]]; then
        info "Extended mode: Testing each QD with numjobs=1, 4, 8"
    fi
    echo

    local test_num=1
    local total_tests=30
    if [[ "$extended" == "true" ]]; then
        total_tests=90
    fi

    # Arrays to store results for summary (global scope for access in fio_run_test)
    # Clear arrays from any previous runs
    test_names=()
    test_results=()
    test_values=()
    test_numjobs=()
    declare -ga test_names
    declare -ga test_results
    declare -ga test_values
    declare -ga test_numjobs

    # Determine numjobs values to test
    local -a numjobs_values=(1)
    if [[ "$extended" == "true" ]]; then
        numjobs_values=(1 4 8)
    fi

    # Sequential Read Bandwidth - 5 queue depths × numjobs values
    local test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Sequential Read Bandwidth Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "seq-read-qd1-jobs${numjobs}" "read" "1M" "1" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "seq-read-qd16-jobs${numjobs}" "read" "1M" "16" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "seq-read-qd32-jobs${numjobs}" "read" "1M" "32" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "seq-read-qd64-jobs${numjobs}" "read" "1M" "64" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "seq-read-qd128-jobs${numjobs}" "read" "1M" "128" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done
    echo

    # Sequential Write Bandwidth - 5 queue depths × numjobs values
    test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Sequential Write Bandwidth Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "seq-write-qd1-jobs${numjobs}" "write" "1M" "1" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "seq-write-qd16-jobs${numjobs}" "write" "1M" "16" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "seq-write-qd32-jobs${numjobs}" "write" "1M" "32" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "seq-write-qd64-jobs${numjobs}" "write" "1M" "64" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "seq-write-qd128-jobs${numjobs}" "write" "1M" "128" "20" "bandwidth" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done
    echo

    # Random Read IOPS - 5 queue depths × numjobs values
    test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Random Read IOPS Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "rand-read-qd1-jobs${numjobs}" "randread" "4K" "1" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "rand-read-qd16-jobs${numjobs}" "randread" "4K" "16" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "rand-read-qd32-jobs${numjobs}" "randread" "4K" "32" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "rand-read-qd64-jobs${numjobs}" "randread" "4K" "64" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "rand-read-qd128-jobs${numjobs}" "randread" "4K" "128" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done
    echo

    # Random Write IOPS - 5 queue depths × numjobs values
    test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Random Write IOPS Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "rand-write-qd1-jobs${numjobs}" "randwrite" "4K" "1" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "rand-write-qd16-jobs${numjobs}" "randwrite" "4K" "16" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "rand-write-qd32-jobs${numjobs}" "randwrite" "4K" "32" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "rand-write-qd64-jobs${numjobs}" "randwrite" "4K" "64" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "rand-write-qd128-jobs${numjobs}" "randwrite" "4K" "128" "30" "iops" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done
    echo

    # Random Read Latency - 5 queue depths × numjobs values
    test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Random Read Latency Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "rand-read-lat-qd1-jobs${numjobs}" "randread" "4K" "1" "20" "latency" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "rand-read-lat-qd16-jobs${numjobs}" "randread" "4K" "16" "20" "latency" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "rand-read-lat-qd32-jobs${numjobs}" "randread" "4K" "32" "20" "latency" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "rand-read-lat-qd64-jobs${numjobs}" "randread" "4K" "64" "20" "latency" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "rand-read-lat-qd128-jobs${numjobs}" "randread" "4K" "128" "20" "latency" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done
    echo

    # Mixed 70/30 Workload - 5 queue depths × numjobs values
    test_range_end=$((test_num + 5 * ${#numjobs_values[@]} - 1))
    info "Mixed 70/30 Workload Tests: [${test_num}-${test_range_end}/${total_tests}]"
    for numjobs in "${numjobs_values[@]}"; do
        local job_suffix=""
        [[ "$extended" == "true" ]] && job_suffix=" (jobs=${numjobs})"
        fio_run_test "Queue Depth = 1${job_suffix}:" "$device" \
            "mixed-7030-qd1-jobs${numjobs}" "randrw" "4K" "1" "30" "mixed" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 16${job_suffix}:" "$device" \
            "mixed-7030-qd16-jobs${numjobs}" "randrw" "4K" "16" "30" "mixed" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 32${job_suffix}:" "$device" \
            "mixed-7030-qd32-jobs${numjobs}" "randrw" "4K" "32" "30" "mixed" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 64${job_suffix}:" "$device" \
            "mixed-7030-qd64-jobs${numjobs}" "randrw" "4K" "64" "30" "mixed" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
        fio_run_test "Queue Depth = 128${job_suffix}:" "$device" \
            "mixed-7030-qd128-jobs${numjobs}" "randrw" "4K" "128" "30" "mixed" "$test_num" "$total_tests" "$numjobs"
        ((test_num++))
    done

    # Display benchmark summary
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Benchmark Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    local completed=0
    local failed=0
    for status in "${test_values[@]}"; do
        if [[ "$status" == "pass" ]]; then
            ((completed++))
        else
            ((failed++))
        fi
    done

    info "Total tests run: $total_tests"
    info "Completed: $completed"
    if [[ $failed -gt 0 ]]; then
        error "Failed: $failed"
    fi
    echo

    # Show top performers in each category
    # In extended mode, show separate sections for each numjobs value
    local -a numjobs_list=(1)
    if [[ "$extended" == "true" ]]; then
        numjobs_list=(1 4 8)
    fi

    # Map test index to queue depth (0=QD1, 1=QD16, 2=QD32, 3=QD64, 4=QD128)
    local qd_map=(1 16 32 64 128)

    for target_numjobs in "${numjobs_list[@]}"; do
        if [[ "$extended" == "true" ]]; then
            echo
            info "Top Performers (numjobs=${target_numjobs}):"
        else
            info "Top Performers:"
        fi
        echo

        # Find best sequential read bandwidth (filter by target numjobs)
        local best_seq_read_idx=-1
        local best_seq_read_value=0
        local value unit
        for i in "${!test_names[@]}"; do
            # Filter: sequential read tests with matching numjobs
            if [[ "${test_names[$i]}" =~ ^seq-read- ]] && [[ "${test_numjobs[$i]:-1}" == "$target_numjobs" ]] && [[ "${test_values[$i]:-}" == "pass" ]]; then
                value=$(echo "${test_results[$i]}" | grep -oP '^[0-9.]+')
                unit=$(echo "${test_results[$i]}" | grep -oP '(MB|GB)/s')
                # Normalize to MB/s for comparison
                if [[ "$unit" == "GB/s" ]]; then
                    value=$(awk "BEGIN {printf \"%.2f\", $value * 1024}")
                fi
                if (( $(echo "$value > $best_seq_read_value" | bc -l 2>/dev/null || echo 0) )); then
                    best_seq_read_value=$value
                    best_seq_read_idx=$i
                fi
            fi
        done
        if [[ $best_seq_read_idx -ge 0 ]]; then
            # Extract QD from test name (e.g., seq-read-qd64-jobs1 -> 64)
            local seq_read_qd=$(echo "${test_names[$best_seq_read_idx]}" | grep -oP 'qd\K[0-9]+')
            printf "  %-22s %20s   (QD=%-3s)\n" "Sequential Read:" "${test_results[$best_seq_read_idx]}" "$seq_read_qd"
        fi

        # Find best sequential write bandwidth (filter by target numjobs)
        local best_seq_write_idx=-1
        local best_seq_write_value=0
        for i in "${!test_names[@]}"; do
            # Filter: sequential write tests with matching numjobs
            if [[ "${test_names[$i]}" =~ ^seq-write- ]] && [[ "${test_numjobs[$i]:-1}" == "$target_numjobs" ]] && [[ "${test_values[$i]:-}" == "pass" ]]; then
                value=$(echo "${test_results[$i]}" | grep -oP '^[0-9.]+')
                unit=$(echo "${test_results[$i]}" | grep -oP '(MB|GB)/s')
                # Normalize to MB/s for comparison
                if [[ "$unit" == "GB/s" ]]; then
                    value=$(awk "BEGIN {printf \"%.2f\", $value * 1024}")
                fi
                if (( $(echo "$value > $best_seq_write_value" | bc -l 2>/dev/null || echo 0) )); then
                    best_seq_write_value=$value
                    best_seq_write_idx=$i
                fi
            fi
        done
        if [[ $best_seq_write_idx -ge 0 ]]; then
            local seq_write_qd=$(echo "${test_names[$best_seq_write_idx]}" | grep -oP 'qd\K[0-9]+')
            printf "  %-22s %20s   (QD=%-3s)\n" "Sequential Write:" "${test_results[$best_seq_write_idx]}" "$seq_write_qd"
        fi

        # Find best random read IOPS (filter by target numjobs)
        local best_rand_read_idx=-1
        local best_rand_read_value=0
        for i in "${!test_names[@]}"; do
            # Filter: random read tests with matching numjobs
            if [[ "${test_names[$i]}" =~ ^rand-read-qd ]] && [[ "${test_numjobs[$i]:-1}" == "$target_numjobs" ]] && [[ "${test_values[$i]:-}" == "pass" ]]; then
                local value=$(echo "${test_results[$i]}" | tr -d ',' | grep -oP '^[0-9.]+')
                if [[ -n "$value" ]] && (( $(echo "$value > $best_rand_read_value" | bc -l 2>/dev/null || echo 0) )); then
                    best_rand_read_value=$value
                    best_rand_read_idx=$i
                fi
            fi
        done
        if [[ $best_rand_read_idx -ge 0 ]]; then
            local rand_read_qd=$(echo "${test_names[$best_rand_read_idx]}" | grep -oP 'qd\K[0-9]+')
            printf "  %-22s %20s   (QD=%-3s)\n" "Random Read IOPS:" "${test_results[$best_rand_read_idx]}" "$rand_read_qd"
        fi

        # Find best random write IOPS (filter by target numjobs)
        local best_rand_write_idx=-1
        local best_rand_write_value=0
        for i in "${!test_names[@]}"; do
            # Filter: random write tests with matching numjobs
            if [[ "${test_names[$i]}" =~ ^rand-write-qd ]] && [[ "${test_numjobs[$i]:-1}" == "$target_numjobs" ]] && [[ "${test_values[$i]:-}" == "pass" ]]; then
                local value=$(echo "${test_results[$i]}" | tr -d ',' | grep -oP '^[0-9.]+')
                if [[ -n "$value" ]] && (( $(echo "$value > $best_rand_write_value" | bc -l 2>/dev/null || echo 0) )); then
                    best_rand_write_value=$value
                    best_rand_write_idx=$i
                fi
            fi
        done
        if [[ $best_rand_write_idx -ge 0 ]]; then
            local rand_write_qd=$(echo "${test_names[$best_rand_write_idx]}" | grep -oP 'qd\K[0-9]+')
            printf "  %-22s %20s   (QD=%-3s)\n" "Random Write IOPS:" "${test_results[$best_rand_write_idx]}" "$rand_write_qd"
        fi

        # Find best (lowest) latency (filter by target numjobs)
        local best_latency_idx=-1
        local best_latency_value=999999999
        for i in "${!test_names[@]}"; do
            # Filter: latency tests with matching numjobs
            if [[ "${test_names[$i]}" =~ ^rand-read-lat- ]] && [[ "${test_numjobs[$i]:-1}" == "$target_numjobs" ]] && [[ "${test_values[$i]:-}" == "pass" ]]; then
                value=$(echo "${test_results[$i]}" | grep -oP '^[0-9.]+')
                unit=$(echo "${test_results[$i]}" | grep -oP '(µs|ms)')
                # Normalize to µs for comparison (lower is better)
                if [[ "$unit" == "ms" ]]; then
                    value=$(awk "BEGIN {printf \"%.2f\", $value * 1000}")
                fi
                if [[ -n "$value" ]] && (( $(echo "$value < $best_latency_value" | bc -l 2>/dev/null || echo 0) )); then
                    best_latency_value=$value
                    best_latency_idx=$i
                fi
            fi
        done
        if [[ $best_latency_idx -ge 0 ]]; then
            local latency_qd=$(echo "${test_names[$best_latency_idx]}" | grep -oP 'qd\K[0-9]+')
            printf "  %-22s %20s   (QD=%-3s)\n" "Lowest Latency:" "${test_results[$best_latency_idx]}" "$latency_qd"
        fi
    done  # End of numjobs loop

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Run a single FIO test with spinner and result display
fio_run_test() {
    local label="$1"
    local device="$2"
    local test_name="$3"
    local rw_mode="$4"
    local block_size="$5"
    local iodepth="$6"
    local runtime="$7"
    local metric_type="$8"
    local test_num="${9:-0}"
    local total_tests="${10:-0}"
    local numjobs="${11:-1}"

    # Validate device is not in use before starting test
    if command -v lsof &>/dev/null; then
        if lsof "$device" &>/dev/null; then
            printf "%-30s " "${label}"
            echo -e "${COLOR_RED}✗${COLOR_RESET} Device in use"
            log "ERROR" "Device $device is in use, cannot run test $test_name"
            return 1
        fi
    fi

    # Note: Progress indicator removed from label to maintain alignment
    # Progress is now shown in a separate progress bar at bottom of screen

    printf "%-30s " "${label}"
    start_spinner

    # Create temporary file for JSON output
    local json_output
    json_output=$(mktemp)

    # Build FIO command with appropriate parameters
    # Note: --size parameter is required for device paths that FIO cannot auto-query (e.g., iSCSI symlinks)
    local fio_cmd="fio --name=${test_name} --ioengine=libaio --direct=1 --rw=${rw_mode} --bs=${block_size} --iodepth=${iodepth} --runtime=${runtime} --time_based --size=10G --group_reporting --filename=${device} --output-format=json"

    # Add numjobs parameter if > 1
    if [[ "$numjobs" -gt 1 ]]; then
        fio_cmd+=" --numjobs=${numjobs}"
    fi

    # Add mixed workload specific parameters
    if [[ "$metric_type" == "mixed" ]]; then
        fio_cmd+=" --rwmixread=70"
    fi

    # Run FIO and capture output
    # Run in background to allow signal handling
    $fio_cmd > "$json_output" 2>&1 &
    local fio_pid=$!

    # Store PID in parent scope for cleanup
    current_fio_pid=$fio_pid

    # Wait for FIO to complete with interruptible polling
    # Check interrupt flag every 0.1s - trap will set flag when CTRL+C pressed
    local fio_exit=0
    while kill -0 $fio_pid 2>/dev/null && [[ "${benchmark_interrupted:-false}" == "false" ]]; do
        sleep 0.1
    done
    wait $fio_pid 2>/dev/null || fio_exit=$?

    # Clear PID after completion
    current_fio_pid=""

    stop_spinner

    if [[ $fio_exit -ne 0 ]]; then
        echo -e "\r$(printf "%-30s " "${label}")${COLOR_RED}✗${COLOR_RESET} Failed"

        # Store failure for summary (arrays are global)
        test_names+=("${test_name}")
        test_results+=("Failed")
        test_values+=("fail")
        test_numjobs+=("${numjobs}")

        rm -f "$json_output"
        return 1
    fi

    # Parse results based on metric type
    local result_text
    case "$metric_type" in
        bandwidth)
            result_text=$(fio_parse_bandwidth "$json_output" "$rw_mode")
            ;;
        iops)
            result_text=$(fio_parse_iops "$json_output" "$rw_mode")
            ;;
        latency)
            result_text=$(fio_parse_latency "$json_output" "$rw_mode")
            ;;
        mixed)
            result_text=$(fio_parse_mixed "$json_output")
            ;;
    esac

    # Display result
    echo -e "\r$(printf "%-30s " "${label}")${COLOR_GREEN}✓${COLOR_RESET} ${result_text}"

    # Store result for summary (arrays are global)
    test_names+=("${test_name}")
    test_results+=("${result_text}")
    test_values+=("pass")
    test_numjobs+=("${numjobs}")

    # Cleanup
    rm -f "$json_output"
}

# Parse bandwidth from FIO JSON output
fio_parse_bandwidth() {
    local json_file="$1"
    local rw_mode="$2"

    # Validate JSON structure
    if ! grep -q '"jobs"' "$json_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON output from FIO - missing 'jobs' section"
        echo "N/A (Invalid JSON)"
        return 1
    fi

    # Extract the read or write section, then find bw_bytes
    local bw_bytes
    if [[ "$rw_mode" == "read" ]]; then
        bw_bytes=$(grep -A 50 '"read" : {' "$json_file" | grep '"bw_bytes"' | head -1 | grep -oP ':\s*\K[0-9]+')
    else
        bw_bytes=$(grep -A 50 '"write" : {' "$json_file" | grep '"bw_bytes"' | head -1 | grep -oP ':\s*\K[0-9]+')
    fi

    if [[ -z "$bw_bytes" ]]; then
        log "WARNING" "Could not parse bandwidth from JSON output"
        echo "N/A"
        return
    fi

    # Convert bytes/sec to MB/s
    local bw_mbps
    bw_mbps=$(awk "BEGIN {printf \"%.2f\", $bw_bytes/1024/1024}")

    # If > 1000 MB/s, show in GB/s
    if (( $(echo "$bw_mbps > 1000" | bc -l) )); then
        local bw_gbps
        bw_gbps=$(awk "BEGIN {printf \"%.2f\", $bw_mbps/1024}")
        echo "${bw_gbps} GB/s"
    else
        echo "${bw_mbps} MB/s"
    fi
}

# Parse IOPS from FIO JSON output
fio_parse_iops() {
    local json_file="$1"
    local rw_mode="$2"

    # Validate JSON structure
    if ! grep -q '"jobs"' "$json_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON output from FIO - missing 'jobs' section"
        echo "N/A (Invalid JSON)"
        return 1
    fi

    # Extract the read or write section, then find iops (not iops_min/max/mean)
    local iops
    if [[ "$rw_mode" == "randread" ]]; then
        iops=$(grep -A 50 '"read" : {' "$json_file" | grep '"iops"' | head -1 | grep -oP ':\s*\K[0-9.]+')
    else
        iops=$(grep -A 50 '"write" : {' "$json_file" | grep '"iops"' | head -1 | grep -oP ':\s*\K[0-9.]+')
    fi

    if [[ -z "$iops" ]]; then
        log "WARNING" "Could not parse IOPS from JSON output"
        echo "N/A"
        return
    fi

    # Format with comma separator for thousands
    local iops_int
    iops_int=$(printf "%.0f" "$iops")
    local formatted_iops
    formatted_iops=$(echo "$iops_int" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
    echo "${formatted_iops} IOPS"
}

# Parse latency from FIO JSON output
fio_parse_latency() {
    local json_file="$1"
    local rw_mode="$2"

    # Validate JSON structure
    if ! grep -q '"jobs"' "$json_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON output from FIO - missing 'jobs' section"
        echo "N/A (Invalid JSON)"
        return 1
    fi

    # Extract the read or write section, find lat_ns section, then get mean
    local lat_ns
    if [[ "$rw_mode" == "randread" ]]; then
        lat_ns=$(grep -A 100 '"read" : {' "$json_file" | grep -A 10 '"lat_ns"' | grep '"mean"' | head -1 | grep -oP ':\s*\K[0-9.]+')
    else
        lat_ns=$(grep -A 100 '"write" : {' "$json_file" | grep -A 10 '"lat_ns"' | grep '"mean"' | head -1 | grep -oP ':\s*\K[0-9.]+')
    fi

    if [[ -z "$lat_ns" ]]; then
        log "WARNING" "Could not parse latency from JSON output"
        echo "N/A"
        return
    fi

    # Convert nanoseconds to microseconds or milliseconds
    local lat_us
    lat_us=$(awk "BEGIN {printf \"%.2f\", $lat_ns/1000}")

    if (( $(echo "$lat_us > 1000" | bc -l) )); then
        local lat_ms
        lat_ms=$(awk "BEGIN {printf \"%.2f\", $lat_us/1000}")
        echo "${lat_ms} ms"
    else
        echo "${lat_us} µs"
    fi
}

# Parse mixed workload results from FIO JSON output
fio_parse_mixed() {
    local json_file="$1"

    # Validate JSON structure
    if ! grep -q '"jobs"' "$json_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON output from FIO - missing 'jobs' section"
        echo "N/A (Invalid JSON)"
        return 1
    fi

    # Extract read and write sections separately
    local read_iops write_iops
    read_iops=$(grep -A 50 '"read" : {' "$json_file" | grep '"iops"' | head -1 | grep -oP ':\s*\K[0-9.]+')
    write_iops=$(grep -A 50 '"write" : {' "$json_file" | grep '"iops"' | head -1 | grep -oP ':\s*\K[0-9.]+')

    if [[ -z "$read_iops" || -z "$write_iops" ]]; then
        log "WARNING" "Could not parse mixed workload from JSON output"
        echo "N/A"
        return
    fi

    local read_iops_int write_iops_int
    read_iops_int=$(printf "%.0f" "$read_iops")
    write_iops_int=$(printf "%.0f" "$write_iops")

    # Format with commas
    read_iops_int=$(echo "$read_iops_int" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
    write_iops_int=$(echo "$write_iops_int" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')

    echo "R: ${read_iops_int} / W: ${write_iops_int} IOPS"
}

# Perform health check on a storage
run_health_check() {
    local storage_name="$1"
    local warnings=0
    local errors=0
    local checks_passed=0
    local checks_total=0
    local checks_skipped=0

    # Helper function for check output
    check_result() {
        local name="$1"
        local status="$2"
        local message="$3"

        printf "%-30s " "${name}:"
        case "$status" in
            OK)
                echo -e "${COLOR_GREEN}✓${COLOR_RESET} $message"
                ((checks_passed++))
                ((checks_total++))
                ;;
            WARNING)
                echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $message"
                ((warnings++))
                ((checks_total++))
                ;;
            CRITICAL)
                echo -e "${COLOR_RED}✗${COLOR_RESET} $message"
                ((errors++))
                ((checks_total++))
                ;;
            SKIP)
                echo -e "${COLOR_CYAN}-${COLOR_RESET} $message"
                ((checks_skipped++))
                ;;
        esac
    }

    # Check 1: Plugin file installed
    if [[ -f "$PLUGIN_FILE" ]]; then
        local version
        version=$(grep 'our $VERSION' "$PLUGIN_FILE" 2>/dev/null | grep -oP "[0-9.]+" || echo "unknown")
        check_result "Plugin file" "OK" "Installed v$version"
    else
        check_result "Plugin file" "CRITICAL" "Not installed"
    fi

    # Check 2: Storage configured
    if grep -q "^truenasplugin: ${storage_name}$" "$STORAGE_CFG" 2>/dev/null; then
        check_result "Storage configuration" "OK" "Configured"
    else
        check_result "Storage configuration" "CRITICAL" "Not configured"
        echo
        error "Storage '$storage_name' not found in configuration"
        return 2
    fi

    # Check 3: Storage status
    printf "%-30s " "Storage status:"
    start_spinner
    local space_result
    if pvesm status 2>/dev/null | grep -q "$storage_name.*active"; then
        local total_kb used_kb percent
        read -r total_kb used_kb percent < <(pvesm status 2>/dev/null | grep "$storage_name" | awk '{print $4, $5, $7}')
        # Sanitize values (remove any whitespace/newlines)
        total_kb=$(echo "$total_kb" | tr -d '\n ')
        used_kb=$(echo "$used_kb" | tr -d '\n ')
        percent=$(echo "$percent" | tr -d '\n ')
        # Convert KB to GB
        local used_gb=$(awk "BEGIN {printf \"%.2f\", $used_kb/1024/1024}")
        local total_gb=$(awk "BEGIN {printf \"%.2f\", $total_kb/1024/1024}")
        space_result="${COLOR_GREEN}✓${COLOR_RESET} Active (${used_gb}GB / ${total_gb}GB used, ${percent})"
        ((checks_passed++))
    else
        space_result="${COLOR_YELLOW}⚠${COLOR_RESET} Inactive or not accessible"
        ((warnings++))
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Storage status:")${space_result}"
    ((checks_total++))

    # Check 4: Content type
    local content
    content=$(get_storage_config_value "$storage_name" "content")
    if [[ "$content" == "images" ]]; then
        check_result "Content type" "OK" "images"
    elif [[ -n "$content" ]]; then
        check_result "Content type" "WARNING" "$content (should be 'images')"
    else
        check_result "Content type" "WARNING" "Not configured"
    fi

    # Check 5: TrueNAS API reachability
    local api_host
    api_host=$(get_storage_config_value "$storage_name" "api_host")
    local api_port
    api_port=$(get_storage_config_value "$storage_name" "api_port")
    api_port=${api_port:-443}

    if [[ -n "$api_host" ]]; then
        printf "%-30s " "TrueNAS API:"
        start_spinner
        local api_result
        if timeout 5 bash -c ">/dev/tcp/$api_host/$api_port" 2>/dev/null; then
            api_result="${COLOR_GREEN}✓${COLOR_RESET} Reachable on $api_host:$api_port"
            ((checks_passed++))
        else
            api_result="${COLOR_RED}✗${COLOR_RESET} Cannot reach $api_host:$api_port"
            ((errors++))
        fi
        stop_spinner
        echo -e "\r$(printf "%-30s " "TrueNAS API:")${api_result}"
        ((checks_total++))
    else
        check_result "TrueNAS API" "CRITICAL" "API host not configured"
    fi

    # Check 6: Dataset configuration
    local dataset
    dataset=$(get_storage_config_value "$storage_name" "dataset")
    if [[ -n "$dataset" ]]; then
        check_result "Dataset" "OK" "$dataset"
    else
        check_result "Dataset" "CRITICAL" "Not configured"
    fi

    # Check 6.5: Dataset type validation (must be FILESYSTEM, not VOLUME)
    local api_key
    api_key=$(get_storage_config_value "$storage_name" "api_key")
    local api_insecure
    api_insecure=$(get_storage_config_value "$storage_name" "api_insecure")

    if [[ -n "$dataset" ]] && [[ -n "$api_host" ]] && [[ -n "$api_key" ]]; then
        printf "%-30s " "Dataset type:"
        start_spinner

        local curl_opts="-s"
        [[ "$api_insecure" == "1" ]] && curl_opts="$curl_opts -k"

        # Make API call to fetch all datasets
        local dataset_info
        dataset_info=$(curl $curl_opts -H "Authorization: Bearer $api_key" \
            "https://$api_host/api/v2.0/pool/dataset" 2>/dev/null)
        local api_status=$?

        stop_spinner

        if [[ $api_status -ne 0 ]] || [[ -z "$dataset_info" ]]; then
            # API call failed - warn but don't fail critically
            local dataset_result="${COLOR_YELLOW}⚠${COLOR_RESET} Cannot validate (API error)"
            echo -e "\r$(printf "%-30s " "Dataset type:")${dataset_result}"
            ((warnings++))
            ((checks_total++))
        else
            # Parse JSON to find our dataset and extract its type
            # We need to find the entry with matching "id" and get its "type" field
            local ds_type
            ds_type=$(echo "$dataset_info" | grep -B2 -A10 "\"id\": *\"$dataset\"" | \
                grep '"type"' | head -1 | sed -E 's/.*"type": *"([^"]+)".*/\1/')

            local dataset_result
            if [[ "$ds_type" == "FILESYSTEM" ]]; then
                dataset_result="${COLOR_GREEN}✓${COLOR_RESET} FILESYSTEM (correct)"
                ((checks_passed++))
            elif [[ "$ds_type" == "VOLUME" ]]; then
                dataset_result="${COLOR_RED}✗${COLOR_RESET} VOLUME (must be FILESYSTEM - zvols cannot have child zvols)"
                ((errors++))
            elif [[ -n "$ds_type" ]]; then
                dataset_result="${COLOR_YELLOW}⚠${COLOR_RESET} Unknown type: $ds_type"
                ((warnings++))
            else
                dataset_result="${COLOR_RED}✗${COLOR_RESET} Dataset not found on TrueNAS"
                ((errors++))
            fi

            echo -e "\r$(printf "%-30s " "Dataset type:")${dataset_result}"
            ((checks_total++))
        fi
    else
        check_result "Dataset type" "SKIP" "Missing dataset or API config"
    fi

    # Detect transport mode
    local transport_mode
    transport_mode=$(get_storage_config_value "$storage_name" "transport_mode")
    transport_mode=${transport_mode:-iscsi}  # Default to iscsi if not specified

    # Check 7: Transport-specific target/subsystem configuration
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # Check for nvme-cli
        if check_nvme_cli; then
            check_result "nvme-cli" "OK" "Installed"
        else
            check_result "nvme-cli" "CRITICAL" "Not installed (required for NVMe/TCP)"
        fi

        # Check subsystem NQN
        local subsystem_nqn
        subsystem_nqn=$(get_storage_config_value "$storage_name" "subsystem_nqn")
        if [[ -n "$subsystem_nqn" ]]; then
            check_result "Subsystem NQN" "OK" "$subsystem_nqn"
        else
            check_result "Subsystem NQN" "CRITICAL" "Not configured"
        fi

        # Check host NQN
        local hostnqn
        hostnqn=$(get_storage_config_value "$storage_name" "hostnqn")
        if [[ -n "$hostnqn" ]]; then
            check_result "Host NQN" "OK" "$hostnqn"
        elif [[ -f /etc/nvme/hostnqn ]]; then
            local system_hostnqn
            system_hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
            check_result "Host NQN" "OK" "Using system: $system_hostnqn"
        else
            check_result "Host NQN" "WARNING" "Not configured (will use system default)"
        fi
    else
        # iSCSI mode - check target IQN
        local target_iqn
        target_iqn=$(get_storage_config_value "$storage_name" "target_iqn")
        if [[ -n "$target_iqn" ]]; then
            check_result "Target IQN" "OK" "$target_iqn"
        else
            check_result "Target IQN" "CRITICAL" "Not configured"
        fi
    fi

    # Check 8: Discovery portal
    local discovery_portal
    discovery_portal=$(get_storage_config_value "$storage_name" "discovery_portal")
    if [[ -n "$discovery_portal" ]]; then
        check_result "Discovery portal" "OK" "$discovery_portal"
    else
        check_result "Discovery portal" "CRITICAL" "Not configured"
    fi

    # Check 9: Sessions/Connections (transport-specific)
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        if [[ -n "$subsystem_nqn" ]]; then
            printf "%-30s " "NVMe connections:"
            start_spinner
            local nvme_result
            if check_nvme_cli && nvme list-subsys 2>/dev/null | grep -q "$subsystem_nqn"; then
                local path_count live_count
                path_count=$(nvme list-subsys 2>/dev/null | grep -A50 "$subsystem_nqn" | grep -c " tcp " || echo "0")
                live_count=$(nvme list-subsys 2>/dev/null | grep -A50 "$subsystem_nqn" | grep -c " live$" || echo "0")
                # Sanitize values (remove any whitespace/newlines)
                path_count=$(echo "$path_count" | head -1 | tr -d '\n ')
                live_count=$(echo "$live_count" | head -1 | tr -d '\n ')
                nvme_result="${COLOR_GREEN}✓${COLOR_RESET} Connected (${path_count} path(s), ${live_count} live)"
                ((checks_passed++))
            else
                nvme_result="${COLOR_YELLOW}⚠${COLOR_RESET} Not connected"
                ((warnings++))
            fi
            stop_spinner
            echo -e "\r\033[K$(printf "%-30s " "NVMe connections:")${nvme_result}"
            ((checks_total++))
        else
            check_result "NVMe connections" "SKIP" "Cannot check (no subsystem NQN)"
        fi
    else
        # iSCSI sessions check
        if [[ -n "$target_iqn" ]]; then
            printf "%-30s " "iSCSI sessions:"
            start_spinner
            local session_count
            session_count=$(iscsiadm -m session 2>/dev/null | grep -c "$target_iqn" || echo "0")
            session_count=$(echo "$session_count" | head -1 | tr -d '\n ')

            # Check node.startup configuration for all portals
            local auto_startup_count=0
            local total_nodes=0
            if command -v iscsiadm &> /dev/null; then
                while IFS= read -r line; do
                    # Format is: portal,tpgt iqn
                    local portal
                    portal=$(echo "$line" | awk '{print $1}')
                    local iqn
                    iqn=$(echo "$line" | awk '{print $2}')
                    if [[ "$iqn" == "$target_iqn" ]] && [[ -n "$portal" ]]; then
                        ((total_nodes++))
                        local startup_val
                        startup_val=$(iscsiadm -m node --targetname "$target_iqn" -p "$portal" -o show 2>/dev/null | grep "^node.startup" | awk '{print $NF}' | head -1)
                        if [[ "$startup_val" == "automatic" ]]; then
                            ((auto_startup_count++))
                        fi
                    fi
                done < <(iscsiadm -m node 2>/dev/null | grep "$target_iqn")
            fi

            local iscsi_result
            if [[ "$session_count" -gt 0 ]]; then
                iscsi_result="${COLOR_GREEN}✓${COLOR_RESET} $session_count active session(s)"
                ((checks_passed++))
            elif [[ "$auto_startup_count" -gt 0 ]]; then
                # No active sessions but auto-startup is configured - this is OK
                iscsi_result="${COLOR_GREEN}✓${COLOR_RESET} Configured (auto-reconnect: ${auto_startup_count}/${total_nodes} portals)"
                ((checks_passed++))
            elif [[ "$total_nodes" -gt 0 ]]; then
                # Nodes exist but no auto-startup configured
                iscsi_result="${COLOR_YELLOW}⚠${COLOR_RESET} Not configured for auto-startup"
                ((warnings++))
            else
                # No nodes configured at all
                iscsi_result="${COLOR_YELLOW}⚠${COLOR_RESET} No sessions or nodes configured"
                ((warnings++))
            fi
            stop_spinner
            echo -e "\r$(printf "%-30s " "iSCSI sessions:")${iscsi_result}"
            ((checks_total++))
        else
            check_result "iSCSI sessions" "SKIP" "Cannot check (no target IQN)"
        fi
    fi

    # Check 10: Multipath configuration (transport-specific)
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # Check native NVMe multipath
        local portals
        portals=$(get_storage_config_value "$storage_name" "portals")
        if [[ -n "$portals" ]]; then
            if [[ -f /sys/module/nvme_core/parameters/multipath ]]; then
                local nvme_mp
                nvme_mp=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null)
                if [[ "$nvme_mp" == "Y" ]]; then
                    check_result "Native multipath" "OK" "Enabled (kernel)"
                else
                    check_result "Native multipath" "WARNING" "Disabled in kernel"
                fi
            else
                check_result "Native multipath" "WARNING" "Cannot detect (nvme_core not loaded)"
            fi
        else
            check_result "Native multipath" "SKIP" "No additional portals configured"
        fi
    else
        # iSCSI multipath check
        local use_multipath
        use_multipath=$(get_storage_config_value "$storage_name" "use_multipath")
        if [[ "$use_multipath" == "1" ]]; then
            if command -v multipath &> /dev/null; then
                local mpath_count
                mpath_count=$(multipath -ll 2>/dev/null | grep -c "dm-" 2>/dev/null || echo "0")
                mpath_count=$(echo "$mpath_count" | head -1 | tr -d '\n ')
                if [[ "$mpath_count" -gt 0 ]]; then
                    check_result "Multipath" "OK" "$mpath_count device(s)"
                else
                    check_result "Multipath" "WARNING" "Enabled but no devices"
                fi
            else
                check_result "Multipath" "WARNING" "Enabled but multipath-tools not installed"
            fi
        else
            check_result "Multipath" "SKIP" "Not enabled"
        fi
    fi

    # Check 11: Orphaned resources (iSCSI only)
    if [[ "$transport_mode" == "iscsi" ]]; then
        local api_host
        api_host=$(get_storage_config_value "$storage_name" "api_host")
        local api_key
        api_key=$(get_storage_config_value "$storage_name" "api_key")
        local api_insecure
        api_insecure=$(get_storage_config_value "$storage_name" "api_insecure")

        if [[ -n "$api_host" ]] && [[ -n "$api_key" ]] && [[ -n "$dataset" ]]; then
            printf "%-30s " "Orphaned resources:"
            start_spinner
            local orphan_result
            local orphan_count
            orphan_count=$(detect_orphaned_resources "$storage_name" "$transport_mode" "$api_host" "$api_key" "$dataset" "$api_insecure" 2>/dev/null)

            if [[ $? -eq 0 ]] && [[ -n "$orphan_count" ]]; then
                if [[ "$orphan_count" -eq 0 ]]; then
                    orphan_result="${COLOR_GREEN}✓${COLOR_RESET} None found"
                    ((checks_passed++))
                else
                    orphan_result="${COLOR_YELLOW}⚠${COLOR_RESET} Found $orphan_count orphan(s) (use Diagnostics > Cleanup orphans)"
                    ((warnings++))
                fi
            else
                orphan_result="${COLOR_YELLOW}⚠${COLOR_RESET} Check skipped (API error)"
                ((warnings++))
            fi
            stop_spinner
            echo -e "\r$(printf "%-30s " "Orphaned resources:")${orphan_result}"
            ((checks_total++))
        else
            check_result "Orphaned resources" "SKIP" "Cannot check (missing API config)"
        fi
    else
        # NVMe/TCP mode - skip orphan check (not yet supported)
        check_result "Orphaned resources" "SKIP" "Not available for NVMe/TCP"
    fi

    # Check 12: PVE daemon status
    if systemctl is-active --quiet pvedaemon; then
        check_result "PVE daemon" "OK" "Running"
    else
        check_result "PVE daemon" "CRITICAL" "Not running"
    fi

    # Check 13: Weight volume presence (iSCSI only)
    if [[ "$transport_mode" == "iscsi" ]]; then
        local weight_check_failed=0
        local weight_name=""

        # Get target IQN to derive weight volume name
        local target_iqn
        target_iqn=$(get_storage_config_value "$storage_name" "target_iqn")

        # Derive weight name from IQN (same logic as plugin)
        # Extract suffix from IQN (e.g., "iqn.2005-10.org.freenas.ctl:proxmox" -> "proxmox")
        local target_suffix="$target_iqn"
        if [[ "$target_iqn" =~ :([^:]+)$ ]]; then
            target_suffix="${BASH_REMATCH[1]}"
        fi
        # Sanitize for zvol name (replace non-alphanumeric with dash)
        target_suffix=$(echo "$target_suffix" | sed 's/[^a-zA-Z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//')
        local new_weight_name="pve-weight-$target_suffix"
        local old_weight_name="pve-plugin-weight"

        # Check for new format first, then old format for backwards compatibility
        local weight_zvol_new="${dataset}/${new_weight_name}"
        local weight_zvol_old="${dataset}/${old_weight_name}"
        local weight_encoded_new=$(echo "$weight_zvol_new" | sed 's/\//%2F/g')
        local weight_encoded_old=$(echo "$weight_zvol_old" | sed 's/\//%2F/g')

        # Check if weight zvol exists via API (try new format first)
        local zvol_response=$(curl -sk -H "Authorization: Bearer $api_key" \
            "https://$api_host/api/v2.0/pool/dataset/id/$weight_encoded_new" 2>/dev/null)

        if echo "$zvol_response" | grep -q '"id"'; then
            weight_name="$new_weight_name"
        else
            # Try old format for backwards compatibility
            zvol_response=$(curl -sk -H "Authorization: Bearer $api_key" \
                "https://$api_host/api/v2.0/pool/dataset/id/$weight_encoded_old" 2>/dev/null)
            if echo "$zvol_response" | grep -q '"id"'; then
                weight_name="$old_weight_name"
            else
                check_result "Weight volume presence" "WARNING" "Weight zvol missing"
                weight_check_failed=1
            fi
        fi

        # Check if weight extent exists (only if zvol exists)
        if [[ $weight_check_failed -eq 0 ]] && [[ -n "$weight_name" ]]; then
            local extent_response=$(curl -sk -H "Authorization: Bearer $api_key" \
                "https://$api_host/api/v2.0/iscsi/extent" 2>/dev/null)

            if ! echo "$extent_response" | grep -q "\"name\": \"$weight_name\""; then
                check_result "Weight volume presence" "WARNING" "Weight extent missing"
                weight_check_failed=1
            fi
        fi

        # If both exist, report OK
        if [[ $weight_check_failed -eq 0 ]]; then
            check_result "Weight volume presence" "OK" "Present ($weight_name)"
        fi
    else
        # NVMe/TCP mode - skip weight check (not applicable)
        check_result "Weight volume presence" "SKIP" "Not applicable for NVMe/TCP"
    fi

    # Summary
    echo
    info "Health Summary:"
    if [[ $checks_skipped -gt 0 ]]; then
        echo "  Checks passed: $checks_passed/$checks_total ($checks_skipped not applicable)"
    else
        echo "  Checks passed: $checks_passed/$checks_total"
    fi

    if [[ $errors -gt 0 ]]; then
        error "Status: CRITICAL ($errors error(s), $warnings warning(s))"
        return 2
    elif [[ $warnings -gt 0 ]]; then
        warning "Status: WARNING ($warnings warning(s))"
        return 1
    else
        success "Status: HEALTHY"
        return 0
    fi
}

# Menu: Install specific version
menu_install_specific_version() {
    clear_screen
    print_banner
    echo

    info "Fetching releases from GitHub..."
    local releases
    releases=$(get_all_releases) || {
        error "Failed to fetch releases"
        read -rp "Press Enter to continue..."
        return 1
    }

    # Parse versions and prerelease status into arrays
    local -a version_array=()
    local -a prerelease_array=()

    # Split releases JSON into individual release objects
    # Accumulate lines between release objects and process complete blocks
    local release_count=0
    local current_block=""
    local tag_name=""
    local is_prerelease=""
    local version=""

    while IFS= read -r line; do
        # Start of a new release object (when we see "url" field at object start)
        # Use [[ =~ ]] instead of grep -q to avoid set -e issues
        if [[ "$line" =~ ^[[:space:]]*\"url\":[[:space:]]*\"https://api.github.com ]]; then
            # Process previous block if it exists
            if [[ -n "$current_block" ]] && [[ $release_count -lt 20 ]]; then
                tag_name=$(echo "$current_block" | grep -Po '"tag_name":[[:space:]]*"\K[^"]+' 2>/dev/null || echo "")
                is_prerelease=$(echo "$current_block" | grep -Po '"prerelease":[[:space:]]*\K(true|false)' 2>/dev/null || echo "false")

                if [[ -n "$tag_name" ]]; then
                    version="${tag_name#v}"
                    version_array+=("$version")
                    prerelease_array+=("$is_prerelease")
                    release_count=$((release_count + 1))
                fi
            fi
            # Start new block
            current_block="$line"
        elif [[ -n "$current_block" ]]; then
            # Continue accumulating current block
            current_block+=$'\n'"$line"
            # Process block when we see "published_at" (end of metadata we need)
            if [[ "$line" =~ \"published_at\" ]]; then
                if [[ $release_count -lt 20 ]]; then
                    tag_name=$(echo "$current_block" | grep -Po '"tag_name":[[:space:]]*"\K[^"]+' 2>/dev/null || echo "")
                    is_prerelease=$(echo "$current_block" | grep -Po '"prerelease":[[:space:]]*\K(true|false)' 2>/dev/null || echo "false")

                    if [[ -n "$tag_name" ]]; then
                        version="${tag_name#v}"
                        version_array+=("$version")
                        prerelease_array+=("$is_prerelease")
                        release_count=$((release_count + 1))
                    fi
                fi
                current_block=""
            fi
        fi
    done <<< "$releases"

    if [[ ${#version_array[@]} -eq 0 ]]; then
        error "No versions found"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Build menu items with version info and pre-release indicators
    local -a menu_items=()
    local menu_version=""
    local menu_is_prerelease=""
    local menu_indicator=""

    for i in "${!version_array[@]}"; do
        menu_version="${version_array[$i]}"
        menu_is_prerelease="${prerelease_array[$i]}"
        menu_indicator=""

        if [[ "$menu_is_prerelease" == "true" ]]; then
            menu_indicator=" ${c3}(Pre-Release)${c0}"
        fi

        menu_items+=("v${menu_version}${menu_indicator}")
    done

    show_menu "Select version to install" "${menu_items[@]}"

    local choice
    choice=$(read_choice "${#version_array[@]}")

    if [[ "$choice" -eq 0 ]]; then
        return 0
    fi

    # Get selected version (adjust for 1-indexed menu)
    local selected_version="${version_array[$((choice-1))]}"

    # Check if this is a cluster node and prompt for installation scope
    local install_cluster_wide=false
    if is_cluster_node && [[ "$NON_INTERACTIVE" != "true" ]]; then
        echo
        info "Cluster detected"
        echo "  1) Install on local node only"
        echo "  2) Install on all cluster nodes"
        echo
        local scope_choice
        while true; do
            read -rp "Enter choice [1-2]: " scope_choice
            if [[ "$scope_choice" == "1" ]]; then
                install_cluster_wide=false
                break
            elif [[ "$scope_choice" == "2" ]]; then
                install_cluster_wide=true
                break
            else
                error "Invalid choice. Please enter 1 or 2"
            fi
        done
    fi

    # Perform installation based on scope
    local install_success=false
    if [[ "$install_cluster_wide" == "true" ]]; then
        if perform_cluster_wide_installation "$selected_version"; then
            install_success=true
        fi
    else
        if perform_installation "$selected_version"; then
            install_success=true
        fi
    fi

    # Post-installation actions
    if [[ "$install_success" == "true" ]]; then
        # Only prompt to configure storage for local installations
        # (cluster-wide shows next steps automatically)
        if [[ "$install_cluster_wide" == "false" ]] && [[ "$NON_INTERACTIVE" != "true" ]]; then
            echo
            read -rp "Would you like to configure storage now? [y/N]: " response
            if [[ "$response" =~ ^[Yy] ]]; then
                menu_configure_storage
            else
                info "You can configure storage later from the main menu"
            fi
        fi
        read -rp "Press Enter to continue..."
        return 0  # Return success
    else
        read -rp "Press Enter to continue..."
        return 1  # Return failure
    fi
}

# ============================================================================
# CONFIGURATION WIZARD
# ============================================================================

# List all TrueNAS plugin storage names
list_truenas_storages() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}'
}

# Get all configuration values for a storage
# Returns associative array-like output: "key=value" per line
get_all_storage_config_values() {
    local storage_name="$1"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    # Extract the entire configuration block for this storage
    awk "/^truenasplugin: ${storage_name}\$/{flag=1; next} /^[a-z].*:/{flag=0} flag" "$STORAGE_CFG" | \
    grep -v "^\s*$" | \
    sed 's/^\s*//' | \
    awk '{print $1 "=" $2}'
}

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
        grep -q "^truenasplugin: ${name}$" "$STORAGE_CFG"
    else
        return 1
    fi
}

# Validate NQN format (must start with nqn.YYYY-MM.)
validate_nqn() {
    local nqn="$1"
    if [[ $nqn =~ ^nqn\.[0-9]{4}-[0-9]{2}\. ]]; then
        return 0
    fi
    return 1
}

# Check if nvme-cli is installed
check_nvme_cli() {
    if command -v nvme &> /dev/null; then
        return 0
    fi
    return 1
}

# Get or generate host NQN
get_hostnqn() {
    local hostnqn=""

    # Check if hostnqn file exists
    if [[ -f /etc/nvme/hostnqn ]]; then
        hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
        if [[ -n "$hostnqn" ]]; then
            info "Found existing host NQN: $hostnqn" >&2
            read -rp "Use this host NQN? [Y/n]: " use_existing
            if [[ ! "$use_existing" =~ ^[Nn] ]]; then
                echo "$hostnqn"
                return 0
            fi
        fi
    fi

    # Generate new hostnqn
    warning "No host NQN found or user declined existing one"
    read -rp "Generate new host NQN? [Y/n]: " gen_new
    if [[ ! "$gen_new" =~ ^[Nn] ]]; then
        if check_nvme_cli; then
            mkdir -p /etc/nvme
            if nvme gen-hostnqn > /etc/nvme/hostnqn 2>/dev/null; then
                hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
                if [[ -z "$hostnqn" ]]; then
                    error "Generated hostnqn file is empty"
                    return 1
                fi
                success "Generated new host NQN: $hostnqn"
                echo "$hostnqn"
                return 0
            else
                error "Failed to generate host NQN"
                return 1
            fi
        else
            error "nvme-cli not available to generate host NQN"
            return 1
        fi
    fi

    # Manual entry with validation
    while true; do
        read -rp "Enter host NQN manually (or press Enter to skip): " hostnqn
        if [[ -z "$hostnqn" ]]; then
            warning "No host NQN configured"
            return 1
        fi
        if ! validate_nqn "$hostnqn"; then
            error "Invalid NQN format. Must start with nqn.YYYY-MM."
            continue
        fi
        break
    done
    echo "$hostnqn"
    return 0
}

# Check NVMe native multipath status
check_nvme_multipath() {
    if [[ -f /sys/module/nvme_core/parameters/multipath ]]; then
        local nvme_mp
        nvme_mp=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null)
        if [[ "$nvme_mp" == "Y" ]]; then
            info "Native NVMe multipath: ENABLED"
            return 0
        else
            warning "Native NVMe multipath: DISABLED (may reduce redundancy)"
            info "To enable: echo 'options nvme_core multipath=Y' > /etc/modprobe.d/nvme.conf"
            info "Then reboot or reload nvme_core module"
            return 1
        fi
    else
        warning "Cannot detect NVMe multipath status (nvme_core module not loaded)"
        return 1
    fi
}

# Test TrueNAS API connectivity
# Uses WebSocket API via TrueNASPlugin (REST not available)
test_truenas_api() {
    local ip="$1"
    local apikey="$2"

    printf "  Testing connection to TrueNAS at %s..." "$ip"
    start_spinner

    local response
    response=$(tn_api_call "$ip" "$apikey" "system.info" "[]" 2>/dev/null)
    local exit_code=$?

    stop_spinner
    printf "\r\033[K"  # Clear spinner line

    if [[ $exit_code -eq 0 ]] && [[ -n "$response" ]] && echo "$response" | grep -q '"version"'; then
        local version
        version=$(echo "$response" | grep -Po '"version":\s*"\K[^"]+' 2>/dev/null)
        success "Connected to TrueNAS successfully (version: $version)"
        return 0
    else
        error "Failed to connect to TrueNAS API"
        return 1
    fi
}

# Verify dataset exists
# Uses WebSocket API via TrueNASPlugin (REST not available)
verify_dataset() {
    local ip="$1"
    local apikey="$2"
    local dataset="$3"

    printf "  Verifying dataset '%s'..." "$dataset"
    start_spinner

    # Use pool.dataset.query with filter for specific dataset
    local filter="[[\"id\", \"=\", \"${dataset}\"]]"
    local response
    response=$(tn_api_call "$ip" "$apikey" "pool.dataset.query" "$filter" 2>/dev/null)
    local exit_code=$?

    stop_spinner
    echo ""

    if [[ $exit_code -ne 0 ]]; then
        warning "Dataset '$dataset' not found or not accessible"
        return 1
    fi

    # Check if response contains the dataset (non-empty array)
    if [[ -n "$response" ]] && [[ "$response" != "[]" ]] && echo "$response" | grep -q "\"id\""; then
        success "Dataset '$dataset' verified"
        return 0
    else
        warning "Dataset '$dataset' not found or not accessible"
        return 1
    fi
}

# Discover available TrueNAS portals from network interfaces
# Uses WebSocket API via TrueNASPlugin (REST not available)
discover_truenas_portals() {
    local ip="$1"
    local apikey="$2"
    local primary_ip="$3"

    # Use tn_query_interfaces which already uses WebSocket
    local response
    response=$(tn_query_interfaces "$ip" "$apikey")

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Extract IP addresses from interfaces, excluding the primary IP
    # Parse JSON to find all "address" fields with IPv4 addresses
    local portals
    portals=$(echo "$response" | grep -Po '"address":\s*"\K[0-9.]+' | grep -v "^127\." | grep -v -- "^${primary_ip}$" | sort -u)

    if [[ -z "$portals" ]]; then
        return 1
    fi

    echo "$portals"
    return 0
}

# Query TrueNAS network interfaces with detailed information
# Returns JSON with interface name, IP, speed, link state
# Uses WebSocket API via TrueNASPlugin (REST not available for this endpoint)
tn_query_interfaces() {
    local ip="$1"
    local apikey="$2"

    # Use WebSocket API call via TrueNASPlugin
    local response
    response=$(tn_api_call "$ip" "$apikey" "interface.query" "[]" 2>/dev/null)

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        return 1
    fi

    echo "$response"
    return 0
}

# Parse link speed from TrueNAS active_media_subtype to human-readable format
# Input: "40000Mb/s Direct Attach Copper" or "10000baseT/Full" or "1000Mb/s"
# Output: "40 Gb" or "10 Gb" or "1 Gb"
parse_link_speed() {
    local media_subtype="$1"

    if [[ -z "$media_subtype" ]]; then
        echo "-"
        return
    fi

    # Pattern: "40000Mb/s..." -> extract number before "Mb/s"
    if [[ "$media_subtype" =~ ([0-9]+)Mb/s ]]; then
        local mbps="${BASH_REMATCH[1]}"
        if [[ $mbps -ge 1000 ]]; then
            echo "$((mbps / 1000)) Gb"
        else
            echo "${mbps} Mb"
        fi
    # Pattern: "10000baseT..." -> extract number before "base"
    elif [[ "$media_subtype" =~ ([0-9]+)base ]]; then
        local mbps="${BASH_REMATCH[1]}"
        if [[ $mbps -ge 1000 ]]; then
            echo "$((mbps / 1000)) Gb"
        else
            echo "${mbps} Mb"
        fi
    else
        echo "-"
    fi
}

# Query TrueNAS iSCSI service configuration for the listen port
# Returns: port number (e.g., "3260") or empty on failure
# Uses WebSocket API via TrueNASPlugin (REST not available)
tn_get_iscsi_port() {
    local ip="$1"
    local apikey="$2"

    local response
    response=$(tn_api_call "$ip" "$apikey" "iscsi.global.config" "[]" 2>/dev/null)

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        return 1
    fi

    # Extract listen_port from response
    local port
    port=$(echo "$response" | grep -Po '"listen_port":\s*\K[0-9]+')

    if [[ -n "$port" ]]; then
        echo "$port"
        return 0
    fi

    return 1
}

# Global array populated by tn_check_existing_portals with all IPs that have portals configured
ISCSI_PORTAL_IPS=()

# Check for existing iSCSI portals matching selected IPs
# Returns: "exact:<portal_id>" if exact match, "partial:<portal_id>:<matched_ips>" if partial, "none" if no match
# Also populates global ISCSI_PORTAL_IPS array with all IPs that have existing portals
# Uses WebSocket API via TrueNASPlugin (REST not available)
tn_check_existing_portals() {
    local ip="$1"
    local apikey="$2"
    local selected_ips="$3"  # Space-separated list of IPs

    # Reset global array
    ISCSI_PORTAL_IPS=()

    # Use WebSocket API call via TrueNASPlugin
    local response
    response=$(tn_api_call "$ip" "$apikey" "iscsi.portal.query" "[]" 2>/dev/null)

    if [[ -z "$response" ]] || [[ "$response" == "[]" ]] || [[ "$response" == "null" ]]; then
        echo "none"
        return
    fi

    # Convert selected IPs to array for comparison
    local -a sel_ips
    read -ra sel_ips <<< "$selected_ips"
    local num_selected=${#sel_ips[@]}

    # Parse portals using awk to properly extract per-portal listen IPs
    # Portal format: [{"id":1,"listen":[{"ip":"10.20.30.20","port":3260},...]}, ...]
    # Note: Uses mawk-compatible syntax (no gawk-specific capture groups)
    local parsed_portals
    parsed_portals=$(echo "$response" | awk '
    # Extract numeric ID value after "id": pattern
    function extract_id(block,    pos, start, num, c, i) {
        # Try "id": with space
        pos = index(block, "\"id\": ")
        if (pos > 0) { start = pos + 6 }
        else {
            # Try "id": without space
            pos = index(block, "\"id\":")
            if (pos > 0) { start = pos + 5 }
            else { return "" }
        }
        # Extract digits
        num = ""
        for (i = start; i <= length(block); i++) {
            c = substr(block, i, 1)
            if (c >= "0" && c <= "9") { num = num c }
            else if (num != "") { break }
        }
        return num
    }

    # Find all IPv4 addresses from "ip":"X.X.X.X" patterns
    function find_ips(block, ips,    count, remainder, pos, addr, i, c) {
        count = 0
        remainder = block
        while (1) {
            pos = index(remainder, "\"ip\":")
            if (pos == 0) break
            remainder = substr(remainder, pos + 5)
            # Skip whitespace and opening quote
            while (substr(remainder, 1, 1) == " ") remainder = substr(remainder, 2)
            if (substr(remainder, 1, 1) != "\"") continue
            remainder = substr(remainder, 2)
            # Extract until closing quote
            addr = ""
            for (i = 1; i <= length(remainder); i++) {
                c = substr(remainder, i, 1)
                if (c == "\"") break
                addr = addr c
            }
            if (addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                count++
                ips[count] = addr
            }
            remainder = substr(remainder, i + 1)
        }
        return count
    }

    BEGIN { RS=""; FS="" }
    {
        json = $0
        gsub(/\n/, " ", json)
        gsub(/  +/, " ", json)

        n = split(json, chars, "")
        depth = 0
        portal_start = 0
        in_top_array = 0

        for (i = 1; i <= n; i++) {
            c = chars[i]

            if (c == "[" && depth == 0) {
                in_top_array = 1
                continue
            }
            if (c == "{") {
                depth++
                if (depth == 1) {
                    portal_start = i
                }
            }
            if (c == "}") {
                depth--
                if (depth == 0 && portal_start > 0) {
                    # Extract portal block
                    portal_block = ""
                    for (j = portal_start; j <= i; j++) {
                        portal_block = portal_block chars[j]
                    }

                    # Extract portal ID
                    portal_id = extract_id(portal_block)

                    # Extract all IPs from listen array for this portal
                    if (portal_id != "") {
                        delete ip_list
                        ip_count = find_ips(portal_block, ip_list)
                        for (k = 1; k <= ip_count; k++) {
                            print portal_id "|" ip_list[k]
                        }
                    }

                    portal_start = 0
                }
            }
        }
    }')

    # Build associative arrays of portal IPs
    local best_match_count=0
    local best_portal_id=""
    local current_portal=""
    local -a current_ips=()

    # Process parsed output, grouping by portal ID
    while IFS='|' read -r portal_id portal_ip; do
        [[ -z "$portal_id" ]] && continue

        # Add to global array of all portal IPs (for per-IP display)
        ISCSI_PORTAL_IPS+=("$portal_ip")

        if [[ "$portal_id" != "$current_portal" ]]; then
            # Check previous portal if any
            if [[ -n "$current_portal" ]] && [[ ${#current_ips[@]} -gt 0 ]]; then
                local match_count=0
                for sel_ip in "${sel_ips[@]}"; do
                    for pip in "${current_ips[@]}"; do
                        if [[ "$sel_ip" == "$pip" ]]; then
                            ((match_count++))
                            break
                        fi
                    done
                done
                if [[ $match_count -gt $best_match_count ]]; then
                    best_match_count=$match_count
                    best_portal_id=$current_portal
                fi
            fi
            # Start new portal
            current_portal="$portal_id"
            current_ips=("$portal_ip")
        else
            current_ips+=("$portal_ip")
        fi
    done <<< "$parsed_portals"

    # Check last portal
    if [[ -n "$current_portal" ]] && [[ ${#current_ips[@]} -gt 0 ]]; then
        local match_count=0
        for sel_ip in "${sel_ips[@]}"; do
            for pip in "${current_ips[@]}"; do
                if [[ "$sel_ip" == "$pip" ]]; then
                    ((match_count++))
                    break
                fi
            done
        done
        if [[ $match_count -gt $best_match_count ]]; then
            best_match_count=$match_count
            best_portal_id=$current_portal
        fi
    fi

    if [[ $best_match_count -eq 0 ]]; then
        echo "none"
    elif [[ $best_match_count -eq $num_selected ]]; then
        echo "exact:${best_portal_id}"
    else
        echo "partial:${best_portal_id}:${best_match_count}/${num_selected}"
    fi
}

# Check for existing NVMe ports matching selected IPs
# Returns space-separated list: "ip:port_id ip:port_id" for existing, or "none"
# Uses WebSocket API via TrueNASPlugin (REST not available)
tn_check_existing_nvme_ports() {
    local ip="$1"
    local apikey="$2"
    local selected_ips="$3"  # Space-separated list of IPs

    # Use WebSocket API call via TrueNASPlugin
    local response
    response=$(tn_api_call "$ip" "$apikey" "nvmet.port.query" "[]" 2>/dev/null)

    if [[ -z "$response" ]] || [[ "$response" == "[]" ]] || [[ "$response" == "null" ]]; then
        echo "none"
        return
    fi

    # Convert selected IPs to array
    local -a sel_ips
    read -ra sel_ips <<< "$selected_ips"

    local existing_ports=""

    # Parse NVMe ports - format: {"id":1,"addr_traddr":"10.20.30.20","addr_trsvcid":4420,...}
    for sel_ip in "${sel_ips[@]}"; do
        # Check if this IP has an existing port
        local port_id
        port_id=$(echo "$response" | grep -Po '"id":\s*([0-9]+)[^}]*"addr_traddr":\s*"'"$sel_ip"'"' | grep -Po '"id":\s*\K[0-9]+' | head -1)
        if [[ -z "$port_id" ]]; then
            # Try alternate order in JSON
            port_id=$(echo "$response" | grep -Po '"addr_traddr":\s*"'"$sel_ip"'"[^}]*"id":\s*([0-9]+)' | grep -Po '"id":\s*\K[0-9]+' | head -1)
        fi
        if [[ -n "$port_id" ]]; then
            existing_ports+="${sel_ip}:${port_id} "
        fi
    done

    if [[ -z "$existing_ports" ]]; then
        echo "none"
    else
        echo "${existing_ports% }"  # Trim trailing space
    fi
}

# Display TrueNAS network interfaces in a formatted table
# Sets global arrays: IFACE_NAMES, IFACE_IPS, IFACE_SPEEDS, IFACE_STATES, IFACE_MGMT
display_interface_table() {
    local interfaces_json="$1"
    local transport_mode="$2"
    local api_host="$3"
    local apikey="$4"

    # Initialize global arrays
    IFACE_NAMES=()
    IFACE_IPS=()
    IFACE_SPEEDS=()
    IFACE_STATES=()
    IFACE_MGMT=()

    # Check for existing portals/ports
    local existing_portals=""
    local existing_nvme_ports=""

    # Parse interfaces from JSON using awk to properly extract per-interface data
    # TrueNAS interface.query returns: [{name, aliases:[{address,...}], state:{link_state, active_media_subtype}}]
    # We use awk to parse JSON structure and output: name|ip|link_state|media_subtype (one line per IP)
    # Note: Uses mawk-compatible syntax (no gawk-specific capture groups)
    local parsed_interfaces
    parsed_interfaces=$(echo "$interfaces_json" | awk '
    # Helper function to extract quoted value after a key
    # Returns the value between quotes after "key": "value" or "key":"value"
    # Note: index() does literal matching, so we try both patterns
    function extract_value(block, key,    pattern, pos, start, end, val) {
        # Try "key":"value" (no space)
        pattern = "\"" key "\":\""
        pos = index(block, pattern)
        if (pos > 0) {
            start = pos + length(pattern)
            end = index(substr(block, start), "\"")
            if (end > 0) return substr(block, start, end - 1)
        }
        # Try "key": "value" (with space)
        pattern = "\"" key "\": \""
        pos = index(block, pattern)
        if (pos > 0) {
            start = pos + length(pattern)
            end = index(substr(block, start), "\"")
            if (end > 0) return substr(block, start, end - 1)
        }
        return ""
    }

    # Helper function to find all IPv4 addresses in a block
    function find_ipv4_addresses(block, ips,    count, pos, remainder, addr, i, c, in_addr) {
        count = 0
        # Look for "address": "X.X.X.X" patterns
        remainder = block
        while (1) {
            pos = index(remainder, "\"address\":")
            if (pos == 0) break
            remainder = substr(remainder, pos + 10)  # Skip past "address":
            # Skip whitespace and opening quote
            while (substr(remainder, 1, 1) == " ") remainder = substr(remainder, 2)
            if (substr(remainder, 1, 1) != "\"") continue
            remainder = substr(remainder, 2)  # Skip opening quote
            # Extract until closing quote
            addr = ""
            for (i = 1; i <= length(remainder); i++) {
                c = substr(remainder, i, 1)
                if (c == "\"") break
                addr = addr c
            }
            # Check if it looks like IPv4 (contains only digits and dots)
            if (addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                count++
                ips[count] = addr
            }
            remainder = substr(remainder, i + 1)
        }
        return count
    }

    BEGIN { RS=""; FS="" }
    {
        json = $0
        # Remove newlines and normalize whitespace
        gsub(/\n/, " ", json)
        gsub(/  +/, " ", json)

        # Track brace depth to find interface boundaries
        n = split(json, chars, "")
        depth = 0
        in_array = 0
        iface_start = 0
        current_name = ""
        current_link = "UP"
        current_speed = ""

        for (i = 1; i <= n; i++) {
            c = chars[i]

            if (c == "[" && depth == 0) {
                in_array = 1
                continue
            }
            if (c == "{") {
                depth++
                if (depth == 1) {
                    iface_start = i
                    current_name = ""
                    current_link = "UP"
                    current_speed = ""
                }
            }
            if (c == "}") {
                depth--
                if (depth == 0 && iface_start > 0) {
                    # Extract interface block
                    iface_block = ""
                    for (j = iface_start; j <= i; j++) {
                        iface_block = iface_block chars[j]
                    }

                    # Extract name using helper function
                    current_name = extract_value(iface_block, "name")

                    # Extract link_state from state object
                    link_val = extract_value(iface_block, "link_state")
                    if (link_val ~ /DOWN/) {
                        current_link = "DOWN"
                    } else {
                        current_link = "UP"
                    }

                    # Extract active_media_subtype from state object
                    current_speed = extract_value(iface_block, "active_media_subtype")

                    # Extract all IPv4 addresses from aliases array
                    delete ip_list
                    ip_count = find_ipv4_addresses(iface_block, ip_list)
                    for (k = 1; k <= ip_count; k++) {
                        ip = ip_list[k]
                        # Skip localhost
                        if (ip !~ /^127\./) {
                            print current_name "|" ip "|" current_link "|" current_speed
                        }
                    }

                    iface_start = 0
                }
            }
        }
    }')

    # Process parsed output into arrays
    while IFS='|' read -r iface_name ipv4 link_state media_subtype; do
        [[ -z "$ipv4" ]] && continue

        # Skip if we already have this IP (shouldn't happen with proper parsing)
        local already_added=false
        for existing_ip in "${IFACE_IPS[@]}"; do
            if [[ "$existing_ip" == "$ipv4" ]]; then
                already_added=true
                break
            fi
        done
        [[ "$already_added" == "true" ]] && continue

        # Parse speed
        local speed
        speed=$(parse_link_speed "$media_subtype")

        # Check if this is the management interface
        local is_mgmt=""
        if [[ "$ipv4" == "$api_host" ]]; then
            is_mgmt="mgmt"
        fi

        IFACE_NAMES+=("$iface_name")
        IFACE_IPS+=("$ipv4")
        IFACE_SPEEDS+=("$speed")
        IFACE_STATES+=("$link_state")
        IFACE_MGMT+=("$is_mgmt")
    done <<< "$parsed_interfaces"

    # Fallback: if awk parsing failed, try simple grep extraction
    if [[ ${#IFACE_IPS[@]} -eq 0 ]]; then
        local all_ips
        all_ips=$(echo "$interfaces_json" | grep -Po '"address":\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=")' | grep -v "^127\." | sort -u)
        local idx=1
        for ipv4 in $all_ips; do
            IFACE_NAMES+=("if${idx}")
            IFACE_IPS+=("$ipv4")
            IFACE_SPEEDS+=("-")
            IFACE_STATES+=("UP")
            if [[ "$ipv4" == "$api_host" ]]; then
                IFACE_MGMT+=("mgmt")
            else
                IFACE_MGMT+=("")
            fi
            ((idx++))
        done
    fi

    if [[ ${#IFACE_IPS[@]} -eq 0 ]]; then
        error "No network interfaces with IPv4 addresses found on TrueNAS"
        return 1
    fi

    # Check if ALL interfaces are DOWN
    local all_down=true
    for state in "${IFACE_STATES[@]}"; do
        if [[ "$state" == "UP" ]]; then
            all_down=false
            break
        fi
    done

    if [[ "$all_down" == "true" ]]; then
        echo
        warning "All available interfaces are DOWN"
        warning "Storage may not be accessible until interfaces are active"
        read -rp "Continue anyway? [y/N]: " continue_down
        if [[ ! "$continue_down" =~ ^[Yy] ]]; then
            return 1
        fi
    fi

    # Get existing portal/port info for display
    local all_ips_space="${IFACE_IPS[*]}"
    if [[ "$transport_mode" == "iscsi" ]]; then
        existing_portals=$(tn_check_existing_portals "$api_host" "$apikey" "$all_ips_space")
    else
        existing_nvme_ports=$(tn_check_existing_nvme_ports "$api_host" "$apikey" "$all_ips_space")
    fi

    # Display header
    echo
    printf '%b%b%s%b\n' "${c6}" "${c8}" "TrueNAS Network Interfaces" "${c0}"
    printf '%b%s%b\n' "${c6}" "$(printf '─%.0s' {1..65})" "${c0}"

    local portal_col
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        portal_col="NVMe Port"
    else
        portal_col="Portal"
    fi
    printf "  %-3s %-14s %-17s %-8s %-6s %s\n" "#" "Interface" "IP Address" "Speed" "Link" "$portal_col"
    printf '%b%s%b\n' "${c6}" "$(printf '─%.0s' {1..65})" "${c0}"

    # Display each interface
    for ((i=0; i<${#IFACE_IPS[@]}; i++)); do
        local num=$((i+1))
        local name="${IFACE_NAMES[$i]}"
        local ip="${IFACE_IPS[$i]}"
        local speed="${IFACE_SPEEDS[$i]}"
        local state="${IFACE_STATES[$i]}"
        local mgmt="${IFACE_MGMT[$i]}"

        # Color for link state
        local state_color="${c2}"  # Green for UP
        if [[ "$state" == "DOWN" ]]; then
            state_color="${c1}"  # Red for DOWN
        fi

        # Portal/Port status - check per-IP
        local portal_status="-"
        if [[ "$mgmt" == "mgmt" ]]; then
            portal_status="${c3}⚠ Mgmt${c0}"
        elif [[ "$transport_mode" == "nvme-tcp" ]] && [[ "$existing_nvme_ports" != "none" ]]; then
            if echo "$existing_nvme_ports" | grep -q -- "^${ip}:"; then
                portal_status="${c2}✓ Exists${c0}"
            fi
        elif [[ "$transport_mode" == "iscsi" ]]; then
            # Check if this specific IP has an existing portal
            for portal_ip in "${ISCSI_PORTAL_IPS[@]}"; do
                if [[ "$portal_ip" == "$ip" ]]; then
                    portal_status="${c2}✓ Exists${c0}"
                    break
                fi
            done
        fi

        printf "  %-3s %-14s %-17s %-8s %b%-6s%b %b\n" \
            "$num" "$name" "$ip" "$speed" "$state_color" "$state" "${c0}" "$portal_status"
    done

    printf '%b%s%b\n' "${c6}" "$(printf '─%.0s' {1..65})" "${c0}"
    echo

    return 0
}

# Handle interface selection with validation
# Returns selected indices (1-based) in SELECTED_IFACE_INDICES array
select_interfaces() {
    local max_index="$1"

    SELECTED_IFACE_INDICES=()

    while true; do
        read -rp "Select interfaces (space-separated, e.g., '2 3'): " selection

        if [[ -z "$selection" ]]; then
            error "Must select at least 1 interface"
            continue
        fi

        local -a selected=()
        local -a invalid=()

        for num in $selection; do
            # Check if it's a number
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                invalid+=("$num")
                continue
            fi

            # Check range
            if [[ $num -lt 1 ]] || [[ $num -gt $max_index ]]; then
                invalid+=("$num")
                continue
            fi

            # Check for duplicates
            local is_dup=false
            for s in "${selected[@]}"; do
                if [[ "$s" == "$num" ]]; then
                    is_dup=true
                    break
                fi
            done
            if [[ "$is_dup" == "false" ]]; then
                selected+=("$num")
            fi
        done

        if [[ ${#invalid[@]} -gt 0 ]]; then
            warning "Invalid selections: ${invalid[*]}"
        fi

        if [[ ${#selected[@]} -eq 0 ]]; then
            error "No valid interfaces selected"
            continue
        fi

        # Check for DOWN interfaces and warn
        local down_ifaces=""
        for idx in "${selected[@]}"; do
            local arr_idx=$((idx-1))
            if [[ "${IFACE_STATES[$arr_idx]}" == "DOWN" ]]; then
                down_ifaces+="${IFACE_NAMES[$arr_idx]} "
            fi
        done

        if [[ -n "$down_ifaces" ]]; then
            warning "Selected interface(s) are DOWN: ${down_ifaces}"
            read -rp "Continue with DOWN interfaces? [y/N]: " confirm_down
            if [[ ! "$confirm_down" =~ ^[Yy] ]]; then
                continue
            fi
        fi

        # Check for management interface
        for idx in "${selected[@]}"; do
            local arr_idx=$((idx-1))
            if [[ "${IFACE_MGMT[$arr_idx]}" == "mgmt" ]]; then
                warning "Interface ${IFACE_IPS[$arr_idx]} is the management interface"
                info "Using it for storage may impact API connectivity"
                read -rp "Include management interface? [y/N]: " confirm_mgmt
                if [[ ! "$confirm_mgmt" =~ ^[Yy] ]]; then
                    # Remove from selection
                    local new_selected=()
                    for s in "${selected[@]}"; do
                        if [[ "$s" != "$idx" ]]; then
                            new_selected+=("$s")
                        fi
                    done
                    selected=("${new_selected[@]}")
                fi
            fi
        done

        if [[ ${#selected[@]} -eq 0 ]]; then
            error "No interfaces selected after filtering"
            continue
        fi

        SELECTED_IFACE_INDICES=("${selected[@]}")
        break
    done

    # Display confirmation
    echo
    info "Selected interfaces:"
    for idx in "${SELECTED_IFACE_INDICES[@]}"; do
        local arr_idx=$((idx-1))
        printf "  • %-14s %-17s %s\n" "${IFACE_NAMES[$arr_idx]}" "${IFACE_IPS[$arr_idx]}" "${IFACE_SPEEDS[$arr_idx]}"
    done

    return 0
}

# ============================================================================
# TRUENAS API PROVISIONING FUNCTIONS
# ============================================================================
# These functions provide direct plugin invocation via perl -e for TrueNAS
# storage provisioning. They enable automated creation of datasets, iSCSI
# targets, portals, and NVMe/TCP subsystems from the installer.

# Rollback state management - tracks created resources for cleanup on failure
declare -a ROLLBACK_RESOURCES=()

# Register a resource for potential rollback
# Parameters: resource_type (dataset|portal|target|subsystem), resource_id
register_resource() {
    local resource_type="$1"
    local resource_id="$2"
    ROLLBACK_RESOURCES+=("${resource_type}:${resource_id}")
    log "INFO" "Registered resource for rollback: ${resource_type}:${resource_id}"
}

# Clear all registered rollback resources (call on success)
clear_rollback_state() {
    ROLLBACK_RESOURCES=()
    log "INFO" "Cleared rollback state"
}

# Get count of registered resources
get_rollback_resource_count() {
    echo "${#ROLLBACK_RESOURCES[@]}"
}

# Core wrapper that calls plugin's _api_call function via perl -e
# Parameters: host, api_key, ws_method, ws_params_json
# Returns: JSON output from TrueNAS API to stdout
# Exit code: 0 on success, 1 on error (error message on stderr)
tn_api_call() {
    local host="$1"
    local api_key="$2"
    local method="$3"
    local params="${4:-[]}"

    log "INFO" "tn_api_call: method=$method"

    local result
    local exit_code
    result=$(perl -e '
        use strict;
        use warnings;
        use lib "/usr/share/perl5/PVE/Storage/Custom";
        use TrueNASPlugin;
        use JSON::PP;

        my ($host, $api_key, $method, $params_json) = @ARGV;

        # Build minimal scfg for API call
        my $scfg = {
            api_host => $host,
            api_key => $api_key,
            api_insecure => 1,
        };

        # Decode params
        my $params = eval { decode_json($params_json) } // [];

        # Make the API call
        my $result = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, $method, $params,
                sub { die "REST API not supported for provisioning operations\n"; });
        };

        if ($@) {
            print STDERR "ERROR: $@";
            exit 1;
        }

        # Output result as JSON
        print encode_json($result) if defined $result;
    ' "$host" "$api_key" "$method" "$params" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        # Extract error message
        local error_msg
        error_msg=$(echo "$result" | grep -oP 'ERROR:\s*\K.*' || echo "$result")
        log "ERROR" "tn_api_call failed: $error_msg"
        echo "$error_msg" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# Write operation wrapper (uses ephemeral connection)
# Parameters: host, api_key, ws_method, ws_params_json
# Returns: JSON output from TrueNAS API
# Exit code: 0 on success, 1 on error
tn_api_call_write() {
    local host="$1"
    local api_key="$2"
    local method="$3"
    local params="${4:-[]}"

    log "INFO" "tn_api_call_write: method=$method"

    local result
    local exit_code
    result=$(perl -e '
        use strict;
        use warnings;
        use lib "/usr/share/perl5/PVE/Storage/Custom";
        use TrueNASPlugin;
        use JSON::PP;

        my ($host, $api_key, $method, $params_json) = @ARGV;

        # Build minimal scfg for API call
        my $scfg = {
            api_host => $host,
            api_key => $api_key,
            api_insecure => 1,
        };

        # Decode params - fail fast if JSON is invalid
        my $params = eval { decode_json($params_json) };
        if ($@ || !defined $params) {
            print STDERR "ERROR: Failed to decode params JSON: $@\n";
            print STDERR "Params received: $params_json\n";
            exit 1;
        }

        # Make the API call with ephemeral connection
        my $result = eval {
            PVE::Storage::Custom::TrueNASPlugin::_api_call_write($scfg, $method, $params,
                sub { die "REST API not supported for provisioning operations\n"; });
        };

        if ($@) {
            print STDERR "ERROR: $@";
            exit 1;
        }

        # Output result as JSON
        print encode_json($result) if defined $result;
    ' "$host" "$api_key" "$method" "$params" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        local error_msg
        error_msg=$(echo "$result" | grep -oP 'ERROR:\s*\K.*' || echo "$result")
        log "ERROR" "tn_api_call_write failed: $error_msg"
        echo "$error_msg" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# JSON parsing helper - extract a field value from JSON
# Parameters: json_string, field_name
# Returns: Field value (unquoted)
parse_json_field() {
    local json="$1"
    local field="$2"

    # Handle both "field": "value" and "field": value (numbers, booleans)
    local value
    value=$(echo "$json" | grep -oP "\"${field}\":\s*\K(\"[^\"]*\"|[0-9]+|true|false|null)" | head -1)

    # Remove quotes if present
    value="${value%\"}"
    value="${value#\"}"

    echo "$value"
}

# Validate API connectivity by calling core.ping
# Parameters: host, api_key
# Returns: 0 if connected, 1 on failure
tn_validate_api() {
    local host="$1"
    local api_key="$2"

    log "INFO" "Validating API connectivity to $host"

    local result
    result=$(tn_api_call "$host" "$api_key" "core.ping" "[]" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "API validation failed: $result"
        return 1
    fi

    # core.ping returns "pong" on success
    if [[ "$result" == '"pong"' ]] || [[ "$result" == 'pong' ]]; then
        log "INFO" "API connectivity validated"
        return 0
    fi

    log "ERROR" "Unexpected response from core.ping: $result"
    return 1
}

# List available ZFS pools
# Parameters: host, api_key
# Returns: JSON array of pools
tn_list_pools() {
    local host="$1"
    local api_key="$2"

    log "INFO" "Listing ZFS pools"
    tn_api_call "$host" "$api_key" "pool.query" "[]"
}

# Check if a dataset exists
# Parameters: host, api_key, dataset_path (e.g., "tank/proxmox")
# Returns: JSON object if exists, empty if not found
# Exit code: 0 if exists, 1 if not found or error
tn_check_dataset() {
    local host="$1"
    local api_key="$2"
    local dataset="$3"

    log "INFO" "Checking if dataset exists: $dataset"

    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [[['id', '=', sys.argv[1]]]]
print(json.dumps(data))
" "$dataset" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct dataset query params: $params"
        return 1
    fi

    local result
    result=$(tn_api_call "$host" "$api_key" "pool.dataset.query" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Dataset check failed: $result"
        return 1
    fi

    # Check if result is non-empty array
    if [[ "$result" == "[]" ]] || [[ -z "$result" ]]; then
        log "INFO" "Dataset does not exist: $dataset"
        return 1
    fi

    log "INFO" "Dataset exists: $dataset"
    echo "$result"
    return 0
}

# Create a ZFS dataset for Proxmox storage
# Parameters: host, api_key, parent_pool, dataset_name
# Returns: JSON with created dataset info
# Exit code: 0 on success, 1 on failure
tn_create_dataset() {
    local host="$1"
    local api_key="$2"
    local parent_pool="$3"
    local dataset_name="$4"

    local full_path="${parent_pool}/${dataset_name}"
    log "INFO" "Creating dataset: $full_path"

    # Create dataset with FILESYSTEM type (for zvol children)
    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [{'name': sys.argv[1], 'type': 'FILESYSTEM'}]
print(json.dumps(data))
" "$full_path" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct dataset params JSON: $params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local result
    result=$(tn_api_call_write "$host" "$api_key" "pool.dataset.create" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Dataset creation failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Dataset created successfully: $full_path"
    echo "$result"
    return 0
}

# Delete a ZFS dataset
# Parameters: host, api_key, dataset_path
# Returns: 0 on success, 1 on failure
tn_delete_dataset() {
    local host="$1"
    local api_key="$2"
    local dataset="$3"

    log "INFO" "Deleting dataset: $dataset"

    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [sys.argv[1], {'recursive': True, 'force': True}]
print(json.dumps(data))
" "$dataset" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct dataset delete params: $params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local result
    result=$(tn_api_call_write "$host" "$api_key" "pool.dataset.delete" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Dataset deletion failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Dataset deleted successfully: $dataset"
    return 0
}

# Query existing iSCSI portals
# Parameters: host, api_key
# Returns: JSON array of portals
tn_query_portals() {
    local host="$1"
    local api_key="$2"

    log "INFO" "Querying iSCSI portals"
    tn_api_call "$host" "$api_key" "iscsi.portal.query" "[]"
}

# Find an existing iSCSI portal by IP and port
# Parameters: host, api_key, listen_ip, listen_port
# Returns: portal_id if found (empty string if not found)
tn_find_portal() {
    local host="$1"
    local api_key="$2"
    local listen_ip="$3"
    local listen_port="${4:-3260}"

    log "INFO" "Searching for existing iSCSI portal: $listen_ip:$listen_port"

    # Query all portals
    local portals_result
    portals_result=$(tn_api_call "$host" "$api_key" "iscsi.portal.query" "[]" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "WARNING" "Failed to query iSCSI portals: $portals_result"
        echo ""
        return 1
    fi

    # Find portal matching IP and port
    local portal_id
    portal_id=$(echo "$portals_result" | python3 -c "
import sys, json
try:
    portals = json.load(sys.stdin)
    for portal in portals:
        listen = portal.get('listen', [])
        for addr in listen:
            if (addr.get('ip') == '$listen_ip' and
                str(addr.get('port')) == '$listen_port'):
                print(portal.get('id', ''))
                sys.exit(0)
except:
    pass
" 2>/dev/null)

    if [[ -n "$portal_id" ]]; then
        log "INFO" "Found existing iSCSI portal ID: $portal_id"
    else
        log "INFO" "No existing iSCSI portal found for $listen_ip:$listen_port"
    fi

    echo "$portal_id"
    return 0
}

# Create a new iSCSI portal
# Parameters: host, api_key, listen_ip, listen_port
# Returns: JSON with created portal info
tn_create_portal() {
    local host="$1"
    local api_key="$2"
    local listen_ip="$3"
    local listen_port="${4:-3260}"

    log "INFO" "Creating iSCSI portal: $listen_ip:$listen_port"

    local params
    # Use Python to construct JSON with proper escaping
    # Note: TrueNAS 25.10+ only accepts 'ip' in listen items, port is auto-assigned
    params=$(python3 -c "
import json, sys
data = [{'listen': [{'ip': sys.argv[1]}]}]
print(json.dumps(data))
" "$listen_ip" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct portal params JSON: $params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local result
    result=$(tn_api_call_write "$host" "$api_key" "iscsi.portal.create" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Portal creation failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Portal created successfully"
    echo "$result"
    return 0
}

# Delete an iSCSI portal
# Parameters: host, api_key, portal_id
# Returns: 0 on success, 1 on failure
tn_delete_portal() {
    local host="$1"
    local api_key="$2"
    local portal_id="$3"

    log "INFO" "Deleting iSCSI portal: $portal_id"

    local params
    params=$(printf '[%s]' "$portal_id")

    local result
    result=$(tn_api_call_write "$host" "$api_key" "iscsi.portal.delete" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Portal deletion failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Portal deleted successfully"
    return 0
}

# Query existing iSCSI targets
# Parameters: host, api_key
# Returns: JSON array of targets
tn_query_targets() {
    local host="$1"
    local api_key="$2"

    log "INFO" "Querying iSCSI targets"
    tn_api_call "$host" "$api_key" "iscsi.target.query" "[]"
}

# Check if an iSCSI target with specific IQN exists
# Parameters: host, api_key, target_iqn
# Returns: JSON object if exists, exit 1 if not found
tn_check_target() {
    local host="$1"
    local api_key="$2"
    local target_iqn="$3"

    log "INFO" "Checking if iSCSI target exists: $target_iqn"

    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [[['name', '=', sys.argv[1]]]]
print(json.dumps(data))
" "$target_iqn" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct target query params: $params"
        return 1
    fi

    local result
    result=$(tn_api_call "$host" "$api_key" "iscsi.target.query" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Target check failed: $result"
        return 1
    fi

    if [[ "$result" == "[]" ]] || [[ -z "$result" ]]; then
        log "INFO" "Target does not exist: $target_iqn"
        return 1
    fi

    log "INFO" "Target exists: $target_iqn"
    echo "$result"
    return 0
}

# Generate a standard IQN for iSCSI target
# Parameters: storage_name
# Returns: Generated IQN string
generate_iqn() {
    local storage_name="$1"
    local year_month
    year_month=$(date +%Y-%m)

    # Format: iqn.YYYY-MM.org.freenas.ctl:storage-name
    echo "iqn.${year_month}.org.freenas.ctl:${storage_name}"
}

# Create an iSCSI target with portal association
# Parameters: host, api_key, target_iqn, listen_ip, listen_port
# Returns: JSON with created target info (includes portal_id and portal_reused flag)
# Note: Automatically finds or creates portal matching the listen address
tn_create_target() {
    local host="$1"
    local api_key="$2"
    local target_iqn="$3"
    local listen_ip="$4"
    local listen_port="${5:-3260}"

    log "INFO" "Creating iSCSI target: $target_iqn for portal $listen_ip:$listen_port"

    local portal_id=""
    local portal_reused=false

    # Step 1: Check if portal already exists
    portal_id=$(tn_find_portal "$host" "$api_key" "$listen_ip" "$listen_port" 2>/dev/null)

    if [[ -n "$portal_id" ]]; then
        log "INFO" "Reusing existing iSCSI portal ID: $portal_id"
        portal_reused=true
    else
        # Create the portal
        local portal_params
        # Use Python to construct JSON with proper escaping
        # Note: TrueNAS 25.10+ only accepts 'ip' in listen items, port is auto-assigned
        portal_params=$(python3 -c "
import json, sys
data = [{'listen': [{'ip': sys.argv[1]}]}]
print(json.dumps(data))
" "$listen_ip" 2>&1)

        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to construct portal params JSON: $portal_params"
            echo "Failed to construct JSON params" >&2
            return 1
        fi

        local portal_result
        portal_result=$(tn_api_call_write "$host" "$api_key" "iscsi.portal.create" "$portal_params" 2>&1)
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            log "ERROR" "iSCSI portal creation failed: $portal_result"
            echo "$portal_result" >&2
            return 1
        fi

        # Extract portal ID from result
        portal_id=$(echo "$portal_result" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('id', ''))" 2>/dev/null)

        if [[ -z "$portal_id" ]]; then
            log "ERROR" "Failed to extract portal ID from result: $portal_result"
            echo "Failed to extract portal ID" >&2
            return 1
        fi

        log "INFO" "iSCSI portal created with ID: $portal_id"
    fi

    # Step 2: Create target with portal group association
    local params
    # Use Python to construct JSON with proper escaping to prevent JSON injection
    params=$(python3 -c "
import json, sys
data = [{
    'name': sys.argv[1],
    'groups': [{
        'portal': int(sys.argv[2]),
        'authmethod': 'NONE',
        'auth': None
    }]
}]
print(json.dumps(data))
" "$target_iqn" "$portal_id" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct target params JSON: $params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local result
    result=$(tn_api_call_write "$host" "$api_key" "iscsi.target.create" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Target creation failed: $result"
        echo "$result" >&2
        return 1
    fi

    # Add reused flag to result for consistency with NVMe pattern
    if [[ "$portal_reused" == "true" ]]; then
        result=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
data['portal_reused'] = True
data['portal_id'] = $portal_id
print(json.dumps(data))
" 2>/dev/null || echo "$result")
    else
        result=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
data['portal_reused'] = False
data['portal_id'] = $portal_id
print(json.dumps(data))
" 2>/dev/null || echo "$result")
    fi

    log "INFO" "Target created successfully: $target_iqn"
    echo "$result"
    return 0
}

# Delete an iSCSI target
# Parameters: host, api_key, target_id
# Returns: 0 on success, 1 on failure
tn_delete_target() {
    local host="$1"
    local api_key="$2"
    local target_id="$3"

    log "INFO" "Deleting iSCSI target: $target_id"

    local params
    params=$(printf '[%s]' "$target_id")

    local result
    result=$(tn_api_call_write "$host" "$api_key" "iscsi.target.delete" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Target deletion failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Target deleted successfully"
    return 0
}

# Query existing NVMe subsystems
# Parameters: host, api_key
# Returns: JSON array of subsystems
tn_query_subsystems() {
    local host="$1"
    local api_key="$2"

    log "INFO" "Querying NVMe subsystems"
    tn_api_call "$host" "$api_key" "nvmet.subsys.query" "[]"
}

# Check if an NVMe subsystem with specific NQN exists
# Parameters: host, api_key, subsystem_nqn
# Returns: JSON object if exists, exit 1 if not found
tn_check_subsystem() {
    local host="$1"
    local api_key="$2"
    local subsystem_nqn="$3"

    log "INFO" "Checking if NVMe subsystem exists: $subsystem_nqn"

    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [[['subnqn', '=', sys.argv[1]]]]
print(json.dumps(data))
" "$subsystem_nqn" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct subsystem query params: $params"
        return 1
    fi

    local result
    result=$(tn_api_call "$host" "$api_key" "nvmet.subsys.query" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Subsystem check failed: $result"
        return 1
    fi

    if [[ "$result" == "[]" ]] || [[ -z "$result" ]]; then
        log "INFO" "Subsystem does not exist: $subsystem_nqn"
        return 1
    fi

    log "INFO" "Subsystem exists: $subsystem_nqn"
    echo "$result"
    return 0
}

# Generate a standard NQN for NVMe subsystem
# Parameters: storage_name
# Returns: Generated NQN string
generate_nqn() {
    local storage_name="$1"
    local year_month
    year_month=$(date +%Y-%m)

    # Format: nqn.YYYY-MM.org.freenas.ctl:storage-name
    echo "nqn.${year_month}.org.freenas.ctl:${storage_name}"
}

# Create an NVMe subsystem
# Parameters: host, api_key, subsystem_name, subsystem_nqn
# Returns: JSON with created subsystem info
tn_create_subsystem() {
    local host="$1"
    local api_key="$2"
    local subsystem_name="$3"
    local subsystem_nqn="$4"

    log "INFO" "Creating NVMe subsystem: $subsystem_nqn"

    # Create subsystem with allow_any_host=true (as per design non-goals)
    local params
    # Use Python to construct JSON with proper escaping
    params=$(python3 -c "
import json, sys
data = [{
    'name': sys.argv[1],
    'subnqn': sys.argv[2],
    'allow_any_host': True
}]
print(json.dumps(data))
" "$subsystem_name" "$subsystem_nqn" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct subsystem params JSON: $params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local result
    result=$(tn_api_call_write "$host" "$api_key" "nvmet.subsys.create" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Subsystem creation failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Subsystem created successfully: $subsystem_nqn"
    echo "$result"
    return 0
}

# Delete an NVMe subsystem
# Parameters: host, api_key, subsystem_id
# Returns: 0 on success, 1 on failure
tn_delete_subsystem() {
    local host="$1"
    local api_key="$2"
    local subsystem_id="$3"

    log "INFO" "Deleting NVMe subsystem: $subsystem_id"

    local params
    params=$(printf '[%s]' "$subsystem_id")

    local result
    result=$(tn_api_call_write "$host" "$api_key" "nvmet.subsys.delete" "$params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Subsystem deletion failed: $result"
        echo "$result" >&2
        return 1
    fi

    log "INFO" "Subsystem deleted successfully"
    return 0
}

# Find existing NVMe port by address and transport
# Parameters: host, api_key, listen_ip, listen_port
# Returns: port ID if found, empty string if not found
tn_find_nvme_port() {
    local host="$1"
    local api_key="$2"
    local listen_ip="$3"
    local listen_port="${4:-4420}"

    log "INFO" "Searching for existing NVMe port: $listen_ip:$listen_port"

    # Query all ports
    local ports_result
    ports_result=$(tn_api_call "$host" "$api_key" "nvmet.port.query" "[]" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "WARNING" "Failed to query NVMe ports: $ports_result"
        echo ""
        return 1
    fi

    # Find port matching address and transport
    local port_id
    port_id=$(echo "$ports_result" | python3 -c "
import sys, json
try:
    ports = json.load(sys.stdin)
    for port in ports:
        if (port.get('addr_trtype') == 'TCP' and
            port.get('addr_traddr') == '$listen_ip' and
            str(port.get('addr_trsvcid')) == '$listen_port'):
            print(port.get('id', ''))
            break
except:
    pass
" 2>/dev/null)

    if [[ -n "$port_id" ]]; then
        log "INFO" "Found existing NVMe port with ID: $port_id"
        echo "$port_id"
        return 0
    fi

    log "INFO" "No existing NVMe port found for $listen_ip:$listen_port"
    echo ""
    return 1
}

# Create NVMe port for subsystem (or reuse existing port)
# Parameters: host, api_key, subsystem_id, listen_ip, listen_port
# Returns: JSON with port info (created or existing)
tn_create_nvme_port() {
    local host="$1"
    local api_key="$2"
    local subsystem_id="$3"
    local listen_ip="$4"
    local listen_port="${5:-4420}"

    log "INFO" "Creating/finding NVMe port for subsystem $subsystem_id: $listen_ip:$listen_port"

    local port_id=""
    local port_result=""
    local port_reused=false

    # Step 1: Check if port already exists
    port_id=$(tn_find_nvme_port "$host" "$api_key" "$listen_ip" "$listen_port" 2>/dev/null)

    if [[ -n "$port_id" ]]; then
        log "INFO" "Reusing existing NVMe port ID: $port_id"
        port_reused=true
        # Create a JSON result for consistency
        port_result=$(python3 -c "
import json, sys
data = {'id': int(sys.argv[1]), 'addr_trtype': 'TCP', 'addr_traddr': sys.argv[2], 'addr_trsvcid': int(sys.argv[3]), 'reused': True}
print(json.dumps(data))
" "$port_id" "$listen_ip" "$listen_port" 2>&1)
    else
        # Create the port (TrueNAS 25.10+ uses separate port and subsystem association)
        local port_params
        # Use Python to construct JSON with proper escaping
        port_params=$(python3 -c "
import json, sys
data = [{'addr_trtype': 'TCP', 'addr_traddr': sys.argv[1], 'addr_trsvcid': int(sys.argv[2])}]
print(json.dumps(data))
" "$listen_ip" "$listen_port" 2>&1)

        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to construct port params JSON: $port_params"
            echo "Failed to construct JSON params" >&2
            return 1
        fi

        port_result=$(tn_api_call_write "$host" "$api_key" "nvmet.port.create" "$port_params" 2>&1)
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            log "ERROR" "NVMe port creation failed: $port_result"
            echo "$port_result" >&2
            return 1
        fi

        # Extract port ID from result
        port_id=$(echo "$port_result" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('id', ''))" 2>/dev/null)

        if [[ -z "$port_id" ]]; then
            log "ERROR" "Failed to extract port ID from result: $port_result"
            echo "Failed to extract port ID" >&2
            return 1
        fi

        log "INFO" "NVMe port created with ID: $port_id"
    fi

    # Step 2: Associate port with subsystem
    local assoc_params
    # Use Python to construct JSON (port_id and subsys_id are integers)
    assoc_params=$(python3 -c "
import json, sys
data = [{'port_id': int(sys.argv[1]), 'subsys_id': int(sys.argv[2])}]
print(json.dumps(data))
" "$port_id" "$subsystem_id" 2>&1)

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to construct association params JSON: $assoc_params"
        echo "Failed to construct JSON params" >&2
        return 1
    fi

    local assoc_result
    assoc_result=$(tn_api_call_write "$host" "$api_key" "nvmet.port_subsys.create" "$assoc_params" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        # Check if association already exists (common when reusing ports)
        if echo "$assoc_result" | grep -q "already"; then
            log "INFO" "Port-subsystem association already exists"
        else
            log "ERROR" "NVMe port-subsystem association failed: $assoc_result"
            echo "$assoc_result" >&2
            return 1
        fi
    fi

    if [[ "$port_reused" == "true" ]]; then
        log "INFO" "Reused existing NVMe port and associated with subsystem"
    else
        log "INFO" "NVMe port created and associated with subsystem successfully"
    fi

    echo "$port_result"
    return 0
}

# ============================================================================
# RESOURCE VALIDATION FUNCTIONS
# ============================================================================

# Validate dataset exists via API
# Parameters: host, api_key, dataset_path
# Returns: 0 if valid, 1 if invalid
validate_dataset_exists() {
    local host="$1"
    local api_key="$2"
    local dataset="$3"

    local result
    result=$(tn_check_dataset "$host" "$api_key" "$dataset" 2>/dev/null)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]] && [[ -n "$result" ]]; then
        return 0
    fi
    return 1
}

# Validate iSCSI target is discoverable from Proxmox
# Parameters: portal_ip, portal_port, target_iqn
# Returns: 0 if discoverable, 1 if not
# Note: Retries for up to 10 seconds to allow iSCSI service to register new targets
validate_iscsi_discovery() {
    local portal_ip="$1"
    local portal_port="${2:-3260}"
    local target_iqn="$3"
    local max_attempts=10
    local attempt=1

    log "INFO" "Validating iSCSI discovery: $target_iqn at $portal_ip:$portal_port"

    # Check if iscsiadm is available
    if ! command -v iscsiadm &>/dev/null; then
        log "WARNING" "iscsiadm not found, skipping iSCSI discovery validation"
        return 0  # Don't fail if tool not available
    fi

    # Retry loop - wait up to 10 seconds for target to become discoverable
    while [[ $attempt -le $max_attempts ]]; do
        # Perform discovery
        local discovery_output
        discovery_output=$(iscsiadm -m discovery -t sendtargets -p "${portal_ip}:${portal_port}" 2>&1)
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            # Check if target is in discovery output
            if echo "$discovery_output" | grep -q "$target_iqn"; then
                log "INFO" "iSCSI target discovered successfully: $target_iqn (attempt $attempt)"
                return 0
            fi
        fi

        # Wait 1 second before retry (except on last attempt)
        if [[ $attempt -lt $max_attempts ]]; then
            sleep 1
        fi
        ((attempt++))
    done

    log "ERROR" "Target not found in discovery after ${max_attempts}s: $target_iqn"
    return 1
}

# Validate NVMe subsystem is discoverable from Proxmox
# Parameters: portal_ip, portal_port, subsystem_nqn
# Returns: 0 if discoverable, 1 if not
validate_nvme_discovery() {
    local portal_ip="$1"
    local portal_port="${2:-4420}"
    local subsystem_nqn="$3"

    log "INFO" "Validating NVMe discovery: $subsystem_nqn at $portal_ip:$portal_port"

    # Check if nvme command is available
    if ! command -v nvme &>/dev/null; then
        log "WARNING" "nvme command not found, skipping NVMe discovery validation"
        return 0  # Don't fail if tool not available
    fi

    # Perform discovery
    local discovery_output
    discovery_output=$(nvme discover -t tcp -a "$portal_ip" -s "$portal_port" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "NVMe discovery failed: $discovery_output"
        return 1
    fi

    # Check if subsystem NQN is in discovery output
    if echo "$discovery_output" | grep -q "$subsystem_nqn"; then
        log "INFO" "NVMe subsystem discovered successfully: $subsystem_nqn"
        return 0
    fi

    log "ERROR" "Subsystem not found in discovery: $subsystem_nqn"
    return 1
}

# Combined validation orchestrator
# Parameters: host, api_key, transport_mode, dataset, target_or_nqn, portal_ip, portal_port
# Returns: 0 if all validations pass, 1 if any fail
validate_provisioning() {
    local host="$1"
    local api_key="$2"
    local transport_mode="$3"
    local dataset="$4"
    local target_or_nqn="$5"
    local portal_ip="$6"
    local portal_port="$7"

    local failures=0

    info "Validating provisioned resources..."
    echo

    # Validate dataset
    printf "  %-30s" "Dataset exists..."
    if validate_dataset_exists "$host" "$api_key" "$dataset"; then
        echo "${c2}OK${c0}"
    else
        echo "${c1}FAILED${c0}"
        ((failures++))
    fi

    # Validate transport-specific resources
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        printf "  %-30s" "NVMe subsystem discoverable..."
        if validate_nvme_discovery "$portal_ip" "$portal_port" "$target_or_nqn"; then
            echo "${c2}OK${c0}"
        else
            echo "${c1}FAILED${c0}"
            warning "NVMe discovery failed. Check:"
            warning "  - TrueNAS NVMe-oF service is running"
            warning "  - Firewall allows port $portal_port"
            warning "  - Network path to $portal_ip is available"
            ((failures++))
        fi
    else
        printf "  %-30s" "iSCSI target discoverable..."
        if validate_iscsi_discovery "$portal_ip" "$portal_port" "$target_or_nqn"; then
            echo "${c2}OK${c0}"
        else
            echo "${c1}FAILED${c0}"
            warning "iSCSI discovery failed. Check:"
            warning "  - TrueNAS iSCSI service is running"
            warning "  - Firewall allows port $portal_port"
            warning "  - Network path to $portal_ip is available"
            ((failures++))
        fi
    fi

    echo

    if [[ $failures -gt 0 ]]; then
        error "Validation failed with $failures error(s)"
        return 1
    fi

    success "All validations passed"
    return 0
}

# ============================================================================
# ROLLBACK FUNCTIONS
# ============================================================================

# Perform rollback of all registered resources
# Parameters: host, api_key
# Returns: 0 if all deleted, 1 if any failures
rollback_provisioning() {
    local host="$1"
    local api_key="$2"

    local resource_count=${#ROLLBACK_RESOURCES[@]}
    if [[ $resource_count -eq 0 ]]; then
        info "No resources to rollback"
        return 0
    fi

    echo
    warning "The following resources will be deleted:"
    for resource in "${ROLLBACK_RESOURCES[@]}"; do
        echo "  - $resource"
    done
    echo

    local confirm
    read -rp "Type 'DELETE' to confirm rollback: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        warning "Rollback cancelled"
        return 1
    fi

    local failures=0
    local failed_resources=()

    # Delete in reverse order (LIFO)
    info "Rolling back resources..."
    for ((i=${#ROLLBACK_RESOURCES[@]}-1; i>=0; i--)); do
        local resource="${ROLLBACK_RESOURCES[$i]}"
        local resource_type="${resource%%:*}"
        local resource_id="${resource#*:}"

        printf "  Deleting %s: %s..." "$resource_type" "$resource_id"

        local delete_result=0
        case "$resource_type" in
            dataset)
                tn_delete_dataset "$host" "$api_key" "$resource_id" >/dev/null 2>&1 || delete_result=1
                ;;
            portal)
                tn_delete_portal "$host" "$api_key" "$resource_id" >/dev/null 2>&1 || delete_result=1
                ;;
            target)
                tn_delete_target "$host" "$api_key" "$resource_id" >/dev/null 2>&1 || delete_result=1
                ;;
            subsystem)
                tn_delete_subsystem "$host" "$api_key" "$resource_id" >/dev/null 2>&1 || delete_result=1
                ;;
            *)
                warning "Unknown resource type: $resource_type"
                delete_result=1
                ;;
        esac

        if [[ $delete_result -eq 0 ]]; then
            echo " ${c2}OK${c0}"
        else
            echo " ${c1}FAILED${c0}"
            ((failures++))
            failed_resources+=("$resource")
        fi
    done

    # Clear state after rollback attempt
    clear_rollback_state

    if [[ $failures -gt 0 ]]; then
        echo
        error "Rollback completed with $failures failure(s)"
        warning "The following resources may need manual cleanup:"
        for resource in "${failed_resources[@]}"; do
            warning "  - $resource"
        done
        return 1
    fi

    echo
    success "Rollback completed successfully"
    return 0
}

# ============================================================================
# PROVISIONING MODE SELECTION
# ============================================================================

# Select provisioning mode
# Returns: "create" | "existing" | "cancel"
select_provisioning_mode() {
    # Output menu to stderr so it displays when captured with $()
    echo >&2
    printf '%b\n' "${c4}  How would you like to configure TrueNAS storage?${c0}" >&2
    echo "  1) Create new storage on TrueNAS (automated provisioning)" >&2
    echo "  2) Use existing storage (manual configuration)" >&2
    echo "  0) Cancel" >&2
    echo >&2

    local choice
    while true; do
        read -rp "Select option [0-2]: " choice
        case "$choice" in
            0) echo "cancel"; return 0 ;;
            1) echo "create"; return 0 ;;
            2) echo "existing"; return 0 ;;
            *) error "Invalid choice. Please enter 0, 1, or 2" ;;
        esac
    done
}

# ============================================================================
# PROVISIONING WORKFLOW - INPUT COLLECTION
# ============================================================================

# Global variables for provisioning configuration
PROV_POOL=""
PROV_DATASET_NAME=""
PROV_DATASET_PATH=""
PROV_DATASET_EXISTS="false"
PROV_NQN=""
PROV_IQN=""
PROV_TARGET_EXISTS="false"
PROV_PORTAL_IP=""
PROV_PORTAL_PORT=""
PROV_PORTAL_ID=""
PROV_PORTAL_IPS=()           # Array of selected portal IPs for multipath
PROV_USE_MULTIPATH=""        # "1" if multipath enabled
PROV_ADDITIONAL_PORTALS=""   # Comma-separated additional portals (IP:port)
PROV_BLOCKSIZE=""
PROV_SPARSE=""
PROV_HOSTNQN=""

# Show progressive summary of collected configuration
# Parameters: storage_name, transport_mode
show_progress_summary() {
    local storage_name="$1"
    local transport_mode="$2"

    echo
    printf "  ${c4}%-18s${c0} %s\n" "Storage Name:" "$storage_name"
    printf "  ${c4}%-18s${c0} %s\n" "Transport:" "$transport_mode"

    if [[ -n "$PROV_POOL" ]]; then
        printf "  ${c4}%-18s${c0} %s\n" "Pool:" "$PROV_POOL"
    fi

    if [[ -n "$PROV_DATASET_NAME" ]]; then
        local ds_status=""
        if [[ "$PROV_DATASET_EXISTS" == "true" ]]; then
            ds_status=" ${c3}(existing)${c0}"
        else
            ds_status=" ${c2}(new)${c0}"
        fi
        printf "  ${c4}%-18s${c0} %s%s\n" "Dataset:" "$PROV_DATASET_PATH" "$ds_status"
    fi

    if [[ -n "$PROV_NQN" ]]; then
        local tgt_status=""
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            tgt_status=" ${c3}(existing)${c0}"
        else
            tgt_status=" ${c2}(new)${c0}"
        fi
        printf "  ${c4}%-18s${c0} %s%s\n" "Subsystem NQN:" "$PROV_NQN" "$tgt_status"
    fi

    if [[ -n "$PROV_IQN" ]]; then
        local tgt_status=""
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            tgt_status=" ${c3}(existing)${c0}"
        else
            tgt_status=" ${c2}(new)${c0}"
        fi
        printf "  ${c4}%-18s${c0} %s%s\n" "Target IQN:" "$PROV_IQN" "$tgt_status"
    fi

    if [[ -n "$PROV_PORTAL_IP" ]]; then
        if [[ ${#PROV_PORTAL_IPS[@]} -gt 1 ]]; then
            # Multiple portals - show multipath
            printf "  ${c4}%-18s${c0} %s ${c2}(multipath: %d)${c0}\n" "Portals:" "${PROV_PORTAL_IPS[0]}:${PROV_PORTAL_PORT}" "${#PROV_PORTAL_IPS[@]}"
            for ((i=1; i<${#PROV_PORTAL_IPS[@]}; i++)); do
                printf "  ${c4}%-18s${c0} %s:%s\n" "" "${PROV_PORTAL_IPS[$i]}" "$PROV_PORTAL_PORT"
            done
        else
            printf "  ${c4}%-18s${c0} %s:%s\n" "Portal:" "$PROV_PORTAL_IP" "$PROV_PORTAL_PORT"
        fi
    fi

    echo
    echo "  ---"
    echo
}

# Collect all provisioning configuration upfront using progressive wizard
# Parameters: host, api_key, storage_name, transport_mode
# Returns: 0 on success (config collected), 1 on cancel/failure
# Sets: PROV_* global variables and updates WIZARD_* for display
collect_provisioning_config() {
    local host="$1"
    local api_key="$2"
    local storage_name="$3"
    local transport_mode="$4"

    # Reset all config variables
    PROV_POOL=""
    PROV_DATASET_NAME=""
    PROV_DATASET_PATH=""
    PROV_DATASET_EXISTS="false"
    PROV_NQN=""
    PROV_IQN=""
    PROV_TARGET_EXISTS="false"
    PROV_PORTAL_IP=""
    PROV_PORTAL_PORT=""
    PROV_PORTAL_IPS=()
    PROV_USE_MULTIPATH=""
    PROV_ADDITIONAL_PORTALS=""
    PROV_BLOCKSIZE=""
    PROV_SPARSE=""
    PROV_HOSTNQN=""

    # Fetch pools first (before showing UI)
    local pools_json
    pools_json=$(tn_list_pools "$host" "$api_key" 2>&1)
    if [[ $? -ne 0 ]]; then
        error "Failed to list pools: $pools_json"
        return 1
    fi

    local -a pool_names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && pool_names+=("$name")
    done < <(echo "$pools_json" | python3 -c "import sys, json; pools = json.load(sys.stdin); print('\n'.join(p['name'] for p in pools))" 2>/dev/null)

    if [[ ${#pool_names[@]} -eq 0 ]]; then
        error "No ZFS pools found on TrueNAS"
        return 1
    fi

    # --- Step 1: Pool Selection ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "pool"

    info "Select ZFS pool:"
    local idx=1
    for pool in "${pool_names[@]}"; do
        echo "  $idx) $pool"
        ((idx++))
    done
    echo

    local pool_choice
    while true; do
        read -rp "Select pool [1-${#pool_names[@]}]: " pool_choice
        if [[ "$pool_choice" =~ ^[0-9]+$ ]] && [[ "$pool_choice" -ge 1 ]] && [[ "$pool_choice" -le "${#pool_names[@]}" ]]; then
            PROV_POOL="${pool_names[$((pool_choice-1))]}"
            WIZARD_POOL="$PROV_POOL"
            break
        else
            error "Invalid selection"
        fi
    done

    # --- Step 2: Dataset Name ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "dataset"

    info "Enter dataset name (will be created under ${WIZARD_POOL}/):"
    while true; do
        read -rp "Dataset name (e.g., proxmox): " PROV_DATASET_NAME
        if [[ -z "$PROV_DATASET_NAME" ]]; then
            error "Dataset name cannot be empty"
            continue
        fi
        if [[ ! "$PROV_DATASET_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            error "Dataset name can only contain letters, numbers, hyphens, and underscores"
            continue
        fi
        break
    done

    PROV_DATASET_PATH="${PROV_POOL}/${PROV_DATASET_NAME}"
    WIZARD_DATASET="$PROV_DATASET_NAME"
    WIZARD_DATASET_PATH="$PROV_DATASET_PATH"

    # Check if dataset exists with spinner
    echo
    printf "  %-30s" "Checking dataset..."
    start_spinner
    if tn_check_dataset "$host" "$api_key" "$PROV_DATASET_PATH" >/dev/null 2>&1; then
        PROV_DATASET_EXISTS="true"
        WIZARD_DATASET_EXISTS="true"
    else
        PROV_DATASET_EXISTS="false"
        WIZARD_DATASET_EXISTS="false"
    fi
    stop_spinner
    if [[ "$PROV_DATASET_EXISTS" == "true" ]]; then
        echo -e "\r  $(printf "%-30s" "Checking dataset...")${c3}EXISTS${c0} (will use existing)"
    else
        echo -e "\r  $(printf "%-30s" "Checking dataset...")${c2}OK${c0} (will create new)"
    fi
    sleep 1

    # --- Step 3: Target/Subsystem Configuration ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "target"

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # NVMe subsystem configuration
        local auto_nqn
        auto_nqn="nqn.$(date +%Y-%m).org.freenas.ctl:${storage_name}"

        info "NVMe Subsystem Configuration:"
        echo "  1) Use auto-generated NQN: $auto_nqn"
        echo "  2) Enter custom NQN"
        echo

        local nqn_choice
        read -rp "Select option [1-2] [1]: " nqn_choice
        nqn_choice=${nqn_choice:-1}

        case "$nqn_choice" in
            1) PROV_NQN="$auto_nqn" ;;
            2)
                while true; do
                    read -rp "Enter NQN: " PROV_NQN
                    if [[ -z "$PROV_NQN" ]]; then
                        error "NQN cannot be empty"
                        continue
                    fi
                    break
                done
                ;;
            *) PROV_NQN="$auto_nqn" ;;
        esac

        WIZARD_TARGET="$PROV_NQN"

        # Check if subsystem exists with spinner
        echo
        printf "  %-30s" "Checking subsystem..."
        start_spinner
        if tn_check_subsystem "$host" "$api_key" "$PROV_NQN" >/dev/null 2>&1; then
            PROV_TARGET_EXISTS="true"
            WIZARD_TARGET_EXISTS="true"
        else
            PROV_TARGET_EXISTS="false"
            WIZARD_TARGET_EXISTS="false"
        fi
        stop_spinner
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            echo -e "\r  $(printf "%-30s" "Checking subsystem...")${c3}EXISTS${c0} (will use existing)"
        else
            echo -e "\r  $(printf "%-30s" "Checking subsystem...")${c2}OK${c0} (will create new)"
        fi
        sleep 1
    else
        # iSCSI target configuration
        local auto_iqn
        auto_iqn="iqn.$(date +%Y-%m).org.freenas.ctl:${storage_name}"

        info "iSCSI Target Configuration:"
        echo "  1) Use auto-generated IQN: $auto_iqn"
        echo "  2) Enter custom IQN"
        echo

        local iqn_choice
        read -rp "Select option [1-2] [1]: " iqn_choice
        iqn_choice=${iqn_choice:-1}

        case "$iqn_choice" in
            1) PROV_IQN="$auto_iqn" ;;
            2)
                while true; do
                    read -rp "Enter IQN: " PROV_IQN
                    if [[ -z "$PROV_IQN" ]]; then
                        error "IQN cannot be empty"
                        continue
                    fi
                    break
                done
                ;;
            *) PROV_IQN="$auto_iqn" ;;
        esac

        WIZARD_TARGET="$PROV_IQN"

        # Check if target exists with spinner
        echo
        printf "  %-30s" "Checking target..."
        start_spinner
        if tn_check_target "$host" "$api_key" "$PROV_IQN" >/dev/null 2>&1; then
            PROV_TARGET_EXISTS="true"
            WIZARD_TARGET_EXISTS="true"
        else
            PROV_TARGET_EXISTS="false"
            WIZARD_TARGET_EXISTS="false"
        fi
        stop_spinner
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            echo -e "\r  $(printf "%-30s" "Checking target...")${c3}EXISTS${c0} (will use existing)"
        else
            echo -e "\r  $(printf "%-30s" "Checking target...")${c2}OK${c0} (will create new)"
        fi
        sleep 1
    fi

    # --- Step 4: Portal Configuration (Interface Selection) ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "portal"

    local default_port
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        info "NVMe Portal Configuration:"
        default_port="4420"
    else
        info "iSCSI Portal Configuration:"
        # Query TrueNAS for configured iSCSI port (may differ from default 3260)
        default_port=$(tn_get_iscsi_port "$host" "$api_key" 2>/dev/null)
        if [[ -z "$default_port" ]]; then
            default_port="3260"  # Fallback to standard port
        fi
    fi

    # Query TrueNAS network interfaces
    echo
    info "Querying TrueNAS network interfaces..."
    local interfaces_json
    interfaces_json=$(tn_query_interfaces "$host" "$api_key")

    local interface_selection_ok=false
    if [[ -n "$interfaces_json" ]] && [[ "$interfaces_json" != "[]" ]]; then
        # Display interface table and allow selection
        if display_interface_table "$interfaces_json" "$transport_mode" "$host" "$api_key"; then
            local num_interfaces=${#IFACE_IPS[@]}

            if [[ $num_interfaces -gt 0 ]]; then
                info "Select one or more interfaces for storage access"
                if [[ $num_interfaces -gt 1 ]]; then
                    info "Selecting multiple interfaces enables multipath for redundancy/performance"
                fi

                select_interfaces "$num_interfaces"

                if [[ ${#SELECTED_IFACE_INDICES[@]} -gt 0 ]]; then
                    interface_selection_ok=true

                    # Build portal IP array from selection
                    PROV_PORTAL_IPS=()
                    for idx in "${SELECTED_IFACE_INDICES[@]}"; do
                        local arr_idx=$((idx-1))
                        PROV_PORTAL_IPS+=("${IFACE_IPS[$arr_idx]}")
                    done

                    # Set primary portal from first selection
                    PROV_PORTAL_IP="${PROV_PORTAL_IPS[0]}"
                    PROV_PORTAL_PORT="$default_port"

                    # NVMe-specific: prompt for port number
                    if [[ "$transport_mode" == "nvme-tcp" ]]; then
                        echo
                        read -rp "NVMe port [${default_port}]: " nvme_port
                        nvme_port="${nvme_port:-$default_port}"
                        PROV_PORTAL_PORT="$nvme_port"
                    fi

                    # Handle multipath if multiple interfaces selected
                    if [[ ${#PROV_PORTAL_IPS[@]} -gt 1 ]]; then
                        # Build additional portals (all except first)
                        local additional=()
                        for ((i=1; i<${#PROV_PORTAL_IPS[@]}; i++)); do
                            additional+=("${PROV_PORTAL_IPS[$i]}:${PROV_PORTAL_PORT}")
                        done
                        PROV_ADDITIONAL_PORTALS=$(IFS=,; echo "${additional[*]}")

                        # Check for multipath support
                        if [[ "$transport_mode" == "iscsi" ]]; then
                            if ! command -v multipath &> /dev/null; then
                                warning "multipath-tools package is not installed"
                                info "Multipath requires: apt-get install multipath-tools"
                                read -rp "Continue configuring multipath anyway? [y/N]: " continue_mp
                                if [[ "$continue_mp" =~ ^[Yy] ]]; then
                                    PROV_USE_MULTIPATH="1"
                                else
                                    info "Using first interface only for storage access"
                                    PROV_PORTAL_IPS=("${PROV_PORTAL_IPS[0]}")
                                    PROV_ADDITIONAL_PORTALS=""
                                fi
                            else
                                PROV_USE_MULTIPATH="1"
                                info "Multipath enabled with ${#PROV_PORTAL_IPS[@]} interfaces"
                            fi
                        else
                            # NVMe/TCP uses native kernel multipath
                            info "NVMe/TCP will use native kernel multipath with ${#PROV_PORTAL_IPS[@]} interfaces"
                        fi
                    fi
                fi
            fi
        fi
    fi

    # Fallback to manual entry if interface selection failed
    if [[ "$interface_selection_ok" != "true" ]]; then
        warning "Could not query TrueNAS interfaces, using manual entry"
        while true; do
            read -rp "Portal IP address [${host}]: " PROV_PORTAL_IP
            PROV_PORTAL_IP=${PROV_PORTAL_IP:-$host}
            if validate_ip "$PROV_PORTAL_IP"; then
                break
            else
                error "Invalid IP address format"
            fi
        done
        PROV_PORTAL_PORT="$default_port"
        PROV_PORTAL_IPS=("$PROV_PORTAL_IP")
    fi

    WIZARD_PORTAL_IP="$PROV_PORTAL_IP"
    WIZARD_PORTAL_PORT="$PROV_PORTAL_PORT"
    WIZARD_PORTAL_IPS=("${PROV_PORTAL_IPS[@]}")
    WIZARD_USE_MULTIPATH="$PROV_USE_MULTIPATH"

    # --- Step 5: Block Size Configuration ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "blocksize"

    info "ZFS Block Size Configuration:"
    echo "  Recommended sizes based on workload:"
    echo "    4K  - Databases with small random I/O (PostgreSQL, MySQL)"
    echo "    8K  - General-purpose databases, mixed workloads"
    echo "    16K - Default, balanced for most VM workloads (Recommended)"
    echo "    32K - Large sequential I/O, media files"
    echo "    64K - Very large files, backup storage"
    echo "    128K - Maximum for large sequential workloads"
    echo

    while true; do
        read -rp "Block size [16K]: " PROV_BLOCKSIZE
        PROV_BLOCKSIZE="${PROV_BLOCKSIZE:-16K}"
        # Validate blocksize format (number followed by K or M)
        if [[ "$PROV_BLOCKSIZE" =~ ^[0-9]+[KkMm]$ ]]; then
            # Normalize to uppercase
            PROV_BLOCKSIZE="${PROV_BLOCKSIZE^^}"
            # Extract numeric part
            local bs_num="${PROV_BLOCKSIZE%[KM]}"
            local bs_unit="${PROV_BLOCKSIZE: -1}"
            # Convert to bytes for validation
            local bs_bytes
            if [[ "$bs_unit" == "K" ]]; then
                bs_bytes=$((bs_num * 1024))
            else
                bs_bytes=$((bs_num * 1024 * 1024))
            fi
            # Valid range: 512 bytes to 1M (ZFS limit)
            if [[ "$bs_bytes" -ge 512 ]] && [[ "$bs_bytes" -le 1048576 ]]; then
                # Must be power of 2
                if (( (bs_bytes & (bs_bytes - 1)) == 0 )); then
                    break
                else
                    error "Block size must be a power of 2 (e.g., 4K, 8K, 16K, 32K, 64K, 128K)"
                fi
            else
                error "Block size must be between 512 bytes and 1M"
            fi
        else
            error "Invalid format. Use number followed by K or M (e.g., 16K, 128K, 1M)"
        fi
    done
    WIZARD_BLOCKSIZE="$PROV_BLOCKSIZE"

    # --- Step 6: Sparse Volume Configuration ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "sparse"

    info "Sparse Volume Configuration:"
    echo "  Sparse volumes (thin provisioning) allocate space on-demand rather than"
    echo "  pre-allocating the full size. This saves storage space but may cause"
    echo "  slight fragmentation over time. Recommended for most use cases."
    echo

    while true; do
        read -rp "Enable sparse volumes? [Y/n]: " sparse_choice
        sparse_choice="${sparse_choice:-Y}"
        if [[ "$sparse_choice" =~ ^[Yy]$ ]]; then
            PROV_SPARSE="1"
            break
        elif [[ "$sparse_choice" =~ ^[Nn]$ ]]; then
            PROV_SPARSE="0"
            break
        else
            error "Please enter Y or N"
        fi
    done
    WIZARD_SPARSE="$PROV_SPARSE"

    # --- Step 7: Host NQN Configuration (NVMe only) ---
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        clear_screen
        print_banner
        echo
        print_header "Storage Provisioning"
        show_wizard_summary "hostnqn"

        info "Host NQN Configuration:"
        echo "  The Host NQN (NVMe Qualified Name) identifies this Proxmox host to the"
        echo "  TrueNAS storage system. It is used for access control and connection"
        echo "  tracking."
        echo

        # Check for existing host NQN
        local existing_hostnqn=""
        if [[ -f /etc/nvme/hostnqn ]]; then
            existing_hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
        fi

        if [[ -n "$existing_hostnqn" ]]; then
            success "Found existing host NQN:"
            echo "  $existing_hostnqn"
            echo
            while true; do
                read -rp "Use this host NQN? [Y/n]: " use_existing
                use_existing="${use_existing:-Y}"
                if [[ "$use_existing" =~ ^[Yy]$ ]]; then
                    PROV_HOSTNQN="$existing_hostnqn"
                    break
                elif [[ "$use_existing" =~ ^[Nn]$ ]]; then
                    echo
                    read -rp "Enter custom host NQN: " PROV_HOSTNQN
                    if [[ -z "$PROV_HOSTNQN" ]]; then
                        error "Host NQN cannot be empty"
                        continue
                    fi
                    break
                else
                    error "Please enter Y or N"
                fi
            done
        else
            warning "No existing host NQN found in /etc/nvme/hostnqn"
            echo
            echo "  You can:"
            echo "    1) Enter a custom NQN"
            echo "    2) Leave empty to use system default"
            echo
            read -rp "Host NQN (or press Enter for default): " PROV_HOSTNQN
        fi
        WIZARD_HOSTNQN="$PROV_HOSTNQN"
    fi

    return 0
}

# Show provisioning summary and get confirmation
# Parameters: storage_name, transport_mode
# Returns: 0 if confirmed, 1 if cancelled
show_provisioning_summary() {
    local storage_name="$1"
    local transport_mode="$2"

    # Clear screen and show summary header
    clear_screen
    print_banner
    print_header "Provisioning Summary"

    info "The following resources will be configured:"

    # Connection settings
    printf "  ${c2}✓${c0} %-20s %s\n" "Storage Name:" "$storage_name"
    printf "  ${c2}✓${c0} %-20s %s\n" "TrueNAS IP:" "$WIZARD_TRUENAS_IP"
    # API Key - show masked
    local masked_key="****${WIZARD_API_KEY: -4}"
    printf "  ${c2}✓${c0} %-20s %s\n" "API Key:" "$masked_key"
    printf "  ${c2}✓${c0} %-20s %s\n" "Transport Mode:" "$transport_mode"
    echo

    # Storage resources
    info "Storage Resources:"
    echo
    # Dataset
    if [[ "$PROV_DATASET_EXISTS" == "true" ]]; then
        printf "  ${c3}○${c0} %-20s %s %s\n" "Dataset:" "$PROV_DATASET_PATH" "${c3}(existing)${c0}"
    else
        printf "  ${c2}+${c0} %-20s %s %s\n" "Dataset:" "$PROV_DATASET_PATH" "${c2}(create new)${c0}"
    fi

    # Target/Subsystem
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            printf "  ${c3}○${c0} %-20s %s %s\n" "Subsystem NQN:" "$PROV_NQN" "${c3}(existing)${c0}"
        else
            printf "  ${c2}+${c0} %-20s %s %s\n" "Subsystem NQN:" "$PROV_NQN" "${c2}(create new)${c0}"
        fi
        printf "  ${c2}✓${c0} %-20s %s\n" "NVMe Port:" "${PROV_PORTAL_IP}:${PROV_PORTAL_PORT}"
    else
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            printf "  ${c3}○${c0} %-20s %s %s\n" "Target IQN:" "$PROV_IQN" "${c3}(existing)${c0}"
        else
            printf "  ${c2}+${c0} %-20s %s %s\n" "Target IQN:" "$PROV_IQN" "${c2}(create new)${c0}"
        fi
        printf "  ${c2}✓${c0} %-20s %s\n" "iSCSI Portal:" "${PROV_PORTAL_IP}:${PROV_PORTAL_PORT}"
    fi
    echo

    # Volume settings
    info "Volume Settings:"
    echo
    printf "  ${c2}✓${c0} %-20s %s\n" "Block Size:" "$PROV_BLOCKSIZE"
    local sparse_display="Yes (thin provisioning)"
    [[ "$PROV_SPARSE" == "0" ]] && sparse_display="No (thick provisioning)"
    printf "  ${c2}✓${c0} %-20s %s\n" "Sparse Volumes:" "$sparse_display"

    # Host NQN (NVMe only)
    if [[ "$transport_mode" == "nvme-tcp" ]] && [[ -n "$PROV_HOSTNQN" ]]; then
        # Truncate long NQN for display
        local nqn_display="$PROV_HOSTNQN"
        if [[ ${#nqn_display} -gt 45 ]]; then
            nqn_display="${nqn_display:0:42}..."
        fi
        printf "  ${c2}✓${c0} %-20s %s\n" "Host NQN:" "$nqn_display"
    fi
    echo

    # Legend
    echo "  ${c2}✓${c0} = Validated  ${c2}+${c0} = Will create  ${c3}○${c0} = Existing"
    echo

    read -rp "Proceed with provisioning? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        info "Provisioning cancelled"
        return 1
    fi

    return 0
}

# Execute provisioning with progress display
# Parameters: host, api_key, storage_name, transport_mode
# Returns: 0 on success, 1 on failure
execute_provisioning() {
    local host="$1"
    local api_key="$2"
    local storage_name="$3"
    local transport_mode="$4"

    # Clear any previous rollback state
    clear_rollback_state

    # Reset provisioned resource variables
    PROVISIONED_DATASET=""
    PROVISIONED_TARGET_IQN=""
    PROVISIONED_SUBSYSTEM_NQN=""
    PROVISIONED_PORTAL_IP=""
    PROVISIONED_PORTAL_PORT=""
    PROVISIONED_PORTAL_ID=""

    # Clear screen and show execution header
    clear_screen
    print_banner
    echo
    print_header "Executing Provisioning"

    local errors=0

    # --- Create Dataset ---
    if [[ "$PROV_DATASET_EXISTS" == "true" ]]; then
        echo -e "$(printf "%-30s " "Dataset:")${c2}✓${c0} Using existing"
        PROVISIONED_DATASET="$PROV_DATASET_PATH"
    else
        printf "%-30s " "Dataset:"
        start_spinner
        local result
        result=$(tn_create_dataset "$host" "$api_key" "$PROV_POOL" "$PROV_DATASET_NAME" 2>&1)
        local exit_code=$?
        stop_spinner
        if [[ $exit_code -eq 0 ]]; then
            echo -e "\r$(printf "%-30s " "Dataset:")${c2}✓${c0} Created"
            register_resource "dataset" "$PROV_DATASET_PATH"
            PROVISIONED_DATASET="$PROV_DATASET_PATH"
        else
            echo -e "\r$(printf "%-30s " "Dataset:")${c1}✗${c0} Failed to create"
            echo "  $result"
            ((errors++))
        fi
    fi

    # --- Create Target/Subsystem ---
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            echo -e "$(printf "%-30s " "NVMe subsystem:")${c2}✓${c0} Using existing"
            PROVISIONED_SUBSYSTEM_NQN="$PROV_NQN"
            # Get subsystem ID for port association
            local subsys_info
            subsys_info=$(tn_check_subsystem "$host" "$api_key" "$PROV_NQN" 2>/dev/null)
            PROV_SUBSYSTEM_ID=$(echo "$subsys_info" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('id', ''))" 2>/dev/null)
        else
            printf "%-30s " "NVMe subsystem:"
            start_spinner
            local result
            # Extract subsystem name from NQN (part after last colon)
            local subsys_name="${PROV_NQN##*:}"
            result=$(tn_create_subsystem "$host" "$api_key" "$subsys_name" "$PROV_NQN" 2>&1)
            local exit_code=$?
            stop_spinner
            if [[ $exit_code -eq 0 ]]; then
                echo -e "\r$(printf "%-30s " "NVMe subsystem:")${c2}✓${c0} Created"
                PROV_SUBSYSTEM_ID=$(echo "$result" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('id', ''))" 2>/dev/null)
                register_resource "subsystem" "$PROV_NQN"
                PROVISIONED_SUBSYSTEM_NQN="$PROV_NQN"
            else
                echo -e "\r$(printf "%-30s " "NVMe subsystem:")${c1}✗${c0} Failed to create"
                echo "  $result"
                ((errors++))
            fi
        fi

        # Create or reuse NVMe port
        if [[ $errors -eq 0 ]] && [[ -n "$PROV_SUBSYSTEM_ID" ]]; then
            printf "%-30s " "NVMe port:"
            start_spinner
            local result
            result=$(tn_create_nvme_port "$host" "$api_key" "$PROV_SUBSYSTEM_ID" "$PROV_PORTAL_IP" "$PROV_PORTAL_PORT" 2>&1)
            local exit_code=$?
            stop_spinner
            if [[ $exit_code -eq 0 ]]; then
                # Check if port was reused
                if echo "$result" | grep -q '"reused": true'; then
                    echo -e "\r$(printf "%-30s " "NVMe port:")${c2}✓${c0} Using existing"
                else
                    echo -e "\r$(printf "%-30s " "NVMe port:")${c2}✓${c0} Created"
                fi
                PROVISIONED_PORTAL_IP="$PROV_PORTAL_IP"
                PROVISIONED_PORTAL_PORT="$PROV_PORTAL_PORT"
            else
                echo -e "\r$(printf "%-30s " "NVMe port:")${c1}✗${c0} Failed to configure"
                echo "  $result"
                ((errors++))
            fi
        fi
    else
        # iSCSI provisioning
        if [[ "$PROV_TARGET_EXISTS" == "true" ]]; then
            echo -e "$(printf "%-30s " "iSCSI target:")${c2}✓${c0} Using existing"
            PROVISIONED_TARGET_IQN="$PROV_IQN"
        else
            printf "%-30s " "iSCSI target:"
            start_spinner
            local result
            result=$(tn_create_target "$host" "$api_key" "$PROV_IQN" "$PROV_PORTAL_IP" "$PROV_PORTAL_PORT" 2>&1)
            local exit_code=$?
            stop_spinner
            if [[ $exit_code -eq 0 ]]; then
                echo -e "\r$(printf "%-30s " "iSCSI target:")${c2}✓${c0} Created"
                register_resource "target" "$PROV_IQN"
                PROVISIONED_TARGET_IQN="$PROV_IQN"
                PROVISIONED_PORTAL_IP="$PROV_PORTAL_IP"
                PROVISIONED_PORTAL_PORT="$PROV_PORTAL_PORT"
            else
                echo -e "\r$(printf "%-30s " "iSCSI target:")${c1}✗${c0} Failed to create"
                echo "  $result"
                ((errors++))
            fi
        fi
    fi

    # --- Validation ---
    printf "%-30s " "Dataset validation:"
    start_spinner
    local dataset_valid=false
    validate_dataset_exists "$host" "$api_key" "$PROVISIONED_DATASET" && dataset_valid=true
    stop_spinner
    if [[ "$dataset_valid" == "true" ]]; then
        echo -e "\r$(printf "%-30s " "Dataset validation:")${c2}✓${c0} Verified"
    else
        echo -e "\r$(printf "%-30s " "Dataset validation:")${c1}✗${c0} Not found"
        ((errors++))
    fi

    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        printf "%-30s " "NVMe discovery:"
        start_spinner
        local discovery_valid=false
        validate_nvme_discovery "$PROV_PORTAL_IP" "$PROV_PORTAL_PORT" "$PROVISIONED_SUBSYSTEM_NQN" && discovery_valid=true
        stop_spinner
        if [[ "$discovery_valid" == "true" ]]; then
            echo -e "\r$(printf "%-30s " "NVMe discovery:")${c2}✓${c0} Subsystem visible"
        else
            echo -e "\r$(printf "%-30s " "NVMe discovery:")${c3}?${c0} May need service restart"
        fi
    else
        # For iSCSI, invoke the plugin's _ensure_target_visible to create weight volume
        # This makes the target discoverable via iscsiadm
        printf "%-30s " "Weight volume:"
        start_spinner
        local weight_result
        weight_result=$(perl -e '
            use lib "/usr/share/perl5/PVE/Storage/Custom";
            use TrueNASPlugin;

            my $scfg = {
                api_host => $ARGV[0],
                api_key => $ARGV[1],
                api_insecure => 1,
                dataset => $ARGV[2],
                target_iqn => $ARGV[3],
                discovery_portal => $ARGV[4],
            };

            eval { PVE::Storage::Custom::TrueNASPlugin::_ensure_target_visible($scfg) };
            if ($@) {
                print "ERROR: $@";
                exit 1;
            }
            print "OK";
        ' "$host" "$api_key" "$PROVISIONED_DATASET" "$PROVISIONED_TARGET_IQN" "${PROV_PORTAL_IP}:${PROV_PORTAL_PORT}" 2>&1)
        local weight_exit=$?
        stop_spinner

        if [[ $weight_exit -eq 0 ]]; then
            echo -e "\r$(printf "%-30s " "Weight volume:")${c2}✓${c0} Created"
        else
            echo -e "\r$(printf "%-30s " "Weight volume:")${c1}✗${c0} Failed"
            log "ERROR" "Weight volume creation failed: $weight_result"
        fi

        # Now verify with iscsiadm discovery
        printf "%-30s " "iSCSI discovery:"
        start_spinner
        local discovery_valid=false
        validate_iscsi_discovery "$PROV_PORTAL_IP" "$PROV_PORTAL_PORT" "$PROVISIONED_TARGET_IQN" && discovery_valid=true
        stop_spinner
        if [[ "$discovery_valid" == "true" ]]; then
            echo -e "\r$(printf "%-30s " "iSCSI discovery:")${c2}✓${c0} Target visible"
        else
            echo -e "\r$(printf "%-30s " "iSCSI discovery:")${c3}?${c0} May need service restart"
        fi
    fi

    echo
    if [[ $errors -gt 0 ]]; then
        error "Provisioning completed with $errors error(s)"
        echo
        echo "  1) Continue anyway"
        echo "  2) Rollback created resources"
        echo "  0) Cancel (keep resources)"
        echo

        local choice
        read -rp "Select option [0-2]: " choice
        case "$choice" in
            1)
                warning "Continuing with errors"
                clear_rollback_state
                return 0
                ;;
            2)
                rollback_provisioning "$host" "$api_key"
                return 1
                ;;
            *)
                clear_rollback_state
                return 1
                ;;
        esac
    fi

    success "Provisioning completed successfully!"
    echo
    read -rp "Press any key to continue..." -n1 _
    echo
    clear_rollback_state
    return 0
}

# Legacy function - deprecated, use collect_provisioning_config + execute_provisioning instead
provision_dataset() {
    error "provision_dataset: This function is deprecated"
    return 1
}

# Provision iSCSI resources (portal and target)
# Parameters: host, api_key, storage_name
# Returns: 0 on success, 1 on failure
# Sets: PROVISIONED_TARGET_IQN, PROVISIONED_PORTAL_IP, PROVISIONED_PORTAL_PORT, PROVISIONED_PORTAL_ID
provision_iscsi() {
    local host="$1"
    local api_key="$2"
    local storage_name="$3"

    echo
    print_header "iSCSI Configuration"

    # Query existing portals
    info "Fetching existing iSCSI portals..."
    local portals_json
    portals_json=$(tn_query_portals "$host" "$api_key" 2>&1)

    local -a portal_ids=()
    local -a portal_displays=()

    # Parse portals - extract id and listen info
    if [[ -n "$portals_json" ]] && [[ "$portals_json" != "[]" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ \"id\":\ *([0-9]+) ]]; then
                local portal_id="${BASH_REMATCH[1]}"
                # Try to extract IP from the same portal block
                local portal_ip
                portal_ip=$(echo "$portals_json" | grep -oP "\"id\":\s*${portal_id}[^}]*\"ip\":\s*\"\K[^\"]+")
                portal_ids+=("$portal_id")
                portal_displays+=("Portal #$portal_id - $portal_ip:3260")
            fi
        done < <(echo "$portals_json" | grep -oP '"id":\s*[0-9]+')
    fi

    local portal_id
    local portal_ip
    local portal_port="3260"

    if [[ ${#portal_ids[@]} -gt 0 ]]; then
        echo
        info "Existing iSCSI portals:"
        local idx=1
        for display in "${portal_displays[@]}"; do
            echo "  $idx) $display"
            ((idx++))
        done
        echo "  $idx) Create new portal"
        echo "  0) Cancel"
        echo

        local portal_choice
        while true; do
            read -rp "Select portal [0-$idx]: " portal_choice
            if [[ "$portal_choice" == "0" ]]; then
                return 1
            elif [[ "$portal_choice" =~ ^[0-9]+$ ]] && [[ "$portal_choice" -ge 1 ]] && [[ "$portal_choice" -lt "$idx" ]]; then
                portal_id="${portal_ids[$((portal_choice-1))]}"
                # Extract IP from display
                portal_ip=$(echo "${portal_displays[$((portal_choice-1))]}" | grep -oP '\d+\.\d+\.\d+\.\d+')
                info "Using existing portal: $portal_ip:$portal_port (ID: $portal_id)"
                break
            elif [[ "$portal_choice" == "$idx" ]]; then
                # Create new portal
                portal_id=""
                break
            else
                error "Invalid selection"
            fi
        done
    fi

    # Create new portal if needed
    if [[ -z "$portal_id" ]]; then
        echo
        read -rp "Portal listen IP address (e.g., $host): " portal_ip
        portal_ip="${portal_ip:-$host}"

        if ! validate_ip "$portal_ip"; then
            error "Invalid IP address"
            return 1
        fi

        # Port is auto-assigned by TrueNAS (default 3260)
        portal_port="3260"

        info "Creating iSCSI portal: $portal_ip:$portal_port"
        local portal_result
        portal_result=$(tn_create_portal "$host" "$api_key" "$portal_ip" "$portal_port" 2>&1)
        local portal_exit=$?

        if [[ $portal_exit -ne 0 ]]; then
            error "Failed to create portal: $portal_result"
            return 1
        fi

        portal_id=$(echo "$portal_result" | grep -oP '"id":\s*\K[0-9]+')
        if [[ -z "$portal_id" ]]; then
            error "Failed to get portal ID from response"
            return 1
        fi

        register_resource "portal" "$portal_id"
        success "Portal created (ID: $portal_id)"
    fi

    # Target IQN
    echo
    local target_iqn
    local auto_iqn
    auto_iqn=$(generate_iqn "$storage_name")

    info "iSCSI Target Configuration"
    echo "  1) Generate IQN automatically: $auto_iqn"
    echo "  2) Enter custom IQN"
    echo

    local iqn_choice
    read -rp "Select option [1-2] [1]: " iqn_choice
    iqn_choice="${iqn_choice:-1}"

    case "$iqn_choice" in
        1)
            target_iqn="$auto_iqn"
            ;;
        2)
            read -rp "Enter target IQN: " target_iqn
            if [[ -z "$target_iqn" ]]; then
                error "IQN cannot be empty"
                return 1
            fi
            ;;
        *)
            target_iqn="$auto_iqn"
            ;;
    esac

    # Check if target exists
    if tn_check_target "$host" "$api_key" "$target_iqn" >/dev/null 2>&1; then
        echo
        warning "Target '$target_iqn' already exists"
        echo "  1) Use existing target"
        echo "  2) Enter a different IQN"
        echo "  0) Cancel"

        local exist_choice
        while true; do
            read -rp "Select option [0-2]: " exist_choice
            case "$exist_choice" in
                0)
                    return 1
                    ;;
                1)
                    info "Using existing target: $target_iqn"
                    PROVISIONED_TARGET_IQN="$target_iqn"
                    PROVISIONED_PORTAL_IP="$portal_ip"
                    PROVISIONED_PORTAL_PORT="$portal_port"
                    PROVISIONED_PORTAL_ID="$portal_id"
                    return 0
                    ;;
                2)
                    read -rp "Enter new target IQN: " target_iqn
                    if [[ -z "$target_iqn" ]]; then
                        error "IQN cannot be empty"
                        return 1
                    fi
                    ;;
                *)
                    error "Invalid choice"
                    ;;
            esac
        done
    fi

    # Create target with portal association
    info "Creating iSCSI target: $target_iqn"
    local target_result
    target_result=$(tn_create_target "$host" "$api_key" "$target_iqn" "$portal_ip" "$portal_port" 2>&1)
    local target_exit=$?

    if [[ $target_exit -ne 0 ]]; then
        error "Failed to create target: $target_result"
        return 1
    fi

    local target_id
    target_id=$(echo "$target_result" | grep -oP '"id":\s*\K[0-9]+')
    if [[ -n "$target_id" ]]; then
        register_resource "target" "$target_id"
    fi

    success "Target created: $target_iqn"

    PROVISIONED_TARGET_IQN="$target_iqn"
    PROVISIONED_PORTAL_IP="$portal_ip"
    PROVISIONED_PORTAL_PORT="$portal_port"
    PROVISIONED_PORTAL_ID="$portal_id"

    return 0
}

# Provision NVMe/TCP resources (subsystem)
# Parameters: host, api_key, storage_name
# Returns: 0 on success, 1 on failure
# Sets: PROVISIONED_SUBSYSTEM_NQN, PROVISIONED_PORTAL_IP, PROVISIONED_PORTAL_PORT
provision_nvme() {
    local host="$1"
    local api_key="$2"
    local storage_name="$3"

    echo
    print_header "NVMe/TCP Configuration"

    # Subsystem NQN
    local subsystem_nqn
    local auto_nqn
    auto_nqn=$(generate_nqn "$storage_name")

    info "NVMe Subsystem Configuration"
    echo "  1) Generate NQN automatically: $auto_nqn"
    echo "  2) Enter custom NQN"
    echo

    local nqn_choice
    read -rp "Select option [1-2] [1]: " nqn_choice
    nqn_choice="${nqn_choice:-1}"

    case "$nqn_choice" in
        1)
            subsystem_nqn="$auto_nqn"
            ;;
        2)
            while true; do
                read -rp "Enter subsystem NQN: " subsystem_nqn
                if [[ -z "$subsystem_nqn" ]]; then
                    error "NQN cannot be empty"
                    continue
                fi
                if ! validate_nqn "$subsystem_nqn"; then
                    error "Invalid NQN format. Must start with nqn.YYYY-MM."
                    continue
                fi
                break
            done
            ;;
        *)
            subsystem_nqn="$auto_nqn"
            ;;
    esac

    # Check if subsystem exists
    if tn_check_subsystem "$host" "$api_key" "$subsystem_nqn" >/dev/null 2>&1; then
        echo
        warning "Subsystem '$subsystem_nqn' already exists"
        echo "  1) Use existing subsystem"
        echo "  2) Enter a different NQN"
        echo "  0) Cancel"

        local exist_choice
        while true; do
            read -rp "Select option [0-2]: " exist_choice
            case "$exist_choice" in
                0)
                    return 1
                    ;;
                1)
                    info "Using existing subsystem: $subsystem_nqn"
                    # Get portal info
                    read -rp "Portal IP address [$host]: " portal_ip
                    portal_ip="${portal_ip:-$host}"
                    read -rp "Portal port [4420]: " portal_port
                    portal_port="${portal_port:-4420}"

                    PROVISIONED_SUBSYSTEM_NQN="$subsystem_nqn"
                    PROVISIONED_PORTAL_IP="$portal_ip"
                    PROVISIONED_PORTAL_PORT="$portal_port"
                    return 0
                    ;;
                2)
                    while true; do
                        read -rp "Enter new subsystem NQN: " subsystem_nqn
                        if [[ -z "$subsystem_nqn" ]]; then
                            error "NQN cannot be empty"
                            continue
                        fi
                        if validate_nqn "$subsystem_nqn"; then
                            break
                        fi
                        error "Invalid NQN format"
                    done
                    ;;
                *)
                    error "Invalid choice"
                    ;;
            esac
        done
    fi

    # Get portal configuration
    echo
    local portal_ip
    local portal_port
    read -rp "Portal IP address for NVMe/TCP [$host]: " portal_ip
    portal_ip="${portal_ip:-$host}"

    if ! validate_ip "$portal_ip"; then
        error "Invalid IP address"
        return 1
    fi

    read -rp "Portal port [4420]: " portal_port
    portal_port="${portal_port:-4420}"

    # Create subsystem
    local subsystem_name="${storage_name}"
    info "Creating NVMe subsystem: $subsystem_nqn"

    local subsys_result
    subsys_result=$(tn_create_subsystem "$host" "$api_key" "$subsystem_name" "$subsystem_nqn" 2>&1)
    local subsys_exit=$?

    if [[ $subsys_exit -ne 0 ]]; then
        error "Failed to create subsystem: $subsys_result"
        return 1
    fi

    local subsystem_id
    subsystem_id=$(echo "$subsys_result" | grep -oP '"id":\s*\K[0-9]+')
    if [[ -z "$subsystem_id" ]]; then
        error "Failed to get subsystem ID from response"
        return 1
    fi

    register_resource "subsystem" "$subsystem_id"
    success "Subsystem created (ID: $subsystem_id)"

    # Create port for subsystem
    info "Creating NVMe port: $portal_ip:$portal_port"
    local port_result
    port_result=$(tn_create_nvme_port "$host" "$api_key" "$subsystem_id" "$portal_ip" "$portal_port" 2>&1)
    local port_exit=$?

    if [[ $port_exit -ne 0 ]]; then
        warning "Failed to create NVMe port: $port_result"
        warning "Port may need to be configured manually in TrueNAS"
        # Don't fail - subsystem was created successfully
    else
        success "NVMe port created"
    fi

    PROVISIONED_SUBSYSTEM_NQN="$subsystem_nqn"
    PROVISIONED_PORTAL_IP="$portal_ip"
    PROVISIONED_PORTAL_PORT="$portal_port"

    return 0
}

# Main provisioning orchestrator - new workflow
# Parameters: storage_name, host, api_key, transport_mode
# Returns: 0 on success, 1 on failure
# Uses three-phase approach: collect -> summary -> execute
provision_storage_resources() {
    local storage_name="$1"
    local host="$2"
    local api_key="$3"
    local transport_mode="$4"

    # Phase 1: Collect all configuration
    if ! collect_provisioning_config "$host" "$api_key" "$storage_name" "$transport_mode"; then
        return 1
    fi

    # Phase 2: Show summary and get confirmation
    if ! show_provisioning_summary "$storage_name" "$transport_mode"; then
        return 1
    fi

    # Phase 3: Execute provisioning with progress display
    if ! execute_provisioning "$host" "$api_key" "$storage_name" "$transport_mode"; then
        return 1
    fi

    return 0
}

# Handle provisioning errors with retry/skip/abort options
# Parameters: host, api_key
handle_provisioning_error() {
    local host="$1"
    local api_key="$2"

    echo
    error "Provisioning encountered an error"
    echo
    echo "  1) Retry the failed step"
    echo "  2) Rollback created resources and abort"
    echo "  3) Abort without rollback (keep partial resources)"
    echo

    local choice
    read -rp "Select option [1-3]: " choice
    case "$choice" in
        1)
            info "Retry not yet implemented for this step"
            return 1
            ;;
        2)
            rollback_provisioning "$host" "$api_key"
            return 1
            ;;
        3)
            warning "Aborting without rollback"
            warning "Partial resources may exist on TrueNAS"
            clear_rollback_state
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Backup storage.cfg
# Outputs: backup file path to stdout on success
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
        error "Failed to create storage.cfg backup" >&2
        return 1
    }

    log "INFO" "Storage config backed up: $backup_file"
    echo "$backup_file"  # Output path to stdout for capture
    return 0
}

# Generate storage configuration block
generate_storage_config() {
    local name="$1"
    local ip="$2"
    local apikey="$3"
    local dataset="$4"
    local target_or_nqn="$5"  # target_iqn for iSCSI, subsystem_nqn for NVMe
    local portal="${6:-}"
    local blocksize="${7:-16K}"
    local sparse="${8:-1}"
    local use_multipath="${9:-}"
    local portals="${10:-}"
    local transport_mode="${11:-iscsi}"  # Default to iscsi for backward compatibility
    local hostnqn="${12:-}"

    cat <<EOF
truenasplugin: ${name}
	api_host ${ip}
	api_key ${apikey}
	dataset ${dataset}
EOF

    # Add transport mode if not default iSCSI
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo "	transport_mode nvme-tcp"
        echo "	subsystem_nqn ${target_or_nqn}"
    else
        echo "	target_iqn ${target_or_nqn}"
    fi

    echo "	api_insecure 1"
    echo "	shared 1"

    if [[ -n "$portal" ]]; then
        echo "	discovery_portal ${portal}"
    fi

    if [[ -n "$blocksize" ]]; then
        echo "	zvol_blocksize ${blocksize}"
    fi

    if [[ -n "$sparse" ]]; then
        echo "	tn_sparse ${sparse}"
    fi

    # Only add use_multipath for iSCSI (NVMe uses native multipath)
    if [[ -n "$use_multipath" ]] && [[ "$transport_mode" == "iscsi" ]]; then
        echo "	use_multipath ${use_multipath}"
    fi

    if [[ -n "$portals" ]]; then
        echo "	portals ${portals}"
    fi

    # Add hostnqn for NVMe if provided
    if [[ -n "$hostnqn" ]] && [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo "	hostnqn ${hostnqn}"
    fi

    # Always add content type
    echo "	content images"
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

# Update existing storage configuration in storage.cfg
update_storage_config() {
    local storage_name="$1"
    local new_config="$2"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        error "Storage configuration file not found: $STORAGE_CFG"
        return 1
    fi

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    # Create temporary file
    local temp_file="${STORAGE_CFG}.tmp.$$"

    # Remove old storage block and write everything except that storage
    awk -v storage="truenasplugin: ${storage_name}" '
        $0 ~ "^" storage "$" { skip=1; next }
        /^[a-z].*:/ { skip=0 }
        !skip { print }
    ' "$STORAGE_CFG" > "$temp_file"

    # Append new configuration
    echo "" >> "$temp_file"
    echo "$new_config" >> "$temp_file"

    # Replace original file
    if mv "$temp_file" "$STORAGE_CFG"; then
        success "Storage configuration updated in $STORAGE_CFG"
        log "INFO" "Storage '$storage_name' configuration updated"
        return 0
    else
        error "Failed to update storage configuration"
        rm -f "$temp_file"
        return 1
    fi
}

# Edit existing storage configuration
menu_edit_storage() {
    local storage_name="$1"

    print_header "Edit Storage Configuration: $storage_name"

    info "Loading existing configuration for '$storage_name'..."
    echo

    # Load all existing configuration values
    declare -A config_values
    while IFS='=' read -r key value; do
        config_values["$key"]="$value"
    done < <(get_all_storage_config_values "$storage_name")

    # Display immutable fields (read-only)
    info "Current Configuration (read-only fields):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Transport mode (immutable)
    local transport_mode="${config_values[transport_mode]:-iscsi}"
    echo "  Transport mode:     $transport_mode ${c3}(cannot be changed)${c0}"

    # Dataset (immutable - changing would orphan volumes)
    local dataset="${config_values[dataset]}"
    echo "  Dataset:            $dataset ${c3}(cannot be changed)${c0}"

    # Block size (immutable - cannot change after volumes created)
    local blocksize="${config_values[zvol_blocksize]:-16K}"
    echo "  Block size:         $blocksize ${c3}(cannot be changed)${c0}"

    # Transport-specific immutable fields
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        local subsystem_nqn="${config_values[subsystem_nqn]}"
        echo "  Subsystem NQN:      $subsystem_nqn ${c3}(cannot be changed)${c0}"
    else
        local target_iqn="${config_values[target_iqn]}"
        echo "  Target IQN:         $target_iqn ${c3}(cannot be changed)${c0}"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    warning "Note: Fields marked as 'cannot be changed' are immutable to prevent orphaning existing volumes"
    echo

    # Prompt for mutable fields with current values as defaults
    info "Editable Configuration:"
    echo

    # TrueNAS API settings
    local current_api_host="${config_values[api_host]}"
    local truenas_ip
    read -rp "TrueNAS IP address [$current_api_host]: " truenas_ip
    truenas_ip="${truenas_ip:-$current_api_host}"

    if [[ -z "$truenas_ip" ]]; then
        error "TrueNAS IP address cannot be empty"
        return 1
    fi

    if ! validate_ip "$truenas_ip"; then
        error "Invalid IP address format"
        return 1
    fi

    # API Key
    local current_api_key="${config_values[api_key]}"
    info "Current API key: ${current_api_key:0:20}... (hidden)"
    local api_key
    read -rp "New TrueNAS API key (press Enter to keep current): " api_key
    api_key="${api_key:-$current_api_key}"

    if [[ -z "$api_key" ]]; then
        error "API key cannot be empty"
        return 1
    fi

    # Test connectivity
    if ! test_truenas_api "$truenas_ip" "$api_key"; then
        error "Failed to connect to TrueNAS. Please check IP and API key."
        read -rp "Continue anyway? [y/N]: " choice
        [[ "$choice" =~ ^[Yy] ]] || return 1
    fi

    # Portal configuration
    local current_portal="${config_values[discovery_portal]}"
    local default_port
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        default_port="4420"
    else
        default_port="3260"
    fi

    local portal
    read -rp "Portal IP:port [$current_portal]: " portal
    portal="${portal:-$current_portal}"

    if [[ -z "$portal" ]]; then
        portal="${truenas_ip}:${default_port}"
    elif [[ ! "$portal" =~ : ]]; then
        portal="${portal}:${default_port}"
    fi

    # Sparse volumes
    local current_sparse="${config_values[tn_sparse]:-1}"
    local sparse
    read -rp "Enable sparse volumes? (0/1) [$current_sparse]: " sparse
    sparse="${sparse:-$current_sparse}"

    # Multipath configuration
    echo
    info "Multipath Configuration:"
    local current_use_multipath="${config_values[use_multipath]:-0}"
    local current_portals="${config_values[portals]:-}"

    if [[ "$transport_mode" == "iscsi" ]]; then
        echo "  Current multipath setting: $current_use_multipath"
        if [[ -n "$current_portals" ]]; then
            echo "  Current portals: $current_portals"
        fi
        echo

        local use_multipath
        read -rp "Enable multipath I/O? (0/1) [$current_use_multipath]: " use_multipath
        use_multipath="${use_multipath:-$current_use_multipath}"

        local portals="$current_portals"
        if [[ "$use_multipath" == "1" ]]; then
            read -rp "Additional portals (comma-separated IP:port) [$current_portals]: " portals
            portals="${portals:-$current_portals}"
        else
            portals=""
        fi
    else
        # NVMe/TCP - only portals matter
        echo "  Current portals: ${current_portals:-none}"
        echo
        local portals
        read -rp "Portals for native multipath (comma-separated IP:port) [$current_portals]: " portals
        portals="${portals:-$current_portals}"
        use_multipath=""  # Not used for NVMe
    fi

    # Host NQN for NVMe (optional, can be changed)
    local hostnqn="${config_values[hostnqn]:-}"
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo
        info "Current host NQN: ${hostnqn:-system default}"
        read -rp "Update host NQN? [y/N]: " update_hostnqn
        if [[ "$update_hostnqn" =~ ^[Yy] ]]; then
            read -rp "New host NQN: " hostnqn
        fi
    fi

    # Generate updated configuration
    echo
    info "Updated Configuration Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local config
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        local subsystem_nqn="${config_values[subsystem_nqn]}"
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$subsystem_nqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "$hostnqn")
    else
        local target_iqn="${config_values[target_iqn]}"
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target_iqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "")
    fi
    echo "$config"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    read -rp "Apply these changes to $STORAGE_CFG? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        warning "Configuration changes cancelled"
        return 1
    fi

    # Update configuration (remove old, add new)
    if update_storage_config "$storage_name" "$config"; then
        echo
        success "Storage configuration updated successfully!"
        info "Storage '$storage_name' has been reconfigured"
        echo
        info "Next steps:"
        echo "  1. Restart pvedaemon and pveproxy if needed"
        echo "  2. Check storage status: pvesm status"
        echo "  3. Verify connectivity with existing volumes"
        echo
        read -rp "Press Enter to continue..."
    else
        error "Failed to update configuration"
        return 1
    fi

    return 0
}

# ============================================================================
# PROGRESSIVE WIZARD FOR STORAGE CONFIGURATION
# ============================================================================

# Global wizard state variables
WIZARD_CONFIG_MODE=""        # "create" or "existing"
WIZARD_STORAGE_NAME=""
WIZARD_TRUENAS_IP=""
WIZARD_API_KEY=""
WIZARD_API_VALIDATED=""      # "true" if API connectivity confirmed
WIZARD_TRANSPORT_MODE=""     # "iscsi" or "nvme-tcp"
WIZARD_POOL=""               # ZFS pool name
WIZARD_DATASET=""            # Dataset name (without pool prefix)
WIZARD_DATASET_PATH=""       # Full dataset path (pool/dataset)
WIZARD_DATASET_EXISTS=""     # "true" if dataset already exists
WIZARD_TARGET=""             # IQN or NQN
WIZARD_TARGET_EXISTS=""      # "true" if target/subsystem already exists
WIZARD_PORTAL_IP=""          # Portal IP address
WIZARD_PORTAL_PORT=""        # Portal port
WIZARD_PORTAL_IPS=()         # Array of portal IPs for multipath
WIZARD_USE_MULTIPATH=""      # "1" if multipath enabled
WIZARD_BLOCKSIZE=""          # Block size (e.g., 16K)
WIZARD_SPARSE=""             # Sparse volume (0 or 1)
WIZARD_HOSTNQN=""            # Host NQN for NVMe/TCP

# Display wizard progress summary with validated inputs
# Shows checkmarks for validated items
show_wizard_summary() {
    local current_step="$1"

    info "Configuration Progress:"

    # Configuration Mode
    if [[ -n "$WIZARD_CONFIG_MODE" ]]; then
        if [[ "$WIZARD_CONFIG_MODE" == "create" ]]; then
            echo -e "  ${c2}✓${c0} Configuration Mode:  Automated Provisioning"
        else
            echo -e "  ${c2}✓${c0} Configuration Mode:  Manual Configuration"
        fi
    elif [[ "$current_step" == "mode" ]]; then
        echo -e "  ${c6}▸${c0} Configuration Mode:  ${c6}(selecting...)${c0}"
    else
        echo -e "    Configuration Mode:  ${c6}(pending)${c0}"
    fi

    # Storage Name
    if [[ -n "$WIZARD_STORAGE_NAME" ]]; then
        echo -e "  ${c2}✓${c0} Storage Name:        $WIZARD_STORAGE_NAME"
    elif [[ "$current_step" == "name" ]]; then
        echo -e "  ${c6}▸${c0} Storage Name:        ${c6}(entering...)${c0}"
    elif [[ -n "$WIZARD_CONFIG_MODE" ]]; then
        echo -e "    Storage Name:        ${c6}(pending)${c0}"
    fi

    # TrueNAS IP
    if [[ -n "$WIZARD_TRUENAS_IP" ]]; then
        echo -e "  ${c2}✓${c0} TrueNAS IP:          $WIZARD_TRUENAS_IP"
    elif [[ "$current_step" == "ip" ]]; then
        echo -e "  ${c6}▸${c0} TrueNAS IP:          ${c6}(entering...)${c0}"
    elif [[ -n "$WIZARD_STORAGE_NAME" ]]; then
        echo -e "    TrueNAS IP:          ${c6}(pending)${c0}"
    fi

    # API Key
    if [[ "$WIZARD_API_VALIDATED" == "true" ]]; then
        echo -e "  ${c2}✓${c0} API Key:             ****${WIZARD_API_KEY: -4} ${c2}(connected)${c0}"
    elif [[ -n "$WIZARD_API_KEY" ]]; then
        echo -e "  ${c3}?${c0} API Key:             ****${WIZARD_API_KEY: -4} ${c3}(unverified)${c0}"
    elif [[ "$current_step" == "apikey" ]]; then
        echo -e "  ${c6}▸${c0} API Key:             ${c6}(entering...)${c0}"
    elif [[ -n "$WIZARD_TRUENAS_IP" ]]; then
        echo -e "    API Key:             ${c6}(pending)${c0}"
    fi

    # Transport Mode (only for automated provisioning)
    if [[ "$WIZARD_CONFIG_MODE" == "create" ]]; then
        if [[ -n "$WIZARD_TRANSPORT_MODE" ]]; then
            if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
                echo -e "  ${c2}✓${c0} Transport Mode:      NVMe/TCP"
            else
                echo -e "  ${c2}✓${c0} Transport Mode:      iSCSI"
            fi
        elif [[ "$current_step" == "transport" ]]; then
            echo -e "  ${c6}▸${c0} Transport Mode:      ${c6}(selecting...)${c0}"
        elif [[ "$WIZARD_API_VALIDATED" == "true" ]]; then
            echo -e "    Transport Mode:      ${c6}(pending)${c0}"
        fi

        # Pool (only shown after transport mode for automated)
        if [[ -n "$WIZARD_POOL" ]]; then
            echo -e "  ${c2}✓${c0} ZFS Pool:            $WIZARD_POOL"
        elif [[ "$current_step" == "pool" ]]; then
            echo -e "  ${c6}▸${c0} ZFS Pool:            ${c6}(selecting...)${c0}"
        elif [[ -n "$WIZARD_TRANSPORT_MODE" ]]; then
            echo -e "    ZFS Pool:            ${c6}(pending)${c0}"
        fi

        # Dataset
        if [[ -n "$WIZARD_DATASET_PATH" ]]; then
            local ds_status=""
            if [[ "$WIZARD_DATASET_EXISTS" == "true" ]]; then
                ds_status=" ${c3}(exists)${c0}"
            else
                ds_status=" ${c2}(new)${c0}"
            fi
            echo -e "  ${c2}✓${c0} Dataset:             $WIZARD_DATASET_PATH$ds_status"
        elif [[ "$current_step" == "dataset" ]]; then
            echo -e "  ${c6}▸${c0} Dataset:             ${c6}(entering...)${c0}"
        elif [[ -n "$WIZARD_POOL" ]]; then
            echo -e "    Dataset:             ${c6}(pending)${c0}"
        fi

        # Target/Subsystem
        if [[ -n "$WIZARD_TARGET" ]]; then
            local tgt_status=""
            if [[ "$WIZARD_TARGET_EXISTS" == "true" ]]; then
                tgt_status=" ${c3}(exists)${c0}"
            else
                tgt_status=" ${c2}(new)${c0}"
            fi
            if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
                echo -e "  ${c2}✓${c0} Subsystem NQN:       $WIZARD_TARGET$tgt_status"
            else
                echo -e "  ${c2}✓${c0} Target IQN:          $WIZARD_TARGET$tgt_status"
            fi
        elif [[ "$current_step" == "target" ]]; then
            if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
                echo -e "  ${c6}▸${c0} Subsystem NQN:       ${c6}(configuring...)${c0}"
            else
                echo -e "  ${c6}▸${c0} Target IQN:          ${c6}(configuring...)${c0}"
            fi
        elif [[ -n "$WIZARD_DATASET_PATH" ]]; then
            if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
                echo -e "    Subsystem NQN:       ${c6}(pending)${c0}"
            else
                echo -e "    Target IQN:          ${c6}(pending)${c0}"
            fi
        fi

        # Portal (iSCSI) / Discovery (NVMe/TCP)
        local portal_label="Portal"
        local portals_label="Portals"
        if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
            portal_label="Discovery"
            portals_label="Discovery"
        fi
        if [[ -n "$WIZARD_PORTAL_IP" ]]; then
            if [[ ${#WIZARD_PORTAL_IPS[@]} -gt 1 ]]; then
                echo -e "  ${c2}✓${c0} ${portals_label}:             ${WIZARD_PORTAL_IP}:${WIZARD_PORTAL_PORT} ${c2}(multipath: ${#WIZARD_PORTAL_IPS[@]})${c0}"
            else
                echo -e "  ${c2}✓${c0} ${portal_label}:              ${WIZARD_PORTAL_IP}:${WIZARD_PORTAL_PORT}"
            fi
        elif [[ "$current_step" == "portal" ]]; then
            echo -e "  ${c6}▸${c0} ${portal_label}:              ${c6}(configuring...)${c0}"
        elif [[ -n "$WIZARD_TARGET" ]]; then
            echo -e "    ${portal_label}:              ${c6}(pending)${c0}"
        fi

        # Block Size
        if [[ -n "$WIZARD_BLOCKSIZE" ]]; then
            echo -e "  ${c2}✓${c0} Block Size:          $WIZARD_BLOCKSIZE"
        elif [[ "$current_step" == "blocksize" ]]; then
            echo -e "  ${c6}▸${c0} Block Size:          ${c6}(configuring...)${c0}"
        elif [[ -n "$WIZARD_PORTAL_IP" ]]; then
            echo -e "    Block Size:          ${c6}(pending)${c0}"
        fi

        # Sparse Volumes
        if [[ -n "$WIZARD_SPARSE" ]]; then
            local sparse_display="Yes (thin)"
            [[ "$WIZARD_SPARSE" == "0" ]] && sparse_display="No (thick)"
            echo -e "  ${c2}✓${c0} Sparse Volumes:      $sparse_display"
        elif [[ "$current_step" == "sparse" ]]; then
            echo -e "  ${c6}▸${c0} Sparse Volumes:      ${c6}(configuring...)${c0}"
        elif [[ -n "$WIZARD_BLOCKSIZE" ]]; then
            echo -e "    Sparse Volumes:      ${c6}(pending)${c0}"
        fi

        # Host NQN (NVMe only)
        if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
            if [[ -n "$WIZARD_HOSTNQN" ]]; then
                # Truncate long NQN for display
                local nqn_display="$WIZARD_HOSTNQN"
                if [[ ${#nqn_display} -gt 40 ]]; then
                    nqn_display="${nqn_display:0:37}..."
                fi
                echo -e "  ${c2}✓${c0} Host NQN:            $nqn_display"
            elif [[ "$current_step" == "hostnqn" ]]; then
                echo -e "  ${c6}▸${c0} Host NQN:            ${c6}(configuring...)${c0}"
            elif [[ -n "$WIZARD_SPARSE" ]]; then
                echo -e "    Host NQN:            ${c6}(pending)${c0}"
            fi
        fi
    fi

    echo
}

# Reset wizard state
reset_wizard_state() {
    WIZARD_CONFIG_MODE=""
    WIZARD_STORAGE_NAME=""
    WIZARD_TRUENAS_IP=""
    WIZARD_API_KEY=""
    WIZARD_API_VALIDATED=""
    WIZARD_TRANSPORT_MODE=""
    WIZARD_POOL=""
    WIZARD_DATASET=""
    WIZARD_DATASET_PATH=""
    WIZARD_DATASET_EXISTS=""
    WIZARD_TARGET=""
    WIZARD_TARGET_EXISTS=""
    WIZARD_PORTAL_IP=""
    WIZARD_PORTAL_PORT=""
    WIZARD_PORTAL_IPS=()
    WIZARD_USE_MULTIPATH=""
    WIZARD_BLOCKSIZE=""
    WIZARD_SPARSE=""
    WIZARD_HOSTNQN=""
}

# Progressive wizard for adding new storage
# Returns: 0 on success (config collected), 1 on cancel/failure
wizard_add_storage() {
    reset_wizard_state

    local can_provision=false
    if [[ -f "$PLUGIN_FILE" ]]; then
        can_provision=true
    fi

    # --- Step 1: Configuration Mode ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "mode"

    if [[ "$can_provision" == "true" ]]; then
        info "How would you like to configure TrueNAS storage?"
        echo "  1) Create new storage on TrueNAS (automated provisioning)"
        echo "  2) Use existing storage (manual configuration)"
        echo "  0) Cancel"
        echo

        local mode_choice
        while true; do
            read -rp "Select option [0-2]: " mode_choice
            case "$mode_choice" in
                0) info "Configuration cancelled"; return 1 ;;
                1) WIZARD_CONFIG_MODE="create"; break ;;
                2) WIZARD_CONFIG_MODE="existing"; break ;;
                *) error "Invalid choice. Please enter 0, 1, or 2" ;;
            esac
        done
    else
        info "Plugin not installed - using manual configuration mode"
        WIZARD_CONFIG_MODE="existing"
        sleep 1
    fi

    # --- Step 2: Storage Name ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "name"

    info "Enter a unique name for this storage configuration:"
    while true; do
        read -rp "Storage name (e.g., truenas-main): " WIZARD_STORAGE_NAME
        if [[ -z "$WIZARD_STORAGE_NAME" ]]; then
            error "Storage name cannot be empty"
            continue
        fi
        if ! validate_storage_name "$WIZARD_STORAGE_NAME"; then
            error "Invalid storage name. Use only letters, numbers, hyphens, and underscores"
            continue
        fi
        if storage_name_exists "$WIZARD_STORAGE_NAME"; then
            error "Storage name '$WIZARD_STORAGE_NAME' already exists"
            WIZARD_STORAGE_NAME=""
            continue
        fi
        break
    done

    # --- Step 3: TrueNAS IP ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "ip"

    info "Enter the IP address of your TrueNAS server:"
    while true; do
        read -rp "TrueNAS IP address: " WIZARD_TRUENAS_IP
        if validate_ip "$WIZARD_TRUENAS_IP"; then
            break
        else
            error "Invalid IP address format"
            WIZARD_TRUENAS_IP=""
        fi
    done

    # --- Step 4: API Key ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "apikey"

    info "Enter your TrueNAS API key:"
    info "(Generate one in TrueNAS: Settings → API Keys → Add)"
    echo
    while true; do
        read -rp "API key: " WIZARD_API_KEY
        if [[ -z "$WIZARD_API_KEY" ]]; then
            error "API key cannot be empty"
            continue
        fi
        break
    done

    # Test API connectivity
    echo
    printf "  %-30s" "Testing API connectivity..."
    start_spinner
    local api_test_result
    api_test_result=$(test_truenas_api "$WIZARD_TRUENAS_IP" "$WIZARD_API_KEY" 2>&1)
    local api_test_code=$?
    stop_spinner

    if [[ $api_test_code -eq 0 ]]; then
        echo -e "\r  $(printf "%-30s" "Testing API connectivity...")${c2}OK${c0}"
        WIZARD_API_VALIDATED="true"
    else
        echo -e "\r  $(printf "%-30s" "Testing API connectivity...")${c1}FAILED${c0}"
        echo
        warning "Could not connect to TrueNAS API"
        read -rp "Continue anyway? [y/N]: " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
            return 1
        fi
        WIZARD_API_VALIDATED="false"
    fi

    # --- Step 5: Transport Mode (for automated provisioning) ---
    if [[ "$WIZARD_CONFIG_MODE" == "create" ]]; then
        clear_screen
        print_banner
        echo
        print_header "Storage Provisioning"
        show_wizard_summary "transport"

        info "Select transport protocol:"
        echo "  1) iSCSI (traditional, widely compatible)"
        echo "  2) NVMe/TCP (modern, lower latency)"
        echo

        local transport_choice
        while true; do
            read -rp "Transport mode [1-2]: " transport_choice
            case "$transport_choice" in
                1) WIZARD_TRANSPORT_MODE="iscsi"; break ;;
                2) WIZARD_TRANSPORT_MODE="nvme-tcp"; break ;;
                *) error "Invalid choice. Please enter 1 or 2" ;;
            esac
        done

        # Check nvme-cli for NVMe/TCP
        if [[ "$WIZARD_TRANSPORT_MODE" == "nvme-tcp" ]]; then
            if ! check_nvme_cli; then
                echo
                warning "nvme-cli package is not installed"
                info "NVMe/TCP requires nvme-cli for management"
                read -rp "Install nvme-cli now? [Y/n]: " install_nvme
                if [[ ! "$install_nvme" =~ ^[Nn] ]]; then
                    info "Installing nvme-cli..."
                    if apt-get update -qq && apt-get install -y -qq nvme-cli; then
                        success "nvme-cli installed successfully"
                    else
                        error "Failed to install nvme-cli"
                        return 1
                    fi
                fi
            fi
        fi
    fi

    # --- Final Summary ---
    clear_screen
    print_banner
    echo
    print_header "Storage Provisioning"
    show_wizard_summary "complete"

    return 0
}

# Configuration wizard
menu_configure_storage() {
    clear_screen
    print_banner
    print_header "Storage Configuration Wizard"

    # Check for existing storage entries
    local existing_storages
    existing_storages=$(list_truenas_storages 2>/dev/null || true)

    local storage_name=""

    if [[ -n "$existing_storages" ]]; then
        # Count existing storages
        local storage_count
        storage_count=$(echo "$existing_storages" | wc -l)

        # Present menu (don't show storage list yet)
        echo -e "  Found ${c6}$storage_count${c0} existing TrueNAS storage configuration(s)"
        echo
        info "What would you like to do?"
        echo "  1) Edit an existing storage"
        echo "  2) Add a new storage"
        echo "  3) Delete a storage"
        echo "  0) Cancel"
        echo

        local menu_choice
        while true; do
            read -rp "Select option [0-3]: " menu_choice
            if [[ "$menu_choice" =~ ^[0-3]$ ]]; then
                break
            else
                error "Invalid choice. Please enter 0, 1, 2, or 3"
            fi
        done

        case "$menu_choice" in
            0)
                info "Configuration cancelled"
                return 0
                ;;
            1)
                # Edit mode - NOW show the storage list
                echo
                info "Available storage configurations:"
                local idx=1
                local -a storage_array=()
                while IFS= read -r storage; do
                    echo "  $idx) $storage"
                    storage_array+=("$storage")
                    ((idx++))
                done <<< "$existing_storages"
                echo

                local storage_idx
                while true; do
                    read -rp "Select storage to edit [1-${#storage_array[@]}] or 0 to cancel: " storage_idx
                    if [[ "$storage_idx" == "0" ]]; then
                        info "Configuration cancelled"
                        return 0
                    elif [[ "$storage_idx" =~ ^[0-9]+$ ]] && [[ "$storage_idx" -ge 1 ]] && [[ "$storage_idx" -le "${#storage_array[@]}" ]]; then
                        storage_name="${storage_array[$((storage_idx-1))]}"
                        # Call edit function and return
                        menu_edit_storage "$storage_name"
                        return $?
                    else
                        error "Invalid selection. Please enter a number between 1 and ${#storage_array[@]}"
                    fi
                done
                ;;
            2)
                # Add new storage mode - use progressive wizard
                if ! wizard_add_storage; then
                    return 1
                fi
                # Continue with provisioning using wizard-collected values
                ;;
            3)
                # Delete mode - clear screen and show storage list
                clear_screen
                print_banner
                print_header "Delete Storage Configuration"

                info "Available storage configurations:"
                local idx=1
                local -a storage_array=()
                while IFS= read -r storage; do
                    echo "  $idx) $storage"
                    storage_array+=("$storage")
                    ((idx++))
                done <<< "$existing_storages"
                echo

                local storage_idx
                while true; do
                    read -rp "Select storage to delete [1-${#storage_array[@]}] or 0 to cancel: " storage_idx
                    if [[ "$storage_idx" == "0" ]]; then
                        info "Deletion cancelled"
                        read -rp "Press any key to return to main menu..." -n1 _
                        echo
                        return 0
                    elif [[ "$storage_idx" =~ ^[0-9]+$ ]] && [[ "$storage_idx" -ge 1 ]] && [[ "$storage_idx" -le "${#storage_array[@]}" ]]; then
                        storage_name="${storage_array[$((storage_idx-1))]}"
                        break
                    else
                        error "Invalid selection. Please enter a number between 1 and ${#storage_array[@]}"
                    fi
                done

                # Clear screen and show warning
                clear_screen
                print_banner
                print_header "Delete Storage Configuration"

                warning "WARNING: Deleting storage configuration '${c1}$storage_name${c0}'"
                warning "This will remove the storage from Proxmox configuration."
                warning "VMs using disks on this storage will lose access until reconfigured."
                echo

                local confirm
                echo -en "Type storage name '${c1}$storage_name${c0}' to confirm deletion: "
                read -r confirm
                if [[ "$confirm" != "$storage_name" ]]; then
                    warning "Confirmation failed. Deletion cancelled."
                    read -rp "Press any key to return to main menu..." -n1 _
                    echo
                    return 0
                fi

                # Read config values BEFORE deletion (config will be gone after)
                local transport_mode api_host api_key subsystem_nqn
                transport_mode=$(get_storage_config_value "$storage_name" "transport_mode" 2>/dev/null || echo "iscsi")
                api_host=$(get_storage_config_value "$storage_name" "api_host" 2>/dev/null)
                api_key=$(get_storage_config_value "$storage_name" "api_key" 2>/dev/null)
                subsystem_nqn=$(get_storage_config_value "$storage_name" "subsystem_nqn" 2>/dev/null)

                # Perform deletion
                echo
                printf "%-30s " "Removing from storage.cfg:"
                start_spinner
                local remove_result
                remove_result=$(remove_storage_config "$storage_name" 2>&1)
                local remove_exit=$?
                stop_spinner

                if [[ $remove_exit -eq 0 ]]; then
                    echo -e "\r$(printf "%-30s " "Removing from storage.cfg:")${c2}✓${c0} Removed"

                    # Verify removal from pvesm
                    printf "%-30s " "Verifying removal:"
                    start_spinner
                    sleep 1
                    local pvesm_check
                    pvesm_check=$(pvesm status 2>&1 | grep -E "^${storage_name}\s" || true)
                    stop_spinner

                    if [[ -z "$pvesm_check" ]]; then
                        echo -e "\r$(printf "%-30s " "Verifying removal:")${c2}✓${c0} Not in pvesm"
                    else
                        echo -e "\r$(printf "%-30s " "Verifying removal:")${c3}!${c0} May need service restart"
                    fi

                    echo
                    success "Storage '$storage_name' has been deleted"

                    # Offer to cleanup TrueNAS resources
                    if [[ -n "$api_host" && -n "$api_key" ]]; then
                        if [[ "$transport_mode" == "nvme-tcp" && -n "$subsystem_nqn" ]]; then
                            # NVMe/TCP: offer to delete the subsystem
                            echo
                            warning "The NVMe subsystem still exists on TrueNAS:"
                            echo "  Subsystem NQN: $subsystem_nqn"
                            echo
                            read -rp "Would you like to delete the NVMe subsystem on TrueNAS? [y/N]: " cleanup_response
                            if [[ "$cleanup_response" =~ ^[Yy] ]]; then
                                # Get subsystem ID by querying
                                printf "%-30s " "Looking up subsystem:"
                                start_spinner
                                local subsys_query subsys_id
                                subsys_query=$(tn_api_call "$api_host" "$api_key" "nvmet.subsys.query" '[[["subnqn", "=", "'"$subsystem_nqn"'"]]]' 2>&1)
                                subsys_id=$(echo "$subsys_query" | grep -oP '"id"\s*:\s*\K[0-9]+' | head -1)
                                stop_spinner

                                if [[ -n "$subsys_id" ]]; then
                                    echo -e "\r$(printf "%-30s " "Looking up subsystem:")${c2}✓${c0} Found (ID: $subsys_id)"

                                    printf "%-30s " "Deleting subsystem:"
                                    start_spinner
                                    local delete_result
                                    # Use force=true to handle port associations and any remaining namespaces
                                    delete_result=$(tn_api_call_write "$api_host" "$api_key" "nvmet.subsys.delete" "[$subsys_id, {\"force\": true}]" 2>&1)
                                    local delete_exit=$?
                                    stop_spinner

                                    if [[ $delete_exit -eq 0 ]]; then
                                        echo -e "\r$(printf "%-30s " "Deleting subsystem:")${c2}✓${c0} Deleted"
                                        success "NVMe subsystem deleted from TrueNAS"
                                    else
                                        echo -e "\r$(printf "%-30s " "Deleting subsystem:")${c1}✗${c0} Failed"
                                        error "Failed to delete subsystem: $delete_result"
                                        warning "The subsystem may have active namespaces. Use orphan cleanup to remove them first."
                                    fi
                                else
                                    echo -e "\r$(printf "%-30s " "Looking up subsystem:")${c3}!${c0} Not found"
                                    info "Subsystem may have already been deleted"
                                fi
                            fi
                        else
                            # iSCSI: Note about orphan cleanup
                            echo
                            info "Tip: Use Diagnostics > Cleanup orphaned resources to remove"
                            info "any remaining iSCSI extents, targets, or zvols on TrueNAS."
                        fi
                    fi
                else
                    echo -e "\r$(printf "%-30s " "Removing from storage.cfg:")${c1}✗${c0} Failed"
                    echo "  $remove_result"
                    error "Failed to delete storage configuration"
                fi

                read -rp "Press any key to return to main menu..." -n1 _
                echo
                return 0
                ;;
        esac
    fi

    # Continue with "Add New Storage" workflow
    # If wizard hasn't been run yet (no existing storages case), run it now
    if [[ -z "$WIZARD_CONFIG_MODE" ]]; then
        if ! wizard_add_storage; then
            return 1
        fi
    fi

    # Use wizard-collected values
    local storage_name="$WIZARD_STORAGE_NAME"
    local truenas_ip="$WIZARD_TRUENAS_IP"
    local api_key="$WIZARD_API_KEY"
    local provisioning_mode="$WIZARD_CONFIG_MODE"
    local transport_mode="$WIZARD_TRANSPORT_MODE"

    # Handle automated provisioning mode
    if [[ "$provisioning_mode" == "create" ]]; then
        # Run automated provisioning workflow
        if ! provision_storage_resources "$storage_name" "$truenas_ip" "$api_key" "$transport_mode"; then
            error "Automated provisioning failed"
            read -rp "Would you like to continue with manual configuration? [y/N]: " manual_choice
            if [[ ! "$manual_choice" =~ ^[Yy] ]]; then
                return 1
            fi
            # Fall through to manual workflow
            provisioning_mode="existing"
        else
            # Provisioning succeeded - use provisioned values and wizard settings
            local dataset="$PROVISIONED_DATASET"
            local target=""
            local subsystem_nqn=""
            local portal=""
            local hostnqn=""
            local blocksize="$PROV_BLOCKSIZE"
            local sparse="$PROV_SPARSE"
            local use_multipath="$PROV_USE_MULTIPATH"
            local portals="$PROV_ADDITIONAL_PORTALS"

            if [[ "$transport_mode" == "nvme-tcp" ]]; then
                subsystem_nqn="$PROVISIONED_SUBSYSTEM_NQN"
                portal="${PROVISIONED_PORTAL_IP}:${PROVISIONED_PORTAL_PORT}"
                hostnqn="$PROV_HOSTNQN"
            else
                target="$PROVISIONED_TARGET_IQN"
                portal="${PROVISIONED_PORTAL_IP}:${PROVISIONED_PORTAL_PORT}"
            fi

            # Generate configuration using wizard-collected values
            local config
            if [[ "$transport_mode" == "nvme-tcp" ]]; then
                config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$subsystem_nqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "$hostnqn")
            else
                config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "")
            fi

            # Show final configuration summary
            clear_screen
            print_banner
            print_header "Final Storage Configuration"

            echo "$config"
            echo "─────────────────────────────────────────────────────────"

            read -rp "Add this configuration to Proxmox? [Y/n]: " confirm
            if [[ "$confirm" =~ ^[Nn] ]]; then
                warning "Configuration cancelled"
                return 1
            fi

            # Clear screen and show finalization header
            clear_screen
            print_banner
            echo
            print_header "Finalizing Storage Configuration"

            local finalize_errors=0

            # Step 1: Backup storage.cfg
            printf "%-30s " "Configuration backup:"
            start_spinner
            local backup_path
            local backup_error
            backup_error=$(backup_storage_cfg 2>&1 1>/tmp/backup_path_$$)
            local backup_exit=$?
            backup_path=$(cat /tmp/backup_path_$$ 2>/dev/null)
            rm -f /tmp/backup_path_$$ 2>/dev/null
            stop_spinner
            if [[ $backup_exit -eq 0 ]] && [[ -n "$backup_path" ]]; then
                echo -e "\r$(printf "%-30s " "Configuration backup:")${c2}✓${c0} $backup_path"
            elif [[ $backup_exit -eq 0 ]]; then
                # No backup needed (no existing storage.cfg)
                echo -e "\r$(printf "%-30s " "Configuration backup:")${c2}✓${c0} Not needed"
            else
                echo -e "\r$(printf "%-30s " "Configuration backup:")${c1}✗${c0} Failed"
                echo "  $backup_error"
                ((finalize_errors++))
            fi

            # Step 2: Add storage configuration
            if [[ $finalize_errors -eq 0 ]]; then
                printf "%-30s " "Storage configuration:"
                start_spinner
                # Append configuration directly (backup already done)
                echo "" >> "$STORAGE_CFG" 2>/dev/null
                echo "$config" >> "$STORAGE_CFG" 2>/dev/null
                local config_exit=$?
                stop_spinner
                if [[ $config_exit -eq 0 ]]; then
                    echo -e "\r$(printf "%-30s " "Storage configuration:")${c2}✓${c0} Added to storage.cfg"
                    log "INFO" "Storage configuration added"
                else
                    echo -e "\r$(printf "%-30s " "Storage configuration:")${c1}✗${c0} Failed to write"
                    ((finalize_errors++))
                fi
            fi

            # Step 3: Validate storage with pvesm (retry for up to 10 seconds)
            if [[ $finalize_errors -eq 0 ]]; then
                printf "%-30s " "Storage validation:"
                start_spinner
                local pvesm_result=""
                local validation_timeout=10
                local validation_start=$SECONDS
                while [[ $((SECONDS - validation_start)) -lt $validation_timeout ]]; do
                    pvesm_result=$(pvesm status 2>&1 | grep -E "^${storage_name}\s" || true)
                    if [[ -n "$pvesm_result" ]]; then
                        break
                    fi
                    sleep 1
                done
                stop_spinner
                if [[ -n "$pvesm_result" ]]; then
                    echo -e "\r$(printf "%-30s " "Storage validation:")${c2}✓${c0} Valid"
                else
                    echo -e "\r$(printf "%-30s " "Storage validation:")${c3}!${c0} May need service restart"
                fi
            fi

            echo
            if [[ $finalize_errors -gt 0 ]]; then
                error "Storage configuration failed"
                return 1
            fi

            success "Storage '$storage_name' configured successfully!"

            read -rp "Press any key to return to main menu..." -n1 _
            echo
            return 0
        fi
    fi

    # Manual workflow continues here (when provisioning_mode="existing")

    # Dataset
    local dataset
    while true; do
        read -rp "ZFS dataset path (e.g., tank/proxmox): " dataset
        if [[ -z "$dataset" ]]; then
            error "Dataset cannot be empty"
            continue
        fi

        # Verify dataset if API connection worked
        if ! verify_dataset "$truenas_ip" "$api_key" "$dataset"; then
            echo
            warning "Dataset verification failed. The dataset may not exist or may not be accessible."
            read -rp "Continue anyway? [y/N]: " continue_choice
            if [[ "$continue_choice" =~ ^[Yy] ]]; then
                warning "Proceeding with unverified dataset '$dataset'"
                break
            else
                echo
                info "Please enter a different dataset name"
                continue
            fi
        fi
        break
    done

    # Transport mode selection
    echo
    info "Select transport protocol:"
    echo "  1) iSCSI (traditional, widely compatible)"
    echo "  2) NVMe/TCP (modern, lower latency)"
    read -rp "Transport mode (1-2) [1]: " transport_choice
    transport_choice=${transport_choice:-1}

    local transport_mode
    case "$transport_choice" in
        1) transport_mode="iscsi" ;;
        2) transport_mode="nvme-tcp" ;;
        *)
            error "Invalid choice, defaulting to iSCSI"
            transport_mode="iscsi"
            ;;
    esac

    # Transport-specific configuration
    local target=""
    local subsystem_nqn=""
    local hostnqn=""

    if [[ "$transport_mode" == "iscsi" ]]; then
        # iSCSI Target
        read -rp "iSCSI target (e.g., iqn.2025-01.com.truenas:target0): " target
        if [[ -z "$target" ]]; then
            error "iSCSI target cannot be empty"
            return 1
        fi
    else
        # NVMe/TCP configuration
        # Check nvme-cli
        if ! check_nvme_cli; then
            warning "nvme-cli package is not installed"
            info "NVMe/TCP requires nvme-cli for management"
            read -rp "Install nvme-cli now? [Y/n]: " install_nvme
            if [[ ! "$install_nvme" =~ ^[Nn] ]]; then
                info "Installing nvme-cli..."
                if ! apt-get update; then
                    error "Failed to update package lists (check network/repositories)"
                    return 1
                fi
                if ! apt-get install -y nvme-cli; then
                    error "Failed to install nvme-cli package"
                    return 1
                fi
                if ! check_nvme_cli; then
                    error "nvme-cli installed but 'nvme' command not found in PATH"
                    info "Try running: hash -r  # to refresh PATH"
                    return 1
                fi
                success "nvme-cli installed successfully"
            else
                warning "Proceeding without nvme-cli (some features may not work)"
            fi
        fi

        # Subsystem NQN
        while true; do
            read -rp "NVMe subsystem NQN (e.g., nqn.2005-10.org.freenas.ctl:proxmox): " subsystem_nqn
            if [[ -z "$subsystem_nqn" ]]; then
                error "Subsystem NQN cannot be empty"
                continue
            fi
            if ! validate_nqn "$subsystem_nqn"; then
                error "Invalid NQN format. Must start with nqn.YYYY-MM."
                continue
            fi
            break
        done

        # Host NQN
        hostnqn=$(get_hostnqn)
        if [[ -z "$hostnqn" ]]; then
            warning "No host NQN configured (plugin will use system default)"
        fi

        # Check native multipath
        echo
        check_nvme_multipath || true
    fi

    # Portal (optional) - set default port based on transport
    local portal
    local default_port
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        default_port="4420"
    else
        default_port="3260"
    fi

    while true; do
        read -rp "Portal IP (optional, press Enter to use TrueNAS IP): " portal
        if [[ -z "$portal" ]]; then
            portal="${truenas_ip}:${default_port}"
            break
        else
            # Extract IP part (may or may not have port)
            local portal_ip="${portal%%:*}"
            if ! validate_ip "$portal_ip"; then
                error "Invalid IP address format"
                continue
            fi
            if [[ ! "$portal" =~ : ]]; then
                # Add default port if not specified
                portal="${portal}:${default_port}"
            else
                # Validate port number
                local portal_port="${portal##*:}"
                if ! [[ "$portal_port" =~ ^[0-9]+$ ]] || [[ "$portal_port" -lt 1 ]] || [[ "$portal_port" -gt 65535 ]]; then
                    error "Invalid port number (must be 1-65535)"
                    continue
                fi
            fi
            break
        fi
    done

    # Blocksize configuration
    echo
    info "ZFS Block Size Configuration:"
    echo "  Recommended sizes based on workload:"
    echo "    4K  - Databases with small random I/O (PostgreSQL, MySQL)"
    echo "    8K  - General-purpose databases, mixed workloads"
    echo "    16K - Default, balanced for most VM workloads (Recommended)"
    echo "    32K - Large sequential I/O, media files"
    echo "    64K - Very large files, backup storage"
    echo "    128K - Maximum for large sequential workloads"
    echo
    local blocksize
    while true; do
        read -rp "Block size [16K]: " blocksize
        blocksize="${blocksize:-16K}"
        # Validate blocksize format (number followed by K or M)
        if [[ "$blocksize" =~ ^[0-9]+[KkMm]$ ]]; then
            # Normalize to uppercase
            blocksize="${blocksize^^}"
            # Extract numeric part
            local bs_num="${blocksize%[KM]}"
            local bs_unit="${blocksize: -1}"
            # Convert to bytes for validation
            local bs_bytes
            if [[ "$bs_unit" == "K" ]]; then
                bs_bytes=$((bs_num * 1024))
            else
                bs_bytes=$((bs_num * 1024 * 1024))
            fi
            # Valid range: 512 bytes to 1M (ZFS limit)
            if [[ "$bs_bytes" -ge 512 ]] && [[ "$bs_bytes" -le 1048576 ]]; then
                # Must be power of 2
                if (( (bs_bytes & (bs_bytes - 1)) == 0 )); then
                    break
                else
                    error "Block size must be a power of 2 (e.g., 4K, 8K, 16K, 32K, 64K, 128K)"
                fi
            else
                error "Block size must be between 512 bytes and 1M"
            fi
        else
            error "Invalid format. Use number followed by K or M (e.g., 16K, 128K, 1M)"
        fi
    done

    # Sparse volume configuration
    echo
    info "Sparse Volume Configuration:"
    echo "  Sparse volumes (thin provisioning) allocate space on-demand rather than"
    echo "  pre-allocating the full size. This saves storage space but may cause"
    echo "  slight fragmentation over time. Recommended for most use cases."
    echo
    local sparse
    while true; do
        read -rp "Enable sparse volumes? [Y/n]: " sparse_choice
        sparse_choice="${sparse_choice:-Y}"
        if [[ "$sparse_choice" =~ ^[Yy]$ ]]; then
            sparse="1"
            break
        elif [[ "$sparse_choice" =~ ^[Nn]$ ]]; then
            sparse="0"
            break
        else
            error "Please enter Y or N"
        fi
    done

    # Multipath configuration
    echo
    info "Advanced Options:"
    local use_multipath=""
    local portals=""
    read -rp "Enable multipath I/O for redundancy/load balancing? [y/N]: " enable_mp

    if [[ "$enable_mp" =~ ^[Yy] ]]; then
        if [[ "$transport_mode" == "iscsi" ]]; then
            # Check for multipath-tools package (iSCSI only)
            if ! command -v multipath &> /dev/null; then
                warning "multipath-tools package is not installed"
                info "Multipath requires: apt-get install multipath-tools"
                read -rp "Continue configuring multipath anyway? [y/N]: " continue_mp
                if [[ ! "$continue_mp" =~ ^[Yy] ]]; then
                    info "Multipath disabled"
                else
                    use_multipath="1"
                fi
            else
                use_multipath="1"
            fi
        else
            # NVMe/TCP uses native multipath
            info "NVMe/TCP uses native kernel multipath (no dm-multipath required)"
            use_multipath=""  # Don't set use_multipath flag for NVMe
        fi

        # If multipath is enabled (or for NVMe), discover and select additional portals
        if [[ "$use_multipath" == "1" ]] || [[ "$transport_mode" == "nvme-tcp" ]]; then
            echo
            info "Discovering available portals from TrueNAS..."
            local discovered_portals
            discovered_portals=$(discover_truenas_portals "$truenas_ip" "$api_key" "$truenas_ip")

            if [[ -n "$discovered_portals" ]]; then
                success "Found available portal IPs:"
                local portal_array=()
                local idx=1
                while IFS= read -r ip; do
                    echo "  $idx) $ip"
                    portal_array+=("$ip")
                    ((idx++))
                done <<< "$discovered_portals"

                echo
                info "Select additional portals for multipath (space-separated numbers, e.g., '1 2')"
                info "Note: Portals should be on different subnets for proper multipath operation"
                read -rp "Portal numbers (or press Enter to skip): " portal_choices

                if [[ -n "$portal_choices" ]]; then
                    local selected_portals=()
                    local invalid_choices=()
                    for choice in $portal_choices; do
                        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$idx" ]]; then
                            selected_portals+=("${portal_array[$((choice-1))]}:${default_port}")
                        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
                            invalid_choices+=("$choice")
                        fi
                    done

                    if [[ ${#invalid_choices[@]} -gt 0 ]]; then
                        warning "Invalid selections ignored: ${invalid_choices[*]}"
                    fi

                    if [[ ${#selected_portals[@]} -gt 0 ]]; then
                        portals=$(IFS=,; echo "${selected_portals[*]}")
                        success "Selected portals: $portals"
                    else
                        warning "No valid portals selected"
                    fi
                fi
            else
                warning "Could not discover portals automatically"
                info "You can enter portals manually"
            fi

            # Fallback to manual entry
            if [[ -z "$portals" ]]; then
                echo
                info "Enter additional portals manually (comma-separated IP:port)"
                if [[ "$transport_mode" == "nvme-tcp" ]]; then
                    info "Example: 192.168.10.101:4420,192.168.10.102:4420"
                else
                    info "Example: 192.168.10.101:3260,192.168.10.102:3260"
                fi
                read -rp "Additional portals (or press Enter to skip): " portals

                # Validate manual portal entry format
                if [[ -n "$portals" ]]; then
                    local portal_valid=true
                    IFS=',' read -ra portal_list <<< "$portals"
                    for p in "${portal_list[@]}"; do
                        if [[ ! "$p" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+$ ]]; then
                            warning "Invalid portal format: $p"
                            portal_valid=false
                        fi
                    done
                    if [[ "$portal_valid" == "false" ]]; then
                        warning "Clearing invalid portal entries"
                        portals=""
                    fi
                fi

                if [[ -z "$portals" ]]; then
                    if [[ "$transport_mode" == "iscsi" && "$use_multipath" == "1" ]]; then
                        warning "No additional portals configured - multipath will not function"
                        warning "You must configure multiple portals for multipath to work"
                    elif [[ "$transport_mode" == "nvme-tcp" ]]; then
                        info "Using single portal (you can add more later for native multipath redundancy)"
                    fi
                fi
            fi
        fi
    else
        use_multipath="0"
    fi

    # Generate configuration
    local config
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$subsystem_nqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "$hostnqn")
    else
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "")
    fi

    # Display summary with validation status
    echo
    echo "─────────────────────────────────────────────────────────"
    info "Configuration Summary"
    echo "─────────────────────────────────────────────────────────"
    echo
    # Storage name - validated for format
    printf "  ${c2}✓${c0} %-20s %s\n" "Storage Name:" "$storage_name"
    # TrueNAS IP - validated with validate_ip
    printf "  ${c2}✓${c0} %-20s %s\n" "TrueNAS IP:" "$truenas_ip"
    # API Key - show masked, validated via API test
    local masked_key="${api_key:0:8}...${api_key: -4}"
    printf "  ${c2}✓${c0} %-20s %s\n" "API Key:" "$masked_key"
    # Dataset - may or may not be verified
    printf "  ${c2}✓${c0} %-20s %s\n" "Dataset:" "$dataset"
    # Transport mode - validated via selection
    printf "  ${c2}✓${c0} %-20s %s\n" "Transport Mode:" "$transport_mode"
    # Target/Subsystem based on mode
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        printf "  ${c4}○${c0} %-20s %s\n" "Subsystem NQN:" "$subsystem_nqn"
        if [[ -n "$hostnqn" ]]; then
            printf "  ${c4}○${c0} %-20s %s\n" "Host NQN:" "$hostnqn"
        fi
    else
        printf "  ${c4}○${c0} %-20s %s\n" "Target IQN:" "$target"
    fi
    # Portal - validated for IP and port
    printf "  ${c2}✓${c0} %-20s %s\n" "Discovery Portal:" "$portal"
    # Block size - validated
    printf "  ${c2}✓${c0} %-20s %s\n" "Block Size:" "$blocksize"
    # Sparse - validated
    local sparse_display="Yes (thin provisioning)"
    [[ "$sparse" == "0" ]] && sparse_display="No (thick provisioning)"
    printf "  ${c2}✓${c0} %-20s %s\n" "Sparse Volumes:" "$sparse_display"
    # Multipath - display based on transport mode
    if [[ "$transport_mode" == "iscsi" ]]; then
        local mp_display="Disabled"
        [[ "$use_multipath" == "1" ]] && mp_display="Enabled"
        printf "  ${c2}✓${c0} %-20s %s\n" "Multipath:" "$mp_display"
    fi
    # Additional portals if configured
    if [[ -n "$portals" ]]; then
        printf "  ${c2}✓${c0} %-20s %s\n" "Additional Portals:" "$portals"
    fi
    echo
    echo "  ${c2}✓${c0} = Validated    ${c4}○${c0} = User provided (not validated)"
    echo
    echo "─────────────────────────────────────────────────────────"
    echo "Raw configuration to be added:"
    echo "─────────────────────────────────────────────────────────"
    echo "$config"
    echo "─────────────────────────────────────────────────────────"
    echo

    read -rp "Add this configuration to $STORAGE_CFG? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
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

        # Add multipath-specific next steps if enabled
        if [[ "$use_multipath" == "1" ]]; then
            echo "  4. Verify multipath configuration: multipath -ll"
            echo "  5. Check multipath service status: systemctl status multipathd"
            if ! command -v multipath &> /dev/null; then
                echo "  6. Install multipath-tools: apt-get install multipath-tools"
            fi
        fi
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
    backups=$(list_backups 2>/dev/null || true)

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
    read -rp "Continue with rollback? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Rollback cancelled"
        read -rp "Press Enter to continue..."
        return 0
    fi

    if restore_plugin_from_backup "$selected_backup"; then
        success "Rollback completed successfully"

        # Show cluster warning if applicable
        if is_cluster_node; then
            show_cluster_warning
        fi
    else
        error "Rollback failed"
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# BACKUP MANAGEMENT
# ============================================================================

# View all backups with detailed information
view_all_backups() {
    print_header "Backup Files"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        info "Backups are stored in: $BACKUP_DIR"
        return 1
    fi

    local stats
    stats=$(scan_backups)
    IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

    echo
    echo "Total: $count backup(s) - $(format_size "$total_size")"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "%-6s %-15s %-20s %-12s %s\n" "No." "Version" "Created" "Size" "Age"
    echo "─────────────────────────────────────────────────────────────────────────────"

    local index=1
    while IFS= read -r backup; do
        local filename
        filename=$(basename "$backup")

        # Extract version and timestamp
        local version_timestamp
        version_timestamp=$(echo "$filename" | sed 's/TrueNASPlugin\.pm\.backup\.//')
        local version
        version=$(echo "$version_timestamp" | sed 's/\.[0-9]*_[0-9]*$//')
        local timestamp
        timestamp=$(echo "$version_timestamp" | sed 's/.*\.\([0-9]*_[0-9]*\)$/\1/')

        # Format timestamp for display
        local display_time
        if [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
            display_time="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"
        else
            display_time="$timestamp"
        fi

        # Get file size
        local size
        size=$(stat -c %s "$backup" 2>/dev/null || stat -f %z "$backup" 2>/dev/null)

        # Get age
        local age
        age=$(backup_age_days "$backup")

        printf "%-6s %-15s %-20s %-12s %s\n" \
            "$index)" \
            "$version" \
            "$display_time" \
            "$(format_size "$size")" \
            "$(format_age "$age")"

        ((index++))
    done <<< "$backups"

    echo "─────────────────────────────────────────────────────────────────────────────"
    echo
}

# Delete old backups by age threshold
delete_old_backups() {
    print_header "Delete Old Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    echo
    read -rp "Delete backups older than how many days? (default: 30): " age_threshold
    age_threshold=${age_threshold:-30}

    # Validate input
    if ! [[ "$age_threshold" =~ ^[0-9]+$ ]]; then
        error "Invalid input. Please enter a number."
        return 1
    fi

    # Find backups older than threshold
    local old_backups=()
    while IFS= read -r backup; do
        local age
        age=$(backup_age_days "$backup")
        if [[ "$age" -gt "$age_threshold" ]]; then
            old_backups+=("$backup")
        fi
    done <<< "$backups"

    if [[ "${#old_backups[@]}" -eq 0 ]]; then
        info "No backups older than $age_threshold days found"
        return 0
    fi

    echo
    warning "Found ${#old_backups[@]} backup(s) older than $age_threshold days:"
    echo
    for backup in "${old_backups[@]}"; do
        local age
        age=$(backup_age_days "$backup")
        echo "  • $(basename "$backup") - $(format_age "$age")"
    done
    echo

    read -rp "Delete these backups? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Delete old backups
    local deleted=0
    local failed=0
    for backup in "${old_backups[@]}"; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted old backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted $deleted backup(s)"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Keep only latest N backups
keep_latest_backups() {
    print_header "Keep Latest N Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    local total_count
    total_count=$(echo "$backups" | wc -l)

    echo
    echo "Current backup count: $total_count"
    read -rp "How many backups would you like to keep? (default: 5): " keep_count
    keep_count=${keep_count:-5}

    # Validate input
    if ! [[ "$keep_count" =~ ^[0-9]+$ ]]; then
        error "Invalid input. Please enter a number."
        return 1
    fi

    if [[ "$keep_count" -ge "$total_count" ]]; then
        info "No backups need to be deleted (keeping $keep_count, have $total_count)"
        return 0
    fi

    local delete_count=$((total_count - keep_count))

    echo
    warning "This will delete $delete_count backup(s), keeping only the $keep_count most recent"
    read -rp "Continue? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Get backups to delete (oldest ones)
    local -a backups_to_delete
    mapfile -t backups_to_delete < <(echo "$backups" | tail -n "$delete_count")

    # Delete backups
    local deleted=0
    local failed=0
    for backup in "${backups_to_delete[@]}"; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted $deleted backup(s), kept $keep_count most recent"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Delete all backups with strong confirmation
delete_all_backups() {
    print_header "Delete All Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    local total_count
    total_count=$(echo "$backups" | wc -l)

    echo
    warning "This will permanently delete ALL $total_count backup(s)!"
    warning "This action cannot be undone!"
    echo
    echo "Type 'DELETE ALL' to confirm:"
    read -r confirm

    if [[ "$confirm" != "DELETE ALL" ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Delete all backups
    local deleted=0
    local failed=0
    while IFS= read -r backup; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done <<< "$backups"

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted all $deleted backup(s)"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Backup management submenu
menu_manage_backups() {
    while true; do
        print_header "Manage Backups"

        local stats
        stats=$(scan_backups)
        IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

        if [[ "$count" -eq 0 ]]; then
            warning "No backups found"
            info "Backups are stored in: $BACKUP_DIR"
            read -rp "Press Enter to return to main menu..."
            return 0
        fi

        # Show backup statistics
        echo
        echo "Backup Statistics:"
        echo "─────────────────────────────────────────────────────────"
        echo "  Total backups: $count"
        echo "  Total size: $(format_size "$total_size")"
        echo "  Oldest backup: $(format_age "$oldest_age")"
        echo "  Newest backup: $(format_age "$newest_age")"
        echo "─────────────────────────────────────────────────────────"
        echo

        show_menu "Backup Management" \
            "View all backups" \
            "Delete old backups (by age)" \
            "Keep only latest N backups" \
            "Delete all backups"

        local choice
        choice=$(read_choice 4)

        case $choice in
            0)
                return 0
                ;;
            1)
                view_all_backups
                read -rp "Press Enter to continue..."
                ;;
            2)
                delete_old_backups
                read -rp "Press Enter to continue..."
                ;;
            3)
                keep_latest_backups
                read -rp "Press Enter to continue..."
                ;;
            4)
                delete_all_backups
                read -rp "Press Enter to continue..."
                ;;
        esac
    done
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

    # Remove the storage block (truenasplugin: line and all indented lines after it)
    awk -v storage="truenasplugin: ${storage_name}" '
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

            read -rp "Remove all TrueNAS storage configurations? [y/N]: " confirm
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

    read -rp "Are you sure you want to uninstall? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Uninstallation cancelled"
        return 0
    fi

    echo
    read -rp "Also remove storage configuration from $STORAGE_CFG? [y/N]: " remove_config_choice

    local remove_config=false
    [[ "$remove_config_choice" =~ ^[Yy] ]] && remove_config=true

    if uninstall_plugin "$remove_config"; then
        success "Uninstallation complete"
    else
        error "Uninstallation failed"
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"

    # Detect if stdin is not a TTY (piped from curl/wget) and redirect to terminal
    if [[ ! -t 0 ]] && [[ "$NON_INTERACTIVE" != "true" ]]; then
        # Try to reconnect stdin to the controlling terminal
        if [[ -c /dev/tty ]] && ( : </dev/tty ) 2>/dev/null; then
            # Test if /dev/tty is actually connected to a terminal
            if [[ -t /dev/tty ]] 2>/dev/null || ( [[ -c /dev/tty ]] && tty -s </dev/tty 2>/dev/null ); then
                # Successfully can use /dev/tty for interactive input
                exec 0</dev/tty
                log "INFO" "Redirected stdin from pipe to /dev/tty for interactive mode"
            else
                # /dev/tty exists but is not usable for interactive input
                echo
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  TrueNAS Plugin Installer - Interactive Mode Not Available"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo
                echo "This installer was run in a non-interactive context (e.g., via SSH"
                echo "without a pseudo-terminal) and cannot access your terminal for prompts."
                echo
                echo "Please choose one of these methods instead:"
                echo
                echo "  ${COLOR_GREEN}1. SSH to Proxmox, then run installer (Recommended)${COLOR_RESET}"
                echo "     ssh root@your-proxmox-host"
                echo "     bash <(curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh)"
                echo
                echo "  ${COLOR_GREEN}2. Download and Run${COLOR_RESET}"
                echo "     wget https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh"
                echo "     chmod +x install.sh"
                echo "     ./install.sh"
                echo
                echo "  ${COLOR_YELLOW}3. Non-Interactive (For Automation)${COLOR_RESET}"
                echo "     curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash -s -- --non-interactive"
                echo
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo
                exit $EXIT_ERROR
            fi
        else
            # Cannot redirect - show helpful error
            echo
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  TrueNAS Plugin Installer - Interactive Mode Not Available"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo
            echo "This installer was piped from curl/wget but cannot access your"
            echo "terminal for interactive prompts."
            echo
            echo "Please choose one of these methods instead:"
            echo
            echo "  ${COLOR_GREEN}1. SSH to Proxmox, then run installer (Recommended)${COLOR_RESET}"
            echo "     ssh root@your-proxmox-host"
            echo "     bash <(curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh)"
            echo
            echo "  ${COLOR_GREEN}2. Download and Run${COLOR_RESET}"
            echo "     wget https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh"
            echo "     chmod +x install.sh"
            echo "     ./install.sh"
            echo
            echo "  ${COLOR_YELLOW}3. Non-Interactive (For Automation)${COLOR_RESET}"
            echo "     curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash -s -- --non-interactive"
            echo
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo
            exit $EXIT_ERROR
        fi
    fi

    # Initialize logging
    init_logging

    # Clean up any orphaned processes from previous runs
    # This prevents accumulation of zombie spinners
    pkill -f "bash.*install\.sh.*while" 2>/dev/null || true
    pkill -f "sleep 0\.1" 2>/dev/null || true

    # Perform checks (with banner for non-interactive mode only)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        print_banner
    fi

    info "Checking system requirements..."
    check_root
    check_dependencies
    success "System requirements satisfied"

    # Main menu loop - re-detect state after certain operations
    while true; do
        # Get current installation state
        local install_state
        install_state=$(get_install_state)

        if [[ "$install_state" == "not_installed" ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # Non-interactive mode: install latest version
                info "Non-interactive mode: Installing latest version..."
                perform_installation "latest"
                exit $?
            else
                # Interactive mode: show menu (menu will handle banner and screen clearing)
                menu_not_installed
            fi
        else
            # Plugin is installed
            local current_version="${install_state#installed:}"

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
                # Interactive mode: show menu (menu will handle banner and screen clearing)
                menu_installed "$current_version"
                # If menu returns, loop back to re-detect state
            fi
        fi
    done

    log "INFO" "Installer completed successfully"
}

# Run main function
main "$@"
