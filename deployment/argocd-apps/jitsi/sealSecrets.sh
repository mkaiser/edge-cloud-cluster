#!/bin/bash
# Seals Jitsi secrets for ArgoCD deployment. Self-contained — all Jitsi auth
# material lives in this folder (not in the central authentik-secrets bundle).
# Idempotent: recovers existing values from the sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# Generates:
#   jwt-secret-sealed.yaml                    — JWT_APP_SECRET (shared prosody <-> oidc-adapter)
#   oidc-client-secret-sealed.yaml            — OIDC_CLIENT_SECRET (Authentik OIDC client)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
#
# Part B (self-contained OIDC): the provisioner token must equal the central
# AUTHENTIK_PROVISIONER_TOKEN (authentik-secrets bundle). It is recovered from that
# bundle (preferred) or this folder's own sealed file, never freshly generated —
# a fresh value would not authenticate. The authentik-provider.yaml jobs use it
# (scoped, non-superuser) to register the jitsi provider + tile via the API.
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
PROV_FILE="$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"

JWT_APP_SECRET=$(recover_or_generate "$JWT_FILE"  JWT_APP_SECRET     "$REGEN" 32)
OIDC_SECRET=$(   recover_or_generate "$OIDC_FILE" OIDC_CLIENT_SECRET "$REGEN" 32)

# Provisioner token: central bundle is the source of truth; fall back to this
# folder's sealed file; last resort prompt to paste.
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$PROV_FILE" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }

seal_secret "$NAMESPACE" jitsi-jwt jwt-secret-sealed.yaml \
  --from-literal=JWT_APP_SECRET="$JWT_APP_SECRET"
SEALED_FILES+=("jwt-secret-sealed.yaml")

seal_secret "$NAMESPACE" jitsi-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=OIDC_CLIENT_SECRET="$OIDC_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

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
