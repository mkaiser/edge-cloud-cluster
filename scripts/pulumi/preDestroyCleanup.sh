#!/bin/bash
# Pre-destroy cleanup: strip finalizers that would block namespace termination.
set -euo pipefail

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

# Remove all unavailable APIServices — their endpoints disappear after drain
# and block namespace garbage collection (NamespaceDeletionDiscoveryFailure).
echo "  Removing unavailable APIServices..."
kubectl get apiservice -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status!="True")) | .metadata.name' \
    | while read -r svc; do
        echo "    Deleting stale APIService: $svc"
        kubectl delete apiservice "$svc" --ignore-not-found 2>/dev/null || true
      done

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
