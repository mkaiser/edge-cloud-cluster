#!/bin/bash
# reopenCloudApi.sh — reopen the k3s API (6443) + SSH (22) on the hcloud Cloud Firewall so the
# admin can reach the cluster API over the PUBLIC path during a destroy.
#
# The hcloud counterpart of reopenRobotApi.sh. On hcloud VMs the public allow-list is enforced
# by the hcloud Cloud Firewall (`<name>-fw`), NOT the host nft table — so in Production (where
# 22/6443 are dropped) reopenRobotApi.sh cannot help a cloud-only cluster: there is no robot
# box, and the closed port lives in the hcloud API firewall. This adds a temporary allow rule
# for 22+6443 there, so `pulumi destroy`'s provider (and the destroy scripts' kubectl) can hit
# the box's own public :6443 — a path independent of the in-cluster wireguard pod, which the
# destroy tears down early. The firewall itself is deleted later in the destroy, so the rule is
# transient by construction.
#
# Best-effort and idempotent: no hcloud nodes ⇒ nothing to do; rule already present ⇒ skip;
# any API hiccup ⇒ warn, exit 0 (the caller's own reachability check is the real gate).
set -uo pipefail

REOPEN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REOPEN_REPO_ROOT="$(cd "$REOPEN_SCRIPT_DIR/../.." && pwd)"
PS_FILE="$REOPEN_REPO_ROOT/project_settings.ts"

# Only relevant when the cluster actually has hcloud nodes (the firewall attaches to them).
if ! perl -ne 'BEGIN{$rc=1} next if m{^\s*//}; if(/provider:\s*"hcloud"/){$rc=0} END{exit $rc}' "$PS_FILE"; then
    echo "reopenCloudApi: no hcloud nodes in project_settings.ts — nothing to reopen." >&2
    exit 0
fi

# HCLOUD_TOKEN from env / active context / the loaded Pulumi stack (shared helper, sourced).
# shellcheck source=../environment/createhcloudContext.sh
source "$REOPEN_SCRIPT_DIR/../environment/createhcloudContext.sh"
ensure_hcloud_token || { echo "reopenCloudApi: WARNING no HCLOUD_TOKEN — cannot reopen (continuing)." >&2; exit 0; }

# The Pulumi-managed firewall is `<general.name>-fw` with a random suffix. Match by that prefix.
FW_PREFIX="$(perl -ne 'next if m{^\s*//}; if(/name:\s*"([^"]+)"/){print "$1"; exit}' "$PS_FILE")-fw"
FW_NAME="$(hcloud firewall list -o noheader -o columns=name 2>/dev/null | grep -E "^${FW_PREFIX}" | head -1)"
if [[ -z "$FW_NAME" ]]; then
    echo "reopenCloudApi: no firewall matching '${FW_PREFIX}*' — nothing to reopen (continuing)." >&2
    exit 0
fi
echo "reopenCloudApi: firewall $FW_NAME — ensuring public 22 + 6443 are open for destroy…" >&2

# Add an inbound allow for a TCP port from anywhere (v4+v6) if not already present. hcloud
# add-rule is not idempotent (it appends duplicates), so check the current rules first.
open_port() {
    local port="$1"
    if hcloud firewall describe "$FW_NAME" -o json 2>/dev/null \
        | jq -e --arg p "$port" '.rules[] | select(.direction=="in" and .protocol=="tcp" and .port==$p)' >/dev/null 2>&1; then
        echo "reopenCloudApi:   tcp/$port already allowed." >&2
        return 0
    fi
    if hcloud firewall add-rule "$FW_NAME" --direction in --protocol tcp --port "$port" \
            --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null 2>&1; then
        echo "reopenCloudApi:   tcp/$port opened." >&2
    else
        echo "reopenCloudApi:   WARNING could not add tcp/$port rule (continuing)." >&2
    fi
}

open_port 22
open_port 6443
echo "reopenCloudApi: done." >&2
exit 0
