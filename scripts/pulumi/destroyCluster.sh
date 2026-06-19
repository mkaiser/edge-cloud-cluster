#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Step 0: double confirmation (skip with --yes or -y)
# ---------------------------------------------------------------------------
AUTO_YES=false
for arg in "$@"; do
    [[ "$arg" == "--yes" || "$arg" == "-y" ]] && AUTO_YES=true
done

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  WARNING: This will PERMANENTLY DESTROY the cluster               ║"
echo "║                                                                   ║"
echo "║  All Kubernetes resources, volumes, and S3 bucket contents        ║"
echo "║  will be deleted. This cannot be undone.                          ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$AUTO_YES" == "true" ]]; then
    echo "Auto-confirmed with --yes flag."
else
    read -rp "Are you sure? Type 'yes' to continue: " confirm1
    [[ "$confirm1" == "yes" ]] || { echo "Aborted."; exit 0; }

    read -rp "This is irreversible. Type 'yes' again to proceed: " confirm2
    [[ "$confirm2" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Pulumi precondition check
# ---------------------------------------------------------------------------
# The caller must have logged in to the backend and selected the stack beforehand
# (e.g. `source ./scripts/pulumi/initPulumiStack.sh`). We do NOT log in or select a
# stack here — just verify one is selected. A wrong/missing PULUMI_CONFIG_PASSPHRASE
# is caught by the pulumi up/destroy steps below. </dev/null avoids any prompt.
if ! pulumi stack --show-name </dev/null &>/dev/null; then
    echo "ERROR: No Pulumi stack selected (or not logged in to the backend)."
    echo "       Select the stack first, e.g.:"
    echo "         source ./scripts/pulumi/initPulumiStack.sh"
    echo "         # or: pulumi login file://... && pulumi stack select <stack>"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: ensure completeClusterTeardown=true
# ---------------------------------------------------------------------------

echo "Checking pulumi variable completeClusterTeardown"
echo ""

if [[ "$(pulumi config get completeClusterTeardown 2>/dev/null || echo "false")" != "true" ]]; then
    if [[ "$AUTO_YES" == "true" ]]; then
        echo "Auto-setting completeClusterTeardown: true and syncing the stack (--yes)."
    else
        read -rp "Changing completeClusterTeardown: true and run 'make up' to update the stack now? [y/n]: " change_answer
        if [[ ! "$change_answer" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    pulumi config set completeClusterTeardown true
    echo "Set completeClusterTeardown=true in Pulumi config — running pulumi up to sync stack..."
    CI=true pulumi up -y --skip-preview 
    echo "Stack synced."

fi

# ---------------------------------------------------------------------------
# Pre-destroy cleanup
# ---------------------------------------------------------------------------
bash "$SCRIPT_DIR/preDestroyCleanup.sh"

# ---------------------------------------------------------------------------
# Pulumi destroy
# ---------------------------------------------------------------------------
CI=true PULUMI_K8S_DELETE_UNREACHABLE=true timeout --foreground 2400 pulumi destroy -y --parallel 20 \
    || { echo "ERROR: pulumi destroy failed or timed out (exit $?)"; exit 1; }

# ---------------------------------------------------------------------------
# Clean up external-dns managed DNS records (not tracked in Pulumi state)
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/../environment/cleanExternalDnsRecords.sh"

# ---------------------------------------------------------------------------
# Delete S3 buckets (including ArgoCD-owned app buckets not managed by Pulumi)
# ---------------------------------------------------------------------------
# Runs AFTER pulumi destroy: Pulumi already removed its own buckets, so this
# wipes whatever remains (e.g. zulip app buckets + any orphans). With --yes,
# delete every remaining bucket without prompting; otherwise go interactive.
echo ""
echo "=== Deleting remaining S3 buckets ==="
if [[ "$AUTO_YES" == "true" ]]; then
    bash "$SCRIPT_DIR/../environment/deleteS3Buckets.sh" --all-yes \
        || echo "WARNING: S3 bucket wipe failed (continuing)."
else
    bash "$SCRIPT_DIR/../environment/deleteS3Buckets.sh" \
        || echo "WARNING: S3 bucket cleanup skipped/failed (continuing)."
fi

# ---------------------------------------------------------------------------
# set the dangerous completeClusterTeardown back to false to prevent accidental cluster teardown in the future
# ---------------------------------------------------------------------------
echo "Setting completeClusterTeardown back to false in Pulumi config to prevent accidental cluster teardown in the future..."
pulumi config set completeClusterTeardown false