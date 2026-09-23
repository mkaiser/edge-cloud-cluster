#!/usr/bin/env bash
# Verify ~/.claude is the persistent named volume (devcontainer.json "mounts"),
# and one-time-migrate session transcripts out of secret/claude-session-backup/
# if the volume came up empty (i.e. this is the first rebuild since the mount
# was added, or the volume was recreated).
#
# Idempotent: once the volume holds sessions, this is a no-op every time.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SLUG="$(printf '%s' "$REPO" | sed 's#[/_]#-#g')" # /workspaces/git_infra -> -workspaces-git-infra
PROJECT_DIR="$HOME/.claude/projects/$SLUG"
BACKUP_DIR="$REPO/secret/claude-session-backup"

# ── Sanity check: is ~/.claude actually the named volume? ───────────────────
# A bind/volume mount target always shows up as its own line in /proc/mounts;
# if it's missing, ~/.claude is just the container's overlay fs again and
# every session written this run will vanish on the next rebuild.
if ! mountpoint -q "$HOME/.claude" 2>/dev/null; then
  echo "WARNING: $HOME/.claude is NOT a mounted volume — check devcontainer.json" \
       "\"mounts\" and rebuild. Sessions will NOT survive this container." >&2
fi

# ── One-time migration from the pre-volume manual backup ────────────────────
if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.jsonl >/dev/null 2>&1; then
  mkdir -p "$PROJECT_DIR"
  restored_ids=()
  for f in "$BACKUP_DIR"/*.jsonl; do
    dest="$PROJECT_DIR/$(basename "$f")"
    if [ ! -e "$dest" ]; then
      cp "$f" "$dest"
      restored_ids+=("$(basename "$f" .jsonl)")
    fi
  done
  if [ "${#restored_ids[@]}" -gt 0 ]; then
    echo "restored ${#restored_ids[@]} session transcript(s) into $PROJECT_DIR:"
    for id in "${restored_ids[@]}"; do
      echo "  claude --resume $id"
    done
  fi
fi

# claude --resume with no ID opens an interactive picker over all sessions in
# $PROJECT_DIR — the reliable fallback when you don't have an ID memorized.
echo "no ID handy? run: claude --resume  (interactive picker, no argument)"
