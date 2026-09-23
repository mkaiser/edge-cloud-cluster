#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v rclone &>/dev/null; then
    echo "Installing rclone..."
    sudo apt-get install -y rclone
fi

if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    source "$SCRIPT_DIR/../pulumi/setPulumiPassphrase.sh"
fi

pulumi login "file://$(cd "$SCRIPT_DIR/../.." && pwd)/.pulumi-state" --non-interactive &>/dev/null
pulumi stack select mystack &>/dev/null

ACCESS_KEY=$(pulumi config get hetznerS3AccessKey)
SECRET_KEY=$(pulumi config get hetznerS3SecretKey)

rclone --s3-provider=Other \
       --s3-access-key-id="$ACCESS_KEY" \
       --s3-secret-access-key="$SECRET_KEY" \
       --s3-endpoint="https://nbg1.your-objectstorage.com" \
       ncdu :s3:
