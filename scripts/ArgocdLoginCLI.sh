#!/usr/bin/env bash

set -euo pipefail

if ! argocd_url=$(pulumi stack output argocdURL --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi stack output 'argocdURL'."
    echo "Ensure Pulumi config secrets are unlocked (for example: source ./scripts/initPulumi.sh)."
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
timeout_min=60
echo -n "Waiting for DNS resolution of $argocd_host (timeout: $timeout_min minutes): "
until nslookup "$argocd_host" >/dev/null 2>&1; do
    dns_wait_min=$((dns_wait_min + 1))
    if [ "$dns_wait_min" -ge $timeout_min ]; then
        echo ""
        echo "ERROR: $argocd_host still not resolvable after $timeout_min minutes — check external-dns and DNS TTL."
        exit 1
    fi
    printf "."
    sleep 60
done
echo -e "\n  DNS resolved after $dns_wait_min minutes."

if ! argocd_admin_password=$(pulumi config get argocdAdminPasswordPlain --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi config 'argocdAdminPasswordPlain'."
    echo "Ensure Pulumi config secrets are unlocked (for example: source ./scripts/initPulumi.sh)."
    exit 1
fi


login_tls_flags=()
if [ "$cert_issuer_type" = "letsencrypt-staging" ]; then
    login_tls_flags+=("--insecure")
fi

# WSL2 has no IPv6 routing. Hetzner DNS returns AAAA records; Go's gRPC dialer
# picks IPv6, gets "network is unreachable", and doesn't fall back to IPv4.
# Use the resolved IPv4 address as the transport target and keep TLS/SNI
# pointed at the DNS name. This avoids writing to /etc/hosts, which is not
# writable in some devcontainer setups.
argocd_ipv4=$(getent ahostsv4 "$argocd_host" 2>/dev/null | awk 'NR==1{print $1}' || true)

argocd_login_target="$argocd_host"
argocd_login_flags=()
if [ -n "$argocd_ipv4" ]; then
    argocd_login_flags+=(--server-name "$argocd_host")
    argocd_login_flags+=(--header "Host: $argocd_host")
    echo "IPv4 fallback available: $argocd_ipv4 for $argocd_host (no /etc/hosts write)."
fi

if ! argocd login "$argocd_login_target" \
    --username admin \
    --password "$argocd_admin_password" \
    --grpc-web "${login_tls_flags[@]}"; then
    if [ ${#login_tls_flags[@]} -eq 0 ]; then
        echo "argocd login failed with strict TLS, retrying with --insecure ..."
        if ! argocd login "$argocd_login_target" \
            --username admin \
            --password "$argocd_admin_password" \
            --grpc-web --insecure; then
            if [ -n "$argocd_ipv4" ]; then
                echo "Hostname login failed, trying IPv4 fallback target $argocd_ipv4 ..."
                argocd login "$argocd_ipv4" \
                    --username admin \
                    --password "$argocd_admin_password" \
                    --grpc-web "${argocd_login_flags[@]}" --insecure
            else
                exit 1
            fi
        fi
    elif [ -n "$argocd_ipv4" ]; then
        echo "Hostname login failed, trying IPv4 fallback target $argocd_ipv4 ..."
        argocd login "$argocd_ipv4" \
            --username admin \
            --password "$argocd_admin_password" \
            --grpc-web "${argocd_login_flags[@]}" "${login_tls_flags[@]}"
    else
        exit 1
    fi
fi