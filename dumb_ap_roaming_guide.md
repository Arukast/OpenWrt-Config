# OpenWrt Coordinated Dumb Access Point & Roaming Guide

This guide provides a comprehensive, step-by-step walkthrough to configure a secondary OpenWrt router to act as a coordinated "Dumb Access Point" (Dumb AP) and seamless roaming node. 

By following this guide, you will expand your network's physical footprint, reclaim unused physical ports, and enable clean, client-initiated fast roaming (802.11r/k/v) without IP conflicts or double-NAT bottlenecks.

---

## 1. Network Topology & Architectural Overview

To create a single, unified network where devices roam seamlessly, the physical and logical placement of the secondary router is critical.

### Physical Wiring: LAN-to-LAN (or Bridged WAN)
The secondary router must connect from its **LAN port** (or a bridged WAN port) directly to a **LAN port on the primary router**, rather than connecting directly to the ISP gateway or upstream WAN.

```
       +-----------------+
       |   ISP Gateway   |
       +--------+--------+
                | (WAN)
       +--------v--------+
       | Primary Router  | [IP: 192.168.11.1]
       | (DHCP Server)   |
       +--------+--------+
                | (LAN Port)
                |
                | (LAN Port or Bridged WAN)
       +--------v--------+
       | Secondary AP    | [IP: 192.168.11.2]
       |  (Dumb Access)  | (DHCP Disabled)
       +-----------------+
```

### Why LAN-to-LAN connection is mandatory:
* **Single Broadcast Domain (Layer 2 Flat Network):** Seamless Wi-Fi roaming requires that the client device retains its IP address when shifting between access points. If a client has to request a new IP address via DHCP or changes its subnet, active TCP connections, VPNs, and streaming services will instantly drop. Connecting LAN-to-LAN keeps all clients on the same Layer 2 network.
* **Avoid Double-NAT & Subnet Segmentation:** Connecting the secondary router's WAN port (without bridging) forces it to create a second local subnet, perform Network Address Translation (NAT) again, and firewall local traffic. This isolates clients on the secondary router from local resources (like printers or NAS devices) connected to the primary router, while degrading gaming and peer-to-peer performance.

---

## 2. Interface Configuration & DHCP Disabling

The secondary router must be configured to act as a transparent bridge, deferring all routing, IP allocation, and DNS resolution tasks to the primary router.

### Step-by-Step Configuration (LuCI GUI)
1. Disconnect the secondary router from the primary router and connect your computer directly to one of the secondary router's LAN ports.
2. Open your browser, navigate to the secondary router's LuCI interface (typically `http://192.168.1.1`), and log in.
3. Go to **Network ➔ Interfaces**.
4. Click **Edit** next to the **LAN** interface:
   * **Protocol:** Keep or change to **Static address**.
   * **IPv4 address:** Choose a static IP within the primary router's subnet but *outside* its active DHCP range (e.g., if the primary is `192.168.11.1`, assign `192.168.11.2` to the secondary).
   * **IPv4 netmask:** Match the primary subnet (usually `255.255.255.0`).
   * **IPv4 gateway:** Set to the IP address of the primary router (e.g., `192.168.11.1`).
   * **Use custom DNS servers:** Set to the IP address of the primary router (e.g., `192.168.11.1`).
5. Scroll down to the **DHCP Server** settings tab for the LAN interface:
   * Under **General Setup**: Check the box for **Ignore interface** (this completely disables the IPv4 DHCP server).
   * Under **IPv6 Settings**: Set **Router Advertisement-Service**, **DHCPv6-Service**, and **NDP-Proxy** to **disabled**.
6. Click **Save**.
7. Go to **System ➔ Startup** and disable the `dnsmasq` and `odhcpd` services to guarantee they do not start or intercept traffic on boot. (Click **Disable** and **Stop** for both).
8. Apply changes by clicking **Save & Apply**.

> [!IMPORTANT]
> Once you click **Save & Apply**, you will lose access to the secondary router. You must now physically connect the LAN port of the secondary router to the LAN port of the primary router. You can then access the secondary router's admin panel at its new static IP address (e.g., `http://192.168.11.2`).

### Command Line Execution (UCI CLI)
If you prefer configuring the interfaces over SSH, run this block on the secondary router:

```bash
# 1. Configure LAN static IP, Gateway, and DNS
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.11.2'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.11.1'
uci add_list network.lan.dns='192.168.11.1'

# 2. Disable IPv4 DHCP on LAN
uci set dhcp.lan.ignore='1'

# 3. Disable IPv6 DHCP & Router Advertisements
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ndp='disabled'

# 4. Commit changes
uci commit
/etc/init.d/network restart
/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop
```

> [!WARNING]
> **If you lose access immediately after running the commands above:**
> Because you disabled the secondary router's DHCP server, your computer can no longer automatically obtain an IP address from it. To regain access:
> 1. **Connect the routers:** Connect a LAN port of the secondary router to a LAN port of the primary router.
> 2. **Renew your PC IP:** Unplug and replug your computer's ethernet cable (or toggle your Wi-Fi) so it gets a fresh IP (in the `192.168.11.x` range) from the **primary** router.
> 3. **Manual Static IP (Alternative):** If configuring the secondary router standalone, manually assign your computer a static IP of `192.168.11.50` with subnet mask `255.255.255.0` in your OS network settings to access `http://192.168.11.2`.

---


## 3. Port Optimization: Bridging WAN to LAN

Because a Dumb AP does not perform WAN routing, the physical WAN port on the secondary router is wasted. We can reclaim this physical port and bridge it into the `br-lan` network interface to act as a regular LAN switch port.

### Step-by-Step Configuration (LuCI GUI)
1. Access the secondary router's web panel at its new static IP (e.g., `http://192.168.11.2`).
2. Go to **Network ➔ Interfaces** and click the **Devices** tab at the top.
3. Locate the bridge device named **`br-lan`** and click **Configure**.
4. In the **Bridge ports** dropdown list, select your physical WAN interface (often listed as `wan`, `eth1`, `eth0.2`, or `ge0` depending on your router architecture) to add it to the bridge alongside the LAN ports.
5. Click **Save**.
6. Go back to the **Interfaces** tab:
   * Select and **Delete** the unused **WAN** and **WAN6** interface profiles to avoid firewall zone conflicts.
7. Click **Save & Apply**.

### Command Line Execution (UCI CLI)
Run these commands over SSH to bridge the WAN port and clean up unused WAN interfaces:

```bash
# 1. Identify the physical WAN interface name (typically 'wan' or 'eth1')
# 2. Add the physical WAN interface to the br-lan bridge ports list
uci add_list network.device.ports='wan'   # Adjust interface name if different

# 3. Delete WAN interface configurations to prevent routing anomalies
uci delete network.wan
uci delete network.wan6

# 4. Commit changes and restart network service
uci commit network
/etc/init.d/network restart
```

---

## 4. Codebase Script Execution (Isolated Packages Subsystem)

To ensure smooth client steering and roam handoffs, we must replace the default basic WPAD package with the full `wpad-openssl` driver package and install `usteer` (the band steering daemon). 

We can leverage the repository's setup script located at [OpenWrtSetup.sh](file://./setup/OpenWrtSetup.sh). We will run it with the target module flag `--module packages` to install only the packages and avoid executing the full script (which would otherwise overwrite our hand-configured network, firewall, and DHCP settings).

### Step-by-Step Setup:
1. Ensure the secondary router is connected to the primary router and has active internet access.
2. Edit `setup/setup.conf` to ensure `ENABLE_USTEER=1` is active.
3. Transfer the `/setup` folder from this repository to the secondary router's `/tmp` directory using SCP or SFTP:
   ```bash
   scp -O -r setup root@192.168.11.2:/tmp/
   ```
4. SSH into the secondary router:
   ```bash
   ssh root@192.168.11.2
   ```
5. Run the setup script using the packages module flag:
   ```bash
   sh /tmp/setup/OpenWrtSetup.sh --module packages --no-reboot --config /tmp/setup/setup.conf
   ```

> [!WARNING]
> **CRITICAL VERIFICATION:** 
> When the packages module runs, it will uninstall the pre-installed basic Wi-Fi driver (`wpad-basic-mbedtls` or `wpad-mini`). 
> 
> If your router loses internet during this step or the installation of `wpad-openssl` fails, your router will be left with **no Wi-Fi encryption daemon (hostapd/wpad)**. Consequently, your Wi-Fi radios will refuse to start on reboot (showing "Wireless is not associated" or staying completely down).
> 
> **How to verify and recover:**
> Make sure `wpad-openssl` installed successfully. If it failed, verify your internet connection on the AP and run:
> ```bash
> apk update && apk add wpad-openssl usteer luci-app-usteer
> # (Or use opkg if running an older OpenWrt version)
> ```


### Why we isolate with `--module packages`:
Using `--module packages` calls `setup_packages` inside [03_packages.sh](file://./setup/03_packages.sh) which does the following:
* Runs `apk update` safely.
* Uninstalls restrictive `wpad-basic` packages.
* Installs `wpad-openssl`, `usteer`, and `luci-app-usteer`.
* **Critically, it bypasses** `setup_network`, `setup_dns`, and `setup_firewall` modules which would otherwise re-enable routing, firewall rules, and DHCP services, destroying your Dumb AP architecture.

---

## 5. Wireless Coordination & Fast Roaming (802.11r/k/v)

With the required software installed, we must coordinate the wireless configuration across both the primary router and the secondary Dumb AP.

### 5.1 Wireless Settings Match-up
For roaming to work seamlessly, both routers must broadcast the exact same network parameters:
* **SSID:** Must be identical (e.g., `Home_Wi-Fi`).
* **Security Protocol:** Must be identical (e.g., `WPA2-PSK` or `WPA3-SAE`).
* **Encryption / Cipher:** Must be identical (e.g., `CCMP (AES)`).
* **Wi-Fi Password / Pre-shared Key:** Must be identical.

### 5.2 Roaming Protocol Configuration (802.11k/v/r)
Configure the following parameters in **Network ➔ Wireless** under each SSID interface edit panel, on both the **Primary** and **Secondary** routers:

> [!WARNING]
> **WPA3-SAE / Mixed Mode Compatibility Note:**
> If your Wi-Fi is configured with **sae-mixed** (WPA2/WPA3 Mixed) or pure **WPA3-SAE** encryption, keeping **802.11r Fast Transition enabled** with local PSK generation can cause handshake failures. Mobile clients (such as iPhones and Android devices) may show "Connected, No Internet" or lose internet when transitioning between bands (2.4GHz/5GHz) or APs.
> 
> For the highest compatibility and stability, **disable 802.11r Fast Transition**. Standard roaming steering via 802.11k/v is more than enough for home networks.

| Parameter | Configuration | Purpose |
| :--- | :--- | :--- |
| **802.11r Fast Transition** | **Disabled** (Unchecked) | Keep disabled unless running pure WPA2-PSK and needing sub-100ms roams. |
| **802.11k (RRM)** | **Enabled** (Checked) | Provides client devices with neighbor reports, speeding up scan times. |
| **802.11v (BSS Transition)** | **Enabled** (Checked) | Allows the APs to suggest and steer clients to a better node. |
| **DTIM Period** | Set to **`3`** | Minimizes power drain for sleeping client devices (standard for Apple/Android). |
| **Disassociate on Low Acknowledgement** | **Disabled** (Unchecked) | Prevents the AP from abruptly kicking clients during brief signal fades, letting them roam gracefully. |

#### Command Line Execution (UCI CLI)
If you prefer applying these wireless roaming optimizations across all active AP interfaces at once via SSH, run the following block on **both** routers:

```bash
# Loop through and enable 802.11k/v and DTIM settings for all AP interfaces (disabling 802.11r)
for iface in $(uci show wireless | grep "=wifi-iface" | awk -F'.' '{print $2}'); do
    if [ "$(uci -q get wireless.$iface.mode)" = "ap" ]; then
        echo "Applying roaming optimizations to interface: $iface"
        uci set wireless.$iface.ieee80211k='1'
        uci set wireless.$iface.ieee80211v='1'
        uci set wireless.$iface.ieee80211r='0'
        uci set wireless.$iface.dtim_period='3'
        uci set wireless.$iface.disassoc_low_ack='0'
    fi
done

uci commit wireless
wifi reload
```

---

### 5.3 Non-Overlapping Channel & Power Strategy
To prevent radio interference and address the "sticky client" problem (where a client remains connected to a weak, distant AP), implement a localized channel map and tune transmit powers.

```
       [ 2nd Floor AP ] <--- 5Ghz: Ch 36 (HE80) --- [ Low Tx Power: 14dBm ]
              |
      (Interference Zone)
              |
       [ 1st Floor AP ] <--- 5Ghz: Ch 149 (HE80) -- [ Med Tx Power: 18dBm ]
```

1. **Non-Overlapping Channels:**
   * **2.4 GHz Band:** Select only from channels **`1`**, **`6`**, or **`11`**. For example, assign Channel `1` to the primary router and Channel `6` or `11` to the secondary router.
   * **5 GHz Band:** Ensure channels do not overlap. If using 80 MHz channel widths, use non-overlapping blocks (e.g., Primary on Channel `36` and Secondary on Channel `149`).
2. **Transmit Power Optimization:**
   * Do not set wireless transmit power to "Auto" or "Maximum".
   * A client device will stay connected to a distant AP if its signal remains loud, even if a closer AP is available.
   * Set **2.4 GHz** transmit power to **Low/Medium** (between `12 dBm` and `15 dBm`).
   * Set **5 GHz** transmit power to **Medium/High** (between `17 dBm` and `20 dBm`).
   * Keeping 5 GHz slightly louder encourages clients to select the high-throughput 5 GHz band over 2.4 GHz.

---

## 6. Advanced Tuning & Performance Optimizations (Highly Recommended)

Since we bypassed the full setup installation to protect the bridge settings, we missed several premium performance tunings. You should apply these manually over SSH to maximize your secondary router's CPU efficiency, memory usage, and bridging speed.

### 6.1 Multi-Core CPU & Network Acceleration
By default, OpenWrt processes network traffic on a single CPU core. We can enable Packet Steering (RPS) to distribute load across all available CPU cores, and disable local IPv6 ULA generation which would otherwise conflict with the primary router:

```bash
# 1. Enable Packet Steering (RPS) across all CPU cores
uci set network.globals.packet_steering='2'

# 2. Delete IPv6 ULA-Prefix to prevent client routing confusion
uci -q delete network.globals.ula_prefix

# 3. Disable IPv6 on LAN if IPv6 was toggled off (Optional)
# uci set network.lan.ipv6='0'

uci commit network
/etc/init.d/network restart
```

### 6.2 Bridge Fast Forwarding (Bypass Firewall on Bridged Packets)
Linux bridges pass packet traffic through iptables firewall rules by default if the bridge netfilter module is active. Because the Dumb AP does not perform routing or firewalling between devices, we can disable this.

*Note: If you get "unknown key" errors when running this, it simply means the `kmod-br-netfilter` package is not loaded or installed. In that case, bridge filtering is already disabled by default (which is the optimal setting), and you can safely ignore the error.*

```bash
# Load the bridge netfilter module if installed, then disable packet filtering
modprobe br_netfilter 2>/dev/null || true

cat > /etc/sysctl.d/99-bridge-performance.conf << 'SYSCTL'
net.bridge.bridge-nf-call-arptables=0
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-iptables=0
SYSCTL

# Reload sysctl parameters (ignore errors if keys are unknown)
sysctl -p /etc/sysctl.d/99-bridge-performance.conf 2>/dev/null || true
```

### 6.3 Coordinated Band Steering (Usteer Network-Wide Mode)

Rather than operating independently, Usteer on the secondary router should coordinate with Usteer on the primary router over the LAN to smoothly transition clients. Below is the optimized production-grade configuration that maximizes steering response while preventing drops for weak clients.

> [!IMPORTANT]
> **SSID List Filtering:** It is highly recommended to add your roaming SSID to the `ssid_list` parameter. This prevents Usteer from attempting to steer single-band static IoT devices (which often triggers connection failures on those devices).

```bash
# 1. Clear out factory defaults and initialize a single clean anonymous section
# (This prevents duplicate config blocks and keeps the LuCI Web GUI in sync)
cat <<EOF > /etc/config/usteer
config usteer
EOF

# 2. Base network & multi-node configuration
uci set usteer.@usteer[0].network='lan'
uci set usteer.@usteer[0].local_mode='0'          # Coordinate network-wide between APs
uci set usteer.@usteer[0].ipv6='0'                # Use IPv4 for node-to-node exchange
uci set usteer.@usteer[0].syslog='1'              # Log steering events

# 3. Association & Probe steering filters
uci set usteer.@usteer[0].probe_steering='1'      # Ignore probes from weak clients to let better APs answer
uci set usteer.@usteer[0].assoc_steering='0'      # Disable association steering to prevent "no internet" loops during band/AP steering
uci set usteer.@usteer[0].min_connect_snr='-80'   # Reject associations if signal < -80 dBm (prevents weak edge joins)

# 4. Roaming signal thresholds (measured in absolute dBm)
uci set usteer.@usteer[0].min_snr='-85'           # Mark clients as steering candidates if signal falls below -85 dBm
uci set usteer.@usteer[0].min_snr_kick_delay='5000' # Wait 5 seconds before kicking low-signal clients to avoid transient drops
uci set usteer.@usteer[0].signal_diff_threshold='6' # Only steer if alternative AP has a +6dB signal advantage

# 5. Band steering parameters (preferred 5GHz steering)
uci set usteer.@usteer[0].band_steering_interval='10000' # Check every 10s to move 2.4GHz clients to 5GHz
uci set usteer.@usteer[0].band_steering_min_snr='-68'    # Only steer to 5GHz if target signal is at least -68 dBm

# 6. 802.11v BSS Transition Management (BTM) trigger parameters
uci set usteer.@usteer[0].roam_scan_snr='-72'     # Request link scans when client signal falls below -72 dBm
uci set usteer.@usteer[0].roam_trigger_snr='-76'  # Send 802.11v BTM roam request when client signal falls below -76 dBm
uci set usteer.@usteer[0].roam_kick_delay='10000' # Kick the client after 10s if it ignores the BTM roam request

# 7. SSID Filter (Enable ONLY for your roaming SSID, e.g., 'Home_Wi-Fi')
# Replace 'Home_Wi-Fi' with your unified roaming SSID.
uci -q delete usteer.@usteer[0].ssid_list
uci add_list usteer.@usteer[0].ssid_list='Home_Wi-Fi'

uci commit usteer
/etc/init.d/usteer restart
```
*(Apply this exact same configuration block on your primary router as well to ensure matching steering parameters across the whole network)*.




### 6.4 Safe LAN Watchdog & System Services Clean-up
Disable unneeded system services to free up RAM, set NTP to client-only mode, reduce serial log verbosity to conserve CPU, and configure Watchcat to reboot the network stack only if it loses connectivity to the **primary router** (`192.168.11.1`):

```bash
# 1. Disable unused routing/firewall services to free up RAM
for svc in firewall dnsmasq odhcpd; do
    /etc/init.d/$svc stop 2>/dev/null
    /etc/init.d/$svc disable 2>/dev/null
done

# 2. Align system logging levels and NTP client mode
uci set system.@system[0].conloglevel='8'
uci set system.@system[0].cronloglevel='9'
uci set system.ntp.enabled='1'
uci set system.ntp.enable_server='0'
uci commit system
/etc/init.d/system restart

# 3. Setup a LAN watchdog (Monitor connection to primary router)
uci -q delete system.@watchcat[0]
uci add system watchcat
uci set system.@watchcat[-1].mode='restart_iface'
uci set system.@watchcat[-1].interface='lan'
uci set system.@watchcat[-1].pinghosts='192.168.11.1'
uci set system.@watchcat[-1].addressfamily='ipv4'
uci set system.@watchcat[-1].pingperiod='60'
uci set system.@watchcat[-1].period='5m'
uci commit system
/etc/init.d/system restart
```


## 7. Client Hostname Syncing (Dumb AP LuCI Fix)

Because a Dumb AP has its DHCP server (`dnsmasq` / `odhcpd`) disabled, it has no local leases file (`/tmp/dhcp.leases`). Consequently, the **Associated Stations** table in the Dumb AP's LuCI web interface will display IP addresses (from the local ARP cache) or `?` instead of readable client hostnames.

To resolve client hostnames on your Dumb AP, you can automate copying the active DHCP leases database from your primary router (which actually assigns the IPs and hostnames) to the Dumb AP.

### Step-by-Step Setup:

1. **Create the SSH directory on the Dumb AP:**
   ```bash
   mkdir -p /root/.ssh
   chmod 700 /root/.ssh
   ```

2. **Generate an SSH keypair on the Dumb AP:**
   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
   chmod 600 /root/.ssh/id_ed25519
   ```

3. **Install the public key onto the Primary Router:**
   Print the public key on the Dumb AP:
   ```bash
   cat /root/.ssh/id_ed25519.pub
   ```
   Copy this output string, log into the **Primary Router**, and append it to the trusted SSH keys file:
   ```bash
   echo "YOUR_PUBLIC_KEY_STRING_HERE" >> /etc/dropbear/authorized_keys
   chmod 600 /etc/dropbear/authorized_keys
   ```
   *(Alternatively, paste it into the primary router's LuCI under **System ➔ Administration ➔ SSH-Keys**).*

4. **Verify passwordless login from the Dumb AP:**
   On the Dumb AP, run the following to test connectivity (replace `192.168.11.1` with your primary router's IP):
   ```bash
   ssh -i /root/.ssh/id_ed25519 root@192.168.11.1 "echo Connection Successful"
   ```
   If it prints `Connection Successful` without prompting for a password, your key setup is correct.

5. **Schedule the Lease Sync via Cron:**
   Open the cron editor on the Dumb AP (run `crontab -e` or go to **System ➔ Scheduled Tasks** in LuCI) and add the following entry to sync the file every 5 minutes:
   ```cron
   */5 * * * * scp -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no root@192.168.11.1:/tmp/dhcp.leases /tmp/dhcp.leases
   ```

   **Crucial Cron Service Activation:**
   On OpenWrt, the cron service (`crond`) is not always active or enabled by default, and it will not automatically reload when you modify the crontab file. Run the following commands on the Dumb AP to enable the service, start it, and apply the new configuration:
   ```bash
   /etc/init.d/cron enable
   /etc/init.d/cron start
   /etc/init.d/cron restart
   ```

6. **Verify the Sync:**
   After the cron job runs (or after running the `scp` command manually once), the Associated Stations list in the Dumb AP's LuCI interface will resolve and display client hostnames instead of raw IP addresses or `?`.

   > [!NOTE]
   > Because `/tmp` is a temporary RAM disk (`tmpfs`), `/tmp/dhcp.leases` is cleared whenever the Dumb AP reboots. Hostnames will not display immediately after a boot until the cron job runs at the next 5-minute interval. You can run the `scp` sync command manually once after a reboot to populate them immediately, or add it to `/etc/rc.local` to sync immediately on startup.


---

## 8. Coordinated Telegram Monitoring (Dumb AP to Primary Router Alerts)

Since Telegram monitoring (which requires `curl` and direct internet connection) is best kept on the **Primary Router**, we use a coordinated **SSH forwarding** architecture to monitor the Dumb AP.

The Dumb AP runs lightweight resource and security scripts locally. When an alert triggers, the Dumb AP executes a lightweight forwarding wrapper that SSHs into the primary router to deliver the Telegram notification. This ensures 100% monitoring feature-parity (CPU, RAM, storage, Wi-Fi status, SSH/LuCI logins, and brute-force events) with zero direct internet access or heavy package dependencies on the AP.

### 8.1 Automated Installation

The Telegram Monitoring installer has been updated to automatically configure everything if it detects a Dumb AP architecture:

1. **Transfer the Telegram Monitoring directory to the Dumb AP:**
   ```bash
   scp -O -r TelegramMonitoring root@192.168.11.2:/tmp/
   ```

2. **SSH into the Dumb AP and run the installer:**
   ```bash
   ssh root@192.168.11.2
   sh /tmp/TelegramMonitoring/install.sh
   ```

   The installer will automatically:
   * Detect that the Dumb AP has DHCP disabled and a LAN gateway.
   * Generate the SSH keypair at `/root/.ssh/id_ed25519` (if it does not exist yet).
   * Install the lightweight forwarding wrapper as `/usr/bin/telegram_notify.sh`.
   * Add the DHCP Lease Synchronization cron job to crontab.
   * Add the resource monitor `dumb_ap_monitor.sh` (which alerts on high CPU, low RAM, low storage, and Wi-Fi interface crashes) to crontab.
   * Install the `auth_monitor.sh` background service to watch for LuCI/SSH brute-force logins, and enable real-time SSH login notifications in `/etc/profile.d/99-ssh-notify.sh`.

3. **Authorize the SSH public key on the Primary Router:**
   At the end of the installation, the script will output the Dumb AP's public key. Copy that string, log into the **Primary Router**, and add it:
   ```bash
   echo "YOUR_DUMB_AP_PUBLIC_KEY_STRING_HERE" >> /etc/dropbear/authorized_keys
   chmod 600 /etc/dropbear/authorized_keys
   ```
   *(This step is identical to Section 7 step 3. If you have already authorized this key for lease syncing, you can skip this step).*

### 8.2 Manual Verification

1. **Verify SSH Forwarding Notification:**
   Run this command on the Dumb AP to trigger a test alert. It should successfully execute through the primary router and send a Telegram alert:
   ```bash
   /usr/bin/telegram_notify.sh "SYSTEM" "Test notification from Dumb AP!"
   ```
   The Telegram message received will automatically be prefixed with the Dumb AP's hostname, for example:
   `[2026-07-17 14:58:00] [DumbAP] Test notification from Dumb AP!`

2. **Verify Security Logins:**
   Try logging into the Dumb AP via SSH in a new terminal window. You should instantly receive a Telegram notification showing the login user and IP address.
```
