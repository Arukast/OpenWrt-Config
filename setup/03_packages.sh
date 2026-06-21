# Package setup module

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
    if [ "$ENABLE_IPV6" = "0" ] && [ -x /usr/bin/wget ] && [ ! -f /usr/bin/wget.orig ]; then
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

    _pkgs="ca-bundle ca-certificates curl sqm-scripts luci-app-sqm kmod-sched-cake https-dns-proxy luci-app-https-dns-proxy watchcat nano iperf3 htop"
    [ -n "$ZRAM_MB" ] && _pkgs="$_pkgs zram-swap"
    [ "$ENABLE_BANDWIDTH_MONITOR" = "1" ] && _pkgs="$_pkgs vnstat2 vnstati2 luci-app-vnstat2"
    [ "$ENABLE_TRAFFIC_MONITOR" = "1" ] && _pkgs="$_pkgs luci-app-nlbwmon"

    run_cmd apk add $_pkgs

    # Replace basic WPAD with full WPAD-OpenSSL to enable 802.11r/k/v roaming features
    log_info "Replacing basic WPAD with full WPAD-OpenSSL..."
    for wpad_pkg in wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad-basic; do
        if apk info "$wpad_pkg" >/dev/null 2>&1; then
            run_cmd apk del "$wpad_pkg"
        fi
    done

    _wifi_pkgs="wpad-openssl kmod-tcp-bbr"
    [ "$ENABLE_USTEER" = "1" ] && _wifi_pkgs="$_wifi_pkgs usteer luci-app-usteer"
    run_cmd apk add $_wifi_pkgs

    if [ "$ENABLE_TAILSCALE" = "1" ]; then
        run_cmd apk add tailscale && log_ok "Tailscale installed." || log_warn "Tailscale install failed."
    fi

    if [ "$ENABLE_WIREGUARD" = "1" ]; then
        run_cmd apk add wireguard-tools luci-proto-wireguard qrencode && log_ok "WireGuard packages installed." || log_warn "WireGuard packages install failed."
    fi

    if [ "$ENABLE_WG_DDNS" = "1" ]; then
        run_cmd apk add ddns-scripts ddns-scripts-services && log_ok "DDNS packages installed." || log_warn "DDNS packages install failed."
    fi

    BLOAT_PKGS="luci-app-statistics rrdtool1 librrd1 libgd libjpeg-turbo libpng libwebp netdata mwan3 luci-app-mwan3 ttyd luci-app-ttyd adblock luci-app-adblock"
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
