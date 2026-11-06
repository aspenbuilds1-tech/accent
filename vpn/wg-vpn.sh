#!/usr/bin/env bash
# wg-vpn.sh — personal WireGuard VPN server manager
#
# Usage (as root on an Ubuntu 22.04+/Debian 12+ server):
#   ./wg-vpn.sh install            # install + configure the server
#   ./wg-vpn.sh add <name>         # create a client (prints QR code)
#   ./wg-vpn.sh show <name>        # re-print a client's config + QR code
#   ./wg-vpn.sh remove <name>      # revoke a client
#   ./wg-vpn.sh list               # list clients and last handshake
#   ./wg-vpn.sh status             # wg show
#   ./wg-vpn.sh uninstall          # remove everything
#
# Optional environment overrides for `install`:
#   WG_PORT=51820  WG_ENDPOINT=vpn.example.com  WG_DNS="9.9.9.9, 149.112.112.112"
#   WG_SUBNET4=10.66.66   WG_SUBNET6=fd42:66:66::
#
# WG_DIR can be pointed elsewhere for testing (default /etc/wireguard).

set -euo pipefail

WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_IF="${WG_IF:-wg0}"
CONF="$WG_DIR/$WG_IF.conf"
PARAMS="$WG_DIR/params"
CLIENT_DIR="$WG_DIR/clients"
# Set WG_NO_APPLY=1 to only write files (no packages, sysctl, services).
WG_NO_APPLY="${WG_NO_APPLY:-0}"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

need_root() {
  [[ "$WG_NO_APPLY" == 1 ]] && return
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 $*)"
}

load_params() {
  [[ -f "$PARAMS" ]] || die "server not installed; run: $0 install"
  # Defines SERVER_PUB_KEY SERVER_ENDPOINT SERVER_PORT PUBLIC_IF SUBNET4 SUBNET6 CLIENT_DNS
  # shellcheck source=/dev/null disable=SC2153
  source "$PARAMS"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "client name must be 1-32 chars: letters, digits, _ or -"
}

apply_conf() {
  [[ "$WG_NO_APPLY" == 1 ]] && return
  if ip link show "$WG_IF" &>/dev/null; then
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
  fi
}

detect_public_if() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_public_ip() {
  local ip=""
  ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(ip -4 addr show "$(detect_public_if)" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
  echo "$ip"
}

cmd_install() {
  need_root install
  [[ -f "$CONF" ]] && die "$CONF already exists; run '$0 uninstall' first to reinstall"

  local port="${WG_PORT:-51820}"
  local dns="${WG_DNS:-1.1.1.1, 1.0.0.1}"
  local s4="${WG_SUBNET4:-10.66.66}"
  local s6="${WG_SUBNET6:-fd42:66:66::}"
  local pub_if endpoint

  if [[ "$WG_NO_APPLY" != 1 ]]; then
    command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) are supported"
    info "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools qrencode iptables curl unattended-upgrades >/dev/null
  fi

  pub_if="${WG_PUBLIC_IF:-$(detect_public_if)}"
  [[ -n "$pub_if" ]] || die "could not detect public network interface; set WG_PUBLIC_IF"
  endpoint="${WG_ENDPOINT:-$(detect_public_ip)}"
  [[ -n "$endpoint" ]] || die "could not detect public IP; set WG_ENDPOINT"

  info "Generating server keys"
  umask 077
  mkdir -p "$WG_DIR" "$CLIENT_DIR"
  local priv pub
  priv=$(wg genkey)
  pub=$(echo "$priv" | wg pubkey)

  cat > "$PARAMS" <<EOF
SERVER_PUB_KEY=$pub
SERVER_ENDPOINT=$endpoint
SERVER_PORT=$port
PUBLIC_IF=$pub_if
SUBNET4=$s4
SUBNET6=$s6
CLIENT_DNS="$dns"
EOF

  # NAT + forwarding rules are attached to the interface lifecycle so they
  # never linger after `wg-quick down`.
  cat > "$CONF" <<EOF
# Managed by wg-vpn.sh — peers are added/removed by the script.
[Interface]
Address = ${s4}.1/24, ${s6}1/64
ListenPort = $port
PrivateKey = $priv
PostUp   = iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${s4}.0/24 -o $pub_if -j MASQUERADE; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -I FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; ip6tables -t nat -A POSTROUTING -s ${s6}/64 -o $pub_if -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${s4}.0/24 -o $pub_if -j MASQUERADE; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; ip6tables -t nat -D POSTROUTING -s ${s6}/64 -o $pub_if -j MASQUERADE
EOF
  chmod 600 "$CONF" "$PARAMS"

  if [[ "$WG_NO_APPLY" != 1 ]]; then
    info "Enabling IP forwarding"
    cat > /etc/sysctl.d/99-wg-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -q --system

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
      info "Opening UDP $port in UFW"
      ufw allow "$port"/udp >/dev/null
      ufw route allow in on "$WG_IF" out "$pub_if" >/dev/null
    fi

    info "Enabling automatic security updates"
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

    info "Starting wg-quick@$WG_IF"
    systemctl enable --now "wg-quick@$WG_IF" >/dev/null
  fi

  echo
  info "Server ready on $endpoint:$port/udp"
  echo "    Make sure UDP $port is allowed in your cloud provider's firewall."
  echo "    Next: $0 add phone"
}

next_ip() {
  local n
  for n in $(seq 2 254); do
    grep -q "AllowedIPs = ${SUBNET4}.${n}/32" "$CONF" || { echo "$n"; return; }
  done
  die "subnet full (253 clients)"
}

# shellcheck disable=SC2153  # CLIENT_DNS comes from the sourced params file
cmd_add() {
  need_root add
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: $0 add <name>"
  valid_name "$name"
  load_params
  grep -q "^### Client $name\$" "$CONF" && die "client '$name' already exists"

  local n priv pub psk
  n=$(next_ip)
  umask 077
  priv=$(wg genkey)
  pub=$(echo "$priv" | wg pubkey)
  psk=$(wg genpsk)

  cat >> "$CONF" <<EOF

### Client $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = ${SUBNET4}.${n}/32, ${SUBNET6}${n}/128
EOF

  local endpoint="$SERVER_ENDPOINT"
  [[ "$endpoint" == *:* && "$endpoint" != \[* ]] && endpoint="[$endpoint]"   # bare IPv6

  # AllowedIPs 0.0.0.0/0, ::/0 = full tunnel. Routing IPv6 into the tunnel
  # also prevents IPv6 leaks even if the server has no IPv6 uplink.
  cat > "$CLIENT_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = ${SUBNET4}.${n}/32, ${SUBNET6}${n}/128
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUB_KEY
PresharedKey = $psk
Endpoint = ${endpoint}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_DIR/$name.conf"

  apply_conf
  info "Added client '$name' (${SUBNET4}.${n})"
  cmd_show "$name"
}

cmd_show() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: $0 show <name>"
  valid_name "$name"
  local f="$CLIENT_DIR/$name.conf"
  [[ -f "$f" ]] || die "no client '$name'"
  echo "--- $f ---"
  cat "$f"
  echo "---"
  if command -v qrencode >/dev/null; then
    echo "Scan with the WireGuard mobile app:"
    qrencode -t ansiutf8 < "$f"
  fi
}

cmd_remove() {
  need_root remove
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: $0 remove <name>"
  valid_name "$name"
  load_params
  grep -q "^### Client $name\$" "$CONF" || die "no client '$name'"

  # Drop the "### Client <name>" block up to the next block / EOF.
  local tmp; tmp=$(mktemp)
  awk -v tag="### Client $name" '
    $0 == tag { skip = 1; next }
    /^### Client / { skip = 0 }
    !skip { print }
  ' "$CONF" | cat -s > "$tmp"
  cat "$tmp" > "$CONF"; rm -f "$tmp"
  rm -f "$CLIENT_DIR/$name.conf"

  apply_conf
  info "Removed client '$name'"
}

cmd_list() {
  load_params
  local names; names=$(awk '/^### Client /{print $3}' "$CONF")
  [[ -n "$names" ]] || { echo "(no clients)"; return; }
  local hs=""
  if [[ "$WG_NO_APPLY" != 1 ]] && ip link show "$WG_IF" &>/dev/null; then
    hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null || true)
  fi
  printf "%-20s %-15s %s\n" NAME ADDRESS LAST-HANDSHAKE
  local name pub addr t when
  for name in $names; do
    pub=$(awk -v tag="### Client $name" '$0==tag{f=1} f&&/^PublicKey/{print $3; exit}' "$CONF")
    addr=$(awk -v tag="### Client $name" '$0==tag{f=1} f&&/^AllowedIPs/{sub(/\/.*/,"",$3); print $3; exit}' "$CONF")
    t=$(awk -v k="$pub" '$1==k{print $2}' <<<"$hs")
    if [[ -z "$t" || "$t" == 0 ]]; then when="never"; else when=$(date -d "@$t" '+%F %T'); fi
    printf "%-20s %-15s %s\n" "$name" "$addr" "$when"
  done
}

cmd_uninstall() {
  need_root uninstall
  read -r -p "Remove the VPN server and ALL client configs? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || exit 0
  if [[ "$WG_NO_APPLY" != 1 ]]; then
    systemctl disable --now "wg-quick@$WG_IF" 2>/dev/null || true
    rm -f /etc/sysctl.d/99-wg-vpn.conf
    sysctl -q --system || true
  fi
  rm -rf "$CONF" "$PARAMS" "$CLIENT_DIR"
  info "Uninstalled (packages left in place)"
}

case "${1:-}" in
  install)   cmd_install ;;
  add)       cmd_add "${2:-}" ;;
  show)      cmd_show "${2:-}" ;;
  remove|rm) cmd_remove "${2:-}" ;;
  list|ls)   cmd_list ;;
  status)    wg show "$WG_IF" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
