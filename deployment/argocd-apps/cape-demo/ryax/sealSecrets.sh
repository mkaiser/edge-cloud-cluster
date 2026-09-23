#!/bin/bash
# Seals the Ryax secrets:
#   ryax-admin-credentials-sealed.yaml       — admin user, consumed by values.yaml
#                                              (authorization.extraEnv secretKeyRef)
#   ryax-user-credentials-sealed.yaml        — the project's Admin account, consumed by
#                                              postsync-ryax-user.yaml
#   authentik-provisioner-token-sealed.yaml  — scoped Authentik API token, consumed
#                                              by authentik-provider.yaml
# Idempotent: recovers existing values from the sealed files on re-runs.
#
# On re-runs you can keep [k] / enter new [e] / generate [g] the password.
# Pass --regenerate to skip the keep prompt and force enter/generate.
set -euo pipefail

NAMESPACE="ryaxns"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEALED_FILE="$SCRIPT_DIR/ryax-admin-credentials-sealed.yaml"

source "$REPO_DIR/manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

ADMIN_USERNAME="${RYAX_ADMIN_USER:-admin}"

EXISTING_PASS=""
if [[ "$REGEN" != "--regenerate" ]]; then
  EXISTING_PASS=$(try_recover "$SEALED_FILE" password)
fi

ADMIN_PASSWORD=""; _need_enter="false"
if [[ -n "$EXISTING_PASS" ]]; then
  prompt_keg "ryax-admin-password" "true" "true"
  case "$KEG_CHOICE" in
    keep)     ADMIN_PASSWORD="$EXISTING_PASS"; echo "  ryax-admin-password — kept." ;;
    generate) ADMIN_PASSWORD=$(openssl rand -hex 16); echo "  Generated new ryax admin password." ;;
    enter)    _need_enter="true" ;;
  esac
else
  prompt_keg "ryax-admin-password" "false" "true"
  if [[ "$KEG_CHOICE" == "generate" ]]; then
    ADMIN_PASSWORD=$(openssl rand -hex 16); echo "  Generated new ryax admin password."
  else
    _need_enter="true"
  fi
fi

if [[ "$_need_enter" == "true" ]]; then
  while true; do
    read -rsp "  Ryax admin password: " ADMIN_PASSWORD; echo
    read -rsp "  Confirm password: " confirm; echo
    [[ "$ADMIN_PASSWORD" == "$confirm" ]] && [[ -n "$ADMIN_PASSWORD" ]] && break
    echo "  Passwords do not match or empty — try again."
  done
fi

echo "Sealing Ryax admin credentials (username: $ADMIN_USERNAME)..."

SEALED_FILES=()

seal_secret "$NAMESPACE" ryax-admin-credentials ryax-admin-credentials-sealed.yaml \
  --from-literal=username="$ADMIN_USERNAME" \
  --from-literal=password="$ADMIN_PASSWORD"
SEALED_FILES+=("ryax-admin-credentials-sealed.yaml")

# The project's Admin account. RYAX_DEFAULT_USER_* seeds only the default admin, and only
# on FIRST BOOT, so every other account has to be provisioned against the running API —
# postsync-ryax-user.yaml does that from this secret. Non-interactive by default (keeps
# the recovered value) so a recreate never blocks on a prompt.
#
# The email is sealed alongside the credentials rather than built as "<user>@<domain>" in the
# Job: keeping it out of the manifest is what stops a real address being published with it.
# It defaults off mail.senderEmail's domain, which project_settings.ts already owns.
RYAX_CREDENTIAL_USERNAME="${RYAX_CREDENTIAL_USER:-ryaxuser}"
RYAX_CREDENTIAL_PASSWORD="${RYAX_CREDENTIAL_PASS:-}"
if [[ -z "$RYAX_CREDENTIAL_PASSWORD" ]]; then
  RYAX_CREDENTIAL_PASSWORD=$(try_recover "$SCRIPT_DIR/ryax-user-credentials-sealed.yaml" password)
fi
if [[ -z "$RYAX_CREDENTIAL_PASSWORD" ]]; then
  while true; do
    read -rsp "  Ryax '$RYAX_CREDENTIAL_USERNAME' password: " RYAX_CREDENTIAL_PASSWORD; echo
    read -rsp "  Confirm password: " confirm; echo
    [[ "$RYAX_CREDENTIAL_PASSWORD" == "$confirm" ]] && [[ -n "$RYAX_CREDENTIAL_PASSWORD" ]] && break
    echo "  Passwords do not match or empty — try again."
  done
fi

RYAX_CREDENTIAL_EMAILADDR="${RYAX_CREDENTIAL_EMAIL:-}"
if [[ -z "$RYAX_CREDENTIAL_EMAILADDR" ]]; then
  RYAX_CREDENTIAL_EMAILADDR=$(try_recover "$SCRIPT_DIR/ryax-user-credentials-sealed.yaml" email)
fi
if [[ -z "$RYAX_CREDENTIAL_EMAILADDR" ]]; then
  # mail.senderEmail is the one address project_settings.ts owns; take its domain so the
  # default follows a recreate instead of pinning a literal here.
  _mail_domain=$(grep -oE 'senderEmail:[[:space:]]*"[^"]+"' "$REPO_DIR/../project_settings.ts" \
    | head -n1 | sed -E 's/.*@([^"]+)"/\1/')
  [[ -n "$_mail_domain" ]] || { echo "ERROR: could not read mail.senderEmail from project_settings.ts" >&2; exit 1; }
  RYAX_CREDENTIAL_EMAILADDR="${RYAX_CREDENTIAL_USERNAME}@${_mail_domain}"
  echo "  Ryax user email defaulted to $RYAX_CREDENTIAL_EMAILADDR (override: RYAX_CREDENTIAL_EMAIL)"
fi

seal_secret "$NAMESPACE" ryax-user-credentials ryax-user-credentials-sealed.yaml \
  --from-literal=username="$RYAX_CREDENTIAL_USERNAME" \
  --from-literal=password="$RYAX_CREDENTIAL_PASSWORD" \
  --from-literal=email="$RYAX_CREDENTIAL_EMAILADDR"
SEALED_FILES+=("ryax-user-credentials-sealed.yaml")

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
# Consumed by authentik-provider.yaml to create the ryax group + access-ryax policy
# + portal tile. NOT the superuser bootstrap token.
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
[[ -z "$PROV_TOKEN" ]] && { read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo; }
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret "$NAMESPACE" authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"
SEALED_FILES+=("authentik-provisioner-token-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal ryax secrets" "${ABS_FILES[@]}"
fi
