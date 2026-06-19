#!/usr/bin/env bash
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$THIS_DIR/inputHelpers.sh"

read_secret_var HCLOUD_TOKEN "Enter your hcloud token (secret)"
printf '%s' "$HCLOUD_TOKEN" | pulumi config set --secret hcloudToken
echo "  hcloudToken — stored."
