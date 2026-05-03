#!/bin/sh
# File: /etc/hotplug.d/dhcp/99-dhcp-notify

# Load config & lang
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
[ -f "$CONF" ] || { echo "ERROR: telegram.conf not found"; exit 1; }
. "$CONF"

LANG_FILE="$(dirname "$0")/lang/${LANG:-en}.sh"
[ -f "$LANG_FILE" ] && . "$LANG_FILE" || . "$(dirname "$0")/lang/en.sh"

KNOWN_DEVICES="/etc/known_devices"
[ ! -f "$KNOWN_DEVICES" ] && touch "$KNOWN_DEVICES"

ACTION=$1
MAC=$2
IP=$3
HOST=${4:-"Unknown"}

# Verify arguments
if [ -z "$ACTION" ] || [ -z "$MAC" ] || [ -z "$IP" ]; then
    exit 0
fi

# Check against known devices (only alert if unknown)
if grep -qi "$MAC" "$KNOWN_DEVICES"; then
    # Device is known, skip alert to avoid spam
    exit 0
fi

if [ "$ACTION" = "add" ] || [ "$ACTION" = "update" ]; then
    MSG=$(printf "$MSG_CLIENT_ADD" "$IP" "$MAC" "$HOST")
    /usr/bin/telegram_notify.sh "DHCP" "$MSG"
elif [ "$ACTION" = "del" ]; then
    MSG=$(printf "$MSG_CLIENT_DEL" "$IP" "$MAC" "$HOST")
    /usr/bin/telegram_notify.sh "DHCP" "$MSG"
fi
