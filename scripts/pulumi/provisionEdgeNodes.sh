#!/bin/bash
# provisionEdgeNodes.sh — second-pass edge-node provisioning.
#
# Run AFTER `make create` once the cloud cluster + VPN/headscale mesh are up
# (~15 min). Flips the provisionEdgeNodes gate, runs `pulumi up` so the
# OnPremiseNodesComponent reconciles (SSH-joins the edge box), then resets the gate
# so a later create/up never attempts edge SSH.
#
# Usage:
#   make provision-edge              # all edge nodes in project_settings.nodes.edge
#   make provision-edge ARGS=ubuntu-vm   # a single node by id
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILTER="${1:-all}"

if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    if [ -f /tmp/passphrase ]; then
        PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
    else
        read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    fi
    export PULUMI_CONFIG_PASSPHRASE
fi

pulumi login "file://${REPO_ROOT}/.pulumi-state" >/dev/null 2>&1
pulumi stack select mystack >/dev/null 2>&1

if ! pulumi config get edgeSshPrivateKey >/dev/null 2>&1; then
    echo "ERROR: Pulumi secret 'edgeSshPrivateKey' is not set." >&2
    echo "  pulumi config set --secret edgeSshPrivateKey \"\$(cat /path/to/edge_key)\"" >&2
    exit 1
fi

echo "=== Provisioning on-premise edge node(s): ${FILTER} ==="

# Always reset the gate, even on failure, so the cloud create never SSHes edge hosts.
cleanup() { pulumi config set provisionEdgeNodes false >/dev/null 2>&1 || true; }
trap cleanup EXIT

pulumi config set provisionEdgeNodes true
pulumi config set edgeProvisionFilter "$FILTER"

CI=true pulumi up -y --skip-preview

echo ""
echo "Edge provisioning complete. Verify with: kubectl get nodes -o wide"
