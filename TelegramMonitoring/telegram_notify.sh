#!/bin/sh
# File: /usr/bin/telegram_notify.sh
# Usage: /usr/bin/telegram_notify.sh "CATEGORY" "Your Message"

if [ $# -lt 2 ]; then
    echo "Usage: $0 \"CATEGORY\" \"Message\"" >&2
    exit 1
fi

KATEGORI="$1"
PESAN="$2"

# Load config
CONF="/etc/telegram.conf"
[ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
[ -f "$CONF" ] || { echo "ERROR: telegram.conf not found" >&2; exit 1; }
. "$CONF"

[ -z "$GAS_URL" ] && { echo "ERROR: GAS_URL not set in telegram.conf" >&2; exit 1; }

# Add timestamp to message
TS=$(date "+%Y-%m-%d %H:%M:%S")
PESAN="[${TS}] %0A${PESAN}"

# Escape JSON payload properly
# Replace newlines with %0A to be handled by telegram properly, and escape quotes
JSON_PAYLOAD=$(printf '{"kategori": "%s", "pesan": "%s"}' \
    "$(echo "$KATEGORI" | sed 's/"/\\"/g')" \
    "$(echo "$PESAN" | sed 's/"/\\"/g')")

# Rate limiting: Max 10 messages per minute
RATE_LIMIT_FILE="/tmp/telegram_rate_limit"
RATE_LIMIT_MAX=10
RATE_LIMIT_WINDOW=60
NOW=$(date +%s)

if [ -f "$RATE_LIMIT_FILE" ]; then
    # Clean up old entries
    awk -v now="$NOW" -v window="$RATE_LIMIT_WINDOW" 'now - $1 <= window' "$RATE_LIMIT_FILE" > "${RATE_LIMIT_FILE}.tmp"
    mv "${RATE_LIMIT_FILE}.tmp" "$RATE_LIMIT_FILE"
    
    # Check limit
    COUNT=$(wc -l < "$RATE_LIMIT_FILE")
    if [ "$COUNT" -ge "$RATE_LIMIT_MAX" ]; then
        echo "ERROR: Rate limit exceeded ($COUNT msgs in ${RATE_LIMIT_WINDOW}s). Dropping message." >&2
        exit 429
    fi
fi
echo "$NOW" >> "$RATE_LIMIT_FILE"

# Send with retry logic
MAX_RETRIES=3
RETRY_DELAY=2
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    HTTP_CODE=$(curl -s -L -w "%{http_code}" -o /dev/null -X POST "$GAS_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")
        
    if [ "$HTTP_CODE" = "200" ]; then
        exit 0
    fi
    
    echo "Attempt $ATTEMPT failed with HTTP code $HTTP_CODE. Retrying in $RETRY_DELAY seconds..." >&2
    sleep $RETRY_DELAY
    ATTEMPT=$((ATTEMPT + 1))
    RETRY_DELAY=$((RETRY_DELAY * 2))
done

echo "ERROR: Failed to send Telegram notification after $MAX_RETRIES attempts." >&2
exit 1
