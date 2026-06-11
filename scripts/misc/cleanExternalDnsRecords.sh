#!/bin/bash
# Delete all DNS records managed by external-dns in the project's DNS zone.
#
# external-dns creates A/AAAA records outside Pulumi state, so they are not
# cleaned up by pulumi destroy. Without this, stale records accumulate across
# subdomain increments (e.g. ecc74 → ecc75 → ecc76).
#
# Ownership is detected via TXT records with heritage=external-dns:
#   a-<hostname>    TXT  → owns <hostname> A record
#   aaaa-<hostname> TXT  → owns <hostname> AAAA record
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DNS_ZONE=$(grep -E '^const baseDomain\s*=' "$SCRIPT_DIR/../../project_settings.ts" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/')

if [ -z "$DNS_ZONE" ]; then
    echo "ERROR: could not determine DNS zone from project_settings." >&2
    exit 1
fi

echo "Cleaning external-dns records in zone: $DNS_ZONE"

DELETED=0
while IFS= read -r txt_name; do
    if [[ "$txt_name" == a-* ]]; then
        record_name="${txt_name#a-}"
        record_type="A"
    elif [[ "$txt_name" == aaaa-* ]]; then
        record_name="${txt_name#aaaa-}"
        record_type="AAAA"
    else
        continue
    fi

    hcloud dns rrset delete "$DNS_ZONE" "$record_name" "$record_type" 2>/dev/null \
        && echo "  Deleted $record_name $record_type" && DELETED=$((DELETED+1)) || true
    hcloud dns rrset delete "$DNS_ZONE" "$txt_name" TXT 2>/dev/null \
        && echo "  Deleted $txt_name TXT" && DELETED=$((DELETED+1)) || true
done < <(
    hcloud dns record list "$DNS_ZONE" -o noheader -o columns=name,type,value 2>/dev/null \
        | grep 'heritage=external-dns' \
        | awk '{print $1}'
)

if [ "$DELETED" -eq 0 ]; then
    echo "  No external-dns records found."
else
    echo "  Deleted $DELETED record(s)."
fi
