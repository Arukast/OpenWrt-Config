#!/bin/sh
# File: /usr/bin/dhcp_notify.sh

ACTION="$1"
MAC="$2"
IP="$3"
HOST="$4"

# Jika perangkat tidak memiliki nama host, beri label Unknown
[ -z "$HOST" ] && HOST="Unknown"

if [ "$ACTION" = "add" ]; then
    /usr/bin/telegram_notify.sh "CLIENT" "Klien Baru Terhubung*%0AIP: $IP%0AMAC: $MAC%0AHost: $HOST"
elif [ "$ACTION" = "del" ]; then
    /usr/bin/telegram_notify.sh "CLIENT" "Klien Terputus*%0AIP: $IP%0AMAC: $MAC%0AHost: $HOST"
fi

