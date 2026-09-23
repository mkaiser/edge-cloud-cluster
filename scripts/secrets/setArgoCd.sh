#!/usr/bin/env bash
# Stores ArgoCD admin password and server secret key in the Pulumi stack.
#
# Usage:
#   bash setArgoCd.sh              — interactive prompts
#   bash setArgoCd.sh --regenerate — auto-generate both values (prints new password)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGEN="${1:-}"

echo ""
echo "Configuring ArgoCD secrets..."

if [[ "$REGEN" == "--regenerate" ]]; then
  argocd_admin_password=$(openssl rand -base64 16 | tr -d '=+/')
  argocd_server_secret_key=$(openssl rand -hex 32)
  echo "  Generated ArgoCD admin password: $argocd_admin_password"
  echo "  Generated ArgoCD server secret key."
else
  read -rp "Generate ArgoCD admin password for user \"admin\" [g] or enter manually [e]? " pw_choice
  if [[ "$pw_choice" =~ ^[Gg] ]]; then
    argocd_admin_password=$(openssl rand -base64 16 | tr -d '=+/')
    echo "  Generated ArgoCD admin password: $argocd_admin_password"
  else
    read -rsp "Enter ArgoCD Admin Password: " argocd_admin_password
    echo
  fi

  read -rp "Generate ArgoCD server secret key [g] or enter manually [e]? " sk_choice
  if [[ "$sk_choice" =~ ^[Gg] ]]; then
    argocd_server_secret_key=$(openssl rand -hex 32)
    echo "  Generated ArgoCD server secret key."
  else
    read -rsp "Enter ArgoCD Server secret key: " argocd_server_secret_key
    echo
  fi
fi

argocd_admin_password_hash=$(node -e "const b=require('bcryptjs'); const pw=process.argv[1]; console.log(b.hashSync(pw,10));" "$argocd_admin_password")
argocd_admin_password_mtime=$(node -e "const crypto=require('crypto'); const pw=process.argv[1]; const digest=crypto.createHash('sha256').update(pw).digest('hex'); const seed=parseInt(digest.slice(0,8),16); const base=1700000000; const ts=base + (seed % 31536000); console.log(new Date(ts*1000).toISOString());" "$argocd_admin_password")

if [[ -n "$argocd_admin_password_hash" && -n "$argocd_admin_password_mtime" ]]; then
  (cd "$REPO_DIR" && pulumi config set --secret argocdAdminPasswordPlain "$argocd_admin_password")
  (cd "$REPO_DIR" && pulumi config set --secret argocdAdminPasswordHash  "$argocd_admin_password_hash")
  (cd "$REPO_DIR" && pulumi config set --secret argocdAdminPasswordMtime "$argocd_admin_password_mtime")
  (cd "$REPO_DIR" && pulumi config set --secret argocdServerSecretKey    "$argocd_server_secret_key")
  echo "  ArgoCD secrets stored in Pulumi config."
else
  echo "ERROR: Failed to compute ArgoCD admin hash/mtime. Run 'npm install' first." >&2
  exit 1
fi
