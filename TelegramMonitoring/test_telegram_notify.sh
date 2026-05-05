#!/bin/sh
echo "Testing Telegram notification..."
if /usr/bin/telegram_notify.sh "TEST" "Sistem notifikasi berfungsi normal."; then
    echo "Success: Notification sent!"
else
    echo "Failed: Could not send notification."
fi
