#!/bin/bash
# Delete all S3 bucket contents and the buckets defined in project_settings.ts.
# Credentials are read from Pulumi config (hetznerS3AccessKey / hetznerS3SecretKey).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETTINGS="$REPO_ROOT/project_settings.ts"

# ── Parse bucket names and endpoint from project_settings.ts ──────────────────
ENDPOINT=$(grep 'baseEndpoint' "$SETTINGS" | sed -E "s/.*baseEndpoint:[[:space:]]*\"([^\"]+)\".*/\1/")
BUCKET_NAMES=$(grep -E 'key:.*name:.*location:' "$SETTINGS" \
    | sed -E "s/.*name:[[:space:]]*\"([^\"]+)\".*/\1/")

if [ -z "$ENDPOINT" ] || [ -z "$BUCKET_NAMES" ]; then
    echo "ERROR: Could not parse S3 config from $SETTINGS"
    exit 1
fi

S3_URL="https://${ENDPOINT}"

# ── Get S3 credentials from Pulumi ────────────────────────────────────────────
if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    export PULUMI_CONFIG_PASSPHRASE
fi

pulumi login "file://${REPO_ROOT}/.pulumi-state" --non-interactive &>/dev/null
pulumi stack select mystack &>/dev/null

S3_ACCESS=$(pulumi config get hetznerS3AccessKey)
S3_SECRET=$(pulumi config get hetznerS3SecretKey)

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  WARNING: This permanently deletes all S3 bucket contents         ║"
echo "║  and the buckets themselves. This cannot be undone.               ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Endpoint : $S3_URL"
echo "Buckets  :"
for B in $BUCKET_NAMES; do
    echo "  - $B"
done
echo ""
read -rp "Type 'yes' to confirm deletion of ALL buckets and their contents: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Delete ────────────────────────────────────────────────────────────────────
export AWS_ACCESS_KEY_ID="$S3_ACCESS"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET"

for BUCKET in $BUCKET_NAMES; do
    echo ""
    echo "── $BUCKET ──"
    if AWS_ACCESS_KEY_ID="$S3_ACCESS" AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
        aws s3 ls "s3://${BUCKET}" --endpoint-url "$S3_URL" &>/dev/null; then
        echo "  Emptying..."
        aws s3 rm "s3://${BUCKET}" --recursive --endpoint-url "$S3_URL" 2>/dev/null || true
        echo "  Deleting bucket..."
        aws s3 rb "s3://${BUCKET}" --endpoint-url "$S3_URL" 2>/dev/null \
            && echo "  Deleted." \
            || echo "  WARNING: bucket delete failed (may already be gone)."
    else
        echo "  Not found — skipping."
    fi
done

echo ""
echo "Done."
