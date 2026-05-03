#!/bin/sh
# File: /etc/profile.d/99-ssh-notify.sh

if [ -n "$SSH_CLIENT" ]; then
    IP_CLIENT=$(echo "$SSH_CLIENT" | awk '{print $1}')
    # Gunakan variabel lingkungan $USER, jika kosong paksa tulis 'root'
    USER_LOGIN=${USER:-"root"}
    /usr/bin/telegram_notify.sh "SECURITY" "Login SSH Berhasil %0AUser: $USER_LOGIN%0ADari IP: $IP_CLIENT"
fi
