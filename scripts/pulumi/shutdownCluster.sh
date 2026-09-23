#!/bin/bash
# Graceful cluster shutdown — preserves infrastructure and S3 data for later restore.
#
# Steps:
#   1. Set targetState=shutdown in project_settings.ts
#   2. pulumi up (sync the state to the stack)
#   3. Trigger on-demand etcd snapshot to S3
#   4. Trigger Longhorn S3 backup for all volumes
#   5. Drain and cordon all nodes
#   6. pulumi dn (destroys servers/DNS/network, keeps S3 buckets)
#      + Set targetState=restore in project_settings.ts — the state this leaves behind
#
# After this script: run 'make restore' to restore the cluster from S3 backup.
#
# Usage: shutdownCluster.sh [--force]
#   --force   skip the interactive confirmation (for unattended/detached runs)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/_common.sh"

# Trap D: gains the /tmp/passphrase fallback (was prompt-only) — unifies with the rest.
load_pulumi_passphrase

# --force: skip the interactive confirmation, for unattended runs (same flag name and
# behaviour as destroyCluster.sh). Every `pulumi up`/`pulumi dn` in here already passes -y,
# so this one prompt was the ONLY thing standing between this script and running detached —
# and a detached run without it dies instantly on the closed stdin (rc=2, duration=0s).
FORCE=false
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=true
done

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster Shutdown — infrastructure preserved, data backed up      ║"
echo "║  Run 'make restore' afterwards to restore from S3.                ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
if [[ "$FORCE" == "true" ]]; then
    echo "Auto-confirmed with --force flag."
else
    read -rp "Proceed with graceful shutdown? Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ── Step 1: reopen the public API BEFORE flipping the state ─────────────────────
# ⚠ ORDER IS LOAD-BEARING, and this must happen while targetState is still "production".
# The robot Commands' SSH host is targetState-gated (src/nodes-k3s-hetzner-robot.ts):
# "production" ⇒ privateIp over the admin WireGuard tunnel, anything else ⇒ publicIp. So the
# moment step 1a below sets "shutdown", pulumi switches to the PUBLIC ip — while the box is
# still hardened and public_guard is still dropping tcp/22. The `pulumi up` that would have
# reopened the port cannot itself get in: it can only open the door by going through it.
# Measured 2026-09-05 on ecc199, the first real run of this script: 10x
# `dial tcp <public>:22: i/o timeout`, rc=1, the stack left half-quiesced at targetState=shutdown.
# reopenRobotApi.sh tries the public IP first and falls back to privateIp over WireGuard, which
# is the path that still works here. Same helper, same gate and same reason as
# destroyCluster.sh — keep the two in step. Best-effort: a box that cannot be reopened will
# fail loudly in the apply below rather than silently skipping the shutdown.
# The gate is "not already open by construction" rather than == production: a RESUMED run
# (a previous attempt died after the flip) sits at targetState=shutdown with the box still
# hardened, and skipping the reopen there reproduces the exact failure this fixes.
if [[ "$(ps_target_state)" != "bootstrap" && "$(ps_target_state)" != "restore" ]]; then
    echo ""
    echo "=== reopening public 22/6443 before the state flip (posture: $(ps_target_state)) ==="
    bash "$SCRIPT_DIR/../runtime/reopenRobotApi.sh" \
        || echo "WARNING: robot API reopen failed (continuing)."
    bash "$SCRIPT_DIR/../runtime/reopenCloudApi.sh" \
        || echo "WARNING: hcloud API reopen failed (continuing)."
fi

# ── Step 1a: set targetState=shutdown ───────────────────────────────────────────
# ⚠ NOT "destroy": that value deletes the S3 buckets, which is exactly what a shutdown
# preserves for the later restore. "shutdown" keeps them and saves the TLS certs back to the
# stack, while still opening public 22/6443 so the drain/backup steps below can reach the API.
if [[ "$(ps_target_state)" != "shutdown" ]]; then
    echo ""
    ps_set_target_state shutdown
    echo "  Done."

    # ── Step 1b: pulumi up (sync the state to the stack) ────────────────────────────
    echo ""
    echo "=== Step 2/7: pulumi up (sync stack) ==="
    # ArgoCD may already own the `argocd` Helm release; refresh the latch so this sync does
    # not try to re-install it. Unlike destroy, shutdown keeps the data and the stack, so the
    # latch is deliberately NOT cleared afterwards — the release survives the shutdown.
    bash "$SCRIPT_DIR/argocdOwnershipLatch.sh" || true
    CI=true pulumi up -y --skip-preview
else
    echo "targetState already shutdown — no change needed."
fi


# ── Step 2b: reduce Longhorn replicas to 1 before backup ─────────────────────
# Ensures backups (and subsequent restores) never have stale multi-replica
# objects that over-schedule disk space on a single-node cluster.
echo ""
echo "=== Step 2b/7: Reduce Longhorn replicas to 1 ==="
echo "  Patching all volumes to numberOfReplicas=1..."
for v in $(kubectl get volumes.longhorn.io -n longhorn-system -o name 2>/dev/null); do
    kubectl -n longhorn-system patch "$v" --type=merge \
        -p '{"spec":{"numberOfReplicas":1}}' >/dev/null 2>&1 || true
done
echo "  Deleting extra replica objects..."
# ⚠ KEEP A RUNNING REPLICA, not whichever one the API happened to list first. This kept
# replicas[0] in dict order and deleted the rest, so on a volume whose first-listed replica
# was `stopped` it asked Longhorn to delete the only RUNNING copy — the validating webhook
# refused ("no other healthy replica available ... may still contain data for recovery"),
# which is Longhorn protecting the data, not a transient error.
# ⚠ And this step must never be fatal: it is a space optimisation before the backup, so
# aborting here skips the etcd snapshot and the Longhorn backup entirely — the very data the
# shutdown exists to preserve. Measured 2026-09-05 on ecc199: rc=123 from xargs under `set -e`,
# 87s in, with no backup taken at all.
kubectl get replicas.longhorn.io -n longhorn-system -o json 2>/dev/null | python3 -c "
import json, sys
from collections import defaultdict
raw = sys.stdin.read().strip()
# Empty stdin = unreachable API (already-torn-down cluster on a resumed run), not malformed
# data. Bail quietly instead of dumping a JSONDecodeError traceback into the log.
if not raw:
    sys.exit(0)
data = json.loads(raw)
by_vol = defaultdict(list)
for r in data['items']:
    by_vol[r['spec']['volumeName']].append(r)
for vol, replicas in by_vol.items():
    # Prefer a running replica as the survivor; fall back to the first if none is running.
    replicas.sort(key=lambda r: r.get('status', {}).get('currentState') != 'running')
    for extra in replicas[1:]:
        print(extra['metadata']['name'])
" | xargs -r kubectl delete replica.longhorn.io -n longhorn-system 2>&1 | tail -5 || true
echo "  Longhorn replicas reduced to 1 (best-effort)."

# ── Steps 3+4: etcd snapshot + Longhorn backup ────────────────────────────────
echo ""
echo "=== Steps 3-4/7: cluster backup (etcd + Longhorn) ==="
# ⚠ SKIP THE BACKUP IF THE CLUSTER IS ALREADY GONE, rather than failing on it. A RESUMED run
# (an earlier attempt backed up, drained and tore the cluster down, then died later) has no
# API to snapshot: `make backup` then dies on
#   "failed to download openapi ... dial tcp <vip>:6443: i/o timeout"
# and takes every remaining step with it, so the shutdown can never finish and targetState
# never reaches "restore". Measured 2026-09-05 on ecc199, attempt 4: rc=2 at step 3-4 with the
# real backup (107.9 MB etcd + 859.8 MiB Longhorn) already sitting in S3 from attempt 3.
# ⚠ This must stay a REACHABILITY test, never a "did we already back up" flag: on a normal run
# the cluster is up and the backup MUST happen — it is the whole point of a shutdown.
if kubectl cluster-info >/dev/null 2>&1; then
    make backup
else
    echo "  Cluster API unreachable — already torn down by an earlier pass; skipping backup."
    echo "  (A shutdown that never reached this point would have failed earlier, not here.)"
fi

# ── Step 5: drain all nodes ────────────────────────────────────────────────────
echo ""
echo "=== Step 5/7: Drain all cluster nodes ==="

# ⚠ Nothing to quiesce once the cluster is gone (resumed run). The individual kubectl calls
# below are all guarded, but the `jq` in the PDB pipeline still exits non-zero on empty input
# and `set -o pipefail` turns that into a fatal — so the whole block must be skipped, not
# merely tolerated. Measured 2026-09-05 on ecc199, attempt 5: rc=1 at "Disabling
# PodDisruptionBudgets" with the cluster already torn down by attempt 3.
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "  Cluster API unreachable — already drained/torn down by an earlier pass; skipping."
else

# Patch all PodDisruptionBudgets to minAvailable:0 so eviction isn't blocked
# when a replacement pod can't be scheduled on a cordoned node.
echo "  Disabling PodDisruptionBudgets cluster-wide..."
kubectl get pdb -A -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kubectl patch pdb "$name" -n "$ns" \
            --type=merge -p '{"spec":{"minAvailable":0,"maxUnavailable":null}}' \
            2>/dev/null || true
      done
echo "  Done."

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for NODE in $NODES; do
    echo "  Draining $NODE..."
    kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=300s \
        2>/dev/null \
    || kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --disable-eviction \
        --timeout=120s \
        2>/dev/null \
    || echo "  WARNING: drain failed for $NODE — continuing."
done
echo "  All nodes drained."

fi

# ── Step 6: pulumi dn (tears down servers, keeps S3 since teardown=false) ─────
echo ""
echo "=== Step 6/6: pulumi dn (destroy servers, DNS, network — S3 buckets preserved) ==="
# Delete DNSEndpoint CRDs first so external-dns can remove the records from
# Hetzner DNS before the pod is killed. Records created via DNSEndpoint are
# outside Pulumi state and won't be cleaned up by pulumi destroy otherwise.
# Only meaningful while the cluster still answers: external-dns is a POD, so with the API gone
# there is nothing to delete and nothing to confirm — waiting the full 120s would just stall a
# resumed run. (`pulumi dn` still removes the Pulumi-managed records either way.)
if kubectl cluster-info >/dev/null 2>&1; then
    echo "  Deleting DNSEndpoints so external-dns can clean up Hetzner DNS records..."
    kubectl delete dnsendpoint --all -A --ignore-not-found 2>/dev/null || true
    echo "  Waiting for external-dns to confirm cleanup (up to 120s)..."
    DEADLINE=$(($(date +%s) + 120))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns \
            --since=30s 2>/dev/null | grep -q "All changes applied"; then
            echo "  external-dns cleanup confirmed."
            break
        fi
        sleep 5
    done
    [ "$(date +%s)" -ge "$DEADLINE" ] && echo "  WARNING: timed out waiting for external-dns — continuing anyway."
else
    echo "  Cluster API unreachable — external-dns is gone; skipping DNSEndpoint cleanup."
fi

bash "$SCRIPT_DIR/nsTerminationCleanup.sh" pre

# One-shot re-run of the unified cleanup between destroy retries. Was an inline
# third copy of the APIService-purge + /finalize logic; `pre` mode covers both
# (and re-strips ArgoCD/Longhorn finalizers — often exactly why a pass failed).
_force_finalize_terminating_namespaces() {
    bash "$SCRIPT_DIR/nsTerminationCleanup.sh" pre
}

# ⚠ HELM RELEASES need their own state purge, and the Namespace sweeps do not cover them.
# `deleteUnreachable` (provider option AND PULUMI_K8S_DELETE_UNREACHABLE) rescues plain k8s
# resources — a StorageClass on an unreachable cluster is dropped from state fine — but the
# Helm provider must load the API SCHEMA before it can delete a Release, so with the nodes
# already gone it fails outright:
#   "can't delete Helm Release with unreachable cluster ... openapi/v2 ... i/o timeout"
# Once the cluster is deliberately gone (step 5 drained it, the servers are deleted) the
# Releases cannot be deleted for real, so dropping them from state is the only outcome.
#
# ⚠ THIS MUST RUN BEFORE EVERY PASS, NOT ONCE. Each `pulumi dn` RE-REGISTERS the Releases it
# could not delete, so a one-shot purge is undone by the very next pass. Measured 2026-09-05
# on ecc199: attempt 3 failed with 14 Releases; attempt 6 purged 7 of them mid-ladder and
# still exited rc=1 with the same names back in state.
_purge_helm_releases_if_cluster_gone() {
    kubectl cluster-info >/dev/null 2>&1 && return 0
    local urns
    urns=$(pulumi stack --show-urns 2>/dev/null | grep 'kubernetes:helm.sh/v3:Release' | grep -oP 'urn:[^\s]+' || true)
    [[ -z "$urns" ]] && return 0
    echo "  Cluster unreachable — removing Helm Release URNs from state (nothing to delete)..."
    while read -r urn; do
        [[ -z "$urn" ]] && continue
        echo "    Removing from state: $urn"
        pulumi state delete "$urn" --force 2>/dev/null || true
    done <<<"$urns"
}

_pulumi_destroy_with_retry() {
    _purge_helm_releases_if_cluster_gone
    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y && return 0

    echo "  First destroy pass failed — cleaning orphaned k8s namespace state and retrying..."
    _force_finalize_terminating_namespaces
    # Remove any namespace resources that errored because k8s already deleted them.
    pulumi stack --show-urns 2>/dev/null \
        | grep 'kubernetes:core/v1:Namespace' \
        | grep -oP 'urn:[^\s]+' \
        | while read -r urn; do
            ns_name=$(echo "$urn" | grep -oP '(?<=::)[^:]+$')
            if ! kubectl get ns "$ns_name" >/dev/null 2>&1; then
                echo "    Removing from state: $urn"
                pulumi state delete "$urn" --force 2>/dev/null || true
            fi
          done

    _purge_helm_releases_if_cluster_gone
    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y && return 0

    echo "  Second destroy pass failed — force-finalizing again and removing all stuck namespace URNs..."
    _force_finalize_terminating_namespaces
    pulumi stack --show-urns 2>/dev/null \
        | grep 'kubernetes:core/v1:Namespace' \
        | grep -oP 'urn:[^\s]+' \
        | while read -r urn; do
            ns_name=$(echo "$urn" | grep -oP '(?<=::)[^:]+$')
            kubectl get ns "$ns_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Terminating' \
                && { echo "    Removing stuck Terminating ns from state: $urn"; pulumi state delete "$urn" --force 2>/dev/null || true; } \
                || true
          done

    _purge_helm_releases_if_cluster_gone
    PULUMI_K8S_DELETE_UNREACHABLE=true pulumi dn -y
}
_pulumi_destroy_with_retry

# ── Step 6 (final): leave targetState=restore ──────────────────────────────────
echo ""
echo "=== Step 6 (final): Set targetState=restore ==="
ps_set_target_state restore
echo "  Done."

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Cluster shutdown complete.                                       ║"
echo "║                                                                   ║"
echo "║  Infrastructure preserved. Data backed up to S3.                  ║"
echo "║  To restore: commit project_settings.ts, then run 'make restore'  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
