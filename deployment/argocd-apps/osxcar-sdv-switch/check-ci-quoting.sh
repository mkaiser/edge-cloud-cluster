#!/usr/bin/env bash
# Assert no stray apostrophe inside the single-quoted `runuser ... bash -lc '...'` block.
#
# ⚠ WHY. That block is ONE shell argument delimited by single quotes. An apostrophe inside
# it — including in a COMMENT, e.g. a possessive or a quoted name like 'BBPATH' — closes the
# string, and a second one reopens it. The result is not a syntax error: the lines between
# the two silently execute in the OUTER shell, which is root.
#
# Measured on job 25 (2026-09-12): three comment apostrophes split the block, so `module
# load` ran as ROOT. The shims were written into /home/headless correctly but landed on
# root's PATH, so the build shell reported
#   PATH module-bin entries: NONE
# with every shim file present and executable, and petalinux-config failed with
#   petalinux-build.sh: line 105: petalinux-config: command not found
# which reads as a PATH or module bug rather than a quoting one.
#
# ⚠ BASH WRAPPER AROUND PYTHON: precommit runs each check as `bash "$script"`, so a python
# shebang would execute the docstring as shell and pass while asserting nothing.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT
exec python3 - "$@" <<'PYEOF'
"""Fail if the runuser block contains an apostrophe other than its own delimiters."""
import os, sys

ROOT = os.environ["REPO_ROOT"]
CI = os.path.join(ROOT, "deployment/argocd-apps/osxcar-sdv-switch/ci/osxcar-sdv-switch.yml")

lines = open(CI).read().split("\n")
start = None
fail = []
for i, line in enumerate(lines):
    if start is None:
        if "runuser -u headless -- bash -lc '" in line:
            start = i
        continue
    # closing delimiter: a line that is only whitespace plus a single quote
    if line.strip() == "'":
        start = None
        continue
    if "'" in line:
        fail.append((i + 1, line.strip()))

if start is not None:
    fail.append((len(lines), "the runuser block is never closed"))

if fail:
    print("CI quoting check FAILED — apostrophe inside the single-quoted runuser block:",
          file=sys.stderr)
    for n, text in fail:
        print(f"  - line {n}: {text[:100]}", file=sys.stderr)
    print("\nAn apostrophe there closes the string and the rest runs as ROOT in the outer\n"
          "shell. Rephrase to avoid it (no possessives, no 'quoted names').", file=sys.stderr)
    sys.exit(1)

print("ok: runuser block is a clean single-quoted string (no stray apostrophes)")
PYEOF
