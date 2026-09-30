#!/bin/bash

# ==============================================================================
#            CPU Temperature Governor and Throttling Service
#
# This script monitors the CPU temperature and adjusts the maximum frequency
# to prevent overheating, logging all actions. Designed for Intel CPUs (e.g., i5-7200U).
# ==============================================================================

set -euo pipefail

### --- CONFIGURATION --- ###

# Frequencies. Ensure these are valid for your CPU architecture.
MIN_FREQ="${MIN_FREQ:-1.5GHz}"
MAX_FREQ_NORMAL="${MAX_FREQ_NORMAL:-2.5GHz}"
MAX_FREQ_REDUCED="${MAX_FREQ_REDUCED:-2.0GHz}"
GOVERNOR="${GOVERNOR:-performance}"

# Temperature thresholds in Celsius degrees.
TEMP_HIGH="${TEMP_HIGH:-80}"
TEMP_LOW="${TEMP_LOW:-70}"

# Logging configuration.
LOG_FILE="${LOG_FILE:-/var/log/cpu-throttle.log}"
LOG_MAX_LINES="${LOG_MAX_LINES:-500}"

# Polling interval in seconds.
SLEEP_INTERVAL="${SLEEP_INTERVAL:-5}"

# Safety configurations.
MAX_TEMP_EMERGENCY=95
MAX_CONSECUTIVE_ERRORS=5
LOCKFILE="/var/run/cpu-throttle.lock"
PID_FILE="/var/run/cpu-throttle.pid"

### --- END OF CONFIGURATION --- ###

# Global variables
CURRENT_STATE="normal"
CONSECUTIVE_ERRORS=0
SCRIPT_PID=$$

# Cleanup function triggered on exit
cleanup() {
    local exit_code=$?
    log_action "--- Service Stopped (exit code: $exit_code) ---"
    
    # Restore normal frequency limits gracefully
    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -g "$GOVERNOR" -d "$MIN_FREQ" -u "$MAX_FREQ_NORMAL" >/dev/null 2>&1 || true
        log_action "Frequency restored to normal values upon exit"
    fi
    
    # Clean up PID file (flock handles the lockfile automatically)
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    
    exit "$exit_code"
}

# Trap signals for graceful shutdown
trap cleanup EXIT INT TERM QUIT

# Check for required system dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v cpupower >/dev/null 2>&1; then
        missing_deps+=("cpupower (linux-tools-common)")
    fi
    
    if ! command -v sensors >/dev/null 2>&1; then
        missing_deps+=("sensors (lm-sensors)")
    fi
    
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root" >&2
        exit 1
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies:" >&2
        printf ' - %s\n' "${missing_deps[@]}" >&2
        exit 1
    fi
}

# Validate user-provided configuration
validate_config() {
    # Check if cpupower can read CPU info
    if ! cpupower frequency-info -l >/dev/null 2>&1; then
        log_action "WARNING: Cannot retrieve CPU frequency limits (driver might be overriding)"
    fi
    
    if [[ $TEMP_HIGH -le $TEMP_LOW ]]; then
        echo "ERROR: TEMP_HIGH ($TEMP_HIGH) must be strictly greater than TEMP_LOW ($TEMP_LOW)" >&2
        exit 1
    fi
    
    if [[ $TEMP_HIGH -gt $MAX_TEMP_EMERGENCY ]]; then
        echo "ERROR: TEMP_HIGH ($TEMP_HIGH) cannot exceed MAX_TEMP_EMERGENCY ($MAX_TEMP_EMERGENCY)" >&2
        exit 1
    fi
    
    if [[ $SLEEP_INTERVAL -lt 1 ]]; then
        echo "ERROR: SLEEP_INTERVAL must be at least 1 second" >&2
        exit 1
    fi
}

# Thread-safe logging mechanism
log_action() {
    local message="$1"
    local temp
    
    mkdir -p "$(dirname "$LOG_FILE")"
    temp=$(get_max_temp 2>/dev/null || echo "N/A")
    
    # Append to log, fallback to syslog on failure
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') | PID:$SCRIPT_PID | Temp: ${temp}°C | $message" >> "$LOG_FILE" 2>/dev/null; then
        logger -t "cpu-throttle[$SCRIPT_PID]" "$message"
    fi
}

# In-place log rotation to prevent inode changes
trim_log_file() {
    if [[ -f "$LOG_FILE" && -w "$LOG_FILE" ]]; then
        local temp_file
        temp_file=$(mktemp) || return 1
        
        if tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$temp_file" 2>/dev/null; then
            # Use 'cat' instead of 'mv' to preserve the file descriptor/inode
            cat "$temp_file" > "$LOG_FILE" 2>/dev/null
        fi
        
        rm -f "$temp_file" 2>/dev/null || true
    fi
}

# Extract the highest temperature across all sensors
get_max_temp() {
    local temp_values temp_max
    
    temp_values=$(
        {
            # Method 1: lm-sensors
            sensors 2>/dev/null | awk '/(Core|Package|CPU).*°C/{
                match($0, /[+]?([0-9]+\.?[0-9]*)[°]?C/, arr)
                if (arr[1] != "") print arr[1]
            }'
            
            # Method 2: thermal_zone (sysfs)
            if [[ -d /sys/class/thermal ]]; then
                for zone in /sys/class/thermal/thermal_zone*/temp; do
                    [[ -r "$zone" ]] || continue
                    local millicelsius
                    millicelsius=$(cat "$zone" 2>/dev/null) || continue
                    echo "$((millicelsius / 1000))"
                done
            fi
            
            # Method 3: hwmon (sysfs)
            if [[ -d /sys/class/hwmon ]]; then
                find /sys/class/hwmon -name "temp*_input" 2>/dev/null | while read -r temp_file; do
                    [[ -r "$temp_file" ]] || continue
                    local millicelsius
                    millicelsius=$(cat "$temp_file" 2>/dev/null) || continue
                    echo "$((millicelsius / 1000))"
                done
            fi
        } | sort -nr | head -n1
    )
    
    temp_max=$(echo "$temp_values" | head -n1)
    
    if [[ -n "$temp_max" && "$temp_max" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$temp_max"
        return 0
    else
        return 1
    fi
}

# Safely set CPU frequency limits relying on exit codes
set_cpu_limits() {
    local min_freq="$1"
    local max_freq="$2"
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Trust cpupower's exit status instead of parsing unit-mismatched string outputs
        if cpupower frequency-set -g "$GOVERNOR" -d "$min_freq" -u "$max_freq" >/dev/null 2>&1; then
            CONSECUTIVE_ERRORS=0
            return 0
        fi
        
        ((retry_count++))
        log_action "WARNING: Retry $retry_count/$max_retries applying frequencies"
        sleep 1
    done
    
    ((CONSECUTIVE_ERRORS++))
    log_action "ERROR: Failed to apply cpupower configuration after $max_retries attempts"
    
    if [[ $CONSECUTIVE_ERRORS -ge $MAX_CONSECUTIVE_ERRORS ]]; then
        log_action "CRITICAL: Too many consecutive errors ($CONSECUTIVE_ERRORS). Exiting to prevent damage."
        exit 1
    fi
    
    return 1
}

# Apply aggressive throttling in case of severe overheating
emergency_throttle() {
    local temp="$1"
    log_action "EMERGENCY: Critical temperature reached ($temp°C). Applying maximum throttle."
    
    if ! cpupower frequency-set -g "powersave" -u "$MIN_FREQ" >/dev/null 2>&1; then
        log_action "CRITICAL: Failed to apply emergency throttle via cpupower."
        # Fallback directly to sysfs as a last resort
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [[ -w "$gov" ]] && echo "powersave" > "$gov" 2>/dev/null || true
        done
    fi
    
    logger -p kern.crit "cpu-throttle: Emergency temp ($temp°C) - maximum throttling enforced"
}

### --- MAIN EXECUTION --- ###

main() {
    # File descriptor 9 is used for flock to guarantee a single instance
    exec 9> "$LOCKFILE"
    if ! flock -n 9; then
        echo "ERROR: Another instance of cpu-throttle is already running." >&2
        exit 1
    fi
    echo "$SCRIPT_PID" > "$PID_FILE"

    check_dependencies
    validate_config
    trim_log_file
    
    log_action "--- Service Started (Config: $MIN_FREQ-$MAX_FREQ_NORMAL, Thresholds: $TEMP_LOW°C-$TEMP_HIGH°C) ---"
    
    if ! set_cpu_limits "$MIN_FREQ" "$MAX_FREQ_NORMAL"; then
        log_action "WARNING: Initial configuration failed, proceeding with monitoring..."
    else
        log_action "Initial state: NORMAL. Max frequency: $MAX_FREQ_NORMAL"
    fi
    
    while true; do
        if ! TEMP=$(get_max_temp); then
            log_action "WARNING: Failed to read CPU temperature"
            ((CONSECUTIVE_ERRORS++))
            
            if [[ $CONSECUTIVE_ERRORS -ge $MAX_CONSECUTIVE_ERRORS ]]; then
                log_action "CRITICAL: Consecutive temperature read failures. Exiting."
                exit 1
            fi
            
            sleep "$SLEEP_INTERVAL"
            continue
        fi
        
        CONSECUTIVE_ERRORS=0
        
        # Truncate decimals for bash integer comparison
        TEMP_INT=${TEMP%.*}
        
        if [[ $TEMP_INT -ge $MAX_TEMP_EMERGENCY ]]; then
            emergency_throttle "$TEMP"
            sleep $((SLEEP_INTERVAL * 2))
            continue
        fi
        
        # Hysteresis-based throttling logic
        if [[ "$CURRENT_STATE" == "normal" && $TEMP_INT -ge $TEMP_HIGH ]]; then
            CURRENT_STATE="reduced"
            if set_cpu_limits "$MIN_FREQ" "$MAX_FREQ_REDUCED"; then
                log_action "STATE CHANGED: REDUCED. Frequency limit set to: $MAX_FREQ_REDUCED"
            fi
            
        elif [[ "$CURRENT_STATE" == "reduced" && $TEMP_INT -le $TEMP_LOW ]]; then
            CURRENT_STATE="normal"
            if set_cpu_limits "$MIN_FREQ" "$MAX_FREQ_NORMAL"; then
                log_action "STATE CHANGED: NORMAL. Frequency limit set to: $MAX_FREQ_NORMAL"
            fi
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
}

main "$@"
