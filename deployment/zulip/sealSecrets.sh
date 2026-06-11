#!/bin/bash
# Seals Zulip secrets for ArgoCD deployment.
# Requires a live cluster (kubeseal reads the sealed-secrets cert).
#
# Generates:
#   zulip-s3-sealed.yaml          — Hetzner S3 access key + secret
#   zulip-oidc-sealed.yaml        — Keycloak OIDC client ID + secret
#   zulip-secret-key-sealed.yaml  — Zulip cryptographic secret key (required by chart 1.12.0)
set -euo pipefail

NAMESPACE="zulip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../manageSealedSecrets.sh"

# --- S3 credentials (Hetzner Object Storage) ---
S3_ACCESS_KEY=$(pulumi config get hetznerS3AccessKey)
S3_SECRET_KEY=$(pulumi config get hetznerS3SecretKey)

seal_secret "$NAMESPACE" zulip-s3 zulip-s3-sealed.yaml \
  --from-literal=access-key="$S3_ACCESS_KEY" \
  --from-literal=secret-key="$S3_SECRET_KEY"
SEALED_FILES+=("zulip-s3-sealed.yaml")

# --- Keycloak OIDC client ---
OIDC_CLIENT_ID="zulip"
OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
echo "Generated Keycloak OIDC client secret."

seal_secret "$NAMESPACE" zulip-oidc zulip-oidc-sealed.yaml \
  --from-literal=client-id="$OIDC_CLIENT_ID" \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET"
SEALED_FILES+=("zulip-oidc-sealed.yaml")

# --- Zulip secret key (cryptographic signing key) ---
SECRET_KEY=$(openssl rand -hex 64)
echo "Generated Zulip secret key."

seal_secret "$NAMESPACE" zulip-secret-key zulip-secret-key-sealed.yaml \
  --from-literal=secret-key="$SECRET_KEY"
SEALED_FILES+=("zulip-secret-key-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do
  ABS_FILES+=("${SCRIPT_DIR}/${f}")
done
ask_and_commit_sealed_files "Seal zulip secrets" "${ABS_FILES[@]}"
