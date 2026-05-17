#!/bin/bash

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl is not available in PATH"
    exit 1
fi

if ! command -v hcloud >/dev/null 2>&1; then
    echo "ERROR: hcloud is not available in PATH"
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "No node names provided. Nothing will be deleted."
    echo "Available Kubernetes nodes:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers || true
    echo "Usage: $0 <node-name> [<node-name> ...]"
    echo "Example: $0 edgecloudinfra-w0 edgecloudinfra-w1"
    exit 1
fi

NODE_NAMES=("$@")

is_control_plane_node() {
    local node_name="$1"
    local cp_label
    local master_label

    cp_label=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)
    master_label=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null || true)

    [[ -n "$cp_label" || -n "$master_label" ]]
}

control_plane_count() {
    kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l | tr -d ' '
}

remaining_control_plane_node() {
    local removed_node="$1"
    kubectl get nodes -l node-role.kubernetes.io/control-plane -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null |
        awk -v removed="$removed_node" '$1 != removed {print $1; exit}'
}

remove_etcd_member_for_control_plane() {
    local removed_node="$1"
    local keeper_node="$2"
    local etcd_pod="etcd-${keeper_node}"
    local member_list
    local member_id

    echo "   - Using remaining control-plane node '$keeper_node'"
    echo "   - Reading etcd membership from pod '$etcd_pod'"

    member_list=$(kubectl -n kube-system exec "$etcd_pod" -- sh -lc '
        ETCDCTL_API=3
        etcdctl \
            --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
            --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
            --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
            --endpoints=https://127.0.0.1:2379 \
            member list
    ')

    member_id=$(printf '%s\n' "$member_list" | awk -F',' -v n="$removed_node" '$0 ~ ("name=" n) {print $1; exit}')

    if [[ -z "$member_id" ]]; then
        echo "ERROR: Could not find etcd member for node '$removed_node'."
        echo "Refusing to continue to avoid leaving a stale etcd member."
        echo "Current etcd members:"
        echo "$member_list"
        exit 1
    fi

    echo "   - Removing etcd member id '$member_id' for node '$removed_node'"
    kubectl -n kube-system exec "$etcd_pod" -- sh -lc "
        ETCDCTL_API=3
        etcdctl \
            --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
            --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
            --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
            --endpoints=https://127.0.0.1:2379 \
            member remove $member_id
    "
}

echo "This will gracefully remove the following node(s): ${NODE_NAMES[*]}"
read -rp "Continue [yes/no]: " confirm
if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted."
    exit 1
fi

for node_name in "${NODE_NAMES[@]}"; do
    echo "---"
    echo "Removing node: $node_name"

    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        echo "ERROR: Kubernetes node '$node_name' not found"
        exit 1
    fi

    node_type="worker"
    if is_control_plane_node "$node_name"; then
        node_type="control-plane"
    fi

    echo "Node role detected: $node_type"

    if [[ "$node_type" == "control-plane" ]]; then
        cp_count=$(control_plane_count)
        if [[ "$cp_count" -le 1 ]]; then
            echo "ERROR: Refusing to remove the last control-plane node."
            exit 1
        fi

        echo "0) Remove etcd member for control-plane node"
        keeper_node=$(remaining_control_plane_node "$node_name")
        if [[ -z "$keeper_node" ]]; then
            echo "ERROR: Could not determine a remaining control-plane node"
            exit 1
        fi
        remove_etcd_member_for_control_plane "$node_name" "$keeper_node"
    fi

    echo "1) Cordon node"
    kubectl cordon "$node_name"

    echo "2) Drain node"
    if [[ "$node_type" == "control-plane" ]]; then
        kubectl drain "$node_name" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --force \
            --grace-period=60 \
            --timeout=15m
    else
        kubectl drain "$node_name" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --grace-period=60 \
            --timeout=10m
    fi

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
            echo "Pulumi path selected. Remove the node from project_settings.ts and run pulumi up to reconcile desired state."
            echo "The Kubernetes node object has already been removed; the Hetzner VM will remain until Pulumi deletes it."
            ;;
        *)
            echo "Invalid choice: '$removal_mode'"
            echo "Aborting before server removal step."
            exit 1
            ;;
    esac
done
