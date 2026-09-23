#!/bin/bash
# vpnReadyCheck.sh — sourceable helper defining vpn_ready_check().
#
# Mesh nodes join over the headscale VPN, which comes up a few minutes after bring-up.
# vpn_ready_check() returns 0 iff the VPN control-plane + subnet route + HTTP ingress are
# all serving. Shared by phase_offer_mesh_provision_auto_skip (poll after create) and provisionMeshNodes.sh
# (fail-fast preflight). Sourcing this file only DEFINES the function; it runs nothing.
#
# Requires REPO_ROOT to be set by the caller (both callers already set it).

# Prints diagnostics to stderr when VERBOSE=1; otherwise silent (for polling).
vpn_ready_check() {
    local tld sub headscale_url ns="headscale"
    # Read the general.{domain,subdomain} properties (there are no top-level consts).
    # First match wins (the general block precedes any other domain:/subdomain: property).
    tld=$(sed -n 's/^[[:space:]]*domain:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/project_settings.ts" | head -n1)
    sub=$(sed -n 's/^[[:space:]]*subdomain:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/project_settings.ts" | head -n1)
    if [ -z "$tld" ]; then
        [ "${VERBOSE:-}" = "1" ] && echo "ERROR: could not parse general.domain from $REPO_ROOT/project_settings.ts" >&2
        return 1
    fi
    headscale_url="https://vpn.${sub:+${sub}.}${tld}"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        [ "${VERBOSE:-}" = "1" ] && echo "ERROR: kubectl not connected. Run ./scripts/runtime/getKubeConfig.sh" >&2
        return 1
    fi
    # headscale pod Ready (controls the VPN control-plane).
    if ! kubectl get pods -n "$ns" -l app.kubernetes.io/name=headscale \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -q True; then
        [ "${VERBOSE:-}" = "1" ] && echo "ERROR: no Ready headscale pod in ns '$ns' — VPN control-plane not up yet." >&2
        return 1
    fi
    # mesh-gateway pod Ready (advertises the cluster subnet route over the VPN).
    if ! kubectl get pods -n "$ns" -l app=mesh-gateway \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -q True; then
        [ "${VERBOSE:-}" = "1" ] && echo "ERROR: no Ready mesh-gateway pod in ns '$ns' — VPN subnet route not advertised yet." >&2
        return 1
    fi
    # headscale HTTP endpoint serving (external ingress path the mesh nodes use).
    # -k: this check is about REACHABILITY, not trust — with certIssuerType
    # letsencrypt-staging the wildcard cert fails public verification (curl exit 60)
    # and without -k the preflight misreports a serving ingress as "not reachable".
    # The mesh nodes themselves import the staging CA in 30-connect-vpn.sh.
    if ! curl -fskS --max-time 10 "${headscale_url}/health" >/dev/null 2>&1; then
        [ "${VERBOSE:-}" = "1" ] && echo "ERROR: headscale HTTP endpoint ${headscale_url}/health not reachable — VPN ingress not ready." >&2
        return 1
    fi
    [ "${VERBOSE:-}" = "1" ] && echo "VPN preflight OK (headscale + mesh-gateway Ready, ${headscale_url} serving)."
    return 0
}
