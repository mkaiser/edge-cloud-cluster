#!/bin/bash
# Seals XWiki secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed file on re-runs.
# Pass --regenerate to rotate secrets.
# OIDC client secret is sealed separately by deployment/authentik/sealSecrets.sh.
#
# Generates:
#   xwiki-db-sealed.yaml      — db-password (XWiki externalDB.customKeyRef + postgres)
#                               superadmin-password (xwiki.cfg superadminpassword)
#   xwiki-pg-user-sealed.yaml — CNPG bootstrap user (username/password) for the
#                               xwiki-pg Cluster; password == db-password.
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
content = re.sub(
    r'(  namespace: [^\n]+\n)(?!  annotations:)',
    lambda m: m.group(0) + anno,
    content, count=1
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

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
