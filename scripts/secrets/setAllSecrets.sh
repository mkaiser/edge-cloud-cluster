#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


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


echo ""
bash "$SCRIPT_DIR/setHcloudToken.sh"

echo ""
bash "$SCRIPT_DIR/setS3ObjectStorage.sh"

echo ""
bash "$SCRIPT_DIR/setGitHubDeployKey.sh"

echo ""
bash "$SCRIPT_DIR/setArgoCd.sh"

echo ""
bash "$SCRIPT_DIR/setSealedSecrets.sh"

echo ""
bash "$SCRIPT_DIR/setWireGuard.sh"


echo "Configuration complete!"
echo -e "\n"

display_pulumi_config
