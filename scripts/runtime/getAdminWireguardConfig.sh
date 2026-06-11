#bin/bash

set -e

mkdir -p tmp 
pulumi stack output wireguardClientConfig --show-secrets > tmp/wg-admin.conf

echo "WireGuard client configuration has been saved to tmp/wg-admin.conf"