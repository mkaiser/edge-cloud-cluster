#!/bin/bash
# Apply the current Pulumi program to an EXISTING cluster.
#
# ⚠ DO NOT DELETE THIS SCRIPT. The dangerous thing was the `make up` TARGET, not this
# file — three lifecycle callers invoke the SCRIPT and die with exit 127 without it:
#
#   scripts/pulumi/production.sh:43     `make production`
#   scripts/pulumi/_lifecycle.sh:267    the hardening phase of `make bootstrap --complete`
#   scripts/pulumi/bootstrap.sh:63      re-opening Bootstrap posture on an existing cluster
#
# That is not cosmetic: a fresh `make bootstrap ARGS=--complete` brings the whole cluster
# up, flips targetState to "production" in git, and THEN dies here — leaving the repo saying
# production while the live firewall is still open (public 22/6443).
#
# `make up` exists again (2026-08-30) and calls THIS script — never `pulumi up` directly.
# The distinction is the whole point: applying the program BY HAND is the dangerous thing,
# because a bare `pulumi up` skips the mesh preflight below and is not logged, so there is
# nothing to point at afterwards.
#
# ⚠ WHY THE PREFLIGHT IS LOAD-BEARING. `pulumi up` re-evaluates every mesh node, and whether
# that is a no-op depends on `meshNodeProvisionSkip`. If that key is stale or EMPTY,
# the provision command's BOX_OK/NODE_PRESENT gate falls through to the full SSH flow, which
# runs 00-cleanup-node.sh — and that does `rm -rf /var/lib/longhorn` (00-cleanup-node.sh:122). Every
# replica on the box dies and the disk returns with a NEW UUID, orphaning the replica CRs
# that still name the old one. Longhorn then reports the volume `faulted` and loops
# "All replicas are failed … Bringing up 0 replicas for auto-salvage" indefinitely, because
# auto-salvage needs an engine and the engine cannot start while the volume is faulted.
# Measured 2026-08-30: a hand-run `pulumi up` wiped all three unibi-lab nodes' Longhorn disks
# and took ad-onprem-0 down for 14 h with two unrecoverable volumes.
#
# The preflight also resets the mesh SCOPE keys (`meshNodeProvisionFilter`,
# `meshNodeProvisionForce`) — see the block that does it for why a leftover filter is its own
# distinct failure, quieter than the one above.
#
# Mirrors what phase_create() does for a fresh create (_lifecycle.sh) so the two paths
# cannot drift: ssh-agent keys, kubeapi host pin, apply, then refresh the kubeconfig.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/_common.sh"
init_pulumi

# Robot/mesh provisioning uses remote.Command over SSH; without the keys in the agent the
# apply fails partway with an auth error rather than up front.
source "$SCRIPT_DIR/sshAgentHelpers.sh"
ensure_node_ssh_keys_in_agent

# Plain text, not a phase banner: this script always runs INSIDE a phase owned by its
# caller (bootstrap's "Re-open Bootstrap posture", the hardening phase, production's
# "Apply"). Opening a phase here would nest one inside another and break the numbering.
echo "compute node preflight (warn-only):" >&2
bash "$SCRIPT_DIR/checkComputeNodes.sh" --warn-only || true

# Which address the kubeconfig/provider should use. Prefer the private VIP when the admin
# WireGuard tunnel is up — that is the only route once Production closes public 6443, and
# hardening runs exactly then. Fall back to the public IP otherwise.
if ip link show wgadmin >/dev/null 2>&1; then
    bash "$REPO_ROOT/scripts/runtime/setKubeApiHost.sh" --vip || true
else
    bash "$REPO_ROOT/scripts/runtime/setKubeApiHost.sh" --public || true
fi

# ⚠ PROBE THE MESH BOXES BEFORE APPLYING. Only provisionMeshNodes.sh used to refresh
# `meshNodeProvisionSkip`, so every caller of THIS script applied with whatever the key held
# from some earlier run. One powered-off box then failed the entire stack update — its
# remote.Command burns 10 dials (~176s) and errors, and mesh-label sits in its 240x5s
# wait-for-register loop — e.g. a mesh node whose box does not exist
# yet. Never fatal: the guard leaves the config untouched if it cannot decide.
bash "$SCRIPT_DIR/meshSkipUnreachable.sh" || true

# ⚠ RESET THE MESH SCOPE FLAGS. `meshNodeProvisionFilter` and `meshNodeProvisionForce` are
# written by provisionMeshNodes.sh (`make provision-mesh-node ARGS='<id> --force'`) and nothing
# used to clear them, so they stayed pinned to whatever node was provisioned last — for every
# later apply. src/nodes-k3s-mesh.ts filters nodes.mesh down to `id === filter`, so a leftover
# filter makes `make up` silently reconcile ONE node and ignore the rest: a node newly switched
# to `enabled: true` is never provisioned, and no message says why (measured 2026-09-10, where
# home-martin-mini0 stayed unprovisioned behind a filter left over from budapest-emdc-node7).
#
# This apply is the whole-stack path by definition, so its scope is always "all". Unlike the
# skip list above, no probe is involved — the correct value is a constant, so set it
# unconditionally rather than trying to detect staleness.
#
# ⚠ `meshNodeProvisionForceNonce` MUST be cleared here too, and it is the DANGEROUS one.
# src/nodes-k3s-mesh.ts puts it in the triggers of mesh-detach, mesh-provision and mesh-label
# *independently of* `force` — so a nonce left over from an earlier force run re-triggers the
# full destructive flow (detach, then 00-cleanup-node.sh, which `rm -rf /var/lib/longhorn`)
# on EVERY mesh node on the next apply, exactly the wipe the skip probe above exists to
# prevent. Those triggers document the invariant "non-empty ONLY on a force run"; since
# provisionMeshNodes.sh clears it only when IT runs, this is what holds that true for
# `make up`.
for _k in meshNodeProvisionFilter:all meshNodeProvisionForce:false meshNodeProvisionForceNonce:; do
    _key="${_k%%:*}" _want="${_k#*:}"
    _cur="$(pulumi config get "$_key" 2>/dev/null || true)"
    if [ "$_cur" != "$_want" ]; then
        pulumi config set "$_key" "$_want" \
            && echo "up: ${_key}='${_want}' (was '${_cur:-<empty>}')." >&2
    fi
done

# ⚠ REFRESH THE ARGOCD OWNERSHIP LATCH BEFORE APPLYING, for the same reason as the mesh probe
# above: this apply must not re-create a Helm release that ArgoCD has already taken over
# ("cannot re-use a name that is still in use"). Runs AFTER the kubeapi pin above so the
# cluster is reachable on whichever endpoint this posture uses. Never fatal — the latch only
# ever moves off→on here, and an unconfirmed handoff leaves Pulumi owning the release.
bash "$SCRIPT_DIR/argocdOwnershipLatch.sh" || true

# CI=true --skip-preview: same as phase_create. These callers have already decided; an
# interactive preview would hang a detached lifecycle run.
CI=true pulumi up -y --skip-preview "$@"

# The apply can change the API endpoint (a posture flip re-pins it), so re-fetch rather
# than trusting the kubeconfig that got us here.
source "$REPO_ROOT/scripts/runtime/getKubeConfig.sh"
