#!/bin/bash
# _local-cleanup-node-over-ssh.sh — run 00-cleanup-node.sh on a remote mesh node over SSH.
#
# Convenience wrapper around 00-cleanup-node.sh: pipes the local script to the remote
# host and executes it with sudo, so you don't have to copy it there by hand.
# Use after a cluster was destroyed to clean stale tailscale/k3s state off an
# mesh box before re-provisioning (see 00-cleanup-node.sh header for why).
#
# Usage:
#   bash _local-cleanup-node-over-ssh.sh <sshHost> [sshPort] [sshUser]
# Defaults: sshPort=22, sshUser=root
# Example:
#   bash _local-cleanup-node-over-ssh.sh pcie6-desktop-lab.example.edu 22 admin
set -euo pipefail
trap 'echo "ERROR: _local-cleanup-node-over-ssh.sh failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_HOST="${1:?Usage: _local-cleanup-node-over-ssh.sh <sshHost> [sshPort] [sshUser]}"
SSH_PORT="${2:-22}"
SSH_USER="${3:-root}"

LOCAL_SCRIPT="$SCRIPT_DIR/00-cleanup-node.sh"
[ -f "$LOCAL_SCRIPT" ] || { echo "ERROR: $LOCAL_SCRIPT not found." >&2; exit 1; }

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Cleaning mesh node ${SSH_USER}@${SSH_HOST}:${SSH_PORT} ==="

# Pipe the script to the remote host and run it via sudo bash. 00-cleanup-node.sh
# also self-sudos, but we force it here so a non-root sshUser works too.
# shellcheck disable=SC2086
ssh $SSH_OPTS -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" 'sudo bash -s' < "$LOCAL_SCRIPT"

echo ""
echo "Remote cleanup complete. Re-provision with: make provision-mesh-node ARGS=<node-id>"
