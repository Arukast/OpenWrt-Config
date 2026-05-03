#!/bin/sh
# Telegram Monitoring Install Script

set -e

SRC_DIR="$(dirname "$0")"

echo "Installing Telegram Monitoring..."

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

# Adjust config loading path in installed scripts
sed -i 's|$(dirname "$0")/lang|/etc/telegram_lang|g' /usr/bin/router_monitor.sh
sed -i 's|$(dirname "$0")/lang|/etc/telegram_lang|g' /usr/bin/auth_monitor.sh

# Copy hotplug scripts
mkdir -p /etc/hotplug.d/iface/
mkdir -p /etc/hotplug.d/dhcp/

cp "$SRC_DIR/99-wisp-notify" /etc/hotplug.d/iface/
cp "$SRC_DIR/dhcp_notify.sh" /etc/hotplug.d/dhcp/99-dhcp-notify

# Adjust config loading path in hotplug scripts
sed -i 's|$(dirname "$0")/lang|/etc/telegram_lang|g' /etc/hotplug.d/iface/99-wisp-notify
sed -i 's|$(dirname "$0")/lang|/etc/telegram_lang|g' /etc/hotplug.d/dhcp/99-dhcp-notify

# Install config if not exists
if [ ! -f /etc/telegram.conf ]; then
    cp "$SRC_DIR/telegram.conf.example" /etc/telegram.conf
    echo "Please edit /etc/telegram.conf with your Webhook URL"
fi

# Setup cron for router_monitor
if ! grep -q "router_monitor.sh" /etc/crontabs/root 2>/dev/null; then
    echo "* * * * * /usr/bin/router_monitor.sh" >> /etc/crontabs/root
    /etc/init.d/cron restart
fi

# Setup auth_monitor to run on boot
if ! grep -q "auth_monitor.sh" /etc/rc.local 2>/dev/null; then
    sed -i '/exit 0/i \/usr/bin/auth_monitor.sh &' /etc/rc.local
fi

echo "Installation complete!"
