#!/usr/bin/env bash

set -euo pipefail

namespace="${1:-argocd}"

argocd_url=$(pulumi stack output argocdURL 2>/dev/null || true)
portal_url=""
if [[ -n "$argocd_url" && "$argocd_url" != "ArgoCD disabled" ]]; then
	argocd_host="${argocd_url#http://}"
	argocd_host="${argocd_host#https://}"
	argocd_host="${argocd_host%%/*}"

	domain_after_service="${argocd_host#*.}"
	infra_subdomain="${domain_after_service%%.*}"
	base_domain="${domain_after_service#*.}"

	deployment_subdomain="$infra_subdomain"
	if [[ "$infra_subdomain" =~ ^infra([0-9]+)$ ]]; then
		deployment_subdomain="test${BASH_REMATCH[1]}"
	fi

	portal_url="https://portal.${deployment_subdomain}.${base_domain}"
fi

printf "username: Administrator\npass: "
kubectl -n "${namespace}" get secret ums-nubus-credentials -o jsonpath='{.data.administrator_password}' | base64 -d
printf "\n"
if [[ -n "$portal_url" ]]; then
	printf "portal: %s\n" "$portal_url"
fi
