#!/bin/bash
# Seals Zammad-specific secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Part B (self-contained OIDC): the scoped provisioner token is sealed HERE;
# zammad/authentik-provider.yaml registers the provider live. There is NO OIDC
# client secret — Zammad uses a PUBLIC client with PKCE (see NOTES.md).
#
# Generates:
#   zammad-db-sealed.yaml                     — DB password consumed by the chart
#                                               (secrets.postgresql, key db-password)
#   zammad-pg-user-sealed.yaml                — CNPG bootstrap user (username/password) for the
#                                               zammad-pg Cluster; password == db-password.
#   zammad-redis-auth-sealed.yaml             — redis requirepass (key redis-password); the chart
#                                               builds REDIS_URL around it, so it cannot be empty.
#   zammad-s3-secret-sealed.yaml              — Hetzner S3 keys for CNPG barman + the bucket job
#   zammad-s3-url-sealed.yaml                 — S3_URL for ticket attachments (key s3-url)
#   zammad-autowizard-sealed.yaml             — initial admin/autowizard JSON (key autowizard)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
#
# NOTE: all generated values are openssl hex, so they are URL-safe — required
# because the DB and S3 passwords are embedded in URLs (S3_URL, DATABASE_URL).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file so CNPG's bootstrap
# user secret is applied (wave -1) before the zammad-pg Cluster reconciles (wave 0).
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

DB_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zammad-db-sealed.yaml" db-password "$REGEN" 24)

# Consumed by the chart via secrets.postgresql (useExisting: true).
seal_secret zammad zammad-db zammad-db-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD"

# CNPG bootstrap user for the zammad-pg Cluster. password must equal db-password
# so the app (which uses db-password) authenticates as the database owner.
seal_secret zammad zammad-pg-user zammad-pg-user-sealed.yaml \
  --from-literal=username="zammad" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/zammad-pg-user-sealed.yaml" "-1"

# Redis password. Unlike the repo's other redis instances this MUST be set: the
# chart hardcodes REDIS_URL as "redis://:$(REDIS_PASSWORD)@host:port" and only
# emits REDIS_PASSWORD when a password is configured, so an unauthenticated redis
# would leave Rails using the literal string "$(REDIS_PASSWORD)".
# datastores.yaml passes the same value to redis-server --requirepass.
REDIS_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zammad-redis-auth-sealed.yaml" redis-password "$REGEN" 24)
seal_secret zammad zammad-redis-auth zammad-redis-auth-sealed.yaml \
  --from-literal=redis-password="$REDIS_PASSWORD"

# CNPG barman S3 credentials (zammad-s3-secret) — Hetzner keys from Pulumi config,
# with the ACCESS_KEY_ID/SECRET_ACCESS_KEY names CNPG barmanObjectStore + the
# s3-buckets-job expect. wave -1 so it exists before the Cluster reconciles.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret zammad zammad-s3-secret zammad-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/zammad-s3-secret-sealed.yaml" "-1"

# S3_URL for ticket attachments (chart secrets.s3 -> env S3_URL). Single
# connection string carrying credentials, endpoint, bucket and region.
# force_path_style=true: Hetzner object storage does not do virtual-host buckets.
S3_ENDPOINT_HOST="nbg1.your-objectstorage.com" # automatically updated from project-settings:storage.objectStorage.baseEndpoint
S3_REGION="nbg1" # automatically updated from project-settings:storage.objectStorage.baseEndpoint
S3_BUCKET="edgecloudinfra-zammad" # automatically updated from project-settings:{general.name,storage.objectStorage.buckets}
S3_URL="https://${S3_ACCESS}:${S3_SECRET}@${S3_ENDPOINT_HOST}/${S3_BUCKET}?region=${S3_REGION}&force_path_style=true"
seal_secret zammad zammad-s3-url zammad-s3-url-sealed.yaml \
  --from-literal=s3-url="$S3_URL"
add_sync_wave "$SCRIPT_DIR/zammad-s3-url-sealed.yaml" "-1"

# Autowizard: creates the initial admin non-interactively on first boot, so a
# cluster recreate needs no manual getting-started wizard. Chart >= 10 wants the
# RAW JSON (not base64) in the secret value.
# Real users arrive via Authentik OIDC; this account is the break-glass admin.
AUTOWIZARD_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zammad-autowizard-sealed.yaml" autowizard-password "$REGEN" 20)
ADMIN_EMAIL="no-reply@your-domain.tld" # automatically updated from project-settings:mail.senderEmail
AUTOWIZARD_JSON=$(ADMIN_EMAIL="$ADMIN_EMAIL" AUTOWIZARD_PASSWORD="$AUTOWIZARD_PASSWORD" python3 -c "
import json, os
print(json.dumps({
  'TextModuleLocale': {'Locale': 'en-us'},
  'Users': [{
    'login':     os.environ['ADMIN_EMAIL'],
    'firstname': 'Zammad',
    'lastname':  'Admin',
    'email':     os.environ['ADMIN_EMAIL'],
    'password':  os.environ['AUTOWIZARD_PASSWORD'],
  }],
}))
")
# The password is kept as its own key so re-runs can recover it (the JSON blob
# itself is not parsed back by recover_or_generate).
seal_secret zammad zammad-autowizard zammad-autowizard-sealed.yaml \
  --from-literal=autowizard="$AUTOWIZARD_JSON" \
  --from-literal=autowizard-password="$AUTOWIZARD_PASSWORD"
add_sync_wave "$SCRIPT_DIR/zammad-autowizard-sealed.yaml" "-1"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret zammad authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit would look like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Zammad secrets" \
    "$SCRIPT_DIR/zammad-db-sealed.yaml" \
    "$SCRIPT_DIR/zammad-pg-user-sealed.yaml" \
    "$SCRIPT_DIR/zammad-redis-auth-sealed.yaml" \
    "$SCRIPT_DIR/zammad-s3-secret-sealed.yaml" \
    "$SCRIPT_DIR/zammad-s3-url-sealed.yaml" \
    "$SCRIPT_DIR/zammad-autowizard-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
