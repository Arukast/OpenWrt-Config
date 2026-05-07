#!/bin/sh
# SQM_Speedtest.sh
# Tests download/upload speed using curl, calculates optimal SQM values (85-95%),
# and can apply them to setup.conf or the live OpenWrt configuration.

set -u

# Download / Upload test size (bytes)
# Using ~20MB download and ~10MB upload for a quick but reasonable test.
DL_BYTES_SIZE=20000000
UL_BYTES_SIZE=10000000

LOG_FILE="/tmp/sqm-speedtest.log"

# --- Colors & Logging ---
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() {
    local level=$1; shift
    local msg="$*"
    # Print to console with color, append to log without color
    case "$level" in
        INFO) printf "${CYAN}[INFO]${NC}  %s\n" "$msg" ;;
        OK)   printf "${GREEN}[ OK ]${NC}  %s\n" "$msg" ;;
        WARN) printf "${YELLOW}[WARN]${NC}  %s\n" "$msg" ;;
        ERR)  printf "${RED}[ ERR ]${NC}  %s\n" "$msg" >&2 ;;
        STEP) printf "\n${BOLD}>>> %s${NC}\n" "$msg" ;;
        *)    printf "%s\n" "$msg" ;;
    esac
    # Remove ansi escape codes for the log file
    echo "[$level] $msg" | sed -E 's/\x1B\[[0-9;]*m//g' >> "$LOG_FILE"
}

log_info()  { _log INFO "$*"; }
log_ok()    { _log OK "$*"; }
log_warn()  { _log WARN "$*"; }
log_error() { _log ERR "$*"; }
log_step()  { _log STEP "$*"; }
_abort()    { log_error "$*"; exit 1; }
raw_echo()  { _log RAW "$*"; }

# Initialize log file
> "$LOG_FILE"

log_step "OpenWrt SQM Speed Optimizer"
log_info "This script uses curl to measure your current download and upload speeds."
log_info "It monitors your ping during the tests to calculate your Bufferbloat,"
log_info "and dynamically adjusts the SQM limits (80%% - 95%%) based on the severity."

# Pre-checks
if ! command -v curl >/dev/null 2>&1; then
    _abort "curl is required. Please install it first (e.g., apk add curl or opkg install curl)."
fi
if ! command -v awk >/dev/null 2>&1; then
    _abort "awk is required but not found."
fi

# Temporarily disable SQM if running on live router to get raw speeds
SQM_WAS_RUNNING=0
if command -v uci >/dev/null 2>&1 && [ -x "/etc/init.d/sqm" ]; then
    if /etc/init.d/sqm status >/dev/null 2>&1; then
        log_warn "Active SQM detected! Temporarily stopping SQM to measure raw, unshaped speeds..."
        /etc/init.d/sqm stop
        SQM_WAS_RUNNING=1
        sleep 2
    fi
fi

# Measure Idle Ping First
log_step "Measuring Idle Latency..."
IDLE_PING_SUM=0
for i in $(seq 1 3); do
    PING_VAL=$(ping -c 3 8.8.8.8 | awk -F'time=' '/time=/{split($2,a," "); sum+=a[1]; count++} END{if(count>0) printf "%.0f", sum/count; else print 0}')
    if [ "$PING_VAL" -gt 0 ]; then
        IDLE_PING_SUM=$((IDLE_PING_SUM + PING_VAL))
    fi
    sleep 1
done
IDLE_PING=$((IDLE_PING_SUM / 3))
[ "$IDLE_PING" -eq 0 ] && IDLE_PING=10  # fallback
log_ok "Average Idle Latency: ${IDLE_PING} ms"

# Multi-pass loop
TEST_ITERATIONS=5
DL_SUM=0
UL_SUM=0
DL_PING_SUM=0
UL_PING_SUM=0
VALID_RUNS=0

log_step "Starting Loaded Speed & Latency Test ($TEST_ITERATIONS Iterations)"
for i in $(seq 1 $TEST_ITERATIONS); do
    log_info "Run $i/$TEST_ITERATIONS: Testing Download (approx $((${DL_BYTES_SIZE}/1000000))MB)..."
    ping 8.8.8.8 > /tmp/dl_ping_raw 2>/dev/null &
    PING_PID=$!
    
    DL_BPS=$(curl -4 -k -s -L -w "%{speed_download}" -o /dev/null "https://speed.cloudflare.com/__down?bytes=$DL_BYTES_SIZE" | sed 's/,/\./g')
    kill $PING_PID 2>/dev/null || true
    DL_PING_RUN=$(awk -F'time=' '/time=/{split($2,a," "); sum+=a[1]; count++} END{if(count>0) printf "%.0f", sum/count; else print 0}' /tmp/dl_ping_raw)

    log_info "Run $i/$TEST_ITERATIONS: Testing Upload (approx $((${UL_BYTES_SIZE}/1000000))MB)..."
    ping 8.8.8.8 > /tmp/ul_ping_raw 2>/dev/null &
    PING_PID=$!
    
    dd if=/dev/urandom of=/tmp/sqm_up_test bs=1000 count=$((${UL_BYTES_SIZE}/1000)) 2>/dev/null
    UL_BPS=$(curl -4 -k -s -L -w "%{speed_upload}" -o /dev/null -T /tmp/sqm_up_test "https://speed.cloudflare.com/__up" | sed 's/,/\./g')
    kill $PING_PID 2>/dev/null || true
    
    UL_PING_RUN=$(awk -F'time=' '/time=/{split($2,a," "); sum+=a[1]; count++} END{if(count>0) printf "%.0f", sum/count; else print 0}' /tmp/ul_ping_raw)
    
    rm -f /tmp/sqm_up_test /tmp/dl_ping_raw /tmp/ul_ping_raw
    
    if [ -n "$DL_BPS" ] && [ -n "$UL_BPS" ] && [ "$DL_BPS" != "0" ] && [ "$UL_BPS" != "0" ] && [ "$DL_BPS" != "0.000" ] && [ "$UL_BPS" != "0.000" ]; then
        DL_KBPS_RUN=$(awk -v bps="$DL_BPS" 'BEGIN { printf "%.0f", (bps * 8) / 1000 }')
        UL_KBPS_RUN=$(awk -v bps="$UL_BPS" 'BEGIN { printf "%.0f", (bps * 8) / 1000 }')
        
        if [ "$DL_KBPS_RUN" -gt 0 ] && [ "$UL_KBPS_RUN" -gt 0 ]; then
            DL_SUM=$((DL_SUM + DL_KBPS_RUN))
            UL_SUM=$((UL_SUM + UL_KBPS_RUN))
            DL_PING_SUM=$((DL_PING_SUM + DL_PING_RUN))
            UL_PING_SUM=$((UL_PING_SUM + UL_PING_RUN))
            VALID_RUNS=$((VALID_RUNS + 1))
            log_ok "Result $i: DL: ${DL_KBPS_RUN} Kbps (${DL_PING_RUN}ms) | UL: ${UL_KBPS_RUN} Kbps (${UL_PING_RUN}ms)"
        else
            log_error "Run $i failed (Speed 0)"
        fi
    else
        log_error "Run $i failed (Connection error)"
    fi
done

if [ "$VALID_RUNS" -eq 0 ]; then
    if [ "$SQM_WAS_RUNNING" -eq 1 ]; then 
        log_info "Restoring original SQM configuration..."
        /etc/init.d/sqm start
    fi
    _abort "All speed test iterations failed. Check your internet connection."
fi

# Calculate averages
DL_KBPS=$((DL_SUM / VALID_RUNS))
UL_KBPS=$((UL_SUM / VALID_RUNS))
AVG_DL_PING=$((DL_PING_SUM / VALID_RUNS))
AVG_UL_PING=$((UL_PING_SUM / VALID_RUNS))

# Bufferbloat calculation
DL_BLOAT=$((AVG_DL_PING - IDLE_PING))
[ "$DL_BLOAT" -lt 0 ] && DL_BLOAT=0

UL_BLOAT=$((AVG_UL_PING - IDLE_PING))
[ "$UL_BLOAT" -lt 0 ] && UL_BLOAT=0

log_step "Bufferbloat Analysis ($VALID_RUNS Valid Runs)"
raw_echo "  Idle Ping:      ${IDLE_PING} ms"
raw_echo "  Download Ping:  ${AVG_DL_PING} ms (+${DL_BLOAT} ms bloat)"
raw_echo "  Upload Ping:    ${AVG_UL_PING} ms (+${UL_BLOAT} ms bloat)"

# Dynamic Percentage Calculation based on bloat
calc_pct() {
    local bloat=$1
    if [ "$bloat" -le 10 ]; then echo 95
    elif [ "$bloat" -le 30 ]; then echo 90
    elif [ "$bloat" -le 60 ]; then echo 85
    else echo 80; fi
}

DL_PCT=$(calc_pct "$DL_BLOAT")
UL_PCT=$(calc_pct "$UL_BLOAT")

log_info "Optimal Download SQM Limit: ${DL_PCT}% of Max"
log_info "Optimal Upload SQM Limit:   ${UL_PCT}% of Max"

# Calculate SQM values
SQM_DL_KBPS=$(awk -v kbps="$DL_KBPS" -v pct="$DL_PCT" 'BEGIN { printf "%.0f", kbps * (pct / 100) }')
SQM_UL_KBPS=$(awk -v kbps="$UL_KBPS" -v pct="$UL_PCT" 'BEGIN { printf "%.0f", kbps * (pct / 100) }')

log_step "Checkpoint: CPU Bottleneck Analysis"
RECOMMEND_DISABLE=0

if command -v uci >/dev/null 2>&1 && [ -f /proc/cpuinfo ]; then
    # Running directly on the router
    CPU_MODEL=$(awk -F: '/system type|machine|model name|Hardware/ {print $2; exit}' /proc/cpuinfo | xargs)
    CORES=$(grep -c "^processor" /proc/cpuinfo)
    
    log_info "Detected Router CPU: ${CPU_MODEL} (${CORES} Cores)"
    
    # Very rough estimations for SQM max capability (Kbps)
    case "$CPU_MODEL" in
        *MT798*|*Filogic*) MAX_SQM_KBPS=1000000 ;;
        *IPQ807*|*IPQ601*) MAX_SQM_KBPS=800000 ;;
        *x86*|*Intel*|*AMD*) MAX_SQM_KBPS=2000000 ;;
        *IPQ401*|*IPQ402*) MAX_SQM_KBPS=300000 ;;
        *MT7621*)          MAX_SQM_KBPS=150000 ;;
        *MT76*)            MAX_SQM_KBPS=100000 ;;
        *)
            if [ "$CORES" -ge 4 ]; then MAX_SQM_KBPS=300000
            elif [ "$CORES" -ge 2 ]; then MAX_SQM_KBPS=150000
            else MAX_SQM_KBPS=80000; fi
            ;;
    esac
    
    log_info "Estimated SQM Capability: $((MAX_SQM_KBPS/1000)) Mbps"
    
    if [ "$DL_KBPS" -gt "$MAX_SQM_KBPS" ]; then
        log_warn "Your internet speed ($((DL_KBPS/1000)) Mbps) is FASTER than what this router's CPU can process for SQM ($((MAX_SQM_KBPS/1000)) Mbps)!"
        log_warn "Enabling SQM will likely BOTTLENECK your speeds and max out your router's CPU."
        RECOMMEND_DISABLE=1
    else
        log_ok "Your router CPU can easily handle SQM for this speed."
    fi
else
    # Running on PC (offline mode)
    log_warn "Running offline on PC. Cannot detect router CPU automatically."
    if [ "$DL_KBPS" -gt 250000 ]; then
        log_warn "Your internet speed ($((DL_KBPS/1000)) Mbps) is very fast!"
        log_warn "Standard routers (like MT7621) cannot handle SQM above 150-200 Mbps."
        log_warn "Unless you have a high-end router (ARM quad-core or x86), enabling SQM might bottleneck your speeds."
        RECOMMEND_DISABLE=1
    fi
fi

if [ "$RECOMMEND_DISABLE" -eq 1 ]; then
    log_step "RECOMMENDATION: DISABLE SQM"
    SQM_DL_KBPS=0
    SQM_UL_KBPS=0
    log_info "Suggested Configuration: DL_KBPS=0, UL_KBPS=0 (Disabled)"
else
    log_step "Suggested Dynamic SQM Configuration"
    raw_echo "  SQM Download (DL_KBPS): ${SQM_DL_KBPS} Kbps (at ${DL_PCT}%)"
    raw_echo "  SQM Upload (UL_KBPS):   ${SQM_UL_KBPS} Kbps (at ${UL_PCT}%)"
fi

# Prompt for application
printf "\n"
read -p "Do you want to implement these new calculation values? (y/N): " confirm
case "$confirm" in
    [yY]|[yY][eE][sS])
        log_step "Applying settings..."
        APPLIED=0
        
        # 1. Update setup.conf if it exists in current dir
        if [ -f "./setup.conf" ]; then
            log_info "Updating ./setup.conf..."
            # Replace the existing values in setup.conf
            sed -i "s/^DL_KBPS=.*/DL_KBPS=\"$SQM_DL_KBPS\"/" ./setup.conf
            sed -i "s/^UL_KBPS=.*/UL_KBPS=\"$SQM_UL_KBPS\"/" ./setup.conf
            log_ok "Updated setup.conf successfully."
            APPLIED=1
        fi
        
        # 2. Update live UCI config if running on OpenWrt router
        if command -v uci >/dev/null 2>&1; then
            log_info "Checking live OpenWrt UCI config..."
            if uci -q get sqm.@queue[0] >/dev/null 2>&1; then
                if [ "$SQM_DL_KBPS" = "0" ] && [ "$SQM_UL_KBPS" = "0" ]; then
                    uci set sqm.@queue[0].enabled='0'
                    log_info "Disabled SQM queue in UCI."
                else
                    uci set sqm.@queue[0].enabled='1'
                    uci set sqm.@queue[0].download="$SQM_DL_KBPS"
                    uci set sqm.@queue[0].upload="$SQM_UL_KBPS"
                    uci set sqm.@queue[0].qdisc='cake'
                    uci set sqm.@queue[0].script='piece_of_cake.qos'
                    log_ok "Updated SQM queue parameters in UCI."
                fi
                uci commit sqm
                log_ok "Live UCI configuration saved."
                
                if [ -x "/etc/init.d/sqm" ]; then
                    /etc/init.d/sqm start
                    log_ok "SQM service started successfully with new parameters."
                fi
                APPLIED=1
            else
                log_warn "No SQM queue found in live UCI configuration. Skipping UCI update."
                log_info "Run OpenWrtSetup.sh first to install packages and initialize the interface!"
            fi
        fi
        
        if [ "$APPLIED" -eq 0 ]; then
            log_warn "Could not find ./setup.conf or /sbin/uci. No changes were made."
        fi
        ;;
    *)
        log_info "Operation cancelled by user. No changes were made."
        if [ "$SQM_WAS_RUNNING" -eq 1 ]; then
            log_info "Restoring original SQM service state..."
            /etc/init.d/sqm start
        fi
        ;;
esac

log_ok "Done."
exit 0
