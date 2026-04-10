#!/usr/bin/env bash
# Seals the Renovate GitHub PAT for the Renovate CronJob.
# The token needs 'repo' scope to read the private repo and open pull requests.
#
# Generates:
#   renovate-token-sealed.yaml  — GitHub PAT for Renovate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SCRIPT="$SCRIPT_DIR/../manageSealedSecrets.sh"
# shellcheck source=../manageSealedSecrets.sh
source "$MANAGE_SCRIPT"

namespace="renovate"
secret_name="renovate-token"
output_file="renovate/${secret_name}-sealed.yaml"

echo "Enter the GitHub Classic Access Token for Renovate."
echo "Required scope: repo (for private repository access and PR creation)"
echo ""

read -rsp "GitHub Classic Access Token: " github_access_token
echo ""
read -rsp "Confirm Token: " github_confirm
echo ""

if [ "$github_access_token" != "$github_confirm" ]; then
  echo "Tokens do not match. Aborting." >&2
  exit 1
fi

"$MANAGE_SCRIPT" "$namespace" "$secret_name" "$output_file" \
  --from-literal=token="$github_access_token"

ask_and_commit_sealed_files "Seal $namespace secrets" "${SCRIPT_DIR}/${secret_name}-sealed.yaml"
