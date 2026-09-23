#!/bin/bash
# Seals Zulip-specific secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Part B (self-contained OIDC): the OIDC client secret + scoped provisioner token
# are sealed HERE; zulip/authentik-provider.yaml registers the provider live.
#
# NOTE: zulipSecretKey must be stable — rotating it invalidates all active sessions.
#
# Generates:
#   zulip-postgresql-sealed.yaml              — PostgreSQL password (pre-created; chart uses existingSecret)
#   zulip-rabbitmq-auth-sealed.yaml           — RabbitMQ password (pre-created; chart uses existingPasswordSecret)
#   zulip-redis-auth-sealed.yaml              — Redis password (pre-created; chart uses existingSecret)
#   zulip-s3-sealed.yaml                      — Hetzner S3 access key + secret key
#   zulip-secret-key-sealed.yaml              — Django SECRET_KEY + SMTP password
#   oidc-client-secret-sealed.yaml            — Authentik OIDC client secret (key SECRET_social_auth_oidc_secret)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

pc() { (cd "$SCRIPT_DIR/../../.." && pulumi config get "$1" 2>/dev/null); }

S3_ACCESS="$(pc hetznerS3AccessKey)"
S3_SECRET="$(pc hetznerS3SecretKey)"
SMTP_PASSWORD="$(pc smtpPassword)"
: "${S3_ACCESS:?hetznerS3AccessKey not set in Pulumi stack}"
: "${S3_SECRET:?hetznerS3SecretKey not set in Pulumi stack}"

PG_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zulip-postgresql-sealed.yaml" password "$REGEN" 24)
seal_secret zulip zulip-postgresql zulip-postgresql-sealed.yaml \
  --from-literal=password="$PG_PASSWORD"

RABBITMQ_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zulip-rabbitmq-auth-sealed.yaml" rabbitmq-password "$REGEN" 24)
seal_secret zulip zulip-rabbitmq-auth zulip-rabbitmq-auth-sealed.yaml \
  --from-literal=rabbitmq-password="$RABBITMQ_PASSWORD"

REDIS_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/zulip-redis-auth-sealed.yaml" redis-password "$REGEN" 24)
seal_secret zulip zulip-redis-auth zulip-redis-auth-sealed.yaml \
  --from-literal=redis-password="$REDIS_PASSWORD"

ZULIP_SECRET_KEY=$(recover_or_generate "$SCRIPT_DIR/zulip-secret-key-sealed.yaml" secret-key "$REGEN" 64)

seal_secret zulip zulip-s3 zulip-s3-sealed.yaml \
  --sealed-annotation=argocd.argoproj.io/sync-wave="-2" \
  --from-literal=access-key="$S3_ACCESS" \
  --from-literal=secret-key="$S3_SECRET"

seal_secret zulip zulip-secret-key zulip-secret-key-sealed.yaml \
  --from-literal=secret-key="$ZULIP_SECRET_KEY" \
  --from-literal=email-password="${SMTP_PASSWORD:-}"

# NOTE: zulip-sync-bot secret is created automatically by postsync-create-sync-bot.yaml.
# No manual sealing required.

# OIDC client secret (key matches values.yaml secretKeyRef + the provider job).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" SECRET_social_auth_oidc_secret "$REGEN" 32)
seal_secret zulip zulip-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=SECRET_social_auth_oidc_secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret zulip authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Zulip secrets" \
    "$SCRIPT_DIR/zulip-postgresql-sealed.yaml" \
    "$SCRIPT_DIR/zulip-rabbitmq-auth-sealed.yaml" \
    "$SCRIPT_DIR/zulip-redis-auth-sealed.yaml" \
    "$SCRIPT_DIR/zulip-s3-sealed.yaml" \
    "$SCRIPT_DIR/zulip-secret-key-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
