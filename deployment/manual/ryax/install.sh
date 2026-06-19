#!/bin/bash
# MANUAL FALLBACK / DEBUG ONLY. The supported path is the ArgoCD wave-20 app
# (deployment/argocd-sync-waves/wave20-ryax.yaml). This script installs the same
# release outside ArgoCD for debugging; the manifests now live in
# deployment/apps/ryax/. Do not run alongside the ArgoCD app on the same cluster.
#
# Install or upgrade Ryax. Blocks until all pods are ready.
# --atomic: rolls back automatically on failure (implies --wait).
# Run from any directory.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
APP_DIR="$(cd "$THIS_DIR/../../apps/ryax" && pwd)"

# Namespace + admin credentials must exist before helm --atomic wait,
# else the authorization pod blocks on missing secret and the install rolls back.
kubectl create namespace ryaxns --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$APP_DIR/ryax-admin-credentials-sealed.yaml"

helm upgrade --install ryax oci://registry.ryax.org/release-charts/ryax-engine \
  -n ryaxns --create-namespace \
  --version 26.4.0 \
  -f "$APP_DIR/values.yaml" \
  --atomic --timeout 30m
  # renovate: datasource=helm depName=registry.ryax.org/release-charts/ryax-engine

kubectl apply -f "$APP_DIR/haproxy-ingress.yaml"

bash "$THIS_DIR/addAuthentikTile.sh"
