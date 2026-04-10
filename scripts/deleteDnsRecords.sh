#!/bin/bash
# Delete A and AAAA DNS records for the given names in the given Zone
# Only deletes records that actually exist

ZONE="myDomain.tld"

SUBDOMAIN=(
  test21
)

NAMES=(
  "*"
  argocd
  grafana
  hello-pulumi
  id
  wg
  argocd
  hello-argo
  hello-pulumi
  prometheus
  ics
  objectstore
  portal
  chat
  files
  meet
  notes
  wiki
  webmail
)

# Fetch current records once
CURRENT_RECORDS=$(hcloud dns record list "$ZONE" 2>&1)
# echo "Current DNS records for $ZONE:"
# echo "$CURRENT_RECORDS"

for subdomain in "${SUBDOMAIN[@]}"; do

  for name in "${NAMES[@]}"; do
    dnsName="$name.$subdomain"
    for type in A AAAA; do
      if echo "$CURRENT_RECORDS" | awk -v n="$dnsName" -v t="$type" '$1 == n && $2 == t {found=1} END {exit !found}'; then
        echo "Deleting $dnsName $type ..."
        hcloud dns record delete "$ZONE" "$dnsName" "$type" 2>&1
      # else
        # echo "Skipping $dnsName $type (not found)"
      fi
    done
    # Wildcard A/AAAA records do not use these external-dns TXT names.
    if [[ "$name" == "*" ]]; then
      continue
    fi
    for prefix in a aaaa; do
      txt_name="${prefix}-${name}.${subdomain}"
      if echo "$CURRENT_RECORDS" | awk -v n="$txt_name" -v t="TXT" '$1 == n && $2 == t {found=1} END {exit !found}'; then
        echo "Deleting $txt_name TXT ..."
        hcloud dns record delete "$ZONE" "$txt_name" TXT 2>&1
      # else
      #   echo "Skipping $txt_name TXT (not found)"
      fi
    done
  done  
done
