#!/bin/sh
# =============================================================================
#  OpenWrt Universal Setup Script — WISP Mode
#  Compatible: OpenWrt 23.05+ (apk package manager)
#
#  USAGE:
#  1. Edit variables in Part 0 to match your hardware
#  2. On your PC: scp -O OpenWrtSetup.sh root@192.168.11.1:/tmp/
#  3. chmod +x /tmp/OpenWrtSetup.sh && sh /tmp/OpenWrtSetup.sh
#  4. After reboot, run 'tailscale up ...' if needed
#  5. On your PC: scp -O OpenWrtSetupTest.sh root@192.168.11.1:/tmp/
#  6. chmod +x /tmp/OpenWrtSetupTest.sh && sh /tmp/OpenWrtSetupTest.sh
# =============================================================================

: <<'TROUBLESHOOTING'
"Operation not permitted" in wget is almost always an SSL failure caused by a
wrong system clock. OpenWrt has no RTC battery, so time resets to epoch on boot.

Check first:
  date
  ping -c3 8.8.8.8

If date shows 1970 / early 2000s — fix the clock via LuCI > System > Time Sync.

If ping 8.8.8.8 shows 100% loss, routing isn't up yet. Diagnose with:
  ifstatus wwan | jsonfilter -e '@.up' -e '@["ipv4-address"][0].address'
  ip route

Common cause — IP subnet conflict:
  192.168.1.0/24 dev br-lan   src 192.168.1.1    ← LAN
  192.168.1.0/24 dev phy0-sta0 src 192.168.1.26  ← upstream AP

Both subnets are the same — kernel treats upstream traffic as local. Fix by
changing the LAN subnet:
  uci set network.lan.ipaddr='192.168.11.1'
  uci set network.lan.netmask='255.255.255.0'
  uci commit network && /etc/init.d/network restart
TROUBLESHOOTING

# =============================================================================
# STRICT MODE
# =============================================================================
set -u          # treat unset variables as errors
# Note: we intentionally do NOT use set -e globally because some uci -q
# delete commands legitimately return 1 when the key doesn't exist.

# =============================================================================
# LOGGING HELPERS
# =============================================================================
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error() { printf "${RED}[ ERR ]${NC}  %s\n" "$*" >&2; }
log_step()  { printf "\n${BOLD}>>> %s${NC}\n" "$*"; }

# Trap for unexpected exits
_on_exit() {
    rc=$?
    [ $rc -ne 0 ] && log_error "Script exited unexpectedly (exit code $rc). Check output above."
}
trap _on_exit EXIT

# =============================================================================
# PART 0 — CONFIGURATION
# =============================================================================

# --- Wireless WAN Interface (WISP/STA) ---
# Check interface name: iw dev | grep -A2 'type managed'
# Or:  ubus call network.wireless status | jsonfilter -e '@.*.interfaces[@.config.mode="sta"].ifname'
WWAN_IFACE="phy0-sta0"

# --- Radio Names ---
# Check with: uci show wireless | grep "\.type='mac80211'"
RADIO_2G="radio0"
RADIO_5G="radio1"       # Leave empty if no 5 GHz radio: RADIO_5G=""

# --- Wireless 2.4 GHz ---
CH_2G="6"
HTMODE_2G="HE20"        # HT20 | HT40
TXPWR_2G="13"           # dBm — check hw limit: iw phy phy0 info | grep -A5 'Supported TX'

# --- Wireless 5 GHz ---
CH_5G="157"
HTMODE_5G="HE80"        # VHT40 | VHT80 (WiFi 5 / AC) | HE80 (WiFi 6 / AX)
TXPWR_5G="17"           # dBm

COUNTRY="ID"

# --- LAN Port Assignment ---
# Leave empty ("") to keep OpenWrt defaults.
# Check available ports: uci show network | grep ports
# Example: LAN_PORTS="lan1 lan2 lan3 lan4"
LAN_PORTS=""

# --- SQM CAKE Bandwidth (kbps) ---
# Use ~95% of actual speedtest result.
# Formula: result_mbps * 1000 * 0.95
DL_KBPS="23000"
UL_KBPS="11000"

# --- SQM MTU / Overhead ---
# PPPoE:            overhead=8,  linklayer=ethernet
# WISP via DHCP:    overhead=44, linklayer=ethernet
# Check actual MTU: ip link show; ping -M do -s 1472 8.8.8.8
SQM_OVERHEAD="44"
SQM_LINKLAYER="ethernet"
SQM_MTU="1480"          # Also used as MTU for the wwan interface

# --- ZRAM ---
# Recommended: ~50% of physical RAM.
# Check total RAM: free | awk '/Mem/{printf "%.0f MB\n", $2/1024}'
# Check algorithms: cat /sys/block/zram0/comp_algorithm
# Leave empty ("") to skip: ZRAM_MB=""
ZRAM_MB="128"
ZRAM_ALGO="lzo-rle"     # lzo-rle | zstd | lz4

# --- DNS over HTTPS ---
DOH_PRIMARY_BOOTSTRAP="1.1.1.1,1.0.0.1"
DOH_PRIMARY_URL="https://cloudflare-dns.com/dns-query"
DOH_PRIMARY_PORT="5053"

DOH_SECONDARY_BOOTSTRAP="9.9.9.9,149.112.112.112"
DOH_SECONDARY_URL="https://dns.quad9.net/dns-query"
DOH_SECONDARY_PORT="5054"

# DOH_SECONDARY_BOOTSTRAP="8.8.8.8,8.8.4.4"
# DOH_SECONDARY_URL="https://dns.google/dns-query"
# DOH_SECONDARY_PORT="5054"

# --- Feature Toggles (1=enabled, 0=disabled) ---
ENABLE_TAILSCALE=1
ENABLE_ADBLOCK_LEAN=1
ENABLE_WANUSB_ZONE=0    # USB modem/dongle fallback WAN zone (not needed for pure WISP)
DISABLE_IPV6=1

# =============================================================================
# VARIABLE VALIDATION — fail fast before touching any config
# =============================================================================
log_step "Validating configuration variables..."

_abort() { log_error "$*"; exit 1; }

[ -z "$WWAN_IFACE"    ] && _abort "WWAN_IFACE is not set."
[ -z "$RADIO_2G"      ] && _abort "RADIO_2G is not set."
[ -z "$DL_KBPS"       ] && _abort "DL_KBPS is not set."
[ -z "$UL_KBPS"       ] && _abort "UL_KBPS is not set."
[ -z "$COUNTRY"       ] && _abort "COUNTRY is not set."

# Numeric checks
for var_name in DL_KBPS UL_KBPS SQM_OVERHEAD SQM_MTU TXPWR_2G; do
    eval val=\$$var_name
    case "$val" in
        ''|*[!0-9]*) _abort "$var_name must be a positive integer (got: '$val')." ;;
    esac
done

log_ok "All required variables look good."

# =============================================================================
# BACKUP — snapshot current UCI config before changes
# =============================================================================
BACKUP_DIR="/tmp/uci-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for ns in network wireless sqm system dhcp https-dns-proxy firewall; do
    uci export "$ns" > "$BACKUP_DIR/${ns}.uci" 2>/dev/null || true
done
log_ok "UCI backup saved to: $BACKUP_DIR"

# =============================================================================
# PART 1 — PACKAGES
# =============================================================================
log_step "[1/10] Installing packages..."

apk update || _abort "apk update failed — check network/time sync."

# SSL certs + curl first (needed for adblock-lean download later)
apk add ca-bundle ca-certificates curl

# SQM, DoH, connection watchdog
# kmod-sched-fq-codel is built-in on OpenWrt 25.x kernels — no need to install
apk add \
    sqm-scripts luci-app-sqm kmod-sched-cake \
    https-dns-proxy luci-app-https-dns-proxy \
    watchcat nano

# Tailscale (optional)
if [ "$ENABLE_TAILSCALE" = "1" ]; then
    apk add tailscale && log_ok "Tailscale installed." \
        || log_warn "Tailscale install failed — continuing without it."
fi

# Remove bloatware — check existence first to avoid errors on clean builds
BLOAT_PKGS="
    luci-app-statistics rrdtool1 librrd1 libgd libjpeg-turbo libpng libwebp
    netdata mwan3 luci-app-mwan3
    ttyd luci-app-ttyd
    vnstat2 vnstat2ri adblock luci-app-adblock
"
for pkg in $BLOAT_PKGS; do
    if apk info "$pkg" >/dev/null 2>&1; then
        apk del "$pkg" && log_ok "Removed: $pkg"
    fi
done

# Remove any remaining collectd packages
for pkg in $(apk info 2>/dev/null | grep "^collectd"); do
    apk del "$pkg" && log_ok "Removed: $pkg"
done

log_ok "Package setup complete."

# =============================================================================
# PART 2 — NETWORK (WISP Mode)
# =============================================================================
log_step "[2/10] Configuring network..."

uci -q delete network.wan  || true
uci -q delete network.wan6 || true

# Assign LAN ports only if explicitly defined
[ -n "$LAN_PORTS" ] && uci set network.@device[0].ports="$LAN_PORTS"

# WISP upstream interface
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.device="$WWAN_IFACE"
uci set network.wwan.mtu="$SQM_MTU"
uci set network.wwan.peerdns='0'
uci -q delete network.wwan.dns || true
uci add_list network.wwan.dns='8.8.8.8'
uci add_list network.wwan.dns='1.1.1.1'

uci set network.globals.packet_steering='2'

[ "$DISABLE_IPV6" = "1" ] && uci set network.lan.ipv6='0'

uci commit network
log_ok "Network config committed."

# =============================================================================
# PART 3 — WIRELESS
# =============================================================================
log_step "[3/10] Configuring wireless..."

# 2.4 GHz
uci set wireless.${RADIO_2G}.channel="$CH_2G"
uci set wireless.${RADIO_2G}.htmode="$HTMODE_2G"
uci set wireless.${RADIO_2G}.txpower="$TXPWR_2G"
uci set wireless.${RADIO_2G}.country="$COUNTRY"
uci set wireless.${RADIO_2G}.disabled='0'

# 5 GHz (skip if RADIO_5G is empty)
if [ -n "$RADIO_5G" ]; then
    uci set wireless.${RADIO_5G}.channel="$CH_5G"
    uci set wireless.${RADIO_5G}.htmode="$HTMODE_5G"
    uci set wireless.${RADIO_5G}.txpower="$TXPWR_5G"
    uci set wireless.${RADIO_5G}.country="$COUNTRY"
    uci set wireless.${RADIO_5G}.disabled='0'
    log_ok "5 GHz radio configured."
else
    log_warn "RADIO_5G is empty — skipping 5 GHz configuration."
fi

# Force SAE-Mixed (WPA2/WPA3) on all AP interfaces
ap_count=0
for iface in $(uci show wireless | grep "mode='ap'" | awk -F'.' '{print $2}'); do
    uci set wireless.${iface}.encryption='sae-mixed'
    ap_count=$((ap_count + 1))
done
log_ok "SAE-Mixed encryption applied to $ap_count AP interface(s)."

uci commit wireless
log_ok "Wireless config committed."

# =============================================================================
# PART 4 — SQM CAKE
# =============================================================================
log_step "[4/10] Configuring SQM CAKE..."

# Create queue section if it doesn't exist (fresh installs have no default entry)
uci -q get sqm.@queue[0] >/dev/null 2>&1 || uci add sqm queue

uci set sqm.@queue[0].enabled='1'
uci set sqm.@queue[0].interface="$WWAN_IFACE"
uci set sqm.@queue[0].download="$DL_KBPS"
uci set sqm.@queue[0].upload="$UL_KBPS"
uci set sqm.@queue[0].qdisc='cake'
uci set sqm.@queue[0].script='piece_of_cake.qos'
uci set sqm.@queue[0].linklayer="$SQM_LINKLAYER"
uci set sqm.@queue[0].overhead="$SQM_OVERHEAD"
uci set sqm.@queue[0].linklayer_advanced='1'
uci set sqm.@queue[0].tcMPU='84'

uci commit sqm
log_ok "SQM CAKE config committed (DL: ${DL_KBPS} kbps / UL: ${UL_KBPS} kbps)."

# =============================================================================
# PART 5 — SYSTEM (ZRAM + Watchcat + sysctl)
# =============================================================================
log_step "[5/10] Configuring system settings..."

# --- ZRAM (23.05+ apk builds — configured via kmod-zram + sysctl) ---
if [ -n "$ZRAM_MB" ]; then
    # Install kmod if not already present
    apk add kmod-zram 2>/dev/null || true
    # Size in bytes
    ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))
    # Write a dedicated init script since there's no stock one
    cat > /etc/init.d/zram-setup << ZRAMEOF
#!/bin/sh /etc/rc.common
START=12
STOP=89
USE_PROCD=1
start_service() {
    modprobe zram 2>/dev/null || true
    sleep 1
    [ -b /dev/zram0 ] || { logger -t zram "ERROR: /dev/zram0 not found"; return 1; }
    echo ${ZRAM_ALGO} > /sys/block/zram0/comp_algorithm
    echo ${ZRAM_BYTES} > /sys/block/zram0/disksize
    mkswap /dev/zram0
    swapon -p 10 /dev/zram0
    logger -t zram "ZRAM swap active: ${ZRAM_MB}MB (${ZRAM_ALGO})"
}
stop_service() {
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
}
ZRAMEOF
    chmod +x /etc/init.d/zram-setup
    /etc/init.d/zram-setup enable
    log_ok "ZRAM init script written and enabled (${ZRAM_MB} MB, ${ZRAM_ALGO})."
fi

uci set system.@system[0].conloglevel='8'
uci set system.@system[0].cronloglevel='9'

# Watchcat — restart wwan interface on connectivity loss
uci -q delete system.@watchcat[0] || true
uci add system watchcat
uci set system.@watchcat[-1].mode='restart_iface'
uci set system.@watchcat[-1].interface='wwan'
uci set system.@watchcat[-1].pinghosts='8.8.8.8 1.1.1.1'
uci set system.@watchcat[-1].addressfamily='ipv4'
uci set system.@watchcat[-1].pingperiod='30'
uci set system.@watchcat[-1].period='3m'

uci commit system
log_ok "System config committed."

# sysctl tuning
cat > /etc/sysctl.d/99-custom.conf << 'SYSCTL'
# TCP congestion control
net.ipv4.tcp_congestion_control=cubic
# Default qdisc for interfaces not managed by SQM
net.core.default_qdisc=fq_codel
SYSCTL

if [ "$DISABLE_IPV6" = "1" ]; then
    cat >> /etc/sysctl.d/99-custom.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL
fi
log_ok "sysctl config written to /etc/sysctl.d/99-custom.conf"

# =============================================================================
# PART 6 — DNS: DoH + dnsmasq
# =============================================================================
log_step "[6/10] Configuring DoH + dnsmasq..."

# Ensure config file exists (some builds don't create it on install)
[ -f /etc/config/https-dns-proxy ] || touch /etc/config/https-dns-proxy

uci -q delete https-dns-proxy.@https-dns-proxy[0] || true
uci -q delete https-dns-proxy.@https-dns-proxy[1] || true

# Primary: Cloudflare
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$DOH_PRIMARY_BOOTSTRAP"
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$DOH_PRIMARY_URL"
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port="$DOH_PRIMARY_PORT"
uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'

# Secondary: Google
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$DOH_SECONDARY_BOOTSTRAP"
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$DOH_SECONDARY_URL"
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port="$DOH_SECONDARY_PORT"
uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'

uci commit https-dns-proxy

# dnsmasq — point to local DoH proxies
uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_PRIMARY_PORT}"
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_SECONDARY_PORT}"

# Block canary domains that bypass DoH (Firefox, iCloud Private Relay)
uci -q delete dhcp.@dnsmasq[0].address || true
uci add_list dhcp.@dnsmasq[0].address='/use-application-dns.net/'
uci add_list dhcp.@dnsmasq[0].address='/mask.icloud.com/'
uci add_list dhcp.@dnsmasq[0].address='/mask-h2.icloud.com/'

if [ "$DISABLE_IPV6" = "1" ]; then
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='disabled'
    uci set dhcp.lan.ndp='disabled'
    /etc/init.d/odhcpd disable
    /etc/init.d/odhcpd stop
    log_ok "DHCPv6 / RA / NDP disabled."
fi

uci commit dhcp
log_ok "DNS / dnsmasq config committed."

# =============================================================================
# PART 7 — FIREWALL
# =============================================================================
log_step "[7/10] Configuring firewall..."

# Drop WAN ping
ping_rule=$(uci show firewall | grep "name='Allow-Ping'" | awk -F'.' '{print $2}')
[ -n "$ping_rule" ] && uci set firewall.${ping_rule}.target='DROP' \
    && log_ok "WAN ping set to DROP."

# Remove unused default IPSec rules
for rule_name in "Allow-IPSec-ESP" "Allow-ISAKMP"; do
    r=$(uci show firewall | grep "name='${rule_name}'" | awk -F'.' '{print $2}')
    if [ -n "$r" ]; then
        uci delete firewall.${r}
        log_ok "Removed unused firewall rule: $rule_name"
    fi
done

# Clean up duplicate WAN zones left by OEM firmware
for z in wan1 wan2 wan3 wan4 wan5 wwan2; do
    uci -q delete firewall.$z && log_ok "Removed duplicate zone: $z" || true
done

# Tailscale zone — idempotent (skip if already exists)
if [ "$ENABLE_TAILSCALE" = "1" ]; then
    _ts_zone=$(uci show firewall | grep "name='tailscale'" | awk -F'.' '{print $2}')
    if [ -z "$_ts_zone" ]; then
        uci add firewall zone
        uci set firewall.@zone[-1].name='tailscale'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].device='tailscale0'

        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='tailscale'

        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='tailscale'
        uci set firewall.@forwarding[-1].dest='lan'
        log_ok "Tailscale firewall zone created."
    else
        log_warn "Tailscale zone already exists — skipping to avoid duplicates."
    fi
fi

# USB WAN zone (enable if using USB modem/dongle as fallback WAN)
if [ "$ENABLE_WANUSB_ZONE" = "1" ]; then
    _usb_zone=$(uci show firewall | grep "name='wanusb'" | awk -F'.' '{print $2}')
    if [ -z "$_usb_zone" ]; then
        uci add firewall zone
        uci set firewall.@zone[-1].name='wanusb'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].network='wanusb'

        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='wanusb'
        log_ok "USB WAN firewall zone created."
    else
        log_warn "wanusb zone already exists — skipping."
    fi
fi

uci commit firewall
log_ok "Firewall config committed."

# =============================================================================
# PART 8 — CRON + adblock-lean
# =============================================================================
log_step "[8/10] Configuring cron + adblock-lean..."

cat > /etc/crontabs/root << 'CRON'
# Weekly reboot every Sunday at 03:00
0 3 * * 0 reboot
0 5 * * * RANDOM_DELAY=1 /etc/init.d/adblock-lean start 1>/dev/null
CRON
log_ok "Cron job written."

if [ "$ENABLE_ADBLOCK_LEAN" = "1" ]; then
    log_info "Downloading adblock-lean installer..."
    uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh \
        -O /tmp/abl-install.sh
    if [ -f /tmp/abl-install.sh ]; then
        sh /tmp/abl-install.sh -v release \
            && log_ok "adblock-lean installed successfully." \
            || log_warn "adblock-lean installer returned an error — check manually."
        rm -f /tmp/abl-install.sh
    else
        log_warn "Failed to download abl-install.sh — skipping adblock-lean."
    fi
fi

service cron enable
log_ok "Cron service enabled."

# =============================================================================
# PART 9 — ENABLE SERVICES
# =============================================================================
log_step "[9/10] Enabling services..."

# ZRAM — init script name varies across builds
if [ -n "$ZRAM_MB" ]; then
    _zram_enabled=0
    for svc in zram zram-swap; do
        if [ -f /etc/init.d/$svc ]; then
            service $svc enable
            log_ok "ZRAM service enabled: $svc"
            _zram_enabled=1
            break
        fi
    done
    [ "$_zram_enabled" = "0" ] && log_warn "No ZRAM init script found — skipping."
fi

# Watchcat — init script name varies
_watchcat_enabled=0
for svc in watchcat watchcat-script; do
    if [ -f /etc/init.d/$svc ]; then
        service $svc enable
        log_ok "Watchcat service enabled: $svc"
        _watchcat_enabled=1
        break
    fi
done
[ "$_watchcat_enabled" = "0" ] && log_warn "No Watchcat init script found — skipping."

if [ "$ENABLE_TAILSCALE" = "1" ] && [ -f /etc/init.d/tailscale ]; then
    service tailscale enable
    log_ok "Tailscale service enabled."
fi

# Apply sysctl now (will also apply on next boot via /etc/sysctl.d/)
sysctl -p /etc/sysctl.d/99-custom.conf
log_ok "sysctl settings applied."

# =============================================================================
# PART 10 — POST-REBOOT INIT (rc.local) + REBOOT
# =============================================================================
log_step "[10/10] Writing post-reboot init and scheduling reboot..."

# Write to a dedicated init script instead of overwriting rc.local entirely.
# Uses a flag file so it runs exactly once, then removes itself.
cat > /etc/rc.local << RCEOF
#!/bin/sh

# Guard: run only once
[ -f /tmp/.setup_done ] && exit 0
touch /tmp/.setup_done

# Wait for all services to be ready
sleep 10

wifi reload
/etc/init.d/sqm            restart
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq         restart
/etc/init.d/firewall        restart

[ -f /etc/init.d/adblock-lean ] && /etc/init.d/adblock-lean start
[ -f /etc/init.d/tailscale    ] && /etc/init.d/tailscale    restart

# Self-remove after successful run
rm -f /etc/rc.local

exit 0
RCEOF

chmod +x /etc/rc.local
log_ok "Post-reboot rc.local written."

# =============================================================================
# FINAL SUMMARY
# =============================================================================
printf "\n${BOLD}============================================================${NC}\n"
printf "${GREEN}  Configuration complete. Rebooting in 5 seconds...${NC}\n"
printf "${BOLD}============================================================${NC}\n"
printf "\nAfter reboot, run these to verify:\n\n"
printf "  # Connectivity\n"
printf "  ping -c4 8.8.8.8\n\n"
printf "  # DoH / DNS\n"
printf "  nslookup google.com 127.0.0.1\n\n"
printf "  # SQM / CAKE\n"
printf "  tc qdisc show dev %s\n\n" "$WWAN_IFACE"
printf "  # HTTPS-DNS-Proxy\n"
printf "  /etc/init.d/https-dns-proxy status\n\n"
printf "  # Watchcat\n"
printf "  logread | grep -i watchcat\n\n"
if [ "$ENABLE_TAILSCALE" = "1" ]; then
    printf "  # Tailscale status\n"
    printf "  tailscale status\n\n"
    printf "  # Tailscale login (adjust subnet as needed)\n"
    printf "  tailscale up --advertise-routes=192.168.11.0/24 --accept-routes\n\n"
fi
printf "  # UCI backup location (pre-change snapshot)\n"
printf "  ls %s\n\n" "$BACKUP_DIR"
printf "${BOLD}============================================================${NC}\n"

sleep 5
reboot