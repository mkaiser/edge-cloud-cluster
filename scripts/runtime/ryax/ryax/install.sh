#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

helm upgrade --install ryax oci://registry.ryax.org/release-charts/ryax-engine -n ryaxns --create-namespace --version 26.4.0 -f prod.yaml \
	# renovate: datasource=helm depName=registry.ryax.org/release-charts/ryax-engine

helm upgrade --install ryax-worker oci://registry.ryax.org/release-charts/ryax-worker -n ryaxns --version 26.4.0 -f worker.yaml \
	# renovate: datasource=helm depName=registry.ryax.org/release-charts/ryax-worker

# Apply HAProxy ingress for the external endpoint
kubectl apply -f haproxy-ingress.yaml