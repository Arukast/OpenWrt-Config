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
# Prefer config values if loaded, else fallback to auto-detection/UCI
CONNECTION_MODE=${CONNECTION_MODE:-""}
if [ -z "$CONNECTION_MODE" ]; then
    if uci -q get network.wwan >/dev/null; then
        CONNECTION_MODE="WISP"
    elif uci -q get network.wan >/dev/null; then
        CONNECTION_MODE="WIRED"
    else
        CONNECTION_MODE="WISP" # fallback
    fi
fi

if [ "$CONNECTION_MODE" = "WIRED" ]; then
    WAN_NAME="wan"
    WAN_IFACE_DEV=${WAN_IFACE:-$(uci -q get network.wan.device || uci -q get network.wan.ifname || echo "eth0")}
else
    WAN_NAME="wwan"
    WAN_IFACE_DEV=${WWAN_IFACE:-$(uci -q get network.wwan.device || echo "phy0-sta0")}
fi

DL_KBPS=${DL_KBPS:-$(uci -q get sqm.@queue[0].download || echo "0")}
UL_KBPS=${UL_KBPS:-$(uci -q get sqm.@queue[0].upload || echo "0")}

# Intelligent auto-detection of active features if no setup.conf was loaded
if [ -z "$ENABLE_WIREGUARD" ]; then
    if uci -q get network.wg0 >/dev/null || [ -f /etc/wireguard/server.key ]; then
        ENABLE_WIREGUARD=1
    else
        ENABLE_WIREGUARD=0
    fi
fi

if [ -z "$ENABLE_TAILSCALE" ]; then
    if command -v tailscale >/dev/null 2>&1 || uci -q get firewall.tailscale >/dev/null; then
        ENABLE_TAILSCALE=1
    else
        ENABLE_TAILSCALE=0
    fi
fi

if [ -z "$ENABLE_WG_DDNS" ]; then
    if uci -q get ddns.duckdns >/dev/null; then
        ENABLE_WG_DDNS=1
    else
        ENABLE_WG_DDNS=0
    fi
fi

if [ -z "${ENABLE_USTEER:-}" ]; then
    if [ -f /etc/init.d/usteer ] || uci -q get usteer.global >/dev/null; then
        ENABLE_USTEER=1
    else
        ENABLE_USTEER=0
    fi
fi

if [ -z "${ENABLE_BANDWIDTH_MONITOR:-}" ]; then
    if [ -f /etc/init.d/vnstat ] || uci -q get vnstat >/dev/null; then
        ENABLE_BANDWIDTH_MONITOR=1
    else
        ENABLE_BANDWIDTH_MONITOR=0
    fi
fi

if [ -z "${ENABLE_TRAFFIC_MONITOR:-}" ]; then
    if [ -f /etc/init.d/nlbwmon ] || uci -q get nlbwmon >/dev/null; then
        ENABLE_TRAFFIC_MONITOR=1
    else
        ENABLE_TRAFFIC_MONITOR=0
    fi
fi


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
if [ "${ENABLE_USTEER:-1}" = "1" ]; then
    pkgs="$pkgs usteer luci-app-usteer"
fi
if [ "${ENABLE_TRAFFIC_MONITOR:-1}" = "1" ]; then
    pkgs="$pkgs luci-app-nlbwmon"
fi

missing=""
for p in $pkgs; do
    if ! apk info "$p" >/dev/null 2>&1 && ! opkg status "$p" >/dev/null 2>&1; then
        missing="$missing $p"
    fi
done

# Special check for Bandwidth Monitor package variations (vnstat/vnstat2, vnstati/vnstati2, luci-app-vnstat/luci-app-vnstat2)
if [ "${ENABLE_BANDWIDTH_MONITOR:-1}" = "1" ]; then
    vnstat_ok=0
    for p in vnstat2 vnstat; do
        if apk info "$p" >/dev/null 2>&1 || opkg status "$p" >/dev/null 2>&1; then
            vnstat_ok=1
            break
        fi
    done
    vnstati_ok=0
    for p in vnstati2 vnstati; do
        if apk info "$p" >/dev/null 2>&1 || opkg status "$p" >/dev/null 2>&1; then
            vnstati_ok=1
            break
        fi
    done
    luci_vnstat_ok=0
    for p in luci-app-vnstat2 luci-app-vnstat; do
        if apk info "$p" >/dev/null 2>&1 || opkg status "$p" >/dev/null 2>&1; then
            luci_vnstat_ok=1
            break
        fi
    done

    [ "$vnstat_ok" = "0" ] && missing="$missing vnstat"
    [ "$vnstati_ok" = "0" ] && missing="$missing vnstati"
    [ "$luci_vnstat_ok" = "0" ] && missing="$missing luci-app-vnstat"
fi

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
        fail "ZRAM enabled but /dev/zram0 not found" "/etc/init.d/zram restart"
    fi
fi

# Monthly reboot every 1st of the month at 03:00 (with bootloop safety trick)
if grep -Fq "0 3 1 * * sleep 70 && touch /etc/banner && reboot" /etc/crontabs/root 2>/dev/null; then
    pass "Monthly reboot cron job is configured"
else
    warn "Monthly reboot cron job is missing" "Check crontab for '0 3 1 * * sleep 70 && touch /etc/banner && reboot'"
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

# Usteer Service Check
if [ "${ENABLE_USTEER:-1}" = "1" ]; then
    if [ -f /etc/init.d/usteer ]; then
        if /etc/init.d/usteer status >/dev/null 2>&1 || pgrep usteer >/dev/null 2>&1; then
            pass "usteer service is running"
        else
            warn "usteer installed but not running" "/etc/init.d/usteer start"
        fi
    else
        warn "usteer is not installed" "Check setup script execution"
    fi
fi

# vnStat Service Check
if [ "${ENABLE_BANDWIDTH_MONITOR:-1}" = "1" ]; then
    if [ -f /etc/init.d/vnstat ]; then
        if /etc/init.d/vnstat status >/dev/null 2>&1 || pgrep vnstatd >/dev/null 2>&1; then
            pass "vnstat service is running"
        else
            warn "vnstat installed but not running" "/etc/init.d/vnstat start"
        fi
    else
        warn "vnstat is not installed" "Check setup script execution"
    fi
fi

# nlbwmon Service Check
if [ "${ENABLE_TRAFFIC_MONITOR:-1}" = "1" ]; then
    if [ -f /etc/init.d/nlbwmon ]; then
        if /etc/init.d/nlbwmon status >/dev/null 2>&1 || pgrep nlbwmon >/dev/null 2>&1; then
            pass "nlbwmon service is running"
        else
            warn "nlbwmon installed but not running" "/etc/init.d/nlbwmon start"
        fi
    else
        warn "nlbwmon is not installed" "Check setup script execution"
    fi
fi

# =============================================================================
# 2. NETWORK CONNECTIVITY
# =============================================================================
section "2. Network Connectivity"

# WAN interface
if uci -q get network.$WAN_NAME >/dev/null; then
    pass "$WAN_NAME interface defined"
else
    fail "$WAN_NAME interface not found" "Run setup script"
fi

wan_ip=$(ifstatus $WAN_NAME 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
if [ -n "$wan_ip" ]; then
    pass "$WAN_NAME IP: $wan_ip"
else
    if [ "$CONNECTION_MODE" = "WIRED" ]; then
        fail "$WAN_NAME has NO IP address" "Check Ethernet cable and upstream DHCP server"
    else
        fail "$WAN_NAME has NO IP address" "wifi reload && ifup wwan"
    fi
fi

if ip route show default | grep -qc "$WAN_IFACE_DEV"; then
    pass "Default route via $WAN_IFACE_DEV"
else
    warn "Default route is NOT via $WAN_IFACE_DEV" "ip route"
fi

if ping -c2 -W2 8.8.8.8 >/dev/null 2>&1; then
    pass "Internet ping OK"
else
    fail "Internet ping FAILED" "Check WISP connection and routing"
fi

lan_subnet=$(ip route | awk '/dev br-lan/{print $1}' | head -1)
wan_subnet=$(ip route | awk "/dev $WAN_IFACE_DEV/{print \$1}" | head -1)
if [ -n "$lan_subnet" ] && [ -n "$wan_subnet" ] && [ "$lan_subnet" = "$wan_subnet" ]; then
    fail "SUBNET CONFLICT: LAN == WAN ($lan_subnet)" "Change LAN IP to a different subnet"
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

if [ "$CONNECTION_MODE" = "WISP" ]; then
    sta_up=$(iw dev 2>/dev/null | grep -c "type managed")
    if [ "$sta_up" -ge 1 ]; then
        pass "$sta_up STA (upstream) interface(s) active"
    else
        warn "No STA interface found" "Check WISP config"
    fi
else
    pass "Wired mode: Upstream STA interface check skipped"
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

tc_out=$(tc qdisc show dev "$WAN_IFACE_DEV" 2>/dev/null)
if echo "$tc_out" | grep -qi "cake"; then
    pass "CAKE qdisc active on $WAN_IFACE_DEV"
else
    fail "CAKE qdisc NOT active" "/etc/init.d/sqm restart"
fi

# =============================================================================
# 5. DNS DoH
# =============================================================================
section "5. DNS DoH"

_ports_checked=0
for r in $(uci show https-dns-proxy 2>/dev/null | grep "=https-dns-proxy$" | awk -F'=' '{print $1}'); do
    port=$(uci -q get ${r}.listen_port || true)
    if [ -n "$port" ]; then
        _ports_checked=$((_ports_checked + 1))
        if netstat -lnup 2>/dev/null | grep -q ":${port}"; then
            pass "https-dns-proxy listening on :${port}"
        else
            fail "https-dns-proxy not listening on :${port}" "/etc/init.d/https-dns-proxy restart"
        fi
    fi
done

if [ "$_ports_checked" -eq 0 ]; then
    fail "No https-dns-proxy configurations found in UCI" "/etc/init.d/https-dns-proxy start"
fi

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

# DNSmasq Hardening Checks
if [ "$(uci -q get dhcp.@dnsmasq[0].localservice)" = "1" ]; then
    pass "DNSmasq localservice is enabled (secure default)"
else
    fail "DNSmasq localservice is disabled (vulnerable to open resolver)" "uci set dhcp.@dnsmasq[0].localservice='1' && uci commit dhcp && /etc/init.d/dnsmasq restart"
fi

_has_lan=0
_has_wg0=0
for iface in $(uci -q get dhcp.@dnsmasq[0].interface || echo "none"); do
    [ "$iface" = "lan" ] && _has_lan=1
    [ "$iface" = "wg0" ] && _has_wg0=1
done
if [ "$_has_lan" -eq 1 ] && [ "$_has_wg0" -eq 1 ]; then
    pass "DNSmasq is explicitly listening on authorized interfaces (lan, wg0)"
else
    fail "DNSmasq is not listening explicitly on lan and wg0 interfaces" "Run setup script"
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

# DNS Hijack Check
_dns_redirect_ipv4=0
_dns_redirect_ipv6=0
for r in $(uci show firewall 2>/dev/null | grep "=redirect$" | awk -F'=' '{print $1}'); do
    name=$(uci -q get ${r}.name || true)
    target=$(uci -q get ${r}.target || true)
    src=$(uci -q get ${r}.src || true)
    src_dport=$(uci -q get ${r}.src_dport || true)
    dest_port=$(uci -q get ${r}.dest_port || true)
    family=$(uci -q get ${r}.family || true)
    if [ "$name" = "Intercept-DNS" ] && [ "$target" = "DNAT" ] && [ "$src" = "lan" ] && [ "$src_dport" = "53" ] && [ "$dest_port" = "53" ]; then
        _dns_redirect_ipv4=1
    elif [ "$name" = "Intercept-DNS-IPv6" ] && [ "$target" = "DNAT" ] && [ "$src" = "lan" ] && [ "$src_dport" = "53" ] && [ "$dest_port" = "53" ] && [ "$family" = "ipv6" ]; then
        _dns_redirect_ipv6=1
    fi
done

if [ "$_dns_redirect_ipv4" -eq 1 ]; then
    pass "IPv4 DNS hijacking (Intercept-DNS) redirect rule configured"
else
    warn "IPv4 DNS hijacking redirect rule NOT configured (vulnerable to DNS leaks)" "Run setup script to configure Intercept-DNS"
fi

if [ "${ENABLE_IPV6:-1}" = "1" ]; then
    if [ "$_dns_redirect_ipv6" -eq 1 ]; then
        pass "IPv6 DNS hijacking (Intercept-DNS-IPv6) redirect rule configured"
    else
        warn "IPv6 DNS hijacking redirect rule NOT configured (vulnerable to DNS leaks)" "Run setup script to configure Intercept-DNS-IPv6"
    fi
fi

# DoT Blocking Check
_dot_blocked=0
for r in $(uci show firewall 2>/dev/null | grep "=rule$" | awk -F'=' '{print $1}'); do
    name=$(uci -q get ${r}.name || true)
    src=$(uci -q get ${r}.src || true)
    dest=$(uci -q get ${r}.dest || true)
    dest_port=$(uci -q get ${r}.dest_port || true)
    target=$(uci -q get ${r}.target || true)
    if [ "$name" = "Block-DoT" ] && [ "$src" = "lan" ] && [ "$dest" = "wan" ] && [ "$dest_port" = "853" ] && [ "$target" = "REJECT" ]; then
        _dot_blocked=1
        break
    fi
done

if [ "$_dot_blocked" -eq 1 ]; then
    pass "DNS-over-TLS (DoT) blocking rule configured"
else
    warn "DoT blocking rule NOT configured (clients can bypass local DNS/adblock)" "Run setup script to configure Block-DoT"
fi


# =============================================================================
# 7. TAILSCALE
# =============================================================================
section "7. Tailscale"

if [ "${ENABLE_TAILSCALE:-1}" = "1" ]; then
    if command -v tailscale >/dev/null 2>&1; then
        ts_status=$(tailscale status 2>&1 | head -1)
        if echo "$ts_status" | grep -qi "logged out\|not logged"; then
            warn "Tailscale not logged in" "tailscale up --accept-dns=false"
        elif echo "$ts_status" | grep -qi "stopped\|error"; then
            fail "Tailscale status error: $ts_status" "/etc/init.d/tailscale restart"
        else
            pass "Tailscale active: $ts_status"
            
            # Check if Tailscale MagicDNS is hijacking system/resolver DNS
            if grep -q "100.100.100.100" /etc/resolv.conf 2>/dev/null || grep -q "100.100.100.100" /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null; then
                fail "Tailscale MagicDNS is hijacking router DNS (accept-dns is true)" "tailscale up --accept-dns=false --reset && /etc/init.d/dnsmasq restart"
            else
                pass "Tailscale DNS hijacking is disabled (accept-dns is false)"
            fi
        fi
    else
        warn "Tailscale not installed" "apk add tailscale"
    fi
fi

# =============================================================================
# 8. IPv6
# =============================================================================
section "8. IPv6"

if [ "${ENABLE_IPV6:-1}" = "1" ]; then
    ula=$(uci -q get network.globals.ula_prefix 2>/dev/null)
    if [ -z "$ula" ]; then
        pass "IPv6 ULA prefix is disabled (Prevents LAN routing confusion)"
    else
        warn "IPv6 ULA prefix still exists ($ula)" "uci delete network.globals.ula_prefix && uci commit network"
    fi

    # Check static LAN IPv6 ULA address configuration
    lan_ip6=$(uci -q get network.lan.ip6addr | grep "fd11:2233:4455::1" || true)
    if [ -n "$lan_ip6" ]; then
        pass "LAN interface has static ULA IPv6 address (fd11:2233:4455::1)"
    else
        fail "LAN interface lacks static ULA IPv6 address" "Run setup script"
    fi

    # Check DHCPv6 DNS advertisement
    lan_dns=$(uci -q get dhcp.lan.dns | grep "fd11:2233:4455::1" || true)
    if [ -n "$lan_dns" ]; then
        pass "DHCPv6 DNS advertisements point to secure local ULA resolver"
    else
        fail "DHCPv6 DNS advertisements do not point to ULA resolver" "Run setup script"
    fi

    if [ "$CONNECTION_MODE" = "WIRED" ]; then
        WAN6_NAME="wan6"
    else
        WAN6_NAME="wwan6"
    fi

    if uci -q get network.$WAN6_NAME >/dev/null; then
        pass "$WAN6_NAME interface defined"
    else
        warn "$WAN6_NAME interface not found" "Run setup script"
    fi

    wan6_ip=$(ifstatus $WAN6_NAME 2>/dev/null | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null)
    if [ -n "$wan6_ip" ]; then
        pass "$WAN6_NAME IPv6: $wan6_ip"
    else
        warn "$WAN6_NAME has NO IPv6 address" "Check upstream IPv6 support"
    fi

    if ping -6 -c2 -W2 2606:4700:4700::1111 >/dev/null 2>&1; then
        pass "IPv6 Internet ping OK"
    else
        warn "IPv6 Internet ping FAILED" "Check upstream IPv6 connectivity"
    fi
else
    pass "IPv6 is disabled"
fi

# =============================================================================
# 9. WIREGUARD VPN & DDNS
# =============================================================================
section "9. WireGuard VPN & DDNS"

WG_CLIENTS=${WG_CLIENTS:-"phone laptop"}

if [ "${ENABLE_WIREGUARD:-1}" = "1" ]; then
    # Check packages
    missing_wg=""
    for p in wireguard-tools luci-proto-wireguard qrencode; do
        if ! apk info "$p" >/dev/null 2>&1 && ! opkg status "$p" >/dev/null 2>&1; then
            missing_wg="$missing_wg $p"
        fi
    done
    if [ -n "$missing_wg" ]; then
        fail "Missing WireGuard packages:$missing_wg" "apk add$missing_wg"
    else
        pass "Required WireGuard packages installed"
    fi

    # Check key files
    if [ -f /etc/wireguard/server.key ] && [ -f /etc/wireguard/server.pub ]; then
        pass "WireGuard server keys exist"
    else
        fail "WireGuard server keys missing" "Run OpenWrtSetup.sh"
    fi

    # Check interface
    if uci -q get network.wg0 >/dev/null; then
        pass "network.wg0 interface defined in UCI"
    else
        fail "network.wg0 interface NOT defined" "Run OpenWrtSetup.sh"
    fi

    # Check firewall zone
    _wg_fwd=0
    for fwd in $(uci show firewall 2>/dev/null | grep "=forwarding$" | awk -F'=' '{print $1}'); do
        src=$(uci -q get ${fwd}.src || true)
        dest=$(uci -q get ${fwd}.dest || true)
        if [ "$src" = "wg" ] || [ "$dest" = "wg" ]; then
            _wg_fwd=$((_wg_fwd + 1))
        fi
    done
    if [ "$_wg_fwd" -ge 2 ]; then
        pass "Firewall zone 'wg' with forwarding rules exists"
    else
        fail "Firewall rules for zone 'wg' are missing or incomplete" "Run OpenWrtSetup.sh"
    fi

    # Check open UDP port
    _port_open=0
    WG_PORT=${WG_PORT:-"51820"}
    for r in $(uci show firewall 2>/dev/null | grep "=rule$" | awk -F'=' '{print $1}'); do
        name=$(uci -q get ${r}.name || true)
        target=$(uci -q get ${r}.target || true)
        dest_port=$(uci -q get ${r}.dest_port || true)
        if [ "$name" = "Allow-WireGuard-IPv6" ] && [ "$target" = "ACCEPT" ] && [ "$dest_port" = "$WG_PORT" ]; then
            _port_open=1
            break
        fi
    done
    if [ "$_port_open" -ge 1 ]; then
        pass "WAN incoming WireGuard IPv6 UDP port rule exists"
    else
        fail "WAN incoming WireGuard IPv6 port rule NOT configured" "Check setup firewall"
    fi

    # Check client profiles
    _client_files_exist=1
    for c in $WG_CLIENTS; do
        if [ ! -f "/etc/wireguard/clients/${c}_split.conf" ] || [ ! -f "/etc/wireguard/clients/${c}_full.conf" ]; then
            _client_files_exist=0
            break
        fi
    done
    if [ "$_client_files_exist" -eq 1 ]; then
        pass "Configured client peer profiles generated successfully ($WG_CLIENTS)"
    else
        warn "Some client peer profiles are missing in /etc/wireguard/clients/" "Check setup execution logs"
    fi
else
    pass "WireGuard is disabled"
fi

if [ "${ENABLE_WG_DDNS:-0}" = "1" ]; then
    if uci -q get ddns.duckdns >/dev/null; then
        if [ "$(uci -q get ddns.duckdns.enabled)" = "1" ]; then
            pass "DuckDNS DDNS updater service is configured and enabled"
        else
            warn "DuckDNS DDNS is configured but disabled in UCI" "uci set ddns.duckdns.enabled='1' && uci commit ddns"
        fi
    else
        fail "DuckDNS DDNS service config is missing" "Run OpenWrtSetup.sh"
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