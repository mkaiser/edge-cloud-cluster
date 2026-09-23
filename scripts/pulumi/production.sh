#!/bin/bash
# production.sh — `make production`: harden the firewall posture.
#
# Closes public SSH (22) + k3s API (6443) on public nodes; the admin WireGuard tunnel becomes
# the only way in. Enforced by the host nftables table (publicGuardScript) on robot/hcloud nodes
# and the hcloud Cloud firewall.
#
# SAFETY: flipping to Production with a dead WireGuard path is a guaranteed lockout on robot boxes
# (recovery = `make breakglass`, worst case the Hetzner rescue console). So it runs a live
# end-to-end tunnel probe (phase_production_preflight) BEFORE changing anything. --force skips the
# probe.
#
# Thin sequencer over _lifecycle.sh phases. Usage: production.sh [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PS_FILE="$REPO_ROOT/project_settings.ts"
source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_lifecycle.sh"
init_tty_colors

FORCE=""
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE="--force"
done

init_pulumi

phase_register "Tunnel preflight" "Set Production posture" "Apply" "Commit & push"

# Prove the VPN path works before closing the public door (unless --force).
phase_begin "Tunnel preflight"
if [[ "$FORCE" != "--force" ]]; then
    phase_production_preflight || exit 1
    phase_end ok
else
    echo "--force: skipping the tunnel probe."
    phase_end skip
fi

phase_begin "Set Production posture"
ps_set_target_state production
phase_end ok

phase_begin "Apply"
# $REPO_ROOT/scripts/pulumi not $SCRIPT_DIR — a sourced runtime script may have clobbered
# SCRIPT_DIR to scripts/runtime/ (Trap G).
bash "$REPO_ROOT/scripts/pulumi/up.sh"
echo "Public SSH/6443 are now closed on public nodes. Locked out? make breakglass"
phase_end ok

phase_begin "Commit & push"
phase_offer_commit_push_auto_skip "targetState → production: resync config from project_settings"
phase_end ok
