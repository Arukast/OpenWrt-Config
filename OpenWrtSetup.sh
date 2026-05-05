#!/bin/sh
# =============================================================================
#  OpenWrt Universal Setup Script — WISP Mode
#  Compatible: OpenWrt 23.05+ (apk package manager)
# =============================================================================

# --- Strict Mode & Globals ---
set -u
START_TIME=$(date +%s)
LOG_FILE="/tmp/openwrt-setup.log"

# --- CLI Arguments ---
DRY_RUN=0
NO_REBOOT=0
AUTO_YES=0
CONFIG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --yes) AUTO_YES=1 ;;
        --config)
            CONFIG_FILE="$2"
            shift
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

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

# Initialize log file
> "$LOG_FILE"
log_info "Starting OpenWrt Setup Script (WISP Mode)"

show_subnet_hint() {
    printf "\n${YELLOW}Troubleshooting: Fix by changing the LAN subnet:${NC}\n"
    printf "uci set network.lan.ipaddr='192.168.11.1'\n"
    printf "uci set network.lan.netmask='255.255.255.0'\n"
    printf "uci commit network && /etc/init.d/network restart\n\n"
}

_on_exit() {
    rc=$?
    [ $rc -ne 0 ] && log_error "Script exited unexpectedly (exit code $rc)."
}
trap _on_exit EXIT

run_uci() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRY-RUN] uci $*"
    else
        uci "$@"
    fi
}

run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================
load_config() {
    log_step "Loading Configuration..."
    if [ -z "$CONFIG_FILE" ]; then
        if [ -f "./setup.conf" ]; then
            CONFIG_FILE="./setup.conf"
        elif [ -f "/etc/openwrt-setup.conf" ]; then
            CONFIG_FILE="/etc/openwrt-setup.conf"
        fi
    fi

    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log_info "Loading configuration from $CONFIG_FILE"
        case "$CONFIG_FILE" in
            */*) . "$CONFIG_FILE" ;;
              *) . "./$CONFIG_FILE" ;;
        esac
    else
        log_info "No configuration file found or specified."
    fi

    # Set defaults if not provided by config file
    : ${HOSTNAME:="OpenWrt-WISP"}
    : ${TIMEZONE:="WIB-7"}
    : ${ZONENAME:="Asia/Jakarta"}
    : ${LAN_IP:="192.168.11.1"}
    : ${LAN_NETMASK:="255.255.255.0"}
    : ${WWAN_IFACE:="phy0-sta0"}
    : ${RADIO_2G:="radio0"}
    : ${RADIO_5G:=""}
    : ${WIFI_SSID_2G:="OpenWrt-WISP-2G"}
    : ${WIFI_SSID_5G:="OpenWrt-WISP-5G"}
    : ${WIFI_KEY:="CHANGE_ME"}
    : ${CH_2G:="6"}
    : ${HTMODE_2G:="HE20"}
    : ${TXPWR_2G:="13"}
    : ${CH_5G:="157"}
    : ${HTMODE_5G:="HE80"}
    : ${TXPWR_5G:="17"}
    : ${COUNTRY:="ID"}
    : ${LAN_PORTS:=""}
    : ${DL_KBPS:="23000"}
    : ${UL_KBPS:="11000"}
    : ${SQM_OVERHEAD:="44"}
    : ${SQM_LINKLAYER:="ethernet"}
    : ${SQM_MTU:="1480"}
    : ${ZRAM_MB:="128"}
    : ${ZRAM_ALGO:="lzo-rle"}
    : ${DOH_PRIMARY_BOOTSTRAP:="1.1.1.1,1.0.0.1"}
    : ${DOH_PRIMARY_URL:="https://cloudflare-dns.com/dns-query"}
    : ${DOH_PRIMARY_PORT:="5053"}
    : ${DOH_SECONDARY_BOOTSTRAP:="9.9.9.9,149.112.112.112"}
    : ${DOH_SECONDARY_URL:="https://dns.quad9.net/dns-query"}
    : ${DOH_SECONDARY_PORT:="5054"}
    : ${NTP_SERVERS:="0.id.pool.ntp.org 1.id.pool.ntp.org 2.id.pool.ntp.org 3.id.pool.ntp.org"}
    : ${ENABLE_TAILSCALE:=1}
    : ${ENABLE_ADBLOCK_LEAN:=1}
    : ${ENABLE_WANUSB_ZONE:=0}
    : ${DISABLE_IPV6:=1}

    if [ "$WIFI_KEY" = "CHANGE_ME" ] || [ "$WIFI_KEY" = "CHANGE_ME_SUPER_SECRET_KEY" ]; then
        _abort "WIFI_KEY is not set to a secure value. Please update your config file."
    fi
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
pre_flight_checks() {
    log_step "Pre-flight Checks..."

    [ "$(id -u)" -ne 0 ] && _abort "This script must be run as root."
    [ ! -x "/sbin/uci" ] && _abort "UCI not found. Are you running this on OpenWrt?"

    # Variable Validation
    [ -z "$WWAN_IFACE" ] && _abort "WWAN_IFACE is not set."
    [ -z "$RADIO_2G" ] && _abort "RADIO_2G is not set."
    for var_name in DL_KBPS UL_KBPS SQM_OVERHEAD SQM_MTU TXPWR_2G; do
        eval val=\$$var_name
        case "$val" in
            ''|*[!0-9]*) _abort "$var_name must be a positive integer (got: '$val')." ;;
        esac
    done

    # Subnet Conflict Detection
    # If LAN and WAN share the same subnet, outbound traffic may loop back.
    _lan_addr=$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    _wan_gw=$(ip route show default 2>/dev/null | awk '/default via/{print $3; exit}')
    if [ -n "$_lan_addr" ] && [ -n "$_wan_gw" ] && [ "${_lan_addr%.*}" = "${_wan_gw%.*}" ]; then
        log_warn "Subnet conflict detected (LAN: $_lan_addr, WAN Gateway: $_wan_gw)"
        show_subnet_hint
    fi

    # Internet Connectivity Check
    log_info "Checking internet connectivity..."
    _connected=0
    for i in $(seq 1 5); do
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            _connected=1
            break
        fi
        [ "$i" -lt 5 ] && sleep 2
    done

    if [ "$_connected" -eq 1 ]; then
        log_ok "Internet connection detected."
        log_info "Synchronizing system clock..."
        _synced=0
        for _ntp in 216.239.35.0 162.159.200.1 216.239.35.4; do
            ntpd -q -n -p "$_ntp" 2>/dev/null && _synced=1 && break
        done
        if [ "$_synced" = "0" ]; then
            # Fallback: read time from HTTP Date header
            _d=$(uclient-fetch -q -O /dev/null http://1.1.1.1/ 2>&1 | sed -n 's/.*Date: //p' | head -1)
            [ -n "$_d" ] && date -s "$_d" >/dev/null 2>&1 && _synced=1
        fi
        hwclock -w 2>/dev/null || true
        log_ok "Clock updated to: $(date)"
    else
        log_warn "No internet connection detected."
        # Show the hint again as it is the most common cause of no internet in WISP mode
        show_subnet_hint
    fi

    # Confirmation
    if [ "$DRY_RUN" = "1" ]; then
        log_info "DRY-RUN MODE ENABLED. No changes will be made."
    elif [ "$AUTO_YES" = "0" ]; then
        printf "\n${BOLD}Configuration Summary:${NC}\n"
        printf "  Hostname  : %s\n" "$HOSTNAME"
        printf "  LAN IP    : %s\n" "$LAN_IP"
        printf "  WiFi 2.4G : %s (Ch %s)\n" "$WIFI_SSID_2G" "$CH_2G"
        printf "  WiFi 5G   : %s (Ch %s)\n" "$WIFI_SSID_5G" "$CH_5G"
        printf "  SQM CAKE  : %s DL / %s UL\n" "$DL_KBPS" "$UL_KBPS"
        printf "  ZRAM      : %s MB\n" "${ZRAM_MB:-Disabled}"
        printf "\n"
        read -p "Proceed with configuration? (y/N) " confirm
        case "$confirm" in
            [yY]|[yY][eE][sS]) ;;
            *) log_info "Aborted by user."; exit 0 ;;
        esac
    fi
}

# =============================================================================
# BACKUP
# =============================================================================
backup_uci() {
    if [ "$DRY_RUN" = "0" ]; then
        BACKUP_DIR="/tmp/uci-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        for ns in network wireless sqm system dhcp https-dns-proxy firewall; do
            uci export "$ns" > "$BACKUP_DIR/${ns}.uci" 2>/dev/null || true
        done
        log_ok "UCI backup saved to: $BACKUP_DIR"
    fi
}

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================

setup_packages() {
    log_step "Installing packages..."

    # --- Subnet Conflict Check ---
    # We no longer apply an automatic 'onlink' fix. If the conflict is present,
    # the user is advised to fix it manually as per the troubleshooting note.
    _lan_addr=$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    _wan_gw=$(ip route show default 2>/dev/null | awk '/default via/{print $3; exit}')
    if [ -n "$_lan_addr" ] && [ -n "$_wan_gw" ] && [ "${_lan_addr%.*}" = "${_wan_gw%.*}" ]; then
        log_warn "Subnet conflict present. Package installation will likely fail."
        show_subnet_hint
    fi

    # --- Fix 2: Force IPv4 for apk ---
    # Replace /usr/bin/wget with a wrapper that passes -4 to uclient-fetch.
    # This prevents apk from attempting IPv6 connections that may return EPERM.
    if [ -x /usr/bin/wget ] && [ ! -f /usr/bin/wget.orig ]; then
        mv /usr/bin/wget /usr/bin/wget.orig
        printf '#!/bin/sh
exec /usr/bin/wget.orig -4 "$@"
' > /usr/bin/wget
        chmod +x /usr/bin/wget
    fi

    run_cmd apk update || {
        log_warn "apk update failed."
        show_subnet_hint
        log_info "Continuing anyway..."
    }

    run_cmd apk add ca-bundle ca-certificates curl sqm-scripts luci-app-sqm kmod-sched-cake https-dns-proxy luci-app-https-dns-proxy watchcat nano iperf3

    if [ "$ENABLE_TAILSCALE" = "1" ]; then
        run_cmd apk add tailscale && log_ok "Tailscale installed." || log_warn "Tailscale install failed."
    fi

    BLOAT_PKGS="luci-app-statistics rrdtool1 librrd1 libgd libjpeg-turbo libpng libwebp netdata mwan3 luci-app-mwan3 ttyd luci-app-ttyd vnstat2 vnstat2ri adblock luci-app-adblock"
    for pkg in $BLOAT_PKGS; do
        if apk info "$pkg" >/dev/null 2>&1; then
            run_cmd apk del "$pkg"
        fi
    done

    for pkg in $(apk info 2>/dev/null | grep "^collectd"); do
        run_cmd apk del "$pkg"
    done
    log_ok "Package setup complete."
}

setup_system() {
    log_step "Configuring system, hostname & NTP..."
    run_uci set system.@system[0].hostname="$HOSTNAME"
    run_uci set system.@system[0].timezone="$TIMEZONE"
    run_uci set system.@system[0].zonename="$ZONENAME"

    run_uci -q delete system.ntp.server || true
    for srv in $NTP_SERVERS; do
        run_uci add_list system.ntp.server="$srv"
    done
    run_uci set system.ntp.enabled='1'
    run_uci set system.ntp.enable_server='0'
    run_uci commit system
    log_ok "System config committed."
}

setup_network() {
    log_step "Configuring network..."
    run_uci -q delete network.wan  || true
    run_uci -q delete network.wan6 || true

    [ -n "$LAN_PORTS" ] && run_uci set network.@device[0].ports="$LAN_PORTS"

    # LAN Config
    run_uci set network.lan.ipaddr="$LAN_IP"
    run_uci set network.lan.netmask="$LAN_NETMASK"

    # WISP Config
    run_uci set network.wwan='interface'
    run_uci set network.wwan.proto='dhcp'
    run_uci set network.wwan.device="$WWAN_IFACE"
    run_uci set network.wwan.mtu="$SQM_MTU"
    run_uci set network.wwan.peerdns='0'
    run_uci -q delete network.wwan.dns || true
    run_uci add_list network.wwan.dns='9.9.9.9'
    run_uci add_list network.wwan.dns='1.1.1.1'

    run_uci set network.globals.packet_steering='2'
    [ "$DISABLE_IPV6" = "1" ] && run_uci set network.lan.ipv6='0'

    run_uci commit network
    log_ok "Network config committed."
}

setup_wireless() {
    log_step "Configuring wireless..."
    for radio in $RADIO_2G $RADIO_5G; do
        [ -z "$radio" ] && continue
        # Configure the radio hardware
        run_uci set wireless.${radio}.country="$COUNTRY"
        run_uci set wireless.${radio}.disabled='0'
        
        if [ "$radio" = "$RADIO_2G" ]; then
            run_uci set wireless.${radio}.band="2g"
            run_uci set wireless.${radio}.channel="$CH_2G"
            run_uci set wireless.${radio}.htmode="$HTMODE_2G"
            run_uci set wireless.${radio}.txpower="$TXPWR_2G"
            ssid_var="$WIFI_SSID_2G"
        else
            run_uci set wireless.${radio}.band="5g"
            run_uci set wireless.${radio}.channel="$CH_5G"
            run_uci set wireless.${radio}.htmode="$HTMODE_5G"
            run_uci set wireless.${radio}.txpower="$TXPWR_5G"
            ssid_var="$WIFI_SSID_5G"
        fi
        
        # Configure the AP and STA interfaces attached to this radio
        for iface in $(uci show wireless | grep "device='${radio}'" | awk -F'.' '{print $2}' | sort -u); do
            run_uci set wireless.${iface}.disabled='0'
            # Only set SSID/Key for AP interfaces, leave STA interfaces untouched to preserve WISP connection
            if uci get wireless.${iface}.mode 2>/dev/null | grep -q "ap"; then
                run_uci set wireless.${iface}.ssid="$ssid_var"
                run_uci set wireless.${iface}.encryption='sae-mixed'
                run_uci set wireless.${iface}.key="$WIFI_KEY"
            fi
        done
    done
    run_uci commit wireless
    log_ok "Wireless config committed."
}

setup_sqm() {
    log_step "Configuring SQM CAKE..."
    uci -q get sqm.@queue[0] >/dev/null 2>&1 || run_uci add sqm queue
    run_uci set sqm.@queue[0].enabled='1'
    run_uci set sqm.@queue[0].interface="$WWAN_IFACE"
    run_uci set sqm.@queue[0].download="$DL_KBPS"
    run_uci set sqm.@queue[0].upload="$UL_KBPS"
    run_uci set sqm.@queue[0].qdisc='cake'
    run_uci set sqm.@queue[0].script='piece_of_cake.qos'
    run_uci set sqm.@queue[0].linklayer="$SQM_LINKLAYER"
    run_uci set sqm.@queue[0].overhead="$SQM_OVERHEAD"
    run_uci set sqm.@queue[0].linklayer_advanced='1'
    run_uci set sqm.@queue[0].tcMPU='84'
    run_uci commit sqm
    log_ok "SQM config committed."
}

setup_tuning() {
    log_step "Configuring ZRAM and Watchcat..."

    if [ -n "$ZRAM_MB" ] && [ "$DRY_RUN" = "0" ]; then
        apk add kmod-zram 2>/dev/null || true
        ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))
        cat > /etc/init.d/zram-setup << ZRAMEOF
#!/bin/sh /etc/rc.common
START=12
STOP=89
USE_PROCD=1
# Notice: \${ZRAM_ALGO} and \${ZRAM_BYTES} are expanded at script generation time. This is intentional.
start_service() {
    modprobe zram 2>/dev/null || true
    sleep 1
    [ -b /dev/zram0 ] || return 1
    echo ${ZRAM_ALGO} > /sys/block/zram0/comp_algorithm
    echo ${ZRAM_BYTES} > /sys/block/zram0/disksize
    mkswap /dev/zram0
    swapon -p 10 /dev/zram0
}
stop_service() {
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
}
ZRAMEOF
        chmod +x /etc/init.d/zram-setup
        /etc/init.d/zram-setup enable
        log_ok "ZRAM init script configured."
    fi

    run_uci set system.@system[0].conloglevel='8'
    run_uci set system.@system[0].cronloglevel='9'

    # Delete all existing watchcat instances to ensure idempotency
    while uci -q get system.@watchcat[0] >/dev/null 2>&1; do
        run_uci -q delete system.@watchcat[0]
    done

    run_uci add system watchcat
    run_uci set system.@watchcat[-1].mode='restart_iface'
    run_uci set system.@watchcat[-1].interface='wwan'
    run_uci set system.@watchcat[-1].pinghosts='8.8.8.8 1.1.1.1'
    run_uci set system.@watchcat[-1].addressfamily='ipv4'
    run_uci set system.@watchcat[-1].pingperiod='30'
    run_uci set system.@watchcat[-1].period='3m'
    run_uci commit system

    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/sysctl.d/99-custom.conf << 'SYSCTL'
net.ipv4.tcp_congestion_control=cubic
net.core.default_qdisc=fq_codel
SYSCTL
        if [ "$DISABLE_IPV6" = "1" ]; then
            cat >> /etc/sysctl.d/99-custom.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL
        fi
    fi
    log_ok "System tuning applied."
}

setup_dns() {
    log_step "Configuring DoH + dnsmasq..."
    [ -f /etc/config/https-dns-proxy ] || run_cmd touch /etc/config/https-dns-proxy

    while uci -q get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; do
        run_uci -q delete https-dns-proxy.@https-dns-proxy[0]
    done

    # Primary
    run_uci add https-dns-proxy https-dns-proxy
    run_uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$DOH_PRIMARY_BOOTSTRAP"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$DOH_PRIMARY_URL"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
    run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_port="$DOH_PRIMARY_PORT"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
    run_uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'

    # Secondary
    run_uci add https-dns-proxy https-dns-proxy
    run_uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$DOH_SECONDARY_BOOTSTRAP"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$DOH_SECONDARY_URL"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
    run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_port="$DOH_SECONDARY_PORT"
    run_uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
    run_uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'
    run_uci commit https-dns-proxy

    run_uci set dhcp.@dnsmasq[0].cachesize='5000'
    run_uci set dhcp.@dnsmasq[0].noresolv='1'
    run_uci -q delete dhcp.@dnsmasq[0].server || true
    run_uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_PRIMARY_PORT}"
    run_uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_SECONDARY_PORT}"

    run_uci -q delete dhcp.@dnsmasq[0].address || true
    run_uci add_list dhcp.@dnsmasq[0].address='/use-application-dns.net/'
    run_uci add_list dhcp.@dnsmasq[0].address='/mask.icloud.com/'
    run_uci add_list dhcp.@dnsmasq[0].address='/mask-h2.icloud.com/'

    if [ "$DISABLE_IPV6" = "1" ]; then
        run_uci set dhcp.lan.dhcpv6='disabled'
        run_uci set dhcp.lan.ra='disabled'
        run_uci set dhcp.lan.ndp='disabled'
        run_cmd /etc/init.d/odhcpd disable 2>/dev/null || true
        run_cmd /etc/init.d/odhcpd stop 2>/dev/null || true
    fi
    run_uci commit dhcp
    log_ok "DNS config committed."
}

setup_firewall() {
    log_step "Configuring firewall..."
    ping_rule=$(uci show firewall 2>/dev/null | grep "name='Allow-Ping'" | awk -F'.' '{print $2}' || true)
    [ -n "$ping_rule" ] && run_uci set firewall.${ping_rule}.target='DROP'

    for rule_name in "Allow-IPSec-ESP" "Allow-ISAKMP"; do
        r=$(uci show firewall 2>/dev/null | grep "name='${rule_name}'" | awk -F'.' '{print $2}' || true)
        [ -n "$r" ] && run_uci delete firewall.${r}
    done

    for z in wan1 wan2 wan3 wan4 wan5 wwan2; do
        run_uci -q delete firewall.$z || true
    done

    # Ensure wwan interface is in the default wan zone for NAT/Internet access
    _wan_zone=$(uci show firewall 2>/dev/null | grep "name='wan'" | awk -F'.' '{print $2}' | head -1 || true)
    if [ -n "$_wan_zone" ]; then
        run_uci del_list firewall.${_wan_zone}.network='wwan' 2>/dev/null || true
        run_uci add_list firewall.${_wan_zone}.network='wwan'
    fi

    if [ "$ENABLE_TAILSCALE" = "1" ]; then
        _ts_zone=$(uci show firewall 2>/dev/null | grep "name='tailscale'" | awk -F'.' '{print $2}' || true)
        if [ -z "$_ts_zone" ]; then
            run_uci add firewall zone
            run_uci set firewall.@zone[-1].name='tailscale'
            run_uci set firewall.@zone[-1].input='ACCEPT'
            run_uci set firewall.@zone[-1].output='ACCEPT'
            run_uci set firewall.@zone[-1].forward='ACCEPT'
            run_uci set firewall.@zone[-1].masq='1'
            run_uci set firewall.@zone[-1].mtu_fix='1'
            run_uci add_list firewall.@zone[-1].device='tailscale0'

            run_uci add firewall forwarding
            run_uci set firewall.@forwarding[-1].src='lan'
            run_uci set firewall.@forwarding[-1].dest='tailscale'

            run_uci add firewall forwarding
            run_uci set firewall.@forwarding[-1].src='tailscale'
            run_uci set firewall.@forwarding[-1].dest='lan'
        fi
    fi

    if [ "$ENABLE_WANUSB_ZONE" = "1" ]; then
        _usb_zone=$(uci show firewall 2>/dev/null | grep "name='wanusb'" | awk -F'.' '{print $2}' || true)
        if [ -z "$_usb_zone" ]; then
            run_uci add firewall zone
            run_uci set firewall.@zone[-1].name='wanusb'
            run_uci set firewall.@zone[-1].input='REJECT'
            run_uci set firewall.@zone[-1].output='ACCEPT'
            run_uci set firewall.@zone[-1].forward='REJECT'
            run_uci set firewall.@zone[-1].masq='1'
            run_uci set firewall.@zone[-1].mtu_fix='1'
            run_uci add_list firewall.@zone[-1].network='wanusb'

            run_uci add firewall forwarding
            run_uci set firewall.@forwarding[-1].src='lan'
            run_uci set firewall.@forwarding[-1].dest='wanusb'
        fi
    fi

    run_uci commit firewall
    log_ok "Firewall config committed."
}

setup_cron_adblock() {
    log_step "Configuring cron + adblock-lean..."
    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/crontabs/root << 'CRON'
0 3 * * 0 reboot
0 5 * * * RANDOM_DELAY=1 /etc/init.d/adblock-lean start 1>/dev/null
CRON
    fi

    if [ "$ENABLE_ADBLOCK_LEAN" = "1" ] && [ "$DRY_RUN" = "0" ]; then
        uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh -O /tmp/abl-install.sh
        if [ -f /tmp/abl-install.sh ]; then
            sh /tmp/abl-install.sh -v release
            rm -f /tmp/abl-install.sh
        fi
    fi

    run_cmd service cron enable || true
    log_ok "Cron service enabled."
}

enable_services() {
    log_step "Enabling services..."
    if [ "$DRY_RUN" = "0" ]; then
        for svc in zram zram-setup zram-swap; do
            [ -f /etc/init.d/$svc ] && service $svc enable
        done
        for svc in watchcat watchcat-script; do
            [ -f /etc/init.d/$svc ] && service $svc enable
        done
        [ "$ENABLE_TAILSCALE" = "1" ] && [ -f /etc/init.d/tailscale ] && service tailscale enable
        sysctl -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true

        # Write post-reboot init
        cat > /etc/rc.local << RCEOF
#!/bin/sh
[ -f /tmp/.setup_done ] && exit 0
touch /tmp/.setup_done
sleep 10
wifi reload
/etc/init.d/sqm            restart
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq         restart
/etc/init.d/firewall        restart
[ -f /etc/init.d/adblock-lean ] && /etc/init.d/adblock-lean start
[ -f /etc/init.d/tailscale    ] && /etc/init.d/tailscale    restart
rm -f /etc/rc.local
exit 0
RCEOF
        chmod +x /etc/rc.local
    fi
}

main() {
    load_config
    pre_flight_checks
    backup_uci

    setup_packages
    setup_system
    setup_network
    setup_wireless
    setup_sqm
    setup_tuning
    setup_dns
    setup_firewall
    setup_cron_adblock
    enable_services

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    printf "\n${BOLD}============================================================${NC}\n"
    printf "${GREEN}  Configuration complete. Elapsed time: %ds${NC}\n" "$ELAPSED"
    printf "${BOLD}============================================================${NC}\n"

    if [ "$DRY_RUN" = "1" ]; then
        exit 0
    fi

    if [ "$NO_REBOOT" = "1" ]; then
        log_info "Reboot skipped as requested (--no-reboot)."
    else
        log_info "Rebooting in 5 seconds..."
        sleep 5
        run_cmd reboot
    fi
}

main