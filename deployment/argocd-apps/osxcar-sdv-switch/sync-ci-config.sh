#!/usr/bin/env bash
# Regenerate ci-config-configmap.yaml from ci/*.yml.
#
# The PreSync hook seeds the pipeline config into its own GitLab project and reads it from a
# ConfigMap mount, so the ConfigMap carries an EMBEDDED COPY of ci/osxcar-sdv-switch.yml.
# That copy is what ships — edit the file under ci/, never the ConfigMap — and this script
# is what keeps them in step. Same shape as remote-desktop/sync-build-files.sh.
#
#   sync-ci-config.sh --write    rewrite the ConfigMap from ci/
#   sync-ci-config.sh            check only, fails if stale (this is what precommit runs)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/ci/osxcar-sdv-switch.yml"
OUT="$DIR/ci-config-configmap.yaml"
# ⚠ --check IS THE DEFAULT WHEN INVOKED WITH NO ARGUMENTS, and that is deliberate.
# precommit's run_contract_check() calls every check as `bash "$script"` with NO arguments.
# If the no-arg mode rewrote files, precommit would silently MUTATE the working tree during
# a commit instead of failing on drift — the staged copy would stay stale while the file on
# disk changed under you. `--write` is the explicit opt-in to rewriting.
CHECK=1
case "${1:-}" in
  --write) CHECK="" ;;
  --check|"") CHECK=1 ;;
  *) echo "usage: $(basename "$0") [--write|--check]" >&2; exit 2 ;;
esac

[ -f "$SRC" ] || { echo "ERROR: missing $SRC" >&2; exit 1; }

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{
  cat <<'HDR'
# ConfigMap carrying the pipeline config the PreSync hook seeds into GitLab.
#
# GENERATED — never hand-edit the embedded copy. Edit ci/osxcar-sdv-switch.yml and run:
#   deployment/argocd-apps/osxcar-sdv-switch/sync-ci-config.sh
# Verify with --check before committing; precommit runs it. The hook reads THIS ConfigMap,
# not the file under ci/, so silent drift would ship a stale pipeline.
apiVersion: v1
kind: ConfigMap
metadata:
  name: osxcar-sdv-switch-ci-config
  namespace: osxcar-sdv-switch
  annotations:
    argocd.argoproj.io/hook: PreSync
    # -2: must exist before the project hook (wave 0) mounts it.
    # ⚠ sync-wave, NOT hook-weight — the latter is not an ArgoCD annotation and was silently
    # ignored, so this ConfigMap and the Job that mounts it both landed in wave 0.
    argocd.argoproj.io/sync-wave: "-2"
data:
HDR
  printf '  osxcar-sdv-switch.yml: |\n'
  sed 's/^/    /' "$SRC"
} > "$tmp"

if [ -n "$CHECK" ]; then
  if ! diff -q "$tmp" "$OUT" >/dev/null 2>&1; then
    echo "ERROR: ci-config-configmap.yaml is STALE vs ci/osxcar-sdv-switch.yml" >&2
    echo "Run: deployment/argocd-apps/osxcar-sdv-switch/sync-ci-config.sh --write" >&2
    exit 1
  fi
  echo "ci-config-configmap.yaml is in sync with ci/osxcar-sdv-switch.yml"
else
  mv "$tmp" "$OUT"; trap - EXIT
  echo "Rewrote $OUT from ci/osxcar-sdv-switch.yml"
fi
