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
#   7. Set restoreClusterFromS3Backup=true in project_settings.ts
#
# After this script: run 'make create' to restore the cluster from S3 backup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$SCRIPT_DIR/../../project_settings.ts"

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
if grep -qE 'completeClusterTeardown\s*:\s*true' "$SETTINGS"; then
    echo ""
    echo "Setting completeClusterTeardown: false in project_settings.ts..."
    sed -i 's/completeClusterTeardown\s*:\s*true/completeClusterTeardown: false/' "$SETTINGS"
    echo "  Done."

    # ── Step 1b: pulumi up (sync teardown flag to stack) ────────────────────────────
    echo ""
    echo "=== Step 2/7: pulumi up (sync stack) ==="
    CI=true pulumi up -y
else
    echo "completeClusterTeardown already false — no change needed."
fi


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

# ── Step 5c: delete external-dns managed DNS records ──────────────────────────
echo ""
echo "=== Step 5c/7: Delete external-dns managed DNS records ==="
"$SCRIPT_DIR/../misc/cleanExternalDnsRecords.sh"

# ── Step 6: pulumi dn (tears down servers, keeps S3 since teardown=false) ─────
echo ""
echo "=== Step 6/7: pulumi dn (destroy servers, DNS, network — S3 buckets preserved) ==="
# Strip ArgoCD finalizers so the argocd namespace doesn't hang in Terminating.
if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "  Stripping ArgoCD application finalizers..."
    kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null \
        | while read -r r; do
            kubectl patch "$r" -n argocd --type=merge \
                -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
          done
    kubectl delete applications.argoproj.io --all -n argocd \
        --force --grace-period=0 2>/dev/null || true
    echo "  Done."
fi

# Remove stale metrics-server APIService — its endpoint disappears after drain
# and blocks namespace garbage collection (NamespaceDeletionDiscoveryFailure).
echo "  Removing stale metrics APIService..."
kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found 2>/dev/null || true

# Force-finalize any namespace already stuck in Terminating before pulumi destroy.
echo "  Force-finalizing Terminating namespaces..."
kubectl get ns -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' \
    | while read -r ns; do
        echo "    Finalizing $ns..."
        kubectl get ns "$ns" -o json \
            | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
            | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
      done
echo "  Done."

_pulumi_destroy_with_retry() {
    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y && return 0

    echo "  First destroy pass failed — cleaning orphaned k8s namespace state and retrying..."
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

    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y
}
_pulumi_destroy_with_retry

# ── Step 7: set restoreClusterFromS3Backup=true in Pulumi config ───────────────
echo ""
echo "=== Step 7/7: Set restoreClusterFromS3Backup=true ==="
pulumi config set restoreClusterFromS3Backup true
echo "  Done."

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster shutdown complete.                                       ║"
echo "║                                                                   ║"
echo "║  Infrastructure preserved. Data backed up to S3.                  ║"
echo "║  To restore: commit project_settings.ts, then run 'make restore'  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
