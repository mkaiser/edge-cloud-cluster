#!/usr/bin/env bash
# Stores the ArgoCD GitHub deploy key in the Pulumi stack.
# Idempotent: skips if the key is already set.
#
# Generate a deploy key pair (run once, add public key to the GitHub repo):
#   ssh-keygen -t ed25519 -C "argocd-deploy" -f argocd_deploy_key
#   cat argocd_deploy_key.pub   # → GitHub repo > Settings > Deploy keys
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

if (cd "$REPO_DIR" && pulumi config get argocdGithubDeployKey &>/dev/null); then
  read -rp "  argocdGithubDeployKey — already set. Keep [k] or replace [r]? " choice
  [[ "$choice" =~ ^[Kk]$ ]] && exit 0
fi

read_multiline_var DEPLOY_KEY "Paste ArgoCD GitHub deploy key (SSH private key, real newlines)"
printf '%s\n' "$DEPLOY_KEY" | (cd "$REPO_DIR" && pulumi config set --secret argocdGithubDeployKey)
echo "  argocdGithubDeployKey — stored."
