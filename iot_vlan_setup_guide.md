# Production-Grade OpenWrt IoT VLAN Isolation & Security Guide (DSA Architecture)

This guide provides a comprehensive, production-ready blueprint for creating an isolated **IoT (Internet of Things) VLAN** on an **OpenWrt Router** running OpenWrt 21.02, 23.05, or newer, utilizing modern **DSA (Distributed Switch Architecture)** bridging, strict firewall isolation, cross-VLAN mDNS service discovery, and dual wireless/trunking topology configurations.

---

## Architecture & Network Overview

Isolating untrusted IoT devices (smart bulbs, cameras, vacuum robots, smart TVs) prevents a compromised smart device from pivoting into your primary LAN and accessing personal computers, NAS storage, or sensitive network assets.

```
                                  ┌───────────────────────────────┐
                                  │         WAN (Internet)        │
                                  └───────────────┬───────────────┘
                                                  │
                                                  ▼
                                 ┌─────────────────────────────────┐
                                 │   OpenWrt Router (Gateway)      │
                                 │   Main Bridge: br-lan           │
                                 └───────┬─────────────────┬───────┘
                                         │                 │
              ┌──────────────────────────┘                 └──────────────────────────┐
              ▼                                                                       ▼
┌──────────────────────────────┐                                    ┌──────────────────────────────┐
│       Main LAN Zone          │                                    │        IoT VLAN 80           │
│ Interface: br-lan            │                                    │ Interface: br-lan.80         │
│ Subnet: 192.168.1.0/24       │                                    │ Subnet: 192.168.80.0/24      │
├──────────────────────────────┤                                    ├──────────────────────────────┤
│ • Laptops, Desktop PCs       │                                    │ • Smart Bulbs / Switches     │
│ • Smartphones & Tablets      │ ───────────────(mDNS)─────────────>│ • Smart TVs & Chromecasts    │
│ • Home Assistant Server      │ <── State Initiation Allowed ───── │ • IP Cameras & Vacuum Bots   │
│ • NAS & Private Servers      │ X── New Connections Blocked ───── │ • Wi-Fi Thermostats          │
└──────────────────────────────┘                                    └──────────────────────────────┘
```

### Network Address & Allocation Plan

| Network Zone | Interface Name | Bridge Device | Tagged VLAN | Subnet | Gateway IP | DHCP Lease Pool |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Main LAN** | `lan` | `br-lan` | Untagged (1) | `192.168.1.0/24` | `192.168.1.1` | `100 - 249` |
| **IoT Zone** | `iot` | `br-lan.80` | **80** | `192.168.80.0/24` | `192.168.80.1` | `100 - 249` |

### Traffic Access Control Matrix

| Source Zone | Destination Zone | Protocol / Target | Firewall Action | Purpose / Rationale |
| :--- | :--- | :--- | :--- | :--- |
| **LAN** | **IoT** | Any / Any | **ACCEPT** | Allows phones/Home Assistant to manage IoT devices. |
| **IoT** | **LAN** | Any / Any | **REJECT / DROP** | Prevents compromised IoT devices from initiating LAN access. |
| **IoT** | **WAN** | Any / Any | **ACCEPT** | Allows IoT devices cloud connectivity / firmware updates. |
| **IoT** | **Router** | DNS (UDP/TCP 53) | **ACCEPT** | Required for IoT hostname resolution. |
| **IoT** | **Router** | DHCP (UDP 67-68) | **ACCEPT** | Required for IoT IP lease allocation. |
| **IoT** | **Router** | SSH (22), LuCI (80/443) | **REJECT** | Prevents IoT devices from reaching router administrative interfaces. |
| **LAN $\leftrightarrow$ IoT**| Multicast | mDNS (UDP 5353) | **REFLECT** | Reflected via `umdns`/`avahi` for AirPlay, HomeKit & Chromecast discovery. |

---

## Step 1: Configure DSA Bridge VLAN 80

OpenWrt 21.02+ uses **DSA (Distributed Switch Architecture)**, treating physical router switch ports (`lan1`, `lan2`, etc.) as individual Linux interfaces bound to the main bridge (`br-lan`).

### Understanding Tagged vs. Untagged Ports

When adding **VLAN 80** to ports on your router, choose the port setting based on what is physically plugged into that port:

1. **Untagged (Access Port)**:
   - **When to use**: Plugged directly into a normal device that does *not* understand VLAN tags (e.g., an IP camera, Smart TV, desktop PC, or printer).
   - **How it works**: The router automatically places any normal network traffic from that port into VLAN 80, and removes the VLAN 80 header before sending data back to the device.
2. **Tagged (Trunk Port)**:
   - **When to use**: Plugged into a VLAN-aware device that handles multiple networks simultaneously (e.g., a Managed Switch, or an external Wi-Fi Access Point broadcasting both `Home-LAN` and `Home-IoT` SSIDs).
   - **How it works**: The router attaches a 4-byte `VLAN 80` tag header to packets traveling over the cable so the receiving switch or AP knows which packet belongs to which network.
3. **Primary CPU Port (`Local` / `br-lan`)**:
   - **Setting**: Always set to **Tagged**. This allows the OpenWrt router CPU itself to send and receive traffic on the VLAN 80 interface (`br-lan.80`).

---

### Real-World Topology Examples

- **Scenario 1: All-in-One OpenWrt Router (Internal Wi-Fi only)**
  - `Local` (CPU Port): **Tagged** (`br-lan:t`)
  - `lan1`, `lan2`, `lan3`, `lan4`: **Off** (or leave untagged in default VLAN 1 for normal LAN devices).
  - *Result*: The router processes VLAN 80 internally and attaches it to the `Home-IoT` wireless SSID created in Step 4.

- **Scenario 2: Dedicated Wired IoT Device (e.g. IP Camera on port `lan4`)**
  - `Local` (CPU Port): **Tagged** (`br-lan:t`)
  - `lan4`: **Untagged** (`lan4:u`)
  - *Result*: Anything plugged directly into `lan4` is automatically put onto the IoT VLAN 80 without needing any VLAN settings on the device itself.

- **Scenario 3: External Access Point or Managed Switch on port `lan1`**
  - `Local` (CPU Port): **Tagged** (`br-lan:t`)
  - `lan1`: **Tagged** (`lan1:t`)
  - *Result*: Port `lan1` carries both default LAN traffic and VLAN 80 traffic down a single cable to the external switch/AP.

---

### Method A: LuCI Web GUI
1. Navigate to **Network $\rightarrow$ Interfaces $\rightarrow$ Devices**.
2. Click **Configure...** on `br-lan`.
3. Select the **Bridge VLAN filtering** tab.
4. Click **Add VLAN**:
   - **VLAN ID**: `80`
   - **Local** (CPU Port): Set to `tagged` (checked/tagged).
   - **Ports**: Set to `tagged` for trunk ports (e.g. `lan1`), `untagged` for dedicated IoT ports (e.g. `lan4`), or `off` if the port is only for Main LAN.
5. Click **Save** $\rightarrow$ **Save & Apply**.

### Method B: UCI Command Line (SSH)
Run the following commands on your OpenWrt router:

```bash
# Enable VLAN filtering on main bridge br-lan
uci set network.br_lan.vlan_filtering='1'

# Add VLAN 80 entry to br-lan device
uci add network bridge-vlan
uci set network.@bridge-vlan[-1].device='br-lan'
uci set network.@bridge-vlan[-1].vlan='80'

# Example A: Tagged on port lan1 (for external AP / managed switch)
uci add_list network.@bridge-vlan[-1].ports='lan1:t'

# Example B: Untagged on port lan4 (for a wired IP camera/device plugged directly into lan4)
uci add_list network.@bridge-vlan[-1].ports='lan4'

# Commit network configuration
uci commit network
/etc/init.d/network restart
```

---

## Step 2: Configure IoT Interface & DHCP Server

Create the logical `iot` interface attached to the VLAN device `br-lan.80` and enable a dedicated DHCP server pool.

### 1. Network Interface Setup (`/etc/config/network`)

#### LuCI Web GUI:
1. Navigate to **Network $\rightarrow$ Interfaces**.
2. Click **Add new interface...**:
   - **Name**: `iot`
   - **Protocol**: `Static address`
   - **Device**: Select `br-lan.80` (Software VLAN device)
3. Under **Device Configuration**:
   - **IPv4 address**: `192.168.80.1`
   - **IPv4 netmask**: `255.255.255.0`
4. Click **Save**.

#### UCI Command Line:
```bash
uci set network.iot=interface
uci set network.iot.proto='static'
uci set network.iot.device='br-lan.80'
uci set network.iot.ipaddr='192.168.80.1'
uci set network.iot.netmask='255.255.255.0'
uci commit network
```

### 2. DHCP Server Configuration (`/etc/config/dhcp`)

#### UCI Command Line:
```bash
uci set dhcp.iot=dhcp
uci set dhcp.iot.interface='iot'
uci set dhcp.iot.start='100'
uci set dhcp.iot.limit='150'
uci set dhcp.iot.leasetime='12h'
# Optional: Force IoT devices to use OpenWrt router IP for DNS
uci add_list dhcp.iot.dhcp_option='6,192.168.80.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

---

## Step 3: Configure Firewall Isolation Rules

Strictly isolate the `iot` firewall zone while granting necessary services (DHCP/DNS) and allowing stateful access from the `lan` zone.

### 1. Firewall Zone Definition

Add the `iot_zone` firewall zone in OpenWrt:

#### UCI Command Line:
```bash
# Create IoT Firewall Zone
uci add firewall zone
uci set firewall.@zone[-1].name='iot_zone'
uci set firewall.@zone[-1].network='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'

# Allow IoT to reach WAN (Internet)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iot_zone'
uci set firewall.@forwarding[-1].dest='wan'

# Allow LAN to reach IoT (Stateful access for phone apps / Home Assistant)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='iot_zone'

uci commit firewall
```

### 2. Allow Essential Gateway Services (DNS & DHCP)

IoT devices must be able to acquire an IP via DHCP and resolve hostnames via DNS.

```bash
# Allow DHCP requests from IoT zone
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DHCP'
uci set firewall.@rule[-1].src='iot_zone'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].src_port='67-68'
uci set firewall.@rule[-1].dest_port='67-68'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow DNS queries (UDP and TCP) from IoT zone
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-DNS'
uci set firewall.@rule[-1].src='iot_zone'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
```

### 3. Explicitly Block Router Management Interfaces

Ensure IoT devices cannot access administrative router services (SSH, LuCI, Telnet).

```bash
# Explicitly block access to Router Web GUI & SSH from IoT
uci add firewall rule
uci set firewall.@rule[-1].name='Block-IoT-Router-Admin'
uci set firewall.@rule[-1].src='iot_zone'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].dest_port='22 80 443 23'
uci set firewall.@rule[-1].target='REJECT'

uci commit firewall
/etc/init.d/firewall restart
```

### 4. Optional: Home Assistant Pinhole Rule Example

If your Home Assistant server resides on `192.168.1.50` on the `lan` zone and needs to receive incoming webhooks or telemetry directly initiated by specific IoT devices (e.g. ESPHome / Tasmota), create an explicit pinhole:

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IoT-to-HomeAssistant-Webhook'
uci set firewall.@rule[-1].src='iot_zone'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].dest_ip='192.168.1.50'
uci set firewall.@rule[-1].dest_port='8123'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

---

## Step 4: Configure IoT Wireless SSID

Create a dedicated Wi-Fi SSID for IoT devices attached directly to the `br-lan.80` bridge device.

### LuCI Web GUI:
1. Navigate to **Network $\rightarrow$ Wireless**.
2. Select your 2.4GHz radio (e.g., `radio0`) and click **Add**.
3. **Interface Configuration**:
   - **ESSID**: `Home-IoT` (or `Home-IoT-2.4G`)
   - **Mode**: `Access Point`
   - **Network**: Check `iot` (bound to `br-lan.80`)
4. **Wireless Security**:
   - **Encryption**: `WPA2-PSK` (recommended for max legacy IoT compatibility) or `WPA2-PSK/WPA3-SAE Mixed Mode`
   - **Key**: Set a strong, secure passphrase.
5. Click **Save** $\rightarrow$ **Save & Apply**.

### UCI Command Line:
```bash
# Add Wireless Network on 2.4GHz Radio (radio0)
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Home-IoT'
uci set wireless.@wifi-iface[-1].network='iot'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='YOUR_STRONG_IOT_WIFI_PASSWORD'

uci commit wireless
wifi reload
```

> [!TIP]
> **Compatibility Note**: Many cheap 2.4GHz IoT microcontrollers (ESP8266, Tuya chips) do not support 5GHz radios or WPA3 security. Keeping a dedicated 2.4GHz SSID with standard WPA2-PSK ensures 100% device compatibility.

---

## Step 5: Ethernet Switch Port Trunking & External Access Points

If you use external access points (e.g. OpenWrt Dumb APs, UniFi, TP-Link Omada) or managed switches, you must pass VLAN 80 as **Tagged** over your Ethernet trunk ports.

```
[OpenWrt Router] ──(Trunk Port: VLAN 1 Untagged, VLAN 80 Tagged)──> [Managed Switch / Dumb AP]
                                                                        ├── SSID: Home-LAN (VLAN 1)
                                                                        └── SSID: Home-IoT (VLAN 80)
```

### Tagging Ethernet Ports on OpenWrt (DSA)

To send tagged VLAN 80 frames down physical port `lan1`:

```bash
# Add tagged VLAN 80 to port lan1
uci del_list network.@bridge-vlan[0].ports='lan1'     # Remove untagged lan1 from default bridge vlan
uci add_list network.@bridge-vlan[0].ports='lan1:u'   # VLAN 1 Untagged (Native) on lan1
uci add_list network.@bridge-vlan[1].ports='lan1:t'   # VLAN 80 Tagged on lan1

uci commit network
/etc/init.d/network restart
```

> [!NOTE]
> For complete instructions on setting up roaming and VLAN trunking on secondary OpenWrt APs, refer to [`dumb_ap_roaming_guide.md`](file:///home/arukast/Projects/openwrt/dumb_ap_roaming_guide.md).

---

## Step 6: Cross-VLAN Service Discovery (mDNS Reflector)

By default, mDNS (multicast DNS / Bonjour) traffic on UDP port 5353 does not cross VLAN boundaries. Without an mDNS reflector, smart home apps on your Main LAN will fail to auto-discover Apple TV/HomeKit, Google Chromecast, Sonos, or AirPlay devices on the IoT VLAN.

### Option 1: Lightweight Micro mDNS Daemon (`umdns`) - Recommended for OpenWrt

OpenWrt includes `umdns`, a lightweight native mDNS reflector daemon.

```bash
# Install umdns
opkg update
opkg install umdns

# Enable umdns on both lan and iot interfaces
uci set umdns.lan=listen
uci set umdns.lan.interface='lan'

uci set umdns.iot=listen
uci set umdns.iot.interface='iot'

uci commit umdns
/etc/init.d/umdns enable
/etc/init.d/umdns start
```

### Option 2: Avahi Daemon (`avahi-daemon-service-ssh`)

If your network relies on complex mDNS filtering or Sonos discovery:

```bash
# Install Avahi
opkg update
opkg install avahi-daemon-service-ssh dbus

# Enable reflector mode in /etc/avahi/avahi-daemon.conf
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf

/etc/init.d/dbus enable
/etc/init.d/dbus start
/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon start
```

### Add Firewall Rule for mDNS Multicast Traffic

Allow mDNS multicast traffic (UDP 5353) to be received on router interfaces:

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-mDNS-Multicast'
uci set firewall.@rule[-1].src='*'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_ip='224.0.0.251'
uci set firewall.@rule[-1].dest_port='5353'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

---

## Step 7: Security Audit & Verification Checklist

Follow this checklist to verify that your IoT isolation policy is active and working correctly.

### 1. Verify IP Assignment & Gateway
Connect a client device to the `Home-IoT` Wi-Fi SSID or a tagged VLAN 80 port.
- [ ] Ensure the device receives an IP in the `192.168.80.X` subnet.
- [ ] Confirm gateway IP is `192.168.80.1` and DNS IP is `192.168.80.1`.

### 2. Isolation Verification Tests

Run the following test commands from a device on the **IoT VLAN** (`192.168.80.X`):

```bash
# 1. Internet Reachability Test (Should SUCCEED)
ping -c 3 1.1.1.1

# 2. LAN Subnet Isolation Test (Should FAIL / Timeout)
ping -c 3 192.168.1.100

# 3. Router Management Port Access Test (Should FAIL / Refuse Connection)
nc -zvw3 192.168.80.1 22
nc -zvw3 192.168.80.1 80
nc -zvw3 192.168.80.1 443
```

Run the following test command from a device on the **Main LAN** (`192.168.1.X`):

```bash
# LAN to IoT Stateful Reachability Test (Should SUCCEED)
ping -c 3 192.168.80.105
```

### 3. mDNS Service Discovery Test

From a smartphone or desktop on the **Main LAN**:
- [ ] Open the Home Assistant app or a Bonjour scanner app (e.g. Discovery DNS-SD browser).
- [ ] Verify that Chromecast, AirPlay, and ESPHome devices on the IoT VLAN are automatically discovered.

---

## Appendix: Complete `/etc/config` Block Snippets

### `/etc/config/network`
```ini
config device 'br_lan'
    option name 'br-lan'
    option type 'bridge'
    list ports 'lan1'
    list ports 'lan2'
    list ports 'lan3'
    list ports 'lan4'
    option vlan_filtering '1'

config bridge-vlan
    option device 'br-lan'
    option vlan '80'
    list ports 'lan1:t'

config interface 'iot'
    option proto 'static'
    option device 'br-lan.80'
    option ipaddr '192.168.80.1'
    option netmask '255.255.255.0'
```

### `/etc/config/firewall`
```ini
config zone
    option name 'iot_zone'
    list network 'iot'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'

config forwarding
    option src 'iot_zone'
    option dest 'wan'

config forwarding
    option src 'lan'
    option dest 'iot_zone'

config rule
    option name 'Allow-IoT-DHCP'
    option src 'iot_zone'
    option proto 'udp'
    option src_port '67-68'
    option dest_port '67-68'
    option target 'ACCEPT'

config rule
    option name 'Allow-IoT-DNS'
    option src 'iot_zone'
    option proto 'tcpudp'
    option dest_port '53'
    option target 'ACCEPT'

config rule
    option name 'Block-IoT-Router-Admin'
    option src 'iot_zone'
    option dest 'lan'
    option dest_port '22 80 443 23'
    option target 'REJECT'
```
