#!/bin/bash
# Seals GitLab secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate auto-generated secrets (DB password, rails secrets).
#
# S3 credentials are read from Pulumi config (set during cluster setup via setAllSecrets.sh):
#   - hetznerS3AccessKey / hetznerS3SecretKey
#
# Generates:
#   gitlab-db-sealed.yaml                  — PostgreSQL password
#   gitlab-s3-connection-sealed.yaml       — S3 connection config for all GitLab object storage
#   gitlab-registry-storage-sealed.yaml    — S3 config for container registry
#   gitlab-root-password-sealed.yaml       — Initial GitLab root password (interactive on first run)
#   gitlab-rails-secrets-sealed.yaml       — Rails secret keys
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NAMESPACE="gitlab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEAL="${SCRIPT_DIR}/../../manageSealedSecrets.sh"
# shellcheck source=../manageSealedSecrets.sh
source "$SEAL"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done
SEALED_FILES=()

echo "=== GitLab Secret Setup ==="

# --- 1. Root password + email ---
ROOT_SEALED="$SCRIPT_DIR/gitlab-root-password-sealed.yaml"

EXISTING_PASS=$(try_recover "$ROOT_SEALED" password)
EXISTING_EMAIL=$(try_recover "$ROOT_SEALED" email)

GITLAB_ROOT_PASSWORD=""; GITLAB_ROOT_EMAIL=""; _need_enter="false"
if [[ -n "$EXISTING_PASS" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "gitlab-root-password" "true" "true"
  case "$KEG_CHOICE" in
    keep)
      echo "  gitlab-root-password — kept."
      GITLAB_ROOT_PASSWORD="$EXISTING_PASS"
      GITLAB_ROOT_EMAIL="$EXISTING_EMAIL"
      if [[ -z "$GITLAB_ROOT_EMAIL" ]]; then
        read -rp "  GitLab root email (missing from sealed file): " GITLAB_ROOT_EMAIL
      fi
      ;;
    generate)
      GITLAB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 20)
      GITLAB_ROOT_EMAIL="$EXISTING_EMAIL"
      echo "  Generated new GitLab root password."
      if [[ -z "$GITLAB_ROOT_EMAIL" ]]; then
        read -rp "  GitLab root email (missing from sealed file): " GITLAB_ROOT_EMAIL
      fi
      ;;
    enter) _need_enter="true" ;;
  esac
else
  prompt_keg "gitlab-root-password" "false" "true"
  if [[ "$KEG_CHOICE" == "generate" ]]; then
    GITLAB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 20)
    echo "  Generated new GitLab root password."
  else
    _need_enter="true"
  fi
fi

if [[ "$_need_enter" == "true" ]]; then
  echo "  GitLab 18.x password requirements:"
  echo "    - Minimum 8 characters"
  echo "    - Must not contain common words/combinations (e.g. 'admin', 'password')"
  while true; do
    read -rsp "  GitLab root password: " GITLAB_ROOT_PASSWORD; echo
    read -rsp "  Confirm password: " confirm; echo
    [[ "$GITLAB_ROOT_PASSWORD" == "$confirm" ]] && [[ ${#GITLAB_ROOT_PASSWORD} -ge 8 ]] && break
    echo "  Passwords do not match or too short — try again."
  done
  _hint=""; [[ -n "$EXISTING_EMAIL" ]] && _hint=" [enter to keep: $EXISTING_EMAIL]"
  read -rp "  GitLab root email${_hint}: " GITLAB_ROOT_EMAIL
  [[ -z "$GITLAB_ROOT_EMAIL" ]] && GITLAB_ROOT_EMAIL="$EXISTING_EMAIL"
fi

seal_secret "$NAMESPACE" gitlab-root-password \
  gitlab-root-password-sealed.yaml \
  --from-literal=password="$GITLAB_ROOT_PASSWORD" \
  --from-literal=email="$GITLAB_ROOT_EMAIL"
SEALED_FILES+=("gitlab-root-password-sealed.yaml")

# --- 2. OIDC secrets: generated dynamically by presync-oidc-secrets.yaml ---
echo "  OIDC secrets: managed by presync-oidc-secrets.yaml (no sealing needed)."

# --- 3. External PostgreSQL DB password ---
DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/gitlab-db-sealed.yaml" db-password "$REGEN")
seal_secret "$NAMESPACE" gitlab-db gitlab-db-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD"
SEALED_FILES+=("gitlab-db-sealed.yaml")

# --- 4. S3 connection ---
echo "Reading S3 credentials from Pulumi config..."
S3_ACCESS_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3AccessKey)
S3_SECRET_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3SecretKey)
echo "  S3 access key, S3 secret key: OK"

S3_CONNECTION=$(cat <<EOCONN
provider: AWS
region: nbg1
aws_access_key_id: "${S3_ACCESS_KEY}"
aws_secret_access_key: "${S3_SECRET_KEY}"
endpoint: https://nbg1.your-objectstorage.com
path_style: false
EOCONN
)
seal_secret "$NAMESPACE" gitlab-s3-connection \
  gitlab-s3-connection-sealed.yaml \
  --from-literal=connection="$S3_CONNECTION"
SEALED_FILES+=("gitlab-s3-connection-sealed.yaml")

# --- 5. Registry storage config ---
REGISTRY_CONFIG=$(cat <<EOREG
s3_v2:
  bucket: edgecloudinfra-gitlab
  accesskey: "${S3_ACCESS_KEY}"
  secretkey: "${S3_SECRET_KEY}"
  region: nbg1
  regionendpoint: https://nbg1.your-objectstorage.com
  v4auth: true
  rootdirectory: /gitlab-registry
EOREG
)
seal_secret "$NAMESPACE" gitlab-registry-storage \
  gitlab-registry-storage-sealed.yaml \
  --from-literal=config="$REGISTRY_CONFIG"
SEALED_FILES+=("gitlab-registry-storage-sealed.yaml")

# --- 6. Rails secrets ---
# Must include ALL keys GitLab 18.x needs, otherwise 2_secret_token.rb tries
# to rewrite secrets.yml to add the missing keys — which fails with EBUSY
# because the file is a subPath volume mount (cross-device rename).
RAILS_SEALED="$SCRIPT_DIR/gitlab-rails-secrets-sealed.yaml"
RAILS_SECRETS_YML=""
if [[ "$REGEN" != "--regenerate" ]] && [[ -f "$RAILS_SEALED" ]]; then
  _privkey=$(cd "$REPO_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || true
  if [[ -n "$_privkey" ]]; then
    RAILS_SECRETS_YML=$(kubeseal --recovery-unseal \
        --recovery-private-key <(echo "$_privkey") \
        < "$RAILS_SEALED" -o json 2>/dev/null \
      | jq -r '.data["secrets.yml"] // empty' \
      | base64 -d 2>/dev/null) || true
  fi
fi
if [[ -z "$RAILS_SECRETS_YML" ]]; then
  RAILS_SECRET_KEY_BASE=$(openssl rand -hex 64)
  RAILS_OTP_KEY_BASE=$(openssl rand -hex 64)
  RAILS_DB_KEY_BASE=$(openssl rand -hex 64)
  RAILS_ENCRYPTED_SETTINGS_KEY_BASE=$(openssl rand -hex 64)
  AR_PRIMARY_KEY=$(openssl rand -base64 32)
  AR_DETERMINISTIC_KEY=$(openssl rand -base64 32)
  AR_KEY_DERIVATION_SALT=$(openssl rand -base64 32)
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
else
  echo "  gitlab-rails-secrets — recovered from sealed file."
fi
seal_secret "$NAMESPACE" gitlab-rails-secrets \
  gitlab-rails-secrets-sealed.yaml \
  --from-literal=secrets.yml="$RAILS_SECRETS_YML"
SEALED_FILES+=("gitlab-rails-secrets-sealed.yaml")

echo ""
if [ ${#SEALED_FILES[@]} -eq 0 ]; then
  echo "Nothing changed — all secrets kept."
else
  ABS_FILES=()
  for f in "${SEALED_FILES[@]}"; do
    ABS_FILES+=("${SCRIPT_DIR}/${f}")
  done
  [[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
fi
