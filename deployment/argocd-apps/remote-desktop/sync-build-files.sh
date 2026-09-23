#!/bin/bash
# Regenerate (or verify) the embedded copies of build files inside a
# build-files-configmap.yaml from their source files.
#
# The ConfigMap is what the build-trigger mirrors into GitLab, so the EMBEDDED copy is
# what actually gets built — a divergence from the source file is silent and ships
# broken behaviour. Source files always win.
#
#   ./sync-build-files.sh [dir]          rewrite the ConfigMap from the sources
#   ./sync-build-files.sh [dir] --check  exit 1 if any embedded copy differs
#
# `dir` defaults to this script's directory (remote-desktop). Pass another app dir
# (e.g. ../eda/hyperlynx-2604) to sync that app's ConfigMap. Key→source mapping is by
# convention: a ConfigMap key is generated from the identically-named file in `dir`,
# except remote-desktop's Dockerfile/.gitlab-ci.yml which come from
# Dockerfile.base/ci-base.yml (GitLab requires the canonical names in the ConfigMap).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DIR="$SCRIPT_DIR"
MODE="write"
for a in "$@"; do
  case "$a" in
    --check) MODE="--check" ;;
    *) TARGET_DIR="$(cd "$a" && pwd)" ;;
  esac
done
CM="$TARGET_DIR/build-files-configmap.yaml"
[ -f "$CM" ] || { echo "ERROR: no build-files-configmap.yaml in $TARGET_DIR" >&2; exit 2; }

python3 - "$CM" "$MODE" "$TARGET_DIR" <<'PY'
import sys, os, re

cm_path, mode, script_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def source_for(key):
    # remote-desktop keeps these under infra-repo-specific names.
    special = {"Dockerfile": "Dockerfile.base", ".gitlab-ci.yml": "ci-base.yml"}
    if key in special and os.path.exists(os.path.join(script_dir, special[key])):
        return special[key]
    return key

lines = open(cm_path).read().split("\n")

# Locate each "  <key>: |" block and the line range of its indented body.
blocks = {}
cur, start = None, None
for i, ln in enumerate(lines):
    m = re.match(r"^  ([A-Za-z0-9._-]+): \|\s*$", ln)
    if m:
        if cur:
            blocks[cur] = (start, i)
        cur, start = m.group(1), i + 1
        continue
    if cur is not None and ln.strip() and not ln.startswith("    "):
        blocks[cur] = (start, i)
        cur, start = None, None
if cur:
    blocks[cur] = (start, len(lines))

# Only keys that have a matching source file on disk are managed; anything else in the
# ConfigMap is authored inline and left untouched.
mapping = {}
for key in blocks:
    src = source_for(key)
    if os.path.exists(os.path.join(script_dir, src)):
        mapping[key] = src

if not mapping:
    print(f"ERROR: no ConfigMap key in {cm_path} has a matching source file", file=sys.stderr)
    sys.exit(2)

drift = []
for key, src in mapping.items():
    s, e = blocks[key]
    embedded = "\n".join(l[4:] if l.startswith("    ") else "" for l in lines[s:e]).strip()
    real = open(os.path.join(script_dir, src)).read().strip()
    if embedded != real:
        drift.append(f"{key} <- {src}")

if mode == "--check":
    if drift:
        print("ERROR: build-files-configmap.yaml is STALE vs its source files:", file=sys.stderr)
        for d in drift:
            print(f"  - {d}", file=sys.stderr)
        print(f"Run: deployment/argocd-apps/remote-desktop/sync-build-files.sh {script_dir}", file=sys.stderr)
        sys.exit(1)
    print("build-files-configmap.yaml is in sync with all source files.")
    sys.exit(0)

if not drift:
    print("Already in sync — nothing to do.")
    sys.exit(0)

# Rewrite stale blocks back-to-front so earlier line offsets stay valid.
for key in sorted(blocks, key=lambda k: blocks[k][0], reverse=True):
    if key not in mapping:
        continue
    s, e = blocks[key]
    body = open(os.path.join(script_dir, mapping[key])).read().rstrip("\n")
    indented = [("    " + l) if l.strip() else "" for l in body.split("\n")]
    lines[s:e] = indented

out = "\n".join(lines)
open(cm_path, "w").write(out if out.endswith("\n") else out + "\n")
print("Rewrote from source: " + ", ".join(drift))
PY
