#!/usr/bin/env python3
"""Fail if any EDA app is left with FORCE_REBUILD: "1".

WHY THIS EXISTS. `FORCE_REBUILD: "1"` is a ONE-SHOT: it exists to push a Dockerfile fix out
under a tag that must not change (the EDA module tags ARE the user-facing module version —
`module load petalinux/2024.1` — so they cannot be bumped the way remote-desktop's base-rN
is). The registry gate would otherwise see the tag already present and skip the build.

Left at "1" it stops being a fix and becomes a permanent cost: the app rebuilds from
installer media on EVERY ArgoCD sync — 12-30 minutes for the small modules and HOURS for the
Xilinx ones — while looking exactly like a normal sync. Nothing else in the repo notices.

A comment saying "reset to 0 once published" has already proven insufficient, which is why
this is enforced rather than documented: the value is set in one session and reset in
another, and the reset is the half that gets forgotten.

⚠ Checks BOTH the source .gitlab-ci.yml and the build-files-configmap.yaml copy: the
ConfigMap copy is what the build trigger mirrors into GitLab, so a reset source with a stale
ConfigMap still rebuilds forever.

To land a one-shot rebuild deliberately, set it to "1", let the pipeline publish, then reset
it to "0" in the SAME branch before this check runs in precommit. If a rebuild genuinely has
to span commits, that is what the ALLOW list below is for — add the app WITH a dated reason
and remove it when the image is published.
"""
import glob
import os
import re
import sys

# app dir name -> why it is temporarily allowed to sit at "1". KEEP THIS EMPTY in steady
# state; an entry here is a promise to come back, not a place to park one permanently.
ALLOW: dict[str, str] = {}

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAT = re.compile(r'^\s*FORCE_REBUILD:\s*"?1"?\s*(?:#.*)?$', re.M)

def main() -> int:
    bad = []
    files = sorted(
        glob.glob(os.path.join(ROOT, "deployment/argocd-apps/eda/*/.gitlab-ci.yml"))
        + glob.glob(os.path.join(ROOT, "deployment/argocd-apps/eda/*/build-files-configmap.yaml"))
    )
    for path in files:
        app = os.path.basename(os.path.dirname(path))
        if app in ALLOW:
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for m in PAT.finditer(text):
            line = text[: m.start()].count("\n") + 1
            bad.append((os.path.relpath(path, ROOT), line, app))

    if bad:
        print("FORCE_REBUILD check FAILED:", file=sys.stderr)
        print("  a ONE-SHOT rebuild flag was left enabled — every ArgoCD sync will rebuild", file=sys.stderr)
        print("  the image from installer media (12-30 min, hours for the Xilinx modules):", file=sys.stderr)
        for rel, line, app in bad:
            print(f"    {rel}:{line}  ({app})", file=sys.stderr)
        print("  Reset it to \"0\" once the rebuilt image is published AND registered.", file=sys.stderr)
        print("  Remember to reset BOTH the .gitlab-ci.yml and the configmap copy.", file=sys.stderr)
        return 1

    print(f"FORCE_REBUILD check: OK — {len(files)} EDA CI file(s), none left at \"1\".")
    return 0

if __name__ == "__main__":
    sys.exit(main())
