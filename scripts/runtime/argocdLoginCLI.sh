#!/usr/bin/env bash

set -euo pipefail

if ! argocd_url=$(pulumi stack output argocdURL --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi stack output 'argocdURL'."
    echo "Ensure Pulumi config secrets are unlocked (for example: source ./scripts/pulumi/initPulumiStack.sh)."
    exit 1
fi
echo -e "ArgoCD URL from Pulumi stack output: $argocd_url"

cert_issuer_type=$(pulumi stack output certIssuerType --non-interactive 2>/dev/null || true)
if [ -z "$argocd_url" ]; then
    echo "Pulumi stack output 'argocdURL' is empty. Is ArgoCD enabled and deployed?"
    exit 1
fi
argocd_host=$(printf '%s' "$argocd_url" | sed -E 's#^https?://##; s#/.*$##')
echo -e "certissuer type from Pulumi stack output: $cert_issuer_type"

if [ "$argocd_url" = "ArgoCD disabled" ]; then
    echo "ArgoCD is disabled (stack output 'argocdURL' is 'ArgoCD disabled')."
    exit 1
fi

echo "Waiting for ArgoCD server pod to be ready... (timeout 5min)"
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

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
echo -n "Waiting for DNS resolution of $argocd_host (timeout: $timeout_min minutes): "
echo -n "Sometimes this works instantly, sometimes never... It is an devContainer / DNS proxy issue. Don't know why."
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
# unreachable". Connecting by raw IPv4 instead breaks haproxy-ingress Host
# routing (it routes by HTTP Host, so an IP target gets a 404). The robust fix
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

if [ -n "$argocd_ipv4" ] && pin_host_to_ipv4 "$argocd_host" "$argocd_ipv4"; then
    echo "Pinned $argocd_host → $argocd_ipv4 in /etc/hosts; logging in over IPv4."
    argocd login "$argocd_host" "${login_args[@]}"
else
    echo "Could not pin /etc/hosts; falling back to kubectl port-forward."
    pf_port=18080
    kubectl port-forward svc/argocd-server -n argocd "${pf_port}:443" --address=127.0.0.1 >/tmp/argocd-pf.log 2>&1 &
    pf_pid=$!
    trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
    for _ in $(seq 1 15); do
        curl -sk --max-time 2 "https://127.0.0.1:${pf_port}/healthz" >/dev/null 2>&1 && break
        sleep 1
    done
    argocd login "127.0.0.1:${pf_port}" \
        --username admin --password "$argocd_admin_password" --grpc-web --insecure
    echo "NOTE: logged in via port-forward (pid $pf_pid). The context targets"
    echo "      127.0.0.1:${pf_port} and only works while a port-forward is running."
fi