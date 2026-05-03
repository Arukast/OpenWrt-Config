#!/bin/sh

# 1. Packages
apk update
# Tambahkan paket inti yang dibutuhkan oleh konfigurasi di bawah
# - sqm-scripts & luci-app-sqm: Wajib ada karena kamu setting uci sqm di Step 4
# - ca-bundle: Wajib agar curl (Step 8) dan Tailscale bisa verifikasi SSL
# - kmod-sched-cake: Untuk scheduler CAKE di SQM
apk add zram-swap https-dns-proxy curl tailscale \
    sqm-scripts luci-app-sqm kmod-sched-cake \
    ca-bundle ca-certificates

# Hapus package yang tidak dibutuhkan (Bloatware/Conflict)
# Adblock standar dihapus karena kamu pakai adblock-lean
apk del luci-app-statistics rrdtool1 librrd1 libgd libjpeg-turbo libpng libwebp \
    netdata mwan3 luci-app-mwan3 ttyd luci-app-ttyd vnstat2 vnstatri2 \
    adblock luci-app-adblock

# Bersihkan sisa collectd jika ada
collectd_pkgs=$(apk info | grep collectd)
[ -n "$collectd_pkgs" ] && apk del $collectd_pkgs

# 2. Network — WISP, MTU, Packet Steering, IPv6 Disable
uci -q delete network.wan
uci -q delete network.wan6
uci set network.@device[0].ports='lan1 lan2 lan3 wan'
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.device='phy0-sta0'
uci set network.wwan.mtu='1480'
uci set network.wwan.peerdns='0'
uci add_list network.wwan.dns='8.8.8.8'
uci add_list network.wwan.dns='1.1.1.1'
uci set network.globals.packet_steering='1'
uci set network.lan.ipv6='0'
uci commit network

# 3. Wireless
uci set wireless.radio0.channel='6'
uci set wireless.radio0.htmode='HT20'
uci set wireless.radio0.txpower='13'
uci set wireless.radio0.country='ID'
uci set wireless.radio1.channel='157'
uci set wireless.radio1.htmode='VHT40'
uci set wireless.radio1.txpower='5'
uci set wireless.radio1.country='ID'
for iface in $(uci show wireless | grep "mode='ap'" | awk -F'.' '{print $2}'); do
    uci set wireless.$iface.encryption='sae-mixed'
done
uci commit wireless

# 4. SQM CAKE
uci set sqm.@queue[0].enabled='1'
uci set sqm.@queue[0].interface='phy0-sta0'
uci set sqm.@queue[0].download='23158'
uci set sqm.@queue[0].upload='11384'
uci set sqm.@queue[0].qdisc='cake'
uci set sqm.@queue[0].script='piece_of_cake.qos'
uci set sqm.@queue[0].linklayer='ethernet'
uci set sqm.@queue[0].overhead='44'
uci set sqm.@queue[0].linklayer_advanced='1'
uci set sqm.@queue[0].tcMPU='84'
uci commit sqm

# 5. System — ZRAM, Watchcat
uci set system.@system[0].zram_comp_algo='lzo-rle'
uci set system.@system[0].zram_size_mb='184'
uci set system.@system[0].conloglevel='8'
uci set system.@system[0].cronloglevel='5'
uci -q delete system.@watchcat[0]
uci add system watchcat
uci set system.@watchcat[-1].mode='restart_iface'
uci set system.@watchcat[-1].interface='wwan'
uci set system.@watchcat[-1].pinghosts='8.8.8.8 1.1.1.1'
uci set system.@watchcat[-1].addressfamily='ipv4'
uci set system.@watchcat[-1].pingperiod='30'
uci set system.@watchcat[-1].period='3m'
uci commit system

cat << 'EOF' > /etc/sysctl.d/99-custom.conf
net.ipv4.tcp_congestion_control=cubic
net.core.default_qdisc=fq_codel
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

# 6. DoH + dnsmasq
uci -q delete https-dns-proxy.@https-dns-proxy[0]
uci -q delete https-dns-proxy.@https-dns-proxy[1]
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='1.1.1.1,1.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://cloudflare-dns.com/dns-query'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5053'
uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'
uci set https-dns-proxy.@https-dns-proxy[-1].force_dns='1'
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='8.8.8.8,8.8.4.4'
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://dns.google/dns-query'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5054'
uci set https-dns-proxy.@https-dns-proxy[-1].use_http1='0'
uci set https-dns-proxy.@https-dns-proxy[-1].dscp_codepoint='46'
uci set https-dns-proxy.@https-dns-proxy[-1].force_dns='1'
uci commit https-dns-proxy

uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci -q delete dhcp.@dnsmasq[0].address
uci add_list dhcp.@dnsmasq[0].address='/use-application-dns.net/'
uci add_list dhcp.@dnsmasq[0].address='/mask.icloud.com/'
uci add_list dhcp.@dnsmasq[0].address='/mask-h2.icloud.com/'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ndp='disabled'
uci commit dhcp
/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop

# 7. Firewall
ping_rule=$(uci show firewall | grep "name='Allow-Ping'" | awk -F'.' '{print $2}')
[ -n "$ping_rule" ] && uci set firewall.$ping_rule.target='DROP'
esp_rule=$(uci show firewall | grep "name='Allow-IPSec-ESP'" | awk -F'.' '{print $2}')
[ -n "$esp_rule" ] && uci delete firewall.$esp_rule
isakmp_rule=$(uci show firewall | grep "name='Allow-ISAKMP'" | awk -F'.' '{print $2}')
[ -n "$isakmp_rule" ] && uci delete firewall.$isakmp_rule
for z in wan1 wan2 wan3 wan4 wan5 wwan2; do uci -q delete firewall.$z; done

uci add firewall zone
uci set firewall.@zone[-1].name='wanusb'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='wanusb'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wanusb'

uci add firewall zone
uci set firewall.@zone[-1].name='tailscale'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].device='tailscale0'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='tailscale'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='tailscale'
uci set firewall.@forwarding[-1].dest='lan'
uci commit firewall

# 8. Cron + adblock-lean
cat << 'EOF' > /etc/crontabs/root
0 3 * * 0 reboot
0 5 * * * RANDOM_DELAY=1 /etc/init.d/adblock-lean start 1>/dev/null
EOF
service cron enable
sh -c "$(curl -sL https://raw.githubusercontent.com/jow-/adblock-lean/master/abl-install.sh)"

# 9. Enable services
service tailscale enable
service zram enable
service watchcat enable
sysctl -p /etc/sysctl.d/99-custom.conf

# 10. Reload semua
wifi reload
/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/sqm restart
/etc/init.d/https-dns-proxy restart
/etc/init.d/adblock-lean start
/etc/init.d/tailscale restart

echo "Selesai. Jalankan 'tailscale up' setelah reboot."