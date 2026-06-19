#!/bin/bash
# Delete the Ryax portal tile from Authentik via API.
# No-op if the authentik namespace or the application does not exist.
set -euo pipefail

if ! kubectl get namespace authentik >/dev/null 2>&1; then
  exit 0
fi

AUTHENTIK_TOKEN=$(kubectl get secret -n authentik authentik-secrets \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
AUTHENTIK_HOST="https://$(kubectl get ingress -n authentik authentik-server \
  -o jsonpath='{.spec.rules[0].host}')"
curl -sfk -X DELETE "$AUTHENTIK_HOST/api/v3/core/applications/ryax/" \
  -H "Authorization: Bearer $AUTHENTIK_TOKEN" || true
