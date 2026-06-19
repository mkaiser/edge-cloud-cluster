#!/bin/bash
# MANUAL FALLBACK / DEBUG ONLY. The supported teardown is removing the ArgoCD
# wave-20 app (prune deletes everything, incl. the Authentik tile ConfigMap).
# Use this only to tear down a manual install done via ./install.sh.

set -euo pipefail

# Remove the Helm release first so it can clean up namespaced objects it owns.
helm uninstall ryax -n ryaxns || true

# Remove the cert-manager Certificate and the namespace.
kubectl delete certificate ryax-tls -n ryaxns --ignore-not-found
kubectl delete namespace ryaxns --ignore-not-found

THIS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
bash "$THIS_DIR/removeAuthentikTile.sh"
