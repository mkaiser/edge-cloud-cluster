#!/bin/bash
# Permanently remove Jitsi's sealed secrets + de-provision its Authentik OIDC.
#
# This is the "remove for good" counterpart to renaming the app-of-apps manifest to
# *.yaml.disable (which only handles RUNTIME teardown via prune + PreDelete). It
# clears the two orphan classes .disable leaves behind:
#   1. the git-tracked *-sealed.yaml files in this folder, and
#   2. Authentik provider/application DB leftovers (runs even if the PreDelete
#      hook never fired) — via an idempotent API DELETE with the scoped token.
#
# Flags (mirror the sealers):
#   --force              non-interactive (skip the destructive confirmation)
#   --skip-git-commit  remove files but do not git-commit the removal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

export REMOVE_YES=0 REMOVE_SKIP_GIT_COMMIT=0
for arg in "$@"; do case "$arg" in
  --force)             REMOVE_YES=1 ;;
  --skip-git-commit) REMOVE_SKIP_GIT_COMMIT=1 ;;
esac; done

# 1. Idempotent Authentik cleanup (covers the case PreDelete never ran).
authentik_deprovision jitsi

# 2. git rm / rm this folder's sealed files (clears orphan class 1).
mapfile -t SEALED_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*-sealed.yaml' | sort)
remove_sealed "Remove jitsi sealed secrets + de-provision OIDC" "${SEALED_FILES[@]}"

echo ""
echo "Done. To also disable the app, remove deployment/argocd-apps/app-of-apps/jitsi.yaml"
echo "(or rename it to .yaml.disable for a temporary disable)."
