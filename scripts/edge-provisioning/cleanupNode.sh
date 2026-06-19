#!/bin/bash
# cleanupNode.sh — full edge-node clean-slate.
#
# Run ON the edge node (lab/home PC) as root to remove ALL stale state left
# behind after a cluster was destroyed (`make destroy`) but the node was not
# torn down. Stale tailscaled + k3s-agent keep beaconing the now-dead control
# URL / DERP / apiserver; a university IDS can rate-limit or blackhole the host
# for that, which then makes a later legitimate `tailscale up` time out even
# though plain HTTPS:443 still works.
#
# Removes: tailscale identity, the project's persistent route + MagicDNS resolved
# drop-ins, any half-joined k3s agent, and the stale mesh route. Idempotent.
#
# Usage (on the edge node):
#   sudo bash cleanupNode.sh
# Then re-provision from the dev box:
#   make provision-edge ARGS=<node-id>
set -euo pipefail
trap 'echo "ERROR: cleanupNode.sh failed at line $LINENO" >&2' ERR

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

set -x
# Stop & disconnect tailscale, wipe identity
systemctl stop tailscaled 2>/dev/null || true
tailscale down 2>/dev/null || true
tailscale logout 2>/dev/null || true
rm -rf /var/lib/tailscale

# Remove persistent route + DNS drop-ins this project installed
rm -f /etc/systemd/system/tailscaled.service.d/vpn-routes.conf
rm -f /etc/systemd/system/tailscale.service.d/vpn-routes.conf
rm -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf
rmdir /etc/systemd/system/tailscaled.service.d 2>/dev/null || true

# Tear down any half-joined k3s agent from the old cluster
[ -x /usr/local/bin/k3s-agent-uninstall.sh ] && /usr/local/bin/k3s-agent-uninstall.sh
[ -x /usr/local/bin/k3s-killall.sh ] && /usr/local/bin/k3s-killall.sh

# Drop the stale mesh route if still present
ip route del 10.0.10.0/23 2>/dev/null || true

systemctl daemon-reload
systemctl restart systemd-resolved 2>/dev/null || true
set +x

echo "Clean. Now re-run from the dev box: make provision-edge ARGS=<node-id>"
