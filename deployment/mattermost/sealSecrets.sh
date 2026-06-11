#!/bin/bash
# Seals Mattermost secrets for ArgoCD deployment.
# Requires a live cluster (kubeseal reads the sealed-secrets cert).
#
# Generates:
#   db-secret-sealed.yaml    — PostgreSQL credentials + datasource URL
#   s3-secret-sealed.yaml    — Hetzner S3 access key + secret
#   oidc-secret-sealed.yaml  — Keycloak OIDC client ID + secret
set -euo pipefail

NAMESPACE="mattermost"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../manageSealedSecrets.sh"

# --- PostgreSQL credentials ---
DB_USER="mattermost"
DB_NAME="mattermost"
DB_HOST="mattermost-postgresql"
DB_ADMIN_PASS=$(openssl rand -hex 24)
DB_USER_PASS=$(openssl rand -hex 24)
DB_DATASOURCE="postgres://${DB_USER}:${DB_USER_PASS}@${DB_HOST}:5432/${DB_NAME}?sslmode=disable"

echo "Generated PostgreSQL credentials."
seal_secret "$NAMESPACE" mattermost-db db-secret-sealed.yaml \
  --from-literal=postgres-password="$DB_ADMIN_PASS" \
  --from-literal=password="$DB_USER_PASS" \
  --from-literal=datasource="$DB_DATASOURCE"
SEALED_FILES+=("db-secret-sealed.yaml")

# --- S3 credentials (Hetzner Object Storage) ---
S3_ACCESS_KEY=$(pulumi config get hetznerS3AccessKey)
S3_SECRET_KEY=$(pulumi config get hetznerS3SecretKey)

seal_secret "$NAMESPACE" mattermost-s3 s3-secret-sealed.yaml \
  --from-literal=access-key="$S3_ACCESS_KEY" \
  --from-literal=secret-key="$S3_SECRET_KEY"
SEALED_FILES+=("s3-secret-sealed.yaml")

# --- Keycloak OIDC client ---
OIDC_CLIENT_ID="mattermost"
OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
echo "Generated Keycloak OIDC client secret."

seal_secret "$NAMESPACE" mattermost-oidc oidc-secret-sealed.yaml \
  --from-literal=client-id="$OIDC_CLIENT_ID" \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET"
SEALED_FILES+=("oidc-secret-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do
  ABS_FILES+=("${SCRIPT_DIR}/${f}")
done
ask_and_commit_sealed_files "Seal mattermost secrets" "${ABS_FILES[@]}"
