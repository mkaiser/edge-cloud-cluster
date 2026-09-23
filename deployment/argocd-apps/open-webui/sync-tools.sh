#!/usr/bin/env bash
# Regenerate tools-configmap.yaml from the Open WebUI Tool sources.
#
# WHY A GENERATED CONFIGMAP: the sources live in ollama-turing/tools/*.py, which that app's
# ArgoCD Application EXCLUDES (`exclude: "{*.sh,README.md,*.py,tools/*}"`) — ArgoCD would
# otherwise try to apply Python as a manifest. So the installer Job cannot read them from
# the repo tree; the content has to be embedded in a manifest that ArgoCD does ship.
#
# The hazard this file exists to prevent is DRIFT: the ConfigMap is what actually gets
# installed, so a stale copy silently ships an old tool. Same trap recorded for the
# remote-desktop build files. Hence
# `--check`, which the pre-commit hook can call to fail on an unsynced copy.
#
# Usage:  sync-tools.sh          regenerate in place
#         sync-tools.sh --check  exit 1 if the generated file is stale
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src_dir="$here/../ollama-turing/tools"
out="$here/tools-configmap.yaml"

# id -> source file. The id is the Open WebUI tool id: it must satisfy str.isidentifier()
# and is the key the installer PUTs to, so changing one orphans the old tool rather than
# updating it.
declare -A TOOLS=(
  [model_library]="model_pull.py"
  [llm_backend_switch]="llm_backend_switch.py"
)

emit() {
  cat <<'HDR'
# GENERATED — do NOT hand-edit. Edit the source under ../ollama-turing/tools/ and run
#   deployment/argocd-apps/open-webui/sync-tools.sh
# Verify with `sync-tools.sh --check` before committing: this ConfigMap is what the
# installer Job actually applies, so a stale copy ships an old tool.
#
# A PLAIN resource, deliberately NOT an ArgoCD hook. It was a PreSync hook, and that was a
# silent bug: hook resources are NOT drift-compared, so editing a tool source and syncing left
# the app Synced/Healthy while the cluster still held the OLD ConfigMap — the installer Job
# then dutifully re-installed the previous version. Measured; it needed a manual
# `kubectl apply`.
#
# As a normal resource it is diffed like anything else, so a source edit shows as OutOfSync and
# self-heals. The negative sync-wave keeps it ahead of the Deployment; the installer that
# consumes it is a PostSync hook, which by definition runs after all waves.
apiVersion: v1
kind: ConfigMap
metadata:
  name: open-webui-tools
  namespace: open-webui
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
data:
HDR
  for id in $(printf '%s\n' "${!TOOLS[@]}" | sort); do
    f="$src_dir/${TOOLS[$id]}"
    [ -f "$f" ] || { echo "missing source: $f" >&2; exit 1; }
    printf '  %s.py: |\n' "$id"
    # 4-space indent under the block scalar. sed, not a heredoc: the sources contain
    # arbitrary text and must pass through byte-for-byte.
    sed 's/^/    /' "$f"
  done
}

if [ "${1:-}" = "--check" ]; then
  if ! diff -q <(emit) "$out" >/dev/null 2>&1; then
    echo "STALE: $out does not match the sources. Run sync-tools.sh." >&2
    exit 1
  fi
  echo "tools-configmap.yaml is in sync."
  exit 0
fi

emit > "$out"
echo "wrote $out"
