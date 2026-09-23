#!/bin/bash
# pruneOrphanedNodes.sh — bulk-delete ORPHANED headscale machine entries.
#
# WHY: mesh nodes are SSH-provisioned boxes that join the headscale/tailscale VPN. Every
# (re-)provision wipes tailscale state (30-connect-vpn.sh: `rm -rf /var/lib/tailscale`) and
# re-registers with `tailscale up --hostname "$(hostname)"`. Headscale keeps the OLD machine
# record and de-duplicates the given name by appending -1, -2, … so the SAME physical box
# accumulates as `pcie-tb-d`, `pcie-tb-d-1`, … `pcie-tb-d-9`, etc. The predecessor entry is
# never deleted, so the headscale DB fills with dead VPN identities that have no live k8s node.
#
# An ORPHAN here = a headscale entry that is OFFLINE *and* whose name maps to no live k8s node.
# Deleting it removes ONLY the dead VPN identity — it does NOT touch k8s, Longhorn, or the box.
#
# BOTH conditions are required, and the name test is a SUFFIX match, not equality. Two traps that
# made an earlier version of this script delete four LIVE nodes' identities on ecc174:
#
#   1. headscale names may be the BOX HOSTNAME (30-connect-vpn.sh: `tailscale up --hostname
#      "${ECC_NODE_NAME:-$(hostname)}"` — the carry-scripts pass ECC_NODE_NAME so those match
#      the k8s name, but a node joined without it is named after the box), while k8s node
#      names are `<site>-<id>` from project_settings.ts. So
#      `pcie-tb-s` (headscale) and `unibi-hclab-pcie-tb-s` (k8s) are the SAME machine, and an
#      equality test calls the live one an orphan. Hence: an entry is live if its name, minus any
#      headscale `-N` de-duplication suffix, is a suffix of some live k8s node name (or vice
#      versa).
#   2. An ONLINE entry is never an orphan, whatever its name. A connected tailnet member is by
#      definition in use — deleting it frees its 10.0.10.x address and the CP immediately loses
#      the route to that node's kubelet (`502 Bad Gateway ... dialing 10.0.10.N:10250`), so
#      `kubectl exec/logs` against it break even though the node still shows Ready.
#
# Recovering from that needs a re-provision of each affected box (`make provision-mesh-node`),
# which is exactly the disruption this script exists to avoid — so the guards stay.
#
# SCOPE — this is one of three cleanup tools; use the right one:
#   - pruneOrphanedNodes.sh (this)   : bulk-remove stale HEADSCALE entries (VPN identity only).
#   - drainOrphanedNodes.sh              : delete dead k8s NODE OBJECTS (+ Longhorn node CRs).
#   - decomissionNode.sh <id>        : FULL retire of ONE node (box wipe + k8s + Longhorn +
#                                          headscale + Pulumi state) — the complete teardown.
#
# Needs only kubectl (a working kubeconfig). No SSH, no Pulumi stack.
#
# Usage:
#   ./scripts/provisioning/pruneOrphanedNodes.sh          # list orphans, pick, delete (interactive)
#   ./scripts/provisioning/pruneOrphanedNodes.sh --yes    # delete ALL orphans without prompting
set -euo pipefail

HS_NAMESPACE="${HS_NAMESPACE:-headscale}"

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl is not available in PATH" >&2
    exit 1
fi
if ! kubectl get nodes -o name >/dev/null 2>&1; then
    echo "ERROR: cannot reach the cluster (kubeconfig?)." >&2
    echo "Fetch it with scripts/runtime/getKubeConfig.sh" >&2
    exit 1
fi

# ── Resolve the headscale pod (same selector fallback as decomissionNode.sh) ──
HS_POD=$(kubectl get pods -n "$HS_NAMESPACE" -l app.kubernetes.io/name=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || kubectl get pods -n "$HS_NAMESPACE" -l app=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$HS_POD" ] || { echo "ERROR: headscale pod not found in ns '$HS_NAMESPACE'." >&2; exit 1; }

# ── Live k8s node names (the set an entry must match to be considered live) ───────
LIVE_NODES="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

# ── Orphans = headscale entries whose name has no matching live k8s node ──────────
# Emit one TSV record per orphan: id, name, online, lastSeen. Same JSON-shape handling
# (given_name/givenName/name, list-or-{nodes:[…]}) as decomissionNode.sh.
ORPHAN_TSV=$(kubectl exec -n "$HS_NAMESPACE" "$HS_POD" -- headscale nodes list --output json 2>/dev/null \
    | LIVE_NODES="$LIVE_NODES" python3 -c "
import sys, json, os, re
live = set(os.environ.get('LIVE_NODES', '').split())

def maps_to_live(name):
    '''True if this headscale entry plausibly belongs to a live k8s node.

    headscale name = box hostname; k8s name = <site>-<box-id>. Strip headscale's -N
    de-duplication suffix, then accept a suffix match in either direction so
    pcie-tb-s <-> unibi-hclab-pcie-tb-s is recognised as one machine. Deliberately
    GENEROUS: a false 'live' leaves a stale entry for the next run to catch, while a
    false 'orphan' cuts a working node off the tailnet.'''
    base = re.sub(r'-\\d+\$', '', name)
    for ln in live:
        if base == ln or ln.endswith('-' + base) or base.endswith('-' + ln):
            return True
    return False

data = json.load(sys.stdin)
nodes = data if isinstance(data, list) else data.get('nodes', [])
for n in nodes:
    name = n.get('given_name') or n.get('givenName') or n.get('name')
    online = n.get('online', n.get('connected'))
    # An online entry is in use by definition — never an orphan.
    if online is True:
        continue
    if maps_to_live(str(name)):
        continue
    last = n.get('lastSeen') or n.get('last_seen') or ''
    print('\t'.join([str(n.get('id')), str(name), str(online), str(last)]))
" 2>/dev/null || true)

if [[ -z "${ORPHAN_TSV//[[:space:]]/}" ]]; then
    echo "No orphaned headscale entries (every entry maps to a live k8s node)."
    exit 0
fi

# Parse into parallel arrays.
IDS=() ; NAMES=() ; ONLINE=() ; LAST=()
while IFS=$'\t' read -r id name online last; do
    [[ -z "$id" ]] && continue
    IDS+=("$id"); NAMES+=("$name"); ONLINE+=("$online"); LAST+=("$last")
done <<< "$ORPHAN_TSV"

echo "Orphaned headscale entries (no matching live k8s node):"
echo ""
printf "  %-3s %-6s %-28s %-8s %s\n" "#" "HS-ID" "NAME" "ONLINE" "LAST-SEEN"
for i in "${!IDS[@]}"; do
    printf "  %-3s %-6s %-28s %-8s %s\n" \
        "$((i + 1))" "${IDS[$i]}" "${NAMES[$i]}" "${ONLINE[$i]}" "${LAST[$i]}"
done
echo ""

# ── Selection (same all/none/numbers UX as drainOrphanedNodes.sh) ─────────────────
SELECTED_IDX=()
if [[ $ASSUME_YES -eq 1 ]]; then
    SELECTED_IDX=("${!IDS[@]}")
    echo "--yes: deleting ALL ${#IDS[@]} orphaned entries."
else
    read -rp "Delete which? [all / none / space-separated numbers] (default: none): " selection
    selection="${selection:-none}"
    case "$selection" in
        none|NONE|"") echo "Nothing selected. Aborted."; exit 0 ;;
        all|ALL)      SELECTED_IDX=("${!IDS[@]}") ;;
        *)
            for tok in $selection; do
                [[ "$tok" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid token '$tok'." >&2; exit 1; }
                idx=$((tok - 1))
                (( idx >= 0 && idx < ${#IDS[@]} )) || {
                    echo "ERROR: '$tok' out of range (1-${#IDS[@]})." >&2; exit 1; }
                SELECTED_IDX+=("$idx")
            done ;;
    esac
fi

[[ ${#SELECTED_IDX[@]} -gt 0 ]] || { echo "Nothing selected. Aborted."; exit 0; }

if [[ $ASSUME_YES -ne 1 ]]; then
    echo ""
    echo "This will DELETE the following headscale entries (VPN identity only):"
    for idx in "${SELECTED_IDX[@]}"; do
        printf '  - id=%s  %s\n' "${IDS[$idx]}" "${NAMES[$idx]}"
    done
    read -rp "Continue [yes/no]: " confirm
    [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { echo "Aborted."; exit 1; }
fi

FAILED=0
for idx in "${SELECTED_IDX[@]}"; do
    hid="${IDS[$idx]}" ; name="${NAMES[$idx]}"
    if kubectl exec -n "$HS_NAMESPACE" "$HS_POD" -- \
            headscale nodes delete --identifier "$hid" --force >/dev/null 2>&1; then
        echo "  deleted headscale entry id=$hid ($name)."
    else
        echo "  WARNING: could not delete headscale entry id=$hid ($name)." >&2
        FAILED=1
    fi
done

echo ""
echo "Done. Remaining headscale entries:"
kubectl exec -n "$HS_NAMESPACE" "$HS_POD" -- headscale nodes list 2>/dev/null | sed 's/^/  /' || true
exit "$FAILED"
