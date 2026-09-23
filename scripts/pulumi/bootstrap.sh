#!/bin/bash
# bootstrap.sh — `make bootstrap`: cluster bring-up / open the Bootstrap firewall posture.
#
#   no cluster in the stack → CREATE one (fresh) — bring-up needs public SSH (22) + k3s API
#                             (6443) open, so create and open-posture are one step. Then offer
#                             to harden to Production, poll the mesh VPN, and commit+push.
#   cluster exists          → just re-open the Bootstrap posture on it (`pulumi up`).
#
# Force a RECREATE over a live cluster: `make destroy` first, or `FORCE_CREATE=1 make bootstrap`.
# This is a THIN sequencer over the phase functions in _lifecycle.sh — no `exec`, and it never
# re-invokes production.sh (hardening is an inline phase).
#
# Usage: bootstrap.sh [--complete]   (ARGS forwarded from make; --force is rejected, see below)
#
#   --complete  auto-answer the three post-create offers (production hardening, mesh-node
#               provisioning, commit & push) with yes, so a recreate runs unattended.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PS_FILE="$REPO_ROOT/project_settings.ts"
source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_lifecycle.sh"
init_tty_colors

# Trap J: --force is Production-only (there it skips the tunnel probe). Letting it mean "wipe and
# reinstall the live cluster" on bootstrap is a muscle-memory accident (fresh create reinstalls
# the CP0 box). Reject it; point at the deliberate escape hatches.
for arg in "$@"; do
    case "$arg" in
        --force)
            echo "ERROR: --force is Production-only (it skips the tunnel probe)." >&2
            echo "       To force a fresh create over an existing cluster: make destroy first," >&2
            echo "       or run FORCE_CREATE=1 make bootstrap." >&2
            exit 1
            ;;
        # Unattended run: the three post-create offers answer themselves with 'y'.
        --complete)
            export COMPLETE_RUN=1
            ;;
        # Reject typos loudly — a silently-ignored '--complet' would leave the run waiting
        # for a human at the first prompt, half an hour into a recreate.
        *)
            echo "ERROR: unknown argument '$arg' (expected: --complete)." >&2
            exit 1
            ;;
    esac
done

init_pulumi

# Dispatch: absent → fresh create (+ harden + mesh); exists → just re-open the posture.
# Locate siblings via $REPO_ROOT/scripts/pulumi, NOT $SCRIPT_DIR: sourcing a runtime script in a
# phase clobbers $SCRIPT_DIR to scripts/runtime/ (Trap G in _lifecycle.sh).
source "$REPO_ROOT/scripts/pulumi/checkClusterExists.sh"

# Register the phases BEFORE the first one starts, and register the list this branch will
# actually attempt — the two paths are not the same length, so a single shared list would
# make every "N/M" wrong on one of them. Phases that self-skip later still keep their
# number (see phase_register in _common.sh).
if cluster_exists; then
    phase_register "Posture" "Re-open Bootstrap posture" "Commit & push"

    phase_begin "Posture"
    ps_set_target_state bootstrap
    phase_end ok

    phase_begin "Re-open Bootstrap posture"
    echo "cluster exists → re-opening Bootstrap posture (pulumi up)"
    bash "$REPO_ROOT/scripts/pulumi/up.sh"
    phase_end ok
else
    phase_register "Posture" "Preflight gates" "Create cluster" "Admin VPN" \
                   "ArgoCD login" "Firewall hardening" "Mesh nodes" "Commit & push"

    phase_begin "Posture"
    ps_set_target_state bootstrap
    phase_end ok

    phase_begin "Preflight gates"
    echo "no cluster in the stack → fresh create (Bootstrap posture)"
    # Gate: a fresh initdb cluster reuses the subdomain-stable CNPG barman S3
    # destinations from the previous incarnation. If those are non-empty,
    # `barman-cloud-check-wal-archive` fails ("Expected empty archive"), WAL
    # archiving never starts, the Postgres PVCs fill and CrashLoop (headscale
    # fill took the whole mesh down). Abort here with instructions to wipe them.
    bash "$REPO_ROOT/scripts/pulumi/checkS3BackupPathsEmpty.sh"
    # Gate: every committed SealedSecret must open with THIS stack's key, because
    # src/sealedsecrets.ts seeds the new controller from exactly that value. A file sealed
    # with any other certificate applies cleanly and yields NO Secret, so the app comes up
    # without credentials and the failure surfaces hours later as an auth error nowhere
    # near its cause (ecc193: three image-registry secrets were in that state).
    #
    # Checked here as a fail-fast — 101 files take about two seconds, against ~40 minutes of
    # bring-up that would end in a half-credentialed cluster. The REPAIRABLE moment is
    # before the destroy, which is where destroyCluster.sh checks it; by now the old
    # cluster's plaintext is already gone, so a failure here means minting new values.
    bash "$REPO_ROOT/deployment/checkSealedKeys.sh"
    phase_end ok

    # phase_create / the two offers each open and close their own phases (Create cluster,
    # Admin VPN, ArgoCD login / Firewall hardening / Mesh nodes) — see _lifecycle.sh.
    phase_create fresh
    offer_phase_harden_auto_skip
    phase_offer_mesh_provision_auto_skip
fi

# NOTHING TO DO HERE FOR THE LAB REGISTRY — remote-desktop and ollama pull their images
# from the lab registry over its NodePort (127.0.0.1:30500), and that now activates itself.
# image-registry/node-registries-config.yaml writes containerd's certs.d/<host>/hosts.toml
# directly, which containerd re-reads on EVERY pull, and the pull credential comes from an
# ordinary imagePullSecret. Neither needs a k3s restart, so there is no post-bootstrap step.
# (Until 2026-09-04 this needed a manual scripts/runtime/activateNodeRegistry.sh run,
# because the config went through /etc/rancher/k3s/registries.yaml, which k3s reads only at
# agent start.)

# Message reflects the ACTUAL final posture (offer_phase_harden_auto_skip may have flipped to Production).
phase_begin "Commit & push"
phase_offer_commit_push_auto_skip "targetState → $(ps_target_state): resync config from project_settings"
phase_end ok

# Lift the maintenance silence opened by phase_create. Apps still converging after this
# point SHOULD alert — that is the window where a stuck app is real news rather than noise.
# If this never runs (killed run, failed phase) the silence expires on its own.
bash "$REPO_ROOT/scripts/runtime/alertSilence.sh" end || true
