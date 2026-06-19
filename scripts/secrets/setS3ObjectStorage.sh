#!/usr/bin/env bash
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$THIS_DIR/inputHelpers.sh"

echo "Configuring Hetzner S3 Object Storage..."
echo "  Endpoint and bucket names are set in project_settings.ts (s3.baseEndpoint)."

read_secret_var S3_ACCESS_KEY "Enter Hetzner S3 Access Key (secret)"
printf '%s' "$S3_ACCESS_KEY" | pulumi config set --secret hetznerS3AccessKey
echo "  hetznerS3AccessKey — stored."

read_secret_var S3_SECRET_KEY "Enter Hetzner S3 Secret Key (secret)"
printf '%s' "$S3_SECRET_KEY" | pulumi config set --secret hetznerS3SecretKey
echo "  hetznerS3SecretKey — stored."
