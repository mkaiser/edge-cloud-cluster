#!/usr/bin/env bash
set -euo pipefail

# Stores all Hetzner credentials (project_settings.hetzner):
#   hcloudToken            — Hetzner Cloud API token (always required)
#   hetznerRobotUser/Pass  — Hetzner Robot webservice creds (optional; only needed
#                            for dedicated provider:"robot" nodes)
#   dedicatedSshPrivateKey — SSH private key trusted by the dedicated server (optional)

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$THIS_DIR/inputHelpers.sh"

# --- Hetzner Cloud API token (always required) ---
read_secret_var HCLOUD_TOKEN "Enter your Hetzner Cloud API token (hcloudToken)"
printf '%s' "$HCLOUD_TOKEN" | pulumi config set --secret hcloudToken
echo "  hcloudToken — stored."

# --- Hetzner Robot webservice credentials (optional; dedicated servers) ---
read -rp "Configure Hetzner Robot credentials for dedicated servers? [y/N]: " CONFIGURE_ROBOT
if [[ "${CONFIGURE_ROBOT,,}" == "y" || "${CONFIGURE_ROBOT,,}" == "yes" ]]; then
    echo "Note: You can create robot credentials at robot.hetzner.com --> Settings -->  Webservice and app settings --> Add a webservce user "
    echo ""
    read_line_var ROBOT_USER "Hetzner Robot webservice user (e.g. #ws+XXXXX)"
    read_secret_var ROBOT_PASS "Hetzner Robot webservice password"
    printf '%s' "$ROBOT_USER" | pulumi config set --secret hetznerRobotUser
    printf '%s' "$ROBOT_PASS" | pulumi config set --secret hetznerRobotPass
    echo "  hetznerRobotUser / hetznerRobotPass — stored."
else
    echo "  Skipping Hetzner Robot credentials (set later by re-running this script)."
fi
