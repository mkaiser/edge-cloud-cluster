#!/bin/bash
# Assert every shell step in every EDA .gitlab-ci.yml actually PARSES.
#
# WHY THIS EXISTS: an edit that drops a branch can drop the `fi` closing the enclosing
# `if` in several apps at once, and nothing else catches it — the YAML stays valid, the
# ConfigMap mirrors sync, and every other check passes. It surfaces only when the pipelines
# die within seconds of starting:
#
#   /scripts-4-24/step_script: eval: line 344: syntax error: unexpected end of file
#                              from `if' command on line 201
#
# That is the same failure class as the stray `fi` in postsync-build-image.yaml (fixed the
# same day): a shell script embedded in YAML is never syntax-checked by anything that
# handles YAML, so a broken one ships green and fails at run time — after the runner has
# already pulled an image and cloned the repo.
#
# Checks `script`, `before_script` and `after_script` of every job with `sh -n`, which is
# parse-only: it never executes anything and does not care that $CI_ variables are unset.
#
#   ./check-ci-shell.sh    exit 1 on the first unparseable step, reporting job and index
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import glob, os, subprocess, sys, yaml

root = sys.argv[1]
# The EDA module builds, plus remote-desktop's ci-base.yml. The latter is not under
# eda/ and is not named .gitlab-ci.yml (it is MIRRORED into GitLab under that name by
# presync-build-desktop.yaml), so a glob alone would silently miss it — while it runs on
# the same [eda] runner and carries the same nested if/else/fi shell this check exists for.
patterns = [
    os.path.join(root, "deployment/argocd-apps/eda/*/.gitlab-ci.yml"),
    os.path.join(root, "deployment/argocd-apps/remote-desktop/ci-base.yml"),
    # ollama and vllm build on the same [eda]/[thor] runners and carry the same
    # recover-or-rebuild + archive shell, so they fail the same way. They live outside
    # eda/, which the glob above would silently skip.
    os.path.join(root, "deployment/argocd-apps/*/.gitlab-ci.yml"),
]
files = sorted(f for pat in patterns for f in glob.glob(pat))
if not files:
    print(f"ERROR: no CI files found under {patterns}", file=sys.stderr)
    sys.exit(2)

fail = []
checked = 0
for f in files:
    rel = os.path.relpath(f, root)
    try:
        doc = yaml.safe_load(open(f))
    except Exception as exc:
        fail.append(f"{rel}: not parseable as YAML — {exc}")
        continue
    for job_name, job in (doc or {}).items():
        if not isinstance(job, dict):
            continue
        for key in ("script", "before_script", "after_script"):
            for i, step in enumerate(job.get(key) or []):
                if not isinstance(step, str):
                    continue
                checked += 1
                # `sh -n` PARSES ONLY. Deliberately /bin/sh, not bash: the runner executes
                # these under the image's shell, which for alpine-based images is ash.
                r = subprocess.run(["sh", "-n"], input=step,
                                   capture_output=True, text=True)
                if r.returncode:
                    fail.append(f"{rel}: {job_name}.{key}[{i}] — {r.stderr.strip()[:160]}")

if fail:
    print(f"\nCI shell syntax FAILED — {len(fail)} unparseable step(s):", file=sys.stderr)
    for x in fail:
        print("  " + x, file=sys.stderr)
    print("\nThese would fail AT RUN TIME, after the runner pulls an image and clones.",
          file=sys.stderr)
    sys.exit(1)
print(f"ok: {checked} shell step(s) across {len(files)} CI file(s) parse")
PY
