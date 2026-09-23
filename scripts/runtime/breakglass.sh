#!/bin/bash
# breakglass.sh — `make breakglass`: lockout recovery for robot/dedicated boxes.
#
# Deliberately needs NO pulumi up and NO kubernetes: a lockout usually means the admin
# WireGuard tunnel is down, and `pulumi up` needs the k3s API, which is only reachable
# through that tunnel — using it for recovery would be circular. Everything here is plain
# ssh + the Robot webservice API (reachable from anywhere with the creds).
#
# Two layers can hold the lock; this script walks them outermost-in:
#
#   1. Robot firewall (switch port) — restored to the known-good coarse ruleset (drop
#      rpcbind/111, allow the rest) via the Robot API. In the normal design this layer is
#      already permissive and identical in both rollout postures, so this step only
#      matters when the rules were tampered with (e.g. tightened in the Robot UI).
#
#   2. Host nftables (inet public_guard) — THE enforcer. In Production it drops public
#      SSH, so it must be repaired over an SSH path that still works. Tried in order:
#        a) the box's public IP  (works in Bootstrap posture, or when nft is not loaded)
#        b) the box's privateIp  (works whenever the WireGuard tunnel is actually up)
#      On the first path that connects, tcp/22+6443 are re-opened in the LIVE ruleset
#      AND in /etc/nftables.conf (so the opening survives a reboot until the next
#      `make production` re-tightens it).
#
# If neither SSH path works, the box is only reachable via the Hetzner Robot rescue
# system (activate rescue + hardware reset in the Robot UI, then edit /etc/nftables.conf
# on the mounted disk). This script prints that procedure and exits 1 — it does NOT
# trigger rescue itself (rescue+reset reboots the box).
#
# Why can't the Robot API alone break the glass (e.g. a src_ip=<my current IP> allow
# rule)? Because the Robot firewall is not what locks you out — it is already permissive
# in both postures. The lock is the host nftables table ON the box, and no Hetzner API
# can edit host state short of rescue+reset. A source-IP rule at the Robot layer would
# let the packet through the switch only for nft to drop it on arrival.
#
# Reads robot serverIds/IPs from project_settings.ts and Robot creds from the Pulumi
# config (local file state + passphrase only — no cloud dependency).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PS_FILE="$REPO_ROOT/project_settings.ts"
API="https://robot-ws.your-server.de"

log() { echo "breakglass: $*" >&2; }

# Layer 2 (host-nft reopen of 22/6443 over public→private SSH) lives in the shared helper so
# `make destroy` can reuse the exact same reopen. Source it for its functions only
# (NFT_OPEN_CMD + open_nft_via_ssh); breakglass wraps that with Layer 1 (Robot-API restore)
# and the rescue fallback below.
REOPEN_ROBOT_API_SOURCED=1 source "$SCRIPT_DIR/reopenRobotApi.sh"
source "$SCRIPT_DIR/../pulumi/_common.sh"

# ── Pulumi config access (passphrase + local state only) ─────────────────────
init_pulumi

RU="$(pulumi config get hetznerRobotUser 2>/dev/null || true)"
RP="$(pulumi config get hetznerRobotPass 2>/dev/null || true)"

# ── Robot node identities: serverId + publicIp + privateIp, associated per node ──────
# (same single-pass perl idiom as rescueRobotNodes.sh)
NODES=$(perl -ne '
    next if m{^\s*//};   # commented-out example nodes and prose mention provider:"robot" too
    $in = 1 if /provider:\s*"robot"/;
    if ($in) {
        $sid = $1 if /serverId:\s*(\d+)/;
        $pub = $1 if /publicIp:\s*"([^"]+)"/;
        if (/privateIp:\s*"([^"]+)"/) { print "$sid $pub $1\n"; $in = 0; $sid=""; $pub=""; }
    }
' "$PS_FILE")
if [[ -z "${NODES//[[:space:]]/}" ]]; then
    log "no robot nodes in project_settings.ts — nothing to break open."
    exit 0
fi

# ── Layer 1: restore the coarse Robot firewall ruleset ───────────────────────
restore_robot_fw() {
    local sid="$1"
    if [[ -z "$RU" || -z "$RP" ]]; then
        log "  (no Robot creds in Pulumi config — skipping Robot-firewall restore for $sid)"
        return 0
    fi
    log "  Robot firewall $sid → coarse known-good ruleset (drop 111, allow rest)…"
    local http
    http=$(curl -s -o /dev/null -w '%{http_code}' -u "$RU:$RP" -X POST "$API/firewall/$sid" \
        --data-urlencode "status=active" \
        --data-urlencode "whitelist_hos=true" \
        --data-urlencode "filter_ipv6=true" \
        --data-urlencode "rules[input][0][ip_version]=ipv4" \
        --data-urlencode "rules[input][0][name]=drop-rpcbind-tcp4" \
        --data-urlencode "rules[input][0][action]=discard" \
        --data-urlencode "rules[input][0][protocol]=tcp" \
        --data-urlencode "rules[input][0][dst_port]=111" \
        --data-urlencode "rules[input][1][ip_version]=ipv4" \
        --data-urlencode "rules[input][1][name]=drop-rpcbind-udp4" \
        --data-urlencode "rules[input][1][action]=discard" \
        --data-urlencode "rules[input][1][protocol]=udp" \
        --data-urlencode "rules[input][1][dst_port]=111" \
        --data-urlencode "rules[input][2][ip_version]=ipv6" \
        --data-urlencode "rules[input][2][name]=drop-rpcbind-tcp6" \
        --data-urlencode "rules[input][2][action]=discard" \
        --data-urlencode "rules[input][2][protocol]=tcp" \
        --data-urlencode "rules[input][2][dst_port]=111" \
        --data-urlencode "rules[input][3][ip_version]=ipv6" \
        --data-urlencode "rules[input][3][name]=drop-rpcbind-udp6" \
        --data-urlencode "rules[input][3][action]=discard" \
        --data-urlencode "rules[input][3][protocol]=udp" \
        --data-urlencode "rules[input][3][dst_port]=111" \
        --data-urlencode "rules[input][4][ip_version]=ipv4" \
        --data-urlencode "rules[input][4][name]=allow-all-v4" \
        --data-urlencode "rules[input][4][action]=accept" \
        --data-urlencode "rules[input][5][ip_version]=ipv6" \
        --data-urlencode "rules[input][5][name]=allow-all-v6" \
        --data-urlencode "rules[input][5][action]=accept")
    case "$http" in
        200|202) log "  Robot firewall $sid restored (HTTP $http)." ;;
        409)     log "  Robot firewall $sid busy (409, apply in process) — likely fine; re-run if needed." ;;
        *)       log "  WARNING: Robot firewall POST for $sid → HTTP $http (continuing; nft is the enforcer)." ;;
    esac
}

# ── Layer 2: re-open SSH in the host nft table over any live SSH path ────────
# NFT_OPEN_CMD + open_nft_via_ssh come from the sourced reopenRobotApi.sh (public IP first,
# then privateIp over the WireGuard tunnel). breakglass adds the rescue fallback below when
# neither SSH path works.
RESCUE_NEEDED=0
while read -r SID PUB PRIV; do
    [[ -z "$SID" ]] && continue
    log "node serverId=$SID publicIp=$PUB privateIp=$PRIV"
    restore_robot_fw "$SID"
    if open_nft_via_ssh "$PUB" "public IP" || open_nft_via_ssh "$PRIV" "VPN/private IP"; then
        log "✓ $PUB opened. SSH: ssh root@$PUB"
    else
        RESCUE_NEEDED=1
        cat >&2 <<EOF
breakglass: ✗ no SSH path to $PUB works — last resort is the Hetzner rescue system:
    1. https://robot.hetzner.com → server $SID → Rescue → activate (linux64) → Reset (hw)
    2. ssh root@$PUB   (rescue password shown in the UI; the box's nft is NOT active in rescue)
    3. mount the system partition (e.g.: mount /dev/md2 /mnt   — installimage default RAID)
    4. edit /mnt/etc/nftables.conf: add   tcp dport { 22, 6443 } accept   before the drop,
       or   systemctl --root=/mnt disable nftables
    5. reboot — the box returns with SSH open; then fix the tunnel and 'make production'.
EOF
    fi
done <<< "$NODES"

if [[ "$RESCUE_NEEDED" == 0 ]]; then
    cat >&2 <<'EOF'

breakglass: done. NOTE: public SSH (22) and the k3s API (6443) are now OPEN TO THE INTERNET
on the opened box(es). When the tunnel works again, re-tighten with:  make production
EOF
fi
exit $RESCUE_NEEDED
