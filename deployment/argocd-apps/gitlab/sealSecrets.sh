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

# --- 1. Root password ---
# The root/admin email is supplied via the postsync bootstrap job's ROOT_EMAIL env
# (project_settings.ts senderEmail), see postsync-bootstrap-gitlab-runner-secrets.yaml.
ROOT_SEALED="$SCRIPT_DIR/gitlab-root-password-sealed.yaml"

EXISTING_PASS=$(try_recover "$ROOT_SEALED" password)

GITLAB_ROOT_PASSWORD=""; _need_enter="false"
if [[ -n "$EXISTING_PASS" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "gitlab-root-password" "true" "true"
  case "$KEG_CHOICE" in
    keep)
      echo "  gitlab-root-password — kept."
      GITLAB_ROOT_PASSWORD="$EXISTING_PASS"
      ;;
    generate)
      GITLAB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 20)
      echo "  Generated new GitLab root password."
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
fi

seal_secret "$NAMESPACE" gitlab-root-password \
  gitlab-root-password-sealed.yaml \
  --from-literal=password="$GITLAB_ROOT_PASSWORD"
SEALED_FILES+=("gitlab-root-password-sealed.yaml")

# --- 2. OIDC secrets: generated dynamically by presync-oidc-secrets.yaml ---
echo "  OIDC secrets: managed by presync-oidc-secrets.yaml (no sealing needed)."

# --- 3. External PostgreSQL DB password ---
DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/gitlab-db-sealed.yaml" db-password "$REGEN")
seal_secret "$NAMESPACE" gitlab-db gitlab-db-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD"
SEALED_FILES+=("gitlab-db-sealed.yaml")

# --- 3b. CNPG bootstrap user for the gitlab-pg Cluster (postgres.yaml) ---
# Same user (`gitlab`) + password as gitlab-db, with the username/password key
# names CNPG initdb requires, so the chart (global.psql → gitlab-db) and CNPG share
# one credential. sync-wave -1 so it exists before the Cluster reconciles at wave 0.
seal_secret "$NAMESPACE" gitlab-pg-user gitlab-pg-user-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-1" \
  --from-literal=username="gitlab" \
  --from-literal=password="$DB_PASSWORD"
SEALED_FILES+=("gitlab-pg-user-sealed.yaml")

# --- 4. S3 connection ---
echo "Reading S3 credentials from Pulumi config..."
S3_ACCESS_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3AccessKey)
S3_SECRET_KEY=$(cd "$REPO_DIR" && pulumi config get hetznerS3SecretKey)
echo "  S3 access key, S3 secret key: OK"

# --- 4b. CNPG barman S3 credentials (gitlab-s3-secret) ---
# Same Hetzner keys, but with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG
# barmanObjectStore + the s3-buckets-job expect (gitlab-s3-connection is a YAML blob,
# wrong shape for barman). wave -1 so it exists before the Cluster reconciles.
seal_secret "$NAMESPACE" gitlab-s3-secret gitlab-s3-secret-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-1" \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  --from-literal=SECRET_ACCESS_KEY="$S3_SECRET_KEY"
SEALED_FILES+=("gitlab-s3-secret-sealed.yaml")

S3_CONNECTION=$(cat <<EOCONN
provider: AWS
region: nbg1 # automatically updated from project-settings:storage.objectStorage.baseEndpoint
aws_access_key_id: "${S3_ACCESS_KEY}"
aws_secret_access_key: "${S3_SECRET_KEY}"
endpoint: https://nbg1.your-objectstorage.com # automatically updated from project-settings:storage.objectStorage.baseEndpoint
path_style: false
EOCONN
)
seal_secret "$NAMESPACE" gitlab-s3-connection \
  gitlab-s3-connection-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-2" \
  --from-literal=connection="$S3_CONNECTION"
SEALED_FILES+=("gitlab-s3-connection-sealed.yaml")

# --- 4b. On-prem S3 connection (CI artifacts on the appliance) ---
# ⚠ RECOVERED, NEVER GENERATED. These are the same credentials the appliance's SeaweedFS
# app was configured with, sealed by deployment/argocd-infra/truenas/sealSecrets.sh.
# Generating a fresh pair here would seal a credential the endpoint has never heard of, and
# the symptom is SignatureDoesNotMatch — which reads like a clock or path-style problem, not
# a wrong key. Rotating there means re-running this script.
TN_S3_SEALED="$REPO_DIR/deployment/argocd-infra/truenas/truenas-s3-admin-sealed.yaml"
ONPREM_AK=$(recover_from_sealed "$TN_S3_SEALED" S3_ACCESS_KEY)
ONPREM_SK=$(recover_from_sealed "$TN_S3_SEALED" S3_SECRET_KEY)

# ⚠ path_style MUST be true. The endpoint is an in-cluster Service name; virtual-host style
# would send requests to <bucket>.gitlab-s3-proxy... which resolves to nothing.
# ⚠ The endpoint is also the host GitLab SIGNS against, so it must match a SAN on the
# appliance listener's certificate — truenas/s3-app-job.yaml mints it with exactly this name.
ONPREM_CONNECTION=$(cat <<EOONPREM
provider: AWS
region: nbg1
aws_access_key_id: "${ONPREM_AK}"
aws_secret_access_key: "${ONPREM_SK}"
endpoint: https://gitlab-s3-proxy.gitlab-s3-proxy.svc.cluster.local:30304
path_style: true
EOONPREM
)
seal_secret "$NAMESPACE" gitlab-s3-onprem-connection \
  gitlab-s3-onprem-connection-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-2" \
  --from-literal=connection="$ONPREM_CONNECTION"
SEALED_FILES+=("gitlab-s3-onprem-connection-sealed.yaml")

# --- 5. Registry storage config ---
REGISTRY_CONFIG=$(cat <<EOREG
s3_v2:
  bucket: edgecloudinfra-gitlab-registry # automatically updated from project-settings:{general.name,storage.objectStorage.buckets}
  accesskey: "${S3_ACCESS_KEY}"
  secretkey: "${S3_SECRET_KEY}"
  region: nbg1 # automatically updated from project-settings:storage.objectStorage.baseEndpoint
  regionendpoint: https://nbg1.your-objectstorage.com # automatically updated from project-settings:storage.objectStorage.baseEndpoint
  v4auth: true
  # Bucket-root: the registry has its own bucket, so a /gitlab-registry rootdirectory
  # would only nest one prefix inside a dedicated bucket.
  rootdirectory: /
  # Throttle outbound S3 requests to stay under Hetzner Object Storage (Ceph RGW,
  # nbg1) per-bucket rate limits. A multi-GB image push (e.g. the 6.35 GB vLLM Thor
  # image, ~15 layers) fires a storm of concurrent PutObject/ListMultipartUploads/
  # HeadObject calls; without a cap the RGW returns "503 SlowDown", the AWS SDK's
  # client-side retry quota drains ("retry quota exceeded, 0 available"), and the
  # registry surfaces a bare HTTP 500 to buildah — the push then fails every retry.
  # maxrequestspersecond keeps the registry below the RGW limit so SlowDown never
  # trips; maxretries widens the SDK budget to ride out any residual throttling.
  maxrequestspersecond: 100
  maxretries: 10
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
