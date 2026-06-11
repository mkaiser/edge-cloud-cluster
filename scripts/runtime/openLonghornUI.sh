#!/usr/bin/env bash

set -euo pipefail

PORT="${1:-8090}"

echo "Forwarding Longhorn UI on 0.0.0.0:${PORT} (accessible from host)"
echo "Open: http://localhost:${PORT}"
echo "Press Ctrl+C to stop."
echo ""

exec kubectl port-forward svc/longhorn-frontend -n longhorn-system "${PORT}:80" --address=0.0.0.0
