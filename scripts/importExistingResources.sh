#!/bin/bash
# Import Hetzner resources that already exist into Pulumi state.
# Run this before 'pulumi up' when deploying on top of an existing Hetzner environment
# (e.g. after a partial teardown where the Pulumi state was reset but cloud resources remain).
#
# Idempotent: skips resources that are already in state with a valid ID.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    echo "ERROR: PULUMI_CONFIG_PASSPHRASE is not set. Run 'source scripts/setPulumiPassphrase.sh' first."
    exit 1
fi

export HCLOUD_TOKEN="${HCLOUD_TOKEN:-$(pulumi config get hcloudToken 2>/dev/null || true)}"
DNS_TOKEN="${HETZNER_DNS_TOKEN:-}"

if [ -z "$HCLOUD_TOKEN" ]; then
    echo "ERROR: Could not get hcloudToken from Pulumi config."
    exit 1
fi

# ---------------------------------------------------------------------------
# Usage: import_if_missing <type> <name> <hetzner-id> [--parent <parent-urn>]
import_if_missing() {
    local type="$1" name="$2" id="$3"
    shift 3
    local extra_args=("$@")

    # Determine expected URN suffix (with or without parent component)
    local state
    state=$(pulumi stack export 2>/dev/null)

    # Remove any stale top-level entry (wrong parent) that would block the import
    local stale_urn
    stale_urn=$(echo "$state" | python3 -c "
import json,sys
state=json.load(sys.stdin)
for r in state.get('deployment',{}).get('resources',[]):
    urn = r.get('urn','')
    rid = r.get('id','')
    # Top-level (no component \$): type matches and name matches but no parent segment
    if '${type}' in r.get('type','') and urn.endswith('::${name}') and '\$' not in urn.split('::')[-2]:
        if rid != '${id}':
            print(urn)
        break
" 2>/dev/null || true)

    if [ -n "$stale_urn" ]; then
        echo "  CLEANUP: removing stale top-level state entry for $name"
        pulumi state unprotect "$stale_urn" --yes 2>/dev/null || true
        pulumi state delete "$stale_urn" --yes
    fi

    # Check if already correctly in state
    local current_id
    current_id=$(echo "$state" | python3 -c "
import json,sys
state=json.load(sys.stdin)
for r in state.get('deployment',{}).get('resources',[]):
    urn = r.get('urn','')
    if '${type}' in r.get('type','') and urn.endswith('::${name}'):
        print(r.get('id',''))
        break
" 2>/dev/null || true)

    if [ "$current_id" = "$id" ]; then
        echo "  SKIP: $name already in state with correct ID $id"
        return
    fi

    echo "  IMPORT: $name ($type) <- $id"
    if ! pulumi import "$type" "$name" "$id" --yes --skip-preview "${extra_args[@]}"; then
        echo "  ERROR: import of $name failed."
        exit 1
    fi
}

echo "=== Importing existing Hetzner resources into Pulumi state ==="

# --- Network ---
NET_ID=$(hcloud network list -o json 2>/dev/null | \
    python3 -c "import json,sys; nets=[n for n in json.load(sys.stdin) if n['name']=='private-network']; print(nets[0]['id'] if nets else '')" 2>/dev/null || true)
if [ -n "$NET_ID" ]; then
    import_if_missing "hcloud:index/network:Network" "edgecloudinfra-net" "$NET_ID" \
        --parent "urn:pulumi:mystack::edgecloudinfra::pxCloud:infra:Network::network"
else
    echo "  SKIP: network private-network not found in Hetzner"
fi

# --- SPF TXT record ---
if [ -z "$DNS_TOKEN" ]; then
    echo "  SKIP: SPF record — set HETZNER_DNS_TOKEN to enable auto-import"
else
    ZONE_ID=$(curl -sf -H "Auth-API-Token: ${DNS_TOKEN}" \
        "https://dns.hetzner.com/api/v1/zones?name=cape-project.eu" | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['zones'][0]['id'])" 2>/dev/null || true)
    if [ -n "$ZONE_ID" ]; then
        SPF_ID=$(curl -sf -H "Auth-API-Token: ${DNS_TOKEN}" \
            "https://dns.hetzner.com/api/v1/records?zone_id=${ZONE_ID}" | \
            python3 -c "
import json,sys
for r in json.load(sys.stdin)['records']:
    if r['type']=='TXT' and r['name']=='@' and 'spf1' in r['value'] and 'mail.your-server.de' in r['value']:
        print(r['id'])
        break
" 2>/dev/null || true)
        if [ -n "$SPF_ID" ]; then
            import_if_missing "hcloud:index/zoneRecord:ZoneRecord" "spf-txt" "$SPF_ID"
        else
            echo "  SKIP: SPF record not found in DNS zone"
        fi
    fi
fi

echo "=== Done. Run 'pulumi up' to deploy. ==="
