#!/bin/sh
# File: /usr/bin/router_monitor.sh

# === KONFIGURASI COOLDOWN ===
COOLDOWN=900 # Jeda notifikasi berulang (900 detik = 15 menit)
LOCK_DIR="/tmp/router_locks"
mkdir -p "$LOCK_DIR"

# Fungsi Pengirim dengan Anti-Spam
send_alert() {
    LOCK_NAME="$1"
    KATEGORI="$2"
    PESAN="$3"
    LOCK_FILE="${LOCK_DIR}/${LOCK_NAME}.lock"
    NOW=$(date +%s)

    # Cek apakah masih dalam masa cooldown
    if [ -f "$LOCK_FILE" ]; then
        LAST_SENT=$(cat "$LOCK_FILE")
        DIFF=$((NOW - LAST_SENT))
        if [ "$DIFF" -lt "$COOLDOWN" ]; then
            return 0 # Batalkan pengiriman, belum lewat 15 menit
        fi
    fi

    # Catat waktu baru & kirim notifikasi
    echo "$NOW" > "$LOCK_FILE"
    /usr/bin/telegram_notify.sh "$KATEGORI" "$PESAN"
}

# Fungsi Reset (Hapus kuncian jika kondisi sudah kembali normal)
reset_alert() {
    LOCK_NAME="$1"
    rm -f "${LOCK_DIR}/${LOCK_NAME}.lock"
}

# === MULAI PENGECEKAN ===

# 1. Pengecekan Kapasitas RAM/ZRAM (< 20MB)
FREE_MEM=$(free | awk '/^Mem:/{print int($4/1024)}')
if [ "$FREE_MEM" -lt 30 ]; then
    send_alert "ram" "RESOURCE" "Peringatan Memori: %0ASisa RAM: ${FREE_MEM}MB. Kapasitas kritis!"
else
    reset_alert "ram"
fi

# 2. Pengecekan Status Layanan Tailscale
if ! ping -c 1 -W 2 100.100.100.100 > /dev/null 2>&1; then
    send_alert "tailscale" "VPN" "Isolasi Jaringan: %0AKonektivitas Tailscale terputus."
else
    reset_alert "tailscale"
fi

# 3. Pengecekan Status Radio WiFi 5GHz & 2.4GHz
WIFI_5G=$(ubus call network.wireless status | jsonfilter -e '@.radio1.up')
if [ "$WIFI_5G" = "false" ]; then
    send_alert "wifi5g" "WLAN" "WiFi 5GHz Down: %0AModul radio1 berhenti memancarkan sinyal."
else
    reset_alert "wifi5g"
fi

WIFI_24G=$(ubus call network.wireless status | jsonfilter -e '@.radio0.up')
if [ "$WIFI_24G" = "false" ]; then
    send_alert "wifi24g" "WLAN" "WiFi 2.4GHz Down: %0AModul radio0 berhenti memancarkan sinyal."
else
    reset_alert "wifi24g"
fi

# 4. Pengecekan Latensi WISP (Ping rata-rata > 150ms)
LATENCY=$(ping -c 3 -q 8.8.8.8 2>/dev/null | awk -F'/' 'END{print int($4)}')
if [ -n "$LATENCY" ] && [ "$LATENCY" -gt 150 ]; then
    send_alert "latensi" "UPLINK" "Latensi tinggi terdeteksi: ${LATENCY}ms. Kemungkinan kongesti dari pusat."
else
    reset_alert "latensi"
fi

# 5. Pengecekan Server/Perangkat Lokal
# TARGET_IP="192.168.1.100"
# if ! ping -c 1 -W 1 "$TARGET_IP" > /dev/null 2>&1; then
#     send_alert "node_$TARGET_IP" "NODE" "Perangkat dengan IP $TARGET_IP terputus dari jaringan."
# else
#     reset_alert "node_$TARGET_IP"
# fi

# 6. Pengecekan Penyimpanan Flash (> 90% terpakai)
OVERLAY_USE=$(df /overlay 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [ -n "$OVERLAY_USE" ] && [ "$OVERLAY_USE" -gt 90 ]; then
    send_alert "storage" "RESOURCE" "Kapasitas /overlay kritis: terpakai ${OVERLAY_USE}%. Lakukan pembersihan log."
else
    reset_alert "storage"
fi

# Pengecekan Load Average (Jika beban > 2.00 selama 1 menit)
# Pengecekan Load Average (Abaikan 10 menit pertama saat booting)
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)

if [ "$UPTIME_SEC" -gt 600 ]; then
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
    LOAD_INT=$(echo "$LOAD_AVG" | awk -F. '{print $1}')

    if [ "$LOAD_INT" -ge 2 ]; then
        send_alert "cpu_load" "RESOURCE" "Beban CPU Tinggi! %0ALoad Average: $LOAD_AVG"
    else
        reset_alert "cpu_load"
    fi
fi
