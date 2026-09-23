#!/bin/bash
# Seals Authentik secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed bundle on re-runs.
# Pass --regenerate to rotate all secrets.
#
# The bundle keeps Authentik's OWN secrets + the two ArgoCD-instance OIDC secrets
# (blueprint platform) + grafana OIDC (blueprint) + the shared AUTHENTIK_PROVISIONER_TOKEN.
# Per-app OIDC apps (nextcloud, xwiki, zulip, rallly, headscale, windows, jitsi,
# rocketchat) are self-contained (Part B) — each seals its own OIDC + a copy of the
# provisioner token. Run this script FIRST so those apps can recover the provisioner
# token from the bundle.
#
# Generates:
#   authentik/authentik-secrets-sealed.yaml                  — authentik core + DB + bootstrap + the two ArgoCD-instance OIDC secrets + grafana OIDC + gitlab OIDC + provisioner token
#   argocd-infra-self/argocd-oidc-secret-sealed.yaml               — infra ArgoCD client secret (ns argocd-infra, key oidc.clientSecret)
#   argocd-apps/argocd-oidc-secret-sealed.yaml               — apps  ArgoCD client secret (ns argocd-apps,  key oidc.clientSecret)
#   prometheus/kube-prometheus-stack/grafana-oidc-secret-sealed.yaml    — grafana OIDC client secret (key GRAFANA_OIDC_CLIENT_SECRET)
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
# Idempotent: if a sync-wave annotation already exists anywhere, leave the file
# alone (re-runs must not append a second, mis-indented block).
if 'argocd.argoproj.io/sync-wave' in content:
    sys.exit(0)
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
# Anchor to the TOP-LEVEL metadata.namespace only (exactly 2-space indent at
# line start). Without ^ + MULTILINE this also matches the 6-space
# 'template.metadata.namespace' and inserts a 2-space 'annotations:' under
# spec — structurally invalid, so the SealedSecret never applies.
content = re.sub(
    r'(^  namespace: [^\n]+\n)',
    lambda m: m.group(0) + anno,
    content, count=1, flags=re.MULTILINE
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$file" "$wave"
}

# If a password was auto-generated, offer to print it once (so the user can
# record it — the cleartext only lives in the sealed bundle otherwise).
maybe_print_generated() {
  local label="$1" value="$2"
  read -rp "  ${label} was generated. Print it now? [y/N]: " _show
  [[ "$_show" =~ ^[Yy]$ ]] && echo "  ${label}: ${value}"
}

BUNDLE="$SCRIPT_DIR/authentik-secrets-sealed.yaml"

echo "Configuring Authentik secrets..."
AUTHENTIK_SECRET_KEY=$(recover_or_generate "$BUNDLE" AUTHENTIK_SECRET_KEY         "$REGEN" 50)
# Recover the app-side DB password. authentik needs it as AUTHENTIK_POSTGRESQL__PASSWORD
# (double underscore → postgresql.password; config.py). It MUST match the CNPG
# authentik-pg-user password, so never silently regenerate on migration: try the new
# double-underscore key, then fall back to the legacy single-underscore key from older
# bundles. Only generate (via recover_or_generate) when neither exists or --regenerate.
if [[ "$REGEN" != "--regenerate" ]]; then
  DB_PASSWORD=$(try_recover "$BUNDLE" AUTHENTIK_POSTGRESQL__PASSWORD)
  [[ -z "$DB_PASSWORD" ]] && DB_PASSWORD=$(try_recover "$BUNDLE" AUTHENTIK_POSTGRESQL_PASSWORD)
fi
[[ -z "${DB_PASSWORD:-}" ]] && DB_PASSWORD=$(recover_or_generate "$BUNDLE" AUTHENTIK_POSTGRESQL__PASSWORD "$REGEN")
AUTHENTIK_PG_ADMIN_PASSWORD=$(   recover_or_generate "$BUNDLE" AUTHENTIK_PG_ADMIN_PASSWORD             "$REGEN")
BOOTSTRAP_TOKEN=$(recover_or_generate "$BUNDLE" AUTHENTIK_BOOTSTRAP_TOKEN     "$REGEN" 32)
BOOTSTRAP_PASSWORD=$(  recover_or_generate "$BUNDLE" AUTHENTIK_BOOTSTRAP_PASSWORD  "$REGEN" 16)
# The two ArgoCD-instance OIDC secrets stay bundle-managed (blueprint platform
# components, not per-app). GITLAB_OIDC stays (gitlab uses a dynamic presync flow,
# never the per-app model) and GRAFANA_OIDC stays (grafana is blueprint-managed
# like ArgoCD). All OTHER per-app OIDC/SCIM secrets moved to their own folders
# (Part B/C): nextcloud, xwiki(+SCIM), zulip, rallly, headscale are self-contained.
ARGOCD_INFRA_OIDC=$(   recover_or_generate "$BUNDLE" ARGOCD_INFRA_OIDC_CLIENT_SECRET "$REGEN" 32)
ARGOCD_APPS_OIDC=$(    recover_or_generate "$BUNDLE" ARGOCD_APPS_OIDC_CLIENT_SECRET  "$REGEN" 32)
GITLAB_OIDC=$(         recover_or_generate "$BUNDLE" GITLAB_OIDC_CLIENT_SECRET     "$REGEN" 32)
GRAFANA_OIDC=$(        recover_or_generate "$BUNDLE" GRAFANA_OIDC_CLIENT_SECRET    "$REGEN" 32)
# Part B: the scoped provisioner token — the ONLY shared Authentik secret. Each
# per-app job seals a copy of this plaintext into its own namespace; the
# provisioner blueprint binds it to the service account via !Env.
#
# NAME: AUTHENTIK_PROVISIONER_TOKEN. It is NOT OIDC-specific — the role also grants
# add_group / expressionpolicy / application / policybinding, and ryax uses it with
# no OIDC at all (own username/password auth).
#
# ⚠ Every per-app sealSecrets.sh recovers THIS key by name and seals a copy into its
# own namespace. try_recover returns empty on a name miss rather than failing, so if
# this key is ever renamed again the token is silently regenerated here and all 12
# per-app copies go stale — their provisioning Jobs then 401 against Authentik.
AUTHENTIK_PROVISIONER_TOKEN=$(recover_or_generate "$BUNDLE" AUTHENTIK_PROVISIONER_TOKEN "$REGEN" 60)
# Samba AD (Phase 2). Two SEPARATE secrets, deliberately:
#   AD_PROVISIONER_TOKEN   — API token for the ad-provisioner service account
#     (authentik-blueprint-ad-provisioner.yaml, bound via !Env). NOT the shared
#     AUTHENTIK_PROVISIONER_TOKEN: that one is handed to every per-app job and
#     deliberately excludes the identity surface.
#   SAMBA_AD_BIND_PASSWORD — the password of the AD account the LDAPSource binds
#     as (authentik-blueprint-ad-source.yaml). This is the credential that carries password
#     write-back, so it is an AD-side secret, not an Authentik one.
AD_PROVISIONER_TOKEN=$(  recover_or_generate "$BUNDLE" AD_PROVISIONER_TOKEN       "$REGEN" 60)
# ⚠ SAMBA_AD_BIND_PASSWORD is NOT generated by recover_or_generate: that helper uses
# `openssl rand -hex`, which emits lowercase hex ONLY — no uppercase, no symbols — and AD
# enforces 3-of-4 character classes. Such a value is accepted into the bundle, then rejected
# by samba at account-creation time with
#   0000052D: check_password_restrictions: the password does not meet the complexity criteria
# Recover an existing value if present, otherwise generate one with all four classes.
SAMBA_AD_BIND_PASSWORD=$(try_recover "$BUNDLE" SAMBA_AD_BIND_PASSWORD)
if [[ -z "$SAMBA_AD_BIND_PASSWORD" || "$REGEN" == "--regenerate" ]]; then
  # 32 url-safe base64 chars (mixed case + digits) plus a symbol → all four classes.
  SAMBA_AD_BIND_PASSWORD="$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 32)Aa1!"
  echo "  SAMBA_AD_BIND_PASSWORD — generated (AD-complexity-safe alphabet)." >&2
else
  echo "  SAMBA_AD_BIND_PASSWORD — recovered from sealed file." >&2
fi


# CLUSTER ADMIN credentials: username, password, email
# clusteradmin username 
_existing_admin_user=$(try_recover "$BUNDLE" CLUSTER_ADMIN_USERNAME)
CLUSTER_ADMIN_USERNAME=""
if [[ -n "$_existing_admin_user" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  read -rp "  clusteradmin username '$_existing_admin_user' already exists. Keep [k] or replace [r]? " _kr
  [[ "$_kr" =~ ^[Rr]$ ]] || CLUSTER_ADMIN_USERNAME="$_existing_admin_user"
fi
if [[ -z "$CLUSTER_ADMIN_USERNAME" ]]; then
  while [[ -z "$CLUSTER_ADMIN_USERNAME" ]]; do
    read -rp "  cluster admin username: " CLUSTER_ADMIN_USERNAME
  done
fi

# clusteradmin password
_existing_admin_pass=$(try_recover "$BUNDLE" CLUSTER_ADMIN_PASSWORD)
CLUSTER_ADMIN_PASSWORD=""; _admin_pass_generated=""
if [[ -n "$_existing_admin_pass" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "clusteradmin password" "true" "true"
  case "$KEG_CHOICE" in
    keep)     CLUSTER_ADMIN_PASSWORD="$_existing_admin_pass" ;;
    generate) CLUSTER_ADMIN_PASSWORD=$(openssl rand -base64 16); _admin_pass_generated="y" ;;
  esac
fi
if [[ -z "$CLUSTER_ADMIN_PASSWORD" ]]; then
  if [[ -z "$_existing_admin_pass" ]]; then
    prompt_keg "clusteradmin password" "false" "true"
    [[ "$KEG_CHOICE" == "generate" ]] && { CLUSTER_ADMIN_PASSWORD=$(openssl rand -base64 16); _admin_pass_generated="y"; }
  fi
  if [[ -z "$CLUSTER_ADMIN_PASSWORD" ]]; then
      read -rsp "  clusteradmin password: " CLUSTER_ADMIN_PASSWORD; echo
  fi
fi
[[ -n "$_admin_pass_generated" ]] && maybe_print_generated "clusteradmin password" "$CLUSTER_ADMIN_PASSWORD"

# clusteradmin email
_existing_admin_email=$(try_recover "$BUNDLE" CLUSTER_ADMIN_EMAIL)
CLUSTER_ADMIN_EMAIL=""
if [[ -n "$_existing_admin_email" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "clusteradmin email ($_existing_admin_email)" "true" "false"
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
  read -rp "  testuser username '$_existing_test_user' already exists. Keep [k] or replace [r]? " _kr
  [[ "$_kr" =~ ^[Rr]$ ]] || TEST_USER_USERNAME="$_existing_test_user"
fi
if [[ -z "$TEST_USER_USERNAME" ]]; then
  _default="${_existing_test_user:-testuser}"
  read -rp "  test user username [${_default}]: " TEST_USER_USERNAME
  [[ -z "$TEST_USER_USERNAME" ]] && TEST_USER_USERNAME="$_default"
fi

# testuser password
_existing_user_pass=$(try_recover "$BUNDLE" TEST_USER_PASSWORD)
TEST_USER_PASSWORD=""; _user_pass_generated=""
if [[ -n "$_existing_user_pass" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "testuser password" "true" "true"
  case "$KEG_CHOICE" in
    keep)     TEST_USER_PASSWORD="$_existing_user_pass" ;;
    generate) TEST_USER_PASSWORD=$(openssl rand -base64 16); _user_pass_generated="y" ;;
  esac
fi
if [[ -z "$TEST_USER_PASSWORD" ]]; then
  if [[ -z "$_existing_user_pass" ]]; then
    prompt_keg "testuser password" "false" "true"
    [[ "$KEG_CHOICE" == "generate" ]] && { TEST_USER_PASSWORD=$(openssl rand -base64 16); _user_pass_generated="y"; }
  fi
  if [[ -z "$TEST_USER_PASSWORD" ]]; then
      read -rsp "  testuser password: " TEST_USER_PASSWORD; echo
  fi
fi
[[ -n "$_user_pass_generated" ]] && maybe_print_generated "testuser password" "$TEST_USER_PASSWORD"

# testuser email
_existing_user_email=$(try_recover "$BUNDLE" TEST_USER_EMAIL)
TEST_USER_EMAIL=""
if [[ -n "$_existing_user_email" ]] && [[ "$REGEN" != "--regenerate" ]]; then
  prompt_keg "testuser email ($_existing_user_email)" "true" "false"
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
  --from-literal=AUTHENTIK_PG_ADMIN_PASSWORD="$AUTHENTIK_PG_ADMIN_PASSWORD" \
  --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$BOOTSTRAP_TOKEN" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASSWORD" \
  --from-literal=ARGOCD_INFRA_OIDC_CLIENT_SECRET="$ARGOCD_INFRA_OIDC" \
  --from-literal=ARGOCD_APPS_OIDC_CLIENT_SECRET="$ARGOCD_APPS_OIDC" \
  --from-literal=GITLAB_OIDC_CLIENT_SECRET="$GITLAB_OIDC" \
  --from-literal=GRAFANA_OIDC_CLIENT_SECRET="$GRAFANA_OIDC" \
  --from-literal=AUTHENTIK_PROVISIONER_TOKEN="$AUTHENTIK_PROVISIONER_TOKEN" \
  --from-literal=AD_PROVISIONER_TOKEN="$AD_PROVISIONER_TOKEN" \
  --from-literal=SAMBA_AD_BIND_PASSWORD="$SAMBA_AD_BIND_PASSWORD" \
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
# Password must match AUTHENTIK_POSTGRESQL_PASSWORD so the app and CNPG use the same creds.
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

# --- Client-side OIDC secrets that stay bundle-managed ---
# The two ArgoCD instances (blueprint-managed platform components) + grafana
# (blueprint-managed). nextcloud/xwiki/zulip/rallly/headscale are now self-contained
# (Part B): each app's own sealSecrets.sh seals its OIDC + provisioner token into
# its own namespace. gitlab uses its own dynamic presync-oidc-secrets flow.
# ArgoCD only loads secrets labelled app.kubernetes.io/part-of=argocd into its
# $secret config substitution; without it $argocd-oidc-client-secret:oidc.clientSecret
# resolves to empty → OIDC login fails with "invalid_client".
seal_secret argocd-infra argocd-oidc-client-secret  ../argocd-infra-self/argocd-oidc-secret-sealed.yaml            --template-label=app.kubernetes.io/part-of=argocd --from-literal=oidc.clientSecret="$ARGOCD_INFRA_OIDC"
seal_secret argocd-apps  argocd-oidc-client-secret  ../argocd-apps/argocd-oidc-secret-sealed.yaml            --template-label=app.kubernetes.io/part-of=argocd --from-literal=oidc.clientSecret="$ARGOCD_APPS_OIDC"
seal_secret prometheus grafana-oidc-secret           ../prometheus/kube-prometheus-stack/grafana-oidc-secret-sealed.yaml --from-literal=GRAFANA_OIDC_CLIENT_SECRET="$GRAFANA_OIDC"

ABS_FILES=(
  "$SCRIPT_DIR/authentik-secrets-sealed.yaml"
  "$SCRIPT_DIR/authentik-smtp-sealed.yaml"
  "$SCRIPT_DIR/authentik-pg-user-sealed.yaml"
  "$SCRIPT_DIR/authentik-s3-secret-sealed.yaml"
  "$SCRIPT_DIR/../argocd-infra-self/argocd-oidc-secret-sealed.yaml"
  "$SCRIPT_DIR/../argocd-apps/argocd-oidc-secret-sealed.yaml"
  "$SCRIPT_DIR/../prometheus/kube-prometheus-stack/grafana-oidc-secret-sealed.yaml"
)
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Authentik + OIDC client secrets" "${ABS_FILES[@]}"
fi
