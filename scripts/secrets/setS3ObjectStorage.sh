#!/usr/bin/env bash
set -euo pipefail

echo "Configuring Hetzner S3 Object Storage..."
echo "  Endpoint and bucket names are set in project_settings.ts (s3.baseEndpoint)."

echo "Enter Hetzner S3 Access Key (secret):"
pulumi config set --secret hetznerS3AccessKey

echo "Enter Hetzner S3 Secret Key (secret):"
pulumi config set --secret hetznerS3SecretKey
