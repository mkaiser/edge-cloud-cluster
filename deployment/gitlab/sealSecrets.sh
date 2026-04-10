#!/bin/bash
# Seals GitLab secrets for ArgoCD deployment.
# Safe to re-run: checks for existing sealed secrets and asks before regenerating.
# Skipped secrets keep their current sealed values (no data loss on re-run).
#
# S3 credentials are read from Pulumi config (set during cluster setup via setPulumiSecrets.sh):
#   - hetznerS3AccessKey / hetznerS3SecretKey
# GitLab root password is entered interactively.
#
# Auto-generated (no user input needed):
#   - OIDC client secret
#   - Rails secret keys
#
# Generates:
#   gitlab-oidc-client-secret-sealed.yaml  — OIDC client secret for Keycloak job
#   gitlab-oidc-provider-sealed.yaml       — OmniAuth OIDC provider config for GitLab
#   gitlab-s3-connection-sealed.yaml       — S3 connection config for all GitLab object storage
#   gitlab-registry-storage-sealed.yaml    — S3 config for container registry
#   gitlab-root-password-sealed.yaml       — Initial GitLab root password
#   gitlab-rails-secrets-sealed.yaml       — Rails secret keys (sealed)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NAMESPACE="gitlab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEAL="${SCRIPT_DIR}/../manageSealedSecrets.sh"
# shellcheck source=../manageSealedSecrets.sh
source "$SEAL"

# --- Helper: check if a sealed secret file exists and ask to keep or regenerate ---
# Returns 0 = regenerate, 1 = skip
should_seal() {
  local file="$1"
  local label="$2"
  if [ -f "${SCRIPT_DIR}/${file}" ]; then
    echo ""
    read -rp "${label} already exists (${file}). Regenerate? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      return 0
    else
      echo "  Keeping existing ${file}"
      return 1
    fi
  fi
  return 0
}

echo "=== GitLab Secret Setup ==="
echo ""

# Track which files were created/updated
SEALED_FILES=()

# --- 1. Root password + email (for user *root*) ---
if should_seal "gitlab-root-password-sealed.yaml" "password + email for user *root*"; then
  echo "  GitLab 18.x password requirements:"
  echo "    - Minimum 8 characters"
  echo "    - Must not contain common words/combinations (e.g. 'admin', 'password')"
  read -rsp "GitLab root password: " GITLAB_ROOT_PASSWORD
  echo
  read -rp "GitLab root email: " GITLAB_ROOT_EMAIL
  "$SEAL" "$NAMESPACE" gitlab-root-password \
    gitlab/gitlab-root-password-sealed.yaml \
    --from-literal=password="$GITLAB_ROOT_PASSWORD" \
    --from-literal=email="$GITLAB_ROOT_EMAIL"
  SEALED_FILES+=("gitlab-root-password-sealed.yaml")
fi

# --- 2. OIDC client secret + provider config (coupled — always regenerate together) ---
if should_seal "gitlab-oidc-client-secret-sealed.yaml" "OIDC client secret + provider"; then
  OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
  echo "  Generated new OIDC client secret."

  "$SEAL" "$NAMESPACE" gitlab-oidc-client-secret \
    gitlab/gitlab-oidc-client-secret-sealed.yaml \
    --from-literal=client-secret="$OIDC_CLIENT_SECRET"
  SEALED_FILES+=("gitlab-oidc-client-secret-sealed.yaml")

  OIDC_PROVIDER=$(sed "s|OIDC_CLIENT_SECRET_PLACEHOLDER|${OIDC_CLIENT_SECRET}|" \
    "${SCRIPT_DIR}/gitlab-oidc-provider.yaml.template")
  "$SEAL" "$NAMESPACE" gitlab-oidc-provider \
    gitlab/gitlab-oidc-provider-sealed.yaml \
    --from-literal=provider="$OIDC_PROVIDER"
  SEALED_FILES+=("gitlab-oidc-provider-sealed.yaml")
fi

# --- 3. S3 connection ---


# --- Read S3 credentials from Pulumi config ---
echo "Reading S3 credentials from Pulumi config..."
S3_ACCESS_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3AccessKey)
S3_SECRET_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3SecretKey)
echo "  S3 access key, S3 secret key: OK"

if should_seal "gitlab-s3-connection-sealed.yaml" "S3 connection"; then
  S3_CONNECTION=$(cat <<EOCONN
provider: AWS
region: nbg1
aws_access_key_id: "${S3_ACCESS_KEY}"
aws_secret_access_key: "${S3_SECRET_KEY}"
endpoint: https://fsn1.your-objectstorage.com
path_style: false
EOCONN
)
  "$SEAL" "$NAMESPACE" gitlab-s3-connection \
    gitlab/gitlab-s3-connection-sealed.yaml \
    --from-literal=connection="$S3_CONNECTION"
  SEALED_FILES+=("gitlab-s3-connection-sealed.yaml")
fi

# --- 4. Registry storage config ---
if should_seal "gitlab-registry-storage-sealed.yaml" "Registry storage"; then
  REGISTRY_CONFIG=$(cat <<EOREG
s3:
  bucket: edgecloud-gitlab
  accesskey: "${S3_ACCESS_KEY}"
  secretkey: "${S3_SECRET_KEY}"
  region: nbg1
  regionendpoint: https://nbg1.your-objectstorage.com
  v4auth: true
  rootdirectory: /gitlab-registry
EOREG
)
  "$SEAL" "$NAMESPACE" gitlab-registry-storage \
    gitlab/gitlab-registry-storage-sealed.yaml \
    --from-literal=config="$REGISTRY_CONFIG"
  SEALED_FILES+=("gitlab-registry-storage-sealed.yaml")
fi

# --- 5. Rails secrets (sealed — safe for public repos) ---
if should_seal "gitlab-rails-secrets-sealed.yaml" "Rails secrets"; then
  RAILS_SECRET_KEY_BASE=$(openssl rand -hex 64)
  RAILS_OTP_KEY_BASE=$(openssl rand -hex 64)
  RAILS_DB_KEY_BASE=$(openssl rand -hex 64)
  RAILS_ENCRYPTED_SETTINGS_KEY_BASE=$(openssl rand -hex 64)
  echo "  Generated new Rails secrets."

  RAILS_SECRETS_YML=$(cat <<EORAILS
production:
  secret_key_base: ${RAILS_SECRET_KEY_BASE}
  otp_key_base: ${RAILS_OTP_KEY_BASE}
  db_key_base: ${RAILS_DB_KEY_BASE}
  encrypted_settings_key_base: ${RAILS_ENCRYPTED_SETTINGS_KEY_BASE}
EORAILS
)
  "$SEAL" "$NAMESPACE" gitlab-rails-secrets \
    gitlab/gitlab-rails-secrets-sealed.yaml \
    --from-literal=secrets.yml="$RAILS_SECRETS_YML"
  SEALED_FILES+=("gitlab-rails-secrets-sealed.yaml")
fi

echo ""
if [ ${#SEALED_FILES[@]} -eq 0 ]; then
  echo "Nothing changed — all secrets kept."
else
  ABS_FILES=()
  for f in "${SEALED_FILES[@]}"; do
    ABS_FILES+=("${SCRIPT_DIR}/${f}")
  done
  ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
fi
