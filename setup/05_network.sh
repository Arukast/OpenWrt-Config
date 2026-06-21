# Network setup module

setup_network() {
    log_step "Configuring network..."

    [ -n "$LAN_PORTS" ] && run_uci set network.@device[0].ports="$LAN_PORTS"
    
    _wan_dev=$(jsonfilter -e '@.network.wan.device' < /etc/board.json 2>/dev/null || true)
    [ -z "$_wan_dev" ] && _wan_dev=$(jsonfilter -e '@.network.wan.ifname' < /etc/board.json 2>/dev/null || true)

    if [ "$CONNECTION_MODE" = "WISP" ] && [ "$USE_WAN_AS_LAN" = "1" ]; then
        if [ -n "$_wan_dev" ]; then
            run_uci del_list network.@device[0].ports="$_wan_dev" 2>/dev/null || true
            run_uci add_list network.@device[0].ports="$_wan_dev"
        fi
    else
        if [ -n "$_wan_dev" ]; then
            run_uci del_list network.@device[0].ports="$_wan_dev" 2>/dev/null || true
        fi
    fi

    # LAN Config
    run_uci set network.lan.ipaddr="$LAN_IP"
    run_uci set network.lan.netmask="$LAN_NETMASK"
    if [ "$ENABLE_IPV6" = "1" ]; then
        run_uci -q delete network.lan.ip6addr || true
        run_uci add_list network.lan.ip6addr="fd11:2233:4455::1/64"
    fi

    if [ "$CONNECTION_MODE" = "WISP" ]; then
        run_uci -q delete network.wan  || true
        run_uci -q delete network.wan6 || true
        
        # WISP Config
        run_uci set network.wwan='interface'
        run_uci set network.wwan.proto='dhcp'
        run_uci set network.wwan.device="$WWAN_IFACE"
        run_uci set network.wwan.mtu="$SQM_MTU"
        run_uci set network.wwan.peerdns='0'
        run_uci -q delete network.wwan.dns || true
        run_uci add_list network.wwan.dns='1.1.1.1'
        run_uci add_list network.wwan.dns='9.9.9.9'

        run_uci set network.globals.packet_steering='2'
        if [ "$ENABLE_IPV6" = "1" ]; then
            # Remove ULA Prefix to prevent routing confusion on LAN clients in WISP relay mode
            run_uci -q delete network.globals.ula_prefix || true
            run_uci set network.wwan6='interface'
            run_uci set network.wwan6.proto='dhcpv6'
            run_uci set network.wwan6.device="$WWAN_IFACE"
            run_uci set network.wwan6.reqaddress='try'
            run_uci set network.wwan6.reqprefix='auto'
            run_uci set network.wwan6.peerdns='0'
            run_uci -q delete network.wwan6.dns || true
            run_uci add_list network.wwan6.dns="$IPV6_DNS_PRIMARY"
            run_uci add_list network.wwan6.dns="$IPV6_DNS_SECONDARY"

            # Auto-bind wireless WISP client STA interfaces in wireless config to both networks 'wwan' and 'wwan6'
            for w_iface in $(uci show wireless 2>/dev/null | grep -E "\.mode='sta'|\.mode='client'" | awk -F'.' '{print $2}' || true); do
                run_uci set wireless.${w_iface}.network='wwan wwan6'
            done
            run_uci -q commit wireless || true
        else
            run_uci set network.lan.ipv6='0'
        fi
    else
        # WIRED Config
        run_uci -q delete network.wwan || true
        run_uci -q delete network.wwan6 || true
        
        _wan_dev=$(jsonfilter -e '@.network.wan.device' < /etc/board.json 2>/dev/null || true)
        [ -z "$_wan_dev" ] && _wan_dev=$(jsonfilter -e '@.network.wan.ifname' < /etc/board.json 2>/dev/null || true)
        
        if ! uci -q get network.wan >/dev/null 2>&1; then
            run_uci set network.wan='interface'
            run_uci set network.wan.proto='dhcp'
            [ -n "$_wan_dev" ] && run_uci set network.wan.device="$_wan_dev"
        fi
        run_uci set network.wan.mtu="$SQM_MTU"
        run_uci set network.wan.peerdns='0'
        run_uci -q delete network.wan.dns || true
        run_uci add_list network.wan.dns='1.1.1.1'
        run_uci add_list network.wan.dns='9.9.9.9'
        
        run_uci set network.globals.packet_steering='2'
        if [ "$ENABLE_IPV6" = "1" ]; then
            run_uci -q delete network.globals.ula_prefix || true
            if ! uci -q get network.wan6 >/dev/null 2>&1; then
                run_uci set network.wan6='interface'
                run_uci set network.wan6.proto='dhcpv6'
                [ -n "$_wan_dev" ] && run_uci set network.wan6.device="$_wan_dev"
            fi
            run_uci set network.wan6.reqaddress='try'
            run_uci set network.wan6.reqprefix='auto'
            run_uci set network.wan6.peerdns='0'
            run_uci -q delete network.wan6.dns || true
            run_uci add_list network.wan6.dns="$IPV6_DNS_PRIMARY"
            run_uci add_list network.wan6.dns="$IPV6_DNS_SECONDARY"
        else
            run_uci set network.lan.ipv6='0'
            run_uci -q delete network.wan6 || true
        fi
    fi

    run_uci commit network
    log_ok "Network config committed."
}
