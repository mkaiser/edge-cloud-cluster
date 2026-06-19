#!/bin/bash
# Interactive S3 bucket deletion for the Hetzner Object Storage account.
#
# Unifies the former scripts/misc/deleteS3Buckets.sh (parsed names from
# project_settings.ts) and scripts/runtime/wipeAppBuckets.sh (app buckets).
# Instead of a hardcoded list it DISCOVERS the live buckets via the S3
# ListBuckets API against the Hetzner endpoint, then lets you delete all of
# them or pick individual ones. The list refreshes after each action until you
# cancel or no buckets remain.
#
# Credentials come from the selected Pulumi stack
# (hetznerS3AccessKey / hetznerS3SecretKey).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETTINGS="$REPO_ROOT/project_settings.ts"

# --all-yes / --yes / -y : delete EVERY bucket with no prompt (for automated
# teardown, e.g. destroyCluster.sh --yes). Otherwise run interactively.
ALL_YES=false
for arg in "$@"; do
    case "$arg" in
        --all-yes | --yes | -y) ALL_YES=true ;;
    esac
done

# ── Endpoint from project_settings.ts ────────────────────────────────────────
ENDPOINT=$(perl -ne 'print "$1\n" and exit if /baseEndpoint:\s*"([^"]+)"/' "$SETTINGS")
: "${ENDPOINT:?Could not parse baseEndpoint from $SETTINGS}"
S3_URL="https://${ENDPOINT}"
REGION="${ENDPOINT%%.*}"   # e.g. "nbg1" from "nbg1.your-objectstorage.com"

# ── Tooling ──────────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { echo "ERROR: 'aws' CLI not found." >&2; exit 1; }

# ── S3 credentials from the Pulumi stack ─────────────────────────────────────
if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    if [ "$ALL_YES" = true ]; then
        echo "ERROR: PULUMI_CONFIG_PASSPHRASE must be set in --all-yes mode." >&2
        exit 1
    fi
    read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    export PULUMI_CONFIG_PASSPHRASE
fi
pulumi login "file://${REPO_ROOT}/.pulumi-state" --non-interactive &>/dev/null
pulumi stack select mystack &>/dev/null
AWS_ACCESS_KEY_ID="$(pulumi config get hetznerS3AccessKey)"
AWS_SECRET_ACCESS_KEY="$(pulumi config get hetznerS3SecretKey)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || {
    echo "ERROR: could not read Hetzner S3 credentials from Pulumi config" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────
list_buckets() {
    aws s3api list-buckets --endpoint-url "$S3_URL" \
        --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

confirm_double() {
    local a b
    read -rp "$1 Type 'yes' to confirm: " a; [ "$a" = "yes" ] || { echo "  Aborted."; return 1; }
    read -rp "  This is irreversible. Type 'yes' again: " b; [ "$b" = "yes" ] || { echo "  Aborted."; return 1; }
    return 0
}

delete_bucket() {
    local B="$1"
    echo "── $B ──"
    echo "  Emptying..."
    aws s3 rm "s3://${B}" --recursive --endpoint-url "$S3_URL" 2>/dev/null || true
    echo "  Deleting bucket..."
    aws s3 rb "s3://${B}" --endpoint-url "$S3_URL" 2>/dev/null \
        && echo "  Deleted." \
        || echo "  WARNING: bucket delete failed (may be non-empty or already gone)."
}

# ── Non-interactive: delete ALL buckets, no prompt (--all-yes) ───────────────
if [ "$ALL_YES" = true ]; then
    mapfile -t BUCKETS < <(list_buckets)
    if [ "${#BUCKETS[@]}" -eq 0 ]; then
        echo "No buckets to delete at $S3_URL."
        exit 0
    fi
    echo "Deleting ALL ${#BUCKETS[@]} bucket(s) at $S3_URL without prompt (--all-yes)..."
    for b in "${BUCKETS[@]}"; do delete_bucket "$b"; done
    echo "Done."
    exit 0
fi

# ── Interactive loop ─────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  S3 bucket deletion — Hetzner Object Storage ($S3_URL)"
echo "║  Permanently deletes bucket contents AND the buckets. Irreversible. ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"

while true; do
    mapfile -t BUCKETS < <(list_buckets)
    if [ "${#BUCKETS[@]}" -eq 0 ]; then
        echo ""
        echo "No buckets remain at $S3_URL."
        break
    fi

    echo ""
    echo "Buckets at $S3_URL:"
    i=1
    for b in "${BUCKETS[@]}"; do
        printf "  %2d) %s\n" "$i" "$b"
        i=$((i + 1))
    done
    echo ""
    read -rp "Enter a number to delete one, [A] delete all, [C] cancel: " choice

    case "$choice" in
        [Cc])
            echo "Cancelled."
            break
            ;;
        [Aa])
            if confirm_double "Delete ALL ${#BUCKETS[@]} bucket(s) and their contents?"; then
                for b in "${BUCKETS[@]}"; do delete_bucket "$b"; done
            fi
            ;;
        ''|*[!0-9]*)
            echo "Invalid input — enter a number, A, or C."
            ;;
        *)
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#BUCKETS[@]}" ]; then
                target="${BUCKETS[$((choice - 1))]}"
                if confirm_double "Delete bucket '$target' and its contents?"; then
                    delete_bucket "$target"
                fi
            else
                echo "Invalid selection — out of range."
            fi
            ;;
    esac
done

echo ""
echo "Done."
