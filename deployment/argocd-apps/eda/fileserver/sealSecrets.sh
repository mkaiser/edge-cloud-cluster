#!/bin/bash
# Seals the SCOPED Authentik provisioner token for the eda-fileserver namespace.
#
# ⚠ NO TrueNAS CREDENTIAL IS SEALED HERE ANY MORE. The provisioning Job MINTS its own
# scoped TrueNAS API key on first run (provision-job.yaml, mint_api_key) and caches it in
# secret/eda-fileserver-api, which it owns. The credential it bootstraps from is the
# appliance admin, sealed for this namespace by
# deployment/argocd-infra/truenas/sealSecrets.sh alongside the truenas and samba-ad copies.
# Run THAT script for the appliance half.
#
# WHY THERE IS NO HAND-MINTED TrueNAS KEY HERE, both reasons real:
#   1. TrueNAS shows a key's value EXACTLY ONCE, so a lost key cannot be re-derived.
#   2. It cannot work on a fresh cluster: the provisioning Job is a PreSync hook, so an
#      ordinary Sync-phase SealedSecret is applied only AFTER the hook that needs it.
#
# ── Creating a TrueNAS API key BY HAND, if you ever need one ──────────────────────────
#   TrueNAS UI → Credentials → Users → (select `truenas_admin`) → Add API key
#     Name:     ecc_api_key           (free text; the Job names its own `eda-fileserver`)
#     Username: truenas_admin
#   The value is displayed ONCE, on creation.
#   An API key buys LEAST PRIVILEGE — a narrower blast radius than the appliance admin
#   password, not a different transport.
#
# Generates (git-committed):
#   authentik-provisioner-token-sealed.yaml  — scoped Authentik API token
#
# Usage: ./sealSecrets.sh                 # recover-or-prompt
#        ./sealSecrets.sh --show          # what is sealed, no values, no changes
set -euo pipefail

NAMESPACE="eda-fileserver"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SEALED_OUT="$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
SEALED_FILES=()

# shellcheck source=../../../manageSealedSecrets.sh
source "$REPO_DIR/deployment/manageSealedSecrets.sh"

SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --skip-git-commit) SKIP_GIT_COMMIT="1" ;;
  --commit-per-app)  SEAL_DEFER_COMMIT="" ;;
  --regenerate)      : ;;  # accepted for uniformity; nothing here is generated
esac; done

if [[ "${1:-}" == "--show" ]]; then
  # Deliberately prints KEY NAMES ONLY, never values.
  if [[ -f "$SEALED_OUT" ]]; then
    echo "sealed secret: present"
    jq -r '.spec.encryptedData | keys[]' "$SEALED_OUT" 2>/dev/null | sed 's/^/  key: /'
  else
    echo "sealed secret: MISSING — run this script"
  fi
  exit 0
fi

for t in kubeseal kubectl pulumi jq; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done

# Same plaintext as the central AUTHENTIK_PROVISIONER_TOKEN — recovered rather than retyped,
# so the copies cannot drift.
PROV_TOKEN=$(try_recover "$REPO_DIR/deployment/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SEALED_OUT" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from the authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && {
  echo "ERROR: provisioner token empty — run argocd-infra/authentik/sealSecrets.sh first" >&2
  exit 1; }

seal_secret "$NAMESPACE" authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"
SEALED_FILES+=("$SEALED_OUT")
unset PROV_TOKEN

if [[ -z "${SKIP_GIT_COMMIT:-}" ]]; then
  ask_and_commit_sealed_files \
    "eda-fileserver: seal the Authentik provisioner token" \
    "${SEALED_FILES[@]}"
fi
