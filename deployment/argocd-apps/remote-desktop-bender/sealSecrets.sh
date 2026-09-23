#!/bin/bash
# Seals the remote-desktop-bender secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed files on re-runs.
# Pass --regenerate to rotate generated passwords.
#
# ONE secret only:
#   remote-desktop-bender-secrets-sealed.yaml — rdp-password (break-glass local account)
#
# ⚠ NO db-password HERE, and that is the point. This app has no database: its Guacamole
# tile lives in remote-desktop's Guacamole, and connection-seed.yaml reads THAT namespace's
# `remote-desktop-secrets` LIVE through a narrow ClusterRole. Sealing a second copy would
# diverge the moment remote-desktop's password is rotated, and the seed would then fail with
# an auth error that reads like a database outage.
#
# ⚠ NO LICENCE KEYS HERE EITHER. `eda-secrets` is sealed into this namespace by
# eda/secrets/sealSecrets.sh from one value shared with the other module runtimes — two
# copies would drift, and the FlexNet/SALT split is easy to get wrong.
#
# ⚠ NO authentik-provisioner-token. This app creates no Authentik objects: its audience is
# the central `employees` group, and the OIDC provider is remote-desktop's.
set -euo pipefail

NAMESPACE="remote-desktop-bender"
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

SEALED="$SCRIPT_DIR/remote-desktop-bender-secrets-sealed.yaml"

# The break-glass local `desktop` account (uid 2001) for when Authentik or the mesh is down.
# Every normal login is an AD identity through xrdp/SSSD and has no password here.
RDP_PASSWORD=$(recover_or_generate "$SEALED" rdp-password "$REGEN")

seal_secret "$NAMESPACE" remote-desktop-bender-secrets remote-desktop-bender-secrets-sealed.yaml \
  --from-literal=rdp-password="$RDP_PASSWORD"
SEALED_FILES+=("remote-desktop-bender-secrets-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal remote-desktop-bender secrets" "${ABS_FILES[@]}"
fi
echo "remote-desktop-bender secrets sealed."
