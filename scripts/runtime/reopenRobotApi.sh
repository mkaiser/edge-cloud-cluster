#!/bin/bash
# reopenRobotApi.sh — reopen host-nft public SSH (22) + k3s API (6443) on robot/dedicated
# boxes over whatever SSH path still works (public IP first, then privateIp over the admin
# WireGuard tunnel). This is breakglass.sh's *Layer 2* (the host-nftables enforcer) factored
# out so both callers share ONE copy of the reopen logic:
#
#   • breakglass.sh  — sources this file for its host-nft repair (it adds Layer 1, the Robot
#                      webservice firewall restore, and a rescue-system fallback on top).
#   • destroyCluster.sh — runs this standalone before its teardown `pulumi up`/`pulumi destroy`:
#                      in Production the guard drops public 6443, so the Pulumi k8s provider
#                      (whose kubeconfig points at the public IP) can't reach the API to delete
#                      Helm releases. Reopening 6443 over WG lets destroy complete.
#
# Sourcing contract: when sourced, only defines functions + NFT_OPEN_CMD (no side effects) if
# REOPEN_ROBOT_API_SOURCED is set by the caller BEFORE sourcing. Run directly (or without that
# var) → parses robot nodes and reopens each. Best-effort: never fatal on its own (a genuinely
# unreachable box means there is nothing to reopen); exits 0 unless a hard arg error.
set -euo pipefail

REOPEN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REOPEN_REPO_ROOT="$(cd "$REOPEN_SCRIPT_DIR/../.." && pwd)"

# ── The reopen itself (runs ON the box over SSH) ─────────────────────────────
# Inserts an accept for tcp/22+6443 ahead of the chain's drop in the LIVE ruleset, then
# patches /etc/nftables.conf so a reboot doesn't re-close it (the `breakglass` comment doubles
# as the idempotency guard for the persisted edit). Idempotent: the live `nft insert` is
# harmless if repeated, and the file edit is skipped once the comment is present.
NFT_OPEN_CMD='
set -e
if ! nft list table inet public_guard >/dev/null 2>&1; then
    echo "public_guard not present — nothing to open"; exit 0
fi
# insert = prepend to the chain head, i.e. ahead of every drop
nft insert rule inet public_guard input tcp dport { 22, 6443 } counter accept
if [ -f /etc/nftables.conf ] && ! grep -q "breakglass" /etc/nftables.conf; then
    sed -i "s#^\(\s*\)ct state invalid drop#\1tcp dport { 22, 6443 } counter accept comment \"breakglass\"\n\1ct state invalid drop#" /etc/nftables.conf
fi
echo "public_guard: tcp 22,6443 re-opened (live + persisted)"
'

# Try one SSH target; return 0 on success.
# known_hosts-free on purpose: a recreate re-keys the same IP, and accept-new REFUSES a changed
# key — a stale pin must never be what blocks re-opening a locked-out node.
#
# ⚠ stderr is CAPTURED, never discarded. In the Production posture the public-IP attempt is
# EXPECTED to fail — that is what the reopen is for — so printing its timeout on every run
# would be pure noise, and this used to be a flat `2>/dev/null`. But when EVERY path fails,
# that stderr is the only evidence of why, and throwing it away cost two `make destroy` runs
# (2026-09-13) that reported nothing but "no SSH path" while a manual SSH to the same box
# succeeded seconds later. So: keep each attempt's stderr, stay quiet while some path still
# works, and let reopen_all_robot_nodes print it for a node it could not reach at all.
# stdout is left alone — NFT_OPEN_CMD's own "re-opened" line belongs in the log.
SSH_ERR_LOG=""
open_nft_via_ssh() {
    local target="$1" label="$2"
    echo "reopenRobotApi:   trying SSH via $label ($target)…" >&2
    local errf rc
    errf=$(mktemp)
    # `if`, not a bare `ssh` + `rc=$?`: under `set -e` a bare failing ssh aborts the shell
    # THERE, skipping the stderr capture below — the very thing we came for. Wrapping it in a
    # condition keeps set -e off the ssh itself so the failure is always recorded.
    # This does NOT make the function safe as a bare statement: it is a predicate and still
    # `return 1`s on failure, which set -e acts on in the caller. Every call site uses it in a
    # condition (`if a || b`), which is the contract.
    if ssh -o BatchMode=yes -o ConnectTimeout=8 \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           "root@$target" "$NFT_OPEN_CMD" 2>"$errf"; then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        rm -f "$errf"
        echo "reopenRobotApi:   ✓ host nft opened via $label." >&2
        return 0
    fi
    SSH_ERR_LOG+="    [$label $target] exit $rc"$'\n'
    while IFS= read -r line; do
        [[ -n "$line" ]] && SSH_ERR_LOG+="      $line"$'\n'
    done < "$errf"
    rm -f "$errf"
    return 1
}

# Reopen every robot node in project_settings.ts. Returns the count that could NOT be reopened
# (0 = all good / no robot nodes). Never exits the shell itself — caller decides fatality.
reopen_all_robot_nodes() {
    local ps_file="$REOPEN_REPO_ROOT/project_settings.ts"
    # serverId + publicIp + privateIp per robot node (same single-pass perl idiom as
    # breakglass.sh / rescueRobotNodes.sh — a grep, not a TS load; skips commented examples).
    local nodes
    # ⚠ Do NOT emit on whichever IP happens to come last in the file. project_settings.ts
    # lists privateIp BEFORE publicIp, so keying the print on privateIp fired with $pub still
    # empty and produced "serverId <privateIp> <empty>" — the public and private targets ended
    # up swapped and the private fallback was never tried. Measured 2026-09-05: the helper
    # reported `publicIp=10.0.1.2 privateIp=` and then "no SSH path", on a box that was
    # reachable. Collect both, emit when the record ENDS (both seen, or the next node starts).
    nodes=$(perl -ne '
        next if m{^\s*//};
        if (/provider:\s*"robot"/) {
            print "$sid $pub $priv\n" if $sid && $pub && $priv;
            $in = 1; $sid=""; $pub=""; $priv="";
        }
        if ($in) {
            $sid  = $1 if /serverId:\s*(\d+)/;
            $pub  = $1 if /publicIp:\s*"([^"]+)"/;
            $priv = $1 if /privateIp:\s*"([^"]+)"/;
            if ($sid && $pub && $priv) { print "$sid $pub $priv\n"; $in = 0; $sid=""; $pub=""; $priv=""; }
        }
        END { print "$sid $pub $priv\n" if $sid && $pub && $priv; }
    ' "$ps_file")

    if [[ -z "${nodes//[[:space:]]/}" ]]; then
        echo "reopenRobotApi: no robot nodes in project_settings.ts — nothing to reopen." >&2
        return 0
    fi

    local failed=0
    while read -r SID PUB PRIV; do
        [[ -z "$SID" ]] && continue
        echo "reopenRobotApi: node serverId=$SID publicIp=$PUB privateIp=$PRIV" >&2
        if open_nft_via_ssh "$PUB" "public IP" || open_nft_via_ssh "$PRIV" "VPN/private IP"; then
            :
        else
            failed=$((failed + 1))
            echo "reopenRobotApi: ✗ no SSH path to $PUB (public or private) — could not reopen." >&2
            # The captured stderr from every attempt on this node — the only thing that says
            # WHY (timeout vs refused vs auth). Without it this line is undiagnosable.
            echo "reopenRobotApi:   what each attempt reported:" >&2
            printf '%s' "$SSH_ERR_LOG" >&2
        fi
        SSH_ERR_LOG=""
    done <<< "$nodes"
    return "$failed"
}

# When run directly (not sourced), do the reopen. Best-effort: a box we can't reach means there
# is nothing to reopen, so we still exit 0 (the caller's own API-reachability check is the real
# gate). ${REOPEN_ROBOT_API_SOURCED:-} lets breakglass.sh source us for the functions only.
if [[ -z "${REOPEN_ROBOT_API_SOURCED:-}" ]]; then
    if reopen_all_robot_nodes; then
        echo "reopenRobotApi: done — robot public 22/6443 reopened where reachable." >&2
    else
        echo "reopenRobotApi: WARNING: one or more robot boxes could not be reopened (continuing)." >&2
    fi
    exit 0
fi
