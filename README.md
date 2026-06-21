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
2. Copy and Edit the configuration inside `setup/setup.conf`, then transfer the entire `setup` directory to the router via SCP:
   ```bash
   scp -O -r setup root@192.168.1.1:/tmp/
   ```
3. SSH into the router:
   ```bash
   ssh root@192.168.1.1
   ```
4. Run the script:
   ```bash
   sh /tmp/setup/OpenWrtSetup.sh --config /tmp/setup/setup.conf
   # Optional: run with --dry-run first to see what will change
   ```
4. Follow the prompts. The router will automatically reboot upon successful completion.

### Post-Setup Verification
After the router reboots, transfer and run the test script:
```bash
scp -O OpenWrtSetupTest.sh root@192.168.11.1:/tmp/
ssh root@192.168.11.1
sh /tmp/OpenWrtSetupTest.sh
```

### SQM Speed Optimization (Optional)
If you want to automatically calculate and apply the optimal SQM (Smart Queue Management) values based on your actual internet speed, use the included `SQM_Speedtest.sh` script.

This script tests your download and upload speeds, performs a **CPU Bottleneck Analysis** to ensure your router can handle SQM at your current speed, and can automatically apply the optimized values directly to your live router or `setup.conf`.

**To run on the router (Recommended for live configuration):**
```bash
scp -O SQM_Speedtest.sh root@192.168.11.1:/tmp/
ssh root@192.168.11.1
sh /tmp/SQM_Speedtest.sh
```

---

## 2. Telegram Monitoring Setup

The `TelegramMonitoring` directory contains scripts to track router health, auth attempts, and DHCP events.

### Configuration & Google Apps Script Setup

To get real-time Telegram alerts and keep an automated log in Google Sheets, you need to set up a Telegram Bot and a Google Apps Script Web App. Follow these steps:

#### **Step A: Get your Telegram Bot Token & Chat ID**
1. Message `@BotFather` on Telegram, send `/newbot`, and follow the prompts to get your **HTTP API Token** (`token`).
2. Message `@userinfobot` or `@GetMyIDBot` on Telegram to retrieve your personal **Telegram Chat ID** (`chatId`).

#### **Step B: Setup your Google Sheet & Apps Script**
1. Create a new, empty Google Spreadsheet (e.g., name it `Router Monitoring Log`).
2. In the Spreadsheet menu, go to **Extensions** -> **Apps Script**.
3. Clear the default `Code.gs` content and paste the code from [spreadsheet_google_apps_script.js](file:///home/arukast/openwrt/TelegramMonitoring/spreadsheet_google_apps_script.js).
4. Fill in your Telegram Token and Chat ID inside the variables at lines 19-20:
   ```javascript
   var token = "YOUR_TELEGRAM_BOT_TOKEN";
   var chatId = "YOUR_TELEGRAM_CHAT_ID";
   ```
5. Click the **Save** (floppy disk) icon.

#### **Step C: Deploy as a Web App**
1. In the top-right corner of the Apps Script page, click **Deploy** -> **New deployment**.
2. Click the gear icon next to "Select type" and choose **Web app**.
3. Set the following options:
   - **Description**: `Router Alerts and Logging Webhook`
   - **Execute as**: `Me (your-email@gmail.com)`
   - **Who has access**: **`Anyone`** *(This is critical! Your router needs access to post logs without authentication).*
4. Click **Deploy**. Authorize Google permissions if prompted (click *Advanced* -> *Go to Project (unsafe)*).
5. Copy the generated **Web App URL** (e.g., `https://script.google.com/macros/s/YOUR_SCRIPT_ID/exec`).

#### **Step D: Configure and Install on your Router**
1. Copy `TelegramMonitoring/telegram.conf.example` and rename it to `telegram.conf`.
2. Open `TelegramMonitoring/telegram.conf` and paste your copied Web App URL:
   ```bash
   GAS_URL="https://script.google.com/macros/s/YOUR_SCRIPT_ID/exec"
   LANG="en" # Use "en" for English or "id" for Indonesian
   ```
3. Transfer the directory to your router:
   ```bash
   scp -O -r TelegramMonitoring root@192.168.11.1:/tmp/
   ```
   *(Note: If you have already changed your router IP to a different temporary IP like `192.168.12.1`, make sure to use that IP instead!)*
4. Run the installer:
   ```bash
   ssh root@192.168.11.1  # (Or your router's current temporary IP)
   sh /tmp/TelegramMonitoring/install.sh
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
