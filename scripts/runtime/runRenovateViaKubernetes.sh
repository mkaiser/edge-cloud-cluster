#!/usr/bin/env bash
# Trigger an on-demand Renovate run instead of waiting for the 2-hourly CronJob.
# Creates a one-off Job from the 'renovate' CronJob and (by default) follows its logs.
#
# Usage:
#   ./scripts/misc/runRenovateNow.sh            # run + follow logs
#   ./scripts/misc/runRenovateNow.sh --no-logs  # run, don't follow
#
# Requires a working kubeconfig (KUBECONFIG or ~/.kube/config; falls back to
# scripts/runtime/getKubeConfig.sh if the cluster is unreachable).
set -euo pipefail

NAMESPACE="renovate"
CRONJOB="renovate"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FOLLOW=1
[ "${1:-}" = "--no-logs" ] && FOLLOW=0

CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
RENOVATE_FORCE="{\"baseBranchPatterns\":[\"$CURRENT_BRANCH\"]}"
echo "Base branch: $CURRENT_BRANCH"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if ! kubectl get cronjob "$CRONJOB" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Renovate CronJob not reachable; trying to fetch kubeconfig..."
    bash "$REPO_ROOT/scripts/runtime/getKubeConfig.sh" || true
    kubectl get cronjob "$CRONJOB" -n "$NAMESPACE" >/dev/null 2>&1 \
        || { echo "ERROR: CronJob $CRONJOB not found in namespace $NAMESPACE."; exit 1; }
fi

JOB="renovate-manual-$(date +%Y%m%d-%H%M%S)"
echo "Creating one-off Renovate job '$JOB' from cronjob/$CRONJOB ..."
kubectl create job "$JOB" --from="cronjob/$CRONJOB" -n "$NAMESPACE" \
    --dry-run=client -o json \
  | jq --arg force "$RENOVATE_FORCE" \
       '(.spec.template.spec.containers[] | select(.name == "renovate") | .env) += [{"name": "RENOVATE_FORCE", "value": $force}]' \
  | kubectl create -f -

echo "Waiting for the job pod to start..."
kubectl wait --for=condition=ready pod -l "job-name=$JOB" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

if [ "$FOLLOW" -eq 1 ]; then
    echo "Following logs (Ctrl-C to stop; the job keeps running):"
    kubectl logs -f -l "job-name=$JOB" -n "$NAMESPACE" --tail=-1 || true
    echo ""
    kubectl get job "$JOB" -n "$NAMESPACE"
else
    echo "Job created. Inspect with:"
    echo "  kubectl logs -f -l job-name=$JOB -n $NAMESPACE"
fi
