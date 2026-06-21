# Common helper functions and globals for OpenWrt Setup Script

# --- Colors & Logging ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

run_uci() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "  [DRY-RUN] uci $*"
    else
        uci "$@"
    fi
}

run_cmd() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

load_config() {
    log_step "Loading Configuration..."
    if [ -z "${CONFIG_FILE:-}" ]; then
        if [ -f "./setup.conf" ]; then
            CONFIG_FILE="./setup.conf"
        elif [ -f "/etc/openwrt-setup.conf" ]; then
            CONFIG_FILE="/etc/openwrt-setup.conf"
        fi
    fi

    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
        log_info "Loading configuration from $CONFIG_FILE"
        case "$CONFIG_FILE" in
            */*) . "$CONFIG_FILE" ;;
              *) . "./$CONFIG_FILE" ;;
        esac
        # Save config file permanently to the router's /etc so that OpenWrtSetupTest.sh can always find it
        if [ "${DRY_RUN:-0}" = "0" ] && [ "$CONFIG_FILE" != "/etc/openwrt-setup.conf" ]; then
            cp -f "$CONFIG_FILE" /etc/openwrt-setup.conf 2>/dev/null || true
            chmod 600 /etc/openwrt-setup.conf 2>/dev/null || true
        fi
    else
        log_info "No configuration file found or specified."
    fi

    # Set defaults if not provided by config file
    : ${HOSTNAME:="OpenWrt-WISP"}
    : ${TIMEZONE:="WIB-7"}
    : ${ZONENAME:="Asia/Jakarta"}
    : ${LAN_IP:="192.168.11.1"}
    : ${LAN_NETMASK:="255.255.255.0"}
    : ${CONNECTION_MODE:="WISP"}
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
    # Backward compatibility mappings for legacy config files
    if [ -n "${DOH_PRIMARY_URL:-}" ]; then
        : ${DOH_1_BOOTSTRAP:="$DOH_PRIMARY_BOOTSTRAP"}
        : ${DOH_1_URL:="$DOH_PRIMARY_URL"}
        : ${DOH_1_PORT:="$DOH_PRIMARY_PORT"}
    fi
    if [ -n "${DOH_SECONDARY_URL:-}" ]; then
        : ${DOH_2_BOOTSTRAP:="$DOH_SECONDARY_BOOTSTRAP"}
        : ${DOH_2_URL:="$DOH_SECONDARY_URL"}
        : ${DOH_2_PORT:="$DOH_SECONDARY_PORT"}
    fi

    # Resolver 1: Quad9 (Safety + Privacy focus)
    : ${DOH_1_BOOTSTRAP:="9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9"}
    : ${DOH_1_URL:="https://dns.quad9.net/dns-query"}
    : ${DOH_1_PORT:="5053"}

    # Resolver 2: Cloudflare Security (Speed + Malware block)
    : ${DOH_2_BOOTSTRAP:="1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002"}
    : ${DOH_2_URL:="https://security.cloudflare-dns.com/dns-query"}
    : ${DOH_2_PORT:="5054"}

    # Resolver 3: AdGuard DNS (Adblocking/Privacy backup)
    : ${DOH_3_BOOTSTRAP:="94.140.14.14,94.140.15.15,2a10:50c0::ad1:ff,2a10:50c0::ad2:ff"}
    : ${DOH_3_URL:="https://dns.adguard-dns.com/dns-query"}
    : ${DOH_3_PORT:="5055"}

    # Resolver 4: Cloudflare Standard (Ultimate speed & reliability backup)
    : ${DOH_4_BOOTSTRAP:="1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"}
    : ${DOH_4_URL:="https://cloudflare-dns.com/dns-query"}
    : ${DOH_4_PORT:="5056"}

    : ${IPV6_DNS_PRIMARY:="2606:4700:4700::1111"}
    : ${IPV6_DNS_SECONDARY:="2620:fe::fe"}
    : ${NTP_SERVERS:="0.id.pool.ntp.org 1.id.pool.ntp.org 2.id.pool.ntp.org 3.id.pool.ntp.org"}
    : ${ENABLE_TAILSCALE:=1}
    : ${ENABLE_ADBLOCK_LEAN:=1}
    : ${ENABLE_WANUSB_ZONE:=0}
    : ${ENABLE_IPV6:=1}
    : ${USE_WAN_AS_LAN:=1}
    : ${ENABLE_WIREGUARD:=1}
    : ${ENABLE_USTEER:=1}
    : ${ENABLE_BANDWIDTH_MONITOR:=1}
    : ${ENABLE_TRAFFIC_MONITOR:=1}
    : ${WG_PORT:="51820"}
    : ${WG_IPV4_SUBNET:="10.8.0.1/24"}
    : ${WG_IPV6_SUBNET:="fd11:2233:4455::1/64"}
    : ${WG_CLIENTS:=""}
    : ${ENABLE_WG_DDNS:=0}
    : ${WG_DDNS_DOMAIN:="yourdomain.duckdns.org"}
    : ${WG_DDNS_TOKEN:="your-duckdns-token"}
    : ${WG_ALLOW_ADMIN:=1}

    if [ "$WIFI_KEY" = "CHANGE_ME" ] || [ "$WIFI_KEY" = "CHANGE_ME_SUPER_SECRET_KEY" ]; then
        _abort "WIFI_KEY is not set to a secure value. Please update your config file."
    fi
}
