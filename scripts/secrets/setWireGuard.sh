#!/usr/bin/env bash
set -euo pipefail

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
