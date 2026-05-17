#!/bin/bash
set -euo pipefail


function display_pulumi_config() {
    echo -e "\ncurrent pulumi config:"
    pulumi config
    echo -e "\n"
}

display_pulumi_config


read -p "Do you want to clear all existing pulumi config values? [y/N]: " clear_config
if [[ "$clear_config" =~ ^[Yy]$ ]]; then
    echo "Clearing pulumi config..."

    pulumi config --stack mystack --json \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).keys()))' \
  | while read -r k; do pulumi config rm --stack mystack "$k"; done

    echo "Pulumi config cleared."
else
    echo "Keeping existing pulumi config."
fi


echo "Enter your hcloud token (secret):"
pulumi config set --secret hcloudToken


echo ""
echo "Configuring Hetzner S3 Object Storage..."
echo "  Endpoint and bucket names are set in project_settings.ts (s3.baseEndpoint)."

echo "Enter Hetzner S3 Access Key (secret):"
pulumi config set --secret hetznerS3AccessKey

echo "Enter Hetzner S3 Secret Key (secret):"
pulumi config set --secret hetznerS3SecretKey


echo ""
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


echo ""
echo "Paste your ArgoCD GitHub deploy key (with real newlines). Press Ctrl+D when done (secret):"
argocd_github_deploy_key=$(cat)
echo "$argocd_github_deploy_key" | pulumi config set --secret argocdGithubDeployKey


echo ""
echo "Configuring Sealed Secrets encryption key..."
echo "The sealed-secrets controller uses a TLS keypair to encrypt/decrypt SealedSecrets."
read -p "Generate a NEW keypair (first deploy) [n,N] or enter an EXISTING one? [eE]: " sealed_secrets_choice
if [[ "$sealed_secrets_choice" =~ ^[Ee] ]]; then
    echo "Paste the TLS certificate. Press Enter and then Ctrl+D when done:"
    sealed_secrets_crt=$(cat)
    echo "$sealed_secrets_crt" | pulumi config set --secret sealedSecretsTlsCrt
    echo ""
    echo "Paste the TLS private key. Press Enter and then Ctrl+D when done:"
    sealed_secrets_key=$(cat)
    echo "$sealed_secrets_key" | pulumi config set --secret sealedSecretsTlsKey
    echo "Sealed Secrets keypair stored in Pulumi config."
elif [[ "$sealed_secrets_choice" =~ ^[Nn] ]]; then
    echo "Generating new sealed-secrets TLS keypair..."
    openssl req -x509 -nodes -newkey rsa:4096 -keyout /tmp/sealed-secrets.key \
        -out /tmp/sealed-secrets.crt -subj "/CN=sealed-secret/O=sealed-secrets" -days 13650
    cat /tmp/sealed-secrets.crt | pulumi config set --secret sealedSecretsTlsCrt
    cat /tmp/sealed-secrets.key | pulumi config set --secret sealedSecretsTlsKey
    rm -f /tmp/sealed-secrets.key /tmp/sealed-secrets.crt
    echo "New sealed-secrets keypair generated and stored in Pulumi config."
fi


echo ""
echo "Configuring WireGuard Admin VPN..."
echo "WireGuard keys are generated with 'wg genkey' / 'wg pubkey'."
echo "Requires wireguard-tools: apt install wireguard-tools  OR  brew install wireguard-tools"
echo ""

read -p "Generate NEW WireGuard keypairs (first deploy) [g] or enter EXISTING ones [e]? " wg_choice
if [[ "$wg_choice" =~ ^[Gg] ]]; then
    wg_server_private=$(wg genkey)
    wg_server_public=$(echo "$wg_server_private" | wg pubkey)
    wg_admin_private=$(wg genkey)
    wg_admin_public=$(echo "$wg_admin_private" | wg pubkey)
    echo "Generated server public key:  $wg_server_public"
    echo "Generated admin  public key:  $wg_admin_public"
else
    read -p "Enter WireGuard server private key: " wg_server_private
    wg_server_public=$(echo "$wg_server_private" | wg pubkey)
    echo "Server public key: $wg_server_public"
    read -p "Enter WireGuard admin peer private key: " wg_admin_private
    wg_admin_public=$(echo "$wg_admin_private" | wg pubkey)
    echo "Admin public key:  $wg_admin_public"
fi

pulumi config set --secret wgServerPrivateKey "$wg_server_private"
pulumi config set         wgServerPublicKey  "$wg_server_public"
pulumi config set --secret wgAdminPrivateKey  "$wg_admin_private"
pulumi config set         wgAdminPublicKey   "$wg_admin_public"

echo "WireGuard keypairs stored in Pulumi config. Save the private keys NOW using 'pulumi config get wgServerPrivateKey' and 'pulumi config get wgAdminPrivateKey'"


echo "Configuration complete!"
echo -e "\n"

display_pulumi_config
