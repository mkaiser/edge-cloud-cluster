#!/bin/bash
# Seals Zulip-specific secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
# OIDC client secret is sealed separately by deployment/authentik/sealSecrets.sh
# (produces zulip/oidc-client-secret-sealed.yaml with key SECRET_social_auth_oidc_secret).
#
# NOTE: zulipSecretKey must be stable — rotating it invalidates all active sessions.
#
# Generates:
#   zulip-postgresql-sealed.yaml   — PostgreSQL password (pre-created; chart uses existingSecret)
#   zulip-rabbitmq-auth-sealed.yaml — RabbitMQ password (pre-created; chart uses existingPasswordSecret)
#   zulip-redis-auth-sealed.yaml   — Redis password (pre-created; chart uses existingSecret)
#   zulip-s3-sealed.yaml           — Hetzner S3 access key + secret key
#   zulip-secret-key-sealed.yaml   — Django SECRET_KEY + SMTP password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  --from-literal=access-key="$S3_ACCESS" \
  --from-literal=secret-key="$S3_SECRET"

seal_secret zulip zulip-secret-key zulip-secret-key-sealed.yaml \
  --from-literal=secret-key="$ZULIP_SECRET_KEY" \
  --from-literal=email-password="${SMTP_PASSWORD:-}"

# NOTE: zulip-sync-bot secret is created automatically by postsync-create-sync-bot.yaml.
# No manual sealing required.

[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal Zulip secrets" \
  "$SCRIPT_DIR/zulip-postgresql-sealed.yaml" \
  "$SCRIPT_DIR/zulip-rabbitmq-auth-sealed.yaml" \
  "$SCRIPT_DIR/zulip-redis-auth-sealed.yaml" \
  "$SCRIPT_DIR/zulip-s3-sealed.yaml" \
  "$SCRIPT_DIR/zulip-secret-key-sealed.yaml"
