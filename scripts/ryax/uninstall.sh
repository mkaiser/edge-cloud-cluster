#!/bin/bash

set -euo pipefail

# Remove the Helm release first so it can clean up namespaced objects it owns.
helm uninstall ryax -n ryaxns || true

# Remove the cert-manager Certificate and the namespace.
kubectl delete certificate ryax-tls -n ryaxns --ignore-not-found
kubectl delete namespace ryaxns --ignore-not-found
