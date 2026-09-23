#!/bin/bash
# End-to-end Ryax smoke test: build two upstream actions, wire a workflow, deploy
# it constrained to one Node Pool, and report whether the execution pod actually
# scheduled where it should. No UI, no git repo of our own to host — everything
# comes from the public default-actions repo Ryax clones itself.
#
# This exists because doing this by hand in a browser is dozens of clicks, and
# because getting it right via the API has THREE non-obvious traps (below) that
# cost real debugging time on 2026-08-31/2026-09-01 — this script is that
# debugging made permanent instead of re-discovered per session.
#
#   smoketest.sh <node-pool-name>    run the test against this Node Pool
#   smoketest.sh --list-pools        show registered Site/Node Pool names
#   smoketest.sh --help
#
# Prerequisites: the ryax ArgoCD app synced, and at least one worker Node Pool
# registered (manageWorker.sh <node>).
#
# ── Trap 1: the HTTP trigger silently doesn't work ─────────────────────────────
# The obvious trigger for a scripted test is `httpapijson` (HTTP API JSON) — it is
# what usage.md's UI walkthrough uses. Via the API it DEPLOYS clean (Runner logs a
# bare `WorkflowDeployedSuccessfully`, no error) but the route never actually
# registers: `GET /user-api/openapi.json` keeps returning `"paths": {}` and the
# endpoint 404s, on both a fresh 2026-08-31 install and a fresh 2026-09-01
# reinstall. This looks like a bug inside the closed-source `ryax_http_api` addon
# (the route lands on some router object that never reaches the ASGI app actually
# serving that port), not anything a workflow config can fix. So this script uses
# `one-run` ("Run once") instead — it fires immediately on deploy with no HTTP
# route to register at all, and proves the exact same pipeline (build, deploy,
# scheduling) without depending on the broken addon.
#
# ── Trap 2: modules-links direction is the OPPOSITE of what the field names say ─
# POST /studio/workflows/{id}/modules-links takes {output_module_id,
# input_module_id}. The natural reading — "output_module_id is the one that
# PRODUCES data, input_module_id is the one that CONSUMES it" — is backwards.
# Verified by round-tripping through GET .../export (a zip containing
# workflow.yaml) and reading each module's `streams_to:` list: setting
# output_module_id=<trigger>, input_module_id=<processor> produces
# `<processor>.streams_to: [<trigger>]` — i.e. data flowing FROM the processor TO
# the trigger, which is nonsense. The call that actually produces
# `<trigger>.streams_to: [<processor>]` (trigger feeds the processor, correct) is
# the reverse: output_module_id=<processor's own module id>,
# input_module_id=<trigger's own module id>. Read as "given output_module_id,
# these are its input_module_id(s)" rather than "output_module_id produces the
# input for input_module_id" and it clicks — but do not trust intuition here,
# trust the export.
#
# ── Trap 3 (found 2026-09-01, FIXED 2026-09-10): image pull from an off-site node ─
# The Runner stamps every execution pod's image: with RYAX_INTERNAL_REGISTRY, which
# defaults to 127.0.0.1:30012. That address is resolved by the KUBELET, which has no
# cluster DNS and no ClusterIP route — so it can only ever be a NodePort on the
# node's own loopback, never an in-cluster Service name. The chart renders exactly
# that Service (ryax-registry-ext) but only when the registry Ingress is OFF, and
# ours is on, so nothing answered on 30012 and every pull failed:
#   dial tcp 127.0.0.1:30012: connect: connection refused
# This was never node-specific — it failed on unibi-hclab too, unnoticed because no
# execution had ever run to completion.
#
# Fixed by the chart's ryax-registry-ext NodePort (registry.ingress.enabled: false)
# + internalRegistryOverride
# in worker-values.yaml (points the worker's kubelet at it). Verified 2026-09-10:
# both images pulled on home-martin-mini0. See plans/ryax-rc3-registry-fix.md.
#
# ── This script is GPU-blind, on purpose ───────────────────────────────────────
# It builds `echo`, which requests no card and would not notice one. GPU usability is
# a SEPARATE failure domain: a pod requesting nvidia.com/gpu with no
# runtimeClassName: nvidia schedules, has the device allocated to it, and then dies on
# `nvidia-smi: not found` — every placement signal green. That is tests/ryaxGpuChecks.sh.
# Do not fold it in here: this script must stay runnable on a cluster with no GPU at all.
#
# ⚠ The script still reports SCHEDULED vs RUNNING separately. Keep that: a pull
# failure and a placement failure look alike from the outside, and separating them
# is what made this diagnosable in the first place.
#
set -euo pipefail

NAMESPACE="ryaxns"
EXECS_NAMESPACE="ryaxns-execs"
DEFAULT_ACTIONS_URL="https://gitlab.com/ryax-tech/workflows/default-actions.git"
DEFAULT_ACTIONS_NAME="default-actions"
WORKFLOW_NAME="${RYAX_SMOKETEST_NAME:-ryax-smoketest}"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Build echo + one-run from the public default-actions repo, wire a minimal
workflow, deploy it constrained to one Node Pool, and report where the
execution pod actually ran.

  smoketest.sh <node-pool-name>    run against this Node Pool (any Site)
  smoketest.sh --list-pools        show registered Site/Node Pool names
  smoketest.sh --help

Env:
  RYAX_SMOKETEST_NAME   workflow name (default: ryax-smoketest). Reused across
                         runs: an existing workflow with this name is stopped
                         and redeployed rather than duplicated.

Node Pool names come from `manageWorker.sh --list` or --list-pools above.
EOF
}

[ $# -ge 1 ] || { usage; die "no Node Pool name given"; }
case "$1" in
  --help|-h) usage; exit 0 ;;
  --list-pools) MODE="list-pools" ;;
  -*) usage; die "unknown option: $1" ;;
  *) MODE="run"; POOL_NAME="$1" ;;
esac

command -v kubectl >/dev/null || die "kubectl not found"
command -v curl    >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"
python3 -c 'import yaml' 2>/dev/null || die "python3 module 'yaml' not found — see .devcontainer/Dockerfile (python3-yaml)"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "namespace $NAMESPACE missing — is the ryax ArgoCD app synced?"

# ── Reach the services ──────────────────────────────────────────────────────────
# Port-forward rather than the public host: works before/independently of the
# HTTPRoute and TLS, and keeps the admin JWT off the network. Same pattern as
# manageWorker.sh, extended to studio + repository (manageWorker.sh needs neither).
PF_PIDS=()
PF_FILES=()
cleanup() {
  local pid; for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "${PF_FILES[@]}"
}
trap cleanup EXIT

port_forward() {
  local svc="$1" remote_port="$2"
  local out; out="$(mktemp)"
  kubectl port-forward -n "$NAMESPACE" "svc/$svc" "0:$remote_port" --address=127.0.0.1 \
    >"$out" 2>&1 &
  PF_PIDS+=("$!")
  PF_FILES+=("$out")
  local p=""
  for _ in $(seq 1 30); do
    p="$(sed -n 's/.*127\.0\.0\.1:\([0-9]\+\).*/\1/p' "$out" | head -1)"
    [ -n "$p" ] && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$p/" 2>/dev/null && break
    [ -n "$p" ] && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$p/healthz" 2>/dev/null && break
    p=""
    sleep 1
  done
  [ -n "$p" ] || { cat "$out" >&2; die "$svc port-forward never came up"; }
  echo "http://127.0.0.1:$p"
}

log "port-forwarding to ryax-runner, ryax-authorization, ryax-studio, ryax-repository ..."
RUNNER="$(port_forward ryax-runner 8080)"
AUTH="$(port_forward ryax-authorization 8080)"
STUDIO="$(port_forward ryax-studio 8080)"
REPO="$(port_forward ryax-repository 8080)"

# ── Authenticate ──────────────────────────────────────────────────────────────
ADMIN_USER="$(kubectl get secret -n "$NAMESPACE" ryax-admin-credentials -o jsonpath='{.data.username}' | base64 -d)"
ADMIN_PASS="$(kubectl get secret -n "$NAMESPACE" ryax-admin-credentials -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$ADMIN_PASS" ] || die "ryax-admin-credentials has no password"

log "logging in as $ADMIN_USER ..."
TOKEN="$(curl -s --max-time 20 -X POST "$AUTH/login" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' \
        "$ADMIN_USER" "$ADMIN_PASS")" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("jwt",""))')"
[ -n "$TOKEN" ] || die "login failed — check ryax-admin-credentials and ryax-authorization"

# NB bare token, not "Bearer $TOKEN" — see the AUTH note in usage.md/manageWorker.sh.
runner_api()     { curl -s --max-time 30 -X "$1" "$RUNNER$2" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' "${@:3}"; }
studio_api()     { curl -s --max-time 60 -X "$1" "$STUDIO$2" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' "${@:3}"; }
repository_api() { curl -s --max-time 30 -X "$1" "$REPO$2"   -H "Authorization: $TOKEN" -H 'Content-Type: application/json' "${@:3}"; }

json_field() {
  local field="$1"
  python3 -c '
import sys, json
body = sys.stdin.read()
try:
    data = json.loads(body)
except json.JSONDecodeError:
    sys.exit(f"API did not return JSON:\n{body.strip()[:400]}")
value = data.get(sys.argv[1]) if isinstance(data, dict) else None
if not value:
    sys.exit(f"API response has no {sys.argv[1]!r}:\n{body.strip()[:400]}")
print(value)
' "$field"
}

if [ "$MODE" = "list-pools" ]; then
  runner_api GET /sites | python3 -c '
import sys, json
d = json.load(sys.stdin)
for s in d.get("sites", []):
    print("Site: %s (%s)" % (s["name"], s["id"]))
    for p in s.get("node_pools", []):
        print("  %s  %s cpu / %.1f GiB" % (p["name"], p["cpu"], p["memory"]/1024**3))
'
  exit 0
fi

# ── Resolve the Node Pool name to a Site + NodePool id ─────────────────────────
SITE_ID="" ; POOL_ID=""
read -r SITE_ID POOL_ID <<<"$(runner_api GET /sites | python3 -c '
import sys, json
d = json.load(sys.stdin)
name = sys.argv[1]
for s in d.get("sites", []):
    for p in s.get("node_pools", []):
        if p["name"] == name:
            print(s["id"], p["id"]); sys.exit(0)
sys.exit(1)
' "$POOL_NAME")" || die "no Node Pool named '$POOL_NAME' — run: manageWorker.sh --list  (or: $0 --list-pools)"
log "target: Site $SITE_ID / NodePool $POOL_ID ($POOL_NAME)"

# ── Repository: add (idempotent) + scan ─────────────────────────────────────────
SRC_ID="$(repository_api GET /v2/sources | python3 -c '
import sys, json
for r in json.load(sys.stdin):
    if r["url"] == sys.argv[1]:
        print(r["id"]); sys.exit(0)
' "$DEFAULT_ACTIONS_URL")"
if [ -z "$SRC_ID" ]; then
  log "adding $DEFAULT_ACTIONS_NAME repository ..."
  SRC_ID="$(repository_api POST /sources \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"url":sys.argv[2]}))' \
          "$DEFAULT_ACTIONS_NAME" "$DEFAULT_ACTIONS_URL")" | json_field id)"
fi
log "scanning ($SRC_ID) ..."
SCAN="$(repository_api POST "/v2/sources/$SRC_ID/scan" -d '{}')"

find_module() {
  python3 -c '
import sys, json
d = json.loads(sys.argv[2])
mods = d.get("last_scan", {}).get("built_actions", []) + d.get("last_scan", {}).get("not_built_actions", [])
for m in mods:
    if m["technical_name"] == sys.argv[1]:
        print(m["id"]); sys.exit(0)
sys.exit(f"module {sys.argv[1]!r} not found in scan results")
' "$1" "$SCAN"
}
ECHO_ID="$(find_module echo)"
ONERUN_ID="$(find_module one-run)"

# ── Build both (idempotent — a Built module just re-reports Built) ─────────────
build_and_wait() {
  local mod_id="$1" name="$2"
  local status
  status="$(python3 -c '
import sys, json
d = json.loads(sys.argv[2])
mods = d.get("last_scan", {}).get("built_actions", []) + d.get("last_scan", {}).get("not_built_actions", [])
for m in mods:
    if m["id"] == sys.argv[1]:
        print(m["status"]); sys.exit(0)
' "$mod_id" "$SCAN")"
  if [ "$status" != "Built" ]; then
    log "building $name ($mod_id) — first build pulls nixpkgs, allow a few minutes ..."
    repository_api POST "/modules/$mod_id/build" -d '{}' >/dev/null
  else
    log "$name already Built"
  fi
  for _ in $(seq 1 60); do
    status="$(repository_api GET "/v2/sources/$SRC_ID" | python3 -c '
import sys, json
d = json.load(sys.stdin)
mods = d.get("last_scan", {}).get("built_actions", []) + d.get("last_scan", {}).get("not_built_actions", [])
for m in mods:
    if m["id"] == sys.argv[1]:
        print(m["status"]); sys.exit(0)
' "$mod_id")"
    case "$status" in
      Built) log "$name: Built"; return 0 ;;
      "Build Error") die "$name build failed — check ryax-action-builder logs" ;;
    esac
    sleep 10
  done
  die "$name never finished building (last status: $status)"
}
build_and_wait "$ECHO_ID" echo
build_and_wait "$ONERUN_ID" one-run

# ── Workflow: reuse by name if it exists, else create ───────────────────────────
WF_ID="$(studio_api GET "/workflows?search=$WORKFLOW_NAME" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get("items", [])
for w in items:
    if w.get("name") == sys.argv[1]:
        print(w["id"]); sys.exit(0)
' "$WORKFLOW_NAME" 2>/dev/null || true)"

if [ -n "$WF_ID" ]; then
  log "reusing workflow $WORKFLOW_NAME ($WF_ID) — stopping before redeploy ..."
  studio_api POST "/workflows/$WF_ID/stop" >/dev/null
  for _ in $(seq 1 30); do
    st="$(studio_api GET "/workflows/$WF_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin)["deployment_status"])')"
    [ "$st" = "None" ] && break
    sleep 2
  done

  # Re-fetch this run's module ids by custom_name — constraints (below) must be
  # re-applied on EVERY run, reuse included: a first version of this script only
  # set them at creation time, so re-running with a DIFFERENT Node Pool name
  # silently redeployed to the OLD pool while reporting the new pool's name.
  ECHO_MOD="$(studio_api GET "/workflows/$WF_ID" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for m in d["modules"]:
    if m["custom_name"] == "echo":
        print(m["id"]); sys.exit(0)
sys.exit("echo module not found in existing workflow")
')"
  TRIG_MOD="$(studio_api GET "/workflows/$WF_ID" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for m in d["modules"]:
    if m["custom_name"] == "trigger":
        print(m["id"]); sys.exit(0)
sys.exit("trigger module not found in existing workflow")
')"
else
  log "creating workflow $WORKFLOW_NAME ..."
  WF_ID="$(studio_api POST /workflows \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1]}))' "$WORKFLOW_NAME")" \
    | json_field workflow_id)"

  ECHO_MOD="$(studio_api POST "/workflows/$WF_ID/modules" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"module_id":sys.argv[1],"custom_name":"echo","position_x":300,"position_y":100}))' "$ECHO_ID")" \
    | json_field id)"
  TRIG_MOD="$(studio_api POST "/workflows/$WF_ID/modules" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"module_id":sys.argv[1],"custom_name":"trigger","position_x":50,"position_y":100}))' "$ONERUN_ID")" \
    | json_field id)"

  # Trap 2 (see header): output_module_id=echo, input_module_id=trigger is the
  # call that actually produces trigger.streams_to=[echo] — the flow we want.
  studio_api POST "/workflows/$WF_ID/modules-links" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"output_module_id":sys.argv[1],"input_module_id":sys.argv[2]}))' "$ECHO_MOD" "$TRIG_MOD")" >/dev/null

  # Workflow result: map echo's test_str output to a key, purely so the workflow
  # has a valid result (required for deploy) — nothing reads it in this test.
  OUT_ID="$(studio_api GET "/workflows/$WF_ID/modules-outputs" | python3 -c '
import sys, json
for o in json.load(sys.stdin):
    if o["technical_name"] == "test_str":
        print(o["id"]); sys.exit(0)
')"
  studio_api PUT "/v2/workflows/$WF_ID/results" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"workflow_results_to_add":[{"key":"echo_result","workflow_module_io_id":sys.argv[1]}]}))' "$OUT_ID")" >/dev/null
fi

# Constrain both modules to the target Site/NodePool — unconditionally, every
# run, so re-running against a different Node Pool name actually moves it.
for MOD in "$ECHO_MOD" "$TRIG_MOD"; do
  studio_api PUT "/v2/workflows/$WF_ID/modules/$MOD/constraints" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"site_list":[sys.argv[1]],"site_type_list":[],"node_pool_list":[sys.argv[2]],"arch_list":[]}))' "$SITE_ID" "$POOL_ID")" >/dev/null
  studio_api PUT "/v2/workflows/$WF_ID/modules/$MOD/objectives" \
    -d '{"energy":10,"cost":10,"performance":10}' >/dev/null
done

# ── Deploy ───────────────────────────────────────────────────────────────────
# Captured BEFORE the deploy call, not right before polling for pods below: the
# deploy-and-schedule round trip takes over a minute, so a timestamp taken only
# once deployment_status stops being "Deploying" can already be AFTER the
# execution pod's own creationTimestamp — excluding the very pod it's meant to
# find. An earlier version of this script had that bug and reported "no
# execution pod appeared" for a pod that had been sitting there the whole time.
BEFORE_DEPLOY="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "deploying ..."
DEPLOY_RESULT="$(studio_api POST "/workflows/$WF_ID/deploy")"
if echo "$DEPLOY_RESULT" | grep -q '"error"'; then
  ERRORS="$(studio_api GET "/workflows/$WF_ID/errors")"
  die "deploy rejected: $DEPLOY_RESULT
workflow errors: $ERRORS
(if constraints/results look right, re-check the modules-links direction —
see Trap 2 in this script's header — via GET /workflows/$WF_ID/export)"
fi

# Observed taking over 60s end to end (constraints -> deploy -> scheduler ->
# executor), so this needs real patience, not a quick poll. It can ALSO simply
# stay "Deploying" indefinitely and never move — confirmed live: a one-run
# execution whose pod is stuck ImagePullBackOff (Trap 3) leaves the WORKFLOW
# status at "Deploying" forever even though the pod itself deployed and
# scheduled fine. So this loop is patience, not a pass/fail gate — a stuck
# "Deploying" is logged and the script moves on to check the pod directly,
# which is the signal that actually answers the placement question.
st="Deploying"
for _ in $(seq 1 40); do
  st="$(studio_api GET "/workflows/$WF_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin)["deployment_status"])')"
  [ "$st" != "Deploying" ] && break
  sleep 5
done
DEPLOY_ERR="$(studio_api GET "/workflows/$WF_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("deployment_error") or "")')"
[ -z "$DEPLOY_ERR" ] || die "deployment_error: $DEPLOY_ERR"
if [ "$st" = "Deploying" ]; then
  log "deployment_status still Deploying after 200s — checking the pod directly instead of waiting further"
else
  log "deployment_status: $st"
fi

# ── Check placement ──────────────────────────────────────────────────────────
# A repeat run of this script leaves earlier executions' pods around (Ryax does
# not clean them up on redeploy), so picking "the" pod in the namespace must mean
# the NEWEST one CREATED BY THIS RUN (filtered against BEFORE_DEPLOY above), not
# whichever the API happens to list first — an early version of this script
# grabbed a 21-minute-old pod from a previous run instead of the fresh one, and
# reported that stale pod's node/status as this run's result.
log "waiting for the execution pod ..."
POD=""
for _ in $(seq 1 30); do
  POD="$(kubectl get pods -n "$EXECS_NAMESPACE" -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
pods = [p for p in d["items"] if p["metadata"]["creationTimestamp"] >= sys.argv[1]]
pods.sort(key=lambda p: p["metadata"]["creationTimestamp"])
print(pods[-1]["metadata"]["name"] if pods else "")
' "$BEFORE_DEPLOY")"
  [ -n "$POD" ] && break
  sleep 2
done
[ -n "$POD" ] || die "no execution pod appeared in $EXECS_NAMESPACE — check studio_api GET /workflows/$WF_ID/errors"

NODE="$(kubectl get pod -n "$EXECS_NAMESPACE" "$POD" -o jsonpath='{.spec.nodeName}')"
STATUS="$(kubectl get pod -n "$EXECS_NAMESPACE" "$POD" -o jsonpath='{.status.phase}')"

echo
echo "pod:    $POD"
echo "node:   ${NODE:-<not yet scheduled>}"
echo "status: $STATUS"
echo

if [ -z "$NODE" ]; then
  kubectl describe pod -n "$EXECS_NAMESPACE" "$POD" | grep -A5 "^Events:"
  die "pod never scheduled — check the Node Pool's node still exists and is Ready, and (if it is at another site) that ryax-placement's site mutation is namespace-scoped to ryaxns only (admission-policies.yaml)"
fi

if [ "$NODE" != "$(kubectl get pod -n "$EXECS_NAMESPACE" "$POD" -o jsonpath='{.spec.nodeSelector.kubernetes\.io/hostname}')" ]; then
  log "WARNING: scheduled node ($NODE) does not match the pod's own hostname selector — investigate"
fi

WAITING_REASON="$(kubectl get pod -n "$EXECS_NAMESPACE" "$POD" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"

case "$STATUS" in
  Running|Succeeded)
    log "PLACEMENT OK — pod ran on $NODE"
    ;;
  Pending|Failed)
    kubectl describe pod -n "$EXECS_NAMESPACE" "$POD" | grep -A5 "^Events:"
    if printf '%s' "$WAITING_REASON" | grep -q ImagePull; then
      log "PLACEMENT OK — scheduled correctly on $NODE, but image pull failed. This is a"
      log "REGRESSION: it was fixed 2026-09-10 (see Trap 3 in this script's header). Check that"
      log "the ryax-registry-ext NodePort exists and has an endpoint, and that the worker carries"
      log "the override:"
      log "  kubectl get svc,endpoints -n $NAMESPACE ryax-registry-ext"
      log "  kubectl get deploy -n $NAMESPACE -o yaml | grep RYAX_INTERNAL_REGISTRY_OVERRIDE"
    else
      log "PLACEMENT OK (scheduled to $NODE) but pod is $STATUS — see events above"
    fi
    ;;
  *)
    kubectl describe pod -n "$EXECS_NAMESPACE" "$POD" | grep -A5 "^Events:"
    die "pod is $STATUS on $NODE — see events above"
    ;;
esac
