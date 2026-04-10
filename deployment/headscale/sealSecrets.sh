#!/bin/bash
# Seals Headscale secrets for ArgoCD deployment.
# Can be run BEFORE cluster creation — uses the sealed-secrets public key
# stored in Pulumi config (sealedSecretsTlsCrt), no live cluster required.
# Commit ALL output files — sealed files are encrypted and safe for git.
#
# Generates:
#   oidc-client-secret-sealed.yaml     — encrypted OIDC client secret (for headscale + headplane)
set -euo pipefail

NAMESPACE="headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../manageSealedSecrets.sh"

# --- OIDC client secret (shared by headscale + headplane) ---
OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
echo "Generated OIDC client secret (will be stored in sealed secret)"
seal_secret "$NAMESPACE" headscale-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do
  ABS_FILES+=("${SCRIPT_DIR}/${f}")
done
ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
