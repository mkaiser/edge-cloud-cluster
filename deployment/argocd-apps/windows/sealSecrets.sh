#!/bin/bash
# Seals Windows VM secrets for ArgoCD deployment.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate secrets.
#
# ⚠ NO Guacamole secrets here. This app no longer runs its own Guacamole: the VM's
# tile is seeded into remote-desktop's, and that database's password is read LIVE by
# connection-seed.yaml rather than sealed a second time (a sealed copy would diverge
# silently on rotation). So there is no DB password, no CNPG bootstrap user and no
# barman S3 key in this app any more.
#
# The scoped provisioner token stays: windows/authentik-provider.yaml still creates
# the windows-users group and the access-windows policy via the Authentik API.
#
# Generates:
#   windows-secrets-sealed.yaml               — Windows VM credentials (RDP account)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token
set -euo pipefail

NAMESPACE="windows"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

echo "Windows admin credentials (set WINDOWS_USERNAME / WINDOWS_PASSWORD env vars to override):"
WIN_USER="${WINDOWS_USERNAME:-WinAdmin}"
WIN_PASS="${WINDOWS_PASSWORD:-$(recover_or_generate "$SCRIPT_DIR/windows-secrets-sealed.yaml" WINDOWS_PASSWORD "$REGEN")}"

# ⚠ WINDOWS_USERNAME / WINDOWS_PASSWORD are the VM's local account, and
# connection-seed.yaml binds them into the Guacamole tile so a click lands straight in
# the session. Rotating them here therefore also changes what the tile logs in with.
seal_secret "$NAMESPACE" windows-secrets windows-secrets-sealed.yaml \
  --from-literal=WINDOWS_USERNAME="$WIN_USER" \
  --from-literal=WINDOWS_PASSWORD="$WIN_PASS"
SEALED_FILES+=("windows-secrets-sealed.yaml")

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
# Guacamole is a public client, so there is no OIDC client secret to seal.
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
  ask_and_commit_sealed_files "Seal windows secrets" "${ABS_FILES[@]}"
fi
