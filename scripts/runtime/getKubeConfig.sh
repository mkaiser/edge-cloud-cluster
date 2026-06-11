#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# check if PULUMI_CONFIG_PASSPHRASE is set, else prompt it via setPulumiPassphrase.sh
if [[ -z "$PULUMI_CONFIG_PASSPHRASE" ]]; then
    echo "PULUMI_CONFIG_PASSPHRASE is not set. Please enter it now."
    source "$SCRIPT_DIR/../pulumi/setPulumiPassphrase.sh"
else
    echo "PULUMI_CONFIG_PASSPHRASE is already set. Using existing value."
fi

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
export KUBECONFIG="$KUBECONFIG_PATH"

mode="${1:-}"

if [[ "$mode" == "vpn" ]]; then
    echo "Fetching kubeconfig (VPN/private network) from Pulumi stack..."
    if ! pulumi stack output kubeconfigVpn --show-secrets > "$KUBECONFIG"; then
        echo "Error: Failed to fetch kubeconfigVpn from Pulumi stack." >&2
        return 1
    fi
    echo "✓ Kubeconfig saved to $KUBECONFIG (using private IP via WireGuard VPN)"
elif [[ "$mode" == "talosctl" ]]; then
    echo "Fetching kubeconfig via talosctl (Talos only)..."
    if ! CP_IP=$(pulumi stack output controlPlaneIP); then
        echo "Error: Failed to fetch controlPlaneIP from Pulumi stack." >&2
        return 1
    fi
    TALOSCONFIG=$(mktemp)
    if ! pulumi stack output talosconfig --show-secrets > "$TALOSCONFIG"; then
        echo "Error: Failed to fetch talosconfig from Pulumi stack." >&2
        rm -f "$TALOSCONFIG"
        return 1
    fi
    if ! talosctl --talosconfig "$TALOSCONFIG" --nodes "$CP_IP" --endpoints "$CP_IP" kubeconfig "$KUBECONFIG"; then
        echo "Error: Failed to fetch kubeconfig via talosctl from $CP_IP." >&2
        rm -f "$TALOSCONFIG"
        return 1
    fi
    rm -f "$TALOSCONFIG"
    echo "✓ Kubeconfig saved to $KUBECONFIG (via talosctl)"
elif [[ "$mode" == "ssh" ]]; then
    echo "Fetching kubeconfig via SSH (Debian/K3s only)..."
    if ! CP_IP=$(pulumi stack output controlPlaneIP); then
        echo "Error: Failed to fetch controlPlaneIP from Pulumi stack." >&2
        return 1
    fi
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$CP_IP" "cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s|https://127.0.0.1:6443|https://$CP_IP:6443|g" > "$KUBECONFIG"; then
        echo "Error: Failed to fetch kubeconfig via SSH from $CP_IP." >&2
        return 1
    fi
    echo "✓ Kubeconfig saved to $KUBECONFIG (via SSH)"
else
    echo "Fetching kubeconfig from Pulumi stack..."
    if ! pulumi stack output kubeconfig --show-secrets > "$KUBECONFIG"; then
        echo "Error: Failed to fetch kubeconfig from Pulumi stack." >&2
        return 1
    fi
    echo "✓ Kubeconfig saved to $KUBECONFIG"
fi
