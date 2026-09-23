#!/bin/bash
# argocdOwnershipLatch.sh — set the durable `argocdSelfManaged` Pulumi-config latch once the
# infra ArgoCD has taken over its own Helm release from Pulumi.
#
# WHY A LATCH AND NOT A PROBE: the handoff is IRREVERSIBLE and asymmetric. On the handoff run
# Pulumi drops `Release argocd` from state while `retainOnDelete: true` keeps the live release
# running. From then on, constructing the Release again means `helm install` over a live
# release, which fails hard:
#
#     kubernetes:helm.sh/v3:Release (argocd): cannot re-use a name that is still in use
#
# src/argocd.ts used to decide this per-process with a fail-open `kubectl` probe of
# `argocd-infra-self`'s sync status (any error → "bootstrap it"). `make bootstrap --complete`
# runs THREE `pulumi up` passes, and pass 3 (mesh provisioning) begins seconds after
# production hardening rewrites ~/.kube/config and re-pins the API endpoint from the public IP
# to the private VIP. A single transient in that window flips the answer back to false and
# pass 3 tries to re-install the release pass 2 just handed over. Measured 2026-09-04 on
# ecc197: pass 2 logged `Release argocd deleted[retain]`, pass 3 failed with the error above.
#
# So ownership is recorded ONCE, in the stack config, and the program only ever reads it.
#
# Usage:
#   argocdOwnershipLatch.sh            # set the latch iff the handoff is confirmed (default)
#   argocdOwnershipLatch.sh --check    # report only, change nothing (exit 0 = latched)
#   argocdOwnershipLatch.sh --clear    # force the latch off (destroy: no cluster ⇒ no release)
#
# Idempotent. NEVER fatal on an unreachable cluster: if it cannot confirm the handoff it
# leaves the latch alone and exits 0, because "could not tell" must not flip a set latch off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/_common.sh"
init_pulumi

MODE="${1:-set}"

current_latch() {
    pulumi config get argocdSelfManaged 2>/dev/null || echo "false"
}

if [ "$MODE" = "--clear" ]; then
    echo "ArgoCD ownership latch: clearing (argocdSelfManaged=false) — Pulumi owns the release again."
    pulumi config set argocdSelfManaged false
    exit 0
fi

LATCHED="$(current_latch)"

if [ "$MODE" = "--check" ]; then
    echo "argocdSelfManaged=$LATCHED"
    [ "$LATCHED" = "true" ]
    exit $?
fi

# Already latched: nothing to confirm, and re-probing could only introduce a wrong answer.
if [ "$LATCHED" = "true" ]; then
    echo "ArgoCD ownership latch: already set (argocdSelfManaged=true) — nothing to do."
    exit 0
fi

# ── Confirm the handoff from DURABLE evidence, both halves required ─────────────────────
# 1. `argocd-infra-self` exists and is Synced → ArgoCD is reconciling the release.
# 2. A Helm release secret `sh.helm.release.v1.argocd.*` exists → there IS a live release for
#    it to own (so a Pulumi create would collide rather than bootstrap).
# Requiring both means a half-built cluster (app present, release never installed) is NOT
# latched, and neither is a cluster we simply cannot reach.
#
# ⚠ RETRY, do not single-shot. This script is called right after the API endpoint is re-pinned
# (public IP → private VIP) and the kubeconfig rewritten, which is exactly when a first
# kubectl call can fail on a cold WireGuard route. Observed while testing this script: the
# first `get application` returned nothing and the immediate retry returned `Synced`. A
# single-shot check would just fail safe (latch left off) and defer the collision to the next
# pass, so retry until the cluster answers.
KUBECTL=(kubectl --kubeconfig "${HOME}/.kube/config")

SYNC=""
RELEASES="0"
for attempt in 1 2 3 4 5; do
    SYNC="$("${KUBECTL[@]}" get application argocd-infra-self -n argocd-infra \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    RELEASES="$("${KUBECTL[@]}" get secret -n argocd-infra \
        -l 'owner=helm,name=argocd' -o name 2>/dev/null | wc -l | tr -d ' ')"
    [ "$SYNC" = "Synced" ] && [ "$RELEASES" != "0" ] && break
    [ "$attempt" = "5" ] && break
    echo "  ArgoCD ownership latch: cluster not answering conclusively" \
        "(sync='${SYNC:-<none>}' releases=$RELEASES) — retry $attempt/4 in 5s…" >&2
    sleep 5
done

if [ "$SYNC" != "Synced" ]; then
    echo "ArgoCD ownership latch: NOT set — 'argocd-infra-self' is '${SYNC:-<absent/unreachable>}'," \
        "not 'Synced'. Pulumi keeps owning the release; re-run after ArgoCD syncs it." >&2
    exit 0
fi

if [ "$RELEASES" = "0" ]; then
    echo "ArgoCD ownership latch: NOT set — 'argocd-infra-self' is Synced but no Helm release" \
        "secret (sh.helm.release.v1.argocd.*) exists in argocd-infra, so there is nothing for" \
        "it to own yet. Pulumi keeps owning the release." >&2
    exit 0
fi

echo "ArgoCD ownership latch: handoff confirmed ('argocd-infra-self' Synced + live Helm release)."
echo "Setting argocdSelfManaged=true — Pulumi will no longer construct the 'argocd' Release."
pulumi config set argocdSelfManaged true
