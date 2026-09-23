#!/usr/bin/env bash

set -euo pipefail

# TTY-guarded ANSI color (empty when not a terminal / piped to a log).
if [ -t 1 ]; then YEL=$'\033[33m'; RST=$'\033[0m'; else YEL=''; RST=''; fi

# Logs the argocd CLI into one of the two ArgoCD instances as a named context.
#
# ⚠ KNOWN BROKEN on ecc217 (2026-09-23), BOTH paths, and it is the CLI, not the cluster.
# Measured, in case someone re-derives this:
#   - the public host answers plain HTTPS 200 and a REAL grpc-web SessionService/Create over
#     it returns a valid JWT (curl, 47 ms). Server, HTTPRoute and Gateway are all fine.
#   - the Gateway offers ALPN "http/1.1" ONLY — no h2. Native gRPC therefore cannot connect,
#     and an h2c prior-knowledge request against the port-forward fails too (curl ver=0),
#     which is what resets the pod connection and kills the forward.
#   - `argocd login --grpc-web` still dies with "gRPC connection not ready: context deadline
#     exceeded" after exactly 30 s (its dial deadline) against BOTH instances, with a FRESH
#     CLI config, on CLI v3.4.2 AND v3.5.3. So --grpc-web is not taking effect at dial time.
# What does work today: the REST API (scripts/runtime/argocdMcpToken.sh uses it), kubectl,
# and the argocd-mcp MCP server. Prefer those until this is root-caused upstream.
#   ./argocdLoginCLI.sh [infra|apps]   (default: infra)
# Run twice (infra, then apps) to get two contexts; `argocd context <host>`
# switches between them. Both instances share the same admin password hash.
INSTANCE="${1:-infra}"
case "$INSTANCE" in
    infra)
        STACK_OUTPUT="argocdURL"
        ARGOCD_NS="argocd-infra"
        ARGOCD_DEPLOYMENT="argocd-server"
        ARGOCD_SVC="argocd-server"
        PF_PORT=18080
        ;;
    apps)
        STACK_OUTPUT="argocdAppsURL"
        ARGOCD_NS="argocd-apps"
        ARGOCD_DEPLOYMENT="argocd-apps-server"
        ARGOCD_SVC="argocd-apps-server"
        PF_PORT=18081
        ;;
    *)
        echo "Usage: $0 [infra|apps]   (default: infra)"
        exit 1
        ;;
esac
echo "ArgoCD instance: $INSTANCE (namespace $ARGOCD_NS, stack output $STACK_OUTPUT)"

if ! argocd_url=$(pulumi stack output "$STACK_OUTPUT" --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi stack output '$STACK_OUTPUT'."
    echo "Ensure Pulumi config secrets are unlocked (for example: source ./scripts/pulumi/initPulumiStack.sh)."
    exit 1
fi
echo -e "ArgoCD URL from Pulumi stack output: $argocd_url"

cert_issuer_type=$(pulumi stack output certIssuerType --non-interactive 2>/dev/null || true)
if [ -z "$argocd_url" ]; then
    echo "Pulumi stack output '$STACK_OUTPUT' is empty. Is ArgoCD enabled and deployed?"
    exit 1
fi
argocd_host=$(printf '%s' "$argocd_url" | sed -E 's#^https?://##; s#/.*$##')
echo -e "certissuer type from Pulumi stack output: $cert_issuer_type"

if [ "$argocd_url" = "ArgoCD disabled" ]; then
    echo "ArgoCD is disabled (stack output '$STACK_OUTPUT' is 'ArgoCD disabled')."
    exit 1
fi

echo "Waiting for ArgoCD server pod to be ready... (timeout 5min)"
kubectl rollout status "deployment/${ARGOCD_DEPLOYMENT}" -n "$ARGOCD_NS" --timeout=5m

curl_tls_flags=()
# Let's Encrypt staging chains can be untrusted in local/system trust stores.
if [ "$cert_issuer_type" = "letsencrypt-staging" ]; then
    curl_tls_flags+=("-k")
elif [ -z "$cert_issuer_type" ]; then
    echo "Warning: Pulumi stack output 'certIssuerType' is empty; probing TLS behavior."
fi

if [ ${#curl_tls_flags[@]} -eq 0 ]; then
    if ! curl -sf --max-time 10 "$argocd_url/healthz" > /dev/null 2>&1; then
        probe_rc=$?
        if [ "$probe_rc" -eq 60 ]; then
            echo "TLS verification failed for $argocd_url; using --insecure for health checks."
            curl_tls_flags+=("-k")
        fi
    fi
fi

dns_wait_min=0
timeout_min=2
echo -n "${YEL}Waiting for DNS resolution of $argocd_host (timeout: $timeout_min minutes). "
echo "Sometimes this works instantly, sometimes never... It is an devContainer / DNS proxy issue. Don't know why. ${RST}"
until nslookup "$argocd_host" >/dev/null 2>&1; do
    dns_wait_min=$((dns_wait_min + 1))
    if [ "$dns_wait_min" -ge $timeout_min ]; then
        echo ""
        echo "ERROR: $argocd_host still not resolvable after $timeout_min minutes — check external-dns and DNS TTL."
        break
    fi
    printf "."
    sleep 60
done

if ! argocd_admin_password=$(pulumi config get argocdAdminPasswordPlain --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi config 'argocdAdminPasswordPlain'."
    echo "Ensure Pulumi config secrets are unlocked (for example: source ./scripts/pulumi/initPulumiStack.sh)."
    exit 1
fi


login_tls_flags=()
if [ "$cert_issuer_type" = "letsencrypt-staging" ]; then
    login_tls_flags+=("--insecure")
fi

# WSL2/devcontainers usually have no IPv6 routing. Hetzner DNS returns AAAA
# records and the argocd CLI's gRPC dialer prefers IPv6 → "network is
# unreachable". Connecting by raw IPv4 instead breaks Host-based routing at the
# Gateway (it routes by HTTP Host, so an IP target gets a 404). The robust fix
# is to pin the hostname to its IPv4 in /etc/hosts: the CLI then dials IPv4 but
# keeps the correct SNI + Host header. If /etc/hosts can't be edited, fall back
# to a kubectl port-forward (no DNS/ingress/IPv6 involved at all).
# Override IPv4 auto-detection with ARGOCD_LOGIN_IP=<ipv4> if needed.
resolve_ipv4() {
    local host="$1" ip
    if [ -n "${ARGOCD_LOGIN_IP:-}" ]; then printf '%s' "$ARGOCD_LOGIN_IP"; return; fi
    ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    ip=$(nslookup -type=A "$host" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9.]+$' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    # Last resort: control-plane IPv4 from the Pulumi stack (argocd ingress = CP node IP).
    pulumi stack output server_controlPlaneIPs_compact --non-interactive 2>/dev/null \
        | grep -oE 'ipv4: [0-9.]+' | head -1 | awk '{print $2}'
}

pin_host_to_ipv4() {  # $1=host $2=ipv4 ; returns 0 if /etc/hosts now maps host→ipv4
    local host="$1" ip="$2" line="$2 $1  # argocd-ipv4-pin"
    local writer="tee"
    if [ ! -w /etc/hosts ]; then
        sudo -n true 2>/dev/null && writer="sudo tee" || return 1
    fi
    # Remove any prior pin for this host, then append the fresh one.
    { grep -v "[[:space:]]${host}\([[:space:]]\|$\)" /etc/hosts 2>/dev/null; echo "$line"; } \
        | $writer /etc/hosts >/dev/null 2>&1 || return 1
    getent ahostsv4 "$host" 2>/dev/null | grep -q "$ip"
}

argocd context delete "$argocd_host" 2>/dev/null && echo "Deleted existing context for $argocd_host" || true

login_args=(--username admin --password "$argocd_admin_password" --grpc-web)
[ ${#login_tls_flags[@]} -gt 0 ] && login_args+=("${login_tls_flags[@]}")

argocd_ipv4=$(resolve_ipv4 "$argocd_host")

# NB the pinned-login branch must fall THROUGH to the port-forward fallback when the
# login itself fails, not just when pinning fails. The gateway terminates TLS without
# ALPN (HTTP/1.1 only), so `argocd login` can die with "gRPC connection not ready:
# context deadline exceeded" against a host that answers plain HTTPS perfectly well.
# Treating a successful pin as a successful login strands the CLI on a stale context.
if [ -n "$argocd_ipv4" ] && pin_host_to_ipv4 "$argocd_host" "$argocd_ipv4" &&
    { echo "Pinned $argocd_host → $argocd_ipv4 in /etc/hosts; logging in over IPv4." &&
        argocd login "$argocd_host" "${login_args[@]}"; }; then
    : # logged in over the pinned public host
else
    echo "Direct login unavailable; falling back to kubectl port-forward."
    # ⚠ Forward to service port 80 (→ targetPort 8080) and speak PLAIN HTTP, not 443/https.
    # The chart runs with `server.insecure: true` (src/argocd.ts params, and
    # argocd-cmd-params-cm confirms it live), so argocd-server serves cleartext on 8080 and
    # the Service maps BOTH 80 and 443 to it. Forwarding :443 and then sending a TLS
    # ClientHello at a cleartext listener makes the pod reset the connection, which surfaces
    # as "error dial proxy: dial tcp 127.0.0.1:18080: connect: connection refused" — the
    # port-forward has died by the time the CLI retries, so the message points at the wrong
    # layer entirely. Measured 2026-09-23.
    kubectl port-forward "svc/${ARGOCD_SVC}" -n "$ARGOCD_NS" "${PF_PORT}:80" --address=127.0.0.1 >/tmp/argocd-pf-${INSTANCE}.log 2>&1 &
    pf_pid=$!
    trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
    for _ in $(seq 1 15); do
        curl -s --max-time 2 "http://127.0.0.1:${PF_PORT}/healthz" >/dev/null 2>&1 && break
        sleep 1
    done
    argocd login "127.0.0.1:${PF_PORT}" \
        --username admin --password "$argocd_admin_password" --grpc-web --plaintext
    echo "NOTE: logged in via port-forward (pid $pf_pid). The context targets"
    echo "      127.0.0.1:${PF_PORT} and only works while a port-forward is running."
fi
