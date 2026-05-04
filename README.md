# OpenWrt-Config

Automated configuration and advanced monitoring suite for OpenWrt routers. This repository contains scripts to rapidly deploy a secure, optimized OpenWrt setup (WISP mode, SQM, DoH) and a comprehensive Telegram monitoring system.

## Features

- **Automated Setup (`OpenWrtSetup.sh`)**: Configures WISP, LAN, WiFi, Tailscale, SQM (CAKE), DNS over HTTPS (DoH), and ZRAM with a single script. Supports Dry-Run and idempotency.
- **Verification (`OpenWrtSetupTest.sh`)**: Validates system health, network configurations, storage limits, and routing post-setup.
- **Telegram Monitoring**: Real-time alerts for system resources, VPN status, brute-force attempts, and client connections.
- **Multi-language Support**: Telegram alerts support English (`en`) and Indonesian (`id`).

## 1. Quick Start: OpenWrt Setup

### Prerequisites
- A router flashed with OpenWrt 23.05+
- Internet connection (via ethernet or tethering) for initial package downloads.

### Installation
1. Connect your PC to the router.
2. Transfer the setup script and example configuration to the router via SCP:
   ```bash
   scp OpenWrtSetup.sh setup.conf.example root@192.168.1.1:/tmp/
   ```
3. SSH into the router, copy the example config, and edit your secrets:
   ```bash
   cd /tmp
   cp setup.conf.example setup.conf
   vi setup.conf # Ensure you change WIFI_KEY
   ```
4. Run the script:
   ```bash
   sh OpenWrtSetup.sh --config setup.conf
   ```
   ssh root@192.168.1.1
   chmod +x /tmp/OpenWrtSetup.sh
   # Optional: run with --dry-run first to see what will change
   sh /tmp/OpenWrtSetup.sh
   ```
4. Follow the prompts. The router will automatically reboot upon successful completion.

### Post-Setup Verification
After the router reboots, transfer and run the test script:
```bash
scp OpenWrtSetupTest.sh root@192.168.11.1:/tmp/
ssh root@192.168.11.1
chmod +x /tmp/OpenWrtSetupTest.sh
sh /tmp/OpenWrtSetupTest.sh
```

---

## 2. Telegram Monitoring Setup

The `TelegramMonitoring` directory contains scripts to track router health, auth attempts, and DHCP events.

### Configuration
1. Open `TelegramMonitoring/telegram.conf.example` and rename it to `telegram.conf`.
2. Add your Google Apps Script Webhook URL and select your language (`en` or `id`).
   ```bash
   GAS_URL="https://script.google.com/macros/s/YOUR_ID/exec"
   LANG="en"
   ```
3. Transfer the directory to your router:
   ```bash
   scp -r TelegramMonitoring root@192.168.11.1:/tmp/
   ```
4. Run the installer:
   ```bash
   ssh root@192.168.11.1
   chmod +x /tmp/TelegramMonitoring/install.sh
   /tmp/TelegramMonitoring/install.sh
   ```

### Included Monitors
- **`router_monitor.sh`**: Runs via cron. Checks RAM, Tailscale, WiFi status, latency, storage, CPU load, SQM status, and WAN IP changes.
- **`auth_monitor.sh`**: Runs continuously in background. Tracks successful/failed LuCI and SSH logins. Triggers alerts on brute-force attempts.
- **`dhcp_notify.sh`**: Hotplug script for DHCP events. Alerts when unknown devices connect/disconnect.
- **`99-wisp-notify`**: Hotplug script. Alerts when WISP connection drops or recovers, including downtime duration and signal strength.

---

## Troubleshooting

- **"Operation not permitted" (wget/curl/apk)**: Your router's clock is out of sync, causing SSL verification to fail. The setup script attempts to fix this automatically using `ntpd`.
- **Subnet Conflict**: If your upstream WISP network uses `192.168.1.x`, ensure your router's LAN IP is changed (e.g., to `192.168.11.1`) to avoid routing loops.
- **Telegram Rate Limits**: Notifications are throttled to a maximum of 10 per minute to prevent spam.

## License
MIT
