#!/usr/bin/env bash
# Remove ALL committed *-sealed.yaml under argocd-apps/ — the mirror of
# argocd-apps/sealAllSecrets.sh. Part C: for a clean / vanilla / public git
# release (full strip). SealedSecrets ONLY.
#
# This script is self-contained and can be run on its own. It is also invoked by
# the super-script deployment/removeAllSealedSecrets.sh, which strips BOTH areas
# and commits the removals once. When the super sets REMOVE_DEFER_COMMIT=1 this
# script stages the removals (git rm) but does NOT commit — the super commits.
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

# Discover every removeSealedSecret.sh under this area (mirrors the per-folder
# sealSecrets.sh set).
mapfile -t REMOVERS < <(find "$SCRIPT_DIR" -name 'removeSealedSecret.sh' | sort)

echo "=== Removing argocd-apps sealed secrets (full strip) ==="
find "$SCRIPT_DIR" -name '*-sealed.yaml' | sort | sed 's/^/  - /'
echo ""

if [[ -z "$YES" ]]; then
  read -rp "Permanently remove ALL argocd-apps sealed secrets listed above? [y/N]: " choice
  [[ "$choice" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

run() {
  local script="$1"
  echo ""
  echo "━━━ $script"
  # Each remover saw the global confirmation; --force skips its own prompt.
  # --skip-git-commit defers the commit (git rm still stages the deletion).
  bash "$script" --force --skip-git-commit
}

for r in "${REMOVERS[@]}"; do run "$r"; done

echo ""
# When invoked by the super-script, leave the staged removals for it to commit.
if [[ -z "${REMOVE_DEFER_COMMIT:-}" && -z "$SKIP_GIT_COMMIT" ]]; then
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "Remove argocd-apps sealed secrets (full strip)"
    echo "argocd-apps sealed-secret removals committed."
  else
    echo "No staged removals to commit."
  fi
fi

echo ""
echo "All argocd-apps sealed secrets removed."
