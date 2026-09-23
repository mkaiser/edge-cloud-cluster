#!/bin/bash
# Permanently remove XWiki's sealed secrets + de-provision its Authentik OIDC +
# SCIM objects. The "remove for good" counterpart to *.yaml.disable (runtime-only).
#
# Flags:
#   --force              non-interactive (skip the destructive confirmation)
#   --skip-git-commit  remove files but do not git-commit the removal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/deployment/manageSealedSecrets.sh"

export REMOVE_YES=0 REMOVE_SKIP_GIT_COMMIT=0
for arg in "$@"; do case "$arg" in
  --force)             REMOVE_YES=1 ;;
  --skip-git-commit) REMOVE_SKIP_GIT_COMMIT=1 ;;
esac; done

# OIDC app: de-provision the OIDC provider/tile via the shared helper...
authentik_deprovision xwiki

# ...and the SCIM provider/tile (xwiki-specific). Best-effort.
deprovision_scim() {
  local token pf api auth pk
  token=$(try_recover "$REPO_DIR/deployment/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
  [[ -z "$token" ]] && { echo "Provisioner token unavailable — skipping SCIM cleanup."; return 0; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "Cluster unreachable — skipping SCIM cleanup."; return 0; }
  kubectl port-forward -n authentik svc/authentik-server 19010:80 >/tmp/xwiki-scim-pf.log 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' RETURN
  api="http://127.0.0.1:19010/api/v3"; auth="Authorization: Bearer ${token}"
  for _ in $(seq 1 15); do curl -fsS -H "$auth" "$api/core/applications/?slug=xwiki-scim" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS -X DELETE -H "$auth" "$api/core/applications/xwiki-scim/" >/dev/null 2>&1 || true
  pk=$(curl -fsS -H "$auth" "$api/providers/scim/?name=xwiki-scim" 2>/dev/null \
    | python3 -c "import json,sys; r=json.load(sys.stdin).get('results',[]); print(r[0]['pk'] if r else '')" 2>/dev/null || true)
  [[ -n "$pk" ]] && { echo "Deleting SCIM provider 'xwiki-scim' (pk=$pk)..."; curl -fsS -X DELETE -H "$auth" "$api/providers/scim/${pk}/" >/dev/null 2>&1 || true; }
  echo "XWiki SCIM cleanup done."
}
deprovision_scim

# git rm / rm this folder's sealed files (clears orphan class 1).
mapfile -t SEALED_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*-sealed.yaml' | sort)
remove_sealed "Remove xwiki sealed secrets + de-provision OIDC/SCIM" "${SEALED_FILES[@]}"
