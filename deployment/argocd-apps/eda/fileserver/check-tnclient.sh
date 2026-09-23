#!/bin/bash
# Assert that eda-fileserver's embedded tnclient.py is byte-identical to the one in
# argocd-infra/truenas/configure-job.yaml.
#
# WHY A CHECK AND NOT A GENERATOR: a ConfigMap cannot be mounted across namespaces, and
# truenas/verify-job.yaml already mounts the configure job's ConfigMap for this same file.
# So three consumers need the same source in two namespaces, and the copy is unavoidable.
# What IS avoidable is the copies drifting apart silently — hence this.
#
#   ./check-tnclient.sh          exit 1 if they differ (precommit runs this)
#   ./check-tnclient.sh --fix    overwrite the eda-fileserver copy from the infra one
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SRC="$ROOT_DIR/deployment/argocd-infra/truenas/configure-job.yaml"
DST="$SCRIPT_DIR/provision-job.yaml"
MODE="${1:-}"

python3 - "$SRC" "$DST" "$MODE" <<'PY'
import sys, yaml
src_path, dst_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

def extract(path):
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "ConfigMap" and "tnclient.py" in (d.get("data") or {}):
            return d["data"]["tnclient.py"]
    raise SystemExit(f"ERROR: no tnclient.py ConfigMap in {path}")

want, got = extract(src_path), extract(dst_path)
if want == got:
    print("ok: eda-fileserver tnclient.py matches argocd-infra/truenas")
    raise SystemExit(0)

if mode != "--fix":
    import difflib
    print("DRIFT: eda-fileserver/provision-job.yaml tnclient.py differs from "
          "argocd-infra/truenas/configure-job.yaml", file=sys.stderr)
    for line in list(difflib.unified_diff(
            want.split("\n"), got.split("\n"),
            fromfile="truenas/configure-job.yaml", tofile="eda-fileserver/provision-job.yaml",
            lineterm=""))[:40]:
        print("  " + line, file=sys.stderr)
    print("\nRe-sync with: deployment/argocd-apps/eda/fileserver/check-tnclient.sh --fix",
          file=sys.stderr)
    raise SystemExit(1)

# --fix: splice the authoritative text back in, preserving the 2-space YAML indent.
lines = open(dst_path).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.rstrip() == "  tnclient.py: |")
end = next(i for i in range(start + 1, len(lines))
           if lines[i].strip() and not lines[i].startswith("    "))
body = ["    " + l if l.strip() else "" for l in want.split("\n")]
while body and body[-1] == "":
    body.pop()
open(dst_path, "w").write("\n".join(lines[:start + 1] + body + lines[end:]))
print("fixed: rewrote eda-fileserver tnclient.py from argocd-infra/truenas")
PY
