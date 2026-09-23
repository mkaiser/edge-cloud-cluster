#!/bin/bash
# Export ONE admin's WireGuard client config to tmp/wg-<admin>.conf, for use on a machine
# that is not this devcontainer (wgAdminUp.sh brings the tunnel up here directly).
#
# ⚠ Each admin has its OWN keypair and OWN /32 — never hand the same config to two people.
# WireGuard tracks a single endpoint per peer, so two clients on one key steal the endpoint
# from each other and the server misroutes both sides' replies.
#
# Usage: WG_ADMIN=admin2 bash scripts/runtime/getAdminWireguardConfig.sh   (default admin1)

set -e

WG_ADMIN="${WG_ADMIN:-admin1}"
mkdir -p tmp
pulumi stack output wireguardClientConfigs --show-secrets \
    | jq -er --arg a "$WG_ADMIN" '.[$a]' > "tmp/wg-${WG_ADMIN}.conf"

echo "WireGuard client configuration for '$WG_ADMIN' saved to tmp/wg-${WG_ADMIN}.conf"
