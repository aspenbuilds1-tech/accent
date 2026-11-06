# Private Personal VPN (WireGuard)

A self-hosted VPN that you own end to end: your own server, your own keys, no third-party VPN company in the middle. One script (`wg-vpn.sh`) installs the server and manages your devices.

## Why WireGuard

| Option | Verdict for personal use |
|---|---|
| **WireGuard (self-hosted)** ✅ | Fast, about 4k lines of auditable code, modern crypto (Curve25519, ChaCha20-Poly1305), official apps for iOS, Android, macOS, Windows and Linux. You hold all the keys. |
| OpenVPN | Works, but it's slower and heavier, with a bigger attack surface and more complex config. Mainly worth it for legacy or enterprise compatibility. |
| Tailscale / Headscale | Built on WireGuard and easiest for a *mesh* between your own devices. Hosted Tailscale uses a third-party coordination server. Good if you mostly want to reach your home network rather than send all your traffic through a server you control. |

## What a self-hosted VPN does and doesn't do

**It protects you on** public or hotel Wi-Fi, hides your browsing from your ISP or the local network, gives you a stable IP you control, and lets you reach your server's private services.

**It does not make you anonymous.** Your traffic leaves from a VPS that is rented in your name. To the websites you visit, you look like "a person on that VPS's IP". For anonymity, use Tor. A VPN also doesn't replace HTTPS or keeping your devices secure.

## 1. Get a server (about $4–6/month)

Any small Linux VPS works: 1 vCPU and 512 MB–1 GB RAM is plenty. Examples are Hetzner, DigitalOcean, Vultr, Linode/Akamai and the Oracle Cloud free tier. Pick:

- **OS:** Ubuntu 24.04 LTS (22.04, 26.04 and Debian 12 also work)
- **Region:** close to you for speed, or in the country whose IP you want
- **Auth:** an SSH key (not a password)

In the provider's **cloud firewall**, allow inbound **UDP 51820** (and TCP 22 for SSH).

## 2. Install the server

```bash
ssh root@YOUR_SERVER_IP
curl -fsSLO https://raw.githubusercontent.com/aspenbuilds1-tech/accent/main/vpn/wg-vpn.sh
# (or scp vpn/wg-vpn.sh to the server)
less wg-vpn.sh          # read it before running anything as root
chmod +x wg-vpn.sh
./wg-vpn.sh install
```

The installer:
- installs `wireguard`, `qrencode` and `unattended-upgrades` (automatic security patches)
- generates the server keypair (stored with `0600` permissions in `/etc/wireguard`)
- sets up dual-stack tunnel addresses (`10.66.66.0/24` and `fd42:66:66::/64`)
- enables IP forwarding and NAT, with rules tied to the interface so they disappear cleanly when it goes down
- opens the port in UFW if UFW is active, and starts `wg-quick@wg0` on boot

Optional settings, passed as environment variables before `install`:

```bash
WG_PORT=443 WG_DNS="9.9.9.9, 149.112.112.112" WG_ENDPOINT=vpn.mydomain.com ./wg-vpn.sh install
```

## 3. Add your devices

```bash
./wg-vpn.sh add phone      # prints config + QR code
./wg-vpn.sh add laptop
./wg-vpn.sh list           # see clients + last handshake
./wg-vpn.sh show phone     # re-print QR/config
./wg-vpn.sh remove laptop  # revoke a lost/old device instantly
```

Use **one client per device**. Never share a config between two devices.

- **iPhone / Android:** install the official *WireGuard* app, tap **+**, choose **Scan QR code**, and scan the code from your terminal.
- **macOS / Windows:** install WireGuard from wireguard.com/install, then **Import tunnel from file**. Copy the file with `scp root@SERVER:/etc/wireguard/clients/laptop.conf .`
- **Linux:** `sudo cp laptop.conf /etc/wireguard/wg0.conf && sudo wg-quick up wg0`

Delete the downloaded `.conf` from your computer after you import it, because it contains that device's private key.

## 4. Verify it works

1. Connect, then visit an IP-check site. It should show your **server's** IP.
2. Run a DNS leak test (e.g. dnsleaktest.com, extended test). It should list only the DNS provider you chose (Cloudflare by default).
3. Run an IPv6 leak test (e.g. test-ipv6.com). Clients send *all* IPv6 into the tunnel (`::/0`). If your VPS has no IPv6, IPv6 just fails instead of leaking around the VPN.
4. On the server, `./wg-vpn.sh list` should show a recent handshake.

**Kill switch:** in the desktop apps, turn on *Block untunneled traffic*. On iOS, turn on *On-Demand*. On Android, go to Settings → VPN → WireGuard and turn on *Always-on VPN* and *Block connections without VPN*.

## Hardening checklist

- [ ] SSH: key-only login. In `/etc/ssh/sshd_config` set `PasswordAuthentication no` and `PermitRootLogin prohibit-password`.
- [ ] Firewall: allow only `22/tcp` and `51820/udp` inbound, both in UFW and in the cloud firewall.
- [ ] Automatic updates: `unattended-upgrades` is enabled by the installer.
- [ ] Revoke lost devices right away with `./wg-vpn.sh remove <name>`.
- [ ] Optional: `apt install fail2ban` for SSH brute-force protection.
- [ ] Optional: ad and tracker blocking by running AdGuard Home or Pi-hole on the server, then setting `WG_DNS=10.66.66.1`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No handshake | UDP port blocked. Check the cloud firewall and `ufw status`. Some networks block UDP 51820, so reinstall with `WG_PORT=443`. |
| Handshake but no internet | Check `sysctl net.ipv4.ip_forward` (should be 1) and `iptables -t nat -L POSTROUTING` (MASQUERADE rule present). The public interface name may be wrong; reinstall with `WG_PUBLIC_IF=ens3`. |
| Sites slow or not loading | Probably an MTU problem. Add `MTU = 1380` under `[Interface]` in the client config. |
| Conflicts with a local network | Reinstall with `WG_SUBNET4=10.77.77`. |

## Uninstall

```bash
./wg-vpn.sh uninstall
```
