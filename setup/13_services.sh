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

        if [ "$ENABLE_USTEER" = "1" ]; then
            [ -f /etc/init.d/usteer ] && service usteer enable
        else
            [ -f /etc/init.d/usteer ] && { service usteer stop 2>/dev/null || true; service usteer disable 2>/dev/null || true; }
        fi

        if [ "$ENABLE_BANDWIDTH_MONITOR" = "1" ]; then
            [ -f /etc/init.d/vnstat ] && service vnstat enable
        else
            [ -f /etc/init.d/vnstat ] && { service vnstat stop 2>/dev/null || true; service vnstat disable 2>/dev/null || true; }
        fi

        if [ "$ENABLE_TRAFFIC_MONITOR" = "1" ]; then
            [ -f /etc/init.d/nlbwmon ] && service nlbwmon enable
        else
            [ -f /etc/init.d/nlbwmon ] && { service nlbwmon stop 2>/dev/null || true; service nlbwmon disable 2>/dev/null || true; }
        fi

        case "${MDNS_ENGINE:-umdns}" in
            umdns)
                [ -f /etc/init.d/umdns ] && service umdns enable
                [ -f /etc/init.d/avahi-daemon ] && { service avahi-daemon stop 2>/dev/null || true; service avahi-daemon disable 2>/dev/null || true; }
                ;;
            avahi)
                [ -f /etc/init.d/avahi-daemon ] && service avahi-daemon enable
                [ -f /etc/init.d/umdns ] && { service umdns stop 2>/dev/null || true; service umdns disable 2>/dev/null || true; }
                ;;
            none|0)
                [ -f /etc/init.d/umdns ] && { service umdns stop 2>/dev/null || true; service umdns disable 2>/dev/null || true; }
                [ -f /etc/init.d/avahi-daemon ] && { service avahi-daemon stop 2>/dev/null || true; service avahi-daemon disable 2>/dev/null || true; }
                ;;
        esac

        # --- Bridge VLAN fix for WiFi + mDNS ---
        # When vlan_filtering=1 and LAN device is br-lan.1, hostapd dynamically adds
        # WiFi AP interfaces (phy*-ap*) to br-lan WITHOUT correct VLAN membership.
        # - LAN APs get stuck with no PVID  → mDNS multicast can't reach WiFi clients
        # - IoT APs get wrong PVID 1        → IoT devices land on LAN instead of VLAN 80
        # The hotplug queries each AP's UCI network and sets the correct VLAN as PVID.
        if [ "$(cat /sys/class/net/br-lan/bridge/vlan_filtering 2>/dev/null)" = "1" ]; then
            if command -v bridge >/dev/null 2>&1; then
                mkdir -p /etc/hotplug.d/net
                cat > /etc/hotplug.d/net/30-bridge-vlan-wifi << 'HOTPLUG_EOF'
#!/bin/sh
# Fix bridge VLAN membership for WiFi AP interfaces when they join br-lan.
# Required when vlan_filtering=1 and networks use br-lan.N VLAN sub-interfaces.
# Handles LAN (VLAN 1), IoT (VLAN 80), and any other bridge VLAN networks.
[ "$ACTION" = "add" ] || exit 0
case "$INTERFACE" in phy*-ap*) ;; *) exit 0 ;; esac
sleep 1
MASTER=$(ip link show dev "$INTERFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="master"){print $(i+1);exit}}')
[ "$MASTER" = "br-lan" ] || exit 0
[ "$(cat /sys/class/net/br-lan/bridge/vlan_filtering 2>/dev/null)" = "1" ] || exit 0
# Get UCI network name for this interface via ubus (unpack array with [*])
_net=$(ubus call network.wireless status 2>/dev/null | \
    jsonfilter -e "@.*.interfaces[@.ifname=\"${INTERFACE}\"].config.network[*]" 2>/dev/null | tr -d '[]" ' | head -1)
if [ -z "$_net" ]; then
    _sec=$(uci show wireless 2>/dev/null | grep "ifname='${INTERFACE}'" | awk -F'.' '{print $2}' | head -1)
    [ -n "$_sec" ] && _net=$(uci -q get wireless.${_sec}.network | awk '{print $1}')
fi
[ -n "$_net" ] || exit 0
# Derive VLAN from network device (e.g. br-lan.80 → 80; br-lan.1 → 1)
_dev=$(uci -q get network.${_net}.device 2>/dev/null)
_vlan=$(echo "$_dev" | grep -oE '\.[0-9]+$' | tr -d '.')
[ -z "$_vlan" ] && _vlan=1
# Remove incorrect default VLAN 1 PVID if this interface belongs to a different VLAN
[ "$_vlan" != "1" ] && bridge vlan del vid 1 dev "$INTERFACE" 2>/dev/null || true
# Set the correct VLAN as PVID untagged
bridge vlan add vid "$_vlan" dev "$INTERFACE" pvid untagged 2>/dev/null && \
    logger -t bridge-vlan "Set $INTERFACE to VLAN $_vlan pvid untagged [$_net]"
HOTPLUG_EOF
                chmod +x /etc/hotplug.d/net/30-bridge-vlan-wifi
                log_ok "Installed bridge VLAN hotplug for WiFi AP interfaces."

                # Apply immediately to all current WiFi AP interfaces in br-lan.
                # Uses ubus + UCI to determine the correct VLAN for each AP —
                # handles LAN (VLAN 1), IoT (VLAN 80), and any other VLAN networks.
                for _wif in $(ip link show master br-lan 2>/dev/null | grep -oE 'phy[0-9]+-ap[0-9]+'); do
                    _net=$(ubus call network.wireless status 2>/dev/null | \
                        jsonfilter -e "@.*.interfaces[@.ifname=\"${_wif}\"].config.network[*]" 2>/dev/null | tr -d '[]" ' | head -1)
                    if [ -z "$_net" ]; then
                        _sec=$(uci show wireless 2>/dev/null | grep "ifname='${_wif}'" | awk -F'.' '{print $2}' | head -1)
                        [ -n "$_sec" ] && _net=$(uci -q get wireless.${_sec}.network | awk '{print $1}')
                    fi
                    [ -n "$_net" ] || continue
                    _dev=$(uci -q get network.${_net}.device 2>/dev/null)
                    _vlan=$(echo "$_dev" | grep -oE '\.[0-9]+$' | tr -d '.')
                    [ -z "$_vlan" ] && _vlan=1
                    [ "$_vlan" != "1" ] && bridge vlan del vid 1 dev "$_wif" 2>/dev/null || true
                    bridge vlan add vid "$_vlan" dev "$_wif" pvid untagged 2>/dev/null && \
                        log_info "VLAN $_vlan set on AP: $_wif [$_net]" || true
                done
            else
                log_warn "bridge command not found (run: apk add ip-bridge). mDNS multicast may not reach WiFi clients."
                log_warn "Manual fix after install: bridge vlan add vid 1 dev phy0-ap0 pvid untagged"
            fi
        fi

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
[ -f /etc/init.d/umdns ]        && /etc/init.d/umdns restart
[ -f /etc/init.d/avahi-daemon ] && /etc/init.d/avahi-daemon restart
[ -f /etc/init.d/adblock-lean ] && /etc/init.d/adblock-lean start
[ -f /etc/init.d/tailscale    ] && /etc/init.d/tailscale    restart && sleep 3 && [ -x /usr/sbin/tailscale ] && /usr/sbin/tailscale up --accept-dns=false 2>/dev/null
rm -f /etc/rc.local
exit 0
RCEOF
        chmod +x /etc/rc.local
    fi
}
