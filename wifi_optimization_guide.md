# OpenWrt Premium Wi-Fi Optimization Guide

This guide compiles all the premium wireless optimizations configured for a dual-band OpenWrt router under a single unified SSID (e.g. `Home_Wi-Fi`). Following these steps ensures your client devices (smartphones, laptops, IoT) transition seamlessly between 2.4 GHz and 5 GHz, maximizing signal range, throughput, and battery life without experiencing "connected but no internet" drops.

> [!WARNING]
> **CRITICAL PREPARATION:** 
> Step 1 will temporarily shut down your wireless radios. **If you are connected via Wi-Fi, you will lose connection** and cannot reconnect until Step 1 is complete.
> 
> *It is highly recommended to perform these steps while connected to the router via a **wired LAN cable**.*

---

## 📋 Optimization Summary & Target Specs

| Parameter | 2.4 GHz Band | 5 GHz Band | Rationale |
| :--- | :--- | :--- | :--- |
| **SSID** | `<your-unified-ssid>` | `<your-unified-ssid>` | Single unified SSID (same SSID name on both bands so Usteer can manage steering). |
| **Channel Width** | `20` | `40` | VHT40 on 5 GHz doubles signal density (+3dB gain) for maximum wall penetration. |
| **Channel Selection** | Cleanest channel of `1`, `6`, or `11` | Non-DFS channel (e.g. `36`, `40`, `44`, `48`) | Fixed low non-DFS channels to avoid compatibility issues and radar scan drops. |
| **Transmit Power** | Max legal power (e.g. `20 dBm`) | Max legal power (e.g. `23 dBm`) | Balanced maximum allowed power levels to extend the high-speed boundaries. |
| **DTIM Period** | `3` | `3` | Apple/Android/Microsoft standard. Saves standby battery; prevents dropouts. |
| **Roaming Suite** | `802.11r / k / v` | `802.11r / k / v` | Fast transition and network mapping for smooth handoffs. |
| **Steering Daemon** | `Usteer` | `Usteer` | Actively shifts sticky clients to the best band in real-time. |

---

## 🛠️ Step-by-Step Configuration Tutorial

### Step 1: Upgrading the Wi-Fi Driver to Full WPAD
By default, OpenWrt comes with a basic driver package that strips out RRM (802.11k), BTM (802.11v), and Fast Transition (802.11r) to save space. We must upgrade this first.

1. Navigate to **System ➔ Software** in LuCI.
2. Click **Update lists...** to refresh the packages database.
3. In the search filter, type `wpad-basic`. Under the **Installed** tab, find your active basic package (e.g., `wpad-basic-mbedtls` or `wpad-basic-openssl`) and click **Uninstall**.
4. Clear the filter, search for `wpad-openssl`, and click **Install** under the **Available** tab.
5. Search for `usteer` and click **Install** on both:
   *   `usteer`
   *   `luci-app-usteer`
6. Go to **System ➔ Reboot** and reboot the router.

---

### Step 2: Advanced Wi-Fi Radio Settings
1. Go to **Network ➔ Wireless**.
2. Click **Edit** on your **2.4 GHz physical Radio** (e.g., `radio0`):
   *   **Channel:** Set to a clean fixed channel (e.g. `1`, `6`, or `11`).
   *   **Transmit Power:** Select the highest recommended value (e.g., `20 dBm`).
   *   Click **Save**.
3. Click **Edit** on your **5 GHz physical Radio** (e.g., `radio1`):
   *   **Channel:** Set to a fixed non-DFS channel (e.g., `44` or `36`).
   *   **Width (HT mode):** Set to `VHT40` (40 MHz) or `HE40` (if running Wi-Fi 6).
   *   **Transmit Power:** Select the highest recommended value (e.g., `23 dBm`).
   *   Click **Save**.

---

### Step 3: Configure WLAN Roaming (SSID Interfaces)
For **both** the 2.4 GHz and 5 GHz SSID AP interfaces, click **Edit** under the SSID settings, navigate to the **WLAN Roaming** tab, and configure as follows:

1. **802.11r Fast Transition:** Check **Enable**.
2. **Fast Transition over DS:** Uncheck / Disable. *(Using FT Over-the-Air is far more compatible with older devices)*.
3. **Mobility Domain:** Type a 4-digit hex ID (e.g. **`1234`** or **`abcd`**). *Note: This domain ID must be identical on both bands.*
4. **Radio Resource Measurement (RRM / 802.11k):** Check **Enable**.
5. **BSS Transition Management (BTM / 802.11v):** Check **Enable**.
6. Under the **Advanced Settings** tab:
   *   **DTIM Period:** Set to **`3`** (instead of standard `2`).
   *   **Disassociate on Low Acknowledgement:** Uncheck / Disable *(stops older devices from dropping when sleeping)*.
7. Click **Save** for both interfaces, then click **Save & Apply** at the top right.

---

### Step 4: Configure Band Steering (Usteer)
Usteer is your micro-steering manager that prevents sticky connections.

1. Navigate to the new page under **Network ➔ Usteer**.
2. Scroll to the **Settings** section and apply:
   *   **Network:** `lan` (Bridge: "br-lan").
   *   **Local mode:** **Check to Enable (`true`)**. *(Tells Usteer that this is a single AP and to run steering decisions locally).*
   *   **Log messages to syslog:** **Check to Enable (`true`)**.
   *   **IPv6 mode:** **Keep Disabled (`false`)**.
3. Click **Save & Apply**.

---

## ⚡ Instant Replication via Command Line (SSH)
If you ever factory-reset your router or want to replicate this entire setup in less than 30 seconds, log in via SSH and run this unified command block:

```bash
# 1. Update and swap driver packages
apk update
for wpad_pkg in wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad-basic; do
    apk info "$wpad_pkg" >/dev/null 2>&1 && apk del "$wpad_pkg"
done
apk add wpad-openssl usteer luci-app-usteer

# 2. Configure Radio settings (Adjust radio names radio0/radio1 as per your hardware)
uci set wireless.radio0.channel='6'
uci set wireless.radio0.txpower='20'
uci set wireless.radio1.channel='44'
uci set wireless.radio1.htmode='VHT40'
uci set wireless.radio1.txpower='23'

# 3. Configure WLAN Roaming (RRM, BTM, 802.11r) for all AP interfaces
for iface in $(uci show wireless | grep "mode='ap'" | awk -F'.' '{print $2}' | sort -u); do
    uci set wireless.${iface}.dtim_period='3'
    uci set wireless.${iface}.disassoc_low_ack='0'
    uci set wireless.${iface}.ieee80211r='1'
    uci set wireless.${iface}.ft_over_ds='0'
    uci set wireless.${iface}.ft_psk_generate_local='1'
    uci set wireless.${iface}.mobility_domain='1234'
    uci set wireless.${iface}.rrm='1'
    uci set wireless.${iface}.rrm_beacon_report='1'
    uci set wireless.${iface}.rrm_neighbor_report='1'
    uci set wireless.${iface}.bss_transition='1'
done

# 4. Configure Usteer Local Mode
uci set usteer.global.network='lan'
uci set usteer.global.local_mode='1'
uci set usteer.global.ipv6='0'
uci set usteer.global.syslog='1'

# Save and restart services
uci commit wireless
uci commit usteer
/etc/init.d/network restart
/etc/init.d/usteer restart
```
