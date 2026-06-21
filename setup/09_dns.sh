# DNS setup module

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
    run_uci set https-dns-proxy.config.procd_trigger_wan6="$ENABLE_IPV6"
    run_uci commit https-dns-proxy

    run_uci set dhcp.@dnsmasq[0].cachesize='5000'
    run_uci set dhcp.@dnsmasq[0].noresolv='1'
    run_uci set dhcp.@dnsmasq[0].localservice='0'
    run_uci -q delete dhcp.@dnsmasq[0].server || true
    run_uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_PRIMARY_PORT}"
    run_uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DOH_SECONDARY_PORT}"

    run_uci -q delete dhcp.@dnsmasq[0].address || true
    run_uci add_list dhcp.@dnsmasq[0].address='/use-application-dns.net/'
    run_uci add_list dhcp.@dnsmasq[0].address='/mask.icloud.com/'
    run_uci add_list dhcp.@dnsmasq[0].address='/mask-h2.icloud.com/'

    if [ "$CONNECTION_MODE" = "WISP" ]; then
        _wan6_if="wwan6"
    else
        _wan6_if="wan6"
    fi

    if [ "$ENABLE_IPV6" = "1" ]; then
        run_uci set dhcp.lan.dhcpv6='relay'
        run_uci set dhcp.lan.ra='relay'
        run_uci set dhcp.lan.ndp='relay'
        
        # Point clients to the router's Link-Local address to ensure queries go through Dnsmasq (DoH + Adblock)
        # We find the fe80:: address of br-lan dynamically
        _lan_ll_addr=$(ip -6 addr show dev br-lan 2>/dev/null | awk '/inet6 fe80/{print $2}' | cut -d/ -f1 | head -n1)
        run_uci -q delete dhcp.lan.dns || true
        if [ -n "$_lan_ll_addr" ]; then
            log_info "Detected LAN IPv6 Link-Local: $_lan_ll_addr"
            run_uci add_list dhcp.lan.dns="$_lan_ll_addr"
        else
            # Fallback to external if LL not yet assigned (unlikely, but safe)
            run_uci add_list dhcp.lan.dns="$IPV6_DNS_PRIMARY"
            run_uci add_list dhcp.lan.dns="$IPV6_DNS_SECONDARY"
        fi

        run_uci -q delete dhcp.${_wan6_if} || true
        run_uci set dhcp.${_wan6_if}='dhcp'
        run_uci set dhcp.${_wan6_if}.interface="${_wan6_if}"
        run_uci set dhcp.${_wan6_if}.dhcpv6='relay'
        run_uci set dhcp.${_wan6_if}.ra='relay'
        run_uci set dhcp.${_wan6_if}.ndp='relay'
        run_uci set dhcp.${_wan6_if}.master='1'
        
        if [ "$CONNECTION_MODE" = "WISP" ]; then
            run_uci -q delete dhcp.wan6 || true
        else
            run_uci -q delete dhcp.wwan6 || true
        fi
        run_cmd /etc/init.d/odhcpd enable 2>/dev/null || true
    else
        run_uci set dhcp.lan.dhcpv6='disabled'
        run_uci set dhcp.lan.ra='disabled'
        run_uci set dhcp.lan.ndp='disabled'
        run_cmd /etc/init.d/odhcpd disable 2>/dev/null || true
        run_cmd /etc/init.d/odhcpd stop 2>/dev/null || true
    fi
    run_uci commit dhcp
    log_ok "DNS config committed."
}
