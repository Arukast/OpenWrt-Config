#!/bin/sh
# File: /usr/bin/auth_monitor.sh

# Load config & lang
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
[ -f "$CONF" ] || { echo "ERROR: telegram.conf not found"; exit 1; }
. "$CONF"

LANG_FILE="$(dirname "$0")/lang/${LANG:-en}.sh"
[ -f "$LANG_FILE" ] && . "$LANG_FILE" || . "$(dirname "$0")/lang/en.sh"

TRACK_FILE="/tmp/auth_track_ips"
MAX_FAILURES=3
TIME_WINDOW=300 # 5 minutes

logread -f | while read -r line; do
    # Cleanup old tracks
    NOW=$(date +%s)
    if [ -f "$TRACK_FILE" ]; then
        awk -v now="$NOW" -v window="$TIME_WINDOW" 'now - $1 <= window' "$TRACK_FILE" > "${TRACK_FILE}.tmp"
        mv "${TRACK_FILE}.tmp" "$TRACK_FILE"
    else
        touch "$TRACK_FILE"
    fi

    # 1. LuCI Brute Force
    if echo "$line" | grep -q "luci: failed login"; then
        USER=$(echo "$line" | sed -n 's/.*failed login on .* for \(.*\) from .*/\1/p')
        IP=$(echo "$line" | sed -n 's/.*from \([0-9\.]*\).*/\1/p')
        
        echo "$NOW $IP" >> "$TRACK_FILE"
        FAIL_COUNT=$(grep -c " $IP$" "$TRACK_FILE")
        
        if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
            MSG=$(printf "$MSG_BRUTE_FORCE_LUCI" "${USER:-unknown}" "${IP:-unknown}")
            /usr/bin/telegram_notify.sh "SECURITY" "$MSG"
            # Prevent spamming for this IP in the current window by removing its older entries
            grep -v " $IP$" "$TRACK_FILE" > "${TRACK_FILE}.tmp"
            mv "${TRACK_FILE}.tmp" "$TRACK_FILE"
        fi
        continue
    fi

    # 2. LuCI Login Berhasil
    if echo "$line" | grep -q "luci: accepted login"; then
        USER=$(echo "$line" | sed -n 's/.*accepted login on .* for \(.*\) from .*/\1/p')
        IP=$(echo "$line" | sed -n 's/.*from \([0-9\.]*\).*/\1/p')
        MSG=$(printf "$MSG_LOGIN_LUCI" "${USER:-unknown}" "${IP:-unknown}")
        /usr/bin/telegram_notify.sh "AUTH" "$MSG"
        continue
    fi

    # 3. SSH Brute Force
    if echo "$line" | grep -q "dropbear.*Bad password"; then
        USER=$(echo "$line" | sed -n "s/.*Bad password for '\([^']*\)'.*/\1/p")
        IP=$(echo "$line" | sed -n 's/.*from <\([0-9\.]*\):.*/\1/p')
        
        echo "$NOW $IP" >> "$TRACK_FILE"
        FAIL_COUNT=$(grep -c " $IP$" "$TRACK_FILE")
        
        if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
            MSG=$(printf "$MSG_BRUTE_FORCE_SSH" "${USER:-unknown}" "${IP:-unknown}")
            /usr/bin/telegram_notify.sh "SECURITY" "$MSG"
            grep -v " $IP$" "$TRACK_FILE" > "${TRACK_FILE}.tmp"
            mv "${TRACK_FILE}.tmp" "$TRACK_FILE"
        fi
        continue
    fi

    # 4. SSH Login Berhasil
    if echo "$line" | grep -q "dropbear.*Password auth succeeded"; then
        USER=$(echo "$line" | sed -n "s/.*Password auth succeeded for '\([^']*\)'.*/\1/p")
        IP=$(echo "$line" | sed -n 's/.*from <\([0-9\.]*\):.*/\1/p')
        MSG=$(printf "$MSG_LOGIN_SSH" "${USER:-unknown}" "${IP:-unknown}")
        /usr/bin/telegram_notify.sh "AUTH" "$MSG"
        continue
    fi
done
