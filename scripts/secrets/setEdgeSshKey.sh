#!/usr/bin/env bash
# Stores the SSH private key trusted by on-premise edge hosts (e.g. cape@…) in the
# Pulumi stack as `edgeSshPrivateKey`. Consumed by `make provision-edge`
# (src/nodes-k3s-on-premise.ts → command.remote.Command).
#
# OPTIONAL — only needed if you provision on-premise edge nodes (project_settings
# nodes.edge). The key must be PASSPHRASE-LESS: Pulumi's remote.Command can't prompt
# for a passphrase and does not use your local ssh-agent / KeePassXC agent. (A
# KeePassXC-loaded key works for the `ssh` CLI, but Pulumi needs the key material
# stored here.) Idempotent: skips if already set.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

if (cd "$REPO_DIR" && pulumi config get edgeSshPrivateKey &>/dev/null); then
  read -rp "  edgeSshPrivateKey — already set. Keep [k] or replace [r]? " choice
  [[ "$choice" =~ ^[Kk]$ ]] && exit 0
fi

read -rp "  Set edge SSH key now? (only for on-premise edge nodes) [y/N]: " want
[[ "$want" =~ ^[Yy]$ ]] || { echo "  edgeSshPrivateKey — skipped."; exit 0; }

read_multiline_var EDGE_KEY "Paste the edge SSH private key (passphrase-less, real newlines)"
printf '%s\n' "$EDGE_KEY" | (cd "$REPO_DIR" && pulumi config set --secret edgeSshPrivateKey)
echo "  edgeSshPrivateKey — stored."
