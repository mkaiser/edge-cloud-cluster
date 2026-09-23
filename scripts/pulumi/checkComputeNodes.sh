#!/bin/bash
# checkComputeNodes.sh — read-only reconcile of the declared compute nodes
# (project_settings.ts nodes.cloud + nodes.mesh) vs the live k8s node objects.
#
# WHY: the declaration is the desired state, the k8s node objects are the actual state, and
# for mesh nodes NOTHING else bridges the two — mesh nodes are SSH-provisioned, NOT Pulumi
# cloud resources, so `pulumi up`/`refresh` CANNOT detect a dead or out-of-band-deleted one
# (there is no cloud resource to diff against). Cloud nodes ARE Pulumi-owned, so pulumi sees
# them; they are reported here anyway because a node can exist as an hcloud/Robot server yet
# never join k3s (failed provisioning) — which pulumi calls success. Liveness *alerting*
# belongs in Prometheus (KubeNodeNotReady); this is the point-in-time declaration-vs-cluster
# reconcile.
#
# Sections, in bring-up order (each reconciled independently):
#   cloud (hcloud)   provider:"hcloud" — Pulumi-created VMs
#   dedicated (robot) provider:"robot" — Pulumi-adopted bare metal
#   mesh             nodes.mesh — SSH-adopted on-premise boxes, joined over the VPN
#
# Needs only kubectl (a working kubeconfig) + project_settings.ts. No SSH, no Pulumi stack.
#
# Classes (per declared/actual id):
#   OK          declared (enabled) and node Ready
#   NOT_READY   declared, node exists but NotReady/unreachable
#   MISSING     declared, no node object (deleted out-of-band, or never joined)
#   UNDECLARED  node in cluster, absent from project_settings.ts
#   DISABLED    declared enabled:false and absent from the cluster — parked on purpose, NOT drift
#   DISABLED*   declared enabled:false but STILL IN the cluster: enabled:false only skips
#               provisioning, it never tears a node down. Reported (not a failure) so a node
#               parked while still joined is visible. Remedy differs by kind — mesh: retire it
#               with decomissionNode.sh; cloud: re-enable or destroy deliberately (a cloud
#               node is Pulumi-created, so parking a live one is a destroy waiting to happen).
#
# Exit: non-zero if any NOT_READY/MISSING/UNDECLARED (a pre-apply gate). --warn-only → exit 0.
#   make check-nodes
#   make check-nodes ARGS=--warn-only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETTINGS="$ROOT_DIR/project_settings.ts"

WARN_ONLY=0
[[ "${1:-}" == "--warn-only" ]] && WARN_ONLY=1

# shellcheck source=scripts/pulumi/_meshNodes.sh
source "$SCRIPT_DIR/_meshNodes.sh"

# ── k8s node-name for a declared id ──────────────────────────────────────────
# NOT the same rule for both kinds: cloud/robot nodes are provisioned with
# --node-name "<clusterName>-<id>" (src/nodes-k3s-base.ts), while mesh nodes join under their
# bare id. Comparing raw ids for cloud would report every cloud node MISSING *and* its live
# object UNDECLARED. clusterName is general.name lowercased.
# Anchored at the general: block rather than the first name: in the file, so an unrelated
# name: added above it cannot silently rename every cloud node.
CLUSTER_NAME="$(perl -0777 -ne 'print lc($1) if /general:\s*\{.*?name:\s*"([^"]+)"/s' "$SETTINGS" 2>/dev/null)"
k8sNameFor() { # <id> <provider>
    if [[ "$2" == "mesh" ]]; then printf '%s' "$1"; else printf '%s-%s' "$CLUSTER_NAME" "$1"; fi
}

# ── Actual: live node objects + Ready condition, partitioned by the mesh role label ───
# Partitioning matters for the reverse (UNDECLARED) check: a cloud node must not be reported
# as an undeclared *mesh* node, and vice versa. node-role.kubernetes.io/mesh is set by the
# mesh join; everything else is cloud/dedicated.
if ! kubectl get nodes -o name >/dev/null 2>&1; then
    echo "check-nodes: cannot reach the cluster (kubeconfig?). Aborting." >&2
    exit 2
fi
declare -A READY      # id -> True|False|Unknown  (all nodes)
declare -A IS_MESH    # id -> 1 when the node carries the mesh role label
while read -r name status; do
    [[ -z "$name" ]] && continue
    READY[$name]="${status:-Unknown}"
done < <(kubectl get nodes \
           -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
           2>/dev/null)
while read -r name; do
    [[ -n "$name" ]] && IS_MESH[$name]=1
done < <(kubectl get nodes -l node-role.kubernetes.io/mesh -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

fail=0
declare -A DECLARED   # every declared id, any section -> 1 (for the reverse check)

# reconcileSection <heading> <tsv-producer-output-var> [provider-filter]
# Reads TSV records on stdin and reports one line per declared node.
reconcileSection() {
    local heading="$1" provider_filter="${2:-}"
    local -a lines=()
    local id key host port user enabled prov role
    while IFS=$'\t' read -r id key host port user enabled prov role; do
        [[ -z "$id" ]] && continue
        [[ -n "$provider_filter" && "$prov" != "$provider_filter" ]] && continue
        # The declared id and the k8s node-name differ for cloud/robot (see k8sNameFor).
        # Report the id (what you edit) but reconcile against the node-name (what k8s has).
        local kname; kname="$(k8sNameFor "$id" "$prov")"
        DECLARED[$kname]=1
        # Spell out the k8s node-name only when it differs AND something is off — on a healthy
        # line the mapping is noise, but on MISSING/NOT_READY it is the name you go look up.
        local shown="$id" qualified="$id"
        [[ "$kname" != "$id" ]] && qualified="$id (k8s: $kname)"
        if [[ "$enabled" == "false" ]]; then
            # Parked: not provisioned by design → absence is expected, not drift.
            # Still-joined is worth surfacing, since enabled:false tears nothing down.
            if [[ -z "${READY[$kname]:-}" ]]; then
                lines+=("$(printf 'DISABLED    %s — enabled:false, not provisioned (parked)' "$shown")")
            else
                # The remedy differs by kind: a mesh node is retired with the decommission
                # script, whereas a LIVE cloud node parked with enabled:false is a standing
                # hazard — cloud nodes are Pulumi-created, so the flag is a staging flag and
                # dropping such a node from the program would destroy the server.
                local hint="use decomissionNode.sh to retire it"
                [[ "$prov" != "mesh" ]] && hint="cloud nodes are Pulumi-created: re-enable it, or destroy it deliberately — do NOT leave a live node parked"
                lines+=("$(printf 'DISABLED*   %s — enabled:false but STILL in the cluster (Ready=%s); enabled:false does not tear down — %s' "$qualified" "${READY[$kname]}" "$hint")")
            fi
            continue
        fi
        case "${READY[$kname]:-__absent__}" in
            True)       lines+=("$(printf 'OK          %s' "$shown")") ;;
            __absent__) lines+=("$(printf 'MISSING     %s — declared in project_settings.ts, no node object' "$qualified")"); fail=1 ;;
            *)          lines+=("$(printf 'NOT_READY   %s — node Ready=%s (unreachable/down)' "$qualified" "${READY[$kname]}")"); fail=1 ;;
        esac
    done
    # Skip the heading entirely when the section declares nothing (keeps the common
    # cloud-only / mesh-only outputs from growing empty stanzas).
    [[ ${#lines[@]} -eq 0 ]] && return 0
    printf '  %s\n' "$heading"
    printf '    %s\n' "${lines[@]}"
}

reconcileSection "cloud (hcloud)"    hcloud < <(cloudNodesTsv "$SETTINGS")
reconcileSection "dedicated (robot)" robot  < <(cloudNodesTsv "$SETTINGS")
reconcileSection "mesh"                     < <(meshNodesTsv  "$SETTINGS")

# ── reverse: live node not declared anywhere ─────────────────────────────────
# Reported under the section its role label implies, so an undeclared mesh box and an
# undeclared cloud node are not conflated.
undeclared=()
for name in "${!READY[@]}"; do
    [[ -n "${DECLARED[$name]:-}" ]] && continue
    if [[ -n "${IS_MESH[$name]:-}" ]]; then
        undeclared+=("$(printf 'UNDECLARED  %s — in cluster (mesh role), not in project_settings.ts nodes.mesh' "$name")")
    else
        undeclared+=("$(printf 'UNDECLARED  %s — in cluster, not in project_settings.ts nodes.cloud' "$name")")
    fi
    fail=1
done
if [[ ${#undeclared[@]} -gt 0 ]]; then
    printf '  %s\n' "undeclared"
    printf '    %s\n' "${undeclared[@]}"
fi

[[ ${#DECLARED[@]} -eq 0 && ${#READY[@]} -eq 0 ]] && echo "check-nodes: no compute nodes declared or present."

if [[ $fail -ne 0 && $WARN_ONLY -eq 1 ]]; then
    echo "check-nodes: drift found (--warn-only, exit 0)." >&2
    exit 0
fi
exit $fail
