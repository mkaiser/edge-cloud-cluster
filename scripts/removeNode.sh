#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <node-name> [<node-name> ...]"
    echo "Example: $0 edgecloudinfra-w0 edgecloudinfra-w1"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl is not available in PATH"
    exit 1
fi

if ! command -v hcloud >/dev/null 2>&1; then
    echo "ERROR: hcloud is not available in PATH"
    exit 1
fi

echo "This will gracefully remove the following worker node(s): $*"
read -rp "Continue [yes/no]: " confirm
if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted."
    exit 1
fi

for node_name in "$@"; do
    echo "---"
    echo "Removing node: $node_name"

    echo "1) Cordon node"
    kubectl cordon "$node_name"

    echo "2) Drain node"
    kubectl drain "$node_name" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --grace-period=60 \
        --timeout=10m

    echo "3) Delete Kubernetes node object"
    kubectl delete node "$node_name" --wait=true

    echo "4) Remove the Hetzner server"
    read -rp "Do you want to stop the server immediately with hcloud, or use Pulumi to remove it from desired state [hcloud/pulumi]: " removal_mode
    case "$removal_mode" in
        hcloud)
            echo "Shutting down Hetzner server immediately..."
            hcloud server shutdown "$node_name" >/dev/null 2>&1 || true

            echo "Deleting Hetzner server..."
            if hcloud server describe "$node_name" >/dev/null 2>&1; then
                hcloud server delete "$node_name"
            else
                echo "Hetzner server '$node_name' not found, skipping delete."
            fi
            ;;
        pulumi)
            echo "Pulumi path selected. Remove the worker from project_settings.ts and run pulumi up to reconcile desired state."
            echo "The Kubernetes node object has already been removed; the Hetzner VM will remain until Pulumi deletes it."
            ;;
        *)
            echo "Invalid choice: '$removal_mode'"
            echo "Aborting before server removal step."
            exit 1
            ;;
    esac
done
