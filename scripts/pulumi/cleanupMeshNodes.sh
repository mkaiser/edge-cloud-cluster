#!/bin/bash
# cleanupMeshNodes.sh — SSH into the joined on-premise mesh nodes and wipe their k3s + mesh state.
#
# WHY: mesh nodes (project_settings.nodes.mesh) are SSH-provisioned in place — they are NOT
# hcloud/robot resources, so `pulumi destroy` does NOT touch them. After a destroy the box
# keeps a half-joined k3s-agent + tailscaled beaconing the now-dead control URL / apiserver.
# A university IDS can rate-limit or blackhole the host for that, which then makes a later
# legitimate `make provision-mesh-node` time out. This runs the existing clean-slate teardown
# (src/provisioning-scripts/00-cleanup-node.sh) on each mesh box so the next provision starts clean.
#
# Invoked by destroyCluster.sh BEFORE `pulumi destroy` — so the apiserver is still up (we clean
# only mesh nodes ACTUALLY JOINED to the cluster, not the whole static list) and the VPN mesh
# is still up (VPN-only home nodes are reachable). Falls back to "all reachable mesh nodes" if
# the cluster can't be queried (e.g. apiserver already gone).
#
# Idempotent + safe: no-op when there are no mesh nodes; tolerant of an unreachable box
# (skipped with a warning, never aborting the destroy).
#
# Reads mesh node identities (id, ssh.key, ssh.endpoint/port/user) from project_settings.ts and the
# SSH private key from the Pulumi config. Caller must have the stack selected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEANUP_TPL="$ROOT_DIR/src/provisioning-scripts/00-cleanup-node.sh"

log() { echo "  mesh-cleanup: $*" >&2; }

if [[ ! -f "$CLEANUP_TPL" ]]; then
    log "WARNING: $CLEANUP_TPL not found — skipping mesh cleanup."
    exit 0
fi

# ── Mesh node fields from project_settings.ts ────────────────────────────────
# Shared parser (scripts/pulumi/_meshNodes.sh) → TAB records: id, sshKey, host, port, user.
# shellcheck source=scripts/pulumi/_meshNodes.sh
source "$SCRIPT_DIR/_meshNodes.sh"
NODES=$(meshNodesTsv "$ROOT_DIR/project_settings.ts")

if [[ -z "${NODES//[[:space:]]/}" ]]; then
    log "no mesh nodes in project_settings — skipping."
    exit 0
fi

# ── Restrict to mesh nodes actually JOINED to the live cluster ────────────────
# Query the apiserver (still up: this runs before pulumi destroy). When reachable we clean
# only currently-joined mesh nodes; if it can't be queried we fall back to the static list
# (every reachable node), so the script still does the right thing if the cluster is gone.
JOINED=""
if kubectl get nodes -o name >/dev/null 2>&1; then
    JOINED="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    log "cluster reachable — cleaning only joined mesh nodes."
else
    log "cluster not reachable — falling back to all configured mesh nodes."
fi

is_joined() {
    # No live data → treat every configured node as in-scope (fallback path).
    [[ -z "$JOINED" ]] && return 0
    local n
    for n in $JOINED; do [[ "$n" == "$1" ]] && return 0; done
    return 1
}

# ── Run 00-cleanup-node.sh on each mesh box over SSH ─────────────────────────────
# base64-inline the script (the mesh sshd rejects setenv, same constraint as provisioning).
CLEANUP_B64="$(base64 -w0 "$CLEANUP_TPL" 2>/dev/null || base64 "$CLEANUP_TPL" | tr -d '\n')"

# ENABLED (6th field) is read but deliberately NOT honored: cleanup runs on teardown, and a
# node parked with enabled:false may still be JOINED (enabled:false skips provisioning, it
# never detaches). Skipping it here would leave k3s/Tailscale running on the box after destroy.
while IFS=$'\t' read -r ID KEY HOST PORT USER ENABLED; do
    [[ -z "$ID" ]] && continue
    if ! is_joined "$ID"; then
        log "mesh node '$ID' not joined to the cluster — skipping."
        continue
    fi
    log "cleaning mesh node '$ID' ($USER@$HOST:$PORT)…"

    KEYFILE="$(mktemp)"
    chmod 600 "$KEYFILE"
    if ! pulumi config get "$KEY" 2>/dev/null > "$KEYFILE" || ! grep -q 'BEGIN .*PRIVATE KEY' "$KEYFILE"; then
        log "WARNING: SSH key '$KEY' for '$ID' not in Pulumi config — skipping."
        rm -f "$KEYFILE"
        continue
    fi

    # Short connect timeout: VPN-only home nodes are unreachable after destroy — skip fast.
    # -n redirects ssh's stdin from /dev/null: without it ssh consumes the loop's here-string
    # stdin, so `read` hits EOF and only the FIRST node would ever be cleaned.
    if ssh -n -i "$KEYFILE" -p "$PORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 -o BatchMode=yes \
            "$USER@$HOST" \
            "echo $CLEANUP_B64 | base64 -d | sudo bash -s -- --wipe-storage" >/dev/null 2>&1; then
        log "mesh node '$ID' cleaned."
    else
        log "WARNING: could not reach/clean '$ID' (continuing) — run 'sudo bash 00-cleanup-node.sh' on it manually if it rejoins."
    fi
    rm -f "$KEYFILE"
done <<< "$NODES"

log "mesh cleanup pass complete."
