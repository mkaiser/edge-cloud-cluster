#!/bin/bash
# sshAgentHelpers.sh — load node SSH private keys from the Pulumi config into the ssh-agent.
#
# Source this (don't execute it) AFTER the Pulumi stack is selected — the function reads
# `pulumi config`. The local provisioning Commands (k3s join/wait in src/nodes-k3s-*.ts,
# mesh provisioning in src/nodes-k3s-mesh.ts) call `ssh` without `-i` and rely on the
# agent. The node keys (sshkey-ecc-*, meshSshPrivateKey, dedicatedSshPrivateKey) live only in
# the Pulumi config, so without this step every provisioning SSH fails with "Permission
# denied" and the run hangs in the wait loops.
#
# Needed by every command that triggers SSH provisioning: create, restore, up, provision-mesh-node.
# Idempotent: re-adding a key is a no-op.

# Derived public keys are written here, one file per Pulumi config key name
# (e.g. tmp/ssh-public-keys/sshkey-ecc-mesh.pub). Private keys stay in the agent
# only. These pubkeys let ssh configs pin a single agent identity via
# `IdentityFile <pub> + IdentitiesOnly yes` — needed when the agent holds more
# keys than sshd's MaxAuthTries (default 6), which otherwise disconnects with
# "Too many authentication failures" before the right key is offered.
SSH_PUBLIC_KEY_DIR="${SSH_PUBLIC_KEY_DIR:-tmp/ssh-public-keys}"

ensure_node_ssh_keys_in_agent() {
    if ! ssh-add -l >/dev/null 2>&1; then
        eval "$(ssh-agent -s)" >/dev/null || { echo "  ssh-agent unavailable — skipping key load"; return 0; }
    fi
    mkdir -p "$SSH_PUBLIC_KEY_DIR"
    local key
    for key in $(pulumi config 2>/dev/null | awk '/^(sshkey-|meshSshPrivateKey|dedicatedSshPrivateKey)/{print $1}'); do
        local val
        val="$(pulumi config get "$key" 2>/dev/null || true)"
        if printf '%s' "$val" | grep -q 'BEGIN .*PRIVATE KEY'; then
            if printf '%s\n' "$val" | ssh-add - 2>/dev/null; then
                echo "  ssh-agent: loaded node key '$key'"
            else
                echo "  ssh-agent: WARNING could not load '$key' (passphrase-protected or malformed)"
            fi
            # Derive the public key from the private key (no private material on disk)
            # and store it by Pulumi config key name for IdentitiesOnly ssh configs.
            local pub
            if pub="$(printf '%s\n' "$val" | ssh-keygen -y -f /dev/stdin 2>/dev/null)"; then
                # ssh-keygen -y prints "<type> <blob> [comment]"; keep type+blob only
                # and stamp the Pulumi config key name as the comment.
                printf '%s %s %s\n' "$(printf '%s' "$pub" | cut -d' ' -f1)" \
                    "$(printf '%s' "$pub" | cut -d' ' -f2)" "$key" > "$SSH_PUBLIC_KEY_DIR/$key.pub"
            else
                echo "  ssh-agent: WARNING could not derive public key for '$key'"
            fi
        fi
    done
}
