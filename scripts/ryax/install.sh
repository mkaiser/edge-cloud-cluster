#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

helm upgrade --install ryax oci://registry.ryax.org/release-charts/ryax-engine -n ryaxns --create-namespace --version 26.2 -f prod.yaml

# I
# helm upgrade ryax oci://registry.ryax.org/release-charts/ryax-engine -n ryaxns --version 26.2 -f prod.yaml

# Apply HAProxy ingress for the external endpoint
kubectl apply -f haproxy-ingress.yaml