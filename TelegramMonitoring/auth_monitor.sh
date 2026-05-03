#!/bin/sh
# File: /usr/bin/auth_monitor.sh

logread -f | while read -r line; do
    # 1. Deteksi Gagal Login LuCI (Brute Force Web)
    if echo "$line" | grep -q "luci: failed login"; then
        USER_LUCI=$(echo "$line" | awk -F'for ' '{print $2}' | awk '{print $1}')
        IP_LUCI=$(echo "$line" | awk -F'from ' '{print $2}' | awk '{print $1}')
        /usr/bin/telegram_notify.sh "SECURITY" "Peringatan Brute Force (LuCI) %0AUser: $USER_LUCI%0AIP: $IP_LUCI%0AStatus: Sandi salah di Web-UI."
    fi

    # 2. Deteksi Sukses Login LuCI
    if echo "$line" | grep -q "luci: accepted login"; then
        USER_LUCI=$(echo "$line" | awk -F'for ' '{print $2}' | awk '{print $1}')
        IP_LUCI=$(echo "$line" | awk -F'from ' '{print $2}' | awk '{print $1}')
        /usr/bin/telegram_notify.sh "SECURITY" "Login LuCI Berhasil %0AUser: $USER_LUCI%0ADari IP: $IP_LUCI"
    fi

    # 3. Deteksi Gagal Login Dropbear (Brute Force SSH)
    if echo "$line" | grep -q "Bad password attempt"; then
        USER_SSH=$(echo "$line" | awk -F"for '" '{print $2}' | cut -d"'" -f1)
        IP_SSH=$(echo "$line" | awk -F"from " '{print $2}' | cut -d":" -f1)
        /usr/bin/telegram_notify.sh "SECURITY" "Peringatan Brute Force (SSH) %0AUser: $USER_SSH%0AIP: $IP_SSH%0AStatus: Sandi salah di Terminal."
    fi
done
