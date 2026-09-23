#!/usr/bin/env bash
# Super-script: seals ALL secrets across both deployment areas by delegating to
#   deployment/argocd-infra/sealAllSecrets.sh
#   deployment/argocd-apps/sealAllSecrets.sh
#
# Each sub-script is self-contained and can also be run on its own. This area is
# being prepared to split argocd-apps into a separate repository; the per-area
# sealAllSecrets.sh scripts make each area stand alone. manageSealedSecrets.sh
# stays in deployment/ (shared) for now.
#
# Commit behaviour: by DEFAULT both areas are sealed first with no per-app prompt,
# then a SINGLE combined prompt at the end lists every changed sealed file across
# both areas. Use --commit-per-app for the old per-app prompt, or --skip-git-commit
# to seal without committing at all. (DEFER_COMMIT=1 is the default and is passed
# down to the sub-scripts; COMMIT_PER_APP=1 / --commit-per-app opts out.)
#
# Requires the Pulumi stack to be loaded:
#   source ./scripts/pulumi/initPulumiStack.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN=""; SKIP_GIT_COMMIT=""; PER_APP="${COMMIT_PER_APP:+1}"
# DEFER_COMMIT defaults on; --commit-per-app / --skip-git-commit turn it off.
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
  --commit-per-app)  PER_APP="1" ;;
esac; done

# Default = defer: export a shared emit temp file that every app under both areas
# appends its changed files to (markers go to the file, never stdout, so apps'
# interactive prompts work). The sub-scripts inherit SEAL_EMIT_FILE and leave the
# commit to us. --commit-per-app / --skip-git-commit propagate the corresponding
# non-defer flag to the sub-scripts and skip the final commit here.
CHILD_FLAGS="$REGEN"
DEFER=""
if [[ -z "$SKIP_GIT_COMMIT" && -z "$PER_APP" ]]; then
  DEFER="1"
  SEAL_EMIT_FILE="$(mktemp)"
  export SEAL_DEFER_COMMIT=1 SEAL_EMIT_FILE
else
  [[ -n "$PER_APP" ]]         && CHILD_FLAGS="$CHILD_FLAGS --commit-per-app"
  [[ -n "$SKIP_GIT_COMMIT" ]] && CHILD_FLAGS="$CHILD_FLAGS --skip-git-commit"
fi

if ! (cd "$SCRIPT_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded or sealedSecretsTlsKey missing." >&2
  echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
  exit 1
fi

# Run a sub-script with stdout/stderr passed straight through so interactive
# prompts work; changed files arrive via the shared $SEAL_EMIT_FILE.
run_area() {
  local area="$1"
  echo ""
  echo "════ $area/sealAllSecrets.sh"
  bash "$SCRIPT_DIR/$area/sealAllSecrets.sh" $CHILD_FLAGS
}

echo "=== Sealing all Kubernetes secrets (argocd-infra + argocd-apps) ==="

run_area argocd-infra
run_area argocd-apps

echo ""
echo "All secrets sealed."

# Deferred commit: aggregate the files both areas emitted and prompt ONCE.
if [[ -n "$DEFER" ]]; then
  mapfile -t DEFERRED_FILES < <(sort -u "$SEAL_EMIT_FILE")
  rm -f "$SEAL_EMIT_FILE"; unset SEAL_DEFER_COMMIT SEAL_EMIT_FILE
  # shellcheck source=manageSealedSecrets.sh
  source "$SCRIPT_DIR/manageSealedSecrets.sh"  # provides ask_and_commit_sealed_files
  echo ""
  if [[ ${#DEFERRED_FILES[@]} -eq 0 ]]; then
    echo "No sealed files changed — nothing to commit."
  else
    ask_and_commit_sealed_files "Seal all secrets" "${DEFERRED_FILES[@]}"
  fi
fi
