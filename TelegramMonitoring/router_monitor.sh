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

safe_format() {
    local template="$1"
    shift
    local escaped_template
    escaped_template=$(echo "$template" | sed 's/%/%%/g; s/%%s/%s/g')
    printf "$escaped_template" "$@"
}

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
        MSG=$(safe_format "$MSG_RAM_WARN" "$FREE_MEM")
        send_alert "ram" "RESOURCE" "$MSG"
    else
        reset_alert "ram"
    fi
}

check_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        TS_IP=$(tailscale ip -4 2>/dev/null)
        if [ -z "$TS_IP" ] || tailscale status 2>/dev/null | grep -qE "Logged out|NeedsLogin"; then
            UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
            # Skip alert if the router recently booted (within 3 minutes / 180 seconds)
            # to give the tailscale daemon time to initialize and handshake.
            if [ "$UPTIME_SEC" -lt 180 ]; then
                return
            fi

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
            MSG=$(safe_format "$MSG_LATENCY_HIGH" "$AVG_LATENCY")
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
        MSG=$(safe_format "$MSG_STORAGE_WARN" "$OVERLAY_USE")
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
            MSG=$(safe_format "$MSG_CPU_LOAD" "$LOAD_AVG")
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
                MSG=$(safe_format "$MSG_WAN_IP_CHANGE" "$OLD_IP" "$CURRENT_IP")
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
                MSG=$(safe_format "$MSG_SQM_DOWN" "$SQM_IFACE")
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

check_boot_and_heartbeat() {
    HEARTBEAT_FILE="/etc/router_last_seen"
    BOOT_LOCK="/tmp/router_boot_notified"
    NOW=$(date +%s)

    # 1. Boot recovery check
    if [ ! -f "$BOOT_LOCK" ]; then
        # Ensure time is synchronized (epoch greater than 1700000000)
        # OpenWrt might boot up with 1970 or a low build date until NTP syncs.
        if [ "$NOW" -gt 1700000000 ]; then
            touch "$BOOT_LOCK"
            if [ -f "$HEARTBEAT_FILE" ]; then
                LAST_SEEN=$(cat "$HEARTBEAT_FILE")
                # Validate that LAST_SEEN is a valid number
                if expr "$LAST_SEEN" : '^[0-9]\+$' >/dev/null; then
                    DIFF=$((NOW - LAST_SEEN))
                    # Only notify if downtime is significant (e.g., > 120 seconds)
                    if [ "$DIFF" -gt 120 ]; then
                        HOURS=$(( DIFF / 3600 ))
                        MINUTES=$(( (DIFF % 3600) / 60 ))
                        SECONDS=$(( DIFF % 60 ))

                        DOWNTIME=""
                        [ "$HOURS" -gt 0 ] && DOWNTIME="${HOURS}h "
                        [ "$MINUTES" -gt 0 ] || [ "$HOURS" -gt 0 ] && DOWNTIME="${DOWNTIME}${MINUTES}m "
                        DOWNTIME="${DOWNTIME}${SECONDS}s"

                        LAST_SEEN_STR=$(date -d "@$LAST_SEEN" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$LAST_SEEN" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
                        
                        if [ -n "$MSG_ROUTER_ONLINE" ]; then
                            MSG=$(safe_format "$MSG_ROUTER_ONLINE" "$DOWNTIME" "$LAST_SEEN_STR")
                            /usr/bin/telegram_notify.sh "SYSTEM" "$MSG"
                        fi
                    fi
                fi
            fi
        fi
    fi

    # 2. Always update the heartbeat timestamp
    echo "$NOW" > "$HEARTBEAT_FILE"
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
    check_boot_and_heartbeat
}

main

