#!/bin/bash
# Seals Jitsi secrets for ArgoCD deployment. Self-contained — all Jitsi auth
# material lives in this folder (not in the central authentik-secrets bundle).
# Idempotent: recovers existing values from the sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Generates:
#   jwt-secret-sealed.yaml          — JWT_APP_SECRET (shared prosody <-> oidc-adapter)
#   oidc-client-secret-sealed.yaml  — OIDC_CLIENT_SECRET (Authentik OIDC client)
set -euo pipefail

NAMESPACE="jitsi"
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

JWT_FILE="$SCRIPT_DIR/jwt-secret-sealed.yaml"
OIDC_FILE="$SCRIPT_DIR/oidc-client-secret-sealed.yaml"

JWT_APP_SECRET=$(recover_or_generate "$JWT_FILE"  JWT_APP_SECRET     "$REGEN" 32)
OIDC_SECRET=$(   recover_or_generate "$OIDC_FILE" OIDC_CLIENT_SECRET "$REGEN" 32)

seal_secret "$NAMESPACE" jitsi-jwt jwt-secret-sealed.yaml \
  --from-literal=JWT_APP_SECRET="$JWT_APP_SECRET"
SEALED_FILES+=("jwt-secret-sealed.yaml")

seal_secret "$NAMESPACE" jitsi-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=OIDC_CLIENT_SECRET="$OIDC_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
