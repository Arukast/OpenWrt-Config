#!/bin/sh
# =============================================================================
#  OpenWrt Post-Setup Verification Script
#  Run after OpenWrtSetup.sh + reboot to confirm everything is working.
#  Usage: sh /tmp/verify.sh
# =============================================================================

# --- Colors ---
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { printf "  ${GREEN}[PASS]${NC} %s\n" "$*";  PASS=$((PASS+1)); }
fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$*";  FAIL=$((FAIL+1)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*";  WARN=$((WARN+1)); }
section() { printf "\n${BOLD}━━━ %s ━━━${NC}\n" "$*"; }

# =============================================================================
# Read configuration from UCI (mirrors Part 0 of the setup script)
# =============================================================================
WWAN_IFACE=$(uci -q get network.wwan.device || echo "phy0-sta0")
DL_KBPS=$(uci -q get sqm.@queue[0].download  || echo "0")
UL_KBPS=$(uci -q get sqm.@queue[0].upload    || echo "0")
DOH_PORT1=$(uci -q get https-dns-proxy.@https-dns-proxy[0].listen_port || echo "5053")
DOH_PORT2=$(uci -q get https-dns-proxy.@https-dns-proxy[1].listen_port || echo "5054")

printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}  OpenWrt Setup Verification${NC}\n"
printf "  Date : $(date)\n"
printf "  Host : $(uname -n)\n"
printf "${BOLD}============================================================${NC}\n"

# =============================================================================
# 1. NETWORK CONNECTIVITY
# =============================================================================
section "1. Network Connectivity"

# wwan interface up?
wwan_up=$(uci -q get network.wwan.proto 2>/dev/null)
if [ -n "$wwan_up" ]; then
    pass "wwan interface defined in UCI (proto: $wwan_up)"
else
    fail "wwan interface not found in UCI"
fi

# wwan got an IP?
wwan_ip=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
if [ -n "$wwan_ip" ]; then
    pass "wwan has IP address: $wwan_ip"
else
    fail "wwan has NO IP address — interface may be down"
fi

# Default route via wwan?
route_ok=$(ip route show default | grep -c "$WWAN_IFACE")
if [ "$route_ok" -ge 1 ]; then
    pass "Default route via $WWAN_IFACE"
else
    warn "Default route does not go via $WWAN_IFACE — check: ip route"
fi

# Ping test
if ping -c2 -W2 8.8.8.8 >/dev/null 2>&1; then
    rtt=$(ping -c2 -W2 8.8.8.8 2>/dev/null | awk -F'/' '/round-trip/{print $5}')
    pass "Internet ping OK — avg RTT: ${rtt}ms"
else
    fail "Ping to 8.8.8.8 FAILED — no internet connectivity"
fi

# Subnet conflict check
lan_subnet=$(ip route | awk '/dev br-lan/{print $1}' | head -1)
wwan_subnet=$(ip route | awk "/dev $WWAN_IFACE/{print \$1}" | head -1)
if [ -n "$lan_subnet" ] && [ -n "$wwan_subnet" ] && [ "$lan_subnet" = "$wwan_subnet" ]; then
    fail "SUBNET CONFLICT: LAN ($lan_subnet) == WWAN ($wwan_subnet) — routing is broken!"
else
    pass "No LAN/WWAN subnet conflict detected"
fi

# MTU
mtu_val=$(ip link show "$WWAN_IFACE" 2>/dev/null | awk '/mtu/{print $5}')
if [ -n "$mtu_val" ]; then
    pass "WWAN MTU: $mtu_val"
else
    warn "Could not read MTU for $WWAN_IFACE"
fi

# =============================================================================
# 2. WIRELESS
# =============================================================================
section "2. Wireless"

# Any AP interface up?
ap_up=$(iw dev 2>/dev/null | grep -c "type AP")
if [ "$ap_up" -ge 1 ]; then
    pass "$ap_up AP interface(s) active"
else
    fail "No AP interfaces active — run: wifi reload"
fi

# STA (upstream) interface up?
sta_up=$(iw dev 2>/dev/null | grep -c "type managed")
if [ "$sta_up" -ge 1 ]; then
    pass "$sta_up STA (upstream) interface(s) active"
else
    warn "No STA interface found — WISP upstream may not be connected"
fi

# SAE / WPA3 encryption on APs
sae_count=0
for iface in $(uci show wireless | grep "mode='ap'" | awk -F'.' '{print $2}'); do
    enc=$(uci -q get wireless.${iface}.encryption)
    if echo "$enc" | grep -qi "sae"; then
        sae_count=$((sae_count+1))
    fi
done
if [ "$sae_count" -ge 1 ]; then
    pass "SAE/WPA3 encryption active on $sae_count AP(s)"
else
    warn "SAE encryption not detected on any AP — check: uci show wireless | grep encryption"
fi

# Country code
country_2g=$(uci -q get wireless.radio0.country)
if [ -n "$country_2g" ]; then
    pass "Country code set: $country_2g"
else
    warn "Country code not set on radio0"
fi

# =============================================================================
# 3. SQM CAKE
# =============================================================================
section "3. SQM / CAKE"

# UCI enabled?
sqm_enabled=$(uci -q get sqm.@queue[0].enabled)
if [ "$sqm_enabled" = "1" ]; then
    pass "SQM is enabled in UCI (DL: ${DL_KBPS} kbps / UL: ${UL_KBPS} kbps)"
else
    fail "SQM is NOT enabled in UCI"
fi

# Active qdisc on the interface?
tc_out=$(tc qdisc show dev "$WWAN_IFACE" 2>/dev/null)
if echo "$tc_out" | grep -qi "cake"; then
    pass "CAKE qdisc active on $WWAN_IFACE"
    
    # Safely extract bandwidth and convert to kbps using awk
    tc_bw=$(echo "$tc_out" | grep -i "bandwidth" | awk '{
        for(i=1; i<=NF; i++) {
            if($i == "bandwidth") {
                val = $(i+1);
                mult = 1;
                
                # Determine multiplier based on unit suffix
                if (val ~ /[Mm]bit/) mult = 1000;
                else if (val ~ /[Kk]bit/) mult = 1;
                else if (val ~ /bit/ && val !~ /[MmKk]bit/) mult = 0.001;
                
                # Strip all letters and multiply
                gsub(/[A-Za-z]/, "", val);
                print int(val * mult);
            }
        }
    }' | head -n 1)

    if [ "$tc_bw" = "$UL_KBPS" ]; then
        pass "CAKE bandwidth matches UCI setting (${UL_KBPS} kbps)"
    else
        warn "CAKE bandwidth (${tc_bw:-unknown} kbps) differs from UCI ($UL_KBPS kbps) — reload SQM?"
        # Print the exact bandwidth line for context
        echo "       tc output: $(echo "$tc_out" | grep -io 'bandwidth [^ ]*')"
    fi
else
    fail "CAKE qdisc NOT active on $WWAN_IFACE — run: /etc/init.d/sqm restart"
    echo "       tc output: $tc_out"
fi

# ingress present? (needed for DL shaping)
if echo "$tc_out" | grep -qi "ingress"; then
    pass "Ingress qdisc present (download shaping active)"
else
    warn "No ingress qdisc — download shaping may not be active"
fi

# SQM service enabled?
if /etc/init.d/sqm enabled 2>/dev/null; then
    pass "SQM service is enabled (starts on boot)"
else
    warn "SQM service is NOT enabled — run: /etc/init.d/sqm enable"
fi

# =============================================================================
# 4. DNS — DoH + dnsmasq
# =============================================================================
section "4. DNS — DoH + dnsmasq"

# https-dns-proxy: check each instance is listening
for port in $DOH_PORT1 $DOH_PORT2; do
    if netstat -lnup 2>/dev/null | grep -q ":${port}"; then
        pass "https-dns-proxy listening on 127.0.0.1:${port}"
    else
        fail "https-dns-proxy NOT listening on port ${port} — check: /etc/init.d/https-dns-proxy status"
    fi
done

# dnsmasq pointing to local proxies
dnsmasq_srv=$(uci show dhcp | grep "\.server=" | grep -o "127.0.0.1" | wc -l)
if [ "$dnsmasq_srv" -ge 2 ]; then
    pass "dnsmasq has $dnsmasq_srv local DoH upstream(s) configured"
else
    fail "dnsmasq is NOT pointing to local DoH proxies (found $dnsmasq_srv entry)"
fi

# noresolv set (stops dnsmasq using /etc/resolv.conf)
if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = "1" ]; then
    pass "dnsmasq noresolv=1 (does not fall back to resolv.conf)"
else
    warn "dnsmasq noresolv is not set — may leak DNS requests"
fi

# Actual DNS resolution test (via dnsmasq on port 53)
if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    pass "DNS resolution via 127.0.0.1 working"
else
    fail "DNS resolution via 127.0.0.1 FAILED"
fi

# DoH canary domains blocked?
canary_resp=$(nslookup use-application-dns.net 127.0.0.1 2>&1)
if echo "$canary_resp" | grep -q "0.0.0.0\|NXDOMAIN\|can't resolve\|\*\."; then
    pass "DoH canary domain (use-application-dns.net) is blocked"
else
    warn "DoH canary domain may NOT be blocked — Firefox may bypass DoH"
fi

# https-dns-proxy service enabled?
if /etc/init.d/https-dns-proxy enabled 2>/dev/null; then
    pass "https-dns-proxy service enabled (starts on boot)"
else
    warn "https-dns-proxy service NOT enabled — run: /etc/init.d/https-dns-proxy enable"
fi

# =============================================================================
# 5. FIREWALL
# =============================================================================
section "5. Firewall"

# wwan zone
wwan_zone=$(uci show firewall | grep -E "\.(network|device)=" | grep -c -E "(wwan|$WWAN_IFACE)")
if [ "$wwan_zone" -ge 1 ]; then
    pass "Firewall zone references wwan/WWAN interface"
else
    warn "No explicit firewall zone found for wwan — traffic may still be routed via 'wan' zone"
fi

# LAN -> wwan forwarding
fwd_ok=0
for idx in $(uci show firewall | grep "\.src='lan'" | cut -d'[' -f2 | cut -d']' -f1); do
    dest=$(uci -q get firewall.@forwarding[$idx].dest)
    if [ "$dest" = "wan" ] || [ "$dest" = "wwan" ]; then
        fwd_ok=1
        break
    fi
done

if [ "$fwd_ok" -eq 1 ]; then
    pass "Firewall forwarding: lan -> wan/wwan exists"
else
    warn "No lan->wwan forwarding rule found — LAN clients may not reach internet"
fi

# masquerade on wwan
wan_indices=$(uci show firewall | grep -E "name='(wan|wwan)'" | cut -d'[' -f2 | cut -d']' -f1)

if [ -n "$wan_indices" ]; then
    # Loop through each found index
    for idx in $wan_indices; do
        zone_name=$(uci -q get firewall.@zone[$idx].name)
        masq=$(uci -q get firewall.@zone[$idx].masq)
        
        if [ "$masq" = "1" ]; then
            pass "Masquerade (NAT) enabled on '$zone_name' zone"
        else
            fail "Masquerade NOT enabled on '$zone_name' zone — clients will not be NATed"
        fi
    done
else
    fail "Neither WAN nor WWAN zones found in firewall config"
fi

# WAN ping blocked?
ping_idx=$(uci show firewall | grep "name='Allow-Ping'" | cut -d'[' -f2 | cut -d']' -f1 | head -n 1)

if [ -n "$ping_idx" ]; then
    # Query the exact target. If blank, it usually implies ACCEPT in OpenWrt rules.
    ping_target=$(uci -q get firewall.@rule[$ping_idx].target)
    
    if [ "$ping_target" = "DROP" ] || [ "$ping_target" = "REJECT" ]; then
        pass "WAN ping is blocked (target=$ping_target)"
    else
        warn "WAN ping rule is set to '${ping_target:-unspecified/ACCEPT}' — router may respond to external pings"
    fi
else
    warn "Rule 'Allow-Ping' not found in firewall config — relying on default zone input policies"
fi

# Tailscale zone
if uci show firewall | grep -q "name='tailscale'"; then
    pass "Tailscale firewall zone present"
else
    warn "Tailscale firewall zone NOT found — needed if using Tailscale"
fi

# =============================================================================
# 6. SYSTEM — ZRAM
# =============================================================================
section "6. ZRAM"

zram_found=0

# Method 1: init script
for svc in zram zram-swap; do
    if [ -f /etc/init.d/$svc ]; then
        pass "ZRAM init script found: /etc/init.d/$svc"
        if /etc/init.d/$svc enabled 2>/dev/null; then
            pass "ZRAM service ($svc) is enabled"
        else
            warn "ZRAM service ($svc) exists but is NOT enabled"
        fi
        zram_found=1
        break
    fi
done

# Method 2: kernel module + block device active
if [ -b /dev/zram0 ]; then
    zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
    zram_mb=$(( zram_size / 1024 / 1024 ))
    pass "ZRAM block device /dev/zram0 active (${zram_mb} MB allocated)"
    zram_found=1
else
    [ "$zram_found" = "0" ] && fail "/dev/zram0 not present — ZRAM is NOT active"
fi

# Method 3: check if it shows up in swap
if grep -q zram /proc/swaps 2>/dev/null; then
    zram_swap_info=$(grep zram /proc/swaps)
    pass "ZRAM is active in /proc/swaps: $zram_swap_info"
else
    warn "ZRAM not in /proc/swaps — may not be configured as swap"
fi

# kmod loaded?
if lsmod 2>/dev/null | grep -q "^zram"; then
    pass "ZRAM kernel module loaded"
elif modinfo zram >/dev/null 2>&1; then
    warn "ZRAM kernel module available but NOT loaded"
else
    warn "ZRAM kernel module not found — may be built-in or not installed"
fi

# Current swap usage
free_out=$(free 2>/dev/null | awk '/Swap/{printf "total=%s used=%s free=%s", $2, $3, $4}')
[ -n "$free_out" ] && printf "       Swap: %s\n" "$free_out"

# =============================================================================
# 7. SYSTEM — Watchcat
# =============================================================================
section "7. Watchcat"

# UCI config exists?
watchcat_mode=$(uci -q get system.@watchcat[0].mode)
if [ -n "$watchcat_mode" ]; then
    wc_iface=$(uci -q get system.@watchcat[0].interface || echo "?")
    wc_hosts=$(uci -q get system.@watchcat[0].pinghosts  || echo "?")
    wc_period=$(uci -q get system.@watchcat[0].period     || echo "?")
    pass "Watchcat UCI config found (mode=$watchcat_mode iface=$wc_iface period=$wc_period)"
    pass "Watchcat ping targets: $wc_hosts"
else
    fail "Watchcat UCI config NOT found"
fi

# Init script & enabled?
wc_enabled=0
for svc in watchcat watchcat-script; do
    if [ -f /etc/init.d/$svc ]; then
        if /etc/init.d/$svc enabled 2>/dev/null; then
            pass "Watchcat service ($svc) is enabled"
        else
            warn "Watchcat service ($svc) found but NOT enabled"
        fi
        # Check if running
        if /etc/init.d/$svc status 2>/dev/null | grep -qi "running\|active"; then
            pass "Watchcat service ($svc) is running"
        else
            warn "Watchcat service ($svc) may not be running"
        fi
        wc_enabled=1
        break
    fi
done
[ "$wc_enabled" = "0" ] && fail "Watchcat init script not found in /etc/init.d/"

# Recent activity (normal to be silent if no events)
wc_log=$(logread 2>/dev/null | grep -i watchcat | tail -3)
if [ -n "$wc_log" ]; then
    warn "Watchcat has recent log entries (may have triggered a restart):"
    echo "$wc_log" | while IFS= read -r line; do printf "       %s\n" "$line"; done
else
    pass "Watchcat log is silent — no connectivity issues detected (this is good)"
fi

# =============================================================================
# 8. TAILSCALE
# =============================================================================
section "8. Tailscale"

if command -v tailscale >/dev/null 2>&1; then
    pass "Tailscale binary present: $(command -v tailscale)"
    ts_status=$(tailscale status 2>&1 | head -1)
    if echo "$ts_status" | grep -qi "logged out\|not logged"; then
        warn "Tailscale is installed but NOT logged in — run:"
        printf "       tailscale up --advertise-routes=192.168.11.0/24 --accept-routes\n"
    elif echo "$ts_status" | grep -qi "stopped\|error"; then
        fail "Tailscale status: $ts_status"
    else
        pass "Tailscale is active: $ts_status"
        ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
        [ -n "$ts_ip" ] && pass "Tailscale IP: $ts_ip"
    fi
    if [ -f /etc/init.d/tailscale ]; then
        if /etc/init.d/tailscale enabled 2>/dev/null; then
            pass "Tailscale service enabled (starts on boot)"
        else
            warn "Tailscale service NOT enabled — run: /etc/init.d/tailscale enable"
        fi
    fi
else
    warn "Tailscale not installed (skip if not needed)"
fi

# =============================================================================
# 9. ADBLOCK-LEAN
# =============================================================================
section "9. adblock-lean"

if [ -f /etc/init.d/adblock-lean ]; then
    pass "adblock-lean init script present"
    if /etc/init.d/adblock-lean enabled 2>/dev/null; then
        pass "adblock-lean service enabled"
    else
        warn "adblock-lean NOT enabled — run: /etc/init.d/adblock-lean enable"
    fi
    
    # Check for the compressed list first, then fallback to plaintext
    bl_hosts=0
    if [ -f "/var/run/adblock-lean/abl-blocklist.gz" ]; then
        bl_hosts=$(zcat /var/run/adblock-lean/abl-blocklist.gz 2>/dev/null | wc -l)
    elif [ -f "/tmp/adblock-lean/dnsmasq.blacklist" ]; then
        bl_hosts=$(wc -l < /tmp/adblock-lean/dnsmasq.blacklist)
    fi

    if [ "$bl_hosts" -gt 0 ]; then
        pass "adblock-lean blocklist active ($bl_hosts entries)"
    else
        warn "adblock-lean blocklist not loaded yet — run: /etc/init.d/adblock-lean start"
    fi
else
    warn "adblock-lean not installed"
fi

# =============================================================================
# 10. CRON
# =============================================================================
section "10. Cron"

if [ -f /etc/crontabs/root ]; then
    cron_content=$(cat /etc/crontabs/root)
    if echo "$cron_content" | grep -q "reboot"; then
        pass "Weekly reboot cron job present"
        echo "$cron_content" | grep "reboot" | while IFS= read -r line; do
            printf "       %s\n" "$line"
        done
    else
        warn "No reboot cron job found in /etc/crontabs/root"
    fi
else
    warn "/etc/crontabs/root does not exist — cron jobs not configured"
fi

if /etc/init.d/cron enabled 2>/dev/null; then
    pass "Cron service enabled"
else
    warn "Cron service NOT enabled — run: /etc/init.d/cron enable"
fi

# =============================================================================
# 11. SYSCTL
# =============================================================================
section "11. sysctl Tuning"

tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$tcp_cc" = "cubic" ]; then
    pass "TCP congestion control: cubic"
else
    warn "TCP congestion control is '$tcp_cc' (expected: cubic)"
fi

default_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$default_qdisc" = "fq_codel" ]; then
    pass "Default qdisc: fq_codel"
else
    warn "Default qdisc is '$default_qdisc' (expected: fq_codel)"
fi

ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
if [ "$ipv6_disabled" = "1" ]; then
    pass "IPv6 disabled globally (disable_ipv6=1)"
else
    warn "IPv6 is NOT disabled (current: ${ipv6_disabled:-not set})"
fi

if [ -f /etc/sysctl.d/99-custom.conf ]; then
    pass "Custom sysctl config file exists: /etc/sysctl.d/99-custom.conf"
else
    warn "Custom sysctl config NOT found — settings may not persist across reboots"
fi

# =============================================================================
# 12. POST-SETUP SCRIPT (rc.local)
# =============================================================================
section "12. Post-Reboot Init (rc.local)"

if [ -f /etc/rc.local ]; then
    warn "rc.local still present — post-reboot init has NOT run yet, or reboot hasn't happened"
elif [ -f /tmp/.setup_done ]; then
    pass "rc.local has already executed (flag file /tmp/.setup_done present)"
else
    pass "rc.local not present — post-reboot init completed and self-removed (normal)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS + FAIL + WARN))

printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}  VERIFICATION SUMMARY${NC}\n"
printf "${BOLD}============================================================${NC}\n"
printf "  Total checks : %s\n" "$TOTAL"
printf "  ${GREEN}PASS${NC}          : %s\n" "$PASS"
printf "  ${RED}FAIL${NC}          : %s\n" "$FAIL"
printf "  ${YELLOW}WARN${NC}          : %s\n" "$WARN"
printf "${BOLD}============================================================${NC}\n"

if [ "$FAIL" -gt 0 ]; then
    printf "\n${RED}${BOLD}  ACTION REQUIRED: %s check(s) failed. Review FAIL lines above.${NC}\n\n" "$FAIL"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    printf "\n${YELLOW}  Setup looks good but %s item(s) need attention.${NC}\n\n" "$WARN"
    exit 0
else
    printf "\n${GREEN}${BOLD}  All checks passed!${NC}\n\n"
    exit 0
fi