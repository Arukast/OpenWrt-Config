# System setup module

setup_system() {
    log_step "Configuring system, hostname & NTP..."
    run_uci set system.@system[0].hostname="$HOSTNAME"
    run_uci set system.@system[0].timezone="$TIMEZONE"
    run_uci set system.@system[0].zonename="$ZONENAME"

    run_uci -q delete system.ntp.server || true
    for srv in $NTP_SERVERS; do
        run_uci add_list system.ntp.server="$srv"
    done
    run_uci set system.ntp.enabled='1'
    run_uci set system.ntp.enable_server='0'
    run_uci commit system
    log_ok "System config committed."
}
