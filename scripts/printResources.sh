#!/usr/bin/env bash

set -euo pipefail

INTERVAL_SECONDS="${1:-60}"

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$INTERVAL_SECONDS" -le 0 ]]; then
    echo "Usage: $0 [interval_seconds]" >&2
    echo "Example: $0 60" >&2
    exit 1
fi

while true; do
    TS="$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M:%S %Z')"
    echo -n "$TS: "

    # Gather requested memory per node (sum of all pod container requests) in Ki
    declare -A NODE_REQ_MEM
    while IFS= read -r line; do
        node=$(echo "$line" | awk '{print $1}')
        req_ki=$(echo "$line" | awk '{print $2}')
        NODE_REQ_MEM["$node"]=$req_ki
    done < <(kubectl get pods -A --no-headers \
        -o custom-columns="NODE:.spec.nodeName,MEM:.spec.containers[*].resources.requests.memory" \
        2>/dev/null | awk '
        $2 != "<none>" {
            node = $1
            n = split($2, parts, ",")
            for (i = 1; i <= n; i++) {
                val = parts[i]
                if (val ~ /Gi$/) { sub(/Gi$/, "", val); mem_ki = val * 1024 * 1024 }
                else if (val ~ /Mi$/) { sub(/Mi$/, "", val); mem_ki = val * 1024 }
                else if (val ~ /Ki$/) { sub(/Ki$/, "", val); mem_ki = val }
                else mem_ki = val / 1024
                total[node] += mem_ki
            }
        }
        END { for (n in total) printf "%s %d\n", n, total[n] }
    ')

    # Print one line per node with converted units
    kubectl top node --no-headers 2>/dev/null | while read -r name cpu_abs cpu_pct mem_abs mem_pct rest; do
        alloc_ki=$(kubectl get node "$name" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null | sed 's/Ki$//')
        req_ki=${NODE_REQ_MEM["$name"]:-0}

        # CPU: convert millicores (e.g. 1374m) to cores with 2 decimals
        if [[ "$cpu_abs" =~ ^([0-9]+)m$ ]]; then
            cpu_cores=$(awk "BEGIN{printf \"%.2f\", ${BASH_REMATCH[1]}/1000}")
        elif [[ "$cpu_abs" =~ ^([0-9]+)\.?([0-9]*)$ ]]; then
            cpu_cores=$(awk "BEGIN{printf \"%.2f\", ${BASH_REMATCH[1]}${BASH_REMATCH[2]:+.$BASH_REMATCH[2]}}")
        else
            cpu_cores="$cpu_abs"
        fi

        # Memory: convert from Mi/Gi to Gi with 2 decimals
        if [[ "$mem_abs" =~ ^([0-9]+)Mi$ ]]; then
            mem_gi=$(awk "BEGIN{printf \"%.2f\", ${BASH_REMATCH[1]}/1024}")
        elif [[ "$mem_abs" =~ ^([0-9]+)Gi$ ]]; then
            mem_gi=$(awk "BEGIN{printf \"%.2f\", ${BASH_REMATCH[1]}}")
        else
            mem_gi="$mem_abs"
        fi

        # Requested memory: req_ki is in Ki -> convert to Gi
        req_gi=$(awk "BEGIN{printf \"%.2f\", ${req_ki}/1024/1024}")
        cpu_pct_num="${cpu_pct%%%}"
        mem_pct_num="${mem_pct%%%}"

        if [[ "$alloc_ki" -gt 0 ]]; then
            req_pct=$(( req_ki * 100 / alloc_ki ))
            printf "%s cpu=%05.2f cores (%02d%%) mem=%06.2fGi (%02d%%) req=%06.2fGi (%02d%%)" \
                "$name" "$cpu_cores" "$cpu_pct_num" "$mem_gi" "$mem_pct_num" "$req_gi" "$req_pct"
        else
            printf "%s cpu=%05.2f cores (%02d%%) mem=%06.2fGi (%02d%%) req=unknown" \
                "$name" "$cpu_cores" "$cpu_pct_num" "$mem_gi" "$mem_pct_num"
        fi
    done

    echo ""

    unset NODE_REQ_MEM
    sleep "$INTERVAL_SECONDS"
done
