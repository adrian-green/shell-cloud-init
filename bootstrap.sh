#!/usr/bin/env bash
#
# bootstrap.sh - Cloud-Init Compatible Bootstrap System
#
# A cloud-init–compatible bootstrap system.
# Dry-run is the default. Real execution requires --execute.
# Expected YAML sections:
#   packages: [list]
#   users: [list of user definitions]
#   ssh_authorized_keys: [list]
#   write_files: [list of file definitions]
#   hostname: string
#   timezone: string
#   locale: string
#   bootcmd: [list]
#   runcmd: [list]
#   final_message: string
#
# Exit codes:
#   0 = success
#   1 = invalid usage
#   2 = missing or invalid config
#   3 = missing yq and unable to install
#   4 = bootstrap already completed (unless --force)
#   5 = validation error
#   6 = execution error
#
# Requirement: Bash 4+ is required to run this script.
# If your environment lacks bash (e.g., Alpine BusyBox images), install it:
#   - Alpine:   apk add --no-cache bash
#   - Debian/Ubuntu: apt-get update && apt-get install -y bash
#   - RHEL/CentOS/Fedora: dnf/yum install -y bash
#

# Global configuration
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Verify bash presence and version (fail fast)
check_bash_requirement() {
    # Ensure we are running under bash
    if [ -z "${BASH_VERSION:-}" ]; then
        echo "Error: This script must be run with bash. Try: bash $0 ..." >&2
        echo "If bash is missing, install it with your package manager (examples):" >&2
        echo "  Alpine: apk add --no-cache bash" >&2
        echo "  Debian/Ubuntu: apt-get update && apt-get install -y bash" >&2
        echo "  RHEL/CentOS/Fedora: dnf/yum install -y bash" >&2
        exit 1
    fi

    # Require Bash 4+
    bash_major="${BASH_VERSINFO[0]:-0}"
    if [ "$bash_major" -lt 4 ]; then
        echo "Error: Bash 4+ is required. Detected Bash ${BASH_VERSION}." >&2
        echo "Please upgrade bash (or run with a newer bash binary)." >&2
        exit 1
    fi
}

# Runtime variables
DEBUG_MODE="false"
LOG_LEVEL="INFO"
CONFIG_FILE=""
EXECUTE_MODE="false"
FORCE_MODE="false"
INSTALL_YQ="false"
BACKUP_MODE="true"
OVERRIDE_VALUES=""
STAMP_FILE="/var/lib/bootstrap.done"
LOG_FILE="/var/log/bootstrap.log"
BACKUP_DIR="/var/lib/bootstrap-backups"
YQ_BIN=""
JQ_BIN=""
PKG_INSTALL=""
PKG_UPDATE=""

# Logging levels: ERROR=1, WARN=2, INFO=3, DEBUG=4
declare -A LOG_LEVELS=([ERROR]=1 [WARN]=2 [INFO]=3 [DEBUG]=4)

# Enhanced error handling and logging
setup_error_handling() {
    set -euo pipefail
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    # Enhanced error trap
    trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
    trap 'cleanup_on_exit' EXIT
    
    # Debug trap (only when debug mode is enabled)
    if [[ "$DEBUG_MODE" == "true" ]]; then
        trap 'log_debug "Executing: ${BASH_COMMAND:-<none>}"' DEBUG
    fi
}

handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="$3"
    
    log_error "Command failed with exit code $exit_code at line $line_number: $command"
    
    # Attempt to provide context
    if [[ -n "${FUNCNAME[2]:-}" ]]; then
        log_error "Error occurred in function: ${FUNCNAME[2]}"
    fi
    
    cleanup_on_exit
    exit $exit_code
}

cleanup_on_exit() {
    # Clean up temporary files
    if [[ -n "${TMP_YQ:-}" && -f "$TMP_YQ" ]]; then
        rm -f "$TMP_YQ" 2>/dev/null || true
    fi
    
    # Disable traps to prevent recursion
    trap - ERR EXIT DEBUG
}

# Enhanced logging system
log_message() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_entry="[$timestamp] [$level] [$SCRIPT_NAME] $message"
    
    # Check if we should log this level
    local current_level_num=${LOG_LEVELS[$LOG_LEVEL]:-3}
    local message_level_num=${LOG_LEVELS[$level]:-3}
    
    if [[ $message_level_num -le $current_level_num ]]; then
        echo "$log_entry" | tee -a "$LOG_FILE" 2>/dev/null || echo "$log_entry"
    fi
    
    # Always show errors and warnings to stderr
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        echo "$log_entry" >&2
    fi
}

log_error() { log_message "ERROR" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_info() { log_message "INFO" "$1"; }
log_debug() { log_message "DEBUG" "$1"; }

# Utility functions
die() {
    log_error "$1"
    exit "${2:-1}"
}

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Enhanced Cloud-Init Compatible Bootstrap System

USAGE:
    $SCRIPT_NAME --config CONFIG_FILE [OPTIONS]

REQUIRED:
    --config FILE           Path to YAML configuration file

OPTIONS:
    --execute              Execute changes (default is dry-run)
    --force                Force execution even if already completed
    --install-yq           Install yq permanently to /usr/local/bin
    --debug                Enable debug mode with verbose logging
    --log-level LEVEL      Set log level (ERROR, WARN, INFO, DEBUG)
    --no-backup            Disable backup creation before changes
    --override VALUES      Override config values (JSON or key=value,key2=value2)
    --help, -h             Show this help message

EXAMPLES:
    $SCRIPT_NAME --config /etc/cloud-init.yaml
    $SCRIPT_NAME --config config.yaml --execute --debug
    $SCRIPT_NAME --config config.yaml --execute --force --log-level DEBUG
    $SCRIPT_NAME --config config.yaml --override 'hostname=newhost,timezone=UTC' --execute
    $SCRIPT_NAME --config config.yaml --override '{"hostname":"newhost","packages":["vim","curl"]}' --execute

EXIT CODES:
    0 = Success
    1 = Invalid usage
    2 = Missing or invalid config
    3 = Missing yq and unable to install
    4 = Bootstrap already completed (unless --force)
    5 = Validation error
    6 = Execution error
EOF
}

validate_log_level() {
    local level="$1"
    if [[ -z "${LOG_LEVELS[$level]:-}" ]]; then
        die "Invalid log level: $level. Valid levels: ${!LOG_LEVELS[*]}" 1
    fi
}

parse_args() {
    log_debug "parse_args called with: $*"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;

            --debug)
                DEBUG_MODE="true"
                LOG_LEVEL="DEBUG"
                shift
                ;;

            --log-level)
                if [[ $# -lt 2 ]]; then
                    die "--log-level requires a level argument (ERROR, WARN, INFO, DEBUG)" 1
                fi
                validate_log_level "$2"
                LOG_LEVEL="$2"
                shift 2
                ;;

            --config)
                if [[ $# -lt 2 ]]; then
                    die "--config requires a file argument" 1
                fi
                CONFIG_FILE="$2"
                shift 2
                ;;

            --execute)
                EXECUTE_MODE="true"
                shift
                ;;

            --force)
                FORCE_MODE="true"
                shift
                ;;

            --install-yq)
                INSTALL_YQ="true"
                shift
                ;;

            --no-backup)
                BACKUP_MODE="false"
                shift
                ;;

            --override)
                if [[ $# -lt 2 ]]; then
                    die "--override requires a value argument" 1
                fi
                OVERRIDE_VALUES="$2"
                shift 2
                ;;

            *)
                die "Unknown argument: $1. Use --help for usage information." 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$CONFIG_FILE" ]]; then
        die "Missing required --config argument. Use --help for usage information." 1
    fi

    log_debug "CONFIG_FILE resolved to: $CONFIG_FILE"
}


# YAML Flow Style Detection and Conversion Functions
detect_yaml_flow_style() {
    local config_file="$1"
    local content
    
    # Read the file content
    if ! content="$(cat "$config_file" 2>/dev/null)"; then
        return 1
    fi
    
    # Remove comments and whitespace for analysis
    local cleaned_content
    cleaned_content="$(echo "$content" | sed 's/#.*$//' | tr -d '[:space:]')"
    
    # Check if content starts with { and ends with } (YAML Flow style object)
    # or starts with [ and ends with ] (YAML Flow style array)
    if [[ "$cleaned_content" =~ ^(\{.*\}|\[.*\])$ ]]; then
        log_debug "Detected YAML Flow style format in: $config_file"
        return 0
    fi
    
    return 1
}

convert_yaml_flow_to_standard() {
    local config_file="$1"
    local temp_config
    
    log_info "Converting YAML Flow style to standard YAML format"
    
    # Ensure jq is available for JSON processing
    ensure_jq
    
    # Create temporary file for converted configuration
    if ! temp_config="$(mktemp /tmp/flow_config.XXXXXX.yaml)"; then
        die "Failed to create temporary config file for conversion" 6
    fi
    
    # Try to parse as YAML Flow style and convert to standard YAML
    if ! "$YQ_BIN" -o=yaml -P "$config_file" > "$temp_config" 2>/dev/null; then
        # If yq fails, the content might be pure JSON, try jq conversion
        log_debug "yq conversion failed, trying JSON to YAML conversion"
        
        # Validate as JSON first
        if ! "$JQ_BIN" . "$config_file" >/dev/null 2>&1; then
            rm -f "$temp_config"
            die "Invalid YAML Flow style or JSON syntax in configuration file: $config_file" 2
        fi
        
        # Convert JSON to YAML
        if ! "$JQ_BIN" . "$config_file" | "$YQ_BIN" -P > "$temp_config"; then
            rm -f "$temp_config"
            die "Failed to convert JSON to YAML: $config_file" 2
        fi
    fi
    
    # Replace original config with converted version
    if ! mv "$temp_config" "$config_file"; then
        rm -f "$temp_config"
        die "Failed to update configuration file with converted YAML" 6
    fi
    
    log_info "Successfully converted YAML Flow style to standard YAML"
}

# Configuration validation functions
validate_config_file() {
    local config="$1"
    
    log_debug "Validating configuration file: $config"
    
    # Check if file exists and is readable
    if [[ ! -f "$config" ]]; then
        die "Configuration file not found: $config" 2
    fi
    
    if [[ ! -r "$config" ]]; then
        die "Configuration file not readable: $config" 2
    fi
    
    # Check if file is in YAML Flow style format and convert if needed
    if detect_yaml_flow_style "$config"; then
        log_info "YAML Flow style format detected, converting to standard YAML"
        convert_yaml_flow_to_standard "$config"
    fi
    
    # Check if file is valid YAML (after potential conversion)
    if ! "$YQ_BIN" eval '.' "$config" >/dev/null 2>&1; then
        die "Invalid YAML syntax in configuration file: $config" 2
    fi
    
    log_debug "Configuration file validation passed"
}

validate_timezone() {
    local tz="$1"
    [[ -z "$tz" ]] && return 0
    
    if [[ ! -f "/usr/share/zoneinfo/$tz" ]]; then
        log_warn "Timezone file not found: /usr/share/zoneinfo/$tz"
        return 1
    fi
    return 0
}

validate_user_config() {
    local yaml="$1"
    local user_count
    user_count="$("$YQ_BIN" '.users | length' "$yaml" 2>/dev/null || echo 0)"
    
    for i in $(seq 0 $((user_count - 1))); do
        local username
        username="$("$YQ_BIN" ".users[$i].name" "$yaml" 2>/dev/null || true)"
        
        if [[ -z "$username" ]]; then
            log_warn "User configuration at index $i missing name field"
            continue
        fi
        
        # Validate username format
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            log_warn "Invalid username format: $username"
        fi
    done
}
ensure_curl() {
    # 1. Check if curl is already installed
    if command -v curl >/dev/null 2>&1; then
        log_info "curl is already installed."
        return 0
    fi

    echo "curl not found. Attempting to install..."

    # 2. Define a helper for sudo usage
    # If we are root (id 0), don't use sudo. Otherwise, use sudo.
    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
        else
            log_error "Error: Not root and sudo is missing. Cannot install curl."
            return 1
        fi
    fi

    # 3. Detect Package Manager and Install
    if command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu
        log_info "Detected apt-get..."
        $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora / RHEL 8+
        log_info "Detected dnf..."
        $sudo_cmd dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
        # RHEL 7 / CentOS / Amazon Linux
        log_info "Detected yum..."
        $sudo_cmd yum install -y curl
    elif command -v pacman >/dev/null 2>&1; then
        # Arch Linux
        log_info "Detected pacman..."
        $sudo_cmd pacman -Sy --noconfirm curl
    elif command -v apk >/dev/null 2>&1; then
        # Alpine Linux
        log_info "Detected apk..."
        $sudo_cmd apk add --no-cache curl
    elif command -v zypper >/dev/null 2>&1; then
        # OpenSUSE
        log_info "Detected zypper..."
        $sudo_cmd zypper --non-interactive install curl
    else
        log_error "Error: Could not detect a supported package manager (apt, dnf, yum, pacman, apk, zypper)."
        log_error "Please install curl manually."
        return 1
    fi

    # 4. Final Verification
    if command -v curl >/dev/null 2>&1; then
        log_info "curl installed successfully!"
        return 0
    else
        log_error "Error: Installation appeared to fail."
        return 1
    fi
}
# Enhanced dependency management
ensure_yq() {
    log_debug "Checking for yq dependency"
    
    if command -v yq >/dev/null 2>&1; then
        YQ_BIN="$(command -v yq)"
        log_debug "Found existing yq at: $YQ_BIN"
        
        # Verify yq version compatibility
        local yq_version
        yq_version="$("$YQ_BIN" --version 2>/dev/null || echo "unknown")"
        log_debug "yq version: $yq_version"
        return
    fi

    log_info "yq not found, downloading temporary copy"
    
    # Create temporary file with better error handling
    if ! TMP_YQ="$(mktemp /tmp/yq.XXXXXX)"; then
        die "Failed to create temporary file for yq" 3
    fi
    
    # Download with retry logic
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_debug "Downloading yq (attempt $((retry_count + 1))/$max_retries)"
        
        if curl -fsSL --connect-timeout 30 --max-time 300 -o "$TMP_YQ" \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"; then
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_warn "Download failed, retrying in 5 seconds..."
            sleep 5
        else
            die "Failed to download yq after $max_retries attempts" 3
        fi
    done
    
    # Verify download and make executable
    if [[ ! -s "$TMP_YQ" ]]; then
        die "Downloaded yq file is empty or corrupted" 3
    fi
    
    chmod +x "$TMP_YQ" || die "Failed to make yq executable" 3
    YQ_BIN="$TMP_YQ"
    
    # Test yq functionality
    if ! "$YQ_BIN" --version >/dev/null 2>&1; then
        die "Downloaded yq binary is not functional" 3
    fi
    
    log_info "Successfully downloaded and verified yq"

    # Install permanently if requested
    if [[ "$INSTALL_YQ" == "true" ]]; then
        log_info "Installing yq permanently to /usr/local/bin"
        
        if cp "$TMP_YQ" /usr/local/bin/yq 2>/dev/null; then
            chmod +x /usr/local/bin/yq
            YQ_BIN="/usr/local/bin/yq"
            log_info "yq installed successfully"
        else
            log_warn "Failed to install yq permanently, continuing with temporary copy"
        fi
    fi
}

# JSON processing dependency (only called when --override is used)
ensure_jq() {
    log_debug "Checking for jq dependency"
    
    if command -v jq >/dev/null 2>&1; then
        JQ_BIN="$(command -v jq)"
        log_debug "Found existing jq at: $JQ_BIN"
        
        # Verify jq version compatibility
        local jq_version
        jq_version="$(\"$JQ_BIN\" --version 2>/dev/null || echo \"unknown\")"
        log_debug "jq version: $jq_version"
        return
    fi

    log_info "jq not found, downloading temporary copy"
    
    # Create temporary file with better error handling
    if ! TMP_JQ="$(mktemp /tmp/jq.XXXXXX)"; then
        die "Failed to create temporary file for jq" 3
    fi
    
    # Download with retry logic
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_debug "Downloading jq (attempt $((retry_count + 1))/$max_retries)"
        
        if curl -fsSL --connect-timeout 30 --max-time 300 -o "$TMP_JQ" \
            "https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64"; then
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_warn "Download failed, retrying in 5 seconds..."
            sleep 5
        else
            die "Failed to download jq after $max_retries attempts" 3
        fi
    done
    
    # Verify download and make executable
    if [[ ! -s "$TMP_JQ" ]]; then
        die "Downloaded jq file is empty or corrupted" 3
    fi
    
    chmod +x "$TMP_JQ" || die "Failed to make jq executable" 3
    JQ_BIN="$TMP_JQ"
    
    # Test jq functionality
    if ! "$JQ_BIN" --version >/dev/null 2>&1; then
        die "Downloaded jq binary is not functional" 3
    fi
    
    log_info "Successfully downloaded and verified jq"
}

# Apply override values to configuration
apply_overrides() {
    local config_file="$1"
    
    if [[ -z "$OVERRIDE_VALUES" ]]; then
        log_debug "No override values specified"
        return
    fi
    
    log_info "Applying override values: $OVERRIDE_VALUES"
    
    # Ensure jq is available for JSON processing
    ensure_jq
    
    # Create temporary file for modified configuration
    local temp_config
    if ! temp_config="$(mktemp /tmp/config.XXXXXX.yaml)"; then
        die "Failed to create temporary config file" 6
    fi
    
    # Copy original config to temp file
    cp "$config_file" "$temp_config" || die "Failed to copy config file" 6
    
    # Parse override values - support both JSON and key:value formats
    local override_json=""
    
    if [[ "$OVERRIDE_VALUES" =~ ^\{.*\}$ ]]; then
        # JSON or YAML flow style format
        log_debug "Detected brace-enclosed format override"
        
        # Try JSON first
        if echo "$OVERRIDE_VALUES" | "$JQ_BIN" . >/dev/null 2>&1; then
            log_debug "Confirmed JSON format override"
            override_json="$OVERRIDE_VALUES"
        else
            # Try YAML flow style
            log_debug "JSON parsing failed, trying YAML flow style"
            
            # Validate YAML flow style syntax
            if ! echo "$OVERRIDE_VALUES" | "$YQ_BIN" -o=json . >/dev/null 2>&1; then
                die "Invalid JSON or YAML flow style in override values: $OVERRIDE_VALUES" 5
            fi
            
            log_debug "Confirmed YAML flow style override"
            # Convert YAML flow style to JSON for processing
            if ! override_json="$(echo "$OVERRIDE_VALUES" | "$YQ_BIN" -o=json .)"; then
                die "Failed to convert YAML flow style to JSON: $OVERRIDE_VALUES" 5
            fi
        fi
    else
        # Simple key:value format (e.g., "hostname=newhost,timezone=UTC")
        log_debug "Detected key:value format override"
        
        # Convert key:value pairs to JSON
        override_json="{"
        local first=true
        
        IFS=',' read -ra PAIRS <<< "$OVERRIDE_VALUES"
        for pair in "${PAIRS[@]}"; do
            if [[ "$pair" =~ ^([^=]+)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                
                # Trim whitespace
                key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                
                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    override_json+=","
                fi
                
                # Escape value for JSON
                value="$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
                override_json+="\"$key\":\"$value\""
            else
                log_warn "Ignoring invalid override pair: $pair"
            fi
        done
        
        override_json+="}"
        
        # Validate generated JSON
        if ! echo "$override_json" | "$JQ_BIN" . >/dev/null 2>&1; then
            die "Failed to generate valid JSON from override values: $OVERRIDE_VALUES" 5
        fi
    fi
    
    log_debug "Override JSON: $override_json"
    
    # Convert YAML to JSON, merge with overrides, convert back to YAML
    local merged_json
    if ! merged_json="$("$YQ_BIN" -o=json "$temp_config" | "$JQ_BIN" --argjson overrides "$override_json" '. * $overrides')"; then
        die "Failed to merge override values with configuration" 6
    fi
    
    # Convert merged JSON back to YAML
    if ! echo "$merged_json" | "$YQ_BIN" -P > "$temp_config"; then
        die "Failed to convert merged configuration back to YAML" 6
    fi
    
    # Replace original config file with merged version
    mv "$temp_config" "$config_file" || die "Failed to update configuration file" 6
    
    log_info "Successfully applied override values to configuration"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
    elif command -v apk >/dev/null 2>&1; then
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
    else
        die "Unsupported package manager"
    fi
}

# Backup and safety functions
create_backup() {
    local file_path="$1"
    local backup_name="$2"
    
    [[ "$BACKUP_MODE" != "true" ]] && return 0
    [[ ! -f "$file_path" ]] && return 0
    
    local backup_file="$BACKUP_DIR/${backup_name}_${TIMESTAMP}"
    
    log_debug "Creating backup: $file_path -> $backup_file"
    
    if mkdir -p "$BACKUP_DIR" 2>/dev/null && cp "$file_path" "$backup_file" 2>/dev/null; then
        log_debug "Backup created successfully: $backup_file"
        return 0
    else
        log_warn "Failed to create backup for: $file_path"
        return 1
    fi
}

# Enhanced execution function with better error handling
run_or_print() {
    local desc="$1"
    local cmd="$2"
    local allow_failure="${3:-false}"

    if [[ "$EXECUTE_MODE" == "true" ]]; then
        log_info "$desc"
        log_debug "Executing command: $cmd"
        
        # Execute with timeout and error handling
        if [[ "$allow_failure" == "true" ]]; then
            # Allow command to fail without stopping the script
            if ! timeout 300 bash -c "$cmd" 2>&1; then
                log_warn "Command failed (non-critical): $cmd"
                return 1
            fi
        else
            # Critical command - failure stops the script
            if ! timeout 300 bash -c "$cmd" 2>&1; then
                die "Critical command failed: $cmd" 6
            fi
        fi
        
        log_debug "Command completed successfully"
    else
        log_info "[DRY RUN] $desc"
        log_debug "[DRY RUN] Would execute: $cmd"
    fi
}

process_packages() {
    local yaml="$1"
    local pkgs
    pkgs="$("$YQ_BIN" '.packages // [] | .[]' "$yaml" 2>/dev/null || true)"

    [[ -z "$pkgs" ]] && return

    run_or_print "Updating package index" "$PKG_UPDATE"

    for pkg in $pkgs; do
        run_or_print "Installing package: $pkg" "$PKG_INSTALL $pkg"
    done
}

process_users() {
    local yaml="$1"
    local users
    users="$("$YQ_BIN" '.users // [] | .[] | .name' "$yaml" 2>/dev/null || true)"

    [[ -z "$users" ]] && return

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        run_or_print "Ensuring user exists: $user" "id -u $user >/dev/null 2>&1 || useradd -m $user"
    done <<< "$users"
}

process_ssh_keys() {
    local yaml="$1"
    local keys
    keys="$("$YQ_BIN" '.ssh_authorized_keys // [] | .[]' "$yaml" 2>/dev/null || true)"

    [[ -z "$keys" ]] && return

    local target_user
    target_user="$("$YQ_BIN" '.users[0].name // "root"' "$yaml")"

    local ssh_dir="/home/$target_user/.ssh"
    [[ "$target_user" == "root" ]] && ssh_dir="/root/.ssh"

    # Create backup before modifying authorized_keys
    create_backup "$ssh_dir/authorized_keys" "authorized_keys"

    run_or_print "Creating SSH directory for $target_user" "mkdir -p $ssh_dir && chmod 700 $ssh_dir"

    while IFS= read -r key; do
        run_or_print "Adding SSH key for $target_user" "echo \"$key\" >> $ssh_dir/authorized_keys"
    done <<< "$keys"

    run_or_print "Fixing SSH permissions" "chmod 600 $ssh_dir/authorized_keys && chown -R $target_user:$target_user $ssh_dir"
}

process_write_files() {
    local yaml="$1"
    local count
    count="$("$YQ_BIN" '.write_files | length' "$yaml" 2>/dev/null || echo 0)"

    for i in $(seq 0 $((count - 1))); do
        local path perm content
        path="$("$YQ_BIN" ".write_files[$i].path" "$yaml")"
        perm="$("$YQ_BIN" ".write_files[$i].permissions // \"0644\"" "$yaml")"
        content="$("$YQ_BIN" ".write_files[$i].content" "$yaml")"

        # Create backup before writing file
        create_backup "$path" "write_files_$(basename "$path")"
        
        run_or_print "Writing file: $path" "printf \"%s\" \"$content\" > \"$path\" && chmod $perm \"$path\""
    done
}

process_hostname() {
    local yaml="$1"
    local name
    name="$("$YQ_BIN" '.hostname // ""' "$yaml")"
    [[ -z "$name" ]] && return

    # Create backup before modifying hostname
    create_backup "/etc/hostname" "hostname"

    run_or_print "Setting hostname to $name" "hostnamectl set-hostname \"$name\" 2>/dev/null || echo \"$name\" > /etc/hostname"
}

process_timezone() {
    local yaml="$1"
    local tz
    tz="$("$YQ_BIN" '.timezone // ""' "$yaml")"
    [[ -z "$tz" ]] && return

    # Create backup before modifying timezone
    create_backup "/etc/localtime" "localtime"

    run_or_print "Setting timezone to $tz" "ln -sf /usr/share/zoneinfo/$tz /etc/localtime"
}

process_locale() {
    local yaml="$1"
    local loc
    loc="$("$YQ_BIN" '.locale // ""' "$yaml")"
    [[ -z "$loc" ]] && return

    # Create backup before modifying locale configuration
    create_backup "/etc/locale.gen" "locale.gen"

    run_or_print "Setting locale to $loc" "echo \"$loc UTF-8\" >> /etc/locale.gen 2>/dev/null || true; locale-gen 2>/dev/null || true"
}

process_bootcmd() {
    local yaml="$1"
    local cmds
    cmds="$("$YQ_BIN" '.bootcmd // [] | .[]' "$yaml" 2>/dev/null || true)"

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        run_or_print "Executing bootcmd: $cmd" "$cmd"
    done <<< "$cmds"
}

process_runcmd() {
    local yaml="$1"
    local cmds
    cmds="$("$YQ_BIN" '.runcmd // [] | .[]' "$yaml" 2>/dev/null || true)"

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        run_or_print "Executing runcmd: $cmd" "$cmd"
    done <<< "$cmds"
}

process_final_message() {
    local yaml="$1"
    local msg
    msg="$("$YQ_BIN" '.final_message // ""' "$yaml")"
    [[ -z "$msg" ]] && return

    log_message "INFO" "$msg"
}

main() {
    # Verify bash availability/version before setting traps
    check_bash_requirement

    # Initialize error handling first
    setup_error_handling
    
    # Root privilege check
    if [[ $EUID -ne 0 ]]; then
        die "Requires root. Re-run with sudo or as root." 1
    fi

    # Parse arguments and validate configuration
    parse_args "$@"
    
    log_info "Starting bootstrap v$SCRIPT_VERSION"
    log_info "Configuration file: $CONFIG_FILE"
    log_info "Execution mode: $([ "$EXECUTE_MODE" == "true" ] && echo "LIVE" || echo "DRY RUN")"
    log_info "Log level: $LOG_LEVEL"

    # Check if already completed
    if [[ -f "$STAMP_FILE" && "$FORCE_MODE" != "true" ]]; then
        die "Bootstrap already completed. Use --force to override." 4
    fi

    # Initialize dependencies
    ensure_curl
    ensure_yq
    detect_package_manager
    
    # Validate configuration file
    validate_config_file "$CONFIG_FILE"
    validate_user_config "$CONFIG_FILE"
    
    # Apply override values if specified
    apply_overrides "$CONFIG_FILE"
    
    # Create backup directory if needed
    if [[ "$BACKUP_MODE" == "true" && "$EXECUTE_MODE" == "true" ]]; then
        mkdir -p "$BACKUP_DIR" || log_warn "Failed to create backup directory: $BACKUP_DIR"
    fi

    # Execute bootstrap phases
    log_info "Beginning bootstrap execution..."
    
    log_debug "Phase: Boot commands"
    process_bootcmd "$CONFIG_FILE"

    log_debug "Phase: Package installation"
    process_packages "$CONFIG_FILE"

    log_debug "Phase: User management"
    process_users "$CONFIG_FILE"

    log_debug "Phase: SSH key configuration"
    process_ssh_keys "$CONFIG_FILE"

    log_debug "Phase: File creation"
    process_write_files "$CONFIG_FILE"

    log_debug "Phase: System configuration"
    process_hostname "$CONFIG_FILE"
    
    # Validate timezone before setting
    local tz
    tz="$("$YQ_BIN" '.timezone // ""' "$CONFIG_FILE")"
    if [[ -n "$tz" ]]; then
        if validate_timezone "$tz"; then
            process_timezone "$CONFIG_FILE"
        else
            log_warn "Skipping invalid timezone: $tz"
        fi
    fi
    
    process_locale "$CONFIG_FILE"

    log_debug "Phase: Runtime commands"
    process_runcmd "$CONFIG_FILE"

    log_debug "Phase: Finalization"
    process_final_message "$CONFIG_FILE"

    # Mark completion and log results
    if [[ "$EXECUTE_MODE" == "true" ]]; then
        touch "$STAMP_FILE" || log_warn "Failed to create completion stamp file"
        log_info "Bootstrap completed successfully"
        log_info "Completion timestamp: $(date)"
        log_info "Log file: $LOG_FILE"
        [[ "$BACKUP_MODE" == "true" ]] && log_info "Backups stored in: $BACKUP_DIR"
    else
        log_info "Dry run completed successfully (no changes made)"
        log_info "Use --execute to apply changes"
    fi
}


main "$@"
