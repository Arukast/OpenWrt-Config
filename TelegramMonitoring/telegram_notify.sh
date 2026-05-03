# File: /usr/bin/telegram_notify.sh
# Penggunaan: /usr/bin/telegram_notify.sh "KATEGORI" "Pesan Anda"

# Load config (GAS_URL) from external file — keeps secrets out of git
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
[ -f "$CONF" ] || { echo "ERROR: telegram.conf not found" >&2; exit 1; }
. "$CONF"
KATEGORI="$1"
PESAN="$2"

# Parameter -L penting agar curl mengikuti redirect dari Google
curl -s -L -X POST "$GAS_URL" \
    -H "Content-Type: application/json" \
    -d '{"kategori": "'"$KATEGORI"'", "pesan": "'"$PESAN"'"}' > /dev/null
