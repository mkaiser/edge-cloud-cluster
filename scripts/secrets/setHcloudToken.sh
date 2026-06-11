#!/usr/bin/env bash
set -euo pipefail

echo "Enter your hcloud token (secret):"
pulumi config set --secret hcloudToken
