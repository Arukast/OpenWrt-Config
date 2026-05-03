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
LANG_FILE="$(dirname "$0")/lang/${LANG:-en}.sh"
[ -f "$LANG_FILE" ] && . "$LANG_FILE" || . "$(dirname "$0")/lang/en.sh"

# Helper function
send_alert() {
    LOCK_NAME="$1"
    KATEGORI="$2"
    PESAN="$3"
    LOCK_FILE="${LOCK_DIR}/${LOCK_NAME}.lock"
    NOW=$(date +%s)

    if [ -f "$LOCK_FILE" ]; then
        LAST_SENT=$(cat "$LOCK_FILE")
        DIFF=$((NOW - LAST_SENT))
        if [ "$DIFF" -lt "$COOLDOWN" ]; then
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

# 1. RAM Check
FREE_MEM=$(free | awk '/^Mem:/{print int($4/1024)}')
if [ "$FREE_MEM" -lt 30 ]; then
    MSG=$(printf "$MSG_RAM_WARN" "$FREE_MEM")
    send_alert "ram" "RESOURCE" "$MSG"
else
    reset_alert "ram"
fi

# 2. Tailscale Check
if command -v tailscale >/dev/null 2>&1; then
    if ! ping -c 1 -W 2 100.100.100.100 > /dev/null 2>&1; then
        send_alert "tailscale" "VPN" "$MSG_TAILSCALE_DOWN"
    else
        reset_alert "tailscale"
    fi
fi

# 3. WiFi Radio Check
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

# 4. Latency Check
LATENCY=$(ping -c 3 -q 8.8.8.8 2>/dev/null | awk -F'/' 'END{print int($4)}')
if [ -n "$LATENCY" ] && [ "$LATENCY" -gt 150 ]; then
    MSG=$(printf "$MSG_LATENCY_HIGH" "$LATENCY")
    send_alert "latensi" "UPLINK" "$MSG"
else
    reset_alert "latensi"
fi

# 5. Storage Check
OVERLAY_USE=$(df /overlay 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [ -n "$OVERLAY_USE" ] && [ "$OVERLAY_USE" -gt 90 ]; then
    MSG=$(printf "$MSG_STORAGE_WARN" "$OVERLAY_USE")
    send_alert "storage" "RESOURCE" "$MSG"
else
    reset_alert "storage"
fi

# 6. CPU Load Check
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

# 7. WAN IP Change Detection
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

# 8. SQM Status Check
WWAN_IFACE=$(uci -q get network.wwan.device || echo "phy0-sta0")
if uci -q get sqm.@queue[0].enabled | grep -q "1"; then
    if ! tc qdisc show dev "$WWAN_IFACE" 2>/dev/null | grep -qi "cake"; then
        MSG=$(printf "$MSG_SQM_DOWN" "$WWAN_IFACE")
        send_alert "sqm" "QOS" "$MSG"
    else
        reset_alert "sqm"
    fi
fi

# 9. WiFi Client Count (Informational, only send if changed significantly or requested)
# Normally this would be a daily report, but we'll implement it as a function that can be called.
CLIENT_COUNT=$(iw dev 2>/dev/null | grep -c "station")
CLIENT_FILE="/tmp/router_client_count"
if [ -f "$CLIENT_FILE" ]; then
    OLD_COUNT=$(cat "$CLIENT_FILE")
    # Only alert if client count crossed a threshold (e.g. 0 to >0)
    if [ "$OLD_COUNT" -eq 0 ] && [ "$CLIENT_COUNT" -gt 0 ]; then
        # This is just an example of how to use it, you might not want to spam this.
        # MSG=$(printf "$MSG_CLIENTS_COUNT" "$CLIENT_COUNT")
        # /usr/bin/telegram_notify.sh "INFO" "$MSG"
        true
    fi
fi
echo "$CLIENT_COUNT" > "$CLIENT_FILE"
