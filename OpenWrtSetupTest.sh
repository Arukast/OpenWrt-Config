#!/bin/sh
# =============================================================================
#  OpenWrt Post-Setup Verification Script
#  Usage: sh /tmp/verify.sh [--json] [--config file.conf]
# =============================================================================

# --- Arguments ---
JSON_OUT=0
CONFIG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON_OUT=1 ;;
        --config)
            CONFIG_FILE="$2"
            shift
            ;;
    esac
    shift
done

# --- Load Config (Optional, to verify expected state) ---
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "./setup.conf" ]; then
        CONFIG_FILE="./setup.conf"
    elif [ -f "/etc/openwrt-setup.conf" ]; then
        CONFIG_FILE="/etc/openwrt-setup.conf"
    fi
fi

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

# --- Colors ---
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

START_TIME=$(date +%s)
PASS=0; FAIL=0; WARN=0
RESULTS=""

_add_result() {
    local status="$1"
    local msg="$2"
    local fix="$3"
    
    if [ "$JSON_OUT" = "1" ]; then
        # Escape quotes
        msg=$(echo "$msg" | sed 's/"/\\"/g' | tr -d '\n')
        fix=$(echo "$fix" | sed 's/"/\\"/g' | tr -d '\n')
        [ -n "$RESULTS" ] && RESULTS="$RESULTS,"
        RESULTS="$RESULTS{\"status\":\"$status\",\"message\":\"$msg\",\"fix\":\"$fix\"}"
    fi

    if [ "$status" = "PASS" ]; then
        PASS=$((PASS+1))
        [ "$JSON_OUT" = "0" ] && printf "  ${GREEN}[PASS]${NC} %s\n" "$msg"
    elif [ "$status" = "FAIL" ]; then
        FAIL=$((FAIL+1))
        if [ "$JSON_OUT" = "0" ]; then
            printf "  ${RED}[FAIL]${NC} %s\n" "$msg"
            [ -n "$fix" ] && printf "         ${CYAN}Fix:${NC} %s\n" "$fix"
        fi
    elif [ "$status" = "WARN" ]; then
        WARN=$((WARN+1))
        if [ "$JSON_OUT" = "0" ]; then
            printf "${YELLOW}[WARN]${NC} %s\n" "$msg"
            [ -n "$fix" ] && printf "       ${CYAN}Fix:${NC} %s\n" "$fix"
        fi
    fi
}

pass() { _add_result "PASS" "$1" ""; }
fail() { _add_result "FAIL" "$1" "$2"; }
warn() { _add_result "WARN" "$1" "$2"; }
section() { [ "$JSON_OUT" = "0" ] && printf "\n${BOLD}━━━ %s ━━━${NC}\n" "$1"; }

# =============================================================================
# Initialization
# =============================================================================
# Prefer config values if loaded, else fallback to UCI
WWAN_IFACE=${WWAN_IFACE:-$(uci -q get network.wwan.device || echo "phy0-sta0")}
DL_KBPS=${DL_KBPS:-$(uci -q get sqm.@queue[0].download || echo "0")}
UL_KBPS=${UL_KBPS:-$(uci -q get sqm.@queue[0].upload || echo "0")}
DOH_PORT1=${DOH_PRIMARY_PORT:-$(uci -q get https-dns-proxy.@https-dns-proxy[0].listen_port || echo "5053")}
DOH_PORT2=${DOH_SECONDARY_PORT:-$(uci -q get https-dns-proxy.@https-dns-proxy[1].listen_port || echo "5054")}

if [ "$JSON_OUT" = "0" ]; then
    printf "\n${BOLD}============================================================${NC}\n"
    printf "${BOLD}  OpenWrt Setup Verification${NC}\n"
    printf "  Date   : $(date)\n"
    printf "  Host   : $(uname -n)\n"
    printf "  Uptime : $(uptime | awk -F'( |,|:)+' '{print $6" days, "$8" hours, "$9" mins"}')\n"
    [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] && printf "  Config : Loaded from %s\n" "$CONFIG_FILE"
    printf "${BOLD}============================================================${NC}\n"
fi

# =============================================================================
# 1. SYSTEM
# =============================================================================
section "1. System"

# NTP Check
current_year=$(date +%Y)
if [ "$current_year" -lt 2024 ]; then
    fail "System clock is incorrect (Year $current_year)" "ntpd -q -p pool.ntp.org"
else
    pass "System clock is sane ($current_year)"
fi

# Storage Check
if df /overlay 2>/dev/null | grep -q overlay; then
    # Improved robust parsing for different df outputs
    overlay_use=$(df /overlay | tail -n 1 | awk '{print $(NF-1)}' | tr -d '%')
    if [ -n "$overlay_use" ] && [ "$overlay_use" -eq "$overlay_use" ] 2>/dev/null; then
        if [ "$overlay_use" -gt 85 ]; then
            warn "/overlay is ${overlay_use}%% full" "Clean up unused packages or logs in /overlay"
        else
            pass "/overlay storage is healthy (${overlay_use}%% used)"
        fi
    else
        warn "Could not parse /overlay usage properly" ""
    fi
else
    warn "/overlay partition not found" "Check mount points"
fi

# Packages
pkgs="sqm-scripts kmod-sched-cake https-dns-proxy watchcat curl"
missing=""
for p in $pkgs; do
    if ! apk info "$p" >/dev/null 2>&1 && ! opkg status "$p" >/dev/null 2>&1; then
        missing="$missing $p"
    fi
done
if [ -n "$missing" ]; then
    fail "Missing packages:$missing" "apk add$missing"
else
    pass "Required packages installed"
fi

# ZRAM Check
if [ "${ZRAM_MB:-0}" -gt 0 ] || lsmod | grep -q zram; then
    if [ -b /dev/zram0 ]; then
        zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
        zram_mb=$(( zram_size / 1024 / 1024 ))
        pass "ZRAM active (${zram_mb}MB)"
    else
        fail "ZRAM enabled but /dev/zram0 not found" "/etc/init.d/zram-setup restart"
    fi
fi

# Weekly reboot every Sunday at 03:00
if grep -Fq "0 3 * * 0 reboot" /etc/crontabs/root 2>/dev/null; then
    pass "Weekly reboot cron job is configured"
else
    warn "Weekly reboot cron job is missing" "Check crontab for '0 3 * * 0 reboot'"
fi

# Adblock-lean Check
if [ "${ENABLE_ADBLOCK_LEAN:-1}" = "1" ]; then
    if [ -f /etc/init.d/adblock-lean ]; then
        if /etc/init.d/adblock-lean status >/dev/null 2>&1; then
            pass "adblock-lean service is running"
        else
            warn "adblock-lean installed but not running" "/etc/init.d/adblock-lean start"
        fi
    else
        warn "adblock-lean is not installed" "Check setup script execution"
    fi
fi

# =============================================================================
# 2. NETWORK CONNECTIVITY
# =============================================================================
section "2. Network Connectivity"

# wwan interface
if uci -q get network.wwan >/dev/null; then
    pass "wwan interface defined"
else
    fail "wwan interface not found" "Run setup script"
fi

wwan_ip=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
if [ -n "$wwan_ip" ]; then
    pass "wwan IP: $wwan_ip"
else
    fail "wwan has NO IP address" "wifi reload && ifup wwan"
fi

if ip route show default | grep -qc "$WWAN_IFACE"; then
    pass "Default route via $WWAN_IFACE"
else
    warn "Default route is NOT via $WWAN_IFACE" "ip route"
fi

if ping -c2 -W2 8.8.8.8 >/dev/null 2>&1; then
    pass "Internet ping OK"
else
    fail "Internet ping FAILED" "Check WISP connection and routing"
fi

lan_subnet=$(ip route | awk '/dev br-lan/{print $1}' | head -1)
wwan_subnet=$(ip route | awk "/dev $WWAN_IFACE/{print \$1}" | head -1)
if [ -n "$lan_subnet" ] && [ -n "$wwan_subnet" ] && [ "$lan_subnet" = "$wwan_subnet" ]; then
    fail "SUBNET CONFLICT: LAN == WWAN ($lan_subnet)" "Change LAN IP to a different subnet"
else
    pass "No subnet conflict"
fi

# =============================================================================
# 3. WIRELESS
# =============================================================================
section "3. Wireless"

ap_up=$(iw dev 2>/dev/null | grep -c "type AP")
if [ "$ap_up" -ge 1 ]; then
    pass "$ap_up AP interface(s) active"
else
    fail "No AP interfaces active" "wifi reload"
fi

sta_up=$(iw dev 2>/dev/null | grep -c "type managed")
if [ "$sta_up" -ge 1 ]; then
    pass "$sta_up STA (upstream) interface(s) active"
else
    warn "No STA interface found" "Check WISP config"
fi

# =============================================================================
# 4. SQM CAKE
# =============================================================================
section "4. SQM CAKE"

if [ "$(uci -q get sqm.@queue[0].enabled)" = "1" ]; then
    pass "SQM enabled in UCI ($DL_KBPS / $UL_KBPS kbps)"
else
    fail "SQM not enabled in UCI" "uci set sqm.@queue[0].enabled='1' && uci commit sqm"
fi

tc_out=$(tc qdisc show dev "$WWAN_IFACE" 2>/dev/null)
if echo "$tc_out" | grep -qi "cake"; then
    pass "CAKE qdisc active on $WWAN_IFACE"
else
    fail "CAKE qdisc NOT active" "/etc/init.d/sqm restart"
fi

# =============================================================================
# 5. DNS DoH
# =============================================================================
section "5. DNS DoH"

for port in $DOH_PORT1 $DOH_PORT2; do
    if netstat -lnup 2>/dev/null | grep -q ":${port}"; then
        pass "https-dns-proxy listening on :${port}"
    else
        fail "https-dns-proxy not listening on :${port}" "/etc/init.d/https-dns-proxy restart"
    fi
done

if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    pass "DNS resolution via DoH OK"
else
    fail "DNS resolution FAILED" "Check internet or https-dns-proxy logs"
fi

if nslookup use-application-dns.net 127.0.0.1 2>&1 | grep -q "0.0.0.0\|NXDOMAIN\|can't resolve"; then
    pass "DoH canary blocked"
else
    warn "DoH canary NOT blocked" "Add address=/use-application-dns.net/ to dnsmasq"
fi

# =============================================================================
# 6. FIREWALL
# =============================================================================
section "6. Firewall"

lan_wan_fwd=0
for fwd in $(uci show firewall 2>/dev/null | grep "=forwarding$" | awk -F'=' '{print $1}'); do
    src=$(uci -q get ${fwd}.src)
    dest=$(uci -q get ${fwd}.dest)
    if [ "$src" = "lan" ] && { [ "$dest" = "wan" ] || [ "$dest" = "wwan" ]; }; then
        lan_wan_fwd=1
        break
    fi
done

if [ "$lan_wan_fwd" -eq 1 ]; then
    pass "LAN -> WAN forwarding OK"
else
    warn "LAN -> WAN forwarding missing" "Check firewall zones"
fi

# =============================================================================
# 7. TAILSCALE
# =============================================================================
section "7. Tailscale"

if [ "${ENABLE_TAILSCALE:-1}" = "1" ]; then
    if command -v tailscale >/dev/null 2>&1; then
        ts_status=$(tailscale status 2>&1 | head -1)
        if echo "$ts_status" | grep -qi "logged out\|not logged"; then
            warn "Tailscale not logged in" "tailscale up --accept-routes"
        elif echo "$ts_status" | grep -qi "stopped\|error"; then
            fail "Tailscale status error: $ts_status" "/etc/init.d/tailscale restart"
        else
            pass "Tailscale active: $ts_status"
        fi
    else
        warn "Tailscale not installed" "apk add tailscale"
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS + FAIL + WARN))
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ "$JSON_OUT" = "1" ]; then
    printf "{\"summary\":{\"total\":%d,\"pass\":%d,\"fail\":%d,\"warn\":%d,\"elapsed_sec\":%d},\"results\":[%s]}\n" "$TOTAL" "$PASS" "$FAIL" "$WARN" "$ELAPSED" "$RESULTS"
else
    printf "\n${BOLD}============================================================${NC}\n"
    printf "${BOLD}  VERIFICATION SUMMARY (took %ds)${NC}\n" "$ELAPSED"
    printf "${BOLD}============================================================${NC}\n"
    printf "  Total checks : %s\n" "$TOTAL"
    printf "  ${GREEN}PASS${NC}          : %s\n" "$PASS"
    printf "  ${RED}FAIL${NC}          : %s\n" "$FAIL"
    printf "  ${YELLOW}WARN${NC}          : %s\n" "$WARN"
    printf "${BOLD}============================================================${NC}\n"

    if [ "$FAIL" -gt 0 ]; then
        printf "\n${RED}${BOLD}  ACTION REQUIRED: %s check(s) failed. See suggested fixes above.${NC}\n\n" "$FAIL"
        exit 1
    elif [ "$WARN" -gt 0 ]; then
        printf "\n${YELLOW}  Setup looks good but %s item(s) need attention.${NC}\n\n" "$WARN"
        exit 0
    else
        printf "\n${GREEN}${BOLD}  All checks passed!${NC}\n\n"
        exit 0
    fi
fi