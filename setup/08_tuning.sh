# Tuning setup module

setup_tuning() {
    log_step "Configuring ZRAM and Watchcat..."

    if [ -n "$ZRAM_MB" ] && [ "$DRY_RUN" = "0" ]; then
        apk add kmod-zram 2>/dev/null || true
        ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))
        cat > /etc/init.d/zram-setup << ZRAMEOF
#!/bin/sh /etc/rc.common
START=12
STOP=89
USE_PROCD=1
# Notice: \${ZRAM_ALGO} and \${ZRAM_BYTES} are expanded at script generation time. This is intentional.
start_service() {
    modprobe zram 2>/dev/null || true
    sleep 1
    [ -b /dev/zram0 ] || return 1
    echo ${ZRAM_ALGO} > /sys/block/zram0/comp_algorithm
    echo ${ZRAM_BYTES} > /sys/block/zram0/disksize
    mkswap /dev/zram0
    swapon -p 10 /dev/zram0
}
stop_service() {
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
}
ZRAMEOF
        chmod +x /etc/init.d/zram-setup
        /etc/init.d/zram-setup enable
        log_ok "ZRAM init script configured."
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
