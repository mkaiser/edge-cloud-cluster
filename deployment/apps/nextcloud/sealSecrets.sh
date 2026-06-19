#!/bin/bash
# Seals Nextcloud secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
# OIDC client secret is sealed separately by deployment/authentik/sealSecrets.sh.
#
# Generates:
#   nextcloud-admin-sealed.yaml   — admin username/password
#   nextcloud-db-sealed.yaml      — PostgreSQL user + password
#   nextcloud-s3-sealed.yaml      — Hetzner S3 access/secret key (from Pulumi config)
#   nextcloud-smtp-sealed.yaml    — SMTP host/port/login/password (from Pulumi config)
set -euo pipefail

NAMESPACE="nextcloud"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file so CNPG's bootstrap
# user secret is applied (wave -1) before the nextcloud-pg Cluster reconciles (wave 0).
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

ADMIN_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/nextcloud-admin-sealed.yaml" password    "$REGEN" 20)
DB_PASSWORD=$(   recover_or_generate "$SCRIPT_DIR/nextcloud-db-sealed.yaml"    db-password "$REGEN")

seal_secret "$NAMESPACE" nextcloud-admin nextcloud-admin-sealed.yaml \
  --from-literal=username=admin --from-literal=password="$ADMIN_PASSWORD"
SEALED_FILES+=("nextcloud-admin-sealed.yaml")

# Keys match the chart's externalDatabase.existingSecret (db-username/db-password);
# the app uses this secret to connect to the CNPG nextcloud-pg-rw service.
seal_secret "$NAMESPACE" nextcloud-db nextcloud-db-sealed.yaml \
  --from-literal=db-username=nextcloud --from-literal=db-password="$DB_PASSWORD"
SEALED_FILES+=("nextcloud-db-sealed.yaml")

# CNPG bootstrap user for the nextcloud-pg Cluster — same user/password as
# nextcloud-db, but with the username/password key names CNPG initdb requires.
seal_secret "$NAMESPACE" nextcloud-pg-user nextcloud-pg-user-sealed.yaml \
  --from-literal=username="nextcloud" --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/nextcloud-pg-user-sealed.yaml" "-1"
SEALED_FILES+=("nextcloud-pg-user-sealed.yaml")

# S3 credentials from Pulumi config (same Hetzner object store used elsewhere).
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
seal_secret "$NAMESPACE" nextcloud-s3 nextcloud-s3-sealed.yaml \
  --from-literal=accessKey="$S3_ACCESS" --from-literal=secretKey="$S3_SECRET"
SEALED_FILES+=("nextcloud-s3-sealed.yaml")

# Mail settings — derived entirely from the Pulumi stack (no interactive prompts).
SMTP_HOST="$(pc smtpServer)"
SMTP_PORT="$(pc smtpPort)"
SMTP_USER="$(pc smtpUsername)"
SMTP_PASS="$(pc smtpPassword)"
: "${SMTP_HOST:?smtpServer not set in Pulumi config — run scripts/secrets/setMailCredentials.sh}"
: "${SMTP_PORT:?smtpPort not set in Pulumi config — run scripts/secrets/setMailCredentials.sh}"
echo "Mail: SMTP ${SMTP_USER}@${SMTP_HOST}:${SMTP_PORT}"
seal_secret "$NAMESPACE" nextcloud-smtp nextcloud-smtp-sealed.yaml \
  --from-literal=smtp-host="$SMTP_HOST" --from-literal=smtp-port="$SMTP_PORT" \
  --from-literal=smtp-username="$SMTP_USER" --from-literal=smtp-password="$SMTP_PASS"
SEALED_FILES+=("nextcloud-smtp-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
