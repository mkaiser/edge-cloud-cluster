#!/bin/bash
# Seals Open WebUI secrets (Plan B).
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# NOTE: secret-key must be stable — rotating it invalidates all active sessions.
#
# litellm-key is the credential Open WebUI presents to the LiteLLM gateway. It is
# recovered from litellm/litellm-secrets-sealed.yaml (the LiteLLM master-key) so
# the two stay in sync. Run litellm/sealSecrets.sh FIRST.
#
# Generates:
#   open-webui-secrets-sealed.yaml          — db-password, secret-key, litellm-key
#   open-webui-pg-user-sealed.yaml          — CNPG bootstrap user (password == db-password)
#   oidc-client-secret-sealed.yaml          — Authentik OIDC client secret (key client-secret)
#   authentik-provisioner-token-sealed.yaml — scoped Authentik API token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

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

DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/open-webui-secrets-sealed.yaml" db-password "$REGEN" 24)
SECRET_KEY=$(recover_or_generate "$SCRIPT_DIR/open-webui-secrets-sealed.yaml" secret-key "$REGEN" 64)

# Credential to the LiteLLM gateway: reuse the LiteLLM master key so Open WebUI
# authenticates against the same gateway all agents use.
LITELLM_KEY=$(try_recover "$SCRIPT_DIR/../litellm/litellm-secrets-sealed.yaml" master-key)
[[ -z "$LITELLM_KEY" ]] && LITELLM_KEY=$(try_recover "$SCRIPT_DIR/open-webui-secrets-sealed.yaml" litellm-key)
if [[ -z "$LITELLM_KEY" ]]; then
  echo "ERROR: LiteLLM master key not found — run litellm/sealSecrets.sh first." >&2
  exit 1
fi

seal_secret open-webui open-webui-secrets open-webui-secrets-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=secret-key="$SECRET_KEY" \
  --from-literal=litellm-key="$LITELLM_KEY"

# CNPG bootstrap user; password must equal db-password (deployment.yaml DSN).
seal_secret open-webui open-webui-pg-user open-webui-pg-user-sealed.yaml \
  --from-literal=username="open-webui" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/open-webui-pg-user-sealed.yaml" "-1"

# CNPG barman S3 credentials (open-webui-s3-secret) — Hetzner keys from Pulumi config,
# with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG barmanObjectStore + the
# s3-buckets-job expect. wave -1 so it exists before the Cluster reconciles.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret open-webui open-webui-s3-secret open-webui-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/open-webui-s3-secret-sealed.yaml" "-1"

# OIDC client secret (key client-secret, matching deployment.yaml + provider job).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret open-webui open-webui-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret open-webui authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Open WebUI secrets" \
    "$SCRIPT_DIR/open-webui-secrets-sealed.yaml" \
    "$SCRIPT_DIR/open-webui-pg-user-sealed.yaml" \
    "$SCRIPT_DIR/open-webui-s3-secret-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
