#!/bin/bash
# 05-prepare-data-disk.sh — put /var/lib/rancher on a node-local disk.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
# No placeholders in this step.
#
# CONDITIONAL step: runs ONLY on nodes that declare `k3sDataDisk` (project_settings
# ComputeNodeMesh.k3sDataDisk). Nodes without it never execute this file — same shape as
# 20-install-gpu.sh, which runs only for nodes declaring `gpu`.
#
# Runs FIRST of the node steps (before 10-install-prereqs.sh) and specifically BEFORE
# 40-join-cluster.sh, so /var/lib/rancher already points at a real filesystem when the k3s
# agent installs and containerd initialises its snapshotter there.
#
# WHY THIS EXISTS
# ---------------
# k3s puts containerd's snapshotter under /var/lib/rancher/k3s/agent/containerd, and
# OVERLAYFS CANNOT BE STACKED ON OVERLAYFS — the kernel rejects the mount with EINVAL.
# A netboot / live-booted node roots on an overlay (squashfs + tmpfs), so the agent never
# starts; it loops on
#     "overlayfs" snapshotter cannot be enabled for ".../containerd",
#     try using "fuse-overlayfs" or "native"
# and the join dies after ~300s with no other symptom. Measured 2026-09-09 on
# budapest-emdc-node7: three provisioning runs failed this way before the cause was found.
#
# It is also where the SIZE goes — ~10 GB of image layers after a single join, which on such
# a node would otherwise consume a RAM-backed tmpfs.
#
# ⚠ SYMLINK, NEVER A BIND MOUNT.
# 00-cleanup-node.sh runs `rm -rf /var/lib/rancher/k3s`, and rm CANNOT remove a mountpoint:
# it fails EBUSY and, under `set -e`, aborts the entire provisioning run. Measured the same
# day — bind-mounting /var/lib/longhorn killed a run at 00-cleanup-node.sh line 183, and
# mounting a CHILD (…/k3s/agent) failed identically, because rm still recurses into the
# mountpoint on its way down. Through a symlink the cleanup unlinks k3s/ and leaves the link
# itself untouched.
# The obvious objection — "k3s resolves the symlink and lands back on the overlay" — does not
# hold: the link's TARGET is on the disk, so that is where the files go. Verified by mounting
# a real multi-lowerdir overlay under the symlinked path (the exact mount containerd's
# snapshotter probe makes); it succeeded.
#
# ⚠ LONGHORN IS DELIBERATELY NOT RELOCATED. /var/lib/longhorn is deleted OUTRIGHT by the
# cleanup step (not a child of it), so a symlink there is unlinked on every provision and
# Longhorn silently recreates a real directory on the root filesystem — leaving a node that
# advertises RAM as disk. A live-booted node is wipe-on-reboot anyway, so nothing durable may
# live on it wherever the bytes sit.
#
# ⚠ THE DISK MAY BE SHARED WITH ANOTHER TENANT. At the EMDC the same partition also carries a
# foreign live-boot persistence volume (persistence.conf, rw/ with its own SSH keys, work/).
# Everything this script writes stays inside ECC_DATA_DISK_SUBDIR, and the only rm it performs
# names that one directory in full. Never widen it to a glob over the mountpoint.
#
# Inputs (env, set by the caller — both REQUIRED):
#   ECC_DATA_DISK_LABEL   filesystem LABEL of the target partition (blkid -L), not a /dev
#                         path: nvme enumeration is not stable across boots.
#   ECC_DATA_DISK_SUBDIR  directory created on it to hold our data; names the owner.
#
# Idempotent: safe to re-run. On a netboot node it MUST run on every provision, because the
# symlink lives on the ephemeral root and is gone after a reboot.
#
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 05-prepare-data-disk.sh failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

LABEL="${ECC_DATA_DISK_LABEL:-}"
SUBDIR="${ECC_DATA_DISK_SUBDIR:-}"

if [ -z "$LABEL" ] || [ -z "$SUBDIR" ]; then
  echo "ERROR: ECC_DATA_DISK_LABEL and ECC_DATA_DISK_SUBDIR must both be set." >&2
  echo "       This step runs only for nodes declaring k3sDataDisk in project_settings." >&2
  exit 1
fi
# A subdir with a path separator would escape the directory the wipe below is scoped to.
case "$SUBDIR" in
  */*|.|..|"") echo "ERROR: ECC_DATA_DISK_SUBDIR must be a single directory name, got '$SUBDIR'." >&2; exit 1 ;;
esac

echo "=== Preparing node-local data disk (label '$LABEL') ==="

DEV="$(blkid -L "$LABEL" 2>/dev/null || true)"
if [ -z "$DEV" ]; then
  echo "ERROR: no filesystem labelled '$LABEL' on this node." >&2
  echo "       Available labels:" >&2
  lsblk -o NAME,SIZE,FSTYPE,LABEL --noheadings 2>/dev/null | sed 's/^/         /' >&2
  echo "       Fix the label (e2label) or the node's k3sDataDisk.label, then re-run." >&2
  exit 1
fi
echo "  device: $DEV"

# k3s must not be running while its tree is moved out from under it. On a fresh boot there is
# nothing to stop; on a re-provision the agent may be up or crash-looping.
systemctl stop k3s-agent 2>/dev/null || true

# ⚠ REUSE AN EXISTING MOUNT rather than mounting the device a second time. The disk may
# already be mounted elsewhere by fstab — on a Jetson Orin the same NVMe is also the node's
# extraLonghornDisks disk at /mnt/storage. ext4 happily mounts one device at two paths, but
# then `00-cleanup-node.sh`'s `find /mnt -maxdepth 3 -name longhorn-disk.cfg` sees the SAME
# Longhorn disk under both paths and double-counts its replicas, so its refuse-to-wipe guard
# reports twice the real number. Sharing the disk with Longhorn is fine — the two live in
# separate subdirectories — but it must be ONE mountpoint.
MNT="$(findmnt -n -o TARGET --source "$DEV" 2>/dev/null | head -1)"
if [ -n "$MNT" ]; then
  echo "  already mounted at $MNT — reusing it"
else
  MNT=/mnt/ecc-data
  mkdir -p "$MNT"
  mount "$DEV" "$MNT"
fi

OURS="$MNT/$SUBDIR"

# Discard the PREVIOUS boot's tree. The reboot wipes the node's root but NOT this disk, so
# without this a "fresh" node inherits a dead cluster's image layers and k3s state.
# Scoped to our own directory, named in full — see the shared-disk warning above.
if [ -e "$OURS" ]; then
  # An earlier revision, or a partially-applied run, may have left a bind mount here.
  while findmnt -n /var/lib/rancher >/dev/null 2>&1; do umount /var/lib/rancher || break; done
  rm -rf "${OURS:?}"
fi
mkdir -p "$OURS/rancher"

# Say whose data this is, on a disk other people also use.
cat > "$OURS/README.txt" <<TXT
$SUBDIR — Kubernetes (k3s) node scratch

Holds : rancher/ -> symlinked from /var/lib/rancher (k3s agent state, container images).

THIS IS SCRATCH. Nothing here is a backup and nothing needs to survive. Delete this whole
directory whenever the node is reassigned; nothing is lost.

It lives in its own directory because this filesystem is shared: anything outside this
directory belongs to someone else and is never touched by our provisioning.

Recreated on every provisioning run by 05-prepare-data-disk.sh.
TXT
chmod 644 "$OURS/README.txt"

# Symlink, not a bind mount — see the header. Any pre-existing content on the root filesystem
# is discarded rather than copied: this step runs before the join, so there is nothing to keep.
rm -rf /var/lib/rancher
ln -sfn "$OURS/rancher" /var/lib/rancher

echo "  /var/lib/rancher -> $(readlink /var/lib/rancher)"
echo "  filesystem: $(findmnt -no FSTYPE -T /var/lib/rancher/)  free: $(df -h "$MNT" | awk 'NR==2{print $4}')"

# Fail loudly here rather than 300s into the k3s join with a snapshotter error, which is the
# failure this whole step exists to prevent.
FSTYPE="$(findmnt -no FSTYPE -T /var/lib/rancher/)"
if [ "$FSTYPE" = "overlay" ]; then
  echo "ERROR: /var/lib/rancher is still on an overlay filesystem — k3s will not start." >&2
  exit 1
fi

echo "=== Data disk ready ==="
