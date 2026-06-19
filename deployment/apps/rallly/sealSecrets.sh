#!/bin/bash
# Seals Rallly-specific secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
# OIDC client secret is sealed separately by deployment/infrastructure/authentik/sealSecrets.sh
# (produces rallly/oidc-client-secret-sealed.yaml with key client-secret).
#
# NOTE: secret-password must be stable — rotating it invalidates all active sessions.
#
# Generates:
#   rallly-secrets-sealed.yaml   — PostgreSQL password + Next.js session key
#   rallly-pg-user-sealed.yaml   — CNPG bootstrap user (username/password) for the
#                                  rallly-pg Cluster; password == db-password.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal Rallly secrets" \
  "$SCRIPT_DIR/rallly-secrets-sealed.yaml" \
  "$SCRIPT_DIR/rallly-pg-user-sealed.yaml"
