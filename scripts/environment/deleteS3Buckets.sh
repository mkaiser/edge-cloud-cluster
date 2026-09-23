#!/bin/bash
# Interactive S3 bucket deletion for the Hetzner Object Storage account.
#
# DISCOVERS the live buckets via the S3 ListBuckets API against the Hetzner
# endpoint, then lets you delete all of them or pick individual ones. The list refreshes after each action until you
# cancel or no buckets remain.
#
# Credentials come from the selected Pulumi stack
# (hetznerS3AccessKey / hetznerS3SecretKey).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETTINGS="$REPO_ROOT/project_settings.ts"

# --all-yes / --force / -y : delete EVERY bucket with no prompt (for automated
# teardown, e.g. destroyCluster.sh --force). Otherwise run interactively.
ALL_YES=false
for arg in "$@"; do
    case "$arg" in
        --all-yes | --force | -y) ALL_YES=true ;;
    esac
done

# ── Endpoint from project_settings.ts ────────────────────────────────────────
ENDPOINT=$(perl -ne 'print "$1\n" and exit if /baseEndpoint:\s*"([^"]+)"/' "$SETTINGS")
: "${ENDPOINT:?Could not parse baseEndpoint from $SETTINGS}"
S3_URL="https://${ENDPOINT}"
REGION="${ENDPOINT%%.*}"   # e.g. "nbg1" from "nbg1.your-objectstorage.com"

# ── Tooling ──────────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { echo "ERROR: 'aws' CLI not found." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: 'jq' not found." >&2; exit 1; }

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
LC_JSON="$(mktemp)"
trap 'rm -f "$LC_JSON"' EXIT

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

human_size() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB PiB", u, " ")
        i=1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# Objects + bytes in a bucket. Counts ALL object versions and delete markers
# (not just current objects) because that is what DeleteBucket actually sees:
# a bucket showing "0 objects" in a flat listing can still hold non-current
# versions. Delete markers carry no Size, hence `.Size // 0`.
bucket_stats() {
    local B="$1" token page n sz count=0 bytes=0
    token=""
    while true; do
        if [ -n "$token" ]; then
            page=$(aws s3api list-object-versions --bucket "$B" --endpoint-url "$S3_URL" \
                --max-items 1000 --starting-token "$token" --output json 2>/dev/null) || break
        else
            page=$(aws s3api list-object-versions --bucket "$B" --endpoint-url "$S3_URL" \
                --max-items 1000 --output json 2>/dev/null) || break
        fi
        [ -n "$page" ] || break
        n=$(printf '%s' "$page" | jq '[ (.Versions // []), (.DeleteMarkers // []) | .[] ] | length')
        sz=$(printf '%s' "$page" | jq '[ (.Versions // []) | .[] | (.Size // 0) ] | add // 0')
        count=$((count + n))
        bytes=$((bytes + sz))
        token=$(printf '%s' "$page" | jq -r '.NextToken // empty')
        [ -n "$token" ] || break
    done
    # Trailing newline matters: `read` returns 1 at EOF without one, which under
    # `set -e` would abort the script even though both vars were assigned.
    printf '%s %s\n' "$count" "$bytes"
}

# Print the numbered bucket list with object counts and sizes.
print_bucket_table() {
    local -n _arr="$1"
    local i=1 b count bytes
    printf "  %2s  %-40s %10s  %10s\n" "#" "BUCKET" "OBJECTS" "SIZE"
    for b in "${_arr[@]}"; do
        count=0; bytes=0
        read -r count bytes < <(bucket_stats "$b") || true
        printf "  %2d) %-40s %10s  %10s\n" \
            "$i" "$b" "$count" "$(human_size "$bytes")"
        i=$((i + 1))
    done
}

# Bulk-empty a bucket via the DeleteObjects API (up to 1000 keys per request)
# instead of `aws s3 rm --recursive`, which issues one HTTP DELETE per object.
#
# `aws s3 rm --recursive` (and list-objects-v2) only sees CURRENT object
# versions. A bucket can still refuse DeleteBucket with BucketNotEmpty when it
# holds any of:
#   - non-current object versions / delete markers (versioned buckets)
#   - incomplete multipart uploads (partial uploads never completed/aborted)
# So we page list-object-versions (covers versioned AND flat buckets) and also
# abort every multipart upload.
# Drain a bucket in one pass. Returns:
#   0 = bucket verifiably empty afterwards (no versions, no markers, no uploads)
#   3 = objects remained, or a delete-objects call reported failures. This is
#       NOT the same as Hetzner's post-delete listing lag — it means the drain
#       itself did not fully succeed and must be retried (re-emptied).
# WHY the distinction: under teardown load Hetzner throttles (503 SlowDown), so a
# delete-objects page can partially fail. The old code did `|| true` and never
# inspected the response, so a bucket that still held real objects looked
# "emptied" — then only DeleteBucket (rb) was retried, never the drain, and the
# objects survived every round while the run reported "only shells remain".
empty_bucket() {
    local B="$1" token page n total=0 errs=0
    local pf; pf=$(mktemp)   # delete payload file (see below)

    # 1) Delete all object versions + delete markers, 1000 keys/request.
    #    The payload MUST go via --delete file://... : passing ~1000 long keys
    #    inline as an argument overflows the exec ARG_MAX limit ("Argument list
    #    too long") and every delete silently fails.
    token=""
    while true; do
        if [ -n "$token" ]; then
            page=$(aws s3api list-object-versions --bucket "$B" --endpoint-url "$S3_URL" \
                --max-items 1000 --starting-token "$token" --output json 2>/dev/null) || break
        else
            page=$(aws s3api list-object-versions --bucket "$B" --endpoint-url "$S3_URL" \
                --max-items 1000 --output json 2>/dev/null) || break
        fi
        printf '%s' "$page" | jq -c \
            '{Objects: [ (.Versions // []), (.DeleteMarkers // []) | .[] | {Key, VersionId} ], Quiet: true}' > "$pf"
        n=$(jq '.Objects | length' "$pf")
        if [ "$n" -gt 0 ]; then
            # Capture the response (Quiet:true → only Errors are returned) so a
            # throttled/partial delete is counted, not silently swallowed.
            local dout derc=0 derr
            dout=$(aws s3api delete-objects --bucket "$B" --endpoint-url "$S3_URL" \
                --delete "file://$pf" 2>/dev/null) || derc=$?
            if [ "$derc" -ne 0 ]; then
                errs=$((errs + n))                     # whole page failed to send
            else
                derr=$(printf '%s' "$dout" | jq '(.Errors // []) | length' 2>/dev/null || echo 0)
                errs=$((errs + derr))                  # per-key failures in the batch
            fi
            total=$((total + n))
            printf '\r  Emptying... %d versions deleted' "$total"
        fi
        token=$(printf '%s' "$page" | jq -r '.NextToken // empty')
        [ -n "$token" ] || break
    done
    rm -f "$pf"
    [ "$total" -gt 0 ] && printf '\n'
    [ "$errs" -gt 0 ] && echo "  WARNING: $errs object delete(s) failed this pass (will re-empty)."

    # 2) Abort incomplete multipart uploads.
    local uploads mu=0
    uploads=$(aws s3api list-multipart-uploads --bucket "$B" --endpoint-url "$S3_URL" \
        --output json 2>/dev/null | jq -c '.Uploads[]? | {Key, UploadId}')
    if [ -n "$uploads" ]; then
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            local key uid
            key=$(printf '%s' "$u" | jq -r '.Key')
            uid=$(printf '%s' "$u" | jq -r '.UploadId')
            aws s3api abort-multipart-upload --bucket "$B" --endpoint-url "$S3_URL" \
                --key "$key" --upload-id "$uid" >/dev/null 2>&1 || true
            mu=$((mu + 1))
        done <<< "$uploads"
        echo "  Aborted $mu incomplete multipart upload(s)."
    fi

    [ "$total" -eq 0 ] && [ "$mu" -eq 0 ] && echo "  (already empty)"

    # Verify: a failed delete OR anything still listed ⇒ drain incomplete, tell
    # the caller to re-empty rather than assume DeleteBucket is merely lagging.
    if [ "$errs" -gt 0 ] || ! bucket_is_empty "$B"; then
        return 3
    fi
    return 0
}

# True (0) iff the bucket has no object versions, no delete markers, and no
# in-flight multipart uploads. One cheap page each — enough to tell "still has
# data" from an empty shell. Defaults to non-empty (1) on any API error so we
# never falsely declare a bucket empty.
bucket_is_empty() {
    local B="$1" objs ups
    objs=$(aws s3api list-object-versions --bucket "$B" --endpoint-url "$S3_URL" \
        --max-items 1 --output json 2>/dev/null \
        | jq '[(.Versions // []), (.DeleteMarkers // []) | .[]] | length' 2>/dev/null || echo 1)
    ups=$(aws s3api list-multipart-uploads --bucket "$B" --endpoint-url "$S3_URL" \
        --output json 2>/dev/null | jq '(.Uploads // []) | length' 2>/dev/null || echo 1)
    [ "${objs:-1}" -eq 0 ] && [ "${ups:-1}" -eq 0 ]
}

# Hetzner Object Storage lags after a bulk delete — every listing API reports
# the bucket empty yet DeleteBucket returns BucketNotEmpty until an internal
# janitor reconciles (seconds to ~1 hour). Blocking 5x30s per bucket right after
# emptying it wastes that window serially. Instead we try DeleteBucket ONCE, and
# park anything that says BucketNotEmpty in PENDING[] — sweep_pending() retries
# those at the very end, by which time the janitor has usually caught up with
# the buckets emptied earliest.
PENDING=()

# One DeleteBucket attempt. 0=gone, 2=BucketNotEmpty (parked), 1=hard failure.
try_rb() {
    local B="$1" out rc=0
    # `out=$(cmd)` takes cmd's exit status; under `set -e` a non-zero rb would
    # abort the whole script before `rc=$?` ever runs. Split the assignment from
    # the capture so the logic below is reachable.
    out=$(aws s3 rb "s3://${B}" --endpoint-url "$S3_URL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && return 0
    case "$out" in
        *NoSuchBucket*)   return 0 ;;
        *BucketNotEmpty*) return 2 ;;
        *) echo "  FAILED: $out"; return 1 ;;
    esac
}

delete_bucket() {
    local B="$1" rc=0
    echo "── $B ──"
    # If the first drain didn't fully empty the bucket (throttled/partial delete,
    # rc=3), the sweep will re-empty it — don't treat it as merely GC-lagging.
    empty_bucket "$B" || rc=$?
    local drained_ok=true
    [ "$rc" -eq 3 ] && drained_ok=false

    # Belt-and-suspenders: lifecycle rule that expires objects + aborts
    # incomplete multipart uploads, so Hetzner's GC clears any hidden state
    # the S3 listing APIs don't expose.
    printf '{"Rules":[{"ID":"purge-all","Filter":{"Prefix":""},"Status":"Enabled","Expiration":{"Days":1},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' \
        > "$LC_JSON"
    aws s3api put-bucket-lifecycle-configuration --bucket "$B" --endpoint-url "$S3_URL" \
        --lifecycle-configuration "file://$LC_JSON" >/dev/null 2>&1 || true

    # Only attempt DeleteBucket if the drain verified empty; otherwise defer
    # straight to the sweep, which re-empties before retrying.
    if [ "$drained_ok" = true ]; then
        echo "  Deleting bucket..."
        rc=0; try_rb "$B" || rc=$?
        case "$rc" in
            0) echo "  Deleted."; return 0 ;;
            2) echo "  Emptied; bucket shell pending Hetzner GC — deferred to end of run."
               PENDING+=("$B"); return 0 ;;
            *) return 1 ;;
        esac
    else
        echo "  Drain incomplete — deferred to sweep (will re-empty)."
        PENDING+=("$B"); return 0
    fi
}

# Final pass over buckets that were parked: either DeleteBucket lagging on an
# empty bucket, OR a drain that didn't fully complete. Each round RE-EMPTIES the
# bucket (cheap no-op if already empty) and only then retries DeleteBucket — so a
# bucket that still holds real objects (throttled partial delete) actually gets
# drained instead of being assumed empty forever.
sweep_pending() {
    [ "${#PENDING[@]}" -gt 0 ] || return 0
    local round b rc left
    echo ""
    echo "── Deferred bucket removal (${#PENDING[@]} pending) ──"
    for round in 1 2 3 4 5; do
        left=()
        for b in "${PENDING[@]}"; do
            # Re-drain first. `|| true`: rc=3 (still not empty) just means the
            # rb below will fail with BucketNotEmpty and re-park — handled there.
            empty_bucket "$b" >/dev/null 2>&1 || true
            rc=0; try_rb "$b" || rc=$?
            case "$rc" in
                0) echo "  $b: deleted." ;;
                2) left+=("$b") ;;
                *) echo "  $b: hard failure, giving up." ;;
            esac
        done
        PENDING=("${left[@]}")
        [ "${#PENDING[@]}" -gt 0 ] || { echo "  All deferred buckets removed."; return 0; }
        if [ "$round" -lt 5 ]; then
            echo "  ${#PENDING[@]} still not empty; retry $round/5 in 30s..."
            sleep 30
        fi
    done
    echo ""
    echo "  WARNING: ${#PENDING[@]} bucket(s) still not deletable after retries:"
    for b in "${PENDING[@]}"; do
        if bucket_is_empty "$b"; then
            echo "    - $b (empty; Hetzner GC still catching up — safe, re-run later)"
        else
            echo "    - $b (STILL HAS OBJECTS — re-run this script to finish draining)"
        fi
    done
    echo "  Hetzner reconciliation can take up to ~1h for empty shells."
    return 1
}

# ── Non-interactive: delete ALL buckets, no prompt (--all-yes) ───────────────
if [ "$ALL_YES" = true ]; then
    mapfile -t BUCKETS < <(list_buckets)
    if [ "${#BUCKETS[@]}" -eq 0 ]; then
        echo "No buckets to delete at $S3_URL."
        exit 0
    fi
    echo "Deleting ALL ${#BUCKETS[@]} bucket(s) at $S3_URL without prompt (--all-yes)..."
    # `|| true`: one bucket stuck on Hetzner's backend lag must not abort the rest.
    for b in "${BUCKETS[@]}"; do delete_bucket "$b" || true; done
    sweep_pending || true
    echo "Done."
    exit 0
fi

# ── Interactive loop ─────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  S3 bucket deletion — Hetzner Object Storage ($S3_URL)"
echo "║  Permanently deletes bucket contents AND the buckets. Irreversible. ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"

is_pending() {
    local b p
    b="$1"
    for p in ${PENDING[@]+"${PENDING[@]}"}; do [ "$p" = "$b" ] && return 0; done
    return 1
}

while true; do
    # Buckets already emptied and awaiting Hetzner GC still show up in
    # ListBuckets. Hide them from the menu, otherwise the loop would keep
    # offering empty shells forever and never reach sweep_pending().
    ALL=()
    mapfile -t ALL < <(list_buckets)
    BUCKETS=()
    for b in ${ALL[@]+"${ALL[@]}"}; do
        is_pending "$b" || BUCKETS+=("$b")
    done

    if [ "${#BUCKETS[@]}" -eq 0 ]; then
        echo ""
        if [ "${#PENDING[@]}" -gt 0 ]; then
            echo "All remaining buckets are emptied and awaiting Hetzner GC."
        else
            echo "No buckets remain at $S3_URL."
        fi
        break
    fi

    echo ""
    echo "Buckets at $S3_URL:"
    print_bucket_table BUCKETS
    echo ""
    read -rp "Enter a number to delete one, [A] delete all, [C] cancel: " choice

    case "$choice" in
        [Cc])
            echo "Cancelled."
            break
            ;;
        [Aa])
            if confirm_double "Delete ALL ${#BUCKETS[@]} bucket(s) and their contents?"; then
                for b in "${BUCKETS[@]}"; do delete_bucket "$b" || true; done
            fi
            ;;
        ''|*[!0-9]*)
            echo "Invalid input — enter a number, A, or C."
            ;;
        *)
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#BUCKETS[@]}" ]; then
                target="${BUCKETS[$((choice - 1))]}"
                if confirm_double "Delete bucket '$target' and its contents?"; then
                    delete_bucket "$target" || true
                fi
            else
                echo "Invalid selection — out of range."
            fi
            ;;
    esac
done

# Run even after [C]ancel: buckets already emptied this session still need their
# shells removed once Hetzner's janitor catches up.
sweep_pending || true

echo ""
echo "Done."
