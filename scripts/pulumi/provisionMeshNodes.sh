#!/bin/bash
# provisionMeshNodes.sh — second-pass mesh-node provisioning.
#
# Run AFTER `make bootstrap` once the cloud cluster + VPN/headscale mesh are up
# (~15 min). Flips the meshVpnReady gate true (so MeshNodesComponent reconciles the
# SSH-joined mesh box) and runs `pulumi up`. Unlike before, the gate is LEFT true: a
# later `pulumi up`/`make up` keeps the component instantiated and reconciles the mesh
# nodes to a no-op (via the skip-check) instead of deleting them. `make bootstrap` resets
# meshVpnReady to false at the start of a fresh bring-up.
#
# Usage:
#   make provision-mesh-node                       # all ENABLED mesh nodes; reconcile to a no-op
#   make provision-mesh-node ARGS=ubuntu-vm        # ONE node, force re-provision (implied)
#   make provision-mesh-node ARGS='ubuntu-vm --no-force'  # ONE node, non-destructive reconcile
#
# Naming a single node implies --force (detach + cordon/drain + k3s re-join + Tailscale
# re-auth): `enabled:` per node now decides which nodes participate, so an explicit id can
# only mean "re-deploy this one" — and without force the skip-check no-ops an already-Ready
# node, making the single-node form do nothing. The all-nodes form never implies force.
#
# Note: `make provision-mesh-node <id>` (without ARGS=) does NOT pass <id> through — Make
# treats it as a second goal. Always use ARGS='<id>'. This script echoes the effective
# FILTER so an accidental `all` is visible, and validates <id> before any config mutation.
#
# Every candidate box is SSH-probed up front (~10s each) so an unreachable one is never dialed
# for ~176s and hard-failed. SSH-down then falls back to the CLUSTER, giving three outcomes:
#   reachable            → provisioned normally.
#   no SSH, healthy in   → nothing to do (it is Ready with a current fingerprint, so the SSH
#   k8s ("off-VPN")        flow would exit 0 anyway). Left fully in state — NOT skipped.
#   no SSH, not healthy  → EXCLUDED from the run (meshNodeProvisionSkip): it needs an SSH flow
#                          it cannot get. With ARGS=all that is a warning and the other nodes
#                          proceed; with ARGS='<id>' it is a hard error, since skipping the one
#                          node asked for would do nothing at all.
# A skipped node still reconciles its k8s-side labels/fingerprint; only the SSH box flow is
# omitted. The off-VPN case exists so the everyday "home nodes are off-VPN" run does not churn
# their provision resources out of state and back in for no benefit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/_common.sh"

# ── Parse args: optional --force/--no-force anywhere, plus at most one node-id filter ──
FILTER="all"
FORCE=""          # empty = not set explicitly; resolved below from the filter
# --probe-only: run the pre-flight SSH probe, print `SKIP=<csv>` and exit WITHOUT touching
# Pulumi config or provisioning anything. It exists so meshSkipUnreachable.sh can reuse THIS
# probe rather than reimplementing it — the off-VPN-but-healthy distinction below is subtle
# enough that a second copy would drift and start skipping nodes it should keep in state.
PROBE_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE="true" ;;
        --no-force) FORCE="false" ;;
        --probe-only) PROBE_ONLY="1" ;;
        --*) echo "ERROR: unknown flag '$arg' (only --force / --no-force / --probe-only are supported)." >&2; exit 1 ;;
        *)
            if [ "$FILTER" != "all" ]; then
                echo "ERROR: more than one node id given ('$FILTER', '$arg'). Provision one at a time or omit for all." >&2
                exit 1
            fi
            FILTER="$arg"
            ;;
    esac
done

# Naming a single node implies --force. Rationale: which nodes participate at all is now
# declared by `enabled:` per node (project_settings.nodes.mesh), so an explicit ARGS=<id>
# can only mean "re-deploy THIS one" — and without force the skip-check reports BOX_OK=true
# for an already-Ready node with a matching fingerprint and does nothing at all, which made
# the single-node form pointless.
#
# ARGS=all (or no ARGS) deliberately does NOT inherit this: force there would cordon, drain
# and re-join EVERY mesh node at once. The all-nodes form stays a reconcile-to-no-op, which
# is what `pulumi up` relies on to keep MeshNodesComponent instantiated without churn.
#
# --no-force overrides, for re-running one node's reconcile without the destructive path.
if [ -z "$FORCE" ]; then
    if [ "$FILTER" = "all" ]; then FORCE="false"; else FORCE="true"; fi
    IMPLIED_FORCE="true"
else
    IMPLIED_FORCE="false"
fi

init_pulumi

# ── Validate FILTER against the real node ids BEFORE mutating config / running pulumi ──
# _meshNodes.sh is the single source of truth for parsing project_settings.nodes.mesh — its
# header requires every consumer to share it; do not inline a second parser here.
# TSV columns: id, sshKey, host, port, user, enabled, provider, k8sRole
# (so `enabled` is field 6). It strips //-comments, so commented-out node blocks stay invisible.
# shellcheck source=scripts/pulumi/_meshNodes.sh
source "$SCRIPT_DIR/_meshNodes.sh"
NODES="$(meshNodesTsv "$REPO_ROOT/project_settings.ts")"

ALL_IDS=$(printf '%s\n' "$NODES" | cut -f1 | grep -v '^$' || true)
ENABLED_IDS=$(printf '%s\n' "$NODES" | awk -F'\t' '$6=="true"{print $1}')
DISABLED_IDS=$(printf '%s\n' "$NODES" | awk -F'\t' '$6=="false"{print $1}')

if [ "$FILTER" != "all" ]; then
    if ! printf '%s\n' "$ALL_IDS" | grep -qxF "$FILTER"; then
        echo "ERROR: '$FILTER' is not a mesh node id in project_settings.nodes.mesh." >&2
        echo "Valid ids:" >&2
        printf '  %s\n' $ALL_IDS >&2
        exit 1
    fi
    if printf '%s\n' "$DISABLED_IDS" | grep -qxF "$FILTER"; then
        echo "ERROR: mesh node '$FILTER' has enabled:false in project_settings.nodes.mesh." >&2
        echo "Set enabled:true (or drop the field) to provision it." >&2
        exit 1
    fi
elif [ -z "$ENABLED_IDS" ]; then
    echo "ERROR: every mesh node in project_settings.nodes.mesh has enabled:false." >&2
    exit 1
fi

if [ -n "$DISABLED_IDS" ]; then
    echo "  skipping disabled mesh node(s): $(printf '%s ' $DISABLED_IDS)"
fi

# Plain text rather than a phase: this runs inside the caller's "Mesh nodes" phase when
# invoked from bootstrap, and standalone via `make provision-mesh-node` otherwise.
echo "Provisioning on-premise mesh node(s): FILTER='${FILTER}' FORCE='${FORCE}'"
# A force re-provision cordons + drains the node (evicting its pods), deletes its headscale
# machine and re-joins k3s. Never let that be implicit-and-silent — say so when it was not
# asked for on the command line.
if [ "$IMPLIED_FORCE" = "true" ] && [ "$FORCE" = "true" ]; then
    echo "    (--force implied by naming a single node: '${FILTER}' will be cordoned, drained"
    echo "     and re-joined. Use ARGS='${FILTER} --no-force' for a non-destructive reconcile.)"
fi

# ── VPN readiness preflight ───────────────────────────────────────────────────────────
# Mesh nodes join over the headscale VPN; provisioning is meaningless until it serves.
# Fail fast with a clear message (better than an opaque failure deep in `pulumi up`).
# vpn_ready_check() (VERBOSE=1 → diagnostics) is shared with phase_offer_mesh_provision_auto_skip.
source "$SCRIPT_DIR/../runtime/vpnReadyCheck.sh"

if ! VERBOSE=1 vpn_ready_check; then
    echo "" >&2
    echo "Aborting: the VPN/headscale mesh is not ready. Wait for it to come up (a few minutes" >&2
    echo "after 'make bootstrap') and retry. No Pulumi config was changed." >&2
    exit 1
fi

# Load node SSH keys into the agent — the mesh provisioning Commands SSH with bare `ssh`
# (no -i) and rely on the agent (see sshAgentHelpers.sh). Must run after stack select.
# SSH keys are per-node (node.ssh.key in project_settings) and also checked at Pulumi
# evaluation time — run scripts/secrets/setSshKeys.sh if provisioning fails with a
# missing-key error.
source "$SCRIPT_DIR/sshAgentHelpers.sh"
ensure_node_ssh_keys_in_agent

# ── Pre-flight SSH reachability probe ─────────────────────────────────────────────────
# WHY here, before any `pulumi config set`: the boxOk/nodePresent skip gate lives INSIDE the
# mesh-provision remote Command's `create` script, so it only helps AFTER SSH connects. An
# offline box (a home/lab machine simply powered off) makes that Command burn 10 dial retries
# (~176s) and then hard-fail. Probing here and telling Pulumi not to instantiate that one
# Command (meshNodeProvisionSkip) is what keeps an offline box a non-event.
#
# We do NOT drop the node from project_settings.nodes.mesh: mesh nodes own Pulumi mesh-*
# Command resources, so removing one from the program is a DELETE, not a pause.
#
# SSH-unreachable is NOT automatically "skip", though — see node_is_healthy_in_k8s below. A box
# that is off-VPN but Ready in the cluster with a matching fingerprint needs no SSH at all, and
# skipping it would churn its provision resource out of state for nothing.
provision_resource_in_state() {
    # provision_resource_in_state <id> → 0 iff mesh-provision-<id> already exists in the stack.
    # This is the OTHER half of the off-VPN decision and it is NOT optional: the boxOk gate is
    # the first line of the REMOTE script, so it only runs after SSH connects. Keeping an
    # un-skipped resource is therefore only safe when Pulumi will not have to CREATE it — an
    # existing, unchanged remote.Command is never re-executed, but a missing one is created, and
    # creating it dials the box (10 retries, ~176s, then a resource error). Verified the hard way.
    local id="$1"
    pulumi stack export 2>/dev/null \
        | grep -qF "::mesh-provision-${id}\""
}

node_is_healthy_in_k8s() {
    # node_is_healthy_in_k8s <id> <fpBox> → 0 iff the node is Ready AND its stamped
    # ecc/provision-fingerprint equals <fpBox>. Pure kubectl against the CP, so it works while
    # the box itself is unreachable. This is the SAME condition mesh-skipcheck-<id> evaluates
    # (BOX_OK=true) — deliberately duplicated here because we must decide BEFORE pulumi runs,
    # and we must read it LIVE: skipcheck's stored verdict can be stale (it is cached on fpBox),
    # and a stale verdict is exactly what would change `create` and force a dial.
    local id="$1" want="$2"
    local ready="" fp=""
    ready="$(kubectl get node "$id" \
        -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    fp="$(kubectl get node "$id" \
        -o jsonpath='{.metadata.annotations.ecc/provision-fingerprint}' 2>/dev/null || true)"
    [ "$ready" = "True" ] && [ -n "$want" ] && [ "$fp" = "$want" ]
}

# fpBox per node — the same sha256(id, ssh.endpoint, ssh.port, ssh.user, advertiseRoutes)[:16]
# that src/nodes-k3s-mesh.ts computes and mesh-label stamps onto the node. Recomputed here (not
# read from the node) so a node carrying a STALE fingerprint is correctly seen as not-healthy.
mesh_fp_box() {
    node -e '
const crypto = require("crypto");
const fs = require("fs");
let src = fs.readFileSync(process.argv[1], "utf8").replace(/\/\/[^\n]*/g, "");
const m = src.match(/mesh:\s*\[([\s\S]*?)\]\s*as\s+ComputeNodeMesh/);
if (!m) process.exit(0);
let depth = 0, cur = "";
const objs = [];
for (const ch of m[1]) {
    if (ch === "{") depth++;
    if (depth > 0) cur += ch;
    if (ch === "}" && --depth === 0) { objs.push(cur); cur = ""; }
}
for (const o of objs) {
    const id = (o.match(/id:\s*"([^"]+)"/) || [])[1];
    if (!id) continue;
    const ep = (o.match(/endpoint:\s*"([^"]+)"/) || [])[1];
    const pt = Number((o.match(/port:\s*(\d+)/) || [])[1]);
    const us = (o.match(/user:\s*"([^"]+)"/) || [])[1];
    const ar = o.match(/advertiseRoutes:\s*\[([^\]]*)\]/);
    const routes = ar
        ? ar[1].split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter(Boolean)
        : null;
    const fp = crypto.createHash("sha256")
        .update(JSON.stringify([id, ep, pt, us, routes])).digest("hex").slice(0, 16);
    console.log(id + "\t" + fp);
}' "$1" 2>/dev/null || true
}

probe_node_ssh() {
    # probe_node_ssh <id> <sshKey> <host> <port> <user> → 0 reachable, 1 not.
    # Under `set -u`, `local x` DECLARES without initialising — assign every one of these.
    local id="$1" key="$2" host="$3" port="$4" user="$5"
    local keyfile=""
    local rc=0
    keyfile="$(mktemp)"
    chmod 600 "$keyfile"
    if ! pulumi config get "$key" 2>/dev/null > "$keyfile" \
        || ! grep -q 'BEGIN .*PRIVATE KEY' "$keyfile"; then
        echo "  probe: SSH key '$key' for '$id' not in Pulumi config — treating as UNREACHABLE." >&2
        rm -f "$keyfile"
        return 1
    fi
    # -n redirects ssh's stdin from /dev/null: without it ssh consumes the caller loop's
    # here-string stdin, so `read` hits EOF and only the FIRST node is ever probed.
    ssh -n -i "$keyfile" -p "$port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes \
        "$user@$host" true >/dev/null 2>&1 || rc=1
    rm -f "$keyfile"
    return "$rc"
}

SKIP_IDS=""
OFFVPN_IDS=""     # SSH-unreachable but healthy in k8s — kept, NOT skipped
PROBE_IDS="$ENABLED_IDS"
[ "$FILTER" != "all" ] && PROBE_IDS="$FILTER"
FP_TSV="$(mesh_fp_box "$REPO_ROOT/project_settings.ts")"

echo "Pre-flight SSH probe (mesh boxes):"
while IFS=$'\t' read -r ID KEY HOST PORT USER ENABLED _REST; do
    [ -z "$ID" ] && continue
    [ "$ENABLED" = "true" ] || continue
    printf '%s\n' "$PROBE_IDS" | grep -qxF "$ID" || continue
    if probe_node_ssh "$ID" "$KEY" "$HOST" "$PORT" "$USER"; then
        echo "  reachable:   $ID ($USER@$HOST:$PORT)"
        continue
    fi
    # SSH is down. Fall back to the cluster: if the node is Ready with a MATCHING fingerprint it
    # is fully provisioned and the SSH flow would `exit 0` anyway, so there is nothing to skip —
    # leave its provision Command in state (skipping it would delete + recreate the resource for
    # no benefit). Only a node that is genuinely unfinished (absent / NotReady / stale
    # fingerprint) needs the SSH flow it cannot get, and that one is skipped.
    FP="$(printf '%s\n' "$FP_TSV" | awk -F'\t' -v id="$ID" '$1==id{print $2}')"
    if node_is_healthy_in_k8s "$ID" "$FP" && provision_resource_in_state "$ID"; then
        echo "  off-VPN:     $ID ($USER@$HOST:$PORT) — no SSH, but Ready in k8s with a current"
        echo "               fingerprint: already provisioned, nothing to do (resource kept)."
        OFFVPN_IDS="${OFFVPN_IDS:+$OFFVPN_IDS,}$ID"
    elif node_is_healthy_in_k8s "$ID" "$FP"; then
        # Healthy, but its provision resource is missing from state (e.g. a previous off-VPN run
        # skipped it, or it never registered). Creating it would dial the box, so skip again and
        # let it be re-created on the first run where SSH answers — where the gate no-ops it.
        echo "  UNREACHABLE: $ID ($USER@$HOST:$PORT) — no SSH; healthy in k8s but its provision"
        echo "               resource is absent from state, and creating it would dial the box."
        SKIP_IDS="${SKIP_IDS:+$SKIP_IDS,}$ID"
    else
        echo "  UNREACHABLE: $ID ($USER@$HOST:$PORT) — no SSH and not healthy in k8s; its SSH"
        echo "               provision Command will not be created."
        SKIP_IDS="${SKIP_IDS:+$SKIP_IDS,}$ID"
    fi
done <<< "$NODES"

# --probe-only stops HERE: the probe has run and its verdict is on stdout, but nothing has
# been written to Pulumi config and no provisioning has happened. Printed as a machine-
# readable last line so the caller does not have to parse the human-readable log above.
# An EMPTY value is meaningful (every enabled box reachable) and must be emitted, so the
# caller can CLEAR a stale skip list rather than leave a node wrongly skipped forever.
if [ -n "$PROBE_ONLY" ]; then
    [ -n "$OFFVPN_IDS" ] && echo "  NOTE: off-VPN but healthy (kept in state): $OFFVPN_IDS"
    echo "SKIP=${SKIP_IDS}"
    exit 0
fi

# Naming ONE node that is unreachable is an error, not a silent skip: the operator asked for
# that node specifically, and skipping it would report "provisioning complete" having done
# nothing to it. An off-VPN-but-healthy node is NOT an error — there is genuinely nothing to do.
if [ "$FILTER" != "all" ] && [ -n "$SKIP_IDS" ]; then
    echo "" >&2
    echo "ERROR: mesh node '$FILTER' is not SSH-reachable at its configured ssh.endpoint, and it" >&2
    echo "is not Ready in the cluster with a current fingerprint either — so it genuinely needs" >&2
    echo "the SSH flow. Power it on / connect the VPN to its site and retry. No Pulumi config" >&2
    echo "was changed." >&2
    exit 1
fi
if [ -n "$OFFVPN_IDS" ]; then
    echo "  NOTE: already-provisioned, currently off-VPN (kept in state, no SSH attempted): $OFFVPN_IDS"
fi
# For ARGS=all we warn and continue: the Tier-1 kubectl reconcile (labels, Longhorn disk tags,
# fingerprint) is still worth running for every already-joined node even with no box reachable.
if [ -n "$SKIP_IDS" ]; then
    echo "  NOTE: box provisioning is skipped for: $SKIP_IDS"
    echo "        Their k8s-side labels/fingerprint still reconcile; re-run once they are up."
fi

# ⚠ This is the pass that hit "cannot re-use a name that is still in use" on ecc197: it runs
# seconds after production hardening handed the `argocd` Helm release to ArgoCD and re-pinned
# the API endpoint to the private VIP. Refresh the ownership latch so this apply does not try
# to re-install a release ArgoCD already owns. Never fatal (off→on only).
bash "$SCRIPT_DIR/argocdOwnershipLatch.sh" || true

pulumi config set meshVpnReady true
pulumi config set meshNodeProvisionFilter "$FILTER"
pulumi config set meshNodeProvisionForce "$FORCE"
# Stamp a per-run nonce on FORCE runs only. Without it a repeat force is a no-op: the
# detach/provision Commands trigger on fpBox (+ this), and fpBox covers only id/ssh.*/
# advertiseRoutes — none of which change when you re-run against the same box. Pulumi then
# reports "N unchanged" in ~37s while the banner above has already claimed the node "will be
# cordoned, drained and re-joined". Cleared on non-force runs so `make up` never re-provisions.
if [ "$FORCE" = "true" ]; then
    pulumi config set meshNodeProvisionForceNonce "$(date -u +%Y%m%dT%H%M%SZ)-$$"
else
    pulumi config set meshNodeProvisionForceNonce ""
fi
# Set unconditionally — INCLUDING to empty — so a box that came back online is no longer
# skipped on the next run. A stale value here would silently park it forever.
pulumi config set meshNodeProvisionSkip "$SKIP_IDS"

# --continue-on-error: unreachable boxes are already excluded by the probe above, so what this
# still covers is a REACHABLE node whose provisioning script fails (e.g. a missing package).
# Pulumi applies every resource it can, then exits non-zero listing the ones that failed.
# Everything else in the stack is a no-op on a mesh pass, so the only resources that can fail
# here are the per-node mesh Commands — safe to continue. We capture the exit code so we can
# report the failed nodes without `set -e` killing the script, then re-surface it as a warning.
set +e
CI=true pulumi up -y --skip-preview --continue-on-error
UP_RC=$?
set -e

echo ""
if [ "$UP_RC" -ne 0 ]; then
    echo "WARNING: 'pulumi up' finished with errors (rc=$UP_RC) — one or more mesh nodes" >&2
    echo "failed to provision. Unreachable boxes were already excluded by the pre-flight" >&2
    echo "probe, so this is a node that answered SSH but whose provisioning script failed;" >&2
    echo "the named resource error above says which step. Every other node was still" >&2
    echo "provisioned and recorded in state." >&2
    echo "" >&2
fi
echo "Mesh provisioning complete. Verify with: kubectl get nodes -o wide"
echo "meshVpnReady is left true so a later 'make up' reconciles mesh nodes to a no-op."
# Preserve pulumi's exit code so CI still sees a failure, but AFTER the other nodes ran.
exit "$UP_RC"
