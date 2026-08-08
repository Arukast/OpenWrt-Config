#!/bin/sh
# File: /usr/bin/dumb_ap_monitor.sh

# === CONFIGURATION ===
COOLDOWN=900 # 15 minutes
LOCK_DIR="/tmp/router_locks"
mkdir -p "$LOCK_DIR"

PRIMARY_ROUTER_IP=$(uci -q get network.lan.gateway || echo "192.168.11.1")
SSH_KEY="/root/.ssh/id_ed25519"
HOSTNAME=$(uci -q get system.@system[0].hostname || echo "DumbAP")

# Load config if present
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
if [ -f "$CONF" ]; then
    . "$CONF"
fi

# Ensure timezone is set for date calculations
if [ -z "$TZ" ]; then
    SYS_TZ=$(uci -q get system.@system[0].timezone)
    [ -n "$SYS_TZ" ] && export TZ="$SYS_TZ"
else
    export TZ
fi

# Load language
LANG_DIR=${LANG_DIR:-"/etc/telegram_lang"}
[ -d "$(dirname "$0")/lang" ] && LANG_DIR="$(dirname "$0")/lang"
LANG_FILE="${LANG_DIR}/${LANG:-en}.sh"

if [ -f "$LANG_FILE" ]; then
    . "$LANG_FILE"
else
    # Minimal fallback translation if file is missing
    MSG_RAM_WARN="Memory Warning: %0AAvailable RAM: %sMB. Critical capacity!"
    MSG_WIFI_5G_DOWN="WiFi 5GHz Down: %0Aradio1 stopped broadcasting."
    MSG_WIFI_5G_RECOVER="WiFi 5GHz Recovered: %0Aradio1 resumed broadcasting."
    MSG_WIFI_24G_DOWN="WiFi 2.4GHz Down: %0Aradio0 stopped broadcasting."
    MSG_WIFI_24G_RECOVER="WiFi 2.4GHz Recovered: %0Aradio0 resumed broadcasting."
    MSG_STORAGE_WARN="Critical /overlay capacity: %s%% used. Please clean up logs."
    MSG_CPU_LOAD="High CPU Load! %0ALoad Average: %s"
    MSG_ROUTER_ONLINE="Router is ONLINE %0AWas offline for: %s %0ALast seen: %s"
fi

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
    KATEGORI="$2"
    TEMPLATE="$3"
    shift 3
    LOCK_FILE="${LOCK_DIR}/${LOCK_NAME}.lock"

    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        if [ -n "$TEMPLATE" ]; then
            MSG=$(safe_format "$TEMPLATE" "$@")
            /usr/bin/telegram_notify.sh "$KATEGORI" "$MSG"
        fi
    fi
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

check_wifi() {
    WIFI_5G=$(ubus call network.wireless status | jsonfilter -e '@.radio1.up' 2>/dev/null)
    if [ "$WIFI_5G" = "false" ]; then
        send_alert "wifi5g" "WLAN" "$MSG_WIFI_5G_DOWN"
    else
        reset_alert "wifi5g" "WLAN" "$MSG_WIFI_5G_RECOVER"
    fi

    WIFI_24G=$(ubus call network.wireless status | jsonfilter -e '@.radio0.up' 2>/dev/null)
    if [ "$WIFI_24G" = "false" ]; then
        send_alert "wifi24g" "WLAN" "$MSG_WIFI_24G_DOWN"
    else
        reset_alert "wifi24g" "WLAN" "$MSG_WIFI_24G_RECOVER"
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

check_wifi_clients() {
    CLIENT_COUNT=$(iw dev 2>/dev/null | grep -c "station")
    CLIENT_FILE="/tmp/router_client_count"
    echo "$CLIENT_COUNT" > "$CLIENT_FILE"
}

check_boot_and_heartbeat() {
    HEARTBEAT_FILE="/etc/router_last_seen"
    BOOT_LOCK="/tmp/router_boot_notified"
    NOW=$(date +%s)

    if [ ! -f "$BOOT_LOCK" ]; then
        if [ "$NOW" -gt 1700000000 ]; then
            if [ -f "$HEARTBEAT_FILE" ]; then
                LAST_SEEN=$(cat "$HEARTBEAT_FILE")
                if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" -eq "$LAST_SEEN" ] 2>/dev/null; then
                    DIFF=$((NOW - LAST_SEEN))
                    if [ "$DIFF" -gt 0 ]; then
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
                            logger -t "dumb_ap_monitor" "Attempting to send boot recovery alert..."
                            if /usr/bin/telegram_notify.sh "SYSTEM" "$MSG"; then
                                logger -t "dumb_ap_monitor" "Boot recovery alert sent successfully."
                                touch "$BOOT_LOCK"
                            else
                                logger -t "dumb_ap_monitor" "WARNING: Failed to send boot recovery alert. Will retry on next run."
                            fi
                        else
                            touch "$BOOT_LOCK"
                        fi
                    else
                        touch "$BOOT_LOCK"
                    fi
                else
                    touch "$BOOT_LOCK"
                fi
            else
                touch "$BOOT_LOCK"
            fi
        fi
    fi

    if [ "$NOW" -gt 1700000000 ]; then
        echo "$NOW" > "$HEARTBEAT_FILE"
    fi
}

main() {
    if [ ! -f "$SSH_KEY" ]; then
        logger -t "dumb_ap_monitor" "ERROR: SSH key $SSH_KEY not found. Skipping health checks."
        exit 1
    fi

    # Ping primary router first to make sure network is up
    if ! ping -c 1 -W 2 "$PRIMARY_ROUTER_IP" >/dev/null 2>&1; then
        logger -t "dumb_ap_monitor" "Primary router $PRIMARY_ROUTER_IP is unreachable. Skipping checks."
        exit 0
    fi

    check_ram
    check_wifi
    check_storage
    check_cpu_load
    check_wifi_clients
    check_boot_and_heartbeat
}

main
