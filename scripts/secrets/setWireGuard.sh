#!/usr/bin/env bash
# Stores WireGuard keypairs in the Pulumi stack.
#
# Usage:
#   bash setWireGuard.sh              — interactive: generate new or paste existing
#   bash setWireGuard.sh --regenerate — auto-generate new keypairs (no prompts)
#
# Requires wireguard-tools: apt install wireguard-tools  OR  brew install wireguard-tools
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGEN="${1:-}"

echo ""
echo "Configuring WireGuard Admin VPN..."

if [[ "$REGEN" == "--regenerate" ]]; then
  wg_server_private=$(wg genkey)
  wg_server_public=$(echo "$wg_server_private" | wg pubkey)
  wg_admin_private=$(wg genkey)
  wg_admin_public=$(echo "$wg_admin_private" | wg pubkey)
  echo "  Generated server public key: $wg_server_public"
  echo "  Generated admin  public key: $wg_admin_public"
else
  echo "WireGuard keys are generated with 'wg genkey' / 'wg pubkey'."
  read -rp "Generate NEW WireGuard keypairs [g] or paste EXISTING ones [e]? " wg_choice
  if [[ "$wg_choice" =~ ^[Gg] ]]; then
    wg_server_private=$(wg genkey)
    wg_server_public=$(echo "$wg_server_private" | wg pubkey)
    wg_admin_private=$(wg genkey)
    wg_admin_public=$(echo "$wg_admin_private" | wg pubkey)
    echo "  Generated server public key: $wg_server_public"
    echo "  Generated admin  public key: $wg_admin_public"
  else
    read -rp "Enter WireGuard server private key: " wg_server_private
    wg_server_public=$(echo "$wg_server_private" | wg pubkey)
    echo "  Server public key: $wg_server_public"
    read -rp "Enter WireGuard admin peer private key: " wg_admin_private
    wg_admin_public=$(echo "$wg_admin_private" | wg pubkey)
    echo "  Admin public key:  $wg_admin_public"
  fi
fi

(cd "$REPO_DIR" && pulumi config set --secret wgServerPrivateKey "$wg_server_private")
(cd "$REPO_DIR" && pulumi config set --secret wgServerPublicKey  "$wg_server_public")
(cd "$REPO_DIR" && pulumi config set --secret wgAdminPrivateKey  "$wg_admin_private")
(cd "$REPO_DIR" && pulumi config set --secret wgAdminPublicKey   "$wg_admin_public")

echo "  WireGuard keypairs stored in Pulumi config."
echo "  Save the private keys: pulumi config get wgServerPrivateKey / wgAdminPrivateKey"
