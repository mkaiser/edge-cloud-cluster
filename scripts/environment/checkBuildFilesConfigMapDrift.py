#!/usr/bin/env python3
"""Assert each `<key>: |` literal block in a build-files ConfigMap equals its source file.

The real Dockerfile/.gitlab-ci.yml are `exclude`d from the ArgoCD directory source, so the
ConfigMap copy is what actually reaches the build. Editing only the source file is silent:
ArgoCD syncs green, the trigger reads stale content, and nothing reports a problem.

A key normally names its own source file. Where the ConfigMap deliberately RENAMES a file
(remote-desktop presents Dockerfile.base as `Dockerfile` and ci-base.yml as
`.gitlab-ci.yml`, because the mirrored GitLab project needs those names), KEY_ALIASES maps
it back. A key that resolves to nothing is a hard ERROR, never a silent skip: that is the
exact drift this script exists to catch, and skipping left remote-desktop's Dockerfile
unchecked.
"""
import sys, pathlib

# key in the ConfigMap -> candidate source filenames, first match wins.
KEY_ALIASES = {
    "Dockerfile": ["Dockerfile", "Dockerfile.base"],
    ".gitlab-ci.yml": [".gitlab-ci.yml", "ci-base.yml"],
}

def blocks(text):
    out, cur, buf = {}, None, []
    for l in text.split('\n'):
        if l.startswith('  ') and not l.startswith('    ') and l.rstrip().endswith(': |'):
            if cur: out[cur] = '\n'.join(buf)
            cur, buf = l.strip()[:-3].strip(), []
        elif cur is not None:
            buf.append(l[4:] if l.startswith('    ') else l)
    if cur: out[cur] = '\n'.join(buf)
    return out

rc = 0
for cm in sys.argv[1:]:
    p = pathlib.Path(cm)
    for key, emb in blocks(p.read_text()).items():
        f = None
        for cand in KEY_ALIASES.get(key, [key]):
            if (p.parent / cand).exists():
                f = p.parent / cand
                break
        if f is None:
            print(f"UNRESOLVED: {cm} key '{key}' has no source file in {p.parent}/ "
                  f"(tried: {', '.join(KEY_ALIASES.get(key, [key]))}). Add it to "
                  f"KEY_ALIASES if the ConfigMap renames it, or the key is stale.",
                  file=sys.stderr)
            rc = 1
            continue
        if emb.rstrip('\n') != f.read_text().rstrip('\n'):
            print(f"DRIFT: {cm} key '{key}' != {f}", file=sys.stderr)
            rc = 1
        else:
            print(f"ok: {cm} '{key}' matches {f}")
if rc:
    print("\nRegenerate the ConfigMap from the source files before committing.", file=sys.stderr)
sys.exit(rc)
