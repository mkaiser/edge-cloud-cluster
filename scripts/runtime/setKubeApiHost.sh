#!/bin/bash
# setKubeApiHost.sh — point the stable k3s admin API hostname (project_settings
# network.apiServerHost, e.g. kubeapi.ecc.internal) at an IP via /etc/hosts.
#
# WHY: the Pulumi k8s provider's kubeconfig (select-kubeconfig, src/nodes-k3s-base.ts) uses
# this constant hostname so its CONTENT never changes — a public→private endpoint flip in the
# kubeconfig would replace the provider and cascade a create-replacement onto every k8s
# resource ("already exists" storm; the original Bootstrap→Production hardening failure).
# Which IP the name resolves to is a devcontainer-local routing decision:
#   • bootstrap-create / teardown / breakglass → the init CP's PUBLIC IP  (22/6443 open)
#   • steady state (admin WireGuard tunnel up) → the private VIP          (wgAdminUp.sh)
#
# Usage: setKubeApiHost.sh <ip>          pin the name to <ip>
#        setKubeApiHost.sh --public      pin to the init CP's public IP (from project_settings)
#        setKubeApiHost.sh --vip         pin to network.vip
#        setKubeApiHost.sh --show        print the current mapping (no change)
# Idempotent; safe to re-run. Requires sudo for /etc/hosts (same pattern as wgAdminUp.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/pulumi/_common.sh"

PS_FILE="$(ps_settings_file)"
HOSTNAME_ENTRY="$(sed -nE 's/.*apiServerHost:[[:space:]]*"([^"]+)".*/\1/p' "$PS_FILE" | head -n1)"
[ -n "$HOSTNAME_ENTRY" ] || { echo "ERROR: network.apiServerHost not found in $PS_FILE" >&2; exit 1; }

case "${1:-}" in
    --show)
        getent hosts "$HOSTNAME_ENTRY" || echo "(no mapping for $HOSTNAME_ENTRY)"
        exit 0
        ;;
    --vip)
        IP="$(sed -nE 's/.*vip:[[:space:]]*"([^"]+)".*/\1/p' "$PS_FILE" | head -n1)"
        ;;
    --public)
        # init CP's public IP: the clusterLink:"init" node (robot or hcloud). hcloud nodes
        # have no publicIp in settings (assigned at create) — fall back to the kubeconfig's
        # current server IP if the field is absent.
        IP="$(ps_node_field 'clusterLink:\s*"init"' publicIp)"
        if [ -z "$IP" ] && [ -f "$HOME/.kube/config" ]; then
            IP="$(sed -nE 's|.*server: https://([0-9.]+):.*|\1|p' "$HOME/.kube/config" | head -n1)"
        fi
        ;;
    "")
        echo "Usage: $0 <ip> | --public | --vip | --show" >&2
        exit 1
        ;;
    *)
        IP="$1"
        ;;
esac
[ -n "$IP" ] || { echo "ERROR: could not resolve target IP" >&2; exit 1; }

# Upsert: drop any existing line for the name, append the new mapping.
TMP_HOSTS=$(mktemp)
trap 'rm -f "$TMP_HOSTS"' EXIT
grep -v "[[:space:]]$HOSTNAME_ENTRY\([[:space:]]\|$\)" /etc/hosts > "$TMP_HOSTS" || true
echo "$IP $HOSTNAME_ENTRY" >> "$TMP_HOSTS"
sudo cp "$TMP_HOSTS" /etc/hosts
echo "kubeapi host: $HOSTNAME_ENTRY → $IP"
