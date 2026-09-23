#!/bin/bash
# Seals LiteLLM gateway secrets (Plan B).
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# NOTE: master-key and salt-key must be stable — salt-key rotation makes every
# secret LiteLLM stored in its DB undecryptable; master-key rotation breaks admin.
#
# vllm-api-key / vllm-orin-api-key are the vLLM upstream credentials — ONE PER BACKEND
# (vllm = Thor, vllm-orin = Orin). Each is recovered from the app that owns it, so that
# app and this one seal the SAME plaintext. Run vllm/sealSecrets.sh AND
# vllm-orin/sealSecrets.sh FIRST; if you rotate either there, re-run this too.
#
# They are deliberately NOT one shared key: two independent serving backends should not
# share a credential, so rotating or compromising one cannot reach the other. LiteLLM is
# the only party that holds both.
#
# Generates:
#   litellm-secrets-sealed.yaml            — master-key, salt-key, db-password, vllm-api-key, vllm-orin-api-key, admin-username, admin-password
#   litellm-pg-user-sealed.yaml            — CNPG bootstrap user (password == db-password)
#   oidc-client-secret-sealed.yaml         — Authentik OIDC client secret (key client-secret)
#   authentik-provisioner-token-sealed.yaml — scoped Authentik API token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

# Add a sync-wave annotation to a sealed secret file (top-level metadata only) so
# the CNPG bootstrap user secret is applied (wave -1) before the Cluster (wave 0).
add_sync_wave() {
  local file="$1" wave="$2"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
if 'argocd.argoproj.io/sync-wave' in content:
    sys.exit(0)
content = re.sub(
    r'(^  namespace: [^\n]+\n)',
    lambda m: m.group(0) + anno,
    content, count=1, flags=re.MULTILINE
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$file" "$wave"
}

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

MASTER_KEY=$(recover_or_generate "$SCRIPT_DIR/litellm-secrets-sealed.yaml" master-key "$REGEN" 32)
SALT_KEY=$(recover_or_generate "$SCRIPT_DIR/litellm-secrets-sealed.yaml" salt-key "$REGEN" 32)
DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/litellm-secrets-sealed.yaml" db-password "$REGEN" 24)
# Dedicated local admin for the /ui login (UI_USERNAME/UI_PASSWORD in deployment.yaml).
# A username+password match promotes the session to PROXY_ADMIN — full model/key
# management — WITHOUT the master key and WITHOUT SSO. Fixed username, generated
# password (hex → form-safe). Rotate the password with --regenerate.
ADMIN_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/litellm-secrets-sealed.yaml" admin-password "$REGEN" 20)

# Shared vLLM upstream keys — ONE PER BACKEND. Each vLLM app owns its own credential so
# rotating or compromising one cannot reach the other; LiteLLM is the only party holding
# both. Recover from the owning app's sealed file first, then from ours, so they stay in
# sync. If neither exists the owning app has not been sealed yet — that is an error, not
# something to paper over with a fresh random value the server would never accept.
VLLM_API_KEY=$(try_recover "$SCRIPT_DIR/../vllm/vllm-upstream-sealed.yaml" api-key)
[[ -z "$VLLM_API_KEY" ]] && VLLM_API_KEY=$(try_recover "$SCRIPT_DIR/litellm-secrets-sealed.yaml" vllm-api-key)
if [[ -z "$VLLM_API_KEY" ]]; then
  echo "ERROR: vLLM (Thor) upstream key not found — run vllm/sealSecrets.sh first." >&2
  exit 1
fi

VLLM_ORIN_API_KEY=$(try_recover "$SCRIPT_DIR/../vllm-orin/vllm-orin-upstream-sealed.yaml" api-key)
[[ -z "$VLLM_ORIN_API_KEY" ]] && VLLM_ORIN_API_KEY=$(try_recover "$SCRIPT_DIR/litellm-secrets-sealed.yaml" vllm-orin-api-key)
if [[ -z "$VLLM_ORIN_API_KEY" ]]; then
  echo "ERROR: vLLM (Orin) upstream key not found — run vllm-orin/sealSecrets.sh first." >&2
  exit 1
fi

# LiteLLM master key convention is an sk- prefix.
[[ "$MASTER_KEY" == sk-* ]] || MASTER_KEY="sk-${MASTER_KEY}"

seal_secret litellm litellm-secrets litellm-secrets-sealed.yaml \
  --from-literal=master-key="$MASTER_KEY" \
  --from-literal=salt-key="$SALT_KEY" \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=vllm-api-key="$VLLM_API_KEY" \
  --from-literal=vllm-orin-api-key="$VLLM_ORIN_API_KEY" \
  --from-literal=admin-username="litellm-admin" \
  --from-literal=admin-password="$ADMIN_PASSWORD"

# CNPG bootstrap user; password must equal db-password (deployment.yaml DSN).
seal_secret litellm litellm-pg-user litellm-pg-user-sealed.yaml \
  --from-literal=username="litellm" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/litellm-pg-user-sealed.yaml" "-1"

# CNPG barman S3 credentials (litellm-s3-secret) — Hetzner keys from Pulumi config,
# with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG barmanObjectStore + the
# s3-buckets-job expect. wave -1 so it exists before the Cluster reconciles.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret litellm litellm-s3-secret litellm-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/litellm-s3-secret-sealed.yaml" "-1"

# OIDC client secret (key client-secret, matching deployment.yaml + provider job).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret litellm litellm-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret litellm authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal LiteLLM secrets" \
    "$SCRIPT_DIR/litellm-secrets-sealed.yaml" \
    "$SCRIPT_DIR/litellm-pg-user-sealed.yaml" \
    "$SCRIPT_DIR/litellm-s3-secret-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
