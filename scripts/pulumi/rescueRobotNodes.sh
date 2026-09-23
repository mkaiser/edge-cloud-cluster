#!/bin/bash
# rescueRobotNodes.sh — boot every Hetzner Robot/dedicated node into rescue + hardware-reset it.
#
# WHY: the robot installimage step (src/nodes-k3s-hetzner-robot.ts) is marker-guarded — it only
# reinstalls Debian when the box is IN RESCUE and the /etc/ecc-os-installed marker is absent.
# A `make destroy` removes the hcloud resources but does NOT wipe the robot disk, so the old k3s
# + its namespaces survive on the box. The next `make bootstrap` then SKIPS the reinstall (marker
# present) and Pulumi's k8s provider talks to the SURVIVING apiserver → "namespace already exists"
# create failures. Putting the box back into rescue here means the next create reinstalls cleanly.
#
# Invoked by destroyCluster.sh (so every destroy leaves robot boxes ready for a clean rebuild).
# Idempotent + safe: no-op when there are no robot nodes; tolerant of an already-rescued box.
#
# Reads robot node identities from project_settings.ts (serverId) and Robot webservice creds from
# the Pulumi config (hetznerRobotUser / hetznerRobotPass). Caller must have the stack selected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
API="https://robot-ws.your-server.de"

log() { echo "  rescue: $*" >&2; }

# ── Robot serverIds from project_settings.ts (provider:"robot") ──────────────
# Lightweight grep/sed, not a TS load. After each `provider: "robot"` line, take the
# next `serverId: <n>` line. perl one-liner keeps the robot→serverId association in a
# single pass (portable across mawk/gawk; we don't depend on gawk's match() arrays).
SERVER_IDS=$(perl -ne '
    next if m{^\s*//};   # comments mention provider:"robot" too (prose + commented examples)
    $in = 1 if /provider:\s*"robot"/;
    if ($in && /serverId:\s*(\d+)/) { print "$1\n"; $in = 0; }
' "$ROOT_DIR/project_settings.ts" 2>/dev/null || true)

if [[ -z "${SERVER_IDS//[[:space:]]/}" ]]; then
    log "no robot nodes in project_settings — skipping."
    exit 0
fi

# ── Robot webservice creds from Pulumi config ────────────────────────────────
RU="$(pulumi config get hetznerRobotUser 2>/dev/null || true)"
RP="$(pulumi config get hetznerRobotPass 2>/dev/null || true)"
if [[ -z "$RU" || -z "$RP" ]]; then
    log "WARNING: hetznerRobotUser/hetznerRobotPass not in Pulumi config — cannot rescue robot boxes."
    log "         (next 'make bootstrap' will refuse to reinstall a box that still has its OS marker)."
    exit 0
fi

# Authorized key fingerprint for the dedicated key (so rescue accepts our SSH key).
KEYFP="$(curl -s -u "$RU:$RP" "$API/key" 2>/dev/null | python3 -c "
import sys, json
try: ks = json.load(sys.stdin)
except Exception: sys.exit(0)
for k in ks:
    k = k['key']
    if 'ecc' in k['name'].lower() or 'dedicated' in k['name'].lower():
        print(k['fingerprint']); break
" 2>/dev/null || true)"

for SID in $SERVER_IDS; do
    log "activating rescue (linux) on server $SID…"
    if [[ -n "$KEYFP" ]]; then
        curl -s -u "$RU:$RP" "$API/boot/$SID/rescue" \
            -d os=linux --data-urlencode "authorized_key=$KEYFP" >/dev/null 2>&1 \
            || log "WARNING: rescue activation request for $SID failed (continuing)."
    else
        curl -s -u "$RU:$RP" "$API/boot/$SID/rescue" -d os=linux >/dev/null 2>&1 \
            || log "WARNING: rescue activation request for $SID failed (continuing)."
    fi

    log "hardware-resetting server $SID (boots into rescue)…"
    curl -s -u "$RU:$RP" "$API/reset/$SID" -d type=hw >/dev/null 2>&1 \
        || log "WARNING: hardware reset request for $SID failed (continuing)."

    log "server $SID set to rescue + reset — next 'make bootstrap' will reinstall Debian."
done
