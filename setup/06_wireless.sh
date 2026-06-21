# Wireless setup module

setup_wireless() {
    log_step "Configuring wireless..."
    for radio in $RADIO_2G $RADIO_5G; do
        [ -z "$radio" ] && continue
        # Configure the radio hardware
        run_uci set wireless.${radio}.country="$COUNTRY"
        run_uci set wireless.${radio}.disabled='0'
        
        if [ "$radio" = "$RADIO_2G" ]; then
            run_uci set wireless.${radio}.band="2g"
            run_uci set wireless.${radio}.channel="$CH_2G"
            run_uci set wireless.${radio}.htmode="$HTMODE_2G"
            run_uci set wireless.${radio}.txpower="$TXPWR_2G"
            ssid_var="$WIFI_SSID_2G"
        else
            run_uci set wireless.${radio}.band="5g"
            run_uci set wireless.${radio}.channel="$CH_5G"
            run_uci set wireless.${radio}.htmode="$HTMODE_5G"
            run_uci set wireless.${radio}.txpower="$TXPWR_5G"
            ssid_var="$WIFI_SSID_5G"
        fi
        
        # Configure the AP and STA interfaces attached to this radio
        for iface in $(uci show wireless | grep "device='${radio}'" | awk -F'.' '{print $2}' | sort -u); do
            run_uci set wireless.${iface}.disabled='0'
            # Only set SSID/Key for AP interfaces, leave STA interfaces untouched to preserve WISP connection
            if uci get wireless.${iface}.mode 2>/dev/null | grep -q "ap"; then
                run_uci set wireless.${iface}.ssid="$ssid_var"
                run_uci set wireless.${iface}.encryption='sae-mixed'
                run_uci set wireless.${iface}.key="$WIFI_KEY"
                
                # Enable 802.11r Fast Transition for seamless roaming between 2.4GHz & 5GHz
                run_uci set wireless.${iface}.ieee80211r='1'
                run_uci set wireless.${iface}.ft_over_ds='0'  # Disable over DS (uses over-the-air) for better client compatibility
                run_uci set wireless.${iface}.ft_psk_generate_local='1'
                run_uci set wireless.${iface}.mobility_domain='1234'
                
                # Enable 802.11k (RRM) & 802.11v (BTM) to support Usteer band steering
                run_uci set wireless.${iface}.rrm='1'
                run_uci set wireless.${iface}.rrm_beacon_report='1'
                run_uci set wireless.${iface}.rrm_neighbor_report='1'
                run_uci set wireless.${iface}.bss_transition='1'
                
                # Custom optimizations for battery life and legacy device compatibility
                run_uci set wireless.${iface}.dtim_period='3'
                run_uci set wireless.${iface}.disassoc_low_ack='0'
            fi
        done
    done
    run_uci commit wireless
    log_ok "Wireless config committed."
}

setup_usteer() {
    log_step "Configuring Usteer Band Steering..."
    [ -f /etc/config/usteer ] || touch /etc/config/usteer
    run_uci -q get usteer.global >/dev/null 2>&1 || run_uci set usteer.global='usteer'
    
    run_uci set usteer.global.network='lan'
    run_uci set usteer.global.local_mode='1'
    run_uci set usteer.global.ipv6='0'
    run_uci set usteer.global.syslog='1'
    run_uci commit usteer
    log_ok "Usteer config committed."
}
