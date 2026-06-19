#!/bin/bash
# Graceful cluster shutdown — preserves infrastructure and S3 data for later restore.
#
# Steps:
#   1. Ensure completeClusterTeardown=false in project_settings.ts
#   2. pulumi up (sync teardown flag to stack)
#   3. Trigger on-demand etcd snapshot to S3
#   4. Trigger Longhorn S3 backup for all volumes
#   5. Drain and cordon all nodes
#   6. pulumi dn (destroys servers/DNS/network, keeps S3 buckets)
#      + Set restoreClusterFromS3Backup=true in project_settings.ts
#
# After this script: run 'make create' to restore the cluster from S3 backup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    export PULUMI_CONFIG_PASSPHRASE
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster Shutdown — infrastructure preserved, data backed up      ║"
echo "║  Run 'make restore' afterwards to restore from S3.                ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
read -rp "Proceed with graceful shutdown? Type 'yes' to confirm: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Step 1a: ensure completeClusterTeardown=false ───────────────────────────────
current_teardown=$(pulumi config get completeClusterTeardown 2>/dev/null || echo "false")
if [[ "$current_teardown" == "true" ]]; then
    echo ""
    echo "Setting completeClusterTeardown: false in Pulumi config..."
    pulumi config set completeClusterTeardown false
    echo "  Done."

    # ── Step 1b: pulumi up (sync teardown flag to stack) ────────────────────────────
    echo ""
    echo "=== Step 2/7: pulumi up (sync stack) ==="
    CI=true pulumi up -y --skip-preview
else
    echo "completeClusterTeardown already false — no change needed."
fi


# ── Step 2b: reduce Longhorn replicas to 1 before backup ─────────────────────
# Ensures backups (and subsequent restores) never have stale multi-replica
# objects that over-schedule disk space on a single-node cluster.
echo ""
echo "=== Step 2b/7: Reduce Longhorn replicas to 1 ==="
echo "  Patching all volumes to numberOfReplicas=1..."
for v in $(kubectl get volumes.longhorn.io -n longhorn-system -o name 2>/dev/null); do
    kubectl -n longhorn-system patch "$v" --type=merge \
        -p '{"spec":{"numberOfReplicas":1}}' >/dev/null 2>&1 || true
done
echo "  Deleting extra replica objects..."
kubectl get replicas.longhorn.io -n longhorn-system -o json 2>/dev/null | python3 -c "
import json, sys
from collections import defaultdict
data = json.load(sys.stdin)
by_vol = defaultdict(list)
for r in data['items']:
    by_vol[r['spec']['volumeName']].append(r['metadata']['name'])
for vol, replicas in by_vol.items():
    for extra in replicas[1:]:
        print(extra)
" | xargs -r kubectl delete replica.longhorn.io -n longhorn-system
echo "  Longhorn replicas reduced to 1."

# ── Steps 3+4: etcd snapshot + Longhorn backup ────────────────────────────────
echo ""
echo "=== Steps 3-4/7: cluster backup (etcd + Longhorn) ==="
make backup

# ── Step 5: drain all nodes ────────────────────────────────────────────────────
echo ""
echo "=== Step 5/7: Drain all cluster nodes ==="

# Patch all PodDisruptionBudgets to minAvailable:0 so eviction isn't blocked
# when a replacement pod can't be scheduled on a cordoned node.
echo "  Disabling PodDisruptionBudgets cluster-wide..."
kubectl get pdb -A -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kubectl patch pdb "$name" -n "$ns" \
            --type=merge -p '{"spec":{"minAvailable":0,"maxUnavailable":null}}' \
            2>/dev/null || true
      done
echo "  Done."

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for NODE in $NODES; do
    echo "  Draining $NODE..."
    kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=300s \
        2>/dev/null \
    || kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --disable-eviction \
        --timeout=120s \
        2>/dev/null \
    || echo "  WARNING: drain failed for $NODE — continuing."
done
echo "  All nodes drained."

# ── Step 6: pulumi dn (tears down servers, keeps S3 since teardown=false) ─────
echo ""
echo "=== Step 6/6: pulumi dn (destroy servers, DNS, network — S3 buckets preserved) ==="
# Delete DNSEndpoint CRDs first so external-dns can remove the records from
# Hetzner DNS before the pod is killed. Records created via DNSEndpoint are
# outside Pulumi state and won't be cleaned up by pulumi destroy otherwise.
echo "  Deleting DNSEndpoints so external-dns can clean up Hetzner DNS records..."
kubectl delete dnsendpoint --all -A --ignore-not-found 2>/dev/null || true
echo "  Waiting for external-dns to confirm cleanup (up to 120s)..."
DEADLINE=$(($(date +%s) + 120))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns \
        --since=30s 2>/dev/null | grep -q "All changes applied"; then
        echo "  external-dns cleanup confirmed."
        break
    fi
    sleep 5
done
[ "$(date +%s)" -ge "$DEADLINE" ] && echo "  WARNING: timed out waiting for external-dns — continuing anyway."

bash "$SCRIPT_DIR/preDestroyCleanup.sh"

_force_finalize_terminating_namespaces() {
    kubectl get apiservice -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status!="True")) | .metadata.name' \
        | while read -r svc; do kubectl delete apiservice "$svc" --ignore-not-found 2>/dev/null || true; done
    kubectl get ns -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' \
        | while read -r ns; do
            echo "    Force-finalizing $ns..."
            kubectl get ns "$ns" -o json \
                | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
                | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
          done
}

_pulumi_destroy_with_retry() {
    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y && return 0

    echo "  First destroy pass failed — cleaning orphaned k8s namespace state and retrying..."
    _force_finalize_terminating_namespaces
    # Remove any namespace resources that errored because k8s already deleted them.
    pulumi stack --show-urns 2>/dev/null \
        | grep 'kubernetes:core/v1:Namespace' \
        | grep -oP 'urn:[^\s]+' \
        | while read -r urn; do
            ns_name=$(echo "$urn" | grep -oP '(?<=::)[^:]+$')
            if ! kubectl get ns "$ns_name" >/dev/null 2>&1; then
                echo "    Removing from state: $urn"
                pulumi state delete "$urn" --yes 2>/dev/null || true
            fi
          done

    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y && return 0

    echo "  Second destroy pass failed — force-finalizing again and removing all stuck namespace URNs..."
    _force_finalize_terminating_namespaces
    pulumi stack --show-urns 2>/dev/null \
        | grep 'kubernetes:core/v1:Namespace' \
        | grep -oP 'urn:[^\s]+' \
        | while read -r urn; do
            ns_name=$(echo "$urn" | grep -oP '(?<=::)[^:]+$')
            kubectl get ns "$ns_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Terminating' \
                && { echo "    Removing stuck Terminating ns from state: $urn"; pulumi state delete "$urn" --yes 2>/dev/null || true; } \
                || true
          done

    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y
}
_pulumi_destroy_with_retry

# ── Step 6 (final): set restoreClusterFromS3Backup=true in Pulumi config ───────
echo ""
echo "=== Step 6 (final): Set restoreClusterFromS3Backup=true ==="
pulumi config set restoreClusterFromS3Backup true
echo "  Done."

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster shutdown complete.                                       ║"
echo "║                                                                   ║"
echo "║  Infrastructure preserved. Data backed up to S3.                  ║"
echo "║  To restore: commit project_settings.ts, then run 'make restore'  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
