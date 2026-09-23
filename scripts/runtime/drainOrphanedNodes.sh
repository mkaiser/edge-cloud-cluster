#!/usr/bin/env bash

set -euo pipefail

# drainOrphanedNodes.sh — find and delete dead/unresponsive Kubernetes node objects.
#
# A node is ORPHANED when its kubelet has stopped checking in: its Ready condition
# is no longer "True" (Unknown/False) AND its last heartbeat is older than the
# threshold (default 600 s). This happens when a mesh box is re-provisioned under a
# changed id/storageScope (the old node object lingers as NotReady) or when a kubelet
# simply dies. Such a node still owns Longhorn replicas + scheduling intent; deleting
# the node object lets Longhorn rebuild replicas from healthy peers.
#
# This is the DELETE-THE-DEAD-OBJECT counterpart to removeNode.sh (which gracefully
# cordons/drains a LIVE node and tears down its hcloud VM / etcd membership). We do
# NOT cordon/drain here — an unreachable node can't evict pods, so drain would hang —
# and we do NOT touch hcloud (mesh nodes aren't hcloud servers).
#
# Usage:
#   ./drainOrphanedNodes.sh [STALE_SECONDS]
#   STALE_SECONDS=900 ./drainOrphanedNodes.sh      # env override
# Default threshold: 600 s (10 min). The script lists matching nodes and lets you
# delete all of them or a selected subset.

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl is not available in PATH" >&2
    exit 1
fi

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG="$KUBECONFIG_PATH"

if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERROR: cannot reach the cluster (KUBECONFIG=$KUBECONFIG_PATH)" >&2
    echo "Fetch it with scripts/runtime/getKubeConfig.sh" >&2
    exit 1
fi

# Threshold: positional arg wins, then STALE_SECONDS env, then 600 s default.
THRESHOLD="${1:-${STALE_SECONDS:-600}}"
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: threshold must be a positive integer (seconds), got '$THRESHOLD'" >&2
    exit 1
fi

NOW=$(date -u +%s)

# Read each node's Ready condition status + lastHeartbeatTime. Use the HEARTBEAT
# (last real kubelet check-in), NOT lastTransitionTime — for a dead node the latter
# is the newer controller-flip time and would understate staleness.
NODE_DATA=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\t"}{.lastHeartbeatTime}{end}{"\n"}{end}')

# Collect orphans into parallel arrays.
ORPHAN_NAMES=()
ORPHAN_STATUS=()
ORPHAN_AGE_MIN=()

while IFS=$'\t' read -r name status heartbeat; do
    [[ -z "$name" ]] && continue
    # Healthy node — kubelet still reporting Ready.
    [[ "$status" == "True" ]] && continue
    # Guard against bad/empty data — never flag on a timestamp we can't parse.
    [[ -z "$heartbeat" ]] && continue
    hb=$(date -u -d "$heartbeat" +%s 2>/dev/null || echo "")
    [[ -z "$hb" ]] && continue
    age=$((NOW - hb))
    if (( age > THRESHOLD )); then
        ORPHAN_NAMES+=("$name")
        ORPHAN_STATUS+=("$status")
        ORPHAN_AGE_MIN+=("$((age / 60))")
    fi
done <<< "$NODE_DATA"

if [[ ${#ORPHAN_NAMES[@]} -eq 0 ]]; then
    echo "No orphaned nodes (Ready!=True and last heartbeat older than ${THRESHOLD}s)."
    exit 0
fi

echo "Orphaned node(s) — kubelet silent for more than ${THRESHOLD}s:"
echo ""
printf "  %-3s %-28s %-9s %-10s %s\n" "#" "NAME" "READY" "STALE(min)" "ROLES"
for i in "${!ORPHAN_NAMES[@]}"; do
    name="${ORPHAN_NAMES[$i]}"
    roles=$(kubectl get node "$name" --no-headers 2>/dev/null | awk '{print $3}')
    printf "  %-3s %-28s %-9s %-10s %s\n" "$((i + 1))" "$name" "${ORPHAN_STATUS[$i]}" "${ORPHAN_AGE_MIN[$i]}" "${roles:-<none>}"
done
echo ""

read -rp "Delete which? [all / none / space-separated numbers] (default: none): " selection
selection="${selection:-none}"

SELECTED=()
case "$selection" in
    none|NONE|"")
        echo "Nothing selected. Aborted."
        exit 0
        ;;
    all|ALL)
        SELECTED=("${ORPHAN_NAMES[@]}")
        ;;
    *)
        for tok in $selection; do
            if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
                echo "ERROR: invalid selection token '$tok' (expected a number)." >&2
                exit 1
            fi
            idx=$((tok - 1))
            if (( idx < 0 || idx >= ${#ORPHAN_NAMES[@]} )); then
                echo "ERROR: selection '$tok' out of range (1-${#ORPHAN_NAMES[@]})." >&2
                exit 1
            fi
            SELECTED+=("${ORPHAN_NAMES[$idx]}")
        done
        ;;
esac

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "Nothing selected. Aborted."
    exit 0
fi

echo ""
echo "This will DELETE the following node object(s) + their Longhorn node CRs:"
printf '  - %s\n' "${SELECTED[@]}"
read -rp "Continue [yes/no]: " confirm
if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted."
    exit 1
fi

for name in "${SELECTED[@]}"; do
    echo "--- deleting $name ---"
    kubectl delete node "$name" --ignore-not-found --wait=false

    # Longhorn node CR is normally GC'd with the k8s node. When it lingers, Longhorn's
    # validating webhook refuses deletion while the CR is still schedulable (and can
    # transiently refuse right after the k8s node delete, before it observes the node is
    # gone). So mark it unschedulable first, then retry the delete a few times.
    if kubectl get nodes.longhorn.io "$name" -n longhorn-system >/dev/null 2>&1; then
        kubectl patch nodes.longhorn.io "$name" -n longhorn-system \
            --type=merge -p '{"spec":{"allowScheduling":false}}' >/dev/null 2>&1 || true
        for attempt in 1 2 3 4 5; do
            if kubectl delete nodes.longhorn.io "$name" -n longhorn-system \
                    --ignore-not-found --wait=false 2>/dev/null; then
                break
            fi
            [[ $attempt -eq 5 ]] && \
                echo "  WARNING: could not delete Longhorn node CR '$name' — delete it manually." >&2
            sleep 3
        done
    fi
done

echo ""
echo "Done. Remaining nodes:"
kubectl get nodes --no-headers | awk '{print "  " $1 "  " $2}'
