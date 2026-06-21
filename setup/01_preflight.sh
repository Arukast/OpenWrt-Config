# Pre-flight check functions

pre_flight_checks() {
    log_step "Pre-flight Checks..."

    [ "$(id -u)" -ne 0 ] && _abort "This script must be run as root."
    [ ! -x "/sbin/uci" ] && _abort "UCI not found. Are you running this on OpenWrt?"

    # Variable Validation
    [ "$CONNECTION_MODE" != "WISP" ] && [ "$CONNECTION_MODE" != "WIRED" ] && _abort "CONNECTION_MODE must be WISP or WIRED."
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
        printf "  Mode      : %s\n" "$CONNECTION_MODE"
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
