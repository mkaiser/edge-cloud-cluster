#!/usr/bin/env bash

set -euo pipefail

INTERVAL_SECONDS="${1:-60}"

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$INTERVAL_SECONDS" -le 0 ]]; then
    echo "Usage: $0 [interval_seconds]" >&2
    echo "Example: $0 60" >&2
    exit 1
fi

while true; do
    printf "%s | " "$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M:%S %Z')"

    if ! kubectl top node --no-headers \
        | awk '{printf "%s cpu=%6s (%3s) mem=%7s (%3s) | ", $1, $2, $3, $4, $5} END {print ""}'; then
        echo "kubectl top node failed"
    fi

    sleep "$INTERVAL_SECONDS"
done
