#!/bin/bash
# 30-join-cluster.sh — Install k3s agent and join the cluster over the VPN.
#
# SHARED edge-join logic — single source of truth, consumed by BOTH:
#   - scripts/runtime/generateEdgeJoinScript.sh (manual; fills placeholders via sed)
#   - src/nodes-k3s-on-premise.ts (Pulumi remote.Command; fills placeholders via env-subst)
# DO NOT COMMIT a filled-in copy (contains the k3s node token).
#
# Prerequisite: 20-connect-vpn.sh completed (tailscale up).
# Placeholders: CP0_VPN_IP_PLACEHOLDER, K3S_TOKEN_PLACEHOLDER, K3S_VERSION_PLACEHOLDER
# Args: --node-name=<name>, --force (non-interactive re-provision)
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 30-join-cluster.sh failed at line $LINENO" >&2' ERR

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

FORCE=false
NODE_NAME=""
for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
  [[ "$arg" == --node-name=* ]] && NODE_NAME="${arg#--node-name=}"
done

# CP0_VPN_IP is still substituted by the generator/Pulumi pipeline but no longer used
# for the private-network route (now tailscale-managed for HA failover; see below).
# Kept for backwards-compat with the placeholder pipeline / potential future use.
CP0_VPN_IP="CP0_VPN_IP_PLACEHOLDER"  # shellcheck disable=SC2034
K3S_TOKEN="K3S_TOKEN_PLACEHOLDER"
K3S_VERSION="K3S_VERSION_PLACEHOLDER"
# Hetzner private subnet (where the k3s apiserver is advertised) — kept in sync with
# project_settings.ts by scripts/environment/updateConfigFromProjectSettings.sh.
SUBNET_RANGE="10.0.0.0/23" # project-settings: network.subnetRange
# Connect to the API via the headscale MagicDNS name k3s-api.ts.internal, which resolves
# to cp0's tailscale IP (see deployment/argocd-sync-waves/wave8-headscale.yaml extra_records;
# repointed from the kube-vip VIP 10.0.0.100 to 10.0.10.1). Edge nodes reach cp0 directly
# over the tailscale mesh; they CANNOT reach the private VIP 10.0.0.100 (cp0 doesn't forward
# 10.0.0.0/23 off tailscale0), which made the agent's local LB (127.0.0.1:6444) time out
# (Ready=Unknown, failed PVC fetches, pod crash-loops). The DNS name (vs a raw IP) survives
# control-plane IP changes / HA. Requires MagicDNS up at join + the name in the API cert SAN.
K3S_URL="https://k3s-api.ts.internal:6443"

# ── Verify VPN is connected ───────────────────────────────────────────────────
echo "=== Checking VPN connection ==="
command -v tailscale &>/dev/null || {
  echo "ERROR: tailscale not found. Run 20-connect-vpn.sh first." >&2; exit 1
}
EDGE_VPN_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$EDGE_VPN_IP" ] || {
  echo "ERROR: No tailscale VPN IP. Run 20-connect-vpn.sh first." >&2
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
  if [ "$FORCE" = "true" ]; then
    echo "Force flag set — uninstalling existing k3s-agent..."
  else
    printf "Existing k3s-agent installation detected. Uninstall and rejoin? [y/N] "
    read -r REPLY </dev/tty
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Skipping — node not changed."; exit 0 ;;
    esac
  fi
  systemctl stop k3s-agent 2>/dev/null || true
  /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
  # Drop the MagicDNS resolved split-route (20-connect-vpn.sh re-creates it on rejoin).
  # Leaving it on a node that has left the cluster is harmless (NXDOMAIN, never a stale IP)
  # but we clean up so the node returns to its pristine resolver config.
  if [ -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf ]; then
    rm -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  echo "Uninstalled."
fi

# ── Route to Hetzner private network (HA-aware) ──────────────────────────────
# The private network 10.0.0.0/23 is where the k3s apiserver is advertised (CP
# advertise-address). The k3s agent load-balancer learns ALL CP endpoints and fails
# over across them — so the edge must reach the private net via WHICHEVER CP is alive,
# not a fixed one. Every cloud CP advertises 10.0.0.0/23 into the mesh and SNATs
# mesh→private (see src/nodes-k3s-cloud.ts + 00-fetch-cluster-inputs.sh route approval).
# We therefore let tailscale own this route (dev tailscale0, no fixed `via`): with
# --accept-routes (set in 20-connect-vpn.sh) tailscaled installs it and points the
# next-hop at a live CP, failing over automatically when cp0 dies. A fixed `via cp0`
# would pin the next-hop and BREAK failover, so we deliberately do NOT set one.
# In non-HA there is only cp0, so this resolves to cp0 — identical to before.
echo ""
echo "=== Installing route to Hetzner private network (tailscale-managed, HA) ==="
ip route replace "$SUBNET_RANGE" dev tailscale0 2>/dev/null || true
echo "Route $SUBNET_RANGE -> dev tailscale0 (headscale-managed next-hop)"

# NB: unquoted heredoc so $SUBNET_RANGE expands now; the runtime shell vars ($i, $(seq…))
# are escaped (\$) so they are evaluated by systemd at boot, not when this file is written.
cat > /etc/systemd/system/hetzner-private-route.service << ROUTE_SVC
[Unit]
Description=Route to Hetzner private subnet via tailscale (HA, headscale-managed next-hop)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 60); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; ip route replace ${SUBNET_RANGE} dev tailscale0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
ROUTE_SVC
systemctl daemon-reload
systemctl enable hetzner-private-route
echo "Persistent route service enabled."

# ── flannel.1 tx-offload off (VXLAN-over-WireGuard checksum repair) ─────────────
# flannel runs over tailscale0 here. With tx-udp-segmentation / generic checksum
# offload on flannel.1, the VXLAN outer UDP checksum is left wrong for the
# userspace WireGuard path (no NIC fixup), so the peer drops frames as
# UdpInCsumErrors — cloud↔edge pod traffic silently breaks. Disable both offloads.
# The cloud (CP) side does the same in deployment/infrastructure/mesh-gateway/daemonset.yaml.
command -v ethtool >/dev/null 2>&1 || (apt-get install -y ethtool >/dev/null 2>&1 || apk add --no-cache ethtool >/dev/null 2>&1) || true
cat > /etc/systemd/system/flannel-offload.service << 'OFFLOAD_SVC'
[Unit]
Description=Disable flannel.1 tx offload (VXLAN-over-WireGuard checksum repair)
After=k3s-agent.service
Wants=k3s-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in $(seq 1 120); do ip link show flannel.1 >/dev/null 2>&1 && break; sleep 1; done; ethtool -K flannel.1 tx-udp-segmentation off tx-checksum-ip-generic off 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
OFFLOAD_SVC
systemctl daemon-reload
systemctl enable flannel-offload
echo "Persistent flannel-offload service enabled."

# ── Install k3s agent ─────────────────────────────────────────────────────────
echo ""
echo "=== Install k3s agent ==="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG
node-ip: ${EDGE_VPN_IP}
node-external-ip: ${EDGE_VPN_IP}
flannel-iface: tailscale0
${NODE_NAME:+node-name: ${NODE_NAME}}
node-label:
  - 'node.longhorn.io/create-default-disk=true'
  - 'node.kubernetes.io/edge-worker=true'
node-taint:
  - 'ecc/edge=true:NoSchedule'
KCONFIG

# Flannel VXLAN MTU must match the cloud nodes (uniform flannel.1=1230). Edge nodes run
# flannel over tailscale0 (WireGuard MTU 1280); the default flannel.1≈1450 + ~50B VXLAN
# overhead exceeds 1280, silently dropping large frames (API watch streams, kubectl logs,
# Longhorn gRPC) while small ones pass — an intermittently-"Ready" node whose pods crash-loop.
# k3s agents auto-generate net-conf WITHOUT a custom MTU, so write the file explicitly.
# MTU 1280 → flannel.1 = MTU-50 = 1230, fitting inside tailscale0's 1280. Keep in sync with
# src/nodes-k3s-cloud.ts (server + worker).
cat > /etc/rancher/k3s/flannel-conf.json << 'FLANNEL_CONF'
{
  "Network": "10.42.0.0/16",
  "EnableIPv6": false,
  "EnableIPv4": true,
  "IPv6Network": "::/0",
  "Backend": {
    "Type": "vxlan",
    "VNI": 1,
    "Port": 8472,
    "MTU": 1280
  }
}
FLANNEL_CONF
echo "flannel-conf: /etc/rancher/k3s/flannel-conf.json" >> /etc/rancher/k3s/config.yaml

echo "  API server : $K3S_URL"
echo "  node-ip    : $EDGE_VPN_IP"
echo "  node-name  : ${NODE_NAME:-$(hostname)}"
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
