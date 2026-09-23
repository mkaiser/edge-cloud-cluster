#!/bin/bash
# Seals Rallly-specific secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Part B (self-contained OIDC): the OIDC client secret + scoped provisioner token
# are sealed HERE; rallly/authentik-provider.yaml registers the provider live.
#
# NOTE: secret-password must be stable — rotating it invalidates all active sessions.
#
# Generates:
#   rallly-secrets-sealed.yaml                — PostgreSQL password + Next.js session key
#   rallly-pg-user-sealed.yaml                — CNPG bootstrap user (username/password) for the
#                                               rallly-pg Cluster; password == db-password.
#   oidc-client-secret-sealed.yaml            — Authentik OIDC client secret (key client-secret)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file so CNPG's bootstrap
# user secret is applied (wave -1) before the rallly-pg Cluster reconciles (wave 0).
add_sync_wave() {
  local file="$1" wave="$2"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
# Idempotent: if a sync-wave annotation already exists anywhere, leave the file
# alone (re-runs must not append a second, mis-indented block).
if 'argocd.argoproj.io/sync-wave' in content:
    sys.exit(0)
# Anchor to the TOP-LEVEL metadata.namespace only (exactly 2-space indent at
# line start). Without ^ + MULTILINE the old regex also matched the 6-space
# template.metadata.namespace and inserted a 2-space 'annotations:' under spec
# (structurally invalid -> the SealedSecret never applied).
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

DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/rallly-secrets-sealed.yaml" db-password "$REGEN" 24)
SECRET_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/rallly-secrets-sealed.yaml" secret-password "$REGEN" 64)

seal_secret rallly rallly-secrets rallly-secrets-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=secret-password="$SECRET_PASSWORD"

# CNPG bootstrap user for the rallly-pg Cluster. password must equal db-password
# so the app's DATABASE_URL (which uses db-password) authenticates as the owner.
seal_secret rallly rallly-pg-user rallly-pg-user-sealed.yaml \
  --from-literal=username="rallly" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/rallly-pg-user-sealed.yaml" "-1"

# CNPG barman S3 credentials (rallly-s3-secret) — Hetzner keys from Pulumi config,
# with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG barmanObjectStore + the
# s3-buckets-job expect. wave -1 so it exists before the Cluster reconciles.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret rallly rallly-s3-secret rallly-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/rallly-s3-secret-sealed.yaml" "-1"

# OIDC client secret (key client-secret, matching deployment.yaml + provider job).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret rallly rallly-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret rallly authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Rallly secrets" \
    "$SCRIPT_DIR/rallly-secrets-sealed.yaml" \
    "$SCRIPT_DIR/rallly-pg-user-sealed.yaml" \
    "$SCRIPT_DIR/rallly-s3-secret-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
