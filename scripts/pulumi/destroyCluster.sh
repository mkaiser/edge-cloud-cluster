#!/bin/bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/_common.sh"

# ---------------------------------------------------------------------------
# Step 0: double confirmation (skip with --force)
# ---------------------------------------------------------------------------
FORCE=false
# ⚠ NOT folded into --force. An unattended teardown is exactly when nobody is watching for
# an unopenable sealed secret, so the sealed-key preflight needs its own explicit opt-out.
SKIP_SEALED_CHECK=false
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=true
    [[ "$arg" == "--skip-sealed-check" ]] && SKIP_SEALED_CHECK=true
done

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  WARNING: This will PERMANENTLY DESTROY the cluster               ║"
echo "║                                                                   ║"
echo "║  All Kubernetes resources, volumes, and S3 bucket contents        ║"
echo "║  will be deleted. This cannot be undone.                          ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FORCE" == "true" ]]; then
    echo "Auto-confirmed with --force flag."
else
    read -rp "Are you sure? Type 'yes' to continue: " confirm1
    [[ "$confirm1" == "yes" ]] || { echo "Aborted."; exit 0; }

    read -rp "This is irreversible. Type 'yes' again to proceed: " confirm2
    [[ "$confirm2" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Pulumi precondition check
# ---------------------------------------------------------------------------
# The caller must have logged in to the backend and selected the stack beforehand
# (e.g. `source ./scripts/pulumi/initPulumiStack.sh`). We do NOT log in or select a
# stack here — just verify one is selected. A wrong/missing PULUMI_CONFIG_PASSPHRASE
# is caught by the pulumi up/destroy steps below. </dev/null avoids any prompt.
if ! pulumi stack --show-name </dev/null &>/dev/null; then
    echo "ERROR: No Pulumi stack selected (or not logged in to the backend)."
    echo "       Select the stack first, e.g.:"
    echo "         source ./scripts/pulumi/initPulumiStack.sh"
    echo "         # or: pulumi login file://... && pulumi stack select <stack>"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 0.35: every SealedSecret must open with THIS stack's key — checked HERE,
# before anything is torn down
# ---------------------------------------------------------------------------
# src/sealedsecrets.ts seeds the next cluster's controller from the Pulumi
# sealedSecretsTlsCrt/Key, so a file sealed with any other certificate silently produces
# NO Secret over there and the app comes up without credentials.
#
# ⚠ THE POINT OF CHECKING IT BEFORE A DESTROY is that a mismatch is still REPAIRABLE
# WITHOUT LOSS while this cluster is up: the live Secret holds the plaintext, so the value
# can be read back and re-sealed with the right key. After the destroy the same finding is
# a forced rotation — you can only mint a new secret, and anything outside the cluster that
# knew the old one (an appliance account, a registry htpasswd someone configured by hand)
# is now out of step. Found on ecc193: three image-registry secrets were in exactly this
# state and nothing reported it.
#
# --skip-sealed-check exists for the case where you know the mismatch and are destroying
# anyway. It is deliberately NOT covered by --force: an unattended teardown is precisely
# when nobody is watching for this.
if [[ "$SKIP_SEALED_CHECK" == "true" ]]; then
    echo "Skipping the sealed-secret key check (--skip-sealed-check)."
else
    echo "Checking that every SealedSecret opens with this stack's key..."
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/../../deployment/checkSealedKeys.sh"; then
        echo ""
        echo "ERROR: refusing to destroy while sealed secrets cannot be opened with this" >&2
        echo "       stack's key — repair them NOW, while the values are still recoverable" >&2
        echo "       from the running cluster (see the message above), or re-run with" >&2
        echo "       --skip-sealed-check if you accept losing them." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 0.4: refuse to "destroy" a stack that holds no cluster
# ---------------------------------------------------------------------------
# Step 1 below sets targetState=destroy and runs a teardown-sync `pulumi up`
# to align the stack before destroying it. On an EMPTY stack that `pulumi up` has
# nothing to reconcile against, so it CREATES the whole infrastructure from scratch —
# observed: a second `make destroy` against an already-destroyed stack built 28
# resources (network, firewall, vSwitch, DNS records, S3 buckets) and rescue-wiped the
# robot box. A destroy must never create anything.
#
# cluster_exists() (checkClusterExists.sh) is the same predicate bootstrap.sh and
# phase_create use: the stack's `kubeconfig` output is the authoritative "a cluster was
# deployed" signal. Must run BEFORE Step 0.5 so an empty-stack destroy touches nothing
# at all — no pulumi config writes, no firewall reopen, no rescue boot, no DNS writes.
#
# FORCE_CREATE is cleared for this call: that variable is bootstrap's guard-skip, and a
# leftover export in the caller's shell must not silently disable this one.
# FORCE_DESTROY=1 is the escape hatch for tearing down orphaned non-cluster resources
# (buckets/DNS/network) that remain in a stack with no kubeconfig.
source "$THIS_DIR/checkClusterExists.sh"
if [[ "${FORCE_DESTROY:-}" != "1" ]] && ! FORCE_CREATE= cluster_exists; then
    echo ""
    echo "=== no cluster in this stack — nothing to destroy ==="
    echo "  Stack '$(pulumi stack --show-name 2>/dev/null)' has no kubeconfig output."
    echo "  Nothing was created or changed."
    echo ""
    echo "  If the stack still holds orphaned non-cluster resources (S3 buckets, DNS"
    echo "  records, network) and you want them torn down anyway:"
    echo "      FORCE_DESTROY=1 make destroy ARGS=--force"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 0.5: in Production, reopen public 22/6443 so pulumi can reach the API
# ---------------------------------------------------------------------------
# The teardown-sync `pulumi up` (Step 1), `pulumi destroy`, and the destroy scripts' kubectl
# all reach the k3s API on the box's PUBLIC IP. In Production public 6443 is dropped — on
# ROBOT boxes by the host public_guard nft table, on HCLOUD VMs by the hcloud Cloud Firewall —
# so the API is unreachable, pulumi refuses to delete Helm Releases (unreachable cluster), and
# the destroy stalls. Reopen 22/6443 on BOTH enforcement layers BEFORE any step needs the API;
# each helper no-ops when its node type is absent. Bootstrap already has these open ⇒ the whole
# step is skipped (gate on targetState). Best-effort: firewall + box are deleted in the destroy
# anyway (robot box is also rescue-wiped at the tail), so the reopened rules are transient.
if [[ "$(ps_target_state)" == "production" ]]; then
    echo ""
    echo "=== production posture: reopening public 22/6443 so pulumi can reach the k3s API ==="
    bash "$THIS_DIR/../runtime/reopenRobotApi.sh" \
        || echo "WARNING: robot API reopen failed (continuing)."
    bash "$THIS_DIR/../runtime/reopenCloudApi.sh" \
        || echo "WARNING: hcloud API reopen failed (continuing; destroy may stall if the API stays unreachable)."
fi

# Pin the stable admin API hostname (network.apiServerHost — the Pulumi provider's kubeconfig
# endpoint) to the init CP's PUBLIC IP for the whole teardown: `pulumi destroy` deletes the
# in-cluster wireguard pod EARLY, severing the WG/VIP path mid-run. The public path (just
# reopened above in Production; already open in Bootstrap) survives until the node itself is
# deleted last. Best-effort, like the reopen.
bash "$THIS_DIR/../runtime/setKubeApiHost.sh" --public \
    || echo "WARNING: could not pin the admin API hostname to the public IP (continuing)."

# ---------------------------------------------------------------------------
# Step 0.6: point ambient kubectl (~/.kube/config) at the box PUBLIC API
# ---------------------------------------------------------------------------
# The exported kubeconfig (what getKubeConfig.sh writes to ~/.kube/config) points at the
# kube-vip VIP, reached over the admin WireGuard tunnel via the IN-CLUSTER wireguard pod.
# `pulumi destroy` deletes that pod EARLY, so any shell kubectl in this destroy (notably
# nsTerminationCleanup.sh, which force-finalizes stuck namespaces) would then block on an
# unreachable API and the teardown wedges. Re-fetch the init-CP kubeconfig with the server
# set to the box's OWN PUBLIC IP — a direct path that survives until the node itself is
# deleted (last). Best-effort like every other pre-destroy step. (The pulumi PROVIDER is
# repointed separately: select-kubeconfig prefers public when targetState=destroy.)
INIT_CP_PUB=$(ps_node_field 'clusterLink:\s*"init"' publicIp)
if [[ -n "$INIT_CP_PUB" ]]; then
    echo ""
    echo "=== Repointing ~/.kube/config at the init-CP public API ($INIT_CP_PUB:6443) for destroy ==="
    source "$THIS_DIR/sshAgentHelpers.sh"
    ensure_node_ssh_keys_in_agent >/dev/null 2>&1 || true
    KC_PATH="${KUBECONFIG:-$HOME/.kube/config}"
    mkdir -p "$(dirname "$KC_PATH")"
    if ssh -T -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null "root@$INIT_CP_PUB" 'cat /etc/rancher/k3s/k3s.yaml' 2>/dev/null \
            | sed "s|https://127.0.0.1:6443|https://$INIT_CP_PUB:6443|g" > "$KC_PATH.destroy.tmp" \
        && [[ -s "$KC_PATH.destroy.tmp" ]]; then
        mv "$KC_PATH.destroy.tmp" "$KC_PATH"
        echo "  ~/.kube/config now targets $INIT_CP_PUB:6443 (WG-independent)."
    else
        rm -f "$KC_PATH.destroy.tmp"
        echo "  WARNING: could not fetch public kubeconfig from $INIT_CP_PUB (continuing with existing ~/.kube/config)."
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: ensure targetState=destroy
# ---------------------------------------------------------------------------

echo "Checking project_settings targetState"
echo ""

if [[ "$(ps_target_state)" != "destroy" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        echo "Auto-setting targetState: destroy and syncing the stack (--force)."
    else
        read -rp "Changing targetState: destroy and run 'make up' to update the stack now? [y/n]: " change_answer
        if [[ ! "$change_answer" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    ps_set_target_state destroy
    echo "Set targetState=destroy — running pulumi up to sync stack..."
    # The cluster is still up here and ArgoCD may already own the `argocd` Helm release, so
    # refresh the ownership latch before this sync — otherwise it re-creates the Release and
    # fails "cannot re-use a name that is still in use" before anything is torn down. The
    # --clear at the end of this script is what turns it off, after the cluster is gone.
    bash "$THIS_DIR/argocdOwnershipLatch.sh" || true
    # --refresh: reconcile state against reality FIRST. Without it this `up` acts on a
    # possibly-stale state file and can (re)create resources that no longer exist — the
    # failure mode Step 0.4 guards against. Cheap insurance on a path whose whole job is
    # to align the stack immediately before deleting it.
    CI=true pulumi up -y --skip-preview --refresh
    echo "Stack synced."

fi

# ---------------------------------------------------------------------------
# Clean on-premise mesh nodes BEFORE destroy (apiserver + VPN still up)
# ---------------------------------------------------------------------------
# Mesh nodes are SSH-provisioned in place, NOT hcloud/robot resources, so pulumi destroy
# never touches them — they keep a half-joined k3s-agent + tailscaled beaconing the dead
# cluster (an IDS may blackhole the host, breaking the next provision). Run this BEFORE
# destroy so we can (a) query the live cluster to clean only mesh nodes actually joined,
# and (b) reach VPN-only home nodes while the mesh is still up. Tolerant: never fatal.
echo ""
echo "=== Cleaning joined on-premise mesh nodes (clean rejoin on next provision-mesh-node) ==="
bash "$THIS_DIR/cleanupMeshNodes.sh" || echo "WARNING: mesh cleanup step failed (continuing)."

# ---------------------------------------------------------------------------
# Pre-destroy cleanup
# ---------------------------------------------------------------------------
bash "$THIS_DIR/nsTerminationCleanup.sh" pre

# ---------------------------------------------------------------------------
# Pulumi destroy
# ---------------------------------------------------------------------------
# NOTE: pulumi destroy can exit nonzero even on a fully successful teardown — a
# single tolerant `local:Command` delete that logs an error-level diagnostic taints
# the run's exit code while the resource is still marked deleted ("N deleted"). So we
# do NOT treat a nonzero exit as fatal by itself; instead we check whether the stack
# actually emptied. Aborting on the raw exit code here skipped the critical
# post-destroy tail (robot rescue + resetting targetState) on a destroy
# that had in fact succeeded.
# Namespaces (argocd-*, longhorn-system-ns, ...) enter Terminating only WHEN pulumi
# deletes them, and then stick (stale aggregated APIServices + leftover finalizers as
# the control plane is torn down in parallel), making pulumi time out. Run a
# force-finalize loop in the BACKGROUND so it races pulumi's namespace-delete wait and
# unblocks it instead of letting it time out. Tolerant; self-exits when none remain.
bash "$THIS_DIR/nsTerminationCleanup.sh" watch 1800 10 &
FINALIZE_PID=$!

CI=true PULUMI_K8S_DELETE_UNREACHABLE=true timeout --foreground 1800 pulumi destroy -y --parallel 20 \
    || echo "WARNING: pulumi destroy returned nonzero (exit $?) — verifying stack emptied below."

kill "$FINALIZE_PID" 2>/dev/null || true
wait "$FINALIZE_PID" 2>/dev/null || true

REMAINING="$(pulumi stack --show-urns 2>/dev/null | grep -c 'urn:pulumi:' || true)"
if [[ "${REMAINING:-0}" -gt 0 ]]; then
    echo "ERROR: pulumi destroy left $REMAINING resource(s) in the stack — aborting before post-destroy cleanup."
    exit 1
fi
echo "Stack emptied (0 resources) — proceeding with post-destroy cleanup."

# ---------------------------------------------------------------------------
# Clean up external-dns managed DNS records (not tracked in Pulumi state)
# ---------------------------------------------------------------------------
# Forward --force so `make destroy ARGS=--force` stays unattended from a real
# terminal too (the script only auto-confirms on its own when stdin is not a
# TTY). Best-effort like every other post-destroy step: a DNS API hiccup must
# not abort the tail below (robot rescue + targetState reset).
if [[ "$FORCE" == "true" ]]; then
    "$THIS_DIR/../environment/cleanExternalDnsRecords.sh" --force \
        || echo "WARNING: external-dns record cleanup failed (continuing)."
else
    "$THIS_DIR/../environment/cleanExternalDnsRecords.sh" \
        || echo "WARNING: external-dns record cleanup skipped/failed (continuing)."
fi

# ---------------------------------------------------------------------------
# Boot Robot/dedicated nodes back into rescue so the next create reinstalls cleanly
# ---------------------------------------------------------------------------
# ⚠ THIS RUNS BEFORE THE BUCKET WIPE, DELIBERATELY. `pulumi destroy` frees the hcloud-side
# resources but does NOT wipe the physical robot disk, so the box is still up and still
# running the old k3s at this point. Deleting the buckets first left a window with live
# workloads whose only remaining copy of their data had just been deleted — and they can
# still be writing to a bucket that no longer exists. Stop the writers first: rescue-booting
# guarantees nothing is running that could touch S3, and it makes the irreversible step
# (bucket deletion) the LAST thing the teardown does. A rescue failure then still leaves the
# buckets intact, which is the recoverable direction; the reverse order does not.
#
# The wipe itself matters because old k3s + namespaces on that disk would make the next
# `make bootstrap` skip the (marker-guarded) installimage and collide on existing
# namespaces. No-op when there are no robot nodes.
echo ""
echo "=== Booting Robot/dedicated nodes into rescue (clean reinstall on next create) ==="
bash "$THIS_DIR/rescueRobotNodes.sh" || echo "WARNING: robot rescue step failed (continuing)."

# ---------------------------------------------------------------------------
# Delete S3 buckets (including ArgoCD-owned app buckets not managed by Pulumi)
# ---------------------------------------------------------------------------
# Runs AFTER pulumi destroy AND after the rescue wipe above (see the ⚠ there): Pulumi
# already removed its own buckets, so this wipes whatever remains (e.g. zulip app buckets
# + any orphans). This is the irreversible step, so it goes last. With --force, delete
# every remaining bucket without prompting; otherwise go interactive.
echo ""
echo "=== Deleting remaining S3 buckets ==="
if [[ "$FORCE" == "true" ]]; then
    bash "$THIS_DIR/../environment/deleteS3Buckets.sh" --all-yes \
        || echo "WARNING: S3 bucket wipe failed (continuing)."
else
    bash "$THIS_DIR/../environment/deleteS3Buckets.sh" \
        || echo "WARNING: S3 bucket cleanup skipped/failed (continuing)."
fi

# ---------------------------------------------------------------------------
# Leave targetState at the harmless bring-up value, so a later `make up` can never inherit
# "destroy" and delete the S3 buckets by accident.
# ---------------------------------------------------------------------------
echo "Setting targetState back to bootstrap to prevent an accidental teardown later..."
ps_set_target_state bootstrap

# ---------------------------------------------------------------------------
# Reset meshVpnReady=false so the persisted config is HONEST after destroy (no cluster ⇒ nothing
# provisioned ⇒ the mesh gate is off). This is hygiene, NOT the authority: phase_create resets it
# again at the start of every fresh create/restore (crash-safe — a failed/skipped destroy must not
# strand it true, which would fire MeshNodesComponent SSH during bring-up before the VPN is up).
# ---------------------------------------------------------------------------
echo "Setting meshVpnReady back to false (no cluster ⇒ mesh-node provisioning gate off)..."
pulumi config set meshVpnReady false

# Same hygiene for the ArgoCD ownership latch: no cluster ⇒ no Helm release ⇒ Pulumi owns the
# next one. phase_create clears it again on every fresh create, so this is not the authority —
# but leaving it true here would misreport a destroyed stack as self-managed.
bash "$THIS_DIR/argocdOwnershipLatch.sh" --clear