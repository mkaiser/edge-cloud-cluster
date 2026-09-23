#!/bin/bash
# Seals the eda-pcb-agent secrets.
# Idempotent: recovers existing values from the sealed files on re-runs.
# Pass --regenerate to rotate the generated values.
#
# ⚠ THIS APP SEALS NO COPY OF A SHARED SUPERUSER CREDENTIAL, deliberately. Three
# credentials it needs live in OTHER namespaces and are read LIVE at job runtime through a
# resourceNames-pinned ClusterRole, never sealed here:
#   AUTHENTIK_BOOTSTRAP_TOKEN  (ns authentik)       — creates the BlueprintInstance
#   the Guacamole DB password  (ns remote-desktop)  — seeds this app's tile
#   the LiteLLM master key     (ns litellm)         — MINTS this app's virtual key
# Sealing any of them would be a second copy to rotate and leak, and a rotated original
# would then silently diverge. Four existing apps already read the bootstrap token live.
#
# Generates:
#   eda-pcb-agent-secrets-sealed.yaml — consumed by deployment.yaml and the jobs:
#     rdp-password        — the shared AD account's password, typed at the xrdp greeter.
#                           ⚠ A FIXED, HUMAN-MEMORABLE VALUE by request, and therefore WEAK
#                           — see the block where it is set. Not generated; `--regenerate`
#                           is the way back to a random one.
#     authentik-password  — ⚠ THE SAME VALUE. It is one credential wearing two names: the
#                           blueprint sets it on the Authentik user, which LDAP-writes it
#                           to the DC, which is what the greeter then authenticates
#                           against. They are separate KEYS only because two different
#                           consumers read them. Derived below from one variable rather
#                           than generated twice — generate twice and they drift, the
#                           Guacamole tile stops logging in, and it presents as an
#                           Authentik fault rather than a sealing mistake.
#     dashboard-password  — basic auth for the Hermes dashboard. ⚠ MANDATORY, not optional
#                           hardening: the dashboard's auth gate engages on any non-loopback
#                           bind and FAILS CLOSED, and HERMES_DASHBOARD_INSECURE is accepted
#                           but ignored. Without it the container does not start.
#     dashboard-username    Authentik in front is the primary gate; this also covers
#                           in-cluster callers.
#     litellm-key         — ⚠ A PLACEHOLDER ONLY, and it is meant to be overwritten. The
#                           real value is a per-agent VIRTUAL key minted at sync time by
#                           postsync-litellm-key.yaml, which patches it into this same
#                           Secret. It is sealed at all so the pod can start before the
#                           mint job has run (a missing key is a CreateContainerConfigError,
#                           not a 401). ⚠ Do NOT put the LiteLLM MASTER key here: this
#                           account is shared, root-capable, and keeps the key in cleartext
#                           on an NFS home two humans can read.
#
#   oidc-client-secret-sealed.yaml       — eda-pcb-agent-oidc-client-secret, key
#                           client-secret. Confidential-client secret for the Authentik
#                           OAuth2 provider gating the dashboard. Consumed by
#                           authentik-provider.yaml (to CREATE the provider) and by
#                           deployment.yaml (written into .env). Both sides must carry the
#                           SAME value or the token exchange 401s — which looks like an IdP
#                           fault, not a secret mismatch.
#
#   authentik-provisioner-token-sealed.yaml — authentik-provisioner-token, key token.
#                           The SCOPED provisioner token (view_user + add_group only) used
#                           by the provider/cleanup jobs. Same plaintext as the central
#                           AUTHENTIK_PROVISIONER_TOKEN — run authentik/sealSecrets.sh first
#                           so it can be recovered rather than pasted.
#
# ⚠ The rdp/authentik password is a real interactive login to a root-capable shared pod.
# Treat it like the LiteLLM master key.
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

# --- the shared account's password -------------------------------------------------
# ⚠ ONE value, sealed under TWO keys (rdp-password and authentik-password). It is the AD
# account's password: the blueprint sets it in Authentik, LDAP writes it back to the DC, and
# the xrdp greeter authenticates against that. Never derive the two keys separately.
#
# ⚠ A FIXED, HUMAN-MEMORABLE PASSWORD, SET ON REQUEST — AND IT IS WEAK.
# This account has root-capable sudo inside its container and holds a LiteLLM credential in
# cleartext on the shared homes export, so its password is a real privilege. A wordlist
# guesses this one; the value it replaced was 24 random bytes.
#
# It is set this way because both humans type it at the xrdp greeter, where a 49-character
# random string is unusable. That trade is the owner's to make — but do not widen it, and do
# not copy this pattern to another app. Rotate to a random value with `--regenerate` as soon
# as the greeter is no longer typed by hand.
#
# Override without editing this file:  EDA_PCB_AGENT_PASSWORD=... bash sealSecrets.sh
# ⚠ `--regenerate` deliberately IGNORES the default below and generates a random value — it
# is the escape hatch back to a strong password.
if [[ -n "$REGEN" ]]; then
  # Authentik's default password policy rejects a value with no letter, and a pure-hex
  # string can (rarely) be all digits. Prefix a fixed letter so the class is guaranteed.
  ACCOUNT_PASSWORD="P$(openssl rand -hex 24)"
else
  ACCOUNT_PASSWORD="${EDA_PCB_AGENT_PASSWORD:-Blahblah123!}"
fi

DASHBOARD_USERNAME=$(try_recover "$SCRIPT_DIR/eda-pcb-agent-secrets-sealed.yaml" dashboard-username)
[[ -z "$DASHBOARD_USERNAME" ]] && DASHBOARD_USERNAME="pcb-agent-admin"
DASHBOARD_PASSWORD=$(recover_or_generate "$SCRIPT_DIR/eda-pcb-agent-secrets-sealed.yaml" dashboard-password "$REGEN" 32)

# --- LiteLLM: a placeholder the mint job replaces ------------------------------------
# ⚠ Deliberately NOT the master key (see the header). Recovered rather than regenerated so
# a re-seal does not clobber the real virtual key the mint job wrote into this Secret.
LITELLM_KEY=$(try_recover "$SCRIPT_DIR/eda-pcb-agent-secrets-sealed.yaml" litellm-key)
[[ -z "$LITELLM_KEY" ]] && LITELLM_KEY="sk-placeholder-replaced-by-postsync-litellm-key-job"

seal_secret eda-pcb-agent eda-pcb-agent-secrets eda-pcb-agent-secrets-sealed.yaml \
  --from-literal=rdp-password="$ACCOUNT_PASSWORD" \
  --from-literal=authentik-password="$ACCOUNT_PASSWORD" \
  --from-literal=dashboard-username="$DASHBOARD_USERNAME" \
  --from-literal=dashboard-password="$DASHBOARD_PASSWORD" \
  --from-literal=litellm-key="$LITELLM_KEY"

# --- dashboard OIDC (Authentik) ------------------------------------------------------
OIDC_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret eda-pcb-agent eda-pcb-agent-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_SECRET"

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret eda-pcb-agent authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST command makes
# the script exit 1, so --skip-git-commit looks like a failure to the caller
# (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal eda-pcb-agent secrets" \
    "$SCRIPT_DIR/eda-pcb-agent-secrets-sealed.yaml" \
    "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" \
    "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml"
fi
