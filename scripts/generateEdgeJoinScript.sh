#!/bin/bash
# generateEdgeJoinScript: Generate two self-contained edge-node scripts.
#
# Runs on the devcontainer (needs kubectl + wireguard to CP0).
# Produces:
#   tmp/1_connectVPN.sh    — install Tailscale and join headscale VPN
#   tmp/2_joinCluster.sh   — install k3s agent and join the cluster (VPN required)
#
# Run them in order on the edge node:
#   sudo bash 1_connectVPN.sh
#   sudo bash 2_joinCluster.sh
#
# NOTE: The CP0 VPN IP is baked into 2_joinCluster.sh as the routing gateway
# for the Hetzner private subnet (10.0.0.0/23). Re-run after cluster recreation
# to pick up the new CP0 VPN IP.
# K3S_URL points to the kube-vip VIP (10.0.0.100) — stable across CP changes.
#
# Usage:
#   ./scripts/generateEdgeJoinScript.sh           # generate both scripts
#   ./scripts/generateEdgeJoinScript.sh --token   # print tailscale auth key only
#   ./scripts/generateEdgeJoinScript.sh --qr      # display QR code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/tmp"
VPN_SCRIPT="$OUTPUT_DIR/1_connectVPN.sh"
K3S_SCRIPT="$OUTPUT_DIR/2_joinCluster.sh"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
NAMESPACE="${HEADSCALE_NAMESPACE:-headscale}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

# ─────────────────────────────────────────────────────────────────────────────
# Resolve HEADSCALE_URL from project_settings.ts
# ─────────────────────────────────────────────────────────────────────────────
BASE_DOMAIN=$(sed -n 's/^const baseDomain = "\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
SUBDOMAIN=$(sed -n 's/^const subdomain = "\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
HEADSCALE_URL="https://vpn.${SUBDOMAIN:+${SUBDOMAIN}.}${BASE_DOMAIN}"

# ─────────────────────────────────────────────────────────────────────────────
# Verify kubectl
# ─────────────────────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl not connected. Run: ./scripts/getKubeConfig.sh" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Get tailscale auth key from K8s secret
# ─────────────────────────────────────────────────────────────────────────────
if ! kubectl get secret headscale-preauthkey -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: headscale-preauthkey secret not found in namespace $NAMESPACE" >&2
  echo "Create: kubectl exec -n $NAMESPACE <headscale-pod> -- headscale preauthkeys create --user edge-servers --reusable --expiration 8760h" >&2
  exit 1
fi

TS_AUTHKEY=$(kubectl get secret headscale-preauthkey -n "$NAMESPACE" \
  -o jsonpath='{.data.key}' | base64 -d)
[ -n "$TS_AUTHKEY" ] || { echo "ERROR: Could not decode headscale-preauthkey secret" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Resolve CP0 private IP
# ─────────────────────────────────────────────────────────────────────────────
CP0_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl get nodes -o jsonpath='{.items[*].metadata.name}' \
     | tr ' ' '\n' | grep -m1 cp0 || true)

CP0_PRIVATE_IP=$(kubectl get node "$CP0_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)

[ -n "$CP0_PRIVATE_IP" ] || {
  echo "ERROR: Could not determine CP0 private IP. Ensure wireguard is connected." >&2; exit 1
}
echo "CP0 node:       $CP0_NODE"
echo "CP0 private IP: $CP0_PRIVATE_IP"

# ─────────────────────────────────────────────────────────────────────────────
# Get CP0 VPN IP via kubectl exec (tailscale CLI is in the pod, not on the host)
# ─────────────────────────────────────────────────────────────────────────────
CP0_TS_POD=$(kubectl get pods -n headscale -l app=cp-tailscale \
  --field-selector "spec.nodeName=${CP0_NODE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$CP0_TS_POD" ] || {
  echo "ERROR: No cp-tailscale pod found on node $CP0_NODE." >&2
  echo "Check: kubectl get pods -n headscale -l app=cp-tailscale" >&2; exit 1
}

CP0_VPN_IP=$(kubectl exec -n headscale "$CP0_TS_POD" -c tailscale -- \
  tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$CP0_VPN_IP" ] || {
  echo "ERROR: CP0 pod has no tailscale VPN IP. Is headscale reachable?" >&2
  echo "Check: kubectl logs -n headscale $CP0_TS_POD -c tailscale --tail=20" >&2; exit 1
}
echo "CP0 VPN IP:     $CP0_VPN_IP"

# ─────────────────────────────────────────────────────────────────────────────
# Ensure CP0 headscale subnet route (10.0.0.0/23) is approved.
# Edge nodes need this to reach the Hetzner private network (10.0.0.100:6443).
# headscale requires explicit approval of advertised routes; it is not automatic.
# ─────────────────────────────────────────────────────────────────────────────
HS_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=headscale \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
  kubectl get pods -n "$NAMESPACE" -l app=headscale \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$HS_POD" ]; then
  CP0_NODE_ID=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
    headscale nodes list --output json 2>/dev/null \
    | python3 -c "
import sys,json
nodes=json.load(sys.stdin)
nodes=nodes if isinstance(nodes,list) else nodes.get('nodes',[])
cp=[n for n in nodes if n.get('ipAddresses',n.get('ip_addresses',[])) and '${CP0_VPN_IP}' in str(n.get('ipAddresses',n.get('ip_addresses',[])))]
print(cp[0]['id'] if cp else '')
" 2>/dev/null || true)
  if [ -n "$CP0_NODE_ID" ]; then
    kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
      headscale nodes approve-routes --identifier "$CP0_NODE_ID" --routes 10.0.0.0/23 \
      2>/dev/null && echo "Headscale route 10.0.0.0/23 approved for CP0 (node $CP0_NODE_ID)." \
      || echo "WARNING: Could not approve headscale route — approve manually via headplane UI."
  else
    echo "WARNING: CP0 not found in headscale nodes — route approval skipped."
  fi
else
  echo "WARNING: headscale pod not found — route approval skipped."
fi

# ─────────────────────────────────────────────────────────────────────────────
# SSH to CP0 — get k3s node-token
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@${CP0_PRIVATE_IP}" true 2>/dev/null || {
  echo "ERROR: Cannot SSH to root@${CP0_PRIVATE_IP}. Ensure wireguard is active." >&2; exit 1
}

# shellcheck disable=SC2086
K3S_TOKEN=$(ssh $SSH_OPTS "root@${CP0_PRIVATE_IP}" \
  'cat /var/lib/rancher/k3s/server/node-token' || true)
[ -n "$K3S_TOKEN" ] || { echo "ERROR: Could not read k3s node-token from CP0" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Get k3s server version
# ─────────────────────────────────────────────────────────────────────────────
K3S_VERSION=$(kubectl version 2>/dev/null \
  | grep "Server Version" \
  | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' | head -n1 || true)
echo "k3s version:    ${K3S_VERSION:-latest}"

# ─────────────────────────────────────────────────────────────────────────────
# Patch k3s TLS SANs to include CP0 VPN IP (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Checking k3s TLS SANs for $CP0_VPN_IP ..."
CERT_SANS=$(echo \
  | openssl s_client -connect "${CP0_PRIVATE_IP}:6443" 2>/dev/null \
  | openssl x509 -noout -text 2>/dev/null \
  | grep -A2 "Subject Alternative Name" || true)

if echo "$CERT_SANS" | grep -q "$CP0_VPN_IP"; then
  echo "VPN IP already in TLS SANs — no restart needed."
else
  echo "Patching k3s TLS SANs on CP0 and restarting..."
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "root@${CP0_PRIVATE_IP}" "bash -s" << PATCH_EOF
set -e
VPN_IP="${CP0_VPN_IP}"
CONFIG=/etc/rancher/k3s/config.yaml
if grep -q "^tls-san:" "\$CONFIG" 2>/dev/null; then
  grep -q "\$VPN_IP" "\$CONFIG" \
    && echo "  Already in config — restarting to rotate cert." \
    || { sed -i "/^tls-san:/a\\  - \$VPN_IP" "\$CONFIG"; echo "  Appended \$VPN_IP."; }
else
  printf '\ntls-san:\n  - %s\n' "\$VPN_IP" >> "\$CONFIG"
  echo "  Added new tls-san block."
fi
systemctl restart k3s
echo "  k3s restarted."
PATCH_EOF

  echo "Waiting for k3s to recover..."
  for i in $(seq 1 20); do
    kubectl get nodes &>/dev/null 2>&1 && { echo "k3s recovered."; break; }
    sleep 3
  done
  kubectl get nodes &>/dev/null 2>&1 || {
    echo "ERROR: k3s did not recover. Check: ssh root@${CP0_PRIVATE_IP} 'journalctl -u k3s -n 50'" >&2; exit 1
  }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate 1_connectVPN.sh
# ─────────────────────────────────────────────────────────────────────────────
generate_vpn_script() {
  cat > "$VPN_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# 1_connectVPN.sh — Install Tailscale and join the headscale VPN.
# Generated by: scripts/generateEdgeJoinScript.sh — DO NOT COMMIT (contains secrets).
#
# Run as root or with sudo:
#   sudo bash 1_connectVPN.sh
#
# After this script completes, run 2_joinCluster.sh to join the k3s cluster.

set -euo pipefail

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

HEADSCALE_URL="HEADSCALE_URL_PLACEHOLDER"
TS_AUTHKEY="TS_AUTHKEY_PLACEHOLDER"
HEADSCALE_HOST="${HEADSCALE_URL#https://}"
HEADSCALE_CA_FILE="/usr/local/share/ca-certificates/headscale-login-ca.crt"

# ── Trust headscale CA (handles Let's Encrypt staging certs) ─────────────────
install_headscale_ca() {
  local chain_dir chain_file trusted_cert
  chain_dir="$(mktemp -d)"
  chain_file="$chain_dir/chain.pem"
  timeout 15 openssl s_client \
      -connect "${HEADSCALE_HOST}:443" -servername "$HEADSCALE_HOST" \
      -showcerts </dev/null >"$chain_file" 2>/dev/null || { rm -rf "$chain_dir"; return 1; }
  csplit -z -f "$chain_dir/cert-" -b '%02d.pem' "$chain_file" \
    '/-----BEGIN CERTIFICATE-----/' '{*}' >/dev/null 2>&1 || true
  trusted_cert=$(find "$chain_dir" -maxdepth 1 -name 'cert-*.pem' | sort | tail -n1)
  [ -n "$trusted_cert" ] || { rm -rf "$chain_dir"; return 1; }
  install -m 0644 "$trusted_cert" "$HEADSCALE_CA_FILE"
  update-ca-certificates >/dev/null
  rm -rf "$chain_dir"
}

# ── Install Tailscale (skip if already present) ───────────────────────────────
if ! command -v tailscale &>/dev/null; then
  echo "=== Install Tailscale ==="
  export DEBIAN_FRONTEND=noninteractive
  UBUNTU_CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-focal}" || echo "focal")
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt-get update -qq
  apt-get install -y tailscale
else
  echo "=== Tailscale already installed — skipping package install ==="
fi

TS_SERVICE=""
for svc in tailscaled tailscale; do
  systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null \
    | grep -q "^${svc}" && { TS_SERVICE="$svc"; break; }
done
[ -n "$TS_SERVICE" ] || { echo "ERROR: tailscaled unit not found." >&2; exit 1; }

systemctl enable --now "$TS_SERVICE"
systemctl is-active --quiet "$TS_SERVICE" || {
  systemctl status "$TS_SERVICE" --no-pager >&2; exit 1
}

# ── Connect to headscale ──────────────────────────────────────────────────────
echo ""
echo "=== Connect to headscale VPN ==="
# Trust CA first, then restart daemon so it picks up the new cert pool before
# tailscale up is called (tailscaled caches x509 roots at startup).
if ! curl -fsI --max-time 10 "$HEADSCALE_URL" >/dev/null 2>&1; then
  echo "Headscale TLS not trusted; importing CA chain..."
  install_headscale_ca
  systemctl restart "$TS_SERVICE"
  sleep 2
fi
curl -fsI --max-time 10 "$HEADSCALE_URL" >/dev/null 2>&1 || {
  echo "ERROR: Cannot reach $HEADSCALE_URL after CA import" >&2; exit 1
}

# If already connected to a different server, --force-reauth is required.
# If already connected to the correct server, re-up is a no-op (idempotent).
_CURRENT_URL=$(tailscale debug prefs 2>/dev/null | grep -i 'ControlURL' | awk '{print $2}' | tr -d '",' || true)
if tailscale status &>/dev/null && echo "$_CURRENT_URL" | grep -qF "$HEADSCALE_HOST"; then
  echo "Already connected to $HEADSCALE_URL — skipping tailscale up."
else
  tailscale up \
    --login-server "$HEADSCALE_URL" \
    --authkey "$TS_AUTHKEY" \
    --hostname "$(hostname)" \
    --accept-dns=false \
    --accept-routes \
    --force-reauth
fi

echo "Waiting for VPN IP..."
for i in $(seq 1 20); do
  VPN_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  [ -n "$VPN_IP" ] && break
  sleep 3
done
[ -n "$VPN_IP" ] || {
  echo "ERROR: No tailscale IP after 60s." >&2; tailscale status >&2; exit 1
}

echo ""
echo "=== VPN connected ==="
echo "VPN IP: $VPN_IP"
tailscale status

# tailscaled (v1.96.x + headscale) does not install IPv4 peer routes into the
# kernel routing table for custom headscale prefixes.  Without this route,
# traffic to the control-plane VPN IP (10.0.10.1) hits the default gateway
# instead of tailscale0, so k3s-agent can never reach the API server.
# The /23 covers the entire headscale prefix (10.0.10.0–10.0.11.255) and
# is more specific than any RFC-1918 catch-all that might exist on this host.
echo "Installing VPN peer route: 10.0.10.0/23 dev tailscale0"
ip route replace 10.0.10.0/23 dev tailscale0 || true

# Persist the route across reboots via a systemd drop-in.
mkdir -p "/etc/systemd/system/${TS_SERVICE}.service.d"
cat > "/etc/systemd/system/${TS_SERVICE}.service.d/vpn-routes.conf" << 'DROPIN'
[Service]
ExecStartPost=/bin/sh -c 'for i in $(seq 1 30); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; ip route replace 10.0.10.0/23 dev tailscale0 2>/dev/null || true'
DROPIN
systemctl daemon-reload
echo "Persistent VPN route drop-in written."

echo ""
echo "Next step: sudo bash 2_joinCluster.sh"
SCRIPT_EOF

  sed -i "s|HEADSCALE_URL_PLACEHOLDER|${1}|g" "$VPN_SCRIPT"
  sed -i "s|TS_AUTHKEY_PLACEHOLDER|${2}|g"    "$VPN_SCRIPT"
  chmod +x "$VPN_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# Generate 2_joinCluster.sh
# ─────────────────────────────────────────────────────────────────────────────
generate_k3s_script() {
  cat > "$K3S_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# 2_joinCluster.sh — Install k3s agent and join the cluster.
# Generated by: scripts/generateEdgeJoinScript.sh — DO NOT COMMIT (contains secrets).
#
# Prerequisite: 1_connectVPN.sh must have completed successfully.
#
# Run as root or with sudo:
#   sudo bash 2_joinCluster.sh

set -euo pipefail

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

CP0_VPN_IP="CP0_VPN_IP_PLACEHOLDER"
K3S_TOKEN="K3S_TOKEN_PLACEHOLDER"
K3S_VERSION="K3S_VERSION_PLACEHOLDER"
K3S_URL="https://10.0.0.100:6443"

# ── Verify VPN is connected ───────────────────────────────────────────────────
echo "=== Checking VPN connection ==="
command -v tailscale &>/dev/null || {
  echo "ERROR: tailscale not found. Run 1_connectVPN.sh first." >&2; exit 1
}
EDGE_VPN_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$EDGE_VPN_IP" ] || {
  echo "ERROR: No tailscale VPN IP. Run 1_connectVPN.sh first." >&2
  tailscale status >&2; exit 1
}
echo "VPN IP: $EDGE_VPN_IP"

# ── Check for existing k3s-agent installation ────────────────────────────────
K3S_INSTALLED=false
if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  K3S_INSTALLED=true
  echo "k3s-agent service is active."
elif systemctl list-unit-files k3s-agent.service 2>/dev/null | grep -q k3s-agent; then
  K3S_INSTALLED=true
  echo "k3s-agent service is installed but not active."
elif [ -x /usr/local/bin/k3s ] && [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
  K3S_INSTALLED=true
  echo "k3s binary found (service not registered)."
fi

if [ "$K3S_INSTALLED" = "true" ]; then
  printf "Existing k3s-agent installation detected. Uninstall and rejoin? [y/N] "
  read -r REPLY </dev/tty
  case "$REPLY" in
    [yY]|[yY][eE][sS])
      echo "Stopping and uninstalling k3s-agent..."
      systemctl stop k3s-agent 2>/dev/null || true
      /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
      echo "Uninstalled."
      ;;
    *)
      echo "Skipping — node not changed."
      exit 0
      ;;
  esac
fi

# ── Longhorn / storage prerequisites ─────────────────────────────────────────
echo ""
echo "=== Installing Longhorn prerequisites ==="
apt-get update -qq
apt-get install -y open-iscsi nfs-common cryptsetup dmsetup
# Enable iscsid (required by Longhorn for iSCSI volume attachment)
systemctl enable iscsid --now
# Load iscsi_tcp kernel module now; persist across reboots
modprobe iscsi_tcp 2>/dev/null || true
echo "iscsi_tcp" > /etc/modules-load.d/iscsi.conf
echo "Longhorn prerequisites installed. iscsid: $(systemctl is-active iscsid)"

# ── Route to Hetzner private network (needed to reach kube-vip VIP) ──────────
echo ""
echo "=== Installing route to Hetzner private network ==="
ip route replace 10.0.0.0/23 via "$CP0_VPN_IP" dev tailscale0 2>/dev/null || true
echo "Route 10.0.0.0/23 -> $CP0_VPN_IP installed"

cat > /etc/systemd/system/hetzner-private-route.service << 'ROUTE_SVC'
[Unit]
Description=Route to Hetzner private subnet via tailscale
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in $(seq 1 60); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; ip route replace 10.0.0.0/23 via CP0_VPN_IP_PLACEHOLDER dev tailscale0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
ROUTE_SVC
systemctl daemon-reload
systemctl enable hetzner-private-route
echo "Persistent route service enabled."

# ── Install k3s agent ─────────────────────────────────────────────────────────
echo ""
echo "=== Install k3s agent ==="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG
node-ip: ${EDGE_VPN_IP}
node-external-ip: ${EDGE_VPN_IP}
flannel-iface: tailscale0
node-label:
  - 'node.longhorn.io/create-default-disk=true'
KCONFIG

echo "  API server : $K3S_URL"
echo "  node-ip    : $EDGE_VPN_IP"
echo "  interface  : tailscale0"
echo "  version    : ${K3S_VERSION:-latest}"

if [ -n "$K3S_VERSION" ]; then
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -
else
  curl -sfL https://get.k3s.io \
    | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -
fi

echo ""
echo "=== Node joined ==="
echo "Verify from devcontainer: kubectl get nodes"
SCRIPT_EOF

  sed -i "s|CP0_VPN_IP_PLACEHOLDER|${1}|g"  "$K3S_SCRIPT"
  sed -i "s|K3S_TOKEN_PLACEHOLDER|${2}|g"   "$K3S_SCRIPT"
  sed -i "s|K3S_VERSION_PLACEHOLDER|${3}|g" "$K3S_SCRIPT"
  chmod +x "$K3S_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI modes
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --token)
    echo "$TS_AUTHKEY"
    ;;

  --qr)
    command -v qrencode &>/dev/null || {
      echo "qrencode not installed: apt install qrencode" >&2
      echo "Token: $TS_AUTHKEY"; exit 1
    }
    qrencode -t ANSI256 "${HEADSCALE_URL}?authkey=${TS_AUTHKEY}"
    echo ""
    echo "tailscale up --login-server $HEADSCALE_URL --authkey $TS_AUTHKEY"
    ;;

  *)
    mkdir -p "$OUTPUT_DIR"
    generate_vpn_script  "$HEADSCALE_URL" "$TS_AUTHKEY"
    generate_k3s_script  "$CP0_VPN_IP" "$K3S_TOKEN" "${K3S_VERSION:-}"

    echo ""
    echo "=== Generated edge node scripts ==="
    echo "Headscale URL : $HEADSCALE_URL"
    echo "CP0 VPN IP    : $CP0_VPN_IP"
    echo "k3s version   : ${K3S_VERSION:-latest}"
    echo ""
    echo "  $VPN_SCRIPT"
    echo "  $K3S_SCRIPT"
    echo ""
    echo "Copy and run on edge node (adjust user, host, port as needed):"
    echo "  scp -P <port> $VPN_SCRIPT $K3S_SCRIPT user@<edge-node>:/tmp/"
    echo "  ssh -p <port> user@<edge-node> 'sudo bash /tmp/1_connectVPN.sh'"
    echo "  ssh -p <port> user@<edge-node> 'sudo bash /tmp/2_joinCluster.sh'"
    echo ""
    echo "Longhorn disk label and route are applied automatically by 2_joinCluster.sh."
    ;;
esac
