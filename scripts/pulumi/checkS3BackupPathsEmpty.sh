#!/bin/bash
# checkS3BackupPathsEmpty.sh — fail if any CNPG barman backup destination already
# holds objects, BEFORE a fresh `initdb` cluster bring-up.
#
# WHY: every CNPG cluster (headscale, authentik, gitlab, litellm, nextcloud,
# open-webui, rallly, guacamole, xwiki) archives WAL + base backups to a FIXED
# S3 destinationPath keyed on general.name — subdomain-STABLE, so an `eccN`
# recreate reuses the SAME path as the destroyed cluster. On `initdb` bootstrap
# CNPG runs `barman-cloud-check-wal-archive`, which REQUIRES the destination to
# be empty ("Expected empty archive"). A leftover prefix makes that check fail
# forever → continuous WAL archiving never starts → Postgres cannot recycle WAL
# → the PVC fills → the cluster CrashLoops. For headscale that took the whole
# WireGuard mesh down (see doc/network-firewall.md / cloud-mesh-architecture.md).
#
# This gate runs ONLY on fresh create (bootstrap.sh, before phase_create fresh).
# It does NOT touch etcd / longhorn-backup buckets — those legitimately persist
# for `make restore`.
#
# Wipe the offending paths with: bash scripts/environment/deleteS3Buckets.sh
# (or, once implemented, a per-prefix wipe). Then re-run `make bootstrap`.
#
# Exit 0 = all backup paths empty (safe to create). Exit 1 = non-empty (abort).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETTINGS="$REPO_ROOT/project_settings.ts"

# ── Endpoint / region from project_settings.ts (same idiom as deleteS3Buckets.sh) ──
ENDPOINT=$(perl -ne 'print "$1\n" and exit if /baseEndpoint:\s*"([^"]+)"/' "$SETTINGS")
: "${ENDPOINT:?Could not parse baseEndpoint from $SETTINGS}"
S3_URL="https://${ENDPOINT}"
REGION="${ENDPOINT%%.*}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: 'aws' CLI not found." >&2; exit 1; }

# ── S3 credentials from the Pulumi stack (bootstrap has already run init_pulumi,
# so the passphrase + stack are loaded; still guard for standalone use). ──
if ! pulumi stack --show-name >/dev/null 2>&1; then
    if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
        echo "ERROR: Pulumi stack not selected and PULUMI_CONFIG_PASSPHRASE unset." >&2
        exit 1
    fi
    pulumi login "file://${REPO_ROOT}/.pulumi-state" --non-interactive >/dev/null 2>&1
    pulumi stack select mystack >/dev/null 2>&1
fi
AWS_ACCESS_KEY_ID="$(pulumi config get hetznerS3AccessKey)"
AWS_SECRET_ACCESS_KEY="$(pulumi config get hetznerS3SecretKey)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || {
    echo "ERROR: could not read Hetzner S3 credentials from Pulumi config" >&2; exit 1; }

# ── Discover the live barman destinations from the GENERATED postgres.yaml
# manifests (BUCKET_NAME already substituted; .template files are skipped). Each
# `destinationPath: "s3://bucket[/prefix]"` becomes a bucket + key-prefix pair. ──
mapfile -t DEST_PATHS < <(
    grep -rhoE --include='*.yaml' 'destinationPath:[[:space:]]*"s3://[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?"' \
        "$REPO_ROOT/deployment" 2>/dev/null \
        | sed -E 's/.*"s3:\/\/([^"]+)".*/\1/' \
        | grep -v 'BUCKET_NAME' \
        | sort -u
)
[ "${#DEST_PATHS[@]}" -gt 0 ] || { echo "ERROR: no barman destinationPaths found under deployment/." >&2; exit 1; }

# Count objects (incl. all versions + delete markers) under bucket/prefix. A
# prefix that lists nothing is "empty" for barman's purposes.
prefix_object_count() {
    local bucket="$1" prefix="$2" token page n count=0
    local args=(--bucket "$bucket" --endpoint-url "$S3_URL" --max-items 1000 --output json)
    [ -n "$prefix" ] && args+=(--prefix "$prefix")
    token=""
    while true; do
        if [ -n "$token" ]; then
            page=$(aws s3api list-object-versions "${args[@]}" --starting-token "$token" 2>/dev/null) || break
        else
            page=$(aws s3api list-object-versions "${args[@]}" 2>/dev/null) || break
        fi
        [ -n "$page" ] || break
        n=$(printf '%s' "$page" | jq '[ (.Versions // []), (.DeleteMarkers // []) | .[] ] | length')
        count=$((count + n))
        token=$(printf '%s' "$page" | jq -r '.NextToken // empty')
        [ -n "$token" ] || break
    done
    printf '%s\n' "$count"
}

echo "── checking CNPG S3 backup destinations are empty (fresh initdb needs this) ──"
NONEMPTY=()
for dp in "${DEST_PATHS[@]}"; do
    bucket="${dp%%/*}"
    prefix=""
    [ "$dp" != "$bucket" ] && prefix="${dp#*/}"
    # A missing bucket is fine — nothing to collide with; treat as empty.
    if ! aws s3api head-bucket --bucket "$bucket" --endpoint-url "$S3_URL" >/dev/null 2>&1; then
        printf '  ok    s3://%s  (bucket absent)\n' "$dp"
        continue
    fi
    count=$(prefix_object_count "$bucket" "$prefix")
    if [ "$count" -gt 0 ]; then
        printf '  FAIL  s3://%s  (%s objects)\n' "$dp" "$count"
        NONEMPTY+=("$dp")
    else
        printf '  ok    s3://%s  (empty)\n' "$dp"
    fi
done

if [ "${#NONEMPTY[@]}" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: ${#NONEMPTY[@]} CNPG backup destination(s) are NOT empty:" >&2
    printf '  s3://%s\n' "${NONEMPTY[@]}" >&2
    echo "" >&2
    echo "A fresh initdb cluster requires empty barman destinations, or WAL archiving" >&2
    echo "never starts and the Postgres PVCs fill (headscale outage). Wipe them with:" >&2
    echo "  bash scripts/environment/deleteS3Buckets.sh" >&2
    echo "then re-run 'make bootstrap'." >&2
    exit 1
fi

echo "── all CNPG backup destinations empty — safe to create ────────────────────"
