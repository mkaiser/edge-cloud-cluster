#!/usr/bin/env bash
# Stores SSH private keys for compute nodes (cloud VMs, dedicated servers, mesh nodes)
# in the Pulumi stack. The key name must match the `ssh.key` field in
# project_settings.nodes.cloud / nodes.mesh.
#
# Keys must be PASSPHRASE-LESS: Pulumi's remote.Command can't prompt for a passphrase
# and does not use the local ssh-agent. (A KeePassXC-loaded key works for `ssh` CLI,
# but Pulumi needs the key material stored here.)
#
# For cloud/dedicated nodes: key name = Hetzner-registered key name (e.g.
#   sshkey_ed25519_pxCloudEdgeInfra_Martin). Also register the public key in
#   Hetzner Cloud (Project → Security → SSH Keys) or Robot.
# For mesh nodes: key name is the Pulumi config key set in each node's ssh.key field
#   (e.g. meshSshPrivateKey).
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

read -rp "Configure SSH key credentials for compute nodes (cloud, dedicated and mesh)? [y/N]: " want_keys
[[ "$want_keys" =~ ^[Yy]$ ]] || { echo "  SSH keys — skipped."; exit 0; }

while true; do
    echo ""
    echo "  Enter the key name matching the 'ssh.key' field in project_settings nodes."
    echo "  Examples: sshkey-ecc-cloud  |  sshkey-ecc-dedicated  |  sshkey-ecc-mesh"
    read_line_var KEY_NAME "  Key name"

    # If already set, give the user a chance to keep the existing value.
    if (cd "$REPO_DIR" && pulumi config get "$KEY_NAME" &>/dev/null); then
        read -rp "  '$KEY_NAME' — already set. Keep [k] or replace [r]? " keep_or_replace
        if [[ "$keep_or_replace" =~ ^[Kk]$ ]]; then
            echo "  '$KEY_NAME' — kept."
            read -rp "  Add another SSH key? [a/N]: " more
            [[ "$more" =~ ^[Aa]$ ]] || break
            continue
        fi
    fi

    # Enter existing key or generate a new pair.
    read -rp "  Enter existing private key [e] or generate new ed25519 key pair [g]? " key_action

    if [[ "$key_action" =~ ^[Gg]$ ]]; then
        echo "  Register the public key below in Hetzner Cloud → Security → SSH Keys"
        echo "  or Hetzner Robot, under the name '$KEY_NAME'."
        generate_ssh_key_var PRIVATE_KEY "$KEY_NAME"
        read -rp "  Display the generated private key? [y/N]: " show_key
        if [[ "$show_key" =~ ^[Yy]$ ]]; then
            echo ""
            printf '%s\n' "$PRIVATE_KEY"
            echo ""
        fi
        printf '%s\n' "$PRIVATE_KEY" | (cd "$REPO_DIR" && pulumi config set --secret "$KEY_NAME")
        echo "  '$KEY_NAME' — private key stored."
    else
        read_multiline_var PRIVATE_KEY "  Paste the SSH private key for '$KEY_NAME' (passphrase-less, real newlines)"
        printf '%s\n' "$PRIVATE_KEY" | (cd "$REPO_DIR" && pulumi config set --secret "$KEY_NAME")
        echo "  '$KEY_NAME' — stored."
    fi

    read -rp "  Add another SSH key? [y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
done

echo "  SSH keys — done."
