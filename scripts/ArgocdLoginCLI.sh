#!/usr/bin/env bash

set -euo pipefail

if ! argocd_url=$(pulumi stack output argocdURL --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi stack output 'argocdURL'."
    echo "Ensure Pulumi secrets are unlocked (for example: source ./scripts/initPulumi.sh)."
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

echo "Waiting for ArgoCD server pod to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

max_wait_seconds=600
start_time=$SECONDS

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

if ! argocd_admin_password=$(pulumi config get argocdAdminPasswordPlain --non-interactive 2>/dev/null); then
    echo "Failed to read Pulumi config 'argocdAdminPasswordPlain'."
    echo "Ensure Pulumi secrets are unlocked (for example: source ./scripts/initPulumi.sh)."
    exit 1
fi


login_tls_flags=()
if [ "$cert_issuer_type" = "letsencrypt-staging" ]; then
    login_tls_flags+=("--insecure")
fi

if ! argocd login "$argocd_host" \
    --username admin \
    --password "$argocd_admin_password" \
    --grpc-web "${login_tls_flags[@]}"; then
    # If strict TLS fails (or issuer type is unknown), retry once insecure.
    if [ ${#login_tls_flags[@]} -eq 0 ]; then
        echo "argocd login failed with strict TLS, retrying with --insecure ..."
        argocd login "$argocd_host" \
            --username admin \
            --password "$argocd_admin_password" \
            --grpc-web --insecure
    else
        exit 1
    fi
fi