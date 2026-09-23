#!/bin/bash
# decomissionNode.sh — fully retire ONE mesh node (id) so it leaves no ghost behind.
#
# WHY: mesh nodes are SSH-provisioned + VPN-joined, NOT Pulumi cloud resources. Simply
# commenting a node out of project_settings.nodes.mesh[] tears down NOTHING — the box keeps
# a live k3s-agent + tailscale identity, its k8s/Longhorn node objects linger, its headscale
# machine entry orphans, and its 5 command:* resources sit stale in Pulumi state. There is no
# `delete` on those Commands (create-only), so `pulumi up` cannot clean the actual node. This
# script is the single command that does the full teardown, in the correct order.
#
# What it does, per id:
#   1. Box wipe        — SSH in, run src/provisioning-scripts/00-cleanup-node.sh (k3s + tailscale
#                        identity + routes). Skipped if the node is no longer in config (no SSH
#                        details) or unreachable — a warning, never a hard fail.
#   2. k8s objects     — cordon/drain (if Ready) then delete the k8s node + Longhorn node CR.
#   3. headscale entry — delete the machine record whose hostname == <id> (nothing else does).
#   4. Pulumi state    — `pulumi state delete` the 5 mesh-<phase>-<id> command resources.
#
# Idempotent: every step tolerates an already-absent target. Ordering matters — box wipe FIRST
# (while still reachable + declared), state prune LAST.
#
# Usage:
#   bash scripts/provisioning/decomissionNode.sh <node-id>
#   bash scripts/provisioning/decomissionNode.sh <node-id> --keep-config   # don't remove from project_settings
#   bash scripts/provisioning/decomissionNode.sh <node-id> --dry-run
#
# Order of operations vs. config: run this BEFORE removing the node from project_settings.ts if
# possible (so step 1 can read its ssh.{endpoint,port,user,key} and wipe the box). If the node is
# already gone from config, steps 2–4 still run by id; step 1 is skipped with a warning and you
# must `sudo bash 00-cleanup-node.sh` on the box by hand.
#
# Needs: a working kubeconfig (steps 2,3) + the Pulumi stack loaded (steps 1,4 read the SSH key
# from Pulumi config and prune state). Auto-loads both from the documented locations if absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../pulumi/_common.sh"
CLEANUP_TPL="$REPO_ROOT/src/provisioning-scripts/00-cleanup-node.sh"
HS_NAMESPACE="${HS_NAMESPACE:-headscale}"

STACK_URN_PREFIX="urn:pulumi:mystack::edgecloudinfra::ecc:infra:MeshNodes"

log() { echo "  decommission: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Parse args: exactly one id, optional flags ───────────────────────────────
ID=""
KEEP_CONFIG=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --*)           die "unknown flag '$arg' (only --keep-config, --dry-run)." ;;
        *)
            [ -z "$ID" ] || die "more than one node id given ('$ID', '$arg'). Decommission one at a time."
            ID="$arg" ;;
    esac
done
[ -n "$ID" ] || die "usage: $0 <node-id> [--keep-config] [--dry-run]"

run() {  # run() <description> <cmd...> — honour --dry-run
    if [ "$DRY_RUN" = 1 ]; then echo "  DRY-RUN: $*" >&2; return 0; fi
    "$@"
}

# ── Load Pulumi stack (for the SSH key in step 1 + state prune in step 4) ─────
# Keep the fatal-on-fail semantics: a bad login/select must abort a decommission.
load_pulumi_passphrase
pulumi_login_select || die "pulumi login / stack select mystack failed."

# ── Resolve this node's SSH details from project_settings (may be absent) ─────
# Shared parser: TSV records id, sshKey, host, port, user. If the node was already removed
# from config, NODE_LINE is empty → step 1 (box wipe) is skipped with a warning.
# shellcheck source=scripts/pulumi/_meshNodes.sh
source "$REPO_ROOT/scripts/pulumi/_meshNodes.sh"
NODE_LINE="$(meshNodesTsv "$REPO_ROOT/project_settings.ts" | awk -F'\t' -v id="$ID" '$1==id')"

echo "=== Decommissioning mesh node '$ID' (dry-run=$DRY_RUN, keep-config=$KEEP_CONFIG) ==="

# ── kubeconfig for steps 2–3 ─────────────────────────────────────────────────
KUBE_OK=1
kubectl get nodes -o name >/dev/null 2>&1 || KUBE_OK=0
[ "$KUBE_OK" = 1 ] || log "WARNING: cluster not reachable (kubeconfig?) — steps 2 & 3 (k8s + headscale) will be skipped."

# ═════════════════════════════════════════════════════════════════════════════
# 1. Box wipe over SSH (only if still declared in config → we have ssh details)
# ═════════════════════════════════════════════════════════════════════════════
if [ -z "$NODE_LINE" ]; then
    log "node '$ID' not in project_settings.nodes.mesh[] — no SSH details."
    log "  Skipping remote box wipe. Run 'sudo bash 00-cleanup-node.sh' on the box by hand if it still runs."
elif [ ! -f "$CLEANUP_TPL" ]; then
    log "WARNING: $CLEANUP_TPL missing — cannot wipe box remotely. Skipping."
else
    # Trailing ENABLED field must be read into its own var: without it USER would absorb
    # the rest of the line ("cape<TAB>false") and the SSH target would be malformed.
    # enabled:false is irrelevant here — a parked node still needs a real decommission.
    IFS=$'\t' read -r _ KEY HOST PORT USER _ENABLED <<< "$NODE_LINE"
    log "1/4 box wipe: SSH $USER@$HOST:$PORT → 00-cleanup-node.sh"
    KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
    if ! pulumi config get "$KEY" 2>/dev/null > "$KEYFILE" || ! grep -q 'BEGIN .*PRIVATE KEY' "$KEYFILE"; then
        log "  WARNING: SSH key '$KEY' not in Pulumi config — skipping box wipe."
        rm -f "$KEYFILE"
    else
        # base64-inline the script: the mesh sshd rejects setenv (same constraint as provisioning).
        CLEANUP_B64="$(base64 -w0 "$CLEANUP_TPL" 2>/dev/null || base64 "$CLEANUP_TPL" | tr -d '\n')"
        if [ "$DRY_RUN" = 1 ]; then
            echo "  DRY-RUN: ssh $USER@$HOST:$PORT -- '00-cleanup-node.sh | sudo bash -s -- --wipe-storage'" >&2
        elif ssh -n -i "$KEYFILE" -p "$PORT" \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=15 -o BatchMode=yes \
                "$USER@$HOST" "echo $CLEANUP_B64 | base64 -d | sudo bash -s -- --wipe-storage" >/dev/null 2>&1; then
            log "  box '$ID' wiped."
        else
            log "  WARNING: could not reach/wipe '$ID' — run 'sudo bash 00-cleanup-node.sh' on it by hand."
        fi
        rm -f "$KEYFILE"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Delete the k8s node + Longhorn node CR (cordon/drain first if Ready)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$KUBE_OK" = 1 ]; then
    if kubectl get node "$ID" >/dev/null 2>&1; then
        # Capture the VPN IP BEFORE deleting the node — step 3 needs it to find the headscale
        # entry, whose NAME is the guest hostname and so may not contain the node id at all.
        # A mesh node's InternalIP IS its tailscale address (k3s --node-ip=<vpn ip>).
        NODE_VPN_IP=$(kubectl get node "$ID" \
            -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -n "$NODE_VPN_IP" ] && log "  (vpn ip: $NODE_VPN_IP — used to match the headscale entry)"
        READY=$(kubectl get node "$ID" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
        if [ "$READY" = "True" ]; then
            log "2/4 k8s: cordon + drain '$ID' (evict pods, let Longhorn rebuild replicas)…"
            run kubectl cordon "$ID" || true
            run kubectl drain "$ID" --ignore-daemonsets --delete-emptydir-data \
                --force --timeout=120s || log "  WARNING: drain timed out/failed — deleting anyway."
        else
            log "2/4 k8s: node '$ID' NotReady — skipping drain, deleting directly."
        fi
        run kubectl delete node "$ID" --ignore-not-found --wait=false
        # ⚠ The Longhorn admission webhook REFUSES to delete a node CR while it is still
        # marked schedulable, even with zero replicas and the k8s node already gone:
        #   "could not delete node <id> with node ready condition is False, reason is
        #    KubernetesNodeGone, node schedulable true, and 0 replica, 0 engine running on it"
        # The delete therefore has to be preceded by flipping allowScheduling off. This used
        # to be `|| true`, which swallowed the rejection and then logged success — leaving an
        # orphaned node CR that still counts toward longhorn-<scope> replica scheduling.
        #
        if [ "$DRY_RUN" = 1 ]; then
            run kubectl patch nodes.longhorn.io "$ID" -n longhorn-system --type=merge \
                -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
            run kubectl delete nodes.longhorn.io "$ID" -n longhorn-system --ignore-not-found --wait=false
        elif kubectl get nodes.longhorn.io "$ID" -n longhorn-system >/dev/null 2>&1; then
            kubectl patch nodes.longhorn.io "$ID" -n longhorn-system --type=merge \
                -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null 2>&1 || true
            if kubectl delete nodes.longhorn.io "$ID" -n longhorn-system \
                 --ignore-not-found --wait=false >/dev/null 2>&1; then
                log "  Longhorn node CR deleted."
            else
                log "  WARNING: Longhorn node CR '$ID' could NOT be deleted — it will keep"
                log "           counting toward longhorn-<scope> replica scheduling. Retry:"
                log "             kubectl patch nodes.longhorn.io $ID -n longhorn-system --type=merge \\"
                log "               -p '{\"spec\":{\"allowScheduling\":false}}'"
                log "             kubectl delete nodes.longhorn.io $ID -n longhorn-system"
            fi
        fi
        [ "$DRY_RUN" = 1 ] || log "  k8s node object deleted."
    else
        log "2/4 k8s: no node object '$ID' — nothing to delete."
    fi
else
    log "2/4 k8s: skipped (cluster unreachable)."
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. Delete the headscale machine entry. Nothing else does this.
#
# ⚠ THE HEADSCALE NAME MAY NOT BE THE NODE ID. 30-connect-vpn.sh names the tailnet entry
# `${ECC_NODE_NAME:-$(hostname)}`: nodes provisioned by the carry-scripts pass ECC_NODE_NAME
# and so match the k8s node name, but anything joined without it is named whatever the box
# calls itself — the DHCP name where one is served (unibi-hclab-fs-vm → `fs-1-vm`), or the
# ISO's ubuntu-autoinstall-<mac>, or a short form (unibi-hclab-pcie-tb-d → `pcie-tb-d`).
# Matching on the id alone therefore silently finds NOTHING for those and leaves the machine
# orphaned; on the next join headscale hands out a different VPN IP while the stale entry
# keeps the old one.
#
# So resolve the node's ACTUAL VPN IP from k8s (the InternalIP of a mesh node IS its
# tailscale address) and match on that first, falling back to the name. The IP is the
# reliable key: it is what the node registered with, whatever it called itself.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$KUBE_OK" = 1 ]; then
    HS_POD=$(kubectl get pods -n "$HS_NAMESPACE" -l app.kubernetes.io/name=headscale \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
        || kubectl get pods -n "$HS_NAMESPACE" -l app=headscale \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$HS_POD" ]; then
        log "3/4 headscale: pod not found in ns '$HS_NAMESPACE' — skipping (delete the entry via headplane)."
    else
        # The node's VPN IP, captured BEFORE the k8s node object was deleted (step 2) —
        # empty if it had already gone, in which case we fall back to name matching.
        HS_IDS=$(kubectl exec -n "$HS_NAMESPACE" "$HS_POD" -- headscale nodes list --output json 2>/dev/null \
            | NODE_ID="$ID" NODE_VPN_IP="${NODE_VPN_IP:-}" python3 -c "
import sys, json, os
want = os.environ['NODE_ID']
want_ip = (os.environ.get('NODE_VPN_IP') or '').strip()
data = json.load(sys.stdin)
nodes = data if isinstance(data, list) else data.get('nodes', [])
def names(n):
    return {n.get('given_name'), n.get('givenName'), n.get('name')}
def addrs(n):
    a = n.get('ip_addresses') or n.get('ipAddresses') or []
    return {str(x) for x in a}
ids = [str(n['id']) for n in nodes
       if (want_ip and want_ip in addrs(n)) or want in names(n)]
print(' '.join(ids))" 2>/dev/null || true)
        if [ -z "${HS_IDS// }" ]; then
            log "3/4 headscale: no machine entry for '$ID' (vpn-ip '${NODE_VPN_IP:-unknown}') — nothing to delete."
            log "  If one is orphaned, its name is the node's GUEST hostname, not the node id:"
            log "    kubectl exec -n $HS_NAMESPACE $HS_POD -- headscale nodes list"
        else
            for HID in $HS_IDS; do
                log "3/4 headscale: deleting machine entry id=$HID (node '$ID')…"
                # Report the OUTCOME only when something actually ran. run() returns 0 under
                # --dry-run without executing, so an unconditional `&& log "deleted"` claimed a
                # deletion that never happened — the one step whose dry-run output read as if
                # it had already taken effect.
                if run kubectl exec -n "$HS_NAMESPACE" "$HS_POD" -- \
                       headscale nodes delete --identifier "$HID" --force >/dev/null 2>&1; then
                    [ "$DRY_RUN" = 1 ] || log "  headscale entry $HID deleted."
                else
                    log "  WARNING: could not delete headscale entry $HID — delete via headplane."
                fi
            done
        fi
    fi
else
    log "3/4 headscale: skipped (cluster unreachable)."
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. Prune the 5 stale Pulumi state entries (create-only Commands: no delete on `up`)
# ═════════════════════════════════════════════════════════════════════════════
# skipcheck/fetch/detach/label are command:local:Command; provision is command:remote:Command.
log "4/4 pulumi state: pruning stale mesh command resources for '$ID'…"
for phase in skipcheck fetch detach label provision; do
    if [ "$phase" = "provision" ]; then KIND="command:remote:Command"; else KIND="command:local:Command"; fi
    URN="${STACK_URN_PREFIX}\$${KIND}::mesh-${phase}-${ID}"
    if [ "$DRY_RUN" = 1 ]; then
        echo "  DRY-RUN: pulumi state delete '$URN'" >&2
        continue
    fi
    # ⚠ Do NOT report every failure as "not in state". A resource that other resources
    # DEPEND ON fails with "Delete those resources first or pass --target-dependents", which
    # is a very different thing from being absent — and reporting it as absent leaves stale
    # command resources behind that the operator believes were pruned. The next `pulumi up`
    # then sees them and can try to reconcile a node that no longer exists.
    # 3 of the 5 resources reported "not in state" while present.
    # `ERR=$(...)` then `[ $? -eq 0 ]` would test the ASSIGNMENT, not pulumi. Capture the
    # status explicitly, and keep `set -e` from aborting on the expected failure.
    ERR=$(pulumi state delete "$URN" --yes 2>&1) && RC=0 || RC=$?
    if [ "$RC" -eq 0 ]; then
        log "  removed mesh-${phase}-${ID}."
    elif printf '%s' "$ERR" | grep -q 'target-dependents'; then
        if pulumi state delete "$URN" --target-dependents --yes >/dev/null 2>&1; then
            log "  removed mesh-${phase}-${ID} (with dependents)."
        else
            log "  WARNING: mesh-${phase}-${ID} is in state but could NOT be removed:"
            printf '%s\n' "$ERR" | sed 's/^/      /' >&2
        fi
    elif printf '%s' "$ERR" | grep -qiE 'no resource|not found|unknown resource'; then
        log "  (mesh-${phase}-${ID} not in state — skipped.)"
    else
        log "  WARNING: mesh-${phase}-${ID} delete failed:"
        printf '%s\n' "$ERR" | sed 's/^/      /' >&2
    fi
done

# Belt-and-braces: nothing carrying this id may survive in state, or a later `pulumi up`
# reconciles a node that is gone. Cheap to check, and the failure mode is silent otherwise.
if [ "$DRY_RUN" = 0 ]; then
    LEFT=$(pulumi stack --show-urns 2>/dev/null | grep -c "mesh-[a-z]*-${ID}\b" || true)
    if [ "${LEFT:-0}" -gt 0 ]; then
        log "  WARNING: $LEFT resource(s) matching '$ID' REMAIN in Pulumi state. Inspect with:"
        log "    pulumi stack --show-urns | grep $ID"
    else
        log "  pulumi state clean for '$ID'."
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. Optionally remove the node block from project_settings.ts
# ═════════════════════════════════════════════════════════════════════════════
if [ "$KEEP_CONFIG" = 0 ] && [ -n "$NODE_LINE" ]; then
    log "NOTE: '$ID' is still declared in project_settings.nodes.mesh[]."
    log "  Remove its block by hand and commit — the automated edit is intentionally NOT done"
    log "  (the mesh block is TS with comments/anchors; a scripted delete risks corrupting it)."
fi

echo ""
echo "=== '$ID' decommissioned. Verify: kubectl get nodes -o wide | grep -c $ID  (expect 0) ==="
[ -n "$NODE_LINE" ] && [ "$KEEP_CONFIG" = 0 ] && echo "    Remaining: remove the '$ID' block from project_settings.nodes.mesh[] and commit."
