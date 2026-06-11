#!/usr/bin/env bash
set -euo pipefail

echo "Paste your ArgoCD GitHub deploy key (with real newlines). Press Ctrl+D when done (secret):"
argocd_github_deploy_key=$(cat)
echo "$argocd_github_deploy_key" | pulumi config set --secret argocdGithubDeployKey
