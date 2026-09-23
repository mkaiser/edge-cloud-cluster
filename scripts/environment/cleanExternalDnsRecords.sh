#!/bin/bash
# Delete all DNS records managed by external-dns in the project's DNS zone.
#
# external-dns creates A/AAAA records outside Pulumi state, so they are not
# cleaned up by pulumi destroy. Without this, stale records accumulate across
# subdomain increments (e.g. ecc74 → ecc75 → ecc76).
#
# Three ownership signals are matched:
#   1. external-dns: TXT records carrying heritage=external-dns:
#        a-<hostname>    TXT  → owns <hostname> A record
#        aaaa-<hostname> TXT  → owns <hostname> AAAA record
#   2. stale cluster label: any record carrying a per-cluster label of the same
#      shape as the current general.subdomain — the letters of e.g. "ecc196"
#      plus any digits — so leftovers from EARLIER clusters (ecc74, ecc129) are
#      swept too. Skipped in bare-domain mode (empty subdomain): at the apex
#      there is no disposable label, and a generic "letters+digits" matcher
#      would put the zone's own records (default2502._domainkey) at risk. Only
#      signals 1 and 3 remain there, so detection is weaker.
#   3. Pulumi-managed: any record whose per-value comment starts with
#      "Pulumi-managed:" (e.g. the apex "@" SPF TXT). pulumi destroy can leave
#      these behind, and they carry no cluster label, so match on the comment.
#      NB the comment lives under .records[].comment, not top-level .comment.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Non-interactive auto-confirm: --force/--all-yes flag, or stdin is not a TTY
# (e.g. invoked from `make destroy --force`). Otherwise prompt as before.
AUTO_YES="false"
for arg in "$@"; do case "$arg" in --force|--all-yes|-y) AUTO_YES="true" ;; esac; done
[ -t 0 ] || AUTO_YES="true"

# The DNS zone is the apex domain — project_settings.ts: `domain: "<zone>"`.
# (Was `const baseDomain = ...`, but that is now a nested property, not a
# top-level const, so match the `domain:` field instead.)
DNS_ZONE=$(grep -E '^\s*domain\s*:\s*"' "$SCRIPT_DIR/../../project_settings.ts" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$DNS_ZONE" ]; then
    echo "ERROR: could not determine DNS zone from project_settings." >&2
    exit 1
fi

# The per-cluster label, from the same source. Legitimately EMPTY in bare-domain mode.
# Its letters are the family name shared by every cluster ("ecc196" → "ecc"), which is what
# lets the matcher below also catch a previous cluster's records.
CLUSTER_LABEL=$(grep -E '^\s*subdomain\s*:\s*"' "$SCRIPT_DIR/../../project_settings.ts" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
CLUSTER_LABEL_FAMILY=$(printf '%s' "$CLUSTER_LABEL" | sed -E 's/[0-9]+$//')

# hcloud needs a token: use HCLOUD_TOKEN / an active context, else derive it
# from the loaded Pulumi stack. Shared helper (sourced, not executed).
# shellcheck source=../environment/createhcloudContext.sh
source "$SCRIPT_DIR/../environment/createhcloudContext.sh"
ensure_hcloud_token || exit 1

echo "Scanning DNS zone: $DNS_ZONE"

# Fetch the full record set once as JSON. Column-based output ("-o columns=...")
# cannot expose the record value reliably (the TXT heritage marker lives under
# .records[].value), so parse JSON with jq instead. Fail loudly on API errors
# rather than silently treating them as an empty zone.
if ! RECORDS_JSON=$(hcloud zone rrset list "$DNS_ZONE" -o json 2>&1); then
    echo "ERROR: failed to list DNS records for $DNS_ZONE:" >&2
    echo "$RECORDS_JSON" >&2
    exit 1
fi

# ── Collect external-dns owned records ───────────────────────────────────────
# Ownership is declared by a TXT record whose value carries the external-dns
# heritage marker. The TXT name is prefixed a-/aaaa- and points at the A/AAAA
# record it owns (e.g. a-gitlab.ecc129 owns gitlab.ecc129 A).
EXTDNS_RECORDS=()
while IFS= read -r txt_name; do
    [ -z "$txt_name" ] && continue
    if [[ "$txt_name" == a-* ]]; then
        EXTDNS_RECORDS+=("${txt_name#a-} A" "$txt_name TXT")
    elif [[ "$txt_name" == aaaa-* ]]; then
        EXTDNS_RECORDS+=("${txt_name#aaaa-} AAAA" "$txt_name TXT")
    fi
done < <(
    echo "$RECORDS_JSON" \
        | jq -r '.[] | select(.type=="TXT")
                     | select(any(.records[].value; test("heritage=external-dns")))
                     | .name'
)

# ── Collect stale cluster-label records ───────────────────────────────────────
# Name-based signal, keyed on the shape of the current general.subdomain (letters + digits), so
# earlier clusters' leftovers are swept too. In bare-domain mode there is no such label — every
# cluster record sits at apex level beside the zone's own records — so the matcher is skipped
# rather than widened into something that could match a genuine zone record.
ECC_RECORDS=()
if [ -n "$CLUSTER_LABEL_FAMILY" ]; then
    while IFS=' ' read -r rec_name rec_type; do
        [ -z "$rec_name" ] && continue
        ECC_RECORDS+=("$rec_name $rec_type")
    done < <(
        echo "$RECORDS_JSON" \
            | jq -r --arg fam "$CLUSTER_LABEL_FAMILY" \
                   '.[] | select(.name | test("(^|\\.)" + $fam + "[0-9]+")) | "\(.name) \(.type)"' \
            | sort -u
    )
else
    echo "Bare-domain mode (empty general.subdomain): no cluster label to match on;"
    echo "relying on the external-dns heritage TXT signal only."
fi

# ── Collect Pulumi-managed records (by comment) ───────────────────────────────
# Records created by src/dns.ts (apex SPF TXT, wildcard A/AAAA, subdomain SPF)
# historically carried a per-value comment "Pulumi-managed: ...". The newer
# hcloud `zone rrset` API no longer exposes .records[].comment, so this signal
# yields nothing now (the `// ""` guard keeps it safe) — these records are
# removed by `pulumi destroy` directly. Kept for older zones that still have it.
PULUMI_RECORDS=()
while IFS=' ' read -r rec_name rec_type; do
    [ -z "$rec_name" ] && continue
    PULUMI_RECORDS+=("$rec_name $rec_type")
done < <(
    echo "$RECORDS_JSON" \
        | jq -r '.[] | select(any(.records[].comment // ""; test("Pulumi-managed")))
                     | "\(.name) \(.type)"' \
        | sort -u
)

# ── Preview ───────────────────────────────────────────────────────────────────
# A record may be flagged by both sources (e.g. gitlab.ecc129 A is external-dns
# owned AND carries a cluster label). Dedupe so the count and delete pass touch each rrset
# once; show the per-source labels in the preview for context.
DELETE_SET=()
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    DELETE_SET+=("$entry")
done < <(printf '%s\n' "${EXTDNS_RECORDS[@]+"${EXTDNS_RECORDS[@]}"}" \
                       "${ECC_RECORDS[@]+"${ECC_RECORDS[@]}"}" \
                       "${PULUMI_RECORDS[@]+"${PULUMI_RECORDS[@]}"}" | sort -u)

TOTAL=${#DELETE_SET[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "  No records to delete."
    exit 0
fi

echo ""
echo "Records to delete:"
for entry in "${EXTDNS_RECORDS[@]+"${EXTDNS_RECORDS[@]}"}"; do
    echo "  [external-dns]  $entry"
done
for entry in "${ECC_RECORDS[@]+"${ECC_RECORDS[@]}"}"; do
    echo "  [cluster label] $entry"
done
for entry in "${PULUMI_RECORDS[@]+"${PULUMI_RECORDS[@]}"}"; do
    echo "  [pulumi]        $entry"
done
echo ""
echo "Total: $TOTAL unique rrset(s)."
echo ""
if [[ "$AUTO_YES" == "true" ]]; then
    echo "Auto-confirmed (non-interactive) — deleting all listed records."
else
    read -rp "Delete all listed records? Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ── Delete ────────────────────────────────────────────────────────────────────
DELETED=0
for entry in "${DELETE_SET[@]}"; do
    rec_name="${entry% *}"
    rec_type="${entry##* }"
    hcloud zone rrset delete "$DNS_ZONE" "$rec_name" "$rec_type" 2>/dev/null \
        && echo "  Deleted $rec_name $rec_type" && DELETED=$((DELETED+1)) || true
done

echo ""
echo "Deleted $DELETED record(s)."
