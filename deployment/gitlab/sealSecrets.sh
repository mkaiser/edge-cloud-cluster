#!/bin/bash
# Seals GitLab secrets for ArgoCD deployment.
# Safe to re-run: checks for existing sealed secrets and asks before regenerating.
# Skipped secrets keep their current sealed values (no data loss on re-run).
#
# S3 credentials are read from Pulumi config (set during cluster setup via setAllSecrets.sh):
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

# Track which files were created/updated
SEALED_FILES=()

echo "=== GitLab Secret Setup ==="

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

# --- 2. OIDC secrets: generated dynamically by presync-oidc-secrets.yaml ---
# gitlab-oidc-client-secret and gitlab-oidc-provider are no longer sealed secrets.
# The presync job creates them on first install and updates the provider config
# on every sync, reading GITLAB_URL and KEYCLOAK_ISSUER from the manifest.
echo "  OIDC secrets: managed by presync-oidc-secrets.yaml (no sealing needed)."

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
# --- 5. Rails secrets (sealed — safe for public repos) ---
# Must include ALL keys GitLab 18.x needs, otherwise 2_secret_token.rb tries
# to rewrite secrets.yml to add the missing keys — which fails with EBUSY
# because the file is a subPath volume mount (cross-device rename).
if should_seal "gitlab-rails-secrets-sealed.yaml" "Rails secrets"; then
  RAILS_SECRET_KEY_BASE=$(openssl rand -hex 64)
  RAILS_OTP_KEY_BASE=$(openssl rand -hex 64)
  RAILS_DB_KEY_BASE=$(openssl rand -hex 64)
  RAILS_ENCRYPTED_SETTINGS_KEY_BASE=$(openssl rand -hex 64)
  # active_record_encryption keys: base64-encoded 32-byte random values
  AR_PRIMARY_KEY=$(openssl rand -base64 32)
  AR_DETERMINISTIC_KEY=$(openssl rand -base64 32)
  AR_KEY_DERIVATION_SALT=$(openssl rand -base64 32)
  # openid_connect_signing_key: RSA-2048 private key (PEM)
  OIDC_SIGNING_KEY=$(openssl genrsa 2048 2>/dev/null)
  echo "  Generated new Rails secrets."

  RAILS_SECRETS_YML=$(cat <<EORAILS
production:
  secret_key_base: ${RAILS_SECRET_KEY_BASE}
  otp_key_base: ${RAILS_OTP_KEY_BASE}
  db_key_base: ${RAILS_DB_KEY_BASE}
  encrypted_settings_key_base: ${RAILS_ENCRYPTED_SETTINGS_KEY_BASE}
  active_record_encryption_primary_key:
    - ${AR_PRIMARY_KEY}
  active_record_encryption_deterministic_key:
    - ${AR_DETERMINISTIC_KEY}
  active_record_encryption_key_derivation_salt: ${AR_KEY_DERIVATION_SALT}
  openid_connect_signing_key: |
$(echo "$OIDC_SIGNING_KEY" | sed 's/^/    /')
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
