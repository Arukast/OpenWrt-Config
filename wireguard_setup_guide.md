# Production-Grade WireGuard over IPv6 with WG-Easy & OpenWrt Synchronization

This guide provides a comprehensive deployment blueprint and troubleshooting manual for configuring a high-performance, secure **WireGuard over IPv6 VPN** terminating natively on an **OpenWrt Router**, managed via a **WG-Easy (Docker)** dashboard hosted on a **Proxmox LXC Container**, with real-time bidirectional peer synchronization.

---

## 🏗️ Architecture Overview

```
                        [Remote Client (Phone/Laptop)]
                                      │
                         (Direct IPv6 UDP Port 51820)
                                      ▼
                        [OpenWrt Router (Terminates VPN)]
                                      │
                      ┌───────────────┴───────────────┐
                      ▼                               ▼
              [Home Local LAN]               [Secure DNS over HTTPS]
                      │                               │
            (Real-Time Sync SSH)             (Cloudflare / Quad9)
                      ▼
       [Proxmox LXC Host (WG-Easy Manager)]
```

### Key Design Decisions
1. **Direct IPv6 Terminations**: Avoids IPv4 CGNAT bottlenecks by routing directly via native global IPv6.
2. **Sovereign Gateway Control**: Terminating WireGuard on the router guarantees 24/7 VPN uptime, even if the Proxmox homelab is offline.
3. **Decoupled GUI Management**: Uses WG-Easy inside Proxmox for a modern GUI, but translates peers into native OpenWrt UCI commands in under 1 second.
4. **Encrypted DNS Routing**: Bypasses local ISP hijacking by routing all DNS queries through a local DNS over HTTPS (DoH) proxy.

---

## 🛠️ Step 1: OpenWrt Router Configuration

Add the following section to your `/etc/config/network` and `/etc/config/firewall` configurations, or utilize an automated installation script (`setup.conf`).

### 1. Network Interface Configuration (`/etc/config/network`)
```ini
config interface 'wg0'
    option proto 'wireguard'
    option private_key 'YOUR_SERVER_PRIVATE_KEY'
    option listen_port '51820'
    option mtu '1280'
    list addresses '10.8.0.1/24'
    list addresses 'fd11:2233:4455::1/64'
```

### 2. Firewall Zone and Port Configuration (`/etc/config/firewall`)
```ini
config zone
    option name 'wg'
    option input 'ACCEPT'
    option forward 'ACCEPT'
    option output 'ACCEPT'
    option masq '1'
    option mtu_fix '1'
    list network 'wg0'

config forwarding
    option src 'wg'
    option dest 'lan'

config forwarding
    option src 'lan'
    option dest 'wg'

config forwarding
    option src 'wg'
    option dest 'wan'

# Open WAN UDP Port 51820 on IPv6
config rule
    option name 'Allow-WireGuard-IPv6'
    option src 'wan'
    option family 'ipv6'
    option proto 'udp'
    option dest_port '51820'
    option target 'ACCEPT'
```

### 3. DuckDNS Dynamic IP Update (`/etc/config/ddns`)
Since residential IPv6 prefixes are dynamic, configure the DDNS updater to track your router's WAN IPv6 using a secure web lookup.
```ini
config service 'duckdns'
    option enabled '1'
    option lookup_host 'yourdomain.duckdns.org'
    option domain 'yourdomain.duckdns.org'
    option username 'yourdomain'  # DO NOT set to 'none' as it breaks url expansion
    option password 'your-duckdns-token'
    option update_url 'http://www.duckdns.org/update?domains=[USERNAME]&token=[PASSWORD]&ipv6=[IP]'
    option use_ipv6 '1'
    option ip_source 'web'
    option ip_url 'http://v6.ident.me'
    option check_interval '10'
    option check_unit 'minutes'
```

---

## 🔄 Step 2: Proxmox LXC Container Sync Setup

Deploy WG-Easy inside a lightweight Debian/Ubuntu LXC container with Docker installed.

### 1. WG-Easy Compose Config (`/opt/wgeasy/docker-compose.yml`)
```yaml
version: '3.8'
services:
  wg-easy:
    environment:
      - WG_HOST=yourdomain.duckdns.org
      - WG_PORT=51820
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=10.8.0.1,fd11:2233:4455::1
      - WG_ALLOWED_IPS=10.8.0.0/24, fd11:2233:4455::/64, 192.168.11.0/24
      - PASSWORD_HASH=$$2a$$12$$YOUR_BCRYPT_SECURE_PASSWORD_HASH
      - WG_MTU=1280
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    volumes:
      - /opt/wgeasy/config:/etc/wireguard
    ports:
      - "51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

### 2. Real-Time Peer Sync Script (`/opt/wgeasy/sync_peers.sh`)
This script executes inside the LXC container. It monitors `wg0.conf` for modifications and translates the peers **including Preshared Keys (PSK) and the Server PrivateKey** directly to the router's UCI memory.

```bash
#!/bin/bash
# =============================================================================
#  VPN Config Sync Script (Model A)
#  Translates WG-Easy peers to OpenWrt router UCI parameters
# =============================================================================

ROUTER_IP="192.168.11.1" # Change to your Router's private LAN IP
WG_CONF="/opt/wgeasy/config/wg0.conf"
TMP_SCRIPT="/tmp/apply_wg_peers.sh"

if [ ! -f "$WG_CONF" ]; then
    echo "[ERR] WireGuard configuration $WG_CONF not found!"
    exit 1
fi

echo "[INFO] Parsing WG-Easy configurations..."

# Create clean temporary script to execute on the router
cat > "$TMP_SCRIPT" << 'EOF'
#!/bin/sh
log_info() { echo "[INFO]  $1"; }
run_uci() { uci "$@"; }

# 1. Wipe out existing peer configs on the router to maintain idempotency
log_info "Cleaning up existing peer registrations..."
while uci -q get network.@wireguard_wg0[0] >/dev/null 2>&1; do
    run_uci -q delete network.@wireguard_wg0[0]
done
EOF

# Parse the wg0.conf using an ultra-robust awk-based state machine
# - Handles both CRLF (\r\n) and LF (\n) line endings
# - Performs clean trim of leading/trailing whitespace
# - Automatically extracts the Server PrivateKey from [Interface] to match the router's key
# - Automatically extracts and syncs PresharedKeys (PSK) for post-quantum security
# - Automatically strips trailing UUIDs from peer descriptions
# - Seamlessly flushes peer sections without relying on specific empty line placement
awk '
  BEGIN {
      in_peer = 0;
      pubkey = "";
      presharedkey = "";
      desc = "";
      ips = "";
  }
  {
      gsub(/\r/, "");
      line = $0;
      gsub(/^[ \t]+|[ \t]+$/, "", line);
  }
  !in_peer && line ~ /^[Pp][Rr][Ii][Vv][Aa][Tt][Ee][Kk][Ee][Yy][ \t]*=/ {
      privkey = line;
      sub(/^[Pp][Rr][Ii][Vv][Aa][Tt][Ee][Kk][Ee][Yy][ \t]*=[ \t]*/, "", privkey);
      gsub(/^[ \t]+|[ \t]+$/, "", privkey);
      if (privkey != "") {
          printf "log_info \"Syncing server PrivateKey to match WG-Easy...\"\n"
          printf "run_uci set network.wg0.private_key=\"%s\"\n", privkey
      }
      next;
  }
  line ~ /^#[ \t]*(Name|Peer|Client|Description):/ {
      d = line;
      sub(/^#[ \t]*(Name|Peer|Client|Description):[ \t]*/, "", d);
      sub(/[ \t]*\([a-fA-F0-9-][a-fA-F0-9-]*\)/, "", d); # Strip UUIDs like (2e983822...)
      gsub(/^[ \t]+|[ \t]+$/, "", d);
      desc = d;
      next;
  }
  line ~ /^#[ \t]+/ {
      if (desc == "") {
          d = line;
          sub(/^#[ \t]*/, "", d);
          gsub(/^[ \t]+|[ \t]+$/, "", d);
          if (d != "" && d != "Peer" && d != "Client") {
              desc = d;
          }
      }
      next;
  }
  line ~ /^\[[Pp][Ee][Ee][Rr]\]/ {
      if (in_peer) {
          flush_peer();
      }
      in_peer = 1;
      pubkey = "";
      presharedkey = "";
      ips = "";
      next;
  }
  in_peer && line ~ /^[Pp][Uu][Bb][Ll][Ii][Cc][Kk][Ee][Yy][ \t]*=/ {
      p = line;
      sub(/^[Pp][Uu][Bb][Ll][Ii][Cc][Kk][Ee][Yy][ \t]*=[ \t]*/, "", p);
      gsub(/^[ \t]+|[ \t]+$/, "", p);
      pubkey = p;
      next;
  }
  in_peer && line ~ /^[Pp][Rr][Ee][Ss][Hh][Aa][Rr][Ee][Dd][Kk][Ee][Yy][ \t]*=/ {
      psk = line;
      sub(/^[Pp][Rr][Ee][Ss][Hh][Aa][Rr][Ee][Dd][Kk][Ee][Yy][ \t]*=[ \t]*/, "", psk);
      gsub(/^[ \t]+|[ \t]+$/, "", psk);
      presharedkey = psk;
      next;
  }
  in_peer && line ~ /^[Aa][Ll][Ll][Oo][Ww][Ee][Dd][Ii][Pp][Ss][ \t]*=/ {
      i = line;
      sub(/^[Aa][Ll][Ll][Oo][Ww][Ee][Dd][Ii][Pp][Ss][ \t]*=[ \t]*/, "", i);
      gsub(/^[ \t]+|[ \t]+$/, "", i);
      ips = i;
      next;
  }
  function flush_peer() {
      if (pubkey != "") {
          if (desc == "") {
              desc = "Peer_" substr(pubkey, 1, 8);
          }
          printf "log_info \"Adding peer: %s\"\n", desc
          printf "run_uci add network wireguard_wg0\n"
          printf "run_uci set network.@wireguard_wg0[-1].public_key=\"%s\"\n", pubkey
          if (presharedkey != "") {
              printf "run_uci set network.@wireguard_wg0[-1].preshared_key=\"%s\"\n", presharedkey
          }
          printf "run_uci set network.@wireguard_wg0[-1].description=\"%s\"\n", desc
          n = split(ips, arr, ",")
          for (k=1; k<=n; k++) {
              gsub(/^[ \t]+|[ \t]+$/, "", arr[k])
              if (arr[k] != "") {
                  printf "run_uci add_list network.@wireguard_wg0[-1].allowed_ips=\"%s\"\n", arr[k]
              }
          }
      }
      pubkey = "";
      presharedkey = "";
      desc = "";
      ips = "";
      in_peer = 0;
  }
  END {
      if (in_peer) {
          flush_peer();
      }
  }
' "$WG_CONF" >> "$TMP_SCRIPT"

# Append reload, commit, and interface up commands to trigger kernel hot-reload
cat >> "$TMP_SCRIPT" << 'EOF'
run_uci commit network
/etc/init.d/network reload
ifup wg0
log_info "Network reloaded successfully. VPN peers synchronized."
EOF

# Push and execute securely over SSH (uses passwordless SSH key pair configured on LXC root)
scp -O -q "$TMP_SCRIPT" root@$ROUTER_IP:/tmp/apply_wg_peers.sh
ssh root@$ROUTER_IP "sh /tmp/apply_wg_peers.sh && rm -f /tmp/apply_wg_peers.sh"
rm -f "$TMP_SCRIPT"
echo "[OK] Router peers synchronized successfully."
```

### 3. File Watcher Event Daemon (`/opt/wgeasy/daemon_watcher.sh`)
This background service uses `inotifywait` to trigger `sync_peers.sh` the exact millisecond `wg0.conf` is written (when clicking "Create Peer" or "Delete Peer" on the GUI dashboard).

```bash
#!/bin/bash
WATCH_FILE="/opt/wgeasy/config/wg0.conf"
SYNC_SCRIPT="/opt/wgeasy/sync_peers.sh"

echo "[INFO] Starting Real-time VPN Config Sync Daemon..."
echo "[INFO] Monitoring modifications on $WATCH_FILE..."

while [ ! -f "$WATCH_FILE" ]; do
    sleep 2
done

# Run initial sync on boot
$SYNC_SCRIPT

# Watch for write/close events and trigger sync
inotifywait -m -e close_write "$WATCH_FILE" | while read -r directory events filename; do
    echo "[EVENT] $filename modified. Triggering instant sync..."
    $SYNC_SCRIPT
done
```

### 4. Systemd Service Config (`/etc/systemd/system/wg-sync.service`)
Configure a background service to ensure the file watcher daemon runs permanently in the background and starts automatically when the LXC container boots:

```ini
[Unit]
Description=WireGuard Peer Sync Event Daemon
After=docker.service

[Service]
Type=simple
ExecStart=/opt/wgeasy/daemon_watcher.sh
WorkingDirectory=/opt/wgeasy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

To enable and run the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wg-sync.service
```

---

## 🛠️ Step 3: Hardening & Resolving DNS Conflicts

When deploying custom configurations on gateway routers, two highly critical DNS issues commonly emerge. Below is how to diagnose and resolve them.

### 1. Bypassing Tailscale MagicDNS Hijacking
By default, when enabling Tailscale on an OpenWrt router or an Arch Linux PC client, **Tailscale's MagicDNS overrides the system resolvers**. 
* **The Problem**: Tailscale forces all queries to route through `100.100.100.100`, bypassing your local DNS over HTTPS (DoH) proxy and serving heavily cached/stale records.
* **The Solution**: Force Tailscale to ignore DNS configuration while keeping your connections and routing intact.

* **On the Router Gateway (e.g., OpenWrt)**:
  ```bash
  # DO NOT use --reset on your router as it clears your --advertise-routes settings!
  tailscale up --accept-dns=false --advertise-routes=192.168.11.0/24 --accept-routes
  /etc/init.d/dnsmasq restart
  ```
* **On Client Devices (e.g., Arch Linux / Ubuntu)**:
  ```bash
  sudo tailscale up --accept-dns=false --accept-routes=true --reset
  ```

### 2. Resolving Router DNS Interception (`force_dns`)
If your secondary router (like `AltWrt`) uses a band steering, adblock, or DoH client proxy, it likely has a rule called **`force_dns`** enabled.
* **The Problem**: `force_dns` intercepts **all** outgoing standard UDP port 53 and port 853 traffic from the LAN and forces it into the local `dnsmasq` pool. Even if you query `8.8.8.8` manually, the router intercepts it and answers with its own cached records!
* **The Solution**: 
  1. Bypass interception immediately on clients by using **DNS over HTTPS (DoH)** in your browser or utilizing encrypted JSON queries in your scripts:
     ```bash
     curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=yourdomain.duckdns.org&type=AAAA'
     ```
  2. Or, temporarily map the correct IP inside your Arch Linux client `/etc/hosts` file to completely bypass DNS resolution for the endpoint while waiting for the router's resolver cache to expire:
     ```text
     # Add at the bottom of /etc/hosts
     YOUR_ROUTER_PUBLIC_IPV6_ADDRESS  yourdomain.duckdns.org
     ```

---

## 📊 Verification & Diagnostics

Once deployed, run these diagnostic assertions:

1. **Verify handshake on Router**:
   ```bash
   wg show
   ```
   * Ensure `transfer: ... received, ... sent` is populated and `latest handshake` is active.
   * Verify that `preshared key: (hidden)` appears under the peer, proving the PSK successfully synced.

2. **Verify DoH on Router**:
   ```bash
   nslookup google.com
   ```
   * Server must resolve through the local resolver loop (`::1` or `127.0.0.1`), demonstrating that standard WAN DNS is completely ignored.
