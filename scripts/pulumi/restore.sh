#!/bin/bash
# restore.sh — `make restore`: create a cluster FROM the S3 etcd snapshot.
#
# ⚠ SCOPE: this restores ETCD ONLY. Every Kubernetes object comes back (PVCs, PVs,
# StatefulSets, ArgoCD Applications) but the Longhorn REPLICA DATA does not — the replicas
# lived on disks the teardown wiped. The cluster therefore comes up looking healthy (ArgoCD
# sees the manifests it expects) while every pod that mounts a volume sits on
# "volume <pvc> hasn't been attached yet". Measured 2026-09-07: 25 of 33 volumes faulted,
# which took headscale's volume with them and left all 5 mesh nodes NotReady.
# ⚠ That is NOT a missing feature: LonghornRestoreComponent (src/longhorn-restore.ts, wired in
# main.ts under targetState=="restore") does restore the volumes — on 2026-09-07 it never RAN,
# because pulumi aborted earlier on the "already exists" namespace errors from components
# ordered before it. Fix that abort (ToDo.md §9) rather than adding a second mechanism.
# `scripts/runtime/restoreLonghornVolumes.sh` is the manual recovery tool for a restore that
# aborted this way; it also clears the stale-diskUUID state a rescue-wipe leaves behind, which
# otherwise blocks EVERY replica. Postgres is CNPG's own barman backups — see
# plans/prompts/backup-restore.md.
#
# Same create machinery as a fresh bootstrap, but with targetState=restore. Requires
# the Bootstrap posture (a fresh create bakes the firewall into the nodes — see phase_create's
# guard) and an empty stack (never wipe a live cluster; override with `make restore ARGS=--force`
# / FORCE_CREATE=1). After the create, offers Production hardening + mesh provisioning, same as
# bootstrap.
#
# Thin sequencer over _lifecycle.sh phases. Usage: restore.sh [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PS_FILE="$REPO_ROOT/project_settings.ts"
source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_lifecycle.sh"
init_tty_colors

# --force / FORCE_CREATE=1 bypasses the existing-cluster guard (intentional recreate/recovery).
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && export FORCE_CREATE=1
done

init_pulumi

phase_create restore
offer_phase_harden_auto_skip
phase_offer_mesh_provision_auto_skip

phase_offer_commit_push_auto_skip "targetState → $(ps_target_state): resync config from project_settings"
