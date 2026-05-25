#!/bin/sh
# File: /usr/bin/router_monitor.sh

# === CONFIGURATION ===
COOLDOWN=900 # 15 minutes
LOCK_DIR="/tmp/router_locks"
mkdir -p "$LOCK_DIR"

# Load config
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
[ -f "$CONF" ] || { echo "ERROR: telegram.conf not found"; exit 1; }
. "$CONF"

# Load language
LANG_DIR=${LANG_DIR:-"/etc/telegram_lang"}
[ -d "$(dirname "$0")/lang" ] && LANG_DIR="$(dirname "$0")/lang"
LANG_FILE="${LANG_DIR}/${LANG:-en}.sh"

[ -f "$LANG_FILE" ] && . "$LANG_FILE" || . "${LANG_DIR}/en.sh"

# === HELPER FUNCTIONS ===
send_alert() {
    LOCK_NAME="$1"
    KATEGORI="$2"
    PESAN="$3"
    CUSTOM_COOLDOWN="${4:-$COOLDOWN}"
    LOCK_FILE="${LOCK_DIR}/${LOCK_NAME}.lock"
    NOW=$(date +%s)

    if [ -f "$LOCK_FILE" ]; then
        LAST_SENT=$(cat "$LOCK_FILE")
        DIFF=$((NOW - LAST_SENT))
        if [ "$DIFF" -lt "$CUSTOM_COOLDOWN" ]; then
            return 0
        fi
    fi

    echo "$NOW" > "$LOCK_FILE"
    /usr/bin/telegram_notify.sh "$KATEGORI" "$PESAN"
}

reset_alert() {
    LOCK_NAME="$1"
    rm -f "${LOCK_DIR}/${LOCK_NAME}.lock"
}

# === CHECKS ===

check_ram() {
    FREE_MEM=$(free | awk '/^Mem:/{print int($4/1024)}')
    if [ "$FREE_MEM" -lt 30 ]; then
        MSG=$(printf "$MSG_RAM_WARN" "$FREE_MEM")
        send_alert "ram" "RESOURCE" "$MSG"
    else
        reset_alert "ram"
    fi
}

check_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        TS_IP=$(tailscale ip -4 2>/dev/null)
        if [ -z "$TS_IP" ] || tailscale status 2>/dev/null | grep -qE "Logged out|NeedsLogin"; then
            if [ ! -f "${LOCK_DIR}/tailscale_unconfigured.lock" ]; then
                /usr/bin/telegram_notify.sh "VPN" "Tailscale is installed but not configured (Not logged in)."
                touch "${LOCK_DIR}/tailscale_unconfigured.lock"
            fi
            return
        fi

        if ! ping -c 1 -W 2 100.100.100.100 > /dev/null 2>&1; then
            send_alert "tailscale" "VPN" "$MSG_TAILSCALE_DOWN"
        else
            reset_alert "tailscale"
        fi
    fi
}

check_wifi() {
    WIFI_5G=$(ubus call network.wireless status | jsonfilter -e '@.radio1.up' 2>/dev/null)
    if [ "$WIFI_5G" = "false" ]; then
        send_alert "wifi5g" "WLAN" "$MSG_WIFI_5G_DOWN"
    else
        reset_alert "wifi5g"
    fi

    WIFI_24G=$(ubus call network.wireless status | jsonfilter -e '@.radio0.up' 2>/dev/null)
    if [ "$WIFI_24G" = "false" ]; then
        send_alert "wifi24g" "WLAN" "$MSG_WIFI_24G_DOWN"
    else
        reset_alert "wifi24g"
    fi
}

check_latency() {
    # Quick check: 1 packet to see if latency is high
    QUICK_LATENCY=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | awk -F'/' 'END{print int($4)}')
    
    if [ -z "$QUICK_LATENCY" ] || [ "$QUICK_LATENCY" -gt 150 ]; then
        # High latency detected or packet loss, confirm with 5-second test (5 packets)
        AVG_LATENCY=$(ping -c 5 -q 8.8.8.8 2>/dev/null | awk -F'/' 'END{print int($4)}')
        if [ -n "$AVG_LATENCY" ] && [ "$AVG_LATENCY" -gt 150 ]; then
            MSG=$(printf "$MSG_LATENCY_HIGH" "$AVG_LATENCY")
            # Override default 15 min cooldown -> Use 5 mins (300s) for latency alerts
            send_alert "latensi" "UPLINK" "$MSG" 300
        else
            reset_alert "latensi"
        fi
    else
        reset_alert "latensi"
    fi
}

check_storage() {
    OVERLAY_USE=$(df /overlay 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ -n "$OVERLAY_USE" ] && [ "$OVERLAY_USE" -gt 90 ]; then
        MSG=$(printf "$MSG_STORAGE_WARN" "$OVERLAY_USE")
        send_alert "storage" "RESOURCE" "$MSG"
    else
        reset_alert "storage"
    fi
}

check_cpu_load() {
    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
    if [ "$UPTIME_SEC" -gt 600 ]; then
        LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
        LOAD_INT=$(echo "$LOAD_AVG" | awk -F. '{print $1}')
        if [ "$LOAD_INT" -ge 2 ]; then
            MSG=$(printf "$MSG_CPU_LOAD" "$LOAD_AVG")
            send_alert "cpu_load" "RESOURCE" "$MSG"
        else
            reset_alert "cpu_load"
        fi
    fi
}

check_wan_ip() {
    IP_FILE="/tmp/router_wan_ip"
    CURRENT_IP=$(curl -s -m 5 https://api.ipify.org || echo "unknown")
    if [ "$CURRENT_IP" != "unknown" ]; then
        if [ -f "$IP_FILE" ]; then
            OLD_IP=$(cat "$IP_FILE")
            if [ "$OLD_IP" != "$CURRENT_IP" ]; then
                MSG=$(printf "$MSG_WAN_IP_CHANGE" "$OLD_IP" "$CURRENT_IP")
                /usr/bin/telegram_notify.sh "NETWORK" "$MSG"
            fi
        fi
        echo "$CURRENT_IP" > "$IP_FILE"
    fi
}

check_sqm() {
    if uci -q get sqm.@queue[0].enabled 2>/dev/null | grep -q "1"; then
        SQM_IFACE=$(uci -q get sqm.@queue[0].interface)
        if [ -n "$SQM_IFACE" ]; then
            if ! tc qdisc show dev "$SQM_IFACE" 2>/dev/null | grep -qi "cake"; then
                MSG=$(printf "$MSG_SQM_DOWN" "$SQM_IFACE")
                send_alert "sqm" "QOS" "$MSG"
            else
                reset_alert "sqm"
            fi
        fi
    fi
}

check_wifi_clients() {
    # Informational, track client count
    CLIENT_COUNT=$(iw dev 2>/dev/null | grep -c "station")
    CLIENT_FILE="/tmp/router_client_count"
    if [ -f "$CLIENT_FILE" ]; then
        OLD_COUNT=$(cat "$CLIENT_FILE")
        if [ "$OLD_COUNT" -eq 0 ] && [ "$CLIENT_COUNT" -gt 0 ]; then
            # Optional: alert on first connection
            true
        fi
    fi
    echo "$CLIENT_COUNT" > "$CLIENT_FILE"
}

main() {
    check_ram
    check_tailscale
    check_wifi
    check_latency
    check_storage
    check_cpu_load
    check_wan_ip
    check_sqm
    check_wifi_clients
}

main
