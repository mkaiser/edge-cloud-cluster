#!/bin/bash
# alertSilence.sh — open a maintenance silence in Alertmanager for the duration of a
# lifecycle run, so a bring-up does not email every alert it transiently trips.
#
# WHY: alert rules fire on conditions that legitimately hold for the whole of a bootstrap.
# ArgoCDAppNotSynced/ArgoCDAppUnhealthy carry `for: 15m` and a bootstrap takes ~42 min, so
# apps that are merely still converging cross the threshold and page. With
# `send_resolved: true` each one costs a second mail when it clears — ~20 mails per recreate,
# none of them actionable.
#
# ⚠ This silences by TIME WINDOW, not by alert name. An allow/deny list keyed on names is
# exactly the failure this repo already hit once (see the comment in
# alertmanager-config.yaml.template, where a name-keyed route swallowed every alert nobody
# had thought to list). A window expires on its own; a forgotten name filter does not.
#
# ⚠ Best-effort by design: a bring-up must never fail because monitoring was unreachable.
# Every path returns 0. Before Alertmanager exists (early in a fresh create) there is
# nothing to silence and nothing to report.
#
# ⚠ On a FRESH create Alertmanager does not exist yet when the run starts — the cluster is
# still being built — and it appears ~20 min in, mid-run, with plenty of bring-up left to
# alert about. So `start` WAITS in the background for Alertmanager to show up (up to
# --wait minutes) and opens the silence the moment it does. Opening it only at t=0 was a
# no-op on exactly the runs that need it (measured 2026-09-05: "Alertmanager not present
# yet" at 11:59, cluster alerting from ~12:20).
#
# Usage: bash scripts/runtime/alertSilence.sh start [minutes] [waitMinutes]
#          (default 60m silence, wait up to 30m for Alertmanager to appear)
#        bash scripts/runtime/alertSilence.sh end

set -uo pipefail

ACTION="${1:-start}"
MINUTES="${2:-60}"
WAIT_MINUTES="${3:-30}"
NS="prometheus"
SVC="svc/kube-prometheus-stack-alertmanager"
PORT="9093"
STATE_FILE="${TMPDIR:-/tmp}/ecc-alert-silence-id"

am_curl() {
    # Port-forward for a single request, then drop it: a long-lived forward would outlive
    # the phase and wedge if the API server restarts mid-bring-up.
    local method="$1" path="$2" body="${3:-}" pf_pid rc=1 out
    kubectl -n "$NS" port-forward "$SVC" "${PORT}:9093" --address=127.0.0.1 >/dev/null 2>&1 &
    pf_pid=$!
    for _ in $(seq 1 10); do
        sleep 1
        if curl -sf -m 3 "http://127.0.0.1:${PORT}/api/v2/status" >/dev/null 2>&1; then rc=0; break; fi
    done
    if [ "$rc" -ne 0 ]; then kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null; return 1; fi
    if [ -n "$body" ]; then
        out=$(curl -sf -m 10 -X "$method" -H 'Content-Type: application/json' \
              -d "$body" "http://127.0.0.1:${PORT}${path}" 2>/dev/null)
    else
        out=$(curl -sf -m 10 -X "$method" "http://127.0.0.1:${PORT}${path}" 2>/dev/null)
    fi
    rc=$?
    kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null
    [ -n "$out" ] && echo "$out"
    return $rc
}

case "$ACTION" in
    start)
        if ! kubectl -n "$NS" get "$SVC" >/dev/null 2>&1; then
            # Not up yet (fresh create). Wait for it in the BACKGROUND so the deployment is
            # never blocked on monitoring, and open the silence as soon as it exists.
            echo "alert silence: Alertmanager not up yet — waiting up to ${WAIT_MINUTES}m in the background."
            (
                deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
                while [ "$(date +%s)" -lt "$deadline" ]; do
                    sleep 30
                    if kubectl -n "$NS" get "$SVC" >/dev/null 2>&1; then
                        exec bash "$0" start "$MINUTES" 0
                    fi
                done
            ) >/dev/null 2>&1 &
            disown 2>/dev/null || true
            exit 0
        fi
        starts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        ends=$(date -u -d "+${MINUTES} minutes" +%Y-%m-%dT%H:%M:%S.000Z)
        # matcher: alertname=~".+" — every alert, for this window only.
        body=$(cat <<JSON
{"matchers":[{"name":"alertname","value":".+","isRegex":true,"isEqual":true}],
 "startsAt":"$starts","endsAt":"$ends",
 "createdBy":"lifecycle","comment":"cluster lifecycle run — auto-expires"}
JSON
)
        if id=$(am_curl POST /api/v2/silences "$body" | jq -r '.silenceID // empty' 2>/dev/null) && [ -n "$id" ]; then
            echo "$id" > "$STATE_FILE"
            echo "alert silence: active for ${MINUTES}m (id ${id})"
        else
            echo "alert silence: could not create silence (continuing anyway)." >&2
        fi
        ;;
    end)
        [ -s "$STATE_FILE" ] || exit 0
        id=$(cat "$STATE_FILE")
        if am_curl DELETE "/api/v2/silence/${id}" >/dev/null 2>&1; then
            echo "alert silence: lifted (id ${id})"
        else
            echo "alert silence: could not lift id ${id} — it expires on its own." >&2
        fi
        rm -f "$STATE_FILE"
        ;;
    *)
        echo "usage: $0 start [minutes] | end" >&2
        exit 0
        ;;
esac
exit 0
