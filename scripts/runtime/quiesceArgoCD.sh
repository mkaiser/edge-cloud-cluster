#!/bin/bash
# quiesceArgoCD.sh — make both ArgoCD instances stand down, without destroying them.
#
# WHY: during a teardown the ArgoCD controllers fight back. `kubectl delete applications
# --all` never converges because apps-root recreates its 19 children faster than they are
# deleted — observed as an 80-minute silent hang in `make destroy` that looked exactly
# like slow progress. Deleting Applications while their controllers run cannot work.
#
# "Quiesce", not "terminate": Applications, CRDs and Helm releases all survive. The
# controllers are scaled to zero and can be scaled back up; nothing here is destructive
# to cluster data. Safe to run against a live cluster to freeze GitOps for debugging
# (re-arm by scaling the controllers back and re-adding syncPolicy.automated, or just
# let ArgoCD re-sync itself from git).
#
# Three phases, and the ORDER IS LOAD-BEARING:
#
#   1. Terminate in-flight sync operations. A sync already running keeps going no matter
#      what the sync policy says; setting status.operationState.phase=Terminating is what
#      `argocd app terminate-op` does and makes the sync worker wind down
#      (argo-cd controller/appcontroller.go: "SyncAppState will operate in a Terminating
#      phase, allowing the worker to perform"). Do this FIRST — before the controllers
#      are gone, since a scaled-down controller can no longer act on the phase change.
#
#   2. Strip spec.syncPolicy.automated. Disarms auto-sync, selfHeal and prune while
#      leaving the Application registered. 27 of 33 infra Applications carry
#      selfHeal:true, so this matters cluster-wide, not just for argocd-apps.
#      (A deny AppProject sync-window does NOT substitute: CanSync() gates autoSync only
#      — appcontroller.go:1970 — and does not stop a child Application being recreated.)
#
#   3. Scale the reconcilers to zero. The argocd-apps INSTANCE is itself deployed by an
#      Application living in argocd-infra (deployment/argocd-infra/app-of-apps/
#      wave19-argocd-apps.yaml), so scaling argocd-apps down first is useless — infra
#      immediately re-applies its StatefulSet back to replicas>0. Stop infra's controller,
#      delete that Application, THEN stop the apps controller.
#
# Tolerant by design: every step is best-effort and an unreachable apiserver is a clean
# exit 0. Failing here would abort a teardown, which is worse than skipping housekeeping.
#
# Usage:  bash scripts/runtime/quiesceArgoCD.sh
# Called by: scripts/pulumi/nsTerminationCleanup.sh (pre mode), before finalizer stripping.
set -uo pipefail

INFRA_NS="${INFRA_NS:-argocd-infra}"
APPS_NS="${APPS_NS:-argocd-apps}"

# Hard --request-timeout on every call: during a teardown the apiserver can vanish
# mid-run, and an unbounded kubectl would block forever and wedge the caller.
KUBECTL=(kubectl --request-timeout=10s)

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
    echo "  Apiserver unreachable — skipping ArgoCD quiesce (nothing to stand down)."
    exit 0
fi

echo "=== Quiescing ArgoCD (in-flight ops → sync policy → controllers) ==="

# ── 1. Terminate in-flight sync operations ───────────────────────────────────
# Only apps whose operation is actually Running; patching a finished/absent operation
# is a no-op at best and noise at worst. Uses the status subresource.
for NS in "$APPS_NS" "$INFRA_NS"; do
    "${KUBECTL[@]}" get namespace "$NS" >/dev/null 2>&1 || continue
    RUNNING="$("${KUBECTL[@]}" get applications.argoproj.io -n "$NS" -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.operationState.phase == "Running") | .metadata.name' 2>/dev/null)"
    [[ -z "$RUNNING" ]] && continue
    echo "  Terminating in-flight syncs in $NS: $(echo "$RUNNING" | tr '\n' ' ')"
    for APP in $RUNNING; do
        "${KUBECTL[@]}" patch applications.argoproj.io "$APP" -n "$NS" \
            --subresource=status --type=merge \
            -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null 2>&1 \
            || echo "    WARNING: could not terminate operation on $APP (continuing)."
    done
done

# ── 2. Disarm auto-sync / selfHeal / prune ───────────────────────────────────
for NS in "$APPS_NS" "$INFRA_NS"; do
    "${KUBECTL[@]}" get namespace "$NS" >/dev/null 2>&1 || continue
    echo "  Stripping syncPolicy.automated in $NS..."
    "${KUBECTL[@]}" get applications.argoproj.io -n "$NS" -o name 2>/dev/null \
        | while read -r APP; do
            "${KUBECTL[@]}" patch "$APP" -n "$NS" --type=merge \
                -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
          done
done

# ── 3. Stop the reconcilers (order matters — see header) ─────────────────────
echo "  Scaling ArgoCD controllers to zero..."
"${KUBECTL[@]}" -n "$INFRA_NS" scale \
    statefulset/argocd-application-controller \
    deployment/argocd-applicationset-controller \
    --replicas=0 --timeout=60s 2>/dev/null || true

# Break the parent→child link while nothing in infra can re-apply it.
"${KUBECTL[@]}" -n "$INFRA_NS" delete applications.argoproj.io argocd-apps \
    --wait=false --ignore-not-found 2>/dev/null || true

"${KUBECTL[@]}" -n "$APPS_NS" scale \
    statefulset/argocd-apps-application-controller \
    deployment/argocd-apps-applicationset-controller \
    --replicas=0 --timeout=60s 2>/dev/null || true

echo "=== ArgoCD quiesced. ==="
exit 0
