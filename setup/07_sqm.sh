# SQM setup module

setup_sqm() {
    log_step "Configuring SQM CAKE..."
    uci -q get sqm.@queue[0] >/dev/null 2>&1 || run_uci add sqm queue
    
    if [ "$CONNECTION_MODE" = "WISP" ]; then
        _sqm_iface="$WWAN_IFACE"
    else
        _sqm_iface=$(jsonfilter -e '@.network.wan.device' < /etc/board.json 2>/dev/null || true)
        [ -z "$_sqm_iface" ] && _sqm_iface=$(jsonfilter -e '@.network.wan.ifname' < /etc/board.json 2>/dev/null || true)
        [ -z "$_sqm_iface" ] && _sqm_iface=$(uci -q get network.wan.device 2>/dev/null)
        [ -z "$_sqm_iface" ] && _sqm_iface=$(uci -q get network.wan.ifname 2>/dev/null)
        [ -z "$_sqm_iface" ] && _sqm_iface="eth0"
    fi

    if [ "$DL_KBPS" = "0" ] && [ "$UL_KBPS" = "0" ]; then
        run_uci set sqm.@queue[0].enabled='0'
        log_info "SQM is disabled (Speed set to 0)."
    else
        run_uci set sqm.@queue[0].enabled='1'
        run_uci set sqm.@queue[0].interface="$_sqm_iface"
        run_uci set sqm.@queue[0].download="$DL_KBPS"
        run_uci set sqm.@queue[0].upload="$UL_KBPS"
        run_uci set sqm.@queue[0].qdisc='cake'
        run_uci set sqm.@queue[0].script='piece_of_cake.qos'
        run_uci set sqm.@queue[0].linklayer="$SQM_LINKLAYER"
        run_uci set sqm.@queue[0].overhead="$SQM_OVERHEAD"
        run_uci set sqm.@queue[0].linklayer_advanced='1'
        run_uci set sqm.@queue[0].tcMPU='84'
    fi
    run_uci commit sqm
    log_ok "SQM config committed."
}
