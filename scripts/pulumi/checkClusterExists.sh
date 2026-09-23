#!/bin/bash
# Guard for `make bootstrap` / `make restore`: abort if a cluster already exists.
#
# Rationale: a fresh create bumps `robotForceReinstall` (phase_create in _lifecycle.sh), which
# rescue-boots + reinstalls the dedicated (robot) CP0 box, WIPING etcd/k3s. Running a
# fresh create against an already-running cluster therefore destroys it. This guard
# stops that before any pulumi config is mutated. (`make bootstrap` also uses it to
# DISPATCH: cluster exists → posture-reopen via pulumi up; absent → fresh create.)
#
# Detection (per project decision): the Pulumi stack `kubeconfig` output is the
# authoritative "a cluster was deployed" signal. Presence alone => treat as existing
# (strict). We do NOT require the API to be live, because by the time a botched create
# has reinstalled CP0 the API is already down — and we want to have aborted earlier.
#
# Override: set FORCE_CREATE=1 (or pass --force) to intentionally recreate/recover.
#
# Returns 0 if a cluster exists (and no override), 1 otherwise. Prints to stderr.

cluster_exists() {
    if [ "${FORCE_CREATE:-}" = "1" ]; then
        echo "FORCE_CREATE=1 set — skipping existing-cluster guard." >&2
        return 1
    fi

    local kc
    kc="$(pulumi stack output kubeconfig --show-secrets 2>/dev/null || true)"
    if [ -z "$kc" ]; then
        # No kubeconfig output => no cluster was deployed from this stack.
        return 1
    fi
    return 0
}
