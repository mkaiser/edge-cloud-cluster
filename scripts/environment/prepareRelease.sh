#!/usr/bin/env bash
# Project: edgecloudinfra
# File: scripts/environment/prepareRelease.sh
# Purpose: Build an anonymized, secret-free copy of this repo for a PUBLIC repository.
#
# Author: Martin Kaiser
# Copyright (c) 2026 Martin Kaiser
# License: MIT
# SPDX-License-Identifier: MIT
#
# This repo is PRIVATE and keeping secrets in it is fine. The public copy is a separate
# repository, and this builds it as a SHADOW TREE under release/ — the source repo is never
# modified and never committed to.
#
# ⚠ WHY A SHADOW TREE AND NOT AN IN-PLACE ANONYMIZE. The previous version rewrote this repo,
# then offered to undo it, so every failure mode was an incomplete undo. Three problems make
# that unfixable in place:
#   * GIT HISTORY. 4115 commits, 440 of which contain the real domain and 155 of which touch
#     Pulumi.mystack.yaml. Anonymizing the working tree is cosmetic while history keeps
#     everything. A shadow tree gets fresh history for free.
#   * TRACKED SECRET FILES. Pulumi.mystack.yaml (which holds sealedSecretsTlsKey — the key
#     that decrypts every SealedSecret) and .pulumi-state/ are tracked. Excluding them
#     in place would mean `git rm`ing them from the real repo.
#   * A SILENT STRIP. The old flow called removeAllSealedSecrets.sh, which reported success
#     having removed nothing for 14 apps (fixed separately). In a throwaway tree the scrub is
#     direct and the gate below proves it.
#
# Usage:
#   make prepare-release                  build, with prompts
#   make prepare-release ARGS="--force"   no prompts
#   ARGS="--keep-plans"                   also ship plans/ (internal engineering log)
#   ARGS="--out <dir>"                    build somewhere other than release/build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The published placeholders. Both the settings rewrite and the reader's expectations name
# them, so they live here once.
ANON_DOMAIN="your-domain.tld"
ANON_SUB="subdomain1"
ANON_REPO_URL="git@github.com:YourProject/yourGit.git"
# RFC 5737 TEST-NET-3: reserved for documentation, so it reads as an obvious placeholder and
# can never route anywhere real.
ANON_ROBOT_IP="203.0.113.10"

YES=""; KEEP_PLANS=""; BUILD_DIR="$REPO_ROOT/release/build"
while [ "$#" -gt 0 ]; do case "$1" in
  --force)      YES="1"; shift ;;
  --keep-plans) KEEP_PLANS="1"; shift ;;
  --out)        BUILD_DIR="${2:?--out needs a directory}"; shift 2 ;;
  --out=*)      BUILD_DIR="${1#*=}"; shift ;;
  *) echo "Usage: $0 [--force] [--keep-plans] [--out <dir>]" >&2; exit 2 ;;
esac; done

cd "$REPO_ROOT"

# ── 1. Source state ──────────────────────────────────────────────────────────────────────
# The build is `git archive HEAD`, so uncommitted work is NOT in it. That is not a failure
# (the source repo is untouched either way), but shipping something other than what the user
# sees in their editor deserves one prompt.
SOURCE_REF="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "NOTE: the working tree has uncommitted changes; the release is built from HEAD" >&2
  echo "      (${SOURCE_REF:0:12}), so those changes will NOT be in it." >&2
  if [[ -z "$YES" ]]; then
    read -rp "Continue building from HEAD? [y/N] " r
    [[ "${r,,}" == "y" ]] || { echo "Aborted."; exit 1; }
  fi
fi

# ── 2. Stage the tree ────────────────────────────────────────────────────────────────────
# ⚠ `git archive`, deliberately NOT `cp -a`:
#   * it honours .gitignore by construction — the working directory carries install/ and
#     external/ (tens of GB of vendor media and upstream clones) that a copy would duplicate,
#     and excluding them by hand would be a second list to keep in sync;
#   * it emits NO history, so there is no .git to remember to delete. Forgetting that with a
#     copy publishes all 4115 commits with no visible symptom;
#   * it is exactly HEAD, never a half-saved editor buffer.
echo "Building release from ${SOURCE_REF:0:12} into ${BUILD_DIR#"$REPO_ROOT/"}/ ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
git archive "$SOURCE_REF" | tar -x -C "$BUILD_DIR"

# ⚠ Initialise git BEFORE the anchor engine runs (step 5). The engine reads the current branch
# to rewrite every ArgoCD `targetRevision:`; in an un-initialised tree that lookup returns
# empty and it prints "Could not determine current branch; skipping targetRevision update" —
# a warning that scrolls past, leaving the release pointing at whatever branch happened to be
# committed. Pinning `main` here makes it deterministic regardless of the source branch.
git -C "$BUILD_DIR" init -q -b main

# ── 3. Scrub secret material ─────────────────────────────────────────────────────────────
# Values are EMPTIED, files kept: a SealedSecret and a Pulumi stack are both instructive as
# shapes, and a reader of a public infra repo needs to see what they look like. What must not
# survive is the material itself.
#
# ⚠ Deliberately NOT via removeAllSealedSecrets.sh. That driver delegates to per-app remover
# scripts and skips any app lacking one — silently, and it is the whole reason this gate
# exists. Here the scrub is direct and the gate in step 7 proves it.
python3 "$SCRIPT_DIR/scrubReleaseSecrets.py" --root "$BUILD_DIR"

# Bulk machine state: live hostnames, the robot public IP, Hetzner network IDs, encrypted
# secrets. No instructional value, so it goes entirely rather than being emptied.
rm -rf "$BUILD_DIR/.pulumi-state"
# Per-developer tool state, tracked before the .gitignore rule existed.
rm -f "$BUILD_DIR/.claude/settings.local.json"
# The denylist is the inventory of what must not be published, so it must not be published
# itself. checkReleaseClean.py STAYS — the mechanism is worth publishing, and it refuses to
# run without a denylist rather than passing vacuously. The matching [path] rule in the
# denylist is what turns a forgotten deletion here into an aborted release instead of a leak.
rm -f "$BUILD_DIR/scripts/environment/release-denylist.txt"

# ── 4. Anonymize project_settings.ts ─────────────────────────────────────────────────────
SETTINGS="$BUILD_DIR/project_settings.ts"

# Rewrite a key's string value, but ONLY inside the named settings block, so identically
# named keys elsewhere in the file are left untouched.
rewrite_key() {
  local blk="$1" key="$2" val="$3"
  awk -v blk="$blk" -v key="$key" -v val="$val" '
    $0 ~ "^[[:space:]]*" blk ":[[:space:]]*\{" { ing=1 }
    ing && $0 ~ "^[[:space:]]*" key ":[[:space:]]*\"" {
      sub("\"[^\"]*\"", "\"" val "\"")
    }
    ing && /^[[:space:]]*\},[[:space:]]*$/ { ing=0 }
    { print }
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
}

read_key() {
  local blk="$1" key="$2"
  awk -v blk="$blk" -v key="$key" '
    $0 ~ "^[[:space:]]*" blk ":[[:space:]]*\{" { ing=1 }
    ing && $0 ~ "^[[:space:]]*" key ":[[:space:]]*\"" {
      match($0, "\"[^\"]*\""); print substr($0, RSTART+1, RLENGTH-2); exit
    }
    ing && /^[[:space:]]*\},[[:space:]]*$/ { ing=0 }
  ' "$SETTINGS"
}

# subst_once <file> <sed-expr> <literal-to-count> <label> — a substitution that ASSERTS it
# matched exactly once. A sed that silently matches nothing is the defect this whole script
# was rewritten around; every literal patch below goes through here.
subst_once() {
  local file="$1" expr="$2" needle="$3" label="$4" n
  n=$(grep -cF -- "$needle" "$file" || true)
  [[ "$n" == "1" ]] || { echo "ERROR: $label: expected 1 occurrence of '$needle' in ${file#"$BUILD_DIR/"}, found $n" >&2; exit 1; }
  sed -i -E "$expr" "$file"
}

ORIG_DOMAIN="$(read_key general domain)"
ORIG_SUB="$(read_key general subdomain)"
# The sender address embeds the domain, and it is the source every mail anchor is rewritten
# from — anonymize it too or the real domain survives the scrub.
ORIG_SENDER="$(read_key mail senderEmail)"
ANON_SENDER="${ORIG_SENDER%@*}@$ANON_DOMAIN"
[[ -n "$ORIG_DOMAIN" ]] || { echo "ERROR: could not read general.domain" >&2; exit 1; }

rewrite_key general domain    "$ANON_DOMAIN"
rewrite_key general subdomain "$ANON_SUB"
rewrite_key mail senderEmail  "$ANON_SENDER"

# repoUrl sits at argocd.git.repoUrl — two levels deep, which the single-block rewrite_key
# above cannot address. It occurs exactly once in the file, so patch the literal and assert.
ORIG_REPO_URL="$(grep -oE 'git@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git' "$SETTINGS" | head -n1)"
subst_once "$SETTINGS" "s#${ORIG_REPO_URL//./\\.}#${ANON_REPO_URL}#" "$ORIG_REPO_URL" "repoUrl"
# applyProjectSettings.py HARD-FAILS on a repoUrl it cannot parse, 300 lines deeper in Python.
# Assert the shape here so a bad placeholder fails with a message that names the cause.
[[ "$ANON_REPO_URL" =~ ^git@github\.com:[^/[:space:]]+/[^[:space:]]+\.git$ ]] \
  || { echo "ERROR: ANON_REPO_URL '$ANON_REPO_URL' is not git@github.com:owner/repo.git" >&2; exit 1; }

# The robot box's real public IPv4. Anchored into headscale's DERP address, so the engine
# propagates it from here.
ORIG_ROBOT_IP="$(grep -oE 'publicIp: "[0-9.]+"' "$SETTINGS" | head -n1 | grep -oE '[0-9.]+')"
if [[ -n "$ORIG_ROBOT_IP" ]]; then
  sed -i "s/publicIp: \"$ORIG_ROBOT_IP\"/publicIp: \"$ANON_ROBOT_IP\"/" "$SETTINGS"
fi

echo "Anonymized: domain=$ANON_DOMAIN subdomain=$ANON_SUB sender=$ANON_SENDER repo=$ANON_REPO_URL"

# ── 5. Regenerate every derived value ────────────────────────────────────────────────────
# ⚠ --old-domain is what makes the domain half take effect: every rewrite in that script keys
# on the NEW general.domain, so without the previous value the manifests silently keep the old
# one (they did, until 2026-09-04). This is the subtle part; do not drop it.
bash "$BUILD_DIR/scripts/environment/updateConfigFromProjectSettings.sh" --old-domain "$ORIG_DOMAIN"

# ── 6. Patch the literals no setting drives ──────────────────────────────────────────────
# Anything reachable from project_settings.ts was handled by the engine above. What remains is
# prose and defaults, each asserted so a stale patch fails loudly.
#
# The lab SSH jump host is a third party's machine; it is read only by Pulumi at apply time
# (no anchor), so rewriting it propagates nowhere and breaks nothing.
ORIG_JUMP="$(grep -oE '[a-z0-9.-]+\.techfak\.uni-bielefeld\.de' "$SETTINGS" | head -n1 || true)"
if [[ -n "$ORIG_JUMP" ]]; then
  find "$BUILD_DIR" -type f \( -name '*.ts' -o -name '*.sh' -o -name '*.md' -o -name '*.yaml' \) \
    -exec sed -i "s/${ORIG_JUMP//./\\.}/jump.${ANON_DOMAIN}/g" {} +
fi

# README measurement provenance: a real cluster generation in prose.
if grep -q 'cluster ecc[0-9]' "$BUILD_DIR/README.md" 2>/dev/null; then
  sed -i -E 's/cluster ecc[0-9]+/cluster <clusterN>/g' "$BUILD_DIR/README.md"
fi

# ── 7. Prune internal working material ───────────────────────────────────────────────────
# plans/ is an in-flight engineering log: unfinished decisions, the bulk of the eccNNN
# measurement references, and little value to an outside reader. doc/ is the POINT of
# publishing an infra repo and ships — but only if it passes the gate below.
if [[ -z "$KEEP_PLANS" ]]; then
  rm -rf "$BUILD_DIR/plans"
  rm -f  "$BUILD_DIR/ToDo.md" "$BUILD_DIR/DEBUG.md"
fi

# ── 8. THE GATE ──────────────────────────────────────────────────────────────────────────
# Every step above is a substitution, and a substitution that matches nothing does not fail.
# So the release does not get to CLAIM it is clean — this proves it, and refuses to produce a
# committed artifact otherwise.
echo ""
if ! python3 "$SCRIPT_DIR/checkReleaseClean.py" --root "$BUILD_DIR"; then
  echo "" >&2
  echo "RELEASE ABORTED — nothing was committed. The build is left at" >&2
  echo "  ${BUILD_DIR#"$REPO_ROOT/"}/" >&2
  echo "for inspection. Fix the findings in the SOURCE repo (preferred: every future" >&2
  echo "release is then clean), or add a substitution to this script." >&2
  exit 1
fi

# ── 9. One commit, no remote ─────────────────────────────────────────────────────────────
# No remote is added, ever: an accidental push of a build is the one unrecoverable error here.
git -C "$BUILD_DIR" add -A
git -C "$BUILD_DIR" -c user.email=release@example.org -c user.name="Release" \
    commit -q -m "Initial public release"

echo ""
echo "Release built: ${BUILD_DIR#"$REPO_ROOT/"}/"
echo "  source     : ${SOURCE_REF:0:12}"
echo "  files      : $(git -C "$BUILD_DIR" ls-files | wc -l)"
echo "  history    : $(git -C "$BUILD_DIR" rev-list --count HEAD) commit"
echo ""
echo "Review it, then publish with:"
echo "  cd ${BUILD_DIR#"$REPO_ROOT/"} && git remote add origin <public-repo-url> && git push -u origin main"
