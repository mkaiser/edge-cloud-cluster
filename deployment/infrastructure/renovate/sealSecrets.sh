#!/usr/bin/env bash
# Seals the Renovate GitHub PAT for the Renovate CronJob.
# The token needs 'repo' scope to read the private repo and open pull requests.
# Idempotent: recovers existing token from sealed file on re-runs.
# Pass --regenerate to force re-entry.
#
# Generates:
#   renovate-token-sealed.yaml  — GitHub PAT for Renovate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

namespace="renovate"
secret_name="renovate-token"
sealed_file="$SCRIPT_DIR/${secret_name}-sealed.yaml"

existing=""
if [[ "$REGEN" != "--regenerate" ]]; then
  existing=$(try_recover "$sealed_file" token)
fi

TOKEN=""
if [[ -n "$existing" ]]; then
  prompt_keg "renovate-token" "true" "false"
  if [[ "$KEG_CHOICE" == "keep" ]]; then
    TOKEN="$existing"
  fi
fi

if [[ -z "$TOKEN" ]]; then
  echo "Enter the GitHub Classic Access Token for Renovate."
  echo "Required scope: repo (for private repository access and PR creation)"
  echo ""
  while true; do
    read -rsp "  GitHub Classic Access Token: " TOKEN; echo
    read -rsp "  Confirm Token: " confirm; echo
    [[ "$TOKEN" == "$confirm" ]] && [[ -n "$TOKEN" ]] && break
    echo "  Tokens do not match or empty — try again."
  done
fi

seal_secret "$namespace" "$secret_name" "${secret_name}-sealed.yaml" \
  --from-literal=token="$TOKEN"

[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $namespace secrets" "$sealed_file"
