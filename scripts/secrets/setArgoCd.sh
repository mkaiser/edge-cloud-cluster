#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "Configuring ArgoCD secrets..."

read -s -p "Enter ArgoCD Admin Password (secret): " argocd_admin_password
echo

# Compute bcrypt hash and a stable mtime derived from the password.
# This uses Node + bcryptjs (package is in project package.json). If not available,
# instruct the user to run `npm install` or set the two values manually.
argocd_admin_password_hash=$(node -e "const b=require('bcryptjs'); const pw=process.argv[1]; console.log(b.hashSync(pw,10));" "$argocd_admin_password")
argocd_admin_password_mtime=$(node -e "const crypto=require('crypto'); const pw=process.argv[1]; const digest=crypto.createHash('sha256').update(pw).digest('hex'); const seed=parseInt(digest.slice(0,8),16); const base=1700000000; const ts=base + (seed % 31536000); console.log(new Date(ts*1000).toISOString());" "$argocd_admin_password")
if [[ -n "$argocd_admin_password_hash" && -n "$argocd_admin_password_mtime" ]]; then
    pulumi config set --secret argocdAdminPasswordPlain "$argocd_admin_password"
    pulumi config set --secret argocdAdminPasswordHash "$argocd_admin_password_hash"
    pulumi config set --secret argocdAdminPasswordMtime "$argocd_admin_password_mtime"
    echo "Set Pulumi config values: argocdAdminPasswordHash and argocdAdminPasswordMtime"
else
    echo "Failed to compute Argocd admin hash/mtime. Ensure bcryptjs is installed (run 'npm install')."
fi

echo ""
read -s -p "Enter ArgoCD Server secret key (secret): " argocd_server_secret_key
echo
pulumi config set --secret argocdServerSecretKey "$argocd_server_secret_key"
