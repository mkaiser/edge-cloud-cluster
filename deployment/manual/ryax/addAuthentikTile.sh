#!/bin/bash
# Create or update the Ryax portal tile in Authentik via API.
# Idempotent — safe to run on re-installs.
# No-op if the authentik namespace does not exist.
set -euo pipefail

if ! kubectl get namespace authentik >/dev/null 2>&1; then
  echo "authentik namespace not found — skipping tile registration"
  exit 0
fi

AUTHENTIK_TOKEN=$(kubectl get secret -n authentik authentik-secrets \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
AUTHENTIK_HOST="https://$(kubectl get ingress -n authentik authentik-server \
  -o jsonpath='{.spec.rules[0].host}')"
RYAX_HOST="https://$(kubectl get ingress -n ryaxns ryax-haproxy \
  -o jsonpath='{.spec.rules[0].host}')"
APP_JSON="{\"name\":\"Ryax\",\"slug\":\"ryax\",\"meta_launch_url\":\"$RYAX_HOST\",\"group\":\"Development\",\"meta_icon\":\"https://raw.githubusercontent.com/RyaxTech/ryax-engine/master/docs/docs/_static/ryax-icon.png\"}"

# PATCH existing application; fall back to POST if it doesn't exist yet.
HTTP_CODE=$(curl -sk -o /tmp/ak-app.json -w "%{http_code}" \
  -X PATCH "$AUTHENTIK_HOST/api/v3/core/applications/ryax/" \
  -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$APP_JSON")
if [ "$HTTP_CODE" = "404" ]; then
  curl -sk -o /tmp/ak-app.json \
    -X POST "$AUTHENTIK_HOST/api/v3/core/applications/" \
    -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$APP_JSON"
fi
APP_PK=$(python3 -c "import json; print(json.load(open('/tmp/ak-app.json'))['pk'])")

# Bind access-ryax policy (defined in blueprint-apps.yaml) to the application.
# Skip if the binding already exists.
POLICY_PK=$(curl -sk "$AUTHENTIK_HOST/api/v3/policies/expression/?name=access-ryax" \
  -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pk'])")
EXISTING=$(curl -sk "$AUTHENTIK_HOST/api/v3/policies/bindings/?target=$APP_PK&policy=$POLICY_PK" \
  -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['pagination']['count'])")
if [ "$EXISTING" = "0" ]; then
  curl -sk -X POST "$AUTHENTIK_HOST/api/v3/policies/bindings/" \
    -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"target\":\"$APP_PK\",\"policy\":\"$POLICY_PK\",\"order\":0,\"enabled\":true}" \
    > /dev/null
fi

echo "Authentik tile created/updated for Ryax at $RYAX_HOST"
