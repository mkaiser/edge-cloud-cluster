#!/bin/bash
# Tear down the admin WireGuard tunnel brought up by wgAdminUp.sh.
# Usage: bash scripts/runtime/wgAdminDown.sh
set -euo pipefail

IFACE="wgadmin"
CONF="/etc/wireguard/${IFACE}.conf"

if ip link show "$IFACE" >/dev/null 2>&1; then
    sudo WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick down "$CONF" 2>/dev/null \
        || sudo WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick down "$IFACE"
    echo "wgadmin tunnel is down."
else
    echo "wgadmin is not up — nothing to do."
fi
