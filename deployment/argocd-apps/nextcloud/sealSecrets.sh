#!/bin/bash
# Seals Nextcloud secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Part B (self-contained OIDC): the OIDC client secret + the scoped Authentik
# provisioner token are sealed HERE (not the central authentik bundle). The
# nextcloud authentik-provider.yaml jobs register the provider/tile live via the
# Authentik API using the scoped token.
#
# Generates:
#   nextcloud-admin-sealed.yaml               — admin username/password
#   nextcloud-db-sealed.yaml                  — PostgreSQL user + password
#   nextcloud-s3-sealed.yaml                  — Hetzner S3 access/secret key (from Pulumi config)
#   nextcloud-smtp-sealed.yaml                — SMTP host/port/login/password (from Pulumi config)
#   oidc-client-secret-sealed.yaml            — Authentik OIDC client secret (key client-secret)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
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
  --sealed-annotation=argocd.argoproj.io/sync-wave="-2" \
  --from-literal=accessKey="$S3_ACCESS" --from-literal=secretKey="$S3_SECRET"
SEALED_FILES+=("nextcloud-s3-sealed.yaml")

# CNPG barman S3 credentials — SAME Hetzner keys, but with the ACCESS_KEY_ID/
# SECRET_ACCESS_KEY key names CNPG barmanObjectStore expects (postgres.yaml). Kept
# separate from nextcloud-s3 (accessKey/secretKey) so each consumer reads its own keys.
seal_secret "$NAMESPACE" nextcloud-s3-secret nextcloud-s3-secret-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-1" \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
SEALED_FILES+=("nextcloud-s3-secret-sealed.yaml")

# Mail settings — derived entirely from the Pulumi stack (no interactive prompts).
SMTP_HOST="$(pc smtpServer)"
SMTP_PORT="$(pc smtpPort)"
SMTP_USER="$(pc smtpUsername)"
SMTP_PASS="$(pc smtpPassword)"
: "${SMTP_HOST:?smtpServer not set in Pulumi config — run scripts/secrets/setMail.sh}"
: "${SMTP_PORT:?smtpPort not set in Pulumi config — run scripts/secrets/setMail.sh}"
echo "Mail: SMTP user=${SMTP_USER} host=${SMTP_HOST}:${SMTP_PORT}"
seal_secret "$NAMESPACE" nextcloud-smtp nextcloud-smtp-sealed.yaml \
  --from-literal=smtp-host="$SMTP_HOST" --from-literal=smtp-port="$SMTP_PORT" \
  --from-literal=smtp-username="$SMTP_USER" --from-literal=smtp-password="$SMTP_PASS"
SEALED_FILES+=("nextcloud-smtp-sealed.yaml")

# OIDC client secret (key client-secret, matching postsync-configure.yaml + the
# authentik-provider.yaml job). Self-contained — no longer in the central bundle.
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret "$NAMESPACE" nextcloud-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

# Scoped Authentik provisioner token — same plaintext as the central
# AUTHENTIK_PROVISIONER_TOKEN; recovered from the bundle (preferred) or this folder.
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
