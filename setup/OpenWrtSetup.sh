#!/bin/sh
# =============================================================================
#  OpenWrt Universal Setup Script (Modularized & Flat)
#  Compatible: OpenWrt 23.05+ (apk package manager)
# =============================================================================

# --- Strict Mode & Globals ---
set -u
START_TIME=$(date +%s)
LOG_FILE="/tmp/openwrt-setup.log"

# Initialize log file
> "$LOG_FILE"

# --- CLI Arguments ---
DRY_RUN=0
NO_REBOOT=0
AUTO_YES=0
CONFIG_FILE=""
TARGET_MODULE=""

list_modules() {
    echo "Available modules:"
    echo "  preflight    - Run pre-flight validations & network connectivity checks"
    echo "  backup       - Export existing UCI configs to /tmp"
    echo "  packages     - Install core/roaming packages and strip bloatware"
    echo "  system       - Configure hostname, timezone and NTP servers"
    echo "  network      - Setup LAN/WAN interfaces & WISP client configs"
    echo "  wireless     - Setup radio channels, WPA3 AP, 802.11r/k/v, and Usteer"
    echo "  sqm          - Configure SQM CAKE QoS rates & overhead parameters"
    echo "  tuning       - Configure ZRAM, Watchcat, and sysctl/TCP performance options"
    echo "  dns          - Setup DoH resolvers and dnsmasq relay rules"
    echo "  firewall     - Setup custom security zones and Intercept-DNS redirections"
    echo "  wireguard    - Generate server/client WG keys, DuckDNS, profiles & QR codes"
    echo "  cron_adblock - Configure crontab schedule and install adblock-lean"
    echo "  services     - Enable system startup services and write rc.local post-reboot logic"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --yes) AUTO_YES=1 ;;
        --config)
            CONFIG_FILE="$2"
            shift
            ;;
        --module)
            TARGET_MODULE="$2"
            shift
            ;;
        --list-modules)
            list_modules
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# --- Locate and Load Modules ---
MODULES_DIR="$(dirname "$0")"
if [ ! -f "$MODULES_DIR/common.sh" ]; then
    MODULES_DIR="."
fi

if [ ! -f "$MODULES_DIR/common.sh" ]; then
    echo "Error: common.sh not found in $MODULES_DIR" >&2
    exit 1
fi

# Source common helpers
. "$MODULES_DIR/common.sh"

# Set trap using function defined in common.sh
trap _on_exit EXIT

# Source all other modules to define function implementations
for mod_script in "$MODULES_DIR"/[0-9]*.sh; do
    if [ -f "$mod_script" ]; then
        . "$mod_script"
    fi
done

run_single_module() {
    local mod="$1"
    case "$mod" in
        preflight)      pre_flight_checks ;;
        backup)         backup_uci ;;
        packages)       setup_packages ;;
        system)         setup_system ;;
        network)        setup_network ;;
        wireless)
            setup_wireless
            setup_usteer
            ;;
        sqm)            setup_sqm ;;
        tuning)         setup_tuning ;;
        dns)            setup_dns ;;
        firewall)       setup_firewall ;;
        wireguard)      setup_wireguard ;;
        cron_adblock)   setup_cron_adblock ;;
        services)       enable_services ;;
        *)
            log_error "Unknown module: $mod"
            list_modules
            exit 1
            ;;
    esac
}

main() {
    load_config

    if [ -n "$TARGET_MODULE" ]; then
        log_info "Executing target module: $TARGET_MODULE"
        run_single_module "$TARGET_MODULE"
        log_ok "Module $TARGET_MODULE complete."
        exit 0
    fi

    log_info "Starting OpenWrt Setup Script ($CONNECTION_MODE Mode)"
    pre_flight_checks
    backup_uci

    setup_packages
    setup_system
    setup_network
    setup_wireless
    setup_usteer
    setup_sqm
    setup_tuning
    setup_dns
    setup_firewall
    setup_wireguard
    setup_cron_adblock
    enable_services

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))

    printf "\n${BOLD}============================================================${NC}\n"
    printf "${GREEN}  Configuration complete. Elapsed time: %dm %ds${NC}\n" "$MINUTES" "$SECONDS"
    printf "${BOLD}============================================================${NC}\n"

    if [ "$ENABLE_WIREGUARD" = "1" ] && [ "$DRY_RUN" = "0" ]; then
        printf "\n${BOLD}============================================================${NC}\n"
        printf "${GREEN}  WIREGUARD VPN QR CODES (Split Tunnel)${NC}\n"
        printf "  Scan with the official WireGuard app on your phone.\n"
        printf "${BOLD}============================================================${NC}\n"
        for client in $WG_CLIENTS; do
            if [ -f "/etc/wireguard/clients/${client}_split.conf" ]; then
                printf "\n${BOLD}>>> Client: %s (Split Tunnel)${NC}\n" "$client"
                qrencode -t ansiutf8 < "/etc/wireguard/clients/${client}_split.conf"
                printf "Config file saved at: /etc/wireguard/clients/%s_split.conf\n" "$client"
            fi
        done
        printf "${BOLD}============================================================${NC}\n"
    fi

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
