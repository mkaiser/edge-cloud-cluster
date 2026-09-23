#!/bin/bash
# Provision the Ryax workers for the mid-term review: bender (CPU) and
# smartmirror1 (GPU).
#
#   ryax-prov.sh              register both nodes
#   ryax-prov.sh --list       show what is registered now
#   ryax-prov.sh --dry-run    print what would run, change nothing
#
# A thin wrapper over deployment/argocd-apps/cape-demo/ryax/scripts/manageWorker.sh — it holds the
# NODE SET for the review and the preflight checks, and delegates every API call. Do not
# reimplement the Sites/Node-Pools calls here; manageWorker.sh owns them, is additive, and
# is the only thing that knows the auth quirks (the Runner wants a BARE token, not
# "Bearer <jwt>").
#
# WHY A SCRIPT AND NOT A SETTINGS FLAG: a Ryax Node Pool is not a Kubernetes object. It is
# an HTTP POST to the Runner returning an id minted into its Postgres, with no DELETE verb,
# so Pulumi cannot own it — at apply time the Runner may not even exist. Honouring a
# `ryaxWorker` flag in project_settings.ts would need an in-cluster reconcile Job, i.e.
# manageWorker.sh as a controller. The node set lives here instead.
#
# ⚠ The Site is NOT set here. manageWorker.sh defaults it from
# applicationPlacements.meshSite, and a Site NAME IS SPENT ONCE USED — the unique
# constraint survives archiving, so a stray --site permanently burns a name.
#
# ⚠ RYAX_SITE_NAME (a Ryax scheduling target) and the ecc/site node label (this cluster's
# failure/latency domain) are unrelated concepts that merely share the string
# "unibi-hclab". Never conflate them. smartmirror1 is at ecc/site=unibi-recslab and still
# joins the same RYAX Site — that is correct, not a bug.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANAGE_WORKER="$REPO_ROOT/deployment/argocd-apps/cape-demo/ryax/scripts/manageWorker.sh"
NAMESPACE="ryaxns"

# The review's worker set. bender is plain CPU; smartmirror1 carries the two RTX 2070s and
# is registered as a GPU pool — but only if a card is free (see the ollama-turing note in
# the preflight below).
NODES=(unibi-hclab-bender unibi-recslab-smartmirror1)

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Provision the Ryax workers for the mid-term review.

  ryax-prov.sh              register the review's nodes (additive, re-runnable)
  ryax-prov.sh --list       show what is registered now
  ryax-prov.sh --dry-run    print what would run, change nothing
  ryax-prov.sh --help

Nodes: unibi-hclab-bender (CPU), unibi-recslab-smartmirror1 (GPU).

A node that is absent or NotReady is SKIPPED with a warning rather than failing the
run — registration is additive, so re-run once the node is back.
EOF
}

MODE="add"
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --list)     MODE="list" ;;
    --dry-run)  MODE="dry-run" ;;
    *)          usage; die "unknown option: $1" ;;
  esac
  shift
done

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
[ -f "$MANAGE_WORKER" ] || die "manageWorker.sh not found at $MANAGE_WORKER"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "namespace $NAMESPACE missing — is the ryax ArgoCD app synced?"

# manageWorker.sh is mode 0644 and every doc invokes it through `bash`. Match that rather
# than relying on an exec bit that is not set in git.
if [ "$MODE" = "list" ]; then
  exec bash "$MANAGE_WORKER" --list
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
# Skip rather than die on a missing node: unibi-hclab-pcie-tb-s has reboot-looped before,
# and one flaky box must not block registering the others. manageWorker.sh keeps existing
# pools, so a later re-run picks the node up with nothing undone.
READY_NODES=()
for node in "${NODES[@]}"; do
  if ! kubectl get node "$node" >/dev/null 2>&1; then
    log "WARNING: $node not in the cluster — skipping"
    continue
  fi
  ready="$(kubectl get node "$node" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "$ready" != "True" ]; then
    log "WARNING: $node is not Ready (Ready=$ready) — skipping"
    continue
  fi

  # A GPU node needs a FREE card. manageWorker.sh refuses one that has none, which is
  # correct but terse; say here what to do about it, since the fix is a capacity decision
  # in another app rather than anything about Ryax.
  if [ "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.ecc/gpu}' 2>/dev/null)" = "true" ]; then
    cap="$(kubectl get node "$node" \
      -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
    used="$(kubectl get pods --all-namespaces \
      --field-selector "spec.nodeName=$node,status.phase!=Succeeded,status.phase!=Failed" \
      -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.nvidia\.com/gpu}{"\n"}{end}{end}' 2>/dev/null \
      | awk 'NF{s+=$1} END{print s+0}')"
    free=$(( ${cap:-0} - used ))
    if [ "$free" -le 0 ]; then
      log "WARNING: $node has no free GPU (${used}/${cap:-0} requested) — skipping"
      log "         free one by switching ollama-turing to its 1x1-GPU mode:"
      log "         see deployment/argocd-apps/app-of-apps/ollama-turing.yaml"
      continue
    fi
    log "$node: $free of ${cap:-0} GPU(s) free"
  fi

  READY_NODES+=("$node")
done

[ ${#READY_NODES[@]} -gt 0 ] || die "no usable nodes — nothing to do"

if [ "$MODE" = "dry-run" ]; then
  log "would run: bash $MANAGE_WORKER ${READY_NODES[*]}"
  exit 0
fi

log "registering: ${READY_NODES[*]}"
bash "$MANAGE_WORKER" "${READY_NODES[@]}"

cat <<EOF

Registered. Verify each pool actually runs an action — a pool can exist and still place
nothing if the selector and the placement policy disagree:

$(for n in "${READY_NODES[@]}"; do
    printf '  bash deployment/argocd-apps/cape-demo/ryax/scripts/smoketest.sh %s\n' "$n"
  done)

The smoketest returns node_name; it must match the node you asked for.
EOF
