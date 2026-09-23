#!/usr/bin/env bash
# Assert the GENERATED module launcher is valid shell.
#
# ⚠ WHY THIS EXISTS. The launcher body is a python f-string inside module-cli.sh, so python
# processes its escapes when the shim is generated — and the generated text is what actually
# runs in the desktop and in every CI job. Two regressions shipped in one afternoon because
# nothing checked the OUTPUT:
#   r56  a comment containing `\n` was split across two lines; the second line started with
#        `', NEVER ...` and the shell EXECUTED it. Every shim ran a bogus command and
#        petalinux-create failed with "PetaLinuxs: No such file or directory".
#   r57  "fixing" that with a RAW f-string stopped python collapsing `\\` to `\`, so every
#        shell line-continuation became `\\` and the shim died with
#        "syntax error near unexpected token '||'".
# Both are invisible in module-cli.sh itself and obvious in one `bash -n` of the output.
#
# ⚠ BASH WRAPPER AROUND PYTHON, DELIBERATELY: precommit runs every check as `bash "$script"`,
# so a python shebang would execute the docstring as shell and pass while asserting nothing.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT
exec python3 - "$@" <<'PYEOF'
"""Generate a module launcher exactly as module-cli.sh does, then assert it is valid shell."""
import os, re, subprocess, sys, tempfile

ROOT = os.environ["REPO_ROOT"]
CLI = os.path.join(ROOT, "deployment/argocd-apps/remote-desktop/module-cli.sh")

src = open(CLI).read()
try:
    blk = src[src.index("python3 - "):]
    blk = blk[blk.index("\n") + 1: blk.index("\nPY\n")]
    fn = blk[blk.index("def container_wrapper"): blk.index("\n# ── GUI entries")]
except ValueError as e:
    print(f"cannot locate the launcher generator in {CLI}: {e}", file=sys.stderr)
    sys.exit(1)

ns = {}
exec("import os,sys\nauthf='/run/authfile.json'\n" + fn, ns)
shim = ns["container_wrapper"]("petalinux/2024.1", "REG/IMG@sha256:" + "a" * 64,
                               "/usr/local/bin/petalinux-config", "petalinux-config")

fail = []

# 1. It must parse. This is the check that would have caught BOTH shipped regressions.
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write(shim)
    path = f.name
try:
    r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
    if r.returncode != 0:
        fail.append("the generated launcher is not valid bash:\n    " + r.stderr.strip())
finally:
    os.unlink(path)

# 2. No line-continuation may end in a DOUBLE backslash — that is the raw-string regression.
for i, line in enumerate(shim.split("\n"), 1):
    if line.rstrip().endswith("\\\\"):
        fail.append(f"line {i} ends with a double backslash (raw-string regression): {line.strip()!r}")

# 3. argv MUST go through printf, never echo: echo eats -n/-e/-E and silently drops them.
if not re.search(r"printf '%s\\n' \S+ \"\$@\"", shim):
    fail.append("argv is not written with `printf '%s\\n' <cmd> \"$@\"` — echo would delete "
                "any argument that is one of its own flags (-n, -en, -nE vanish; -e/-E are consumed)")
# ⚠ Skip COMMENT lines: the launcher deliberately DOCUMENTS the anti-pattern, and a naive
# search matches that comment and fails a correct shim (it did, first run).
for i, line in enumerate(shim.split("\n"), 1):
    if line.lstrip().startswith("#"):
        continue
    if re.search(r'for _a in .*; do echo ', line):
        fail.append(f"line {i} writes argv with `echo` in a loop — see the printf rule above")

# 4. No comment may be split mid-line by an expanded escape.
for i, line in enumerate(shim.split("\n"), 1):
    s = line.strip()
    if s.startswith("'") or s.startswith("', "):
        fail.append(f"line {i} looks like the tail of a split string/comment: {s!r}")

if fail:
    print("module launcher check FAILED:", file=sys.stderr)
    for f_ in fail:
        print(f"  - {f_}", file=sys.stderr)
    sys.exit(1)

print("ok: generated module launcher parses as bash, single-backslash continuations, "
      "argv via printf, no split comments")
PYEOF
