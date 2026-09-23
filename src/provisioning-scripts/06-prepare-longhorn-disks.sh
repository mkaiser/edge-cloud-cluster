#!/bin/bash
# 06-prepare-longhorn-disks.sh — mount the node's EXTRA Longhorn disks, persistently.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
# No placeholders in this step.
#
# CONDITIONAL step: runs ONLY on nodes that declare `extraLonghornDisks` (project_settings
# ComputeNodeMesh.extraLonghornDisks). Nodes without it never execute this file — the same
# shape as 05-prepare-data-disk.sh, which runs only for nodes declaring `k3sDataDisk`.
#
# Runs AFTER 05-prepare-data-disk.sh and BEFORE 40-join-cluster.sh, so every disk Longhorn
# will be told about is already mounted when longhorn-manager first inspects the node.
#
# WHY THIS EXISTS
# ---------------
# A box often has far more storage than its OS disk. smartmirror1 carries two spare 916 GiB
# SSDs that the cluster simply did not use: Longhorn saw 457 GiB of a ~2.3 TiB machine,
# because `node.longhorn.io/default-disks-config` only ever named /var/lib/longhorn.
# extraLonghornDisks fixes the Longhorn side; this script fixes the HOST side, which is the
# half that has to survive a reboot.
#
# ⚠ MOUNTS, NEVER FORMATS. The filesystem must already exist and carry the LABEL named in
# settings. A node whose disk is missing or mislabelled is a configuration error, not
# something to paper over by creating a filesystem: mkfs on the wrong device destroys data
# that nothing here can bring back. This step fails loudly instead.
#
# ⚠ NEVER WIPES, unlike 05-prepare-data-disk.sh. That script rm -rf's its own subdirectory on
# every run because its content (k3s image layers) is a rebuildable cache. These disks hold
# LONGHORN REPLICAS — the live data of every volume placed on them. Deleting one is exactly
# the unrecoverable action 00-cleanup-node.sh guards against.
#
# ⚠ MOUNT POINTS LIVE OUTSIDE /var/lib/longhorn, and the settings validator enforces it. Two
# traps, both measured, both documented at length in 05-prepare-data-disk.sh:
#   - A mountpoint UNDER /var/lib/longhorn breaks provisioning outright: 00-cleanup-node.sh
#     runs `rm -rf /var/lib/longhorn`, and rm cannot remove a mountpoint — EBUSY, and under
#     `set -e` the whole run aborts.
#   - A SYMLINK at /var/lib/longhorn is unlinked by that same cleanup, after which Longhorn
#     silently recreates a real directory on the root filesystem — a node that advertises RAM
#     as disk.
#
# ⚠ PERSISTENCE IS THE POINT. A runtime-only `mount` would survive until the next reboot, at
# which point Longhorn would find its disk path empty — on the ROOT filesystem — and happily
# schedule replicas into it, silently filling the OS disk while the real SSD sat idle. So the
# fstab entry is what this script is really for; the mount is just the immediate effect.
# `nofail` so a pulled disk degrades the node instead of dropping it to an emergency shell.
#
# Inputs (env, set by the caller — REQUIRED):
#   ECC_LONGHORN_DISKS   semicolon-separated "<label>:<mountpoint>" pairs, e.g.
#                        "storage1:/mnt/storage1;storage2:/mnt/storage2"
#
# Idempotent: re-running mounts nothing new and rewrites no fstab line it already owns.
#
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 06-prepare-longhorn-disks.sh failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

DISKS="${ECC_LONGHORN_DISKS:-}"

if [ -z "$DISKS" ]; then
  echo "ERROR: ECC_LONGHORN_DISKS must be set." >&2
  echo "       This step runs only for nodes declaring extraLonghornDisks in project_settings." >&2
  exit 1
fi

echo "=== Preparing extra Longhorn disks ==="

# The marker that lets us recognise, and safely rewrite, the lines this script owns. A plain
# grep for the mountpoint would also match a hand-written entry and silently take it over.
FSTAB_TAG="# ecc-longhorn-disk"

_changed=0

IFS=';' read -r -a _entries <<< "$DISKS"
for _e in "${_entries[@]}"; do
  [ -n "$_e" ] || continue
  LABEL="${_e%%:*}"
  MNT="${_e#*:}"

  if [ -z "$LABEL" ] || [ -z "$MNT" ] || [ "$LABEL" = "$_e" ]; then
    echo "ERROR: malformed ECC_LONGHORN_DISKS entry '$_e' (want '<label>:<mountpoint>')." >&2
    exit 1
  fi
  case "$MNT" in
    /var/lib/longhorn|/var/lib/longhorn/*)
      # Defence in depth: validateClusterNodes rejects this, but a hand-run of this script
      # must not be the way it gets through.
      echo "ERROR: mountpoint '$MNT' is /var/lib/longhorn or under it — see this file's header." >&2
      exit 1 ;;
    /*) : ;;
    *) echo "ERROR: mountpoint '$MNT' must be an absolute path." >&2; exit 1 ;;
  esac

  echo "  -- $LABEL -> $MNT"

  # Resolve by LABEL, never by /dev path: sd*/nvme* enumeration is not stable across boots,
  # and mounting the wrong device here would hand Longhorn someone else's filesystem.
  DEV="$(blkid -L "$LABEL" 2>/dev/null || true)"
  if [ -z "$DEV" ]; then
    echo "ERROR: no filesystem labelled '$LABEL' on this node." >&2
    echo "       Available labels:" >&2
    lsblk -o NAME,SIZE,FSTYPE,LABEL --noheadings 2>/dev/null | sed 's/^/         /' >&2
    echo "       Fix the label (e2label \$DEV '$LABEL') or the node's extraLonghornDisks entry." >&2
    echo "       This step deliberately does NOT create a filesystem — see the header." >&2
    exit 1
  fi
  echo "     device: $DEV"

  UUID="$(blkid -s UUID -o value "$DEV" 2>/dev/null || true)"
  if [ -z "$UUID" ]; then
    echo "ERROR: could not read a UUID from $DEV." >&2
    exit 1
  fi

  mkdir -p "$MNT"

  # fstab first, then mount — so a failure leaves the node with no half-state that only a
  # human would notice. Replace our own previous line for this mountpoint (the disk may have
  # been re-created with a new UUID); leave anything we do not own alone.
  if grep -q "[[:space:]]${MNT}[[:space:]].*${FSTAB_TAG}\$" /etc/fstab 2>/dev/null; then
    _want="UUID=${UUID} ${MNT} auto defaults,nofail,x-systemd.device-timeout=10 0 2 ${FSTAB_TAG}"
    _have="$(grep "[[:space:]]${MNT}[[:space:]].*${FSTAB_TAG}\$" /etc/fstab)"
    if [ "$_have" != "$_want" ]; then
      cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
      # The mountpoint is the key; escape the slashes for sed.
      _esc="$(printf '%s' "$MNT" | sed 's|/|\\/|g')"
      sed -i "/[[:space:]]${_esc}[[:space:]].*${FSTAB_TAG}\$/c\\${_want}" /etc/fstab
      echo "     fstab: updated"
      _changed=1
    else
      echo "     fstab: already correct"
    fi
  elif grep -qE "^[^#]*[[:space:]]${MNT}[[:space:]]" /etc/fstab 2>/dev/null; then
    # Someone else already manages this mountpoint. Do not fight them — but say so, because
    # a stale UUID there is exactly the failure this script exists to prevent.
    echo "     fstab: an existing entry (not ours) already covers $MNT — leaving it alone."
  else
    cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    printf 'UUID=%s %s auto defaults,nofail,x-systemd.device-timeout=10 0 2 %s\n' \
      "$UUID" "$MNT" "$FSTAB_TAG" >> /etc/fstab
    echo "     fstab: added"
    _changed=1
  fi

  if findmnt -n "$MNT" >/dev/null 2>&1; then
    echo "     mounted already"
  else
    mount "$MNT"
    echo "     mounted"
  fi
done

# systemd caches fstab; without this a later `mount -a`/boot unit can act on the old copy.
[ "$_changed" -eq 1 ] && systemctl daemon-reload 2>/dev/null || true

# Validate what we just wrote, while we can still see the error. A broken fstab is a node
# that does not come back from its next reboot.
if ! findmnt --verify --fstab >/dev/null 2>&1; then
  echo "WARNING: findmnt --verify reports problems with /etc/fstab:" >&2
  findmnt --verify --fstab >&2 || true
fi

echo "=== Extra Longhorn disks ready ==="
df -h $(IFS=';'; for _e in $DISKS; do [ -n "$_e" ] && printf '%s ' "${_e#*:}"; done) 2>/dev/null || true
