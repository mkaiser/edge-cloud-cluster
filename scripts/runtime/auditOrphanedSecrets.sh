#!/usr/bin/env bash
# Read-only orphan audit for OIDC / sealed-secret drift. Prints a report; changes nothing.
# Run it after disabling an app, which is when these three drift:
#   1. SealedSecret manifests in git whose app has no app-of-apps/<app>.yaml.
#   2. Authentik providers/applications with no matching ENABLED app — needs cluster access
#      and the provisioner token, so this section is best-effort.
#   3. *_OIDC_CLIENT_SECRET keys in the authentik bundle with no consumer. Apps migrated to
#      their own sealSecrets.sh no longer read the bundle, so their key lingers there.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPS_DIR="$REPO_DIR/deployment/argocd-apps"
ROOT_APPS="$APPS_DIR/app-of-apps"

echo "=== Orphan audit ==="
echo ""

# --- Class 1: per-app sealed files whose app has no enabled app-of-apps manifest ---
echo "[1] App sealed-secret files with no enabled app-of-apps/<app>.yaml:"
found1=0
for d in "$APPS_DIR"/*/; do
  app="$(basename "$d")"
  [ "$app" = "app-of-apps" ] && continue
  # Does the app have any sealed files?
  if ! compgen -G "$d"'*-sealed.yaml' >/dev/null; then continue; fi
  # Is the app enabled (app-of-apps/<app>.yaml present, not .disable)?
  if [ ! -f "$ROOT_APPS/$app.yaml" ]; then
    echo "  - $app: has $(ls "$d"*-sealed.yaml 2>/dev/null | wc -l) sealed file(s) but no enabled app-of-apps/$app.yaml"
    [ -f "$ROOT_APPS/$app.yaml.disable" ] && echo "      (app-of-apps/$app.yaml.disable exists — temporarily disabled)"
    found1=1
  fi
done
[ "$found1" -eq 0 ] && echo "  (none)"
echo ""

# --- Class 3 (legacy): bundle OIDC keys with no obvious consumer ---
echo "[3] Legacy *_OIDC_CLIENT_SECRET keys still in the authentik bundle:"
BUNDLE="$REPO_DIR/deployment/argocd-infra/authentik/authentik-secrets-sealed.yaml"
if [ -f "$BUNDLE" ]; then
  grep -oE '^[[:space:]]+[A-Z0-9_]+_OIDC_CLIENT_SECRET:' "$BUNDLE" 2>/dev/null \
    | sed -E 's/^[[:space:]]+/  - /; s/:$//' | sort -u || true
  echo "  (review: migrated per-app OIDC apps no longer need their bundle entry)"
else
  echo "  (bundle not found)"
fi
echo ""

# --- Class 2: Authentik providers/applications with no matching enabled app ---
echo "[2] Authentik providers/applications with no matching enabled app:"
TOKEN=""
if command -v kubeseal >/dev/null 2>&1; then
  PRIV=$(cd "$REPO_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null || true)
  if [ -n "$PRIV" ] && [ -f "$BUNDLE" ]; then
    TOKEN=$(kubeseal --recovery-unseal --recovery-private-key <(echo "$PRIV") < "$BUNDLE" -o json 2>/dev/null \
      | jq -r '.data.AUTHENTIK_PROVISIONER_TOKEN // empty' | base64 -d 2>/dev/null || true)
  fi
fi
if [ -z "$TOKEN" ] || ! kubectl cluster-info >/dev/null 2>&1; then
  echo "  (skipped — needs cluster access + provisioner token in the bundle)"
else
  kubectl port-forward -n authentik svc/authentik-server 19001:80 >/tmp/audit-ak-pf.log 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  API="http://127.0.0.1:19001/api/v3"; AUTH="Authorization: Bearer ${TOKEN}"
  for _ in $(seq 1 15); do curl -fsS -H "$AUTH" "$API/core/applications/" >/dev/null 2>&1 && break; sleep 1; done
  # Enabled app slugs from app-of-apps (best-effort: file basename == slug for most).
  enabled_apps=$(ls "$ROOT_APPS"/*.yaml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//' || true)
  curl -fsS -H "$AUTH" "$API/core/applications/?page_size=200" 2>/dev/null \
    | jq -r '.results[]?.slug' 2>/dev/null | while read -r slug; do
        # Slugs with no same-named app-of-apps manifest: they ship inside another
        # app (alertmanager + grafana live in kube-prometheus-stack) or are
        # Pulumi-managed, so the basename heuristic below would false-positive.
        case "$slug" in argocd-infra|argocd-apps|grafana|alertmanager|headscale) continue;; esac
        echo "$enabled_apps" | grep -qx "$slug" || echo "  - application slug '$slug' has no enabled app-of-apps manifest"
      done || true
fi

echo ""
echo "=== Audit complete (read-only) ==="
