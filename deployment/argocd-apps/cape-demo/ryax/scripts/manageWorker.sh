#!/bin/bash
# Register Kubernetes nodes as Ryax Node Pools and install/update the
# ryax-worker-k8s release.
#
#   manageWorker.sh <node> [<node> ...]   add these nodes (keeping existing ones)
#   manageWorker.sh --list                show what is registered now
#   manageWorker.sh --remove <node> ...   stop sending work to these nodes
#
# The Ryax Site defaults to unibi-hclab; pick another with --site or RYAX_SITE_NAME.
# Each Site gets its OWN helm release and its own worker-values.<site>.yaml overrides —
# the worker's own pods carry that site's nodeSelector and storage class, so one shared
# release would move them every time another site was updated.
#
# Node names are exactly as `kubectl get nodes` prints them, so provisioning a new
# mesh node and handing Ryax that name is one command:
#
#   bash manageWorker.sh unibi-hclab-pcie-tb-x
#
# This automates what the upstream docs present as a manual UI walkthrough
# (docs/howto/worker-install.md: "create a new Site ... copy the Site and Node
# Pools IDs from the Ryax UI"). It is fully scriptable because the Runner's Sites
# API accepts writes — see the AUTH note below, which is the whole reason this
# script exists rather than a one-line curl.
#
# ── ADDITIVE, and why that matters ────────────────────────────────────────────
# Adding a node must not disturb the nodes already running work. The set of pools
# is therefore read back from the LIVE worker ConfigMap
# (<release>-config, key config.yaml) and merged with the arguments, rather than
# being re-derived from a list in this file. Consequences worth knowing:
#   * re-running with an already-registered node is a no-op for that node — it
#     keeps its existing NodePool id, so nothing is re-registered and no duplicate
#     pool appears;
#   * a node already registered but NOT named on this run is KEPT. Use --remove to
#     take one out;
#   * the Ryax Site and its pools therefore survive `helm uninstall` (they live in
#     the Runner's database, not in the release) — which is exactly why the
#     ConfigMap is only a cache of ids, and every id is re-validated against the
#     API before use.
#
# ONE POOL PER NODE, deliberately: Ryax stores the cpu/memory figures registered
# for a pool and schedules against them, so a pool spanning differently-sized
# nodes makes every placement decision wrong. Figures come from that node's live
# `.status.allocatable`, scaled by RYAX_POOL_SHARE.
#
# Run from the devcontainer with a working kubeconfig. No Pulumi stack needed.
#
# ── AUTH: the bare token, NOT "Bearer <token>" ────────────────────────────────
# The Runner's auth middleware in 26.7.0 reads the Authorization header as the
# raw JWT. Sending the conventional `Authorization: Bearer <jwt>` returns
# **401 with an empty `{}` body** — which reads exactly like "authenticated fine,
# no sites yet" and is how this was misdiagnosed the first time. Verified inside
# the runner pod against /sites: bare token -> 200, `Bearer ` prefix -> 401, for
# both a login JWT and a self-minted one.
#
# ⚠ The chart's own bundled CLI (`python -m ryax.cli`, "ryaxctl", in
# /data/ryax/cli/) is therefore BROKEN against this build: its
# `CliConfig.auth_headers()` hardcodes `f"Bearer {token}"`, so every verb 401s.
# Do not reach for it as an alternative to this script until upstream fixes that.
set -euo pipefail

NAMESPACE="ryaxns"
# Release name is DERIVED from the Site (see the RELEASE= assignment after argument
# parsing) — one helm release per site, because each carries that site's own
# nodeSelector, storage class and node-pool ConfigMap.
RELEASE=""
CHART="oci://registry.ryax.org/release-charts/ryax-worker-k8s"
# Chart name as the templates see it — the ConfigMap/Deployment are named
# "<release>-<chart>", e.g. ryax-worker-ryax-worker-k8s-config.
CHART_NAME="ryax-worker-k8s"
CHART_VERSION="26.9.0" # renovate: datasource=docker depName=registry.ryax.org/release-charts/ryax-worker-k8s
# The site whose values live in the shared worker-values.yaml and whose release keeps
# the bare name. Kept as its own variable because SITE_NAME is overridable and the
# comparison below needs the un-overridden value.
DEFAULT_SITE="unibi-hclab" # automatically updated from project-settings:applicationPlacements.meshSite
SITE_NAME="${RYAX_SITE_NAME:-$DEFAULT_SITE}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# The manifests live one level up: this script sits in ryax/scripts/, the values
# files it reads stay beside the rest of the app definition in ryax/.
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Fraction of each node's allocatable to hand to Ryax. Not 1.0 because these nodes
# are shared: they also carry Longhorn, the EDA runners and the gVisor desktops, so
# Ryax must not be told it owns the whole box.
POOL_SHARE="${RYAX_POOL_SHARE:-0.6}"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Register Kubernetes nodes as Ryax Node Pools and install/update the worker.

  manageWorker.sh <node> [<node> ...]   add these nodes (existing ones are kept)
  manageWorker.sh --list                show what is registered now
  manageWorker.sh --remove <node> ...   stop sending work to these nodes
  manageWorker.sh --help

Options:
  --site <name>     Ryax Site to use/create (overrides RYAX_SITE_NAME)

Node names are as `kubectl get nodes` prints them.

Env:
  RYAX_SITE_NAME    Ryax Site to use/create (default: applicationPlacements.meshSite)
  RYAX_POOL_SHARE   fraction of each node's allocatable to offer (default: 0.6)

Notes:
  * One pool per node — Ryax schedules from the figures registered per pool, so
    differently-sized nodes must not share one.
  * A GPU node is accepted only while a card is actually FREE. All cards already
    requested (e.g. by ollama-turing) => refused, because its actions would sit
    Pending on "Insufficient nvidia.com/gpu". The Jetson Thor is always refused:
    Ryax builds x86_64 images and the Thor is aarch64.
  * The Site is chosen when it is CREATED. An existing Site is looked up by name,
    so re-running with a different --site does not MOVE a node: it creates a
    second Site and a second pool for that node. To move one, --remove it from the
    old Site first (with that Site's name), then add it under the new one.
  * ONE HELM RELEASE PER SITE. The default site is release "ryax-worker"; every
    other site is "ryax-worker-<site>" and needs its own
    worker-values.<site>.yaml beside worker-values.yaml, carrying at least that
    site's nodeSelector and storage class. Adding a site without that file is
    refused — it would install with the default site's placement.
    --list and --remove act on the release for the site you name, so pass --site
    for anything other than the default.
EOF
}

MODE="add"
NODES=()
SITE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --list)     MODE="list" ;;
    --remove)   MODE="remove" ;;
    --site)     shift; [ $# -gt 0 ] || die "--site needs a name"; SITE_OVERRIDE="$1" ;;
    --site=*)   SITE_OVERRIDE="${1#--site=}"; [ -n "$SITE_OVERRIDE" ] || die "--site needs a name" ;;
    -*)         usage; die "unknown option: $1" ;;
    *)          NODES+=("$1") ;;
  esac
  shift
done
# --site wins over RYAX_SITE_NAME, which wins over the default. Resolved AFTER parsing
# so the flag can appear anywhere on the line.
[ -z "$SITE_OVERRIDE" ] || SITE_NAME="$SITE_OVERRIDE"

# ── One helm release per Site ─────────────────────────────────────────────────
# A second site is not just a second Node Pool: the worker's OWN pods carry that
# site's nodeSelector and bind that site's storage class, so they need their own
# release. Sharing one would have each `helm upgrade` overwrite the previous site's
# values and move its pods.
#
# The default site keeps the bare name `ryax-worker` so an existing installation is
# upgraded in place rather than orphaned beside a renamed one.
if [ "$SITE_NAME" = "$DEFAULT_SITE" ]; then
  RELEASE="ryax-worker"
else
  RELEASE="ryax-worker-$SITE_NAME"
fi

# Per-site overrides layered ON TOP of worker-values.yaml, which holds everything
# site-independent. Absent file => the site uses the shared base unchanged, which is
# right for the default site and wrong for any other, so adding a site means adding
# its file. Checked in `add` mode only: --list and --remove must keep working for a
# site whose file was deleted.
SITE_VALUES="$APP_DIR/worker-values.$SITE_NAME.yaml"

case "$MODE" in
  list)   [ ${#NODES[@]} -eq 0 ] || die "--list takes no node names" ;;
  add)    [ ${#NODES[@]} -gt 0 ] || { usage; die "no nodes given"; } ;;
  remove) [ ${#NODES[@]} -gt 0 ] || { usage; die "--remove needs at least one node"; } ;;
esac

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
command -v curl    >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "namespace $NAMESPACE missing — is the ryax ArgoCD app synced?"

# ── Reach the Runner ──────────────────────────────────────────────────────────
# Port-forward rather than the public host: this must work before/independently
# of the HTTPRoute and TLS, and it keeps the admin JWT off the network. Port 0
# lets the kernel pick a free port, so a stale forward cannot collide.
log "port-forwarding to ryax-runner ..."
PF_OUT="$(mktemp)"
kubectl port-forward -n "$NAMESPACE" svc/ryax-runner 0:8080 --address=127.0.0.1 \
  >"$PF_OUT" 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" 2>/dev/null || true; rm -f "$PF_OUT"; }
trap cleanup EXIT

RUNNER=""
for _ in $(seq 1 30); do
  port="$(sed -n 's/.*127\.0\.0\.1:\([0-9]\+\).*/\1/p' "$PF_OUT" | head -1)"
  if [ -n "$port" ] && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/sites"; then
    RUNNER="http://127.0.0.1:$port"; break
  fi
  sleep 1
done
[ -n "$RUNNER" ] || { cat "$PF_OUT" >&2; die "runner port-forward never came up"; }
log "runner at $RUNNER"

# ── Authenticate ──────────────────────────────────────────────────────────────
# Log in through the authorization service to get a JWT for the admin user that
# values.yaml provisioned from the sealed secret. Read the password from the
# cluster rather than taking it as an argument, so it never lands in shell history.
ADMIN_USER="$(kubectl get secret -n "$NAMESPACE" ryax-admin-credentials \
  -o jsonpath='{.data.username}' | base64 -d)"
ADMIN_PASS="$(kubectl get secret -n "$NAMESPACE" ryax-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$ADMIN_PASS" ] || die "ryax-admin-credentials has no password"

AUTH_PF_OUT="$(mktemp)"
kubectl port-forward -n "$NAMESPACE" svc/ryax-authorization 0:8080 --address=127.0.0.1 \
  >"$AUTH_PF_OUT" 2>&1 &
AUTH_PF_PID=$!
cleanup() {
  kill "$PF_PID" "$AUTH_PF_PID" 2>/dev/null || true
  rm -f "$PF_OUT" "$AUTH_PF_OUT"
}

AUTH=""
for _ in $(seq 1 30); do
  aport="$(sed -n 's/.*127\.0\.0\.1:\([0-9]\+\).*/\1/p' "$AUTH_PF_OUT" | head -1)"
  if [ -n "$aport" ] && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$aport/"; then
    AUTH="http://127.0.0.1:$aport"; break
  fi
  sleep 1
done
[ -n "$AUTH" ] || { cat "$AUTH_PF_OUT" >&2; die "authorization port-forward never came up"; }

log "logging in as $ADMIN_USER ..."
TOKEN="$(curl -s --max-time 20 -X POST "$AUTH/login" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' \
        "$ADMIN_USER" "$ADMIN_PASS")" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("jwt",""))')"
[ -n "$TOKEN" ] || die "login failed — check ryax-admin-credentials and ryax-authorization"

# NB bare token. See the AUTH note in the header: "Bearer $TOKEN" 401s with `{}`.
api() {
  local method="$1" path="$2"; shift 2
  curl -s --max-time 30 -X "$method" "$RUNNER$path" \
    -H "Authorization: $TOKEN" -H 'Content-Type: application/json' "$@"
}

# Pull one field out of a JSON response, but fail LOUDLY when the body is not the
# JSON we expect. The Runner answers some errors with bare text and a 5xx (e.g.
# "500 Internal Server Error\n\nServer got itself in trouble" on a duplicate site
# name), so piping straight into json.load() produces an unreadable
# JSONDecodeError traceback instead of the actual problem.
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

# ── Site ──────────────────────────────────────────────────────────────────────
# NB the body is parsed defensively, like json_field below: the Runner answers some
# errors with bare text (a 500 "Server got itself in trouble"), and a not-yet-ready
# port-forward yields an EMPTY body. Feeding either straight to json.load() produced an
# unreadable JSONDecodeError traceback that read as "Ryax is broken" — measured on
# --list against a healthy cluster whose /sites returned {"sites":[]} when queried
# directly a second later.
SITE_ID="$(api GET /sites | python3 -c '
import sys, json
name = sys.argv[1]
body = sys.stdin.read()
try:
    data = json.loads(body)
except json.JSONDecodeError:
    sys.exit(f"GET /sites did not return JSON:\n{body.strip()[:400]}")
for s in (data.get("sites") or []):
    if s.get("name") == name:
        print(s["id"]); break
' "$SITE_NAME")"

if [ -n "$SITE_ID" ]; then
  log "site '$SITE_NAME' already exists: $SITE_ID"
elif [ "$MODE" = "list" ]; then
  # --list is READ-ONLY. Creating the Site here would spend the name (see the unique
  # constraint below) just because someone asked what is registered, and on a cluster
  # with no Site yet that is the very first thing a reader runs.
  printf '\nNo Ryax Site named %s exists yet — nothing is registered.\n\n' "$SITE_NAME"
  exit 0
else
  # ⚠ Site names carry a UNIQUE constraint (`sites_name_key`) and ARCHIVING DOES
  # NOT FREE THE NAME. An archived site vanishes from GET /sites — so the lookup
  # above cannot see it — yet re-using its name fails with a bare-text
  # 500 ("Server got itself in trouble") whose real cause is only visible in the
  # runner log as psycopg2 UniqueViolation. There is no API to list or purge
  # archived sites, so a name is effectively spent once used.
  #
  # Hence: retry with a timestamp suffix rather than dying. The Site NAME is
  # cosmetic (the worker binds to the site *id*), so a suffixed name costs
  # nothing, whereas a hard failure here would leave a half-configured cluster.
  site_payload() {
    python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"type":"KUBERNETES"}))' "$1"
  }
  if resp="$(api POST /sites -d "$(site_payload "$SITE_NAME")")" \
     && SITE_ID="$(printf '%s' "$resp" | json_field site_id 2>/dev/null)"; then
    log "created site '$SITE_NAME': $SITE_ID"
  else
    SITE_NAME="${SITE_NAME}-$(date +%s)"
    log "name was taken (likely an archived site) — retrying as '$SITE_NAME'"
    SITE_ID="$(api POST /sites -d "$(site_payload "$SITE_NAME")" | json_field site_id)"
    log "created site '$SITE_NAME': $SITE_ID"
  fi
fi

# ── Node Pools ────────────────────────────────────────────────────────────────
# Pools already registered on this Site, keyed by name. The pool NAME is the node
# name — that convention is the whole mechanism that makes this incremental.
#
# NOTE the response shape: GET /sites/{id}/node-pools returns a BARE JSON ARRAY,
# while GET /sites returns {"sites": [...]} with the pools nested under each site.
# Reading it as {"node_pools": ...} yields None, every node then looks absent, and
# each run appends a duplicate set of pools to the same site. Do NOT wrap this in
# `2>/dev/null || true` either — that is what hid the bug the first time.
EXISTING="$(api GET "/sites/$SITE_ID/node-pools" | python3 -c '
import sys, json
d = json.load(sys.stdin)
pools = d if isinstance(d, list) else (d.get("node_pools") or [])
for p in pools:
    print("%s\t%s" % (p.get("name"), p.get("id")))
')"

pool_id_for() { printf '%s\n' "$EXISTING" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

# Nodes the LIVE worker is currently configured to use. This — not a list in this
# file — is what makes adding one node leave the others alone. Absent ConfigMap
# (first install) simply yields nothing.
CONFIGURED="$(kubectl get cm -n "$NAMESPACE" "${RELEASE}-${CHART_NAME}-config" \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin.read()) or {}
except yaml.YAMLError:
    sys.exit(0)
for p in (((d.get("site") or {}).get("spec") or {}).get("nodePools") or []):
    host = (p.get("selector") or {}).get("kubernetes.io/hostname")
    if host:
        print(host)
' || true)"

if [ "$MODE" = "list" ]; then
  printf '\nSite: %s (%s)\n\n' "$SITE_NAME" "$SITE_ID"
  if [ -z "${CONFIGURED//[[:space:]]/}" ]; then
    echo "  no nodes configured — add one with: manageWorker.sh <node>"
  else
    # One API read, then look each configured node up in it. The pools the SITE
    # knows about are a superset of the ones this release USES — a node removed
    # with --remove keeps its pool (there is no delete-pool API), so listing the
    # site's pools alone would misreport what is actually receiving work.
    POOL_INFO="$(api GET "/sites/$SITE_ID/node-pools" | python3 -c '
import sys, json
for p in json.load(sys.stdin):
    print("%s\t%s\t%.1f cpu / %.1f Gi" % (
        p.get("name"), p.get("id"), p.get("cpu", 0), p.get("memory", 0) / 1024**3))
')"
    printf '  %-28s %-34s %s\n' NODE "NODE POOL" "REGISTERED CPU / MEM"
    while read -r host; do
      [ -n "$host" ] || continue
      printf '  %-28s %s\n' "$host" \
        "$(printf '%s\n' "$POOL_INFO" | awk -F'\t' -v n="$host" \
            '$1==n{printf "%-34s %s", $2, $3; found=1} END{if(!found) printf "%-34s", "<missing>"}')"
    done <<< "$CONFIGURED"
  fi
  echo
  exit 0
fi

# ── Merge the requested change into the configured set ────────────────────────
TARGET_NODES="$(python3 - "$MODE" <<PYEOF
import sys
mode = sys.argv[1]
configured = [n for n in """$CONFIGURED""".split() if n]
requested = [n for n in """${NODES[*]}""".split() if n]
if mode == "add":
    # Order-preserving union: existing nodes keep their place, new ones append.
    result = configured + [n for n in requested if n not in configured]
else:
    result = [n for n in configured if n not in requested]
print("\n".join(result))
PYEOF
)"

if [ "$MODE" = "remove" ]; then
  for node in "${NODES[@]}"; do
    printf '%s\n' "$CONFIGURED" | grep -qx "$node" \
      || log "note: $node was not configured — nothing to remove"
  done
  [ -n "${TARGET_NODES//[[:space:]]/}" ] \
    || die "that would leave the worker with no node pools; add another node first"
  # NB the Ryax Node Pool object is deliberately NOT deleted: the API exposes no
  # delete for pools, and the pool carries run history. Dropping it from the
  # worker's config is what stops work being scheduled there.
  log "removing from the worker config: ${NODES[*]}"
fi

declare -A POOL_IDS=()
POOL_ORDER=()
while read -r node; do
  [ -n "$node" ] || continue
  kubectl get node "$node" >/dev/null 2>&1 \
    || die "node $node not found — check 'kubectl get nodes'"

  # GPU nodes: allowed, but only with a card actually FREE.
  #
  # The ryax-placement policy tolerates ecc/gpu=true:NoSchedule (admission-policies.yaml
  # patch 3), so a GPU pool is schedulable. It is only USABLE with a spare card, though:
  # a pool on a node whose GPUs are all requested yields execution pods that sit Pending
  # forever on "Insufficient nvidia.com/gpu" — which reads as a stale device plugin
  # rather than a booked node, so check it here where the cause is obvious.
  #
  # ⚠ The Thor is excluded by the policy, not here: its images are aarch64/sm_110 and Ryax
  # builds x86_64. A pool on it would schedule and then fail with an exec-format error.
  # ⚠ REFUSE A NODE WITHOUT THE RYAX LONGHORN TAG. Registering a pool is a COMPUTE
  # decision, but a Ryax action lands its engine storage on the node it runs on, so a node
  # outside the `unibi-ryax` disk tag has no business hosting one. The tag is the
  # authoritative eligibility signal — checked here rather than by hostname so it follows
  # project_settings.ts instead of drifting from it.
  #
  # This exists because unibi-hclab-fs-vm was registered by hand on 2026-09-18 from its
  # `ecc/site` label, which it shares with the compute nodes. It is a 57.7 G fileserver VM
  # sharing the general `unibi`/`unibi-hclab` tags with 0.9-1.8 T peers, and it is
  # DELIBERATELY excluded from `unibi-ryax` for that reason: on 2026-09-15 it hit
  # DiskPressure and refused a 5 G replica while 50% physically free, taking
  # remote-desktop's Guacamole database down for ~4h. Ryax is the largest tenant of that
  # tag (705 GiB of replica footprint, 400 G of it the action-builder nix-store), so it is
  # the last thing that should land there. README.md already said fs-vm is "deliberately
  # left out"; prose did not stop it, so this does.
  if ! kubectl get nodes.longhorn.io -n longhorn-system "$node" \
         -o jsonpath='{range .spec.disks.*}{.tags}{"\n"}{end}' 2>/dev/null \
       | grep -q 'unibi-ryax'; then
    die "$node carries no 'unibi-ryax' Longhorn disk tag — it is not a Ryax storage node.
  Ryax engine storage is node-local, so a pool here would place action data on a disk that
  project_settings.ts deliberately keeps out of the Ryax pool (see meshStorageScope).
  To make this node eligible, add 'unibi-ryax' to its storageScope in project_settings.ts
  and re-run updateConfigFromProjectSettings.sh — do not work around this check."
  fi

  NODE_GPUS=0
  if [ "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.ecc/gpu}' 2>/dev/null)" = "true" ]; then
    if [ "$(kubectl get node "$node" \
              -o jsonpath='{.metadata.labels.ecc/gpu-model}' 2>/dev/null)" = "jetson-thor" ]; then
      die "$node is the Jetson Thor — Ryax action images are x86_64; it is excluded by policy"
    fi
    # Capacity minus what every non-terminated pod on this node already requests. `kubectl
    # describe` prints the same figure, but only as text; this reads the API.
    NODE_GPUS="$(kubectl get node "$node" \
      -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
    NODE_GPUS="${NODE_GPUS:-0}"
    used="$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=$node,status.phase!=Succeeded,status.phase!=Failed" \
      -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.nvidia\.com/gpu}{"\n"}{end}{end}' 2>/dev/null \
      | awk 'NF{s+=$1} END{print s+0}')"
    NODE_GPUS=$(( NODE_GPUS - used ))
    if [ "$NODE_GPUS" -le 0 ]; then
      die "$node has no free GPU (all $used requested, e.g. by ollama-turing) — free one first, or its actions will sit Pending"
    fi
    log "node $node has $NODE_GPUS free GPU(s)"
  fi

  POOL_ORDER+=("$node")
  found="$(pool_id_for "$node")"
  if [ -n "$found" ]; then
    log "node pool for $node exists: $found"
    POOL_IDS["$node"]="$found"
    continue
  fi

  # Allocatable straight from the node, scaled by POOL_SHARE. cpu is millicores
  # and memory is BYTES in this API (per the bundled CLI's own payload).
  read -r cpu_m mem_b < <(kubectl get node "$node" \
    -o jsonpath='{.status.allocatable.cpu}{" "}{.status.allocatable.memory}' \
    | python3 -c '
import sys
cpu, mem = sys.stdin.read().split()
cpu_m = int(float(cpu[:-1]) if cpu.endswith("m") else float(cpu) * 1000)
units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
         "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12}
for suf, mul in units.items():
    if mem.endswith(suf):
        mem_b = int(float(mem[: -len(suf)]) * mul); break
else:
    mem_b = int(mem)
share = '"$POOL_SHARE"'
print(int(cpu_m * share), int(mem_b * share))
')

  pool_id="$(api POST "/sites/$SITE_ID/node-pools" -d "$(python3 -c '
import json, sys
gpus = int(sys.argv[4])
print(json.dumps({
    "name": sys.argv[1],
    "cpu": int(sys.argv[2]),
    "gpu": gpus,
    "memory": int(sys.argv[3]),
    "energy_score": 10,
    "cost_score": 10,
    "performance_score": 10,
    # Per-execution wall-clock ceiling for this pool. A pool is only ELIGIBLE for an action
    # if maximum_time_in_sec >= the action's requested time (runner site_entities.py:130-135),
    # so this is a SECOND, independent cap on top of the runner's
    # RYAX_DEFAULT_TIME_ALLOTMENT_IN_SECONDS (set in ../values.yaml). KEEP THE TWO IN SYNC:
    # raising only the runner makes every pool ineligible and the execution gets NO site at all,
    # which surfaces as a bare `AssertionError: execution.site_id is not None` in the runner and
    # a trigger that 404s — never as "no pool had enough time". Measured 2026-09-23.
    "maximum_time_in_sec": 3600,
    # Only a CPU-only pool filters GPU actions out. On a pool with cards, GPU actions
    # are exactly what it is for — leaving this True there makes Ryax refuse to place
    # them and the pool looks registered but unusable.
    "filter_no_gpu_action": gpus == 0,
}))' "$node" "$cpu_m" "$mem_b" "$NODE_GPUS")" | json_field node_pool_id)"
  log "created node pool $node (${cpu_m}m cpu / $((mem_b / 1024 / 1024 / 1024))Gi / ${NODE_GPUS} gpu): $pool_id"
  POOL_IDS["$node"]="$pool_id"
done <<< "$TARGET_NODES"

[ ${#POOL_ORDER[@]} -gt 0 ] || die "no usable nodes — nothing to do"

# ── Render the worker values ──────────────────────────────────────────────────
# worker-values.yaml carries everything EXCEPT the `config.site` block, which is
# generated here: the site id and the pool list are per-cluster and change on every
# recreate, so committing them would guarantee drift. Written as a second -f layer
# rather than by string substitution, so the pool list can have any length.
RENDERED="$(mktemp --suffix=.yaml)"
trap 'kill "$PF_PID" "$AUTH_PF_PID" 2>/dev/null || true; rm -f "$PF_OUT" "$AUTH_PF_OUT" "$RENDERED"' EXIT

{
  echo "# Generated by manageWorker.sh — do not edit, do not commit."
  echo "config:"
  echo "  site:"
  echo "    id: $SITE_ID"
  echo "    spec:"
  # spec.namespace is REQUIRED, not decorative: resource_quota.yaml renders both
  # the ResourceQuota and the LimitRange with `namespace: {{ tpl
  # .Values.config.site.spec.namespace . }}`, so omitting it emits objects with an
  # empty namespace and the release fails to apply. Templated by the chart, hence
  # the single quotes.
  echo "      namespace: '{{ .Values.global.ryax.userNamespace }}'"
  echo "      nodePools:"
  for node in "${POOL_ORDER[@]}"; do
    echo "        - id: ${POOL_IDS[$node]}"
    echo "          selector:"
    echo "            kubernetes.io/hostname: $node"
  done
} > "$RENDERED"

grep -q 'REPLACE-WITH' "$APP_DIR/worker-values.yaml" \
  && die "worker-values.yaml still has REPLACE-WITH placeholders — it should no longer carry a config.site block; see its header"

# A non-default site with no overrides file would silently install with the DEFAULT
# site's nodeSelector and storage class — its pods would land at the wrong site, or sit
# Pending forever. Refuse instead.
VALUES_ARGS=(-f "$APP_DIR/worker-values.yaml")
if [ "$SITE_NAME" != "$DEFAULT_SITE" ]; then
  [ -f "$SITE_VALUES" ] || die "site '$SITE_NAME' has no $(basename "$SITE_VALUES") — \
without it the worker would install with $DEFAULT_SITE's nodeSelector and storage class"
  VALUES_ARGS+=(-f "$SITE_VALUES")
  log "site overrides: $(basename "$SITE_VALUES")"
fi

log "node pools for this release: ${POOL_ORDER[*]}"

# ── Install the worker ────────────────────────────────────────────────────────
log "helm upgrade --install $RELEASE (this waits for rollout) ..."
helm upgrade --install "$RELEASE" "$CHART" \
  --version "$CHART_VERSION" \
  -n "$NAMESPACE" \
  "${VALUES_ARGS[@]}" \
  -f "$RENDERED" \
  --wait --timeout 15m

cat <<EOF

Done. Site '$SITE_NAME' ($SITE_ID) now serves ${#POOL_ORDER[@]} node pool(s):
$(printf '  %s\n' "${POOL_ORDER[@]}")
Release $RELEASE is running.

  manageWorker.sh --list             what is registered
  manageWorker.sh <node>             add another node
  manageWorker.sh --remove <node>    stop using one

The Site appears in the Ryax UI under each action's Deploy tab:
  https://ryax.$( kubectl get httproute -n "$NAMESPACE" ryax \
      -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null | sed 's/^ryax\.//' )/app/infrastructure
EOF
