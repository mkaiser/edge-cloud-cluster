#!/bin/bash
# Seals XWiki secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed file on re-runs.
# Pass --regenerate to rotate secrets.
#
# Part B (self-contained OIDC): the OIDC client secret, the SCIM token, and the
# scoped provisioner token are sealed HERE; xwiki/authentik-provider.yaml registers
# the OIDC provider, application, access binding AND the SCIM provider live via the
# Authentik API.
#
# Generates:
#   xwiki-db-sealed.yaml                      — db-password (XWiki externalDB.customKeyRef + postgres)
#                                               superadmin-password (xwiki.cfg superadminpassword)
#   xwiki-pg-user-sealed.yaml                 — CNPG bootstrap user (username/password) for the
#                                               xwiki-pg Cluster; password == db-password.
#   oidc-client-secret-sealed.yaml            — Authentik OIDC client secret (key client-secret)
#   scim-token-sealed.yaml                    — SCIM bearer token (key scim-token; XWiki + the SCIM provider)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
set -euo pipefail

NAMESPACE="xwiki"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file so CNPG's bootstrap
# user secret is applied (wave -1) before the xwiki-pg Cluster reconciles (wave 0).
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
SEALED_FILE="$SCRIPT_DIR/xwiki-db-sealed.yaml"

DB_PASSWORD=$(        recover_or_generate "$SEALED_FILE" db-password        "$REGEN")
SUPERADMIN_PASSWORD=$(recover_or_generate "$SEALED_FILE" superadmin-password "$REGEN")

seal_secret "$NAMESPACE" xwiki-db xwiki-db-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=superadmin-password="$SUPERADMIN_PASSWORD"
SEALED_FILES+=("xwiki-db-sealed.yaml")

# CNPG bootstrap user for the xwiki-pg Cluster. password must equal db-password so
# the app (externalDB.customKeyRef → db-password) authenticates as the owner.
seal_secret "$NAMESPACE" xwiki-pg-user xwiki-pg-user-sealed.yaml \
  --from-literal=username="xwiki" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/xwiki-pg-user-sealed.yaml" "-1"
SEALED_FILES+=("xwiki-pg-user-sealed.yaml")

# CNPG barman S3 credentials (xwiki-s3-secret) — Hetzner keys from Pulumi config,
# with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG barmanObjectStore + the
# s3-buckets-job expect. wave -1 so it exists before the Cluster reconciles.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret "$NAMESPACE" xwiki-s3-secret xwiki-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/xwiki-s3-secret-sealed.yaml" "-1"
SEALED_FILES+=("xwiki-s3-secret-sealed.yaml")

# OIDC client secret (key client-secret, matching values.yaml + the provider job).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret "$NAMESPACE" xwiki-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

# SCIM bearer token (key scim-token) — consumed by postsync-extensions.yaml AND
# set as the SCIM provider's token by the authentik-provider.yaml job.
SCIM_TOKEN=$(recover_or_generate "$SCRIPT_DIR/scim-token-sealed.yaml" scim-token "$REGEN" 32)
seal_secret "$NAMESPACE" xwiki-scim-token scim-token-sealed.yaml \
  --from-literal=scim-token="$SCIM_TOKEN"
SEALED_FILES+=("scim-token-sealed.yaml")

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret "$NAMESPACE" authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"
SEALED_FILES+=("authentik-provisioner-token-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
fi
