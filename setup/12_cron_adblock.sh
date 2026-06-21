# Cron and Adblock setup module

setup_cron_adblock() {
    log_step "Configuring cron + adblock-lean..."
    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/crontabs/root << 'CRON'
# Monthly reboot every 1st of the month at 03:00 (with bootloop safety trick)
0 3 1 * * sleep 70 && touch /etc/banner && reboot
0 5 * * * RANDOM_DELAY=1 /etc/init.d/adblock-lean start 1>/dev/null
CRON
    fi

    if [ "$ENABLE_ADBLOCK_LEAN" = "1" ] && [ "$DRY_RUN" = "0" ]; then
        uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh -O /tmp/abl-install.sh
        if [ -f /tmp/abl-install.sh ]; then
            sh /tmp/abl-install.sh -v release
            rm -f /tmp/abl-install.sh
        fi
    fi

    run_cmd service cron enable || true
    log_ok "Cron service enabled."
}
