#!/bin/bash
# Bring the admin WireGuard tunnel UP *inside the devcontainer* so kubectl/etcdctl
# and SSH can reach the cluster's private IPs (10.0.0.0/16: CP private IPs, the
# kube-vip VIP, edge mesh) directly — without relying on a VPN on the Windows/WSL2
# host (the devcontainer is a separate netns behind the Docker bridge).
#
# Requirements (set in .devcontainer/devcontainer.json; need a container REBUILD):
#   --cap-add=NET_ADMIN  --device=/dev/net/tun  --sysctl net.ipv4.conf.all.src_valid_mark=1
# Userspace backend (wireguard-go) is used so no WSL2 kernel module is needed.
#
# Usage: source ./scripts/pulumi/initPulumiStack.sh   (so the WG config can be exported)
#        bash scripts/runtime/wgAdminUp.sh              (admin1 by default)
#        WG_ADMIN=admin2 bash scripts/runtime/wgAdminUp.sh
#        bash scripts/runtime/wgAdminDown.sh            (to tear it down)
#
# ⚠ ONE ADMIN IDENTITY PER TUNNEL, and never the same one twice concurrently. WireGuard
# holds a single endpoint per peer: a second client presenting the same key repoints the
# server at itself on every handshake, so each client's replies are delivered to the other.
# Two devcontainers sharing admin1 measured 65-90% loss inside the tunnel (0% on the
# underlay) and a 20s rehandshake cycle. Give the second devcontainer WG_ADMIN=admin2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IFACE="wgadmin"
CONF="/etc/wireguard/${IFACE}.conf"

# ── Preconditions ────────────────────────────────────────────────────────────
[ -e /dev/net/tun ] || {
    echo "ERROR: /dev/net/tun missing — rebuild the devcontainer (it needs --device=/dev/net/tun)." >&2
    exit 1
}
if ! capsh --print 2>/dev/null | grep -q cap_net_admin && ! ip link add _wgcheck type dummy 2>/dev/null; then
    echo "ERROR: no NET_ADMIN — rebuild the devcontainer (--cap-add=NET_ADMIN)." >&2
    exit 1
fi
ip link del _wgcheck 2>/dev/null || true
command -v wg-quick >/dev/null || { echo "ERROR: wg-quick not installed." >&2; exit 1; }
command -v wireguard-go >/dev/null || { echo "ERROR: wireguard-go (userspace backend) not installed." >&2; exit 1; }

# ── Export the admin WG config from the Pulumi stack ─────────────────────────
mkdir -p "$REPO_ROOT/tmp"
WG_ADMIN="${WG_ADMIN:-admin1}"
RAW="$REPO_ROOT/tmp/wg-${WG_ADMIN}.conf"
if ! pulumi -C "$REPO_ROOT" stack output wireguardClientConfigs --show-secrets 2>/dev/null \
        | jq -er --arg a "$WG_ADMIN" '.[$a]' > "$RAW" || [ ! -s "$RAW" ]; then
    echo "ERROR: could not export the '$WG_ADMIN' client config — is the Pulumi stack loaded?" >&2
    echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
    echo "  Known admins: $(pulumi -C "$REPO_ROOT" stack output wireguardClientConfigs --show-secrets 2>/dev/null | jq -r 'keys | join(", ")')" >&2
    exit 1
fi
echo "admin identity: $WG_ADMIN"

# wg-quick's DNS= handling needs resolvconf and usually fails in a container; drop
# it (we reach the cluster by IP, not by *.eccNNN hostname). Everything else kept.
sudo mkdir -p /etc/wireguard
grep -v '^DNS' "$RAW" | sudo tee "$CONF" >/dev/null
sudo chmod 600 "$CONF"

# ── Bring it up (idempotent) with the userspace backend ──────────────────────
if ip link show "$IFACE" >/dev/null 2>&1; then
    echo "wgadmin already up — re-applying config."
    sudo WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick down "$IFACE" 2>/dev/null || true
fi
sudo WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick up "$CONF"

# ── Verify private-range reachability ────────────────────────────────────────
echo "--- wg handshake ---"
sudo wg show "$IFACE" 2>&1 | sed 's/^/  /' || true
echo "--- private-IP reachability (CP private IP + API VIP) ---"

# Read IPs from Pulumi stack (space-separated: "<cp0-private> <vip>").
# Returns empty when cluster is down (no stack outputs) — graceful skip.
PRIVATE_IPS=$(pulumi -C "$REPO_ROOT" stack output server_privateIPs_for_wg_check 2>/dev/null || true)

if [ -z "$PRIVATE_IPS" ]; then
    echo "  (no stack outputs — cluster may be down, skipping reachability check)"
else
    for ip in $PRIVATE_IPS; do
        code=$(timeout 6 curl -sk --max-time 5 "https://$ip:6443/healthz" \
               -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
        echo "  $ip:6443/healthz -> $code"
    done
fi

# Tunnel is up → re-pin the stable admin API hostname (network.apiServerHost) to the
# private VIP. The provider/admin kubeconfig points at that hostname; over WG the VIP is
# the HA endpoint (survives init-CP loss). See scripts/runtime/setKubeApiHost.sh.
bash "$SCRIPT_DIR/setKubeApiHost.sh" --vip

echo "wgadmin is up. kubectl against a CP private IP (or the VIP) now works."
