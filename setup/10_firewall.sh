# Firewall setup module

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

    if [ "$CONNECTION_MODE" = "WISP" ]; then
        _wan_if="wwan"
        _wan6_if="wwan6"
        _other_if="wan"
        _other6_if="wan6"
    else
        _wan_if="wan"
        _wan6_if="wan6"
        _other_if="wwan"
        _other6_if="wwan6"
    fi

    # Ensure correct interface is in the default wan zone for NAT/Internet access
    _wan_zone=$(uci show firewall 2>/dev/null | grep "name='wan'" | awk -F'.' '{print $2}' | head -1 || true)
    if [ -n "$_wan_zone" ]; then
        run_uci del_list firewall.${_wan_zone}.network="$_other_if" 2>/dev/null || true
        run_uci del_list firewall.${_wan_zone}.network="$_other6_if" 2>/dev/null || true
        
        run_uci del_list firewall.${_wan_zone}.network="$_wan_if" 2>/dev/null || true
        run_uci add_list firewall.${_wan_zone}.network="$_wan_if"
        if [ "$ENABLE_IPV6" = "1" ]; then
            run_uci del_list firewall.${_wan_zone}.network="$_wan6_if" 2>/dev/null || true
            run_uci add_list firewall.${_wan_zone}.network="$_wan6_if"
        fi
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

    # Intercept and redirect all DNS traffic on port 53 to local resolver to prevent DNS leaks
    for r in $(uci show firewall 2>/dev/null | grep -E "name='Intercept-DNS|name='Intercept-DNS-IPv6'" | awk -F'.' '{print $2}' || true); do
        [ -n "$r" ] && run_uci -q delete firewall.${r}
    done

    # IPv4 DNS Intercept
    run_uci add firewall redirect
    run_uci set firewall.@redirect[-1].name='Intercept-DNS'
    run_uci set firewall.@redirect[-1].src='lan'
    run_uci set firewall.@redirect[-1].src_dport='53'
    run_uci set firewall.@redirect[-1].proto='tcp udp'
    run_uci set firewall.@redirect[-1].dest_port='53'
    run_uci set firewall.@redirect[-1].target='DNAT'
    run_uci set firewall.@redirect[-1].family='ipv4'

    if [ "$ENABLE_IPV6" = "1" ]; then
        # IPv6 DNS Intercept
        run_uci add firewall redirect
        run_uci set firewall.@redirect[-1].name='Intercept-DNS-IPv6'
        run_uci set firewall.@redirect[-1].src='lan'
        run_uci set firewall.@redirect[-1].src_dport='53'
        run_uci set firewall.@redirect[-1].proto='tcp udp'
        run_uci set firewall.@redirect[-1].dest_port='53'
        run_uci set firewall.@redirect[-1].target='DNAT'
        run_uci set firewall.@redirect[-1].family='ipv6'
    fi

    # Block DNS-over-TLS (DoT) to force clients to fall back to standard DNS (which is intercepted)
    for r in $(uci show firewall 2>/dev/null | grep -E "name='Block-DoT'" | awk -F'.' '{print $2}' || true); do
        [ -n "$r" ] && run_uci -q delete firewall.${r}
    done

    run_uci add firewall rule
    run_uci set firewall.@rule[-1].name='Block-DoT'
    run_uci set firewall.@rule[-1].src='lan'
    run_uci set firewall.@rule[-1].dest='wan'
    run_uci set firewall.@rule[-1].dest_port='853'
    run_uci set firewall.@rule[-1].proto='tcp udp'
    run_uci set firewall.@rule[-1].target='REJECT'

    run_uci commit firewall
    log_ok "Firewall config committed."
}
