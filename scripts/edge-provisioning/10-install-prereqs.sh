#!/bin/bash
# 10-install-prereqs.sh — Install Longhorn storage prerequisites on an edge node.
#
# SHARED edge-join logic — single source of truth, consumed by BOTH:
#   - scripts/runtime/generateEdgeJoinScript.sh (manual provisioning)
#   - src/nodes-k3s-on-premise.ts (Pulumi command.remote.Command)
# No placeholders in this step.
#
# Run as root or with sudo.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

echo "=== Installing Longhorn prerequisites ==="
apt-get update -qq
apt-get install -y open-iscsi nfs-common cryptsetup dmsetup || true
systemctl enable iscsid --now
modprobe iscsi_tcp 2>/dev/null || true
echo "iscsi_tcp" > /etc/modules-load.d/iscsi.conf
echo "Longhorn prerequisites installed. iscsid: $(systemctl is-active iscsid)"
