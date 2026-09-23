#!/usr/bin/env bash
# Assert the two desktops' startup scripts have not drifted apart.
#
# ⚠ BASH WRAPPER AROUND PYTHON, DELIBERATELY. precommit's run_contract_check() invokes every
# check as `bash "$script"`, so a file with a `#!/usr/bin/env python3` shebang is executed BY
# BASH — the docstring runs as shell commands and the check silently passes without
# asserting anything. Keep this wrapper. (Same reasoning as check-module-runtime.sh.)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT
exec python3 - "$@" <<'PYEOF'
"""Every desktop runs the SAME startup script, from its own ConfigMap.

remote-desktop, remote-desktop-bender and the hermes desktop sidecar are the same desktop
for different audiences. Their `desktop-startup.sh` therefore has to stay identical — but a
ConfigMap cannot cross namespaces, so the script is necessarily duplicated and nothing in
Kubernetes or ArgoCD notices when one copy is fixed and the other is not.

⚠ WHY THIS MATTERS MORE THAN AN ORDINARY DUPLICATE. The script is ~35 KB and it FATALs on
sssd/krb5 drift by design — it compares its own baked-in realm against $AD_DOMAIN/$AD_REALM
and aborts rather than serving a half-configured directory. A fix applied to one desktop and
not the other is invisible until a user cannot log in to whichever copy was missed, and the
symptom (a Running pod, 2/2, that refuses every AD credential) points at sssd rather than at
the file that was never updated.

This is the same "duplicated fragment + a check that stops the copies drifting" pattern
module-runtime/check-module-runtime.sh documents in its own docstring.

What is allowed to differ: NOTHING inside the script body. Per-desktop values reach the
script through the POD ENV (AD_MACHINE_ACCOUNT, SESSION_MODE, …), which is exactly why the
script itself can be identical — if you find yourself wanting to branch on the desktop here,
add an env var to the Deployment instead.

Run by precommit; exits non-zero on drift.
"""
import os
import sys

import yaml

ROOT = os.environ["REPO_ROOT"]
KEY = "desktop-startup.sh"
COPIES = [
    "deployment/argocd-apps/remote-desktop/startup-configmap.yaml",
    "deployment/argocd-apps/remote-desktop-bender/startup-configmap.yaml",
    "deployment/argocd-apps/hermes/desktop-startup-configmap.yaml",
]

bodies = {}
fail = []

for rel in COPIES:
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        fail.append(f"{rel}: missing — both desktops must ship the startup script")
        continue
    doc = yaml.safe_load(open(path))
    data = (doc or {}).get("data") or {}
    if KEY not in data:
        fail.append(f"{rel}: ConfigMap has no {KEY!r} key")
        continue
    bodies[rel] = data[KEY]

if not fail and len(set(bodies.values())) > 1:
    # Compare every copy against the FIRST one, which is the canonical desktop.
    a = COPIES[0]
    b = next(c for c in COPIES[1:] if c in bodies and bodies[c] != bodies.get(a))
    la, lb = bodies[a].split("\n"), bodies[b].split("\n")
    # Name the FIRST differing line: "they differ" is not actionable on a 900-line script.
    where = next((i for i in range(max(len(la), len(lb)))
                  if (la[i] if i < len(la) else None) != (lb[i] if i < len(lb) else None)),
                 None)
    detail = ""
    if where is not None:
        detail = (f"\n      first difference at line {where + 1} of {KEY}:"
                  f"\n        {a}: {(la[where] if where < len(la) else '<end of file>').strip()!r}"
                  f"\n        {b}: {(lb[where] if where < len(lb) else '<end of file>').strip()!r}")
    fail.append(
        f"the desktops' {KEY} have DRIFTED ({len(la)} vs {len(lb)} lines). They must be "
        f"byte-identical: a fix applied to one desktop and not the other is invisible until "
        f"a user cannot log in to the one that was missed.{detail}")

if fail:
    print("\nstartup-drift check FAILED:", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print(f"startup-drift check: OK — {len(bodies)} desktop(s) share an identical {KEY}")
PYEOF
