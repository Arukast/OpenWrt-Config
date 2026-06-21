# WireGuard setup module

setup_wireguard() {
    if [ "$ENABLE_WIREGUARD" != "1" ]; then
        log_info "WireGuard is disabled. Skipping."
        return 0
    fi
    log_step "Configuring WireGuard over IPv6..."

    if [ "$DRY_RUN" = "1" ]; then
        log_info "[DRY-RUN] Create keys directory and generate server private/public keys"
        _srv_pub="DRY_RUN_SERVER_PUBLIC_KEY"
    else
        run_cmd mkdir -p -m 700 /etc/wireguard/clients
        run_cmd chmod 700 /etc/wireguard/clients
        if [ ! -f /etc/wireguard/server.key ]; then
            log_info "Generating WireGuard server keys..."
            (umask 077 && wg genkey > /etc/wireguard/server.key)
            wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
        else
            log_info "WireGuard server keys already exist. Reusing."
        fi
        _srv_pub=$(cat /etc/wireguard/server.pub)
    fi

    # Delete existing wg0 interface config to ensure idempotency
    run_uci -q delete network.wg0 || true

    # Configure Network Interface wg0
    run_uci set network.wg0='interface'
    run_uci set network.wg0.proto='wireguard'
    if [ "$DRY_RUN" = "0" ]; then
        run_uci set network.wg0.private_key="$(cat /etc/wireguard/server.key)"
    else
        run_uci set network.wg0.private_key="DRY_RUN_PRIVATE_KEY"
    fi
    run_uci set network.wg0.listen_port="$WG_PORT"
    run_uci set network.wg0.mtu='1280'
    run_uci add_list network.wg0.addresses="$WG_IPV4_SUBNET"
    run_uci add_list network.wg0.addresses="$WG_IPV6_SUBNET"

    # Remove any existing wg firewall zone, forwarding rules, and WAN port opening
    _wg_zone=$(uci show firewall 2>/dev/null | grep "name='wg'" | awk -F'.' '{print $2}' || true)
    if [ -n "$_wg_zone" ]; then
        run_uci delete firewall.${_wg_zone}
    fi

    # Remove existing forwardings with 'wg'
    for fwd in $(uci show firewall 2>/dev/null | grep "=forwarding$" | awk -F'=' '{print $1}'); do
        src=$(uci -q get ${fwd}.src || true)
        dest=$(uci -q get ${fwd}.dest || true)
        if [ "$src" = "wg" ] || [ "$dest" = "wg" ]; then
            run_uci delete ${fwd}
        fi
    done

    # Remove existing WAN port opening and custom DNS/Admin rules
    for r_name in Allow-WireGuard-IPv6 Allow-WireGuard-DNS Allow-WireGuard-Admin; do
        _rule=$(uci show firewall 2>/dev/null | grep "name='${r_name}'" | awk -F'.' '{print $2}' || true)
        [ -n "$_rule" ] && run_uci delete firewall.${_rule}
    done

    # 1. Add Firewall Zone
    run_uci add firewall zone
    run_uci set firewall.@zone[-1].name='wg'
    run_uci set firewall.@zone[-1].input='REJECT'
    run_uci set firewall.@zone[-1].forward='ACCEPT'
    run_uci set firewall.@zone[-1].output='ACCEPT'
    run_uci set firewall.@zone[-1].masq='1'
    run_uci set firewall.@zone[-1].mtu_fix='1'
    run_uci add_list firewall.@zone[-1].network='wg0'

    # 2. Add Forwardings
    run_uci add firewall forwarding
    run_uci set firewall.@forwarding[-1].src='wg'
    run_uci set firewall.@forwarding[-1].dest='lan'

    run_uci add firewall forwarding
    run_uci set firewall.@forwarding[-1].src='lan'
    run_uci set firewall.@forwarding[-1].dest='wg'

    run_uci add firewall forwarding
    run_uci set firewall.@forwarding[-1].src='wg'
    run_uci set firewall.@forwarding[-1].dest='wan'

    # 3. Open incoming UDP port on WAN (IPv6)
    run_uci add firewall rule
    run_uci set firewall.@rule[-1].name='Allow-WireGuard-IPv6'
    run_uci set firewall.@rule[-1].src='wan'
    run_uci set firewall.@rule[-1].family='ipv6'
    run_uci set firewall.@rule[-1].proto='udp'
    run_uci set firewall.@rule[-1].dest_port="$WG_PORT"
    run_uci set firewall.@rule[-1].target='ACCEPT'

    # 4. Allow DNS queries from the VPN clients to the router local service
    run_uci add firewall rule
    run_uci set firewall.@rule[-1].name='Allow-WireGuard-DNS'
    run_uci set firewall.@rule[-1].src='wg'
    run_uci set firewall.@rule[-1].dest_port='53'
    run_uci set firewall.@rule[-1].proto='udp tcp'
    run_uci set firewall.@rule[-1].target='ACCEPT'

    # 5. Conditionally permit SSH and LuCI administrative access to the router
    if [ "$WG_ALLOW_ADMIN" = "1" ]; then
        run_uci add firewall rule
        run_uci set firewall.@rule[-1].name='Allow-WireGuard-Admin'
        run_uci set firewall.@rule[-1].src='wg'
        run_uci set firewall.@rule[-1].dest_port='22 80 443'
        run_uci set firewall.@rule[-1].proto='tcp'
        run_uci set firewall.@rule[-1].target='ACCEPT'
    fi

    # DuckDNS Configuration
    if [ "$ENABLE_WG_DDNS" = "1" ]; then
        log_info "Configuring DuckDNS updater..."
        run_uci -q delete ddns.duckdns || true
        
        run_uci set ddns.duckdns='service'
        run_uci set ddns.duckdns.enabled='1'
        run_uci set ddns.duckdns.lookup_host="$WG_DDNS_DOMAIN"
        run_uci set ddns.duckdns.domain="$WG_DDNS_DOMAIN"
        _subdomain="${WG_DDNS_DOMAIN%%.*}"
        run_uci set ddns.duckdns.username="$_subdomain"
        run_uci set ddns.duckdns.password="$WG_DDNS_TOKEN"
        run_uci set ddns.duckdns.update_url='https://www.duckdns.org/update?domains=[USERNAME]&token=[PASSWORD]&ipv6=[IP]'
        run_uci set ddns.duckdns.use_ipv6='1'
        run_uci set ddns.duckdns.ip_source='web'
        run_uci set ddns.duckdns.ip_url='http://v6.ident.me'
        run_uci set ddns.duckdns.check_interval='10'
        run_uci set ddns.duckdns.check_unit='minutes'
    else
        log_info "DuckDNS DDNS is disabled. Client endpoints will use direct IPv6 addresses."
        run_uci -q delete ddns.duckdns || true
    fi

    # Client provisioning
    _client_idx=2
    _endpoint=""
    if [ "$ENABLE_WG_DDNS" = "1" ] && [ -n "$WG_DDNS_DOMAIN" ]; then
        _endpoint="$WG_DDNS_DOMAIN"
    else
        if [ "$DRY_RUN" = "0" ]; then
            if [ "$CONNECTION_MODE" = "WISP" ]; then
                _endpoint=$(ip -6 addr show dev "$WWAN_IFACE" 2>/dev/null | awk '/inet6.*global/{print $2}' | cut -d/ -f1 | head -1)
            else
                _wan_dev=$(jsonfilter -e '@.network.wan.device' < /etc/board.json 2>/dev/null || true)
                [ -z "$_wan_dev" ] && _wan_dev=$(jsonfilter -e '@.network.wan.ifname' < /etc/board.json 2>/dev/null || true)
                [ -z "$_wan_dev" ] && _wan_dev="eth0"
                _endpoint=$(ip -6 addr show dev "$_wan_dev" 2>/dev/null | awk '/inet6.*global/{print $2}' | cut -d/ -f1 | head -1)
            fi
        fi
    fi
    [ -z "$_endpoint" ] && _endpoint="[YOUR_ROUTER_IPV6_OR_DOMAIN]"
    log_info "Using VPN endpoint domain/IPv6: $_endpoint"

    # Remove existing peer registrations in network config
    while uci -q get network.@wireguard_wg0[0] >/dev/null 2>&1; do
        run_uci -q delete network.@wireguard_wg0[0]
    done

    for client in $WG_CLIENTS; do
        log_info "Provisioning peer: $client"
        _c_ip4="10.8.0.${_client_idx}"
        _c_ip6="fd11:2233:4455::${_client_idx}"

        if [ "$DRY_RUN" = "1" ]; then
            _client_pub="DRY_RUN_CLIENT_${client}_PUBLIC_KEY"
            _client_priv="DRY_RUN_CLIENT_${client}_PRIVATE_KEY"
        else
            if [ ! -f "/etc/wireguard/clients/${client}.key" ]; then
                (umask 077 && wg genkey > "/etc/wireguard/clients/${client}.key")
                wg pubkey < "/etc/wireguard/clients/${client}.key" > "/etc/wireguard/clients/${client}.pub"
            fi
            _client_priv=$(cat "/etc/wireguard/clients/${client}.key")
            _client_pub=$(cat "/etc/wireguard/clients/${client}.pub")
        fi

        # Add peer section in OpenWrt
        run_uci add network wireguard_wg0
        run_uci set network.@wireguard_wg0[-1].public_key="$_client_pub"
        run_uci set network.@wireguard_wg0[-1].description="$client"
        run_uci add_list network.@wireguard_wg0[-1].allowed_ips="${_c_ip4}/32"
        run_uci add_list network.@wireguard_wg0[-1].allowed_ips="${_c_ip6}/128"

        # Generate config files
        if [ "$DRY_RUN" = "0" ]; then
            (
                umask 077
                cat > "/etc/wireguard/clients/${client}_split.conf" << CONF
[Interface]
PrivateKey = $_client_priv
Address = ${_c_ip4}/32, ${_c_ip6}/128
DNS = 10.8.0.1, fd11:2233:4455::1

[Peer]
PublicKey = $_srv_pub
Endpoint = ${_endpoint}:${WG_PORT}
AllowedIPs = 10.8.0.0/24, fd11:2233:4455::/64, 192.168.11.0/24
PersistentKeepalive = 25
CONF

                cat > "/etc/wireguard/clients/${client}_full.conf" << CONF
[Interface]
PrivateKey = $_client_priv
Address = ${_c_ip4}/32, ${_c_ip6}/128
DNS = 10.8.0.1, fd11:2233:4455::1

[Peer]
PublicKey = $_srv_pub
Endpoint = ${_endpoint}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF

                cat > "/etc/wireguard/clients/${client}_dns.conf" << CONF
[Interface]
PrivateKey = $_client_priv
Address = ${_c_ip4}/32, ${_c_ip6}/128
DNS = 10.8.0.1, fd11:2233:4455::1

[Peer]
PublicKey = $_srv_pub
Endpoint = ${_endpoint}:${WG_PORT}
AllowedIPs = 10.8.0.1/32, fd11:2233:4455::1/128
PersistentKeepalive = 25
CONF
            )
        fi

        _client_idx=$((_client_idx + 1))
    done

    run_uci commit network
    run_uci commit firewall
    if [ "$ENABLE_WG_DDNS" = "1" ]; then
        run_uci commit ddns
    fi
    log_ok "WireGuard config committed."
}
