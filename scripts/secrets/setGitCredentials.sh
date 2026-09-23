#!/usr/bin/env bash
# Stores the ArgoCD git deploy key in the Pulumi stack:
#   argocdGithubDeployKey  — SSH private key with read access (secret)
#
# The repo URL is NOT stored here — it is plain config in project_settings.ts
# (argocd.git.repoUrl), parsed by updateConfigFromProjectSettings.sh.
#
# The deploy key public key must be registered in the GitHub repo:
#   Repository → Settings → Deploy keys → Add deploy key (read-only is sufficient)
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

# --- Deploy key ---
echo "ArgoCD needs a \"deploy\" key to poll the git for changes. In Github: select git --> settings --> Deploy keys --> Add deploy key" 

if (cd "$REPO_DIR" && pulumi config get argocdGithubDeployKey &>/dev/null); then
    read -rp "  argocdGithubDeployKey — already set. Keep [k] or replace [r]? " choice
    [[ "$choice" =~ ^[Kk]$ ]] && { echo "  argocdGithubDeployKey — kept."; exit 0; }
fi

read -rp "  Generate [g] a new deploy key or enter [e] an existing one? " key_choice
if [[ "$key_choice" =~ ^[Gg]$ ]]; then
    generate_ssh_key_var DEPLOY_KEY "argocd-deploy-key"
    read -rp "  Display the generated private key? [y/N]: " show_key
    if [[ "$show_key" =~ ^[Yy]$ ]]; then
        echo ""
        printf '%s\n' "$DEPLOY_KEY"
        echo ""
    fi
    echo "  Register the public key above as a GitHub Deploy key"
    echo "  (select git --> settings --> Deploy keys --> Add deploy key), then press Enter."
    read -r _
else
    echo "ArgoCD needs a deploy key to poll the git for changes. Set in Github: select git --> settings --> Deploy keys --> Add deploy key"
    read_multiline_var DEPLOY_KEY "Paste ArgoCD deploy key now. SSH private key, passphrase-less, real newlines)"
fi

printf '%s\n' "$DEPLOY_KEY" | (cd "$REPO_DIR" && pulumi config set --secret argocdGithubDeployKey)
echo "  argocdGithubDeployKey — stored."
