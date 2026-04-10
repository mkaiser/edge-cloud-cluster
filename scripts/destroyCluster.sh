#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if completeClusterTeardown is set to true in project_settings.ts
COMPLETE_TEARDOWN=$(grep -E 'completeClusterTeardown\s*:\s*true' "$SCRIPT_DIR/../project_settings.ts" || true)

if [ -n "$COMPLETE_TEARDOWN" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  WARNING: completeClusterTeardown = true                         ║"
    echo "║                                                                  ║"
    echo "║  This will PERMANENTLY DELETE:                                   ║"
    echo "║    • All Kubernetes resources                                    ║"
    echo "║    • The NFS SSD volume (volume-ssd-infra) and ALL its data      ║" 
    echo "║    • WIPE ALL DATA IN S3 buckets (*-gitlab, *-nextcloud, *-etcd) ║"
    echo "║    • Saved TLS certificates from Pulumi config                   ║"
    echo "║                                                                  ║"
    echo "║  This cannot be undone.                                          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
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
    echo "NFS volume and TLS certs will be preserved."
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
# S3 cleanup before destroy.
#
# completeClusterTeardown=true:
#   Full wipe of all buckets: edgecloud-gitlab, edgecloud-nextcloud, edgecloud-etcd.
#
# completeClusterTeardown=false:
#   Ask whether to prune old etcd snapshots, keeping the 3 newest.
#
# Credentials are read from Pulumi config (set via scripts/setPulumiSecrets.sh).
# ---------------------------------------------------------------------------
S3_ACCESS_KEY=$(pulumi config get hetznerS3AccessKey 2>/dev/null || true)
S3_SECRET_KEY=$(pulumi config get hetznerS3SecretKey 2>/dev/null || true)
S3_ENDPOINT="https://nbg1.your-objectstorage.com"
ETCD_BUCKET="edgecloud-etcd"
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
    echo "WARNING: S3 credentials not found in Pulumi config — skipping S3 cleanup."
    echo "         Run scripts/setPulumiSecrets.sh to configure them."
elif ! command -v aws >/dev/null 2>&1; then
    echo "WARNING: aws CLI not found — skipping S3 cleanup."
    echo "         Install awscli or run: pip install awscli"
else
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

    if [ -n "$COMPLETE_TEARDOWN" ]; then
        # Full wipe of everything
        ALL_BUCKETS="edgecloud-gitlab edgecloud-nextcloud edgecloud-headscale ${ETCD_BUCKET}"
        echo ""
        echo "Wiping all S3 buckets: ${ALL_BUCKETS}"
        for BUCKET in $ALL_BUCKETS; do
            echo "  Wiping s3://${BUCKET} ..."
            aws s3 rm "s3://${BUCKET}" \
                --recursive \
                --endpoint-url "$S3_ENDPOINT" \
                --quiet 2>/dev/null || echo "    (bucket empty or does not exist — skipping)"
        done
    else
        read -rp "Prune old etcd snapshots (keep 3 newest)? [y/N] " prune_etcd
        if [[ "$prune_etcd" =~ ^[Yy]$ ]]; then
            _prune_etcd
        else
            echo "Skipping etcd pruning."
        fi
    fi

    echo "S3 cleanup complete."
fi

echo ""
PULUMI_K8S_DELETE_UNREACHABLE=true pulumi destroy -y
