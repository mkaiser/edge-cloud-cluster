#!/usr/bin/env bash
# Super-script: remove ALL committed *-sealed.yaml across both deployment areas
# by delegating to
#   deployment/argocd-infra/removeAllSealedSecrets.sh
#   deployment/argocd-apps/removeAllSealedSecrets.sh
# The mirror of sealAllSecrets.sh (same areas, reverse intent). Part C: for a
# clean / vanilla / public git release (full strip). SealedSecrets ONLY — the
# Pulumi-config scripts/secrets/set*.sh family is NOT in scope.
#
# Each area script is self-contained and can also be run on its own. This area is
# being prepared to split argocd-apps into a separate repository.
#
# This is distinct from disabling ONE app: to disable a single app temporarily use
# its app-of-apps/<app>.yaml.disable; to remove one app for good use that app's own
# removeSealedSecret.sh. This driver strips EVERYTHING for a release.
#
# Flags:
#   --force              non-interactive (skip confirmation, passed to each remover)
#   --skip-git-commit  remove files but do not git-commit the removals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YES=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --force)             YES="--force" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

echo "=== Removing ALL sealed secrets (full strip for a vanilla release) ==="
echo "The following sealed files will be removed:"
find "$SCRIPT_DIR" -name '*-sealed.yaml' | sort | sed 's/^/  - /'
echo ""

if [[ -z "$YES" ]]; then
  read -rp "Permanently remove ALL sealed secrets listed above? [y/N]: " choice
  [[ "$choice" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

# Defer each area's commit so we commit both areas' removals once at the end.
[[ -z "$SKIP_GIT_COMMIT" ]] && export REMOVE_DEFER_COMMIT=1

run_area() {
  local area="$1"
  echo ""
  echo "════ $area/removeAllSealedSecrets.sh"
  # --force: areas saw the global confirmation above. Propagate --skip-git-commit;
  # otherwise REMOVE_DEFER_COMMIT keeps the area from committing (super commits).
  bash "$SCRIPT_DIR/$area/removeAllSealedSecrets.sh" --force $SKIP_GIT_COMMIT
}

run_area argocd-infra
run_area argocd-apps

echo ""
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "Remove all sealed secrets (vanilla-git release / full strip)"
    echo "All sealed-secret removals committed."
  else
    echo "No staged removals to commit."
  fi
fi

echo ""
# ⚠ VERIFY, do not claim. This driver delegates to each app's removeSealedSecret.sh, so it
# only ever removes files belonging to an app that HAS one — and an app whose sealed files
# exist but whose remover does not is skipped in silence, each per-app run cheerfully
# reporting "No sealed files to remove". Measured 2026-09-14: all 14 directories holding
# sealed files lacked a remover, so a full strip left every one of them in place and still
# printed "All sealed secrets removed." That message is what a release is trusted on, so it
# must be a result, not an assertion.
remaining=$(find "$SCRIPT_DIR" -name '*-sealed.yaml' | sort)
if [[ -n "$remaining" ]]; then
  echo "ERROR: sealed secrets REMAIN after the strip — no remover ran for these:" >&2
  printf '  %s\n' $remaining >&2
  echo "" >&2
  echo "Each belongs to an app with no removeSealedSecret.sh, so nothing removed them." >&2
  echo "Add one for that app, or delete the files directly if this is a release strip." >&2
  exit 1
fi

echo "All sealed secrets removed (verified: no *-sealed.yaml remains under deployment/)."
