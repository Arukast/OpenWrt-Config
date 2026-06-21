# Services enablement module

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
[ -f /etc/init.d/tailscale    ] && /etc/init.d/tailscale    restart && sleep 3 && [ -x /usr/sbin/tailscale ] && /usr/sbin/tailscale up --accept-dns=false 2>/dev/null
rm -f /etc/rc.local
exit 0
RCEOF
        chmod +x /etc/rc.local
    fi
}
