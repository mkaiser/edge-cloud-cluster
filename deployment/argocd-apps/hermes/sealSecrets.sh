#!/bin/bash
# Seals the Hermes Agent secrets.
# Idempotent: recovers existing values from the sealed file on re-runs.
# Pass --regenerate to rotate the two server keys (NOT the LiteLLM key — that is owned
# by litellm/sealSecrets.sh; rotate it there).
#
# WHY THIS FILE EXISTS: hermes was committed WITHOUT it, so `hermes-secrets` was never
# created and hermes-0 sat in Init:CreateContainerConfigError for 2+ days
# (`secret "hermes-secrets" not found`, ~12k kubelet retries). It was the only app
# directory referencing a Secret with neither a sealSecrets.sh nor a *-sealed.yaml.
#
# Generates:
#   hermes-secrets-sealed.yaml — three keys consumed by statefulset.yaml:
#     api-server-key          — bearer token for the DEFAULT profile's HTTP API.
#                               ⚠ Hermes refuses to start if this is <16 chars or looks
#                               like a placeholder, and marks the failure NON-RETRYABLE.
#                               32 bytes hex clears that comfortably.
#     profile-api-server-key  — bearer token for the seeded SECONDARY profile. Distinct
#                               on purpose: the whole point of per-profile keys is that
#                               the default key must NOT open another user's profile.
#     litellm-key             — credential Hermes presents to the LiteLLM gateway.
#                               Recovered from litellm/litellm-secrets-sealed.yaml
#                               (the master key), same as open-webui does, so the two
#                               stay in sync. Run litellm/sealSecrets.sh FIRST.
#     dashboard-username      — basic-auth for the admin dashboard.
#     dashboard-password        ⚠ BOTH ARE MANDATORY, not optional hardening: since the
#                               June-2026 hardening the dashboard's auth gate engages on
#                               ANY non-loopback bind and FAILS CLOSED, and
#                               HERMES_DASHBOARD_INSECURE is accepted but ignored. Without
#                               them the container does not start —
#                               `couldn't find key dashboard-username in Secret`
#                               (hit for real; the first version of this script sealed only
#                               three keys and the pod still would not come up). Authentik
#                               in front is the primary gate; this is the second factor
#                               that also covers in-cluster callers.
#
#   oidc-client-secret-sealed.yaml       — hermes-oidc-client-secret, key client-secret.
#                               Confidential-client secret for the Authentik OAuth2
#                               provider that gates the admin dashboard. Consumed by
#                               authentik-provider.yaml (to create the provider) and by
#                               statefulset.yaml (written into $HERMES_HOME/.env as
#                               HERMES_DASHBOARD_OIDC_CLIENT_SECRET). Both sides must
#                               carry the SAME value or the token exchange 401s.
#   authentik-provisioner-token-sealed.yaml — authentik-provisioner-token, key token.
#                               Scoped Authentik API token used by the PostSync/PreDelete
#                               provider jobs. Same plaintext as the central
#                               AUTHENTIK_PROVISIONER_TOKEN — run authentik/sealSecrets.sh
#                               first so it can be recovered rather than pasted.
#
# ⚠ These bearer keys are effectively RCE credentials: Hermes runs arbitrary shell in a
# pod on the cluster pod network. Treat them like the LiteLLM master key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# --- the two API server keys ---
API_SERVER_KEY=$(recover_or_generate "$SCRIPT_DIR/hermes-secrets-sealed.yaml" api-server-key "$REGEN" 32)
PROFILE_API_SERVER_KEY=$(recover_or_generate "$SCRIPT_DIR/hermes-secrets-sealed.yaml" profile-api-server-key "$REGEN" 32)

# --- credential to the LiteLLM gateway (owned by litellm, mirrored here) ---
LITELLM_KEY=$(try_recover "$SCRIPT_DIR/../litellm/litellm-secrets-sealed.yaml" master-key)
[[ -z "$LITELLM_KEY" ]] && LITELLM_KEY=$(try_recover "$SCRIPT_DIR/hermes-secrets-sealed.yaml" litellm-key)
if [[ -z "$LITELLM_KEY" ]]; then
  echo "ERROR: LiteLLM master key not found — run litellm/sealSecrets.sh first." >&2
  exit 1
fi

# --- admin dashboard basic auth (mandatory; see the header) ---
DASHBOARD_USERNAME=$(try_recover "$SCRIPT_DIR/hermes-secrets-sealed.yaml" dashboard-username)
[[ -z "$DASHBOARD_USERNAME" ]] && DASHBOARD_USERNAME="hermes-admin"
DASHBOARD_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/hermes-secrets-sealed.yaml" dashboard-password "$REGEN" 32)

seal_secret hermes hermes-secrets hermes-secrets-sealed.yaml \
  --from-literal=api-server-key="$API_SERVER_KEY" \
  --from-literal=profile-api-server-key="$PROFILE_API_SERVER_KEY" \
  --from-literal=litellm-key="$LITELLM_KEY" \
  --from-literal=dashboard-username="$DASHBOARD_USERNAME" \
  --from-literal=dashboard-password="$DASHBOARD_PASSWORD"

# --- the desktop sidecar's break-glass local account ---
# Every normal login to the desktop is an AD identity through xrdp/SSSD and has no password
# here; this is the local `desktop` account (uid 2001) for when Authentik or the mesh is down.
RDP_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/hermes-desktop-secrets-sealed.yaml" rdp-password "$REGEN" 32)
seal_secret hermes hermes-desktop-secrets hermes-desktop-secrets-sealed.yaml \
  --from-literal=rdp-password="$RDP_PASSWORD"

# --- dashboard OIDC (Authentik) ---
# OIDC client secret (key client-secret, matching authentik-provider.yaml + the
# HERMES_DASHBOARD_OIDC_CLIENT_SECRET the init container writes into .env).
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret hermes hermes-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret hermes authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST command makes
# the script exit 1, so --skip-git-commit looks like a failure to the caller
# (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal Hermes secrets" \
    "$SCRIPT_DIR/hermes-secrets-sealed.yaml" \
    "$SCRIPT_DIR/hermes-desktop-secrets-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
