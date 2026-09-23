#!/usr/bin/env bash
# Stores the GitHub Personal Access Token in the Pulumi stack:
#   githubPatToken  — GitHub Classic PAT with 'repo' scope (secret)
#
# Used by Renovate (deployment/argocd-infra/renovate/sealSecrets.sh) to read
# the private repository and open pull requests. The deployment seals it from
# the Pulumi stack — no manual entry at seal time.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

echo ""
echo "Configuring GitHub PAT (githubPatToken)..."
echo "Required: GitHub Classic Personal Access Token with 'repo' scope"
echo "  (private repository access + pull request creation)."

if (cd "$REPO_DIR" && pulumi config get githubPatToken &>/dev/null); then
    read -rp "  githubPatToken — already set. Keep [k] or replace [r]? " choice
    [[ "$choice" =~ ^[Kk]$ ]] && { echo "  githubPatToken — kept."; exit 0; }
fi

read_secret_var GITHUB_PAT "  GitHub Classic Personal Access Token"

printf '%s' "$GITHUB_PAT" | (cd "$REPO_DIR" && pulumi config set --secret githubPatToken)
echo "  githubPatToken — stored."
