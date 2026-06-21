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
        log_info "Downloading pinned adblock-lean installer..."
        uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/046b19126185acfe7ce1f8d6e8489df1bdd2e046/abl-install.sh -O /tmp/abl-install.sh
        if [ -f /tmp/abl-install.sh ]; then
            # Verify script SHA256 integrity
            _sha="55afa0dfab5c3ceaa1ff41c1ed7088140a0965e724f79a9fa1423645545b5bf5"
            if echo "$_sha  /tmp/abl-install.sh" | sha256sum -c >/dev/null 2>&1; then
                log_info "SHA256 verified successfully. Installing..."
                sh /tmp/abl-install.sh -v release
            else
                log_error "SHA256 verification FAILED for adblock-lean installer! Skipping installation."
            fi
            rm -f /tmp/abl-install.sh
        else
            log_error "Failed to download adblock-lean installer."
        fi
    fi

    run_cmd service cron enable || true
    log_ok "Cron service enabled."
}
