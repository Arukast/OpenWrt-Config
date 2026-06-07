#!/bin/sh
# Telegram Monitoring Install Script

set -e

SRC_DIR="$(dirname "$0")"

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

# Copy language files
mkdir -p /etc/telegram_lang
cp "$SRC_DIR/lang/en.sh" /etc/telegram_lang/
cp "$SRC_DIR/lang/id.sh" /etc/telegram_lang/

# Copy hotplug scripts
mkdir -p /etc/hotplug.d/iface/

cp "$SRC_DIR/99-wisp-notify" /etc/hotplug.d/iface/
chmod +x /etc/hotplug.d/iface/99-wisp-notify

# Copy SSH notify script
if [ -f "$SRC_DIR/99-ssh-notify.sh" ]; then
    cp "$SRC_DIR/99-ssh-notify.sh" /etc/profile.d/
    chmod +x /etc/profile.d/99-ssh-notify.sh
fi

# Install config
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

# Setup cron for router_monitor
if ! grep -q "router_monitor.sh" /etc/crontabs/root 2>/dev/null; then
    echo "* * * * * /usr/bin/router_monitor.sh" >> /etc/crontabs/root
    /etc/init.d/cron restart
fi

# Setup auth_monitor to run on boot (Handle missing /etc/rc.local)
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


echo "Installation complete!"
