#!/bin/bash
# restoreLonghornVolumes.sh — bring Longhorn volumes back from their S3 backups after a restore.
#
# WHY THIS EXISTS
# ---------------
# ⚠ FIRST: this is a RECOVERY TOOL, not the primary mechanism. `LonghornRestoreComponent`
# (src/longhorn-restore.ts, wired in main.ts under targetState=="restore") is the built-in
# volume restore. On 2026-09-07 it never ran — pulumi aborted on "already exists" namespace
# errors from components ordered before it — which is how 25 volumes were left faulted. If you
# are reaching for this script during a recreate, check whether that abort (ToDo.md §9) is the
# real problem. Use this to repair a cluster whose restore already aborted.
#
# `make restore` restores ETCD only when its pulumi pass aborts early. Every Kubernetes object comes back — PVCs, PVs,
# StatefulSets, ArgoCD Applications — but the Longhorn REPLICA DATA does not: the replicas
# lived on disks that the teardown wiped. So the cluster reports itself healthy (ArgoCD sees
# the manifests it expects) while every pod that mounts a volume sits on
#   MountVolume.MountDevice failed ... volume <pvc> hasn't been attached yet
# and the volumes read `detached / faulted`.
#
# Measured 2026-09-07 after a verified etcd restore: 25 of 33 volumes faulted, which took the
# headscale volume with them → VPN control-plane down → all 5 mesh nodes NotReady. A restore
# that returns etcd but not storage is not a restore.
#
# ⚠ THE STALE-DISK TRAP — this bites FIRST and makes everything else look broken.
# The teardown rescue-wipes the robot box, so /var/lib/longhorn is recreated with a NEW
# diskUUID while the Longhorn `Node` CR still records the OLD one. Longhorn then refuses the
# disk:
#   Disk ... is not ready: record diskUUID doesn't match the one on the disk
# and every scheduling attempt fails with the misleading
#   disks are unavailable: no disks found on node <node>
# No replica can be created — with or without a backup — until that is cleared. Dropping the
# stale disk from `.spec.disks` makes longhorn-manager re-register the real one immediately.
# Do this BEFORE touching any volume; otherwise a recreated volume just sits faulted and the
# real cause stays hidden two levels down in the manager log.
#
# WHAT IT DOES
#   1. Clears stale disks (recorded diskUUID != on-disk diskUUID) on every Longhorn node.
#   2. For every faulted volume with a backup in S3: delete the empty volume and recreate it
#      with `spec.fromBackup` pointing at that backup's latest snapshot.
#   3. Restarts the pods that were stuck waiting on those mounts, so the volumes attach —
#      EXCEPT CNPG-owned pods, which it lists instead (see the warning in step 3).
#
# Deleting the Longhorn Volume is safe: the PV/PVC are `Retain`, so the binding survives and
# the recreated volume (same name) re-binds. `spec.fromBackup` is only honoured at CREATE
# time, which is why the volume has to be recreated rather than patched.
#
# ⚠ SCOPE: this fixes the LONGHORN half only. Postgres data belongs to CNPG, which keeps its
# own barman backups in S3 and owns its pods' lifecycle — and a CNPG pod restarted while its
# volume is faulted makes the operator delete the PVC (and with it the PV), turning a
# recoverable fault into "Cluster is unrecoverable and needs manual intervention". So database
# recovery is deliberately OUT of scope here; the open design question is parked in
# plans/prompts/backup-restore.md (revision note 2026-09-07).
#
# Idempotent and safe on a healthy cluster: with no stale disks and no faulted volumes it
# reports "nothing to do" and exits 0. Read-only unless there is damage to repair.
#
# Usage: restoreLonghornVolumes.sh [--dry-run] [--timeout-seconds N]
set -euo pipefail

NS="longhorn-system"
DRY_RUN=false
WAIT_TIMEOUT=900
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --timeout-seconds) WAIT_TIMEOUT="${2:?--timeout-seconds needs a value}"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

log() { echo "  longhorn-restore: $*"; }
run() { if [ "$DRY_RUN" = true ]; then echo "  DRY-RUN: $*"; else "$@"; fi; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found." >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: cluster unreachable. Run ./scripts/runtime/getKubeConfig.sh" >&2; exit 1; }
kubectl get crd volumes.longhorn.io >/dev/null 2>&1 || {
    log "Longhorn CRDs absent — nothing to do (is longhorn deployed yet?)."; exit 0; }

# ── 1. Clear stale disks (the trap above) ────────────────────────────────────
# The on-disk UUID lives in <path>/longhorn-disk.cfg, readable through any manager pod that
# mounts it — the one ON that node, so read each node's config from its own manager.
log "checking for stale Longhorn disks (wiped disk, stale recorded UUID)…"
stale_found=0
while read -r node; do
    [ -z "$node" ] && continue
    mgr=$(kubectl -n "$NS" get pods -l app=longhorn-manager -o json 2>/dev/null \
          | jq -r --arg n "$node" '.items[]|select(.spec.nodeName==$n and .status.phase=="Running")|.metadata.name' | head -1)
    [ -z "$mgr" ] && { log "  $node: no running longhorn-manager — skipping"; continue; }

    while read -r disk path recorded; do
        [ -z "$disk" ] && continue
        actual=$(kubectl -n "$NS" exec "$mgr" -- cat "$path/longhorn-disk.cfg" 2>/dev/null \
                 | jq -r '.diskUUID // empty' 2>/dev/null || true)
        # No cfg at all = a genuinely fresh disk Longhorn has not initialised yet; leave it.
        [ -z "$actual" ] && continue
        [ "$actual" = "$recorded" ] && continue
        stale_found=$((stale_found+1))
        log "  $node: disk $disk STALE (recorded=${recorded:0:8}… actual=${actual:0:8}…) — re-registering"
        # Longhorn refuses to remove a schedulable disk, so disable it first. Preserve the
        # tags: they are what diskSelector matches, and losing them silently unschedules
        # every volume that selects on them.
        tags=$(kubectl -n "$NS" get nodes.longhorn.io "$node" -o json 2>/dev/null \
               | jq -c --arg d "$disk" '.spec.disks[$d].tags // []')
        run kubectl -n "$NS" patch nodes.longhorn.io "$node" --type merge \
            -p "{\"spec\":{\"disks\":{\"$disk\":{\"allowScheduling\":false,\"path\":\"$path\",\"tags\":$tags}}}}" >/dev/null
        run kubectl -n "$NS" patch nodes.longhorn.io "$node" --type json \
            -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$disk\"}]" >/dev/null
    done < <(kubectl -n "$NS" get nodes.longhorn.io "$node" -o json 2>/dev/null | jq -r '
        (.spec.disks // {}) as $s | (.status.diskStatus // {}) | to_entries[]
        | "\(.key) \($s[.key].path // "/var/lib/longhorn") \(.value.diskUUID // "")"')
done < <(kubectl -n "$NS" get nodes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

if [ "$stale_found" -gt 0 ]; then
    log "re-registered $stale_found stale disk(s); waiting for them to come up Ready…"
    for _ in $(seq 1 30); do
        notready=$(kubectl -n "$NS" get nodes.longhorn.io -o json 2>/dev/null | jq -r '
            [.items[].status.diskStatus // {} | to_entries[]
             | select(([.value.conditions[]?|select(.type=="Ready")|.status]|first) != "True")] | length')
        [ "${notready:-1}" -eq 0 ] && break
        sleep 10
    done
fi

# ── 2. Recreate faulted volumes from their backups ──────────────────────────
faulted=$(kubectl -n "$NS" get volumes.longhorn.io -o json 2>/dev/null \
          | jq -r '.items[]|select(.status.robustness=="faulted")|.metadata.name')
if [ -z "$faulted" ]; then
    log "no faulted volumes — nothing to restore."
    [ "$stale_found" -gt 0 ] && log "(stale disks were re-registered; that alone may have been the fix)"
    exit 0
fi
log "faulted volumes: $(echo "$faulted" | wc -l)"

target=$(kubectl -n "$NS" get backuptarget default -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true)
[ -n "$target" ] || { echo "ERROR: no Longhorn backup target configured — cannot restore." >&2; exit 1; }
log "backup target: $target"

restored=0; unbacked=0; consumers=""
for vol in $faulted; do
    bv=$(kubectl -n "$NS" get backupvolumes.longhorn.io -o json 2>/dev/null \
         | jq -r --arg v "$vol" '.items[]|select(.status.volumeName==$v or (.metadata.name|startswith($v+"-")))|.metadata.name' | head -1)
    last=""
    [ -n "$bv" ] && last=$(kubectl -n "$NS" get backupvolumes.longhorn.io "$bv" -o jsonpath='{.status.lastBackupName}' 2>/dev/null || true)
    if [ -z "$last" ]; then
        # No backup = nothing to restore FROM. Never delete such a volume: an empty faulted
        # volume still carries its spec, and a human may be able to salvage a replica.
        log "  $vol: NO BACKUP in S3 — left untouched (cannot restore, will stay faulted)"
        unbacked=$((unbacked+1)); continue
    fi

    # Remember the consumer before deleting anything, so step 3 can kick it.
    claim=$(kubectl get pv "$vol" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}' 2>/dev/null || true)
    [ -n "$claim" ] && consumers="$consumers $claim"

    spec=$(kubectl -n "$NS" get volumes.longhorn.io "$vol" -o json 2>/dev/null | jq -c \
        --arg fb "${target%/}/?backup=${last}&volume=${vol}" \
        '{apiVersion,kind,metadata:{name:.metadata.name,namespace:.metadata.namespace},
          spec:(.spec|.fromBackup=$fb)}')
    [ -n "$spec" ] || { log "  $vol: could not read spec — skipping"; continue; }

    log "  $vol: recreating from $last"
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY-RUN: delete + recreate $vol with fromBackup=${last}"
    else
        kubectl -n "$NS" delete volumes.longhorn.io "$vol" --timeout=60s >/dev/null 2>&1 || true
        printf '%s' "$spec" | kubectl apply -f - >/dev/null 2>&1 \
            && restored=$((restored+1)) \
            || log "  $vol: RECREATE FAILED"
    fi
done
log "recreated $restored volume(s) from backup; $unbacked without a backup"
[ "$DRY_RUN" = true ] && exit 0

# ── 3. Kick the pods that were stuck on those mounts ────────────────────────
# `fromBackup` restores on FIRST ATTACH, and the attach only happens when a consumer asks
# for it. A pod already in mount-retry backoff can wait minutes, so delete it to force a
# fresh attempt. StatefulSet/Deployment pods are recreated by their controller.
#
# ⚠ NEVER restart a CNPG-owned pod here. Measured 2026-09-07: deleting the database pods of 8
# CNPG clusters while their volumes were still faulted made the operator DELETE THE PVCs, and
# the PVs went with them (`Retain` does not save you — the PV is removed along with the claim).
# That turned a recoverable storage fault into 8 clusters reporting
#   "Cluster is unrecoverable and needs manual intervention"
# with `.status.instanceNames` wiped, which the operator will not recover from on its own.
# CNPG owns its own pod lifecycle and has its own barman backups in S3; the database half of a
# restore is ITS job, not this script's. Leave those pods alone and report them instead.
# The open question of how to drive that CNPG recovery is parked in
# plans/prompts/backup-restore.md (revision note 2026-09-07).
log "restarting pods that were waiting on those volumes (CNPG-owned pods are skipped)…"
kicked=0; skipped_cnpg=""
for claim in $consumers; do
    ns="${claim%%/*}"; pvc="${claim##*/}"
    while read -r pod; do
        [ -z "$pod" ] && continue
        # Any pod the CNPG operator manages: identified by its own label, not by name.
        if kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.labels.cnpg\.io/cluster}' 2>/dev/null | grep -q .; then
            skipped_cnpg="$skipped_cnpg $ns/$pod"
            continue
        fi
        kubectl -n "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 && kicked=$((kicked+1))
    done < <(kubectl -n "$ns" get pods -o json 2>/dev/null | jq -r --arg p "$pvc" '
        .items[]|select(.spec.volumes[]?.persistentVolumeClaim.claimName==$p)|.metadata.name')
done
log "restarted $kicked pod(s)"
if [ -n "$skipped_cnpg" ]; then
    log "SKIPPED CNPG-owned pod(s) — recover these through CNPG, not by restarting them:"
    for p in $skipped_cnpg; do log "    $p"; done
fi

# ── 4. Wait for the volumes to come back healthy ────────────────────────────
log "waiting up to ${WAIT_TIMEOUT}s for volumes to attach…"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    bad=$(kubectl -n "$NS" get volumes.longhorn.io -o json 2>/dev/null \
          | jq -r '[.items[]|select(.status.robustness=="faulted")]|length')
    [ "${bad:-1}" -le "$unbacked" ] && { log "all restorable volumes are out of faulted state."; break; }
    sleep 15
done

kubectl -n "$NS" get volumes.longhorn.io \
    -o custom-columns='STATE:.status.state,ROBUSTNESS:.status.robustness' --no-headers 2>/dev/null \
    | sort | uniq -c | sed 's/^/  /'

still=$(kubectl -n "$NS" get volumes.longhorn.io -o json 2>/dev/null \
        | jq -r '[.items[]|select(.status.robustness=="faulted")]|length')
if [ "${still:-0}" -gt "$unbacked" ]; then
    echo "WARNING: $still volume(s) still faulted (expected at most $unbacked without backups)." >&2
    echo "         Check: kubectl -n $NS logs -l app=longhorn-manager --tail=100 | grep -i restore" >&2
    exit 1
fi
log "done."
