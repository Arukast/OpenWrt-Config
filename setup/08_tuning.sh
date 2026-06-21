# Tuning setup module

setup_tuning() {
    log_step "Configuring ZRAM and Watchcat..."

    if [ -n "$ZRAM_MB" ]; then
        if [ "$DRY_RUN" = "0" ] && [ -f /etc/init.d/zram-setup ]; then
            /etc/init.d/zram-setup disable 2>/dev/null || true
            /etc/init.d/zram-setup stop 2>/dev/null || true
            rm -f /etc/init.d/zram-setup
        fi
        
        # Configure standard zram-swap via system config
        run_uci set system.@system[0].zram_size_mb="$ZRAM_MB"
        run_uci set system.@system[0].zram_comp_algo="$ZRAM_ALGO"
        run_uci commit system
        log_ok "ZRAM standardized swap configured via system config."
    fi

    run_uci set system.@system[0].conloglevel='8'
    run_uci set system.@system[0].cronloglevel='9'

    # Delete all existing watchcat instances to ensure idempotency
    while uci -q get system.@watchcat[0] >/dev/null 2>&1; do
        run_uci -q delete system.@watchcat[0]
    done

    run_uci add system watchcat
    run_uci set system.@watchcat[-1].mode='restart_iface'
    if [ "$CONNECTION_MODE" = "WISP" ]; then
        run_uci set system.@watchcat[-1].interface='wwan'
    else
        run_uci set system.@watchcat[-1].interface='wan'
    fi
    run_uci set system.@watchcat[-1].pinghosts='8.8.8.8 1.1.1.1'
    run_uci set system.@watchcat[-1].addressfamily='ipv4'
    run_uci set system.@watchcat[-1].pingperiod='30'
    run_uci set system.@watchcat[-1].period='3m'
    run_uci commit system

    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/sysctl.d/99-custom.conf << 'SYSCTL'
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel
SYSCTL
        if [ "$ENABLE_IPV6" = "1" ]; then
            cat >> /etc/sysctl.d/99-custom.conf << 'SYSCTL'
# Disable IPv6 Privacy Extensions on the router for stable routing
net.ipv6.conf.all.use_tempaddr=0
net.ipv6.conf.default.use_tempaddr=0
SYSCTL
        else
            cat >> /etc/sysctl.d/99-custom.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL
        fi
    fi
    log_ok "System tuning applied."
}
