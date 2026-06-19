#!/bin/bash
# Seals Rocket.Chat secrets for ArgoCD deployment. Self-contained — all auth
# material lives in this folder. Idempotent: recovers existing values from the
# sealed files on re-runs. Pass --regenerate to rotate secrets.
#
# Generates:
#   admin-sealed.yaml          — rocketchat-admin (ADMIN_USERNAME/PASS/EMAIL, seeds admin)
#   mongodb-sealed.yaml        — rocketchat-mongodb (root pw, app-user pw, replica-set keyfile)
#   mongodb-uri-sealed.yaml    — rocketchat-mongodb-uri (mongo-uri consumed by Rocket.Chat)
#   oidc-client-secret-sealed.yaml — rocketchat-oidc-client-secret (Authentik OIDC client)
set -euo pipefail

NAMESPACE="rocketchat"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

ADMIN_FILE="$SCRIPT_DIR/admin-sealed.yaml"
MONGO_FILE="$SCRIPT_DIR/mongodb-sealed.yaml"
URI_FILE="$SCRIPT_DIR/mongodb-uri-sealed.yaml"
OIDC_FILE="$SCRIPT_DIR/oidc-client-secret-sealed.yaml"

ADMIN_USERNAME="rcadmin"
ADMIN_EMAIL="admin@cape-project.eu"
ADMIN_PASS=$(  recover_or_generate "$ADMIN_FILE" ADMIN_PASS            "$REGEN" 24)
MONGO_ROOT_PW=$(recover_or_generate "$MONGO_FILE" mongodb-root-password "$REGEN" 24)
MONGO_USER_PW=$(recover_or_generate "$MONGO_FILE" mongodb-password      "$REGEN" 24)
MONGO_KEYFILE=$(recover_or_generate "$MONGO_FILE" mongodb-keyfile       "$REGEN" 200)
OIDC_SECRET=$(  recover_or_generate "$OIDC_FILE"  OIDC_CLIENT_SECRET    "$REGEN" 32)

# Connection string Rocket.Chat uses (single-node replica set "rs0" on the
# self-managed mongodb StatefulSet, member-0 FQDN).
MONGO_URI="mongodb://rocketchat:${MONGO_USER_PW}@rocketchat-mongodb-0.rocketchat-mongodb.rocketchat.svc.cluster.local:27017/rocketchat?replicaSet=rs0&authSource=rocketchat"

seal_secret "$NAMESPACE" rocketchat-admin admin-sealed.yaml \
  --from-literal=ADMIN_USERNAME="$ADMIN_USERNAME" \
  --from-literal=ADMIN_PASS="$ADMIN_PASS" \
  --from-literal=ADMIN_EMAIL="$ADMIN_EMAIL"
SEALED_FILES+=("admin-sealed.yaml")

seal_secret "$NAMESPACE" rocketchat-mongodb mongodb-sealed.yaml \
  --from-literal=mongodb-root-password="$MONGO_ROOT_PW" \
  --from-literal=mongodb-password="$MONGO_USER_PW" \
  --from-literal=mongodb-keyfile="$MONGO_KEYFILE"
SEALED_FILES+=("mongodb-sealed.yaml")

seal_secret "$NAMESPACE" rocketchat-mongodb-uri mongodb-uri-sealed.yaml \
  --from-literal=mongo-uri="$MONGO_URI"
SEALED_FILES+=("mongodb-uri-sealed.yaml")

seal_secret "$NAMESPACE" rocketchat-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=OIDC_CLIENT_SECRET="$OIDC_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
