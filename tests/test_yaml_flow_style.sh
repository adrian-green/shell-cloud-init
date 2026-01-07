#!/usr/bin/env bash
#
# Test script for YAML Flow style support in bootstrap.sh
#

set -euo pipefail

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_SCRIPT="$PROJECT_DIR/bootstrap.sh"
TEST_CONFIG_FLOW="$PROJECT_DIR/test-flow-config.yaml"
TEST_CONFIG_STANDARD="$PROJECT_DIR/test-config.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Test result functions
test_pass() {
    local test_name="$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log_info "✓ $test_name"
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_error "✗ $test_name: $reason"
}

run_test() {
    local test_name="$1"
    local test_function="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Running test: $test_name"
    
    if $test_function; then
        test_pass "$test_name"
    else
        test_fail "$test_name" "Test function failed"
    fi
    
    echo
}

# Test functions
test_yaml_flow_detection() {
    # Test that YAML Flow style is properly detected
    local temp_config
    temp_config="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create a YAML Flow style config
    cat > "$temp_config" << 'EOF'
{
  "hostname": "test-server",
  "packages": ["vim", "curl"]
}
EOF
    
    # Run bootstrap in dry-run mode to test detection
    local output
    output="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_config" --debug 2>&1)"
    
    if echo "$output" | grep -q "Detected YAML Flow style format in:"; then
        rm -f "$temp_config"
        return 0
    else
        rm -f "$temp_config"
        return 1
    fi
}

test_yaml_flow_conversion() {
    # Test that YAML Flow style is properly converted to standard YAML
    local temp_config
    temp_config="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create a YAML Flow style config
    cat > "$temp_config" << 'EOF'
{"hostname": "test-server", "packages": ["vim", "curl"]}
EOF
    
    # Run bootstrap in dry-run mode to test conversion
    local output
    output="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_config" --debug 2>&1)"
    
    if echo "$output" | grep -q "Converting YAML Flow style to standard YAML format"; then
        # Check if the file was converted to standard YAML format
        if grep -q "hostname: test-server" "$temp_config" && grep -q "packages:" "$temp_config"; then
            rm -f "$temp_config"
            return 0
        fi
    fi
    
    rm -f "$temp_config"
    return 1
}

test_yaml_flow_validation() {
    # Test that invalid YAML Flow style is properly rejected
    local temp_config
    temp_config="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create an invalid YAML Flow style config
    cat > "$temp_config" << 'EOF'
{
  "hostname": "test-server",
  "packages": ["vim", "curl"
}
EOF
    
    # Run bootstrap and expect it to fail with validation error
    local output
    output="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_config" 2>&1)"
    
    if echo "$output" | grep -q "Invalid YAML Flow style or JSON syntax"; then
        rm -f "$temp_config"
        return 0
    else
        rm -f "$temp_config"
        return 1
    fi
}

test_yaml_flow_processing() {
    # Test that YAML Flow style config is processed correctly
    local temp_config
    temp_config="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create a valid YAML Flow style config
    cat > "$temp_config" << 'EOF'
{
  "hostname": "flow-test",
  "packages": ["curl"],
  "final_message": "Flow style test completed"
}
EOF
    
    # Run bootstrap in dry-run mode and check for expected processing
    local output
    output="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_config" 2>&1)"
    
    if echo "$output" | grep -q "Setting hostname to flow-test" && \
       echo "$output" | grep -q "Installing package: curl" && \
       echo "$output" | grep -q "Flow style test completed"; then
        rm -f "$temp_config"
        return 0
    else
        rm -f "$temp_config"
        return 1
    fi
}

test_yaml_flow_with_overrides() {
    # Test that YAML Flow style works with override values
    local temp_config
    temp_config="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create a YAML Flow style config
    cat > "$temp_config" << 'EOF'
{
  "hostname": "original-host",
  "packages": ["vim"]
}
EOF
    
    # Run bootstrap with YAML Flow style override
    local output
    output="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_config" --override '{hostname: "overridden-host", packages: ["curl", "git"]}' 2>&1)"
    
    if echo "$output" | grep -q "Setting hostname to overridden-host" && \
       echo "$output" | grep -q "Installing package: curl" && \
       echo "$output" | grep -q "Installing package: git"; then
        rm -f "$temp_config"
        return 0
    else
        rm -f "$temp_config"
        return 1
    fi
}

test_mixed_format_support() {
    # Test that both standard YAML and YAML Flow style work
    local temp_standard temp_flow
    temp_standard="$(mktemp /tmp/test_standard.XXXXXX.yaml)"
    temp_flow="$(mktemp /tmp/test_flow.XXXXXX.yaml)"
    
    # Create standard YAML config
    cat > "$temp_standard" << 'EOF'
hostname: standard-host
packages:
  - vim
  - curl
EOF
    
    # Create YAML Flow style config
    cat > "$temp_flow" << 'EOF'
{"hostname": "flow-host", "packages": ["vim", "curl"]}
EOF
    
    # Test both formats
    local output_standard output_flow
    output_standard="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_standard" 2>&1)"
    output_flow="$(sudo "$BOOTSTRAP_SCRIPT" --config "$temp_flow" 2>&1)"
    
    if echo "$output_standard" | grep -q "Setting hostname to standard-host" && \
       echo "$output_flow" | grep -q "Setting hostname to flow-host"; then
        rm -f "$temp_standard" "$temp_flow"
        return 0
    else
        rm -f "$temp_standard" "$temp_flow"
        return 1
    fi
}

# Main test execution
main() {
    log_info "Starting YAML Flow style tests for bootstrap.sh"
    log_info "Bootstrap script: $BOOTSTRAP_SCRIPT"
    echo
    
    # Check if bootstrap script exists
    if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
        log_error "Bootstrap script not found: $BOOTSTRAP_SCRIPT"
        exit 1
    fi
    
    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "Tests must be run as root or with sudo"
        exit 1
    fi
    
    # Run tests
    run_test "YAML Flow style detection" test_yaml_flow_detection
    run_test "YAML Flow style conversion" test_yaml_flow_conversion
    run_test "YAML Flow style validation" test_yaml_flow_validation
    run_test "YAML Flow style processing" test_yaml_flow_processing
    run_test "YAML Flow style with overrides" test_yaml_flow_with_overrides
    run_test "Mixed format support" test_mixed_format_support
    
    # Print summary
    echo "========================================="
    log_info "Test Summary:"
    log_info "Tests run: $TESTS_RUN"
    log_info "Tests passed: $TESTS_PASSED"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Tests failed: $TESTS_FAILED"
        exit 1
    else
        log_info "All tests passed!"
        exit 0
    fi
}

main "$@"