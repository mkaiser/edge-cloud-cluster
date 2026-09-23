#!/bin/bash
# meshSkipUnreachable.sh — set `meshNodeProvisionSkip` for mesh boxes that cannot be reached,
# so a `pulumi up` does not hard-fail on one that is powered off.
#
# WHY THIS EXISTS SEPARATELY FROM provisionMeshNodes.sh.
# The skip mechanism it feeds is not new: src/nodes-k3s-mesh.ts already declines to
# instantiate `mesh-provision-<id>` for any id in `meshNodeProvisionSkip`, and that is the
# ONLY Command that dials a box. What was missing is that the probe populating that config
# key ran in exactly one place — provisionMeshNodes.sh, i.e. `make provision-mesh-node` and
# the post-create offer in _lifecycle.sh.
#
# Every OTHER entry point applied the program with whatever value the key happened to hold
# from a previous run. So `make production`, the hardening phase of `make bootstrap
# --complete`, and re-opening Bootstrap posture all ran `pulumi up` with a STALE skip list.
# A mesh node whose box does not exist yet fails like this:
#
#   command:remote:Command (mesh-provision-unibi-hclab-fs-container):
#     error: after 10 failed attempts: dial tcp xxx.xxx.xxx.xxx:3004: i/o timeout
#   command:local:Command (mesh-label-unibi-hclab-fs-container):
#     error: signal: killed          <- the 240x5s wait-for-register loop, killed by ^C
#
# One unreachable box failed the whole stack update — including resources with nothing to do
# with the mesh. That is the failure mode this closes.
#
# ⚠ IT IS DELIBERATELY NOT A PROBE OF ITS OWN. It shells out to the SAME probe in
# provisionMeshNodes.sh (--probe-only), so the two cannot drift. That probe is subtle in a way
# worth preserving: SSH-unreachable is NOT automatically "skip". A box that is off-VPN but
# Ready in k8s with a matching fingerprint needs no SSH at all, and skipping it would churn
# its provision resource out of Pulumi state for nothing. Only a genuinely unfinished node
# (absent / NotReady / stale fingerprint) is skipped.
#
# ⚠ `make destroy` DOES NOT NEED THIS. Teardown is already covered by a stronger guard:
# targetState "destroy" (and "shutdown") makes src/nodes-k3s-mesh.ts skip the remote Command
# for EVERY mesh node unconditionally, reachable or not (see the `teardown` const there). This
# script closes the *other* half — the apply paths, in every other state.
#
# Never fatal: a probe that cannot run leaves the config untouched and returns 0. Failing
# here would block the very applies it exists to protect.
#
# Usage:
#   bash scripts/pulumi/meshSkipUnreachable.sh          # probe + set meshNodeProvisionSkip
#   bash scripts/pulumi/meshSkipUnreachable.sh --show   # report only, change nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHOW_ONLY=""
[ "${1:-}" = "--show" ] && SHOW_ONLY=1

command -v pulumi >/dev/null || { echo "meshSkipUnreachable: pulumi not found — skipping." >&2; exit 0; }

# No mesh nodes at all ⇒ nothing to guard. Cheap and avoids a pointless probe pass.
# shellcheck source=scripts/pulumi/_meshNodes.sh
source "$SCRIPT_DIR/_meshNodes.sh" 2>/dev/null || exit 0
NODES="$(meshNodesTsv "$REPO_ROOT/project_settings.ts" 2>/dev/null || true)"
ENABLED_IDS="$(printf '%s\n' "$NODES" | awk -F'\t' '$6=="true"{print $1}' | grep -v '^$' || true)"
if [ -z "$ENABLED_IDS" ]; then
    echo "meshSkipUnreachable: no enabled mesh nodes — nothing to probe."
    exit 0
fi

echo "── mesh pre-flight: probing boxes so an offline one cannot fail the apply ──" >&2
SKIP_LIST="$(bash "$SCRIPT_DIR/provisionMeshNodes.sh" --probe-only 2>&1)"
RC=$?
printf '%s\n' "$SKIP_LIST" >&2
if [ $RC -ne 0 ]; then
    echo "meshSkipUnreachable: probe failed (rc=$RC) — leaving meshNodeProvisionSkip unchanged." >&2
    exit 0
fi

# The probe prints the final value on its last SKIP= line; empty is a valid answer and means
# "every enabled box is reachable", which must CLEAR a stale list rather than keep it.
NEW_SKIP="$(printf '%s\n' "$SKIP_LIST" | sed -n 's/^SKIP=//p' | tail -n1)"
CUR_SKIP="$(cd "$REPO_ROOT" && pulumi config get meshNodeProvisionSkip 2>/dev/null || true)"

if [ "$NEW_SKIP" = "$CUR_SKIP" ]; then
    echo "meshSkipUnreachable: meshNodeProvisionSkip already '${CUR_SKIP:-<empty>}' — unchanged." >&2
    exit 0
fi
if [ -n "$SHOW_ONLY" ]; then
    echo "meshSkipUnreachable: would set meshNodeProvisionSkip='${NEW_SKIP:-<empty>}' (was '${CUR_SKIP:-<empty>}')." >&2
    exit 0
fi
(cd "$REPO_ROOT" && pulumi config set meshNodeProvisionSkip "$NEW_SKIP") \
    && echo "meshSkipUnreachable: meshNodeProvisionSkip='${NEW_SKIP:-<empty>}' (was '${CUR_SKIP:-<empty>}')." >&2
exit 0
