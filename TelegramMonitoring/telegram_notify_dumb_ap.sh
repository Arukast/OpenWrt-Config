#!/bin/sh
# File: /usr/bin/telegram_notify.sh (Dumb AP SSH Forwarding Wrapper)

if [ $# -lt 2 ]; then
    echo "Usage: $0 \"CATEGORY\" \"Message\"" >&2
    exit 1
fi

KATEGORI="$1"
PESAN="$2"

PRIMARY_ROUTER_IP=$(uci -q get network.lan.gateway || echo "192.168.11.1")
SSH_KEY="/root/.ssh/id_ed25519"
HOSTNAME=$(uci -q get system.@system[0].hostname || echo "DumbAP")

if [ ! -f "$SSH_KEY" ]; then
    logger -t "telegram_notify" "ERROR: SSH key $SSH_KEY not found. Cannot forward alert."
    exit 1
fi

# Forward the notification via SSH to the primary router
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@$PRIMARY_ROUTER_IP" \
    "/usr/bin/telegram_notify.sh \"$KATEGORI\" \"[$HOSTNAME] $PESAN\""
