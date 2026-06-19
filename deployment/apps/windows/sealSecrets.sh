#!/bin/bash
# Seals Windows/Guacamole secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Generates:
#   windows-secrets-sealed.yaml   — DB password + Windows VM credentials
#   guacamole-pg-user-sealed.yaml — CNPG bootstrap user (username/password) for the
#                                   guacamole-pg Cluster; password == db-password.
set -euo pipefail

NAMESPACE="windows"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file so CNPG's bootstrap
# user secret is applied (wave -1) before the guacamole-pg Cluster reconciles (wave 0).
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

DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/windows-secrets-sealed.yaml" db-password "$REGEN")

echo "Windows admin credentials (set WINDOWS_USERNAME / WINDOWS_PASSWORD env vars to override):"
WIN_USER="${WINDOWS_USERNAME:-WinAdmin}"
WIN_PASS="${WINDOWS_PASSWORD:-$(recover_or_generate "$SCRIPT_DIR/windows-secrets-sealed.yaml" WINDOWS_PASSWORD "$REGEN")}"

seal_secret "$NAMESPACE" windows-secrets windows-secrets-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=WINDOWS_USERNAME="$WIN_USER" \
  --from-literal=WINDOWS_PASSWORD="$WIN_PASS"
SEALED_FILES+=("windows-secrets-sealed.yaml")

# CNPG bootstrap user for the guacamole-pg Cluster. password must equal db-password
# so the app + connection-seed job (which use windows-secrets:db-password)
# authenticate as the guacamole_user owner.
seal_secret "$NAMESPACE" guacamole-pg-user guacamole-pg-user-sealed.yaml \
  --from-literal=username="guacamole_user" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/guacamole-pg-user-sealed.yaml" "-1"
SEALED_FILES+=("guacamole-pg-user-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal windows secrets" "${ABS_FILES[@]}"
