#!/bin/bash
# sshConnectNode.sh — open an interactive (or one-shot) SSH session to an on-premise mesh node.
#
# WHY: mesh nodes are reached as their configured ssh.endpoint/port/user with a private key
# held in the Pulumi config (NOT root@public-ip). That key is loaded into the ssh-agent by
# sshAgentHelpers.sh — but the agent usually holds several keys, and a plain
# `ssh -l <user> <endpoint>` offers them ALL. The mesh sshd's MaxAuthTries (default 6) then
# disconnects with "Too many authentication failures" before the right key is tried.
#
# This helper pins the ONE correct agent key by its PUBLIC key: sshAgentHelpers.sh writes each
# loaded key's public half to tmp/ssh-public-keys/<key>.pub, and we connect with
# `ssh -o IdentitiesOnly=yes -i <pub>` so only the matching agent identity is offered. The
# PRIVATE key never touches disk — only the harmless public key does.
#
# Usage:
#   bash scripts/runtime/sshConnectNode.sh <node-id> [-- <remote command...>]
# Examples:
#   bash scripts/runtime/sshConnectNode.sh unibi-hclab-vm0                 # interactive shell
#   bash scripts/runtime/sshConnectNode.sh unibi-hclab-vm0 -- id -un       # run a command
#
# Requires the Pulumi stack (to load the key + derive the pubkey). If PULUMI_CONFIG_PASSPHRASE
# is unset it is read from /tmp/passphrase, else prompted. Reads node identity (endpoint, key,
# port, user) from project_settings.nodes.mesh — same one-pass perl parse as cleanupMeshNodes.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PUBKEY_DIR="$REPO_ROOT/tmp/ssh-public-keys"

# ── Args ─────────────────────────────────────────────────────────────────────
NODE_ID="${1:-}"
if [[ -z "$NODE_ID" ]]; then
    echo "usage: $0 <node-id> [-- <remote command...>]" >&2
    exit 2
fi
shift || true
# Everything after an optional "--" is the remote command; passed through verbatim.
REMOTE_CMD=()
if [[ "${1:-}" == "--" ]]; then
    shift
    REMOTE_CMD=("$@")
fi

# ── Resolve node from project_settings.ts ────────────────────────────────────
# Depth-aware per-node parse (same as cleanupMeshNodes.sh): strip //-comments, then split the
# mesh array into top-level { ... } objects with a brace counter (each node nests ssh: { ... }).
MESH_PARSE='
    s{//[^\n]*}{}g;
    if (/mesh:\s*\[(.*?)\]\s*as\s+ComputeNodeMesh/s) {
        my $blk = $1;
        my @objs; my $depth = 0; my $cur = "";
        for my $ch (split //, $blk) {
            $depth++ if $ch eq "{";
            $cur .= $ch if $depth > 0;
            if ($ch eq "}") { $depth--; if ($depth == 0) { push @objs, $cur; $cur = ""; } }
        }
        for my $o (@objs) {
            my ($id)   = $o =~ /id:\s*"([^"]+)"/;
            my ($key)  = $o =~ /key:\s*"([^"]+)"/;
            my ($host) = $o =~ /endpoint:\s*"([^"]+)"/;
            my ($port) = $o =~ /port:\s*(\d+)/;
            my ($user) = $o =~ /user:\s*"([^"]+)"/;
            next unless $id;
            $port ||= 22; $user ||= "root";
            print "$id\t$key\t$host\t$port\t$user\n";
        }
    }'
RECORD=$(perl -0777 -ne "$MESH_PARSE" "$REPO_ROOT/project_settings.ts" 2>/dev/null \
    | awk -F'\t' -v id="$NODE_ID" '$1==id' || true)

if [[ -z "${RECORD//[[:space:]]/}" ]]; then
    echo "ERROR: '$NODE_ID' is not a mesh node id in project_settings.nodes.mesh." >&2
    echo "Valid ids:" >&2
    perl -0777 -ne "$MESH_PARSE" "$REPO_ROOT/project_settings.ts" 2>/dev/null \
        | awk -F'\t' '{print "  "$1}' >&2
    exit 1
fi
IFS=$'\t' read -r ID KEY ENDPOINT PORT USER <<< "$RECORD"

if [[ -z "$KEY" || -z "$ENDPOINT" ]]; then
    echo "ERROR: mesh node '$ID' is missing ssh.key or ssh.endpoint in project_settings." >&2
    exit 1
fi

# ── Load Pulumi stack + key into the agent + materialize the pubkey selector ──
if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    if [[ -f /tmp/passphrase ]]; then
        PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
    else
        read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE; echo ""
    fi
    export PULUMI_CONFIG_PASSPHRASE
fi
pulumi login "file://${REPO_ROOT}/.pulumi-state" >/dev/null 2>&1 || true
pulumi stack select mystack >/dev/null 2>&1 || true

# ensure_node_ssh_keys_in_agent loads every node key into the agent AND writes
# tmp/ssh-public-keys/<key>.pub for each (idempotent). It must run IN THIS shell (not a
# subshell) so the loaded agent identities persist to the exec ssh below. Run from the repo
# root so the default SSH_PUBLIC_KEY_DIR (tmp/ssh-public-keys) resolves there.
_prev_pwd="$PWD"
cd "$REPO_ROOT"
# shellcheck source=../pulumi/sshAgentHelpers.sh
source "$SCRIPT_DIR/../pulumi/sshAgentHelpers.sh"
ensure_node_ssh_keys_in_agent \
    || echo "  WARNING: could not load SSH keys from Pulumi config (is the stack reachable?)" >&2
cd "$_prev_pwd"

PUBKEY="$PUBKEY_DIR/$KEY.pub"
if [[ ! -f "$PUBKEY" ]]; then
    echo "ERROR: public key selector '$PUBKEY' was not created." >&2
    echo "  The Pulumi key '$KEY' may be unset (scripts/secrets/setSshKeys.sh) or the stack" >&2
    echo "  is unreachable. Without it the correct agent identity cannot be pinned." >&2
    exit 1
fi

# ── Connect ──────────────────────────────────────────────────────────────────
# IdentitiesOnly + the pubkey selector → ssh offers ONLY the matching agent key, so it never
# trips the mesh sshd's MaxAuthTries. The private key stays in the agent (not on disk).
# NumberOfPasswordPrompts=0 + PreferredAuthentications=publickey: if the pinned key is rejected,
# fail cleanly instead of falling back to a password prompt / spawning ssh-askpass. Interactive
# shells still get their TTY (unlike BatchMode) — only password auth is disabled.
echo "  ssh -> ${USER}@${ENDPOINT}:${PORT} (key '${KEY}')" >&2
exec ssh -o IdentitiesOnly=yes -i "$PUBKEY" \
    -o PreferredAuthentications=publickey \
    -o NumberOfPasswordPrompts=0 \
    -o StrictHostKeyChecking=accept-new \
    -p "$PORT" "${USER}@${ENDPOINT}" "${REMOTE_CMD[@]}"
