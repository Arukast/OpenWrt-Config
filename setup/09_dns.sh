# DNS setup module

setup_dns() {
    log_step "Configuring DoH + dnsmasq..."
    [ -f /etc/config/https-dns-proxy ] || run_cmd touch /etc/config/https-dns-proxy

    while uci -q get https-dns-proxy.@https-dns-proxy[0] >/dev/null 2>&1; do
        run_uci -q delete https-dns-proxy.@https-dns-proxy[0]
    done

    run_uci set dhcp.@dnsmasq[0].cachesize='5000'
    run_uci set dhcp.@dnsmasq[0].noresolv='1'
    run_uci set dhcp.@dnsmasq[0].localservice='1'
    run_uci -q delete dhcp.@dnsmasq[0].interface || true
    run_uci add_list dhcp.@dnsmasq[0].interface='lan'
    run_uci add_list dhcp.@dnsmasq[0].interface='wg0'
    [ "$ENABLE_TAILSCALE" = "1" ] && run_uci add_list dhcp.@dnsmasq[0].interface='tailscale0'
    run_uci -q delete dhcp.@dnsmasq[0].server || true

    for idx in 1 2 3 4; do
        eval bootstrap="\$DOH_${idx}_BOOTSTRAP"
        eval url="\$DOH_${idx}_URL"
        eval port="\$DOH_${idx}_PORT"

        if [ -n "$url" ] && [ -n "$bootstrap" ] && [ -n "$port" ]; then
            log_info "Configuring DoH Resolver ${idx}: ${url}"
            run_uci add https-dns-proxy https-dns-proxy
            run_uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$bootstrap"
            run_uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$url"
            run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
            run_uci set https-dns-proxy.@https-dns-proxy[-1].listen_port="$port"
            run_uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
            run_uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'

            run_uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${port}"
        fi
    done
    run_uci set https-dns-proxy.config.procd_trigger_wan6="$ENABLE_IPV6"
    run_uci commit https-dns-proxy

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
        
        # Point clients to the router's stable Unique Local Address to ensure queries go through Dnsmasq (DoH + Adblock)
        run_uci -q delete dhcp.lan.dns || true
        run_uci add_list dhcp.lan.dns="fd11:2233:4455::1"

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
