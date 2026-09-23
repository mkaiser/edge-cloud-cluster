#!/bin/bash
# nsTerminationCleanup.sh — everything that unsticks namespace termination during a
# destroy/shutdown, in one place (replaces preDestroyCleanup.sh + forceFinalizeNamespaces.sh,
# which duplicated the APIService purge and the /finalize clear).
#
# Two modes, because the work happens at two different times:
#
#   pre                     One-shot, run BEFORE `pulumi destroy` while the apiserver is
#                           fully healthy. Strips the finalizers that would wedge
#                           namespaces later (ArgoCD applications, Longhorn CRs), purges
#                           stale APIServices, and finalizes anything already Terminating.
#
#   watch [dur] [interval]  Bounded polling loop, run IN THE BACKGROUND racing
#                           `pulumi destroy`. Namespaces enter Terminating only WHEN
#                           pulumi deletes them (minutes into the run) — the pre pass
#                           cannot catch them. Each poll re-purges APIServices that went
#                           Unavailable mid-destroy (NamespaceDeletionDiscoveryFailure
#                           blocks namespace GC) and force-finalizes any Terminating
#                           namespace via the /finalize subresource, unblocking pulumi's
#                           wait instead of letting it time out. Exits early once
#                           namespaces were seen Terminating and then drained; an empty
#                           FIRST poll means "not yet", not "done". Defaults: 300s / 10s.
#
# Both modes are best-effort and tolerant: apiserver unreachable ⇒ nothing to finalize,
# exit 0 (aborting the caller's destroy would be worse than skipping housekeeping).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="${1:-}"
if [[ "$MODE" != "pre" && "$MODE" != "watch" ]]; then
    echo "usage: $0 pre | watch [duration_seconds] [interval_seconds]" >&2
    exit 1
fi

# Every kubectl carries a hard --request-timeout. During a destroy the apiserver can
# vanish mid-run (the WG pod / VIP that carried it gets torn down) — WITHOUT a timeout
# a single `kubectl get ns` blocks forever and wedges the whole watch loop, so it never
# iterates to force-finalize the very namespaces it exists to unstick. A bounded timeout
# turns "API gone" into a fast failure the loop rides over (next poll / window elapse).
KUBECTL=(kubectl --request-timeout=10s)

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
    echo "  Apiserver unreachable — skipping namespace-termination cleanup (nothing to finalize)."
    exit 0
fi

# ── Shared: purge APIServices whose backends are gone ────────────────────────
# Unavailable aggregated APIServices block namespace garbage collection
# (NamespaceDeletionDiscoveryFailure); their endpoints disappear after drain and
# keep disappearing DURING the destroy, so both modes run this.
purge_stale_apiservices() {
    "${KUBECTL[@]}" get apiservice -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status!="True")) | .metadata.name' 2>/dev/null \
        | while read -r svc; do
            [[ -z "$svc" ]] && continue
            echo "    Deleting stale APIService: $svc"
            "${KUBECTL[@]}" delete apiservice "$svc" --ignore-not-found 2>/dev/null || true
          done
}

# ── Shared: force-finalize every namespace stuck in Terminating ──────────────
# Clears spec.finalizers via the /finalize subresource. Echoes each namespace it
# touches; prints nothing when none are Terminating. Sets FINALIZED_ANY=true when
# at least one namespace was handled (read by the watch loop's drain logic).
FINALIZED_ANY=false
finalize_terminating_namespaces() {
    local stuck ns
    stuck="$("${KUBECTL[@]}" get ns -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null)"
    [[ -z "$stuck" ]] && return 0
    FINALIZED_ANY=true
    for ns in $stuck; do
        echo "  Finalizing $ns..."
        "${KUBECTL[@]}" get ns "$ns" -o json 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
            | "${KUBECTL[@]}" replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    done
}

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "pre" ]]; then
    # Make ArgoCD stand down BEFORE touching any Application: terminate in-flight syncs,
    # disarm syncPolicy.automated, scale the controllers to zero. While the controllers
    # run they recreate children (apps-root → 19 apps) faster than we can delete them, so
    # the `delete --all` below never converges and blocks forever. See that script's
    # header for why the infra→apps ordering is load-bearing.
    bash "$REPO_ROOT/scripts/runtime/quiesceArgoCD.sh" \
        || echo "  WARNING: ArgoCD quiesce failed (continuing)."

    # Strip ArgoCD finalizers so the argocd namespaces don't hang in Terminating.
    # Two instances: apps (argocd-apps) is torn down first since it is a child of
    # the infra instance, then infra (argocd-infra).
    for ARGOCD_NS in argocd-apps argocd-infra; do
        if "${KUBECTL[@]}" get namespace "$ARGOCD_NS" >/dev/null 2>&1; then
            echo "  Stripping ArgoCD application finalizers in $ARGOCD_NS..."
            "${KUBECTL[@]}" get applications.argoproj.io -n "$ARGOCD_NS" -o name 2>/dev/null \
                | while read -r r; do
                    "${KUBECTL[@]}" patch "$r" -n "$ARGOCD_NS" --type=merge \
                        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
                  done
            # --wait=false: never block on objects going away (a live controller or a
            # stuck finalizer would hang this forever — it once sat here 80 min silently).
            # timeout + visible warning: a hang must be diagnosable, not look like progress.
            timeout 120 "${KUBECTL[@]}" delete applications.argoproj.io --all -n "$ARGOCD_NS" \
                --wait=false --ignore-not-found --force --grace-period=0 2>/dev/null \
                || echo "  WARNING: Application delete in $ARGOCD_NS timed out/failed (continuing)."
            # Jobs created as ArgoCD SYNC HOOKS carry argocd.argoproj.io/hook-finalizer.
            # Deleting the Applications above removes the only controller that would ever
            # clear it, so any leftover hook Job pins the namespace in Terminating forever.
            # A leftover barrier Job holds the namespace for the full 600s Pulumi timeout
            # and fails the destroy, with the reason visible only in
            #   kubectl get ns argocd-infra -o jsonpath='{.status.conditions}'
            #   -> NamespaceFinalizersRemaining: argocd.argoproj.io/hook-finalizer
            echo "  Stripping ArgoCD hook finalizers on Jobs in $ARGOCD_NS..."
            "${KUBECTL[@]}" get jobs -n "$ARGOCD_NS" -o name 2>/dev/null \
                | while read -r r; do
                    "${KUBECTL[@]}" patch "$r" -n "$ARGOCD_NS" --type=merge \
                        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                  done
            echo "  Done ($ARGOCD_NS)."
        fi
    done

    # Remove admission webhooks whose backend is already gone.
    #
    # A ValidatingWebhookConfiguration outlives the namespace that served it, and while it
    # exists the apiserver REJECTS every write to the resources it guards — including the
    # finalizer edits this script needs to make. Longhorn's is the killer: once
    # longhorn-system is deleted, ANY PVC write cluster-wide fails with
    #   failed calling webhook "validator.longhorn.io": no endpoints available
    # which then blocks kubernetes.io/pvc-protection from ever clearing, which pins whatever
    # namespace holds that PVC — e.g. argocd-infra cannot finish because its
    # argocd-helm-cache PVC cannot be patched.
    #
    # Deleting these is safe here by definition — we are tearing the cluster down, and a
    # webhook with no endpoints only ever returns errors.
    echo "  Removing orphaned admission webhook configurations..."
    for W in longhorn-webhook-validator longhorn-webhook-mutator; do
        "${KUBECTL[@]}" delete validatingwebhookconfiguration "$W" --ignore-not-found 2>/dev/null || true
        "${KUBECTL[@]}" delete mutatingwebhookconfiguration "$W" --ignore-not-found 2>/dev/null || true
    done

    # Strip Longhorn finalizers BEFORE its namespace is deleted. Longhorn CRs
    # (volumes/engines/replicas/instancemanagers/nodes/backuptargets/...) carry
    # finalizers serviced by longhorn-manager. Once the Longhorn pods are gone those
    # finalizers never clear and longhorn-system-ns hangs in Terminating forever.
    # Clear them while the apiserver is still up. Tolerant: no-op without the CRDs.
    # (pre-only: enumerating every Longhorn CR is too heavy to repeat each watch poll,
    # and the CRs exist only before the destroy starts deleting them.)
    echo "  Stripping Longhorn finalizers..."
    for CRD in $("${KUBECTL[@]}" get crd -o name 2>/dev/null | grep 'longhorn.io' || true); do
        KIND="${CRD#customresourcedefinition.apiextensions.k8s.io/}"
        "${KUBECTL[@]}" get "$KIND" -A -o json 2>/dev/null \
            | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
            | while read -r ns name; do
                [[ -z "$name" ]] && continue
                "${KUBECTL[@]}" patch "$KIND" "$name" -n "$ns" --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
              done
    done

    # Gateway API teardown. The GatewayClass carries
    # gateway-exists-finalizer.gateway.networking.k8s.io, which the Envoy Gateway
    # controller keeps in place for exactly as long as some Gateway still references
    # that class. `pulumi destroy` then sits on the GatewayClass for its full timeout
    # and fails; because it is a dependency root, everything behind it is never even
    # attempted — a teardown stops after a handful of resources with dozens left.
    #
    # ORDER MATTERS, and stripping alone is NOT enough. The Envoy Gateway controller is
    # still running here — quiesceArgoCD.sh scales down ArgoCD's controllers, not
    # envoy-gateway — so it simply RE-ADDS the finalizer to a still-referenced
    # GatewayClass the moment we clear it, so a strip-only version of this block silently
    # fails to prevent the deadlock.
    #
    # So: delete the referencing objects FIRST (routes, then Gateways) and let the
    # controller drop the finalizer on its own, which it does within a second or two.
    # The strip afterwards is the backstop for whatever the controller did not clear
    # (it is already gone, or the class is orphaned).
    echo "  Deleting Gateway API routes and Gateways..."
    # Routes first: a Gateway with attached routes can linger on its own finalizer.
    for RKIND in httproutes grpcroutes tcproutes udproutes tlsroutes; do
        "${KUBECTL[@]}" get "$RKIND.gateway.networking.k8s.io" -A >/dev/null 2>&1 || continue
        timeout 60 "${KUBECTL[@]}" delete "$RKIND.gateway.networking.k8s.io" --all -A \
            --wait=false --ignore-not-found 2>/dev/null || true
    done
    # Then the Gateways themselves — this is what releases gateway-exists-finalizer.
    if "${KUBECTL[@]}" get gateways.gateway.networking.k8s.io -A >/dev/null 2>&1; then
        timeout 60 "${KUBECTL[@]}" delete gateways.gateway.networking.k8s.io --all -A \
            --wait=false --ignore-not-found 2>/dev/null || true
        # Give the controller a moment to observe the deletions and release the class.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            REMAINING_GW="$("${KUBECTL[@]}" get gateways.gateway.networking.k8s.io -A \
                --no-headers 2>/dev/null | wc -l | tr -d ' ')"
            [[ "${REMAINING_GW:-0}" == "0" ]] && break
            sleep 2
        done
    fi

    echo "  Stripping Gateway API finalizers..."
    for CRD in $("${KUBECTL[@]}" get crd -o name 2>/dev/null \
                 | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io' || true); do
        KIND="${CRD#customresourcedefinition.apiextensions.k8s.io/}"
        "${KUBECTL[@]}" get "$KIND" -A -o json 2>/dev/null \
            | jq -r '.items[] | select(.metadata.finalizers != null)
                     | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
            | while read -r ns name; do
                [[ -z "$name" ]] && continue
                # Cluster-scoped kinds (GatewayClass) report a null namespace.
                if [[ "$ns" == "null" ]]; then
                    "${KUBECTL[@]}" patch "$KIND" "$name" --type=merge \
                        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
                else
                    "${KUBECTL[@]}" patch "$KIND" "$name" -n "$ns" --type=merge \
                        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
                fi
              done
    done

    echo "  Removing unavailable APIServices..."
    purge_stale_apiservices
    echo "  Force-finalizing Terminating namespaces..."
    finalize_terminating_namespaces
    echo "  Done."
    exit 0
fi

# ── watch mode ────────────────────────────────────────────────────────────────
DURATION="${2:-300}"
INTERVAL="${3:-10}"
END=$(( $(date +%s) + DURATION ))
echo "=== Force-finalizing Terminating namespaces (up to ${DURATION}s) ==="
# Only exit early AFTER at least one namespace was seen Terminating and then
# observed to drain; before that, keep polling the whole window (pulumi may not
# have reached the namespace deletes yet).
SEEN_ANY=false
while [[ $(date +%s) -lt $END ]]; do
    purge_stale_apiservices
    FINALIZED_ANY=false
    finalize_terminating_namespaces
    if [[ "$FINALIZED_ANY" == "true" ]]; then
        SEEN_ANY=true
    elif [[ "$SEEN_ANY" == "true" ]]; then
        echo "  All previously-Terminating namespaces drained — done."
        exit 0
    fi
    sleep "$INTERVAL"
done
echo "  Force-finalize window elapsed."
exit 0
