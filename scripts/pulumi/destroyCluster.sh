#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_SETTINGS="$SCRIPT_DIR/../../project_settings.ts"

# ---------------------------------------------------------------------------
# Step 0: double confirmation
# ---------------------------------------------------------------------------
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  WARNING: This will PERMANENTLY DESTROY the cluster               ║"
echo "║                                                                   ║"
echo "║  All Kubernetes resources, volumes, and S3 bucket contents        ║"
echo "║  will be deleted. This cannot be undone.                          ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
read -rp "Are you sure? Type 'yes' to continue: " confirm1
[[ "$confirm1" == "yes" ]] || { echo "Aborted."; exit 0; }

read -rp "This is irreversible. Type 'yes' again to proceed: " confirm2
[[ "$confirm2" == "yes" ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Pulumi init
# ---------------------------------------------------------------------------
if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    source "$SCRIPT_DIR/setPulumiPassphrase.sh"
fi
pulumi login "file://$(cd "$SCRIPT_DIR/../.." && pwd)/.pulumi-state" --non-interactive &>/dev/null
pulumi stack select mystack &>/dev/null

# ---------------------------------------------------------------------------
# Step 1: ensure completeClusterTeardown=true
# ---------------------------------------------------------------------------
if ! grep -qE 'completeClusterTeardown\s*:\s*true' "$PROJECT_SETTINGS"; then
    echo ""
    echo "project_settings.ts has set completeClusterTeardown: false"
    echo "completeClusterTeardown must be set to true to ensure all cluster resources are deleted properly, including S3 buckets."
    echo ""
    read -rp "Set completeClusterTeardown: true and run 'make up' now? [y/n]: " change_answer
    if [[ ! "$change_answer" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    sed -i 's/completeClusterTeardown\s*:\s*false/completeClusterTeardown: true/' "$PROJECT_SETTINGS"
    echo "Updated project_settings.ts — running pulumi up to sync stack..."
    CI=true pulumi up -y
    echo "Stack synced."
else
    # Already true — check stack state matches (protect against manual edits not yet deployed)
    STACK_STATE="$SCRIPT_DIR/../../.pulumi-state/.pulumi/stacks/edgecloudinfra/mystack.json"
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
            if ! echo "$STACK_DELETE_CMD" | grep -q "aws s3 rb"; then
                echo ""
                echo "WARNING: Stack was last deployed with completeClusterTeardown=false."
                echo "Pulumi destroy hooks won't delete S3 buckets unless the stack is redeployed."
                echo ""
                read -rp "Run 'pulumi up' now to sync the stack? [y/n]: " sync_answer
                if [[ "$sync_answer" =~ ^[Yy]$ ]]; then
                    CI=true pulumi up -y
                    echo "Stack synced."
                else
                    echo "Aborted. Re-run after manually running 'pulumi up'."
                    exit 2
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Pulumi destroy
# ---------------------------------------------------------------------------
CI=true PULUMI_K8S_DELETE_UNREACHABLE=true timeout --foreground 2400 pulumi destroy -y --parallel 20 \
    || { echo "ERROR: pulumi destroy failed or timed out (exit $?)"; exit 1; }

# ---------------------------------------------------------------------------
# Clean up external-dns managed DNS records (not tracked in Pulumi state)
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/../misc/cleanExternalDnsRecords.sh"
