#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if completeClusterTeardown is set to true in project_settings.ts
COMPLETE_TEARDOWN=$(grep -E 'completeClusterTeardown\s*:\s*true' "$SCRIPT_DIR/../project_settings.ts" || true)

# ---------------------------------------------------------------------------
# Verify project_settings.ts matches the last-deployed Pulumi stack state.
# The delete command of ensure-s3-bucket-etcd encodes the deployed value:
#   "aws s3 rb ..." → stack was deployed with completeClusterTeardown=true
#   "true"          → stack was deployed with completeClusterTeardown=false
# ---------------------------------------------------------------------------
STACK_STATE="$SCRIPT_DIR/../.pulumi-state/.pulumi/stacks/edgecloudinfra/mystack.json"
if [ -f "$STACK_STATE" ]; then
    STACK_DELETE_CMD=$(python3 -c "
import json, sys
try:
    state = json.load(open('$STACK_STATE'))
    resources = state.get('checkpoint', {}).get('latest', {}).get('resources', [])
    for r in resources:
        if 'ensure-s3-bucket-etcd' in r.get('urn', ''):
            print(r.get('inputs', {}).get('delete', ''))
            sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null)

    if [ "$STACK_DELETE_CMD" != "NOT_FOUND" ] && [ -n "$STACK_DELETE_CMD" ]; then
        if echo "$STACK_DELETE_CMD" | grep -q "aws s3 rb"; then
            STACK_TEARDOWN="true"
        else
            STACK_TEARDOWN="false"
        fi

        LOCAL_TEARDOWN="false"
        [ -n "$COMPLETE_TEARDOWN" ] && LOCAL_TEARDOWN="true"

        if [ "$LOCAL_TEARDOWN" != "$STACK_TEARDOWN" ]; then
            echo ""
            echo "╔═══════════════════════════════════════════════════════════════════╗"
            echo "║  WARNING: completeClusterTeardown mismatch                        ║"
            echo "╠═══════════════════════════════════════════════════════════════════╣"
            printf "║  project_settings.ts : completeClusterTeardown = %-18s║\n" "$LOCAL_TEARDOWN"
            printf "║  Pulumi stack state  : completeClusterTeardown = %-18s║\n" "$STACK_TEARDOWN"
            echo "║                                                                   ║"
            echo "║  The destroy hooks in the stack reflect the OLD setting.          ║"
            echo "║  'pulumi up' must run first to update them before destroy.        ║"
            echo "╚═══════════════════════════════════════════════════════════════════╝"
            echo ""
            read -rp "Run 'pulumi up' now to sync the stack? [y/n]: " sync_answer
            if [[ "$sync_answer" =~ ^[Yy]$ ]]; then
                echo "Running pulumi up..."
                CI=true pulumi up -y
                echo "Stack synced. Continuing with destroy..."
            else
                echo "Aborted. Re-run after manually running 'pulumi up'."
                exit 2
            fi
        fi
    fi
fi

if [ -n "$COMPLETE_TEARDOWN" ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║  WARNING: completeClusterTeardown = true                          ║"
    echo "║                                                                   ║"
    echo "║  This will PERMANENTLY DELETE:                                    ║"
    echo "║    • All Kubernetes resources                                     ║"
    echo "║    • All S3 buckets and their contents (via pulumi destroy)       ║"
    echo "║    • Saved TLS certificates from Pulumi config                    ║"
    echo "║                                                                   ║"
    echo "║  This cannot be undone.                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    read -rp "Are you sure you want to erase EVERYTHING? Type 'yes' to confirm: " confirm1
    if [[ "$confirm1" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi

    read -rp "This is irreversible. Type 'yes' again to proceed: " confirm2
    if [[ "$confirm2" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Proceeding with complete teardown..."
else
    echo ""
    echo "completeClusterTeardown = false — cluster recreation mode."
    echo ""
    echo "To do a full wipe instead, set completeClusterTeardown: true"
    echo "in project_settings.ts before running this script."
    echo ""
    read -rp "Proceed with cluster destroy? Type 'yes' to confirm: " confirm1
    if [[ "$confirm1" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Remove hetzner-s3 secret to unblock Pulumi destroy (it has a finalizer)
if kubectl get secret hetzner-s3 -n argocd >/dev/null 2>&1; then
    kubectl delete secret hetzner-s3 -n argocd --wait=false 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# S3 etcd snapshot pruning (completeClusterTeardown=false only).
# Full bucket deletion is handled by `pulumi destroy` when
# completeClusterTeardown=true (see storage.ts ensure-s3-bucket-* resources).
#
# Values below must match objectStorage.buckets in project_settings.ts.
# Credentials are read from Pulumi config (set via scripts/setPulumiSecrets.sh).
# ---------------------------------------------------------------------------
S3_ACCESS_KEY=$(pulumi config get hetznerS3AccessKey 2>/dev/null || true)
S3_SECRET_KEY=$(pulumi config get hetznerS3SecretKey 2>/dev/null || true)
# Must match project_settings.ts objectStorage.buckets + baseEndpoint
ETCD_BUCKET="edgecloud-etcd"
S3_ENDPOINT="https://nbg1.your-objectstorage.com"
ETCD_FOLDER="k3s-etcd"

_prune_etcd() {
    local keep=3
    echo ""
    echo "Pruning old etcd snapshots in s3://${ETCD_BUCKET}/${ETCD_FOLDER}/ (keeping newest ${keep})..."
    SNAPSHOTS=$(aws s3 ls "s3://${ETCD_BUCKET}/${ETCD_FOLDER}/" \
        --endpoint-url "$S3_ENDPOINT" 2>/dev/null \
        | sort -k1,2 | awk '{print $4}' | grep -v '/$' || true)
    TOTAL=$(echo "$SNAPSHOTS" | grep -c . || true)
    if [ "${TOTAL:-0}" -le "$keep" ]; then
        echo "  Only ${TOTAL} snapshot(s) found — nothing to prune."
    else
        DELETE_COUNT=$(( TOTAL - keep ))
        echo "$SNAPSHOTS" | head -n "$DELETE_COUNT" | while read -r KEY; do
            echo "  Deleting s3://${ETCD_BUCKET}/${ETCD_FOLDER}/${KEY}"
            aws s3 rm "s3://${ETCD_BUCKET}/${ETCD_FOLDER}/${KEY}" \
                --endpoint-url "$S3_ENDPOINT" --quiet 2>/dev/null || true
        done
        echo "  Pruned ${DELETE_COUNT} old snapshot(s), kept ${keep}."
    fi
}

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo "WARNING: S3 credentials not found in Pulumi config — skipping etcd pruning."
    echo "         Run scripts/setPulumiSecrets.sh to configure them."
elif ! command -v aws >/dev/null 2>&1; then
    echo "WARNING: aws CLI not found — skipping etcd pruning."
    echo "         Install awscli or run: pip install awscli"
else
    if [ -n "$COMPLETE_TEARDOWN" ]; then
        echo "Bucket deletion will be performed by 'pulumi destroy' (completeClusterTeardown=true)."
    else
        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
        read -rp "Prune etcd snapshots: [y] keep 3 newest, [n] keep all: " etcd_cleanup_mode
        case "${etcd_cleanup_mode}" in
            y|Y) _prune_etcd ;;
            *)   echo "Keeping all etcd snapshots." ;;
        esac
    fi
fi



# Strip ArgoCD finalizers so the argocd namespace doesn't get stuck in Terminating.
# ArgoCD adds finalizers to Application resources; once its controllers are gone
# nothing processes them and the namespace hangs indefinitely waiting for cleanup.
if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "Stripping ArgoCD application finalizers..."
    kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null \
        | while read -r r; do
            kubectl patch "$r" -n argocd --type=merge \
                -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
    kubectl delete applications.argoproj.io --all -n argocd \
        --force --grace-period=0 2>/dev/null || true
    kubectl delete jobs --all -n argocd \
        --force --grace-period=0 2>/dev/null || true
    echo "ArgoCD finalizers cleared."
fi

CI=true PULUMI_K8S_DELETE_UNREACHABLE=true timeout --foreground 900 pulumi destroy -y --parallel 20 \
    || { echo "ERROR: pulumi destroy failed or timed out (exit $?)"; exit 1; }
