#!/bin/bash
# Seals Authentik secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed bundle on re-runs.
# Pass --regenerate to rotate all secrets.
#
# The authentik-secrets bundle is the canonical source for all OIDC client secrets.
# Run this script before any client-app sealSecrets.sh that calls recover_from_sealed.
#
# Generates:
#   authentik/authentik-secrets-sealed.yaml                  — authentik core + DB + bootstrap + all OIDC client secrets
#   argocd-infra/argocd-oidc-secret-sealed.yaml              — argocd client secret (key oidc.clientSecret)
#   headscale/oidc-client-secret-sealed.yaml                 — headscale client secret (key client-secret)
#   nextcloud/oidc-client-secret-sealed.yaml                 — nextcloud client secret
#   xwiki/oidc-client-secret-sealed.yaml                     — xwiki client secret
#   kube-prometheus-stack/grafana-oidc-secret-sealed.yaml    — grafana OIDC client secret (key GRAFANA_OIDC_CLIENT_SECRET)
#   zulip/oidc-client-secret-sealed.yaml                     — zulip OIDC client secret (key SECRET_social_auth_oidc_secret)
# NOTE: gitlab OIDC client secret is NOT sealed here — presync-oidc-secrets.yaml creates it dynamically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# Add argocd sync-wave annotation to a sealed secret file so it is applied
# at that wave within the Application (before the CNPG Cluster at wave 0).
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

BUNDLE="$SCRIPT_DIR/authentik-secrets-sealed.yaml"

echo "Configuring Authentik secrets..."
AUTHENTIK_SECRET_KEY=$(recover_or_generate "$BUNDLE" AUTHENTIK_SECRET_KEY         "$REGEN" 50)
DB_PASSWORD=$(         recover_or_generate "$BUNDLE" AUTHENTIK_POSTGRESQL__PASSWORD "$REGEN")
PG_ADMIN_PASSWORD=$(   recover_or_generate "$BUNDLE" postgres-password             "$REGEN")
BOOTSTRAP_TOKEN=$(     recover_or_generate "$BUNDLE" AUTHENTIK_BOOTSTRAP_TOKEN     "$REGEN" 32)
BOOTSTRAP_PASSWORD=$(  recover_or_generate "$BUNDLE" AUTHENTIK_BOOTSTRAP_PASSWORD  "$REGEN" 16)
ARGOCD_OIDC=$(         recover_or_generate "$BUNDLE" ARGOCD_OIDC_CLIENT_SECRET     "$REGEN" 32)
HEADSCALE_OIDC=$(      recover_or_generate "$BUNDLE" HEADSCALE_OIDC_CLIENT_SECRET  "$REGEN" 32)
NEXTCLOUD_OIDC=$(      recover_or_generate "$BUNDLE" NEXTCLOUD_OIDC_CLIENT_SECRET  "$REGEN" 32)
XWIKI_OIDC=$(          recover_or_generate "$BUNDLE" XWIKI_OIDC_CLIENT_SECRET      "$REGEN" 32)
GITLAB_OIDC=$(         recover_or_generate "$BUNDLE" GITLAB_OIDC_CLIENT_SECRET     "$REGEN" 32)
GRAFANA_OIDC=$(        recover_or_generate "$BUNDLE" GRAFANA_OIDC_CLIENT_SECRET    "$REGEN" 32)
ZULIP_OIDC=$(          recover_or_generate "$BUNDLE" ZULIP_OIDC_CLIENT_SECRET      "$REGEN" 32)
RALLLY_OIDC=$(         recover_or_generate "$BUNDLE" RALLLY_OIDC_CLIENT_SECRET     "$REGEN" 32)
NEXTCLOUD_SCIM=$(      recover_or_generate "$BUNDLE" NEXTCLOUD_SCIM_TOKEN          "$REGEN" 32)
XWIKI_SCIM=$(          recover_or_generate "$BUNDLE" XWIKI_SCIM_TOKEN              "$REGEN" 32)


# CLUSTER ADMIN credentials: username, password, email
# clusteradmin username 
_existing_admin_user=$(try_recover "$BUNDLE" CLUSTER_ADMIN_USERNAME)
CLUSTER_ADMIN_USERNAME=""
if [[ -n "$_existing_admin_user" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "clusteradmin username" "true" "false"
  [[ "$KEG_CHOICE" == "keep" ]] && CLUSTER_ADMIN_USERNAME="$_existing_admin_user"
fi
if [[ -z "$CLUSTER_ADMIN_USERNAME" ]]; then
  _default="${_existing_admin_user:-clusteradmin}"
  read -rp "  cluster admin username [${_default}]: " CLUSTER_ADMIN_USERNAME
  [[ -z "$CLUSTER_ADMIN_USERNAME" ]] && CLUSTER_ADMIN_USERNAME="$_default"
fi

# clusteradmin password
_existing_admin_pass=$(try_recover "$BUNDLE" CLUSTER_ADMIN_PASSWORD)
CLUSTER_ADMIN_PASSWORD=""
if [[ -n "$_existing_admin_pass" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "clusteradmin password" "true" "true"
  case "$KEG_CHOICE" in
    keep)     CLUSTER_ADMIN_PASSWORD="$_existing_admin_pass" ;;
    generate) CLUSTER_ADMIN_PASSWORD=$(openssl rand -base64 16) ;;
  esac
fi
if [[ -z "$CLUSTER_ADMIN_PASSWORD" ]]; then
  if [[ -z "$_existing_admin_pass" ]]; then
    prompt_keg "clusteradmin password" "false" "true"
    [[ "$KEG_CHOICE" == "generate" ]] && CLUSTER_ADMIN_PASSWORD=$(openssl rand -base64 16)
  fi
  if [[ -z "$CLUSTER_ADMIN_PASSWORD" ]]; then
    while true; do
      read -rsp "  clusteradmin password: " CLUSTER_ADMIN_PASSWORD; echo
      read -rsp "  Confirm: " _c; echo
      [[ "$CLUSTER_ADMIN_PASSWORD" == "$_c" ]] && [[ -n "$CLUSTER_ADMIN_PASSWORD" ]] && break
      echo "  Mismatch or empty — try again."
    done
  fi
fi

# clusteradmin email
_existing_admin_email=$(try_recover "$BUNDLE" CLUSTER_ADMIN_EMAIL)
CLUSTER_ADMIN_EMAIL=""
if [[ -n "$_existing_admin_email" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "clusteradmin email" "true" "false"
  [[ "$KEG_CHOICE" == "keep" ]] && CLUSTER_ADMIN_EMAIL="$_existing_admin_email"
fi
if [[ -z "$CLUSTER_ADMIN_EMAIL" ]]; then
  _hint=""; [[ -n "$_existing_admin_email" ]] && _hint=" [enter to keep: $_existing_admin_email]"
  read -rp "  clusteradmin email${_hint}: " CLUSTER_ADMIN_EMAIL
  [[ -z "$CLUSTER_ADMIN_EMAIL" ]] && CLUSTER_ADMIN_EMAIL="$_existing_admin_email"
fi


# TEST USER credentials: username, password, email
# testuser username
_existing_test_user=$(try_recover "$BUNDLE" TEST_USER_USERNAME)
TEST_USER_USERNAME=""
if [[ -n "$_existing_test_user" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "testuser username" "true" "false"
  [[ "$KEG_CHOICE" == "keep" ]] && TEST_USER_USERNAME="$_existing_test_user"
fi
if [[ -z "$TEST_USER_USERNAME" ]]; then
  _default="${_existing_test_user:-testuser}"
  read -rp "  test user username [${_default}]: " TEST_USER_USERNAME
  [[ -z "$TEST_USER_USERNAME" ]] && TEST_USER_USERNAME="$_default"
fi

# testuser password
_existing_user_pass=$(try_recover "$BUNDLE" TEST_USER_PASSWORD)
TEST_USER_PASSWORD=""
if [[ -n "$_existing_user_pass" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "testuser password" "true" "true"
  case "$KEG_CHOICE" in
    keep)     TEST_USER_PASSWORD="$_existing_user_pass" ;;
    generate) TEST_USER_PASSWORD=$(openssl rand -base64 16) ;;
  esac
fi
if [[ -z "$TEST_USER_PASSWORD" ]]; then
  if [[ -z "$_existing_user_pass" ]]; then
    prompt_keg "testuser password" "false" "true"
    [[ "$KEG_CHOICE" == "generate" ]] && TEST_USER_PASSWORD=$(openssl rand -base64 16)
  fi
  if [[ -z "$TEST_USER_PASSWORD" ]]; then
    while true; do
      read -rsp "  testuser password: " TEST_USER_PASSWORD; echo
      read -rsp "  Confirm: " _c; echo
      [[ "$TEST_USER_PASSWORD" == "$_c" ]] && [[ -n "$TEST_USER_PASSWORD" ]] && break
      echo "  Mismatch or empty — try again."
    done
  fi
fi

# testuser email
_existing_user_email=$(try_recover "$BUNDLE" TEST_USER_EMAIL)
TEST_USER_EMAIL=""
if [[ -n "$_existing_user_email" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "testuser email" "true" "false"
  [[ "$KEG_CHOICE" == "keep" ]] && TEST_USER_EMAIL="$_existing_user_email"
fi
if [[ -z "$TEST_USER_EMAIL" ]]; then
  _hint=""; [[ -n "$_existing_user_email" ]] && _hint=" [enter to keep: $_existing_user_email]"
  read -rp "  testuser email${_hint}: " TEST_USER_EMAIL
  [[ -z "$TEST_USER_EMAIL" ]] && TEST_USER_EMAIL="$_existing_user_email"
fi

if [[ "$CLUSTER_ADMIN_EMAIL" == "$TEST_USER_EMAIL" ]]; then
  echo "WARNING: clusteradmin and testuser share the same email (${CLUSTER_ADMIN_EMAIL})."
  echo "         Authentik email login is ambiguous when emails are not unique."
  echo "         Use username-based login or assign distinct emails."
fi

# Full SMTP relay config for Authentik outgoing mail (enrollment email
# verification + notifications). Sourced from Pulumi config (same relay used by
# argocd/nextcloud/grafana) and sealed in its ENTIRETY into the authentik-smtp
# secret as AUTHENTIK_EMAIL__* env vars (injected via global.envFrom in
# values.yaml), so nothing about the mail relay appears in git. from == username.
# use_tls/use_ssl/timeout are constants matching the relay (587/STARTTLS).
pcfg() { (cd "$SCRIPT_DIR/../.." && pulumi config get "$1" 2>/dev/null || true); }
SMTP_HOST=$(pcfg smtpServer)
SMTP_PORT=$(pcfg smtpPort)
SMTP_USERNAME=$(pcfg smtpUsername)
SMTP_PASSWORD=$(pcfg smtpPassword)
SMTP_FROM="$SMTP_USERNAME"
[[ -z "$SMTP_HOST"     ]] && { echo "ERROR: smtpServer not in Pulumi config — needed for authentik-smtp"   >&2; exit 1; }
[[ -z "$SMTP_PORT"     ]] && { echo "ERROR: smtpPort not in Pulumi config — needed for authentik-smtp"     >&2; exit 1; }
[[ -z "$SMTP_USERNAME" ]] && { echo "ERROR: smtpUsername not in Pulumi config — needed for authentik-smtp" >&2; exit 1; }
[[ -z "$SMTP_PASSWORD" ]] && { echo "ERROR: smtpPassword not in Pulumi config — needed for authentik-smtp" >&2; exit 1; }

# --- authentik-secrets bundle (IdP side) ---
seal_secret authentik authentik-secrets authentik-secrets-sealed.yaml \
  --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$DB_PASSWORD" \
  --from-literal=password="$DB_PASSWORD" \
  --from-literal=postgres-password="$PG_ADMIN_PASSWORD" \
  --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$BOOTSTRAP_TOKEN" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASSWORD" \
  --from-literal=ARGOCD_OIDC_CLIENT_SECRET="$ARGOCD_OIDC" \
  --from-literal=HEADSCALE_OIDC_CLIENT_SECRET="$HEADSCALE_OIDC" \
  --from-literal=NEXTCLOUD_OIDC_CLIENT_SECRET="$NEXTCLOUD_OIDC" \
  --from-literal=XWIKI_OIDC_CLIENT_SECRET="$XWIKI_OIDC" \
  --from-literal=GITLAB_OIDC_CLIENT_SECRET="$GITLAB_OIDC" \
  --from-literal=GRAFANA_OIDC_CLIENT_SECRET="$GRAFANA_OIDC" \
  --from-literal=ZULIP_OIDC_CLIENT_SECRET="$ZULIP_OIDC" \
  --from-literal=RALLLY_OIDC_CLIENT_SECRET="$RALLLY_OIDC" \
  --from-literal=NEXTCLOUD_SCIM_TOKEN="$NEXTCLOUD_SCIM" \
  --from-literal=XWIKI_SCIM_TOKEN="$XWIKI_SCIM" \
  --from-literal=CLUSTER_ADMIN_PASSWORD="$CLUSTER_ADMIN_PASSWORD" \
  --from-literal=CLUSTER_ADMIN_EMAIL="$CLUSTER_ADMIN_EMAIL" \
  --from-literal=CLUSTER_ADMIN_USERNAME="$CLUSTER_ADMIN_USERNAME" \
  --from-literal=TEST_USER_PASSWORD="$TEST_USER_PASSWORD" \
  --from-literal=TEST_USER_EMAIL="$TEST_USER_EMAIL" \
  --from-literal=TEST_USER_USERNAME="$TEST_USER_USERNAME"

# --- Authentik SMTP config, fully sealed (enrollment email verification + notifications) ---
seal_secret authentik authentik-smtp authentik-smtp-sealed.yaml \
  --from-literal=AUTHENTIK_EMAIL__HOST="$SMTP_HOST" \
  --from-literal=AUTHENTIK_EMAIL__PORT="$SMTP_PORT" \
  --from-literal=AUTHENTIK_EMAIL__USERNAME="$SMTP_USERNAME" \
  --from-literal=AUTHENTIK_EMAIL__PASSWORD="$SMTP_PASSWORD" \
  --from-literal=AUTHENTIK_EMAIL__FROM="$SMTP_FROM" \
  --from-literal=AUTHENTIK_EMAIL__USE_TLS="true" \
  --from-literal=AUTHENTIK_EMAIL__USE_SSL="false" \
  --from-literal=AUTHENTIK_EMAIL__TIMEOUT="30"

# --- Authentik CNPG PostgreSQL user (authentik-pg-user, used by CNPG Cluster bootstrap) ---
# Password must match AUTHENTIK_POSTGRESQL__PASSWORD so the app and CNPG use the same creds.
seal_secret authentik authentik-pg-user authentik-pg-user-sealed.yaml \
  --from-literal=username="authentik" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/authentik-pg-user-sealed.yaml" "-1"

# --- Authentik CNPG S3 credentials (authentik-s3-secret, used by CNPG barman backups) ---
S3_ACCESS_KEY=$(pcfg hetznerS3AccessKey)
S3_SECRET_KEY=$(pcfg hetznerS3SecretKey)
[[ -z "$S3_ACCESS_KEY" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET_KEY" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret authentik authentik-s3-secret authentik-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  --from-literal=SECRET_ACCESS_KEY="$S3_SECRET_KEY"
add_sync_wave "$SCRIPT_DIR/authentik-s3-secret-sealed.yaml" "-1"

# --- Client-side OIDC secrets (must match values above) ---
seal_secret argocd     argocd-oidc-client-secret  ../argocd-infra/argocd-oidc-secret-sealed.yaml             --from-literal=oidc.clientSecret="$ARGOCD_OIDC"
seal_secret headscale  headscale-oidc-client-secret ../headscale/oidc-client-secret-sealed.yaml              --from-literal=client-secret="$HEADSCALE_OIDC"
seal_secret nextcloud  nextcloud-oidc-client-secret ../../apps/nextcloud/oidc-client-secret-sealed.yaml      --from-literal=client-secret="$NEXTCLOUD_OIDC"
seal_secret xwiki      xwiki-oidc-client-secret     ../../apps/xwiki/oidc-client-secret-sealed.yaml          --from-literal=client-secret="$XWIKI_OIDC"
seal_secret prometheus grafana-oidc-secret           ../kube-prometheus-stack/grafana-oidc-secret-sealed.yaml --from-literal=GRAFANA_OIDC_CLIENT_SECRET="$GRAFANA_OIDC"
seal_secret zulip      zulip-oidc-client-secret      ../../apps/zulip/oidc-client-secret-sealed.yaml          --from-literal=SECRET_social_auth_oidc_secret="$ZULIP_OIDC"
seal_secret rallly     rallly-oidc-client-secret     ../../apps/rallly/oidc-client-secret-sealed.yaml         --from-literal=client-secret="$RALLLY_OIDC"
seal_secret nextcloud  nextcloud-scim-token          ../../apps/nextcloud/scim-token-sealed.yaml               --from-literal=scim-token="$NEXTCLOUD_SCIM"
seal_secret xwiki      xwiki-scim-token              ../../apps/xwiki/scim-token-sealed.yaml                   --from-literal=scim-token="$XWIKI_SCIM"

ABS_FILES=(
  "$SCRIPT_DIR/authentik-secrets-sealed.yaml"
  "$SCRIPT_DIR/authentik-smtp-sealed.yaml"
  "$SCRIPT_DIR/authentik-pg-user-sealed.yaml"
  "$SCRIPT_DIR/authentik-s3-secret-sealed.yaml"
  "$REPO_DIR/infra/argocd-infra/argocd-oidc-secret-sealed.yaml"
  "$REPO_DIR/infra/headscale/oidc-client-secret-sealed.yaml"
  "$REPO_DIR/apps/nextcloud/oidc-client-secret-sealed.yaml"
  "$REPO_DIR/apps/nextcloud/scim-token-sealed.yaml"
  "$REPO_DIR/apps/xwiki/oidc-client-secret-sealed.yaml"
  "$REPO_DIR/apps/xwiki/scim-token-sealed.yaml"
  "$REPO_DIR/infra/kube-prometheus-stack/grafana-oidc-secret-sealed.yaml"
  "$REPO_DIR/apps/zulip/oidc-client-secret-sealed.yaml"
  "$REPO_DIR/apps/rallly/oidc-client-secret-sealed.yaml"
)
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal Authentik + OIDC client secrets" "${ABS_FILES[@]}"
