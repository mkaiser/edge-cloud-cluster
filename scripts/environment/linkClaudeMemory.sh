#!/usr/bin/env bash
# Link Claude's per-machine auto-memory dir to the repo-tracked .claude/memory/.
#
# Claude's auto-memory only reads/writes one hardcoded path:
#   ~/.claude/projects/<workspace-slug>/memory/
# where <workspace-slug> is the repo checkout path with / -> - .
# This script points that path at .claude/memory/ in the repo, so memories are
# committed & shared while auto-memory keeps working. Run once per machine.
# Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_MEM="$REPO/.claude/memory"
SLUG="$(printf '%s' "$REPO" | sed 's#[/_]#-#g')" # /workspaces/git_infra -> -workspaces-git-infra
HOME_MEM="$HOME/.claude/projects/$SLUG/memory"

mkdir -p "$REPO_MEM" "$(dirname "$HOME_MEM")"

# If a real (non-symlink) memory dir already exists, migrate its files in first.
if [ -d "$HOME_MEM" ] && [ ! -L "$HOME_MEM" ]; then
  cp -an "$HOME_MEM/." "$REPO_MEM/" 2>/dev/null || true
  rm -rf "$HOME_MEM"
fi

ln -sfn "$REPO_MEM" "$HOME_MEM"
echo "linked $HOME_MEM -> $REPO_MEM"
