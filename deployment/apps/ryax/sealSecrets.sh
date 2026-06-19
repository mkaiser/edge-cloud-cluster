#!/bin/bash
# Seals Ryax admin credentials for deployment.
# Consumed by deployment/apps/ryax/values.yaml (authorization.extraEnv secretKeyRef).
# Idempotent: recovers existing password from the sealed file on re-runs.
#
# On re-runs you can keep [k] / enter new [e] / generate [g] the password.
# Pass --regenerate to skip the keep prompt and force enter/generate.
set -euo pipefail

NAMESPACE="ryaxns"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

seal_secret "$NAMESPACE" ryax-admin-credentials ryax-admin-credentials-sealed.yaml \
  --from-literal=username="$ADMIN_USERNAME" \
  --from-literal=password="$ADMIN_PASSWORD"

[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal ryax admin credentials" "$SEALED_FILE"
