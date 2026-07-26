# OpenWrt IP Addressing Guide: Static IP vs. DHCP Configuration

## 1. Overview of Addressing Concepts

Network IP addressing in an OpenWrt environment falls into three distinct implementation methods. Choosing the correct method depends on whether you are configuring an OpenWrt interface or a connected client device.

### A. Dynamic DHCP (Dynamic Host Configuration Protocol)
* **Definition:** OpenWrt automatically assigns an IP address, netmask, default gateway, and DNS servers to a device from a pre-configured pool for a specific duration (lease time).
* **Behavior:** The IP address assigned to a device may change over time, upon device restart, or after router reboots.
* **Best Used For:** Mobile devices, guest connections, and client hardware that does not host local network services.

### B. Static DHCP Reservation (OpenWrt Static Lease)
* **Definition:** The client device remains in DHCP mode, requesting its IP automatically. OpenWrt inspects the device hardware MAC address and matches it against a local reservation table to always issue the exact same IP address.
* **Behavior:** The device receives a fixed, permanent IP address while retaining dynamic network management.
* **Best Used For:** Most IoT devices, smart home hubs, IP cameras, NVRs, local servers, NAS units, and network printers.

### C. Manual Static IP (Device-Side Assignment)
* **Definition:** The IP address, subnet mask, gateway, and DNS server details are manually configured directly within the operating system or network settings of the target device.
* **Behavior:** The device bypasses DHCP requests completely.
* **Best Used For:** Core infrastructure hardware, bare-metal hypervisors (Proxmox, ESXi), and primary network switches.

---

## 2. OpenWrt Router Interface Protocol Selection

Network interfaces configured in OpenWrt (`/etc/config/network`) specify how the router interacts with upstream networks (WAN) and downstream local segments (LAN/VLANs).

### A. WAN Interface (Upstream / Internet)

| Protocol Mode | When to Select | Requirements & Notes |
| :--- | :--- | :--- |
| **DHCP Client (`proto 'dhcp'`)** | Standard home fiber/cable modems, LTE/5G gateways, or OpenWrt operating behind an ISP router (Double-NAT). | Default mode. The upstream ISP modem dynamically provides the public/WAN IP, gateway, and DNS servers. |
| **Static Address (`proto 'static'`)** | Business internet connections with a dedicated static public IPv4 address block. | Requires explicit configuration of IP Address, Subnet Mask, Gateway, and DNS servers provided by your ISP. |
| **PPPoE (`proto 'pppoe'`)** | Fiber to the home (FTTH) or DSL connections using point-to-point authentication over Ethernet. | Requires ISP authentication credentials (Username and Password). |

#### Configuration Examples for WAN:

**LuCI Web Interface:**
1. Navigate to **Network -> Interfaces**.
2. Click **Edit** next to **WAN**.
3. Under **Protocol**, select **DHCP client** (or **Static address**).
4. Save and Apply.

**UCI Configuration (`/etc/config/network`):**
```ini
# Standard WAN using DHCP
config interface 'wan'
    option device 'eth1'
    option proto 'dhcp'

# WAN using Static IP (Static Public IP from ISP)
config interface 'wan_static'
    option device 'eth1'
    option proto 'static'
    option ipaddr '203.0.113.45'
    option netmask '255.255.255.248'
    option gateway '203.0.113.41'
    list dns '1.1.1.1'
    list dns '8.8.8.8'
```

---

### B. LAN and VLAN Interfaces (Downstream / Local Networks)

| Interface Type | Protocol Mode | Reason |
| :--- | :--- | :--- |
| **Primary LAN (`br-lan`)** | Static Address | OpenWrt must have a fixed local IP (e.g. `192.168.1.1`) to serve as default gateway and DNS for local clients. |
| **IoT VLAN (`br-lan.80`)** | Static Address | OpenWrt gateway IP must remain fixed (e.g. `192.168.80.1`) for firewall routing and local device communication. |
| **Guest VLAN (`br-lan.90`)** | Static Address | Required to route isolated guest traffic and host local DHCP/DNS services. |
| **Dumb AP Mode** | Static Address or DHCP | If OpenWrt acts purely as a Wireless Access Point, it can use DHCP from the main router or a fixed static IP management address. |

#### Configuration Examples for Local Interfaces:

**UCI Configuration (`/etc/config/network`):**
```ini
config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.1.1'
    option netmask '255.255.255.0'

config interface 'iot'
    option device 'br-lan.80'
    option proto 'static'
    option ipaddr '192.168.80.1'
    option netmask '255.255.255.0'
```

---

## 3. Client Device IP Assignment Strategy

Connecting devices require different IP assignment strategies based on their role, reliability needs, and connectivity requirements.

### Category 1: Static DHCP Reservations (OpenWrt MAC Reservation)

This is the recommended strategy for almost all fixed hardware and IoT devices.

#### Applicable Devices:
* **Smart Home Controllers:** Home Assistant, Homebridge, Hubitat, Zigbee/Z-Wave gateways.
* **Surveillance Hardware:** IP Cameras, Doorbell cameras, NVRs (Shinobi, Frigate, Reolink NVR).
* **Storage & Servers:** NAS units (Synology, Unraid, TrueNAS), local web servers, media servers (Plex, Jellyfin).
* **DNS Sinks & Network Services:** AdGuard Home, Pi-hole, local NTP/Time servers.
* **Hardware Printers:** Network attached multi-function printers.
* **IoT Hardware:** Smart plugs, smart switches, LED controllers, ESP32/ESP8266 devices, Tuya/Tasmota devices.

#### Advantages of Static DHCP Reservations:
1. **Centralized Administration:** All IP assignments are stored in OpenWrt (`/etc/config/dhcp`). Changing network subnets requires modifying one router file instead of reconfiguring dozens of individual devices.
2. **Prevents Connectivity Failures:** Applications like Home Assistant, RTSP video streams, and NVRs rely on static IP paths. Dynamic IP changes break these connections.
3. **Resilience to Factory Resets:** Cheap IoT hardware that loses settings or undergoes firmware updates will automatically receive its assigned IP upon reconnecting.
4. **Eliminates IP Collisions:** OpenWrt tracks reserved IPs and excludes them from dynamic pool distribution.

---

### Category 2: Dynamic DHCP

Recommended for devices where mobility, plug-and-play setup, or temporary connectivity is required.

#### Applicable Devices:
* **Mobile Devices:** Smartphones, tablets, smartwatches.
* **Client Computers:** Laptops, desktop PCs, workstation clients.
* **Transient & Guest Hardware:** Visitor devices, temporary testing hardware, game consoles.
* **Cloud-Only IoT:** Smart bulbs or simple sensors that only send outbound telemetry to external cloud servers and do not accept local incoming connections.

#### Advantages of Dynamic DHCP:
1. **Zero Configuration:** Devices connect and function without manual setup.
2. **Subnet Independence:** Devices easily move between home networks, guest networks, and external Wi-Fi networks.
3. **Efficient Address Reuse:** Unused IP addresses return to the pool when leases expire.

---

### Category 3: Manual Device-Side Static IP

Configuring static IP credentials directly inside the client operating system.

#### Applicable Devices:
* **Bare-metal Hypervisors:** Proxmox VE, VMware ESXi, bare-metal Linux servers.
* **Core Network Hardware:** Out-of-band management cards (iDRAC, IPMI), main managed switches.

#### Considerations:
* Manual static IPs must be set **outside** the active DHCP start/limit pool range in OpenWrt to avoid duplicate IP assignment errors.
* Example: If OpenWrt DHCP pool is `192.168.1.100` to `192.168.1.249`, set manual static IPs in the range `192.168.1.2` to `192.168.1.99`.

---

## 4. OpenWrt Implementation Guide

### A. Configuring a DHCP Server on a Subnet

To serve dynamic IP addresses on a network interface:

1. In LuCI, navigate to **Network -> Interfaces**.
2. Click **Edit** on the target interface (e.g. `IOT`).
3. Select the **DHCP Server** tab at the bottom.
4. If not configured, click **Setup DHCP Server**.
5. Configure pool boundary parameters:
   * **Start:** `100` (First leased IP, e.g. `192.168.80.100`)
   * **Limit:** `150` (Pool size, leasing up to `.249`)
   * **Lease time:** `12h` (Lease duration)
6. Save and Apply.

**UCI Configuration (`/etc/config/dhcp`):**
```ini
config dhcp 'iot'
    option interface 'iot'
    option start '100'
    option limit '150'
    option leasetime '12h'
```

---

### B. Creating Static DHCP Reservations (Static Leases)

To ensure a specific device always receives the same IP address:

1. In LuCI, navigate to **Network -> DHCP and DNS**.
2. Scroll to the **Static Leases** section at the bottom.
3. Click **Add**.
4. Fill in the required fields:
   * **Hostname:** Device identifier (e.g. `nvr-camera-01`)
   * **MAC Address:** Hardware address of the client device (e.g. `00:11:22:33:44:55`)
   * **IPv4 Address:** Reserved IP address (e.g. `192.168.80.50`)
5. Click **Save & Apply**.

**UCI Configuration (`/etc/config/dhcp`):**
```ini
config host
    option name 'nvr-camera-01'
    option mac '00:11:22:33:44:55'
    option ip '192.168.80.50'
    option leasetime 'infinite'
```

---

## 5. Troubleshooting Common IP Addressing Issues

### A. IP Address Conflict (Duplicate IP)
* **Symptom:** Flaky network connectivity, dropped packets, or devices disconnecting intermittently.
* **Cause:** A device was configured with a manual static IP that falls within the active DHCP pool, and OpenWrt leased the same IP to another device.
* **Resolution:** Ensure all manual static IPs are strictly outside the DHCP pool range (e.g. use `.2` through `.99` for static reservations, and `.100` through `.249` for dynamic DHCP).

### B. Subnet Mismatch
* **Symptom:** Device has a static IP but cannot access the router or internet.
* **Cause:** The device static IP subnet (e.g. `192.168.1.50`) does not match the OpenWrt gateway interface subnet (e.g. `192.168.80.1`).
* **Resolution:** Reconfigure the device IP to match the exact subnet of its assigned VLAN interface, or switch the device back to DHCP with an OpenWrt Static Lease.

### C. Offline Devices After Router Replacement
* **Symptom:** IoT devices with manual static IPs become unreachable after installing a new OpenWrt router.
* **Cause:** The default gateway or DNS IP address configured on the device points to an old router IP.
* **Resolution:** Standardize on OpenWrt Static DHCP Leases so the router automatically distributes updated gateway and DNS parameters to all devices.

---

## 6. Comprehensive Summary Matrix

| Device / Interface Role | Addressing Method | Managed Where | Primary Benefit |
| :--- | :--- | :--- | :--- |
| **OpenWrt WAN (Standard ISP)** | DHCP Client | OpenWrt Interface | Automatically retrieves public IP and ISP routes. |
| **OpenWrt WAN (Static Subscription)** | Static Address | OpenWrt Interface | Explicit configuration for dedicated business IPs. |
| **OpenWrt LAN / VLAN Gateway** | Static Address | OpenWrt Interface | Ensures a fixed default gateway IP for internal subnets. |
| **Home Assistant / NVR / NAS** | Static DHCP Lease | OpenWrt DHCP Table | Unchanging IP for local access without complex manual OS edits. |
| **IP Cameras / Smart Plugs** | Static DHCP Lease | OpenWrt DHCP Table | Prevents RTSP and API stream disconnections after reboot. |
| **Smartphones / Laptops / Guests** | Dynamic DHCP | OpenWrt DHCP Pool | Plug-and-play connectivity across multiple network locations. |
| **Proxmox / Hypervisor Hosts** | Manual Static IP | Client Hardware OS | Maintains host management access even when OpenWrt is offline. |
