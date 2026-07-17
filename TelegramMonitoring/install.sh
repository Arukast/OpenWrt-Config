#!/bin/sh
# Telegram Monitoring Install Script

set -e

SRC_DIR="$(dirname "$0")"

# Detect if current router is configured as a Dumb AP
IS_DUMB_AP=0
PRIMARY_ROUTER_IP=""
if [ "$(uci -q get dhcp.lan.ignore)" = "1" ] && [ -n "$(uci -q get network.lan.gateway)" ]; then
    IS_DUMB_AP=1
    PRIMARY_ROUTER_IP=$(uci -q get network.lan.gateway)
fi

if [ "$IS_DUMB_AP" -eq 1 ]; then
    echo "========================================================"
    echo "DUMB AP DETECTED (DHCP disabled, LAN gateway defined)"
    echo "Setting up Coordinated Monitoring & Lease Sync..."
    echo "========================================================"

    # 1. SSH Key Generation
    if [ ! -f /root/.ssh/id_ed25519 ]; then
        echo "Generating SSH key pair for Dumb AP..."
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
        chmod 600 /root/.ssh/id_ed25519
    fi

    # 2. Copy core scripts
    cp "$SRC_DIR/telegram_notify_dumb_ap.sh" /usr/bin/telegram_notify.sh
    cp "$SRC_DIR/dumb_ap_monitor.sh" /usr/bin/
    cp "$SRC_DIR/auth_monitor.sh" /usr/bin/

    chmod +x /usr/bin/telegram_notify.sh
    chmod +x /usr/bin/dumb_ap_monitor.sh
    chmod +x /usr/bin/auth_monitor.sh

    # 3. Setup cron for lease sync & dumb_ap_monitor
    # Ensure cron is enabled
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron start 2>/dev/null || true

    if ! grep -q "dhcp.leases" /etc/crontabs/root 2>/dev/null; then
        echo "Adding lease synchronization cron job (every 5 minutes)..."
        echo "*/5 * * * * scp -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no root@$PRIMARY_ROUTER_IP:/tmp/dhcp.leases /tmp/dhcp.leases" >> /etc/crontabs/root
    fi

    if ! grep -q "dumb_ap_monitor.sh" /etc/crontabs/root 2>/dev/null; then
        echo "Adding Dumb AP monitor cron job (every 5 minutes)..."
        echo "*/5 * * * * /usr/bin/dumb_ap_monitor.sh" >> /etc/crontabs/root
    fi
    /etc/init.d/cron restart

else
    # Standard router mode configuration
    echo "========================================================"
    echo "STANDARD ROUTER DETECTED"
    echo "Setting up full Direct Telegram Monitoring..."
    echo "========================================================"

    # Check dependencies
    if ! command -v curl >/dev/null 2>&1; then
        echo "Warning: curl is not installed. Attempting to install..."
        opkg update && opkg install curl || {
            echo "Error: Failed to install curl. Please install it manually with 'opkg update && opkg install curl'."
            exit 1
        }
    fi

    # Copy core scripts
    cp "$SRC_DIR/telegram_notify.sh" /usr/bin/
    cp "$SRC_DIR/router_monitor.sh" /usr/bin/
    cp "$SRC_DIR/auth_monitor.sh" /usr/bin/

    chmod +x /usr/bin/telegram_notify.sh
    chmod +x /usr/bin/router_monitor.sh
    chmod +x /usr/bin/auth_monitor.sh

    # Setup cron for router_monitor
    if ! grep -q "router_monitor.sh" /etc/crontabs/root 2>/dev/null; then
        echo "Adding router monitor cron job (every minute)..."
        echo "* * * * * /usr/bin/router_monitor.sh" >> /etc/crontabs/root
        /etc/init.d/cron restart
    fi
fi

# Shared configurations for both Standard and Dumb AP modes:

# 4. Copy language files
mkdir -p /etc/telegram_lang
cp "$SRC_DIR/lang/en.sh" /etc/telegram_lang/
cp "$SRC_DIR/lang/id.sh" /etc/telegram_lang/

# 5. Copy hotplug scripts (Only relevant if interface is wan/wwan, but harmless to copy)
mkdir -p /etc/hotplug.d/iface/
cp "$SRC_DIR/99-wisp-notify" /etc/hotplug.d/iface/
chmod +x /etc/hotplug.d/iface/99-wisp-notify

# 6. Copy SSH notify script
if [ -f "$SRC_DIR/99-ssh-notify.sh" ]; then
    cp "$SRC_DIR/99-ssh-notify.sh" /etc/profile.d/
    chmod +x /etc/profile.d/99-ssh-notify.sh
fi

# 7. Install config (Only needed for placeholders or language settings on Dumb AP)
if [ -f "$SRC_DIR/telegram.conf" ]; then
    echo "Overwriting /etc/telegram.conf with local copy..."
    cp "$SRC_DIR/telegram.conf" /etc/telegram.conf
    chmod 600 /etc/telegram.conf 2>/dev/null || true
elif [ ! -f /etc/telegram.conf ] || grep -q "YOUR_SCRIPT_ID_HERE" /etc/telegram.conf; then
    echo "Installing default /etc/telegram.conf..."
    cp "$SRC_DIR/telegram.conf.example" /etc/telegram.conf
    chmod 600 /etc/telegram.conf 2>/dev/null || true
else
    echo "Preserving existing /etc/telegram.conf"
fi

# 8. Setup auth_monitor to run on boot (Handle missing /etc/rc.local)
RC_LOCAL="/etc/rc.local"
AUTH_CMD="/usr/bin/auth_monitor.sh &"

if [ ! -f "$RC_LOCAL" ]; then
    echo "Creating $RC_LOCAL..."
    printf "#!/bin/sh\n\n%s\n\nexit 0\n" "$AUTH_CMD" > "$RC_LOCAL"
    chmod +x "$RC_LOCAL"
else
    if ! grep -q "auth_monitor.sh" "$RC_LOCAL"; then
        if grep -q "exit 0" "$RC_LOCAL"; then
            sed -i "/exit 0/i $AUTH_CMD" "$RC_LOCAL"
        else
            echo "$AUTH_CMD" >> "$RC_LOCAL"
        fi
    fi
fi

# Restart auth_monitor to apply updates
echo "Restarting auth_monitor.sh..."
killall auth_monitor.sh 2>/dev/null || true
sleep 1
/usr/bin/auth_monitor.sh &

echo "========================================================"
echo "Installation complete!"
if [ "$IS_DUMB_AP" -eq 1 ]; then
    echo "========================================================"
    echo "CRITICAL STEP:"
    echo "You MUST add this Dumb AP's SSH public key to the"
    echo "Primary Router's authorized_keys file to enable"
    echo "lease synchronization and Telegram forwarding!"
    echo ""
    echo "DUMB AP SSH PUBLIC KEY:"
    cat /root/.ssh/id_ed25519.pub
    echo "========================================================"
fi
