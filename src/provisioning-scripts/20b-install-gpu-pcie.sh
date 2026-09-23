#!/bin/bash
# 20b-install-gpu-pcie.sh — discrete PCIe GPU host enablement (desktop driver).
#
# SOURCED by 20-install-gpu.sh when --gpu is NOT jetson-* — NOT executed standalone.
# Inherits: set -euo pipefail, root, $GPU_TYPE, $REBOOT_REQUIRED.
#
# Unlike the Jetson path there is no flash to supply the driver, so this installs it. That
# plus the nouveau blacklist means the node needs ONE REBOOT before the GPU is usable; this
# script sets REBOOT_REQUIRED=1 and lets the caller stop the pipeline.
#
# Deliberately NOT done here: the CUDA toolkit (upstream x86 serving images carry their own
# nvcc/ptxas, unlike the Jetson vLLM image) and any container-runtime mode pin (mode=auto
# resolves to the NVML path, which is what discrete GPUs want).

echo "=== GPU host enablement (discrete PCIe / desktop driver: $GPU_TYPE) ==="

# Pinned driver branch. 580 is a production branch that still supports Turing (sm_75).
# Do NOT float this to unversioned `nvidia-driver-server` or bump blindly — a newer branch
# may DROP Turing, and the failure mode is a node that provisions fine but has no GPU.
NVIDIA_DRIVER_PKG="nvidia-driver-580-server"  # renovate: tracked by "Ubuntu nvidia driver" regex

# ── P1. Secure Boot assertion ─────────────────────────────────────────────────
# The DKMS-built nvidia module is UNSIGNED, so with Secure Boot enforcing it will not load
# and the node comes up driverless. Fail LOUD rather than produce a silently broken node.
if [ -d /sys/firmware/efi ] && command -v mokutil >/dev/null 2>&1 \
   && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  echo "ERROR: Secure Boot is ENABLED — the DKMS nvidia module will not load unsigned." >&2
  echo "       Enroll a MOK key manually or disable Secure Boot, then re-run." >&2
  exit 1
fi

# ── P2. Blacklist nouveau ─────────────────────────────────────────────────────
# nouveau binds the cards and drives the console framebuffer, so it holds refs and CANNOT
# be rmmod'd live — do not try. The blacklist stops the *automatic* modprobe; the initramfs
# rebuild is the load-bearing part, because without it the OLD initramfs still loads nouveau
# at boot and the nvidia module then fails to bind.
# (The driver package ships its own blacklist too; writing ours anyway is idempotent and
# keeps the intent explicit in git rather than depending on packaging being kind to us.)
NOUVEAU_CONF=/etc/modprobe.d/blacklist-nouveau.conf
NOUVEAU_TMP="$(mktemp)"
cat > "$NOUVEAU_TMP" <<'NOUVEAUCONF'
# Managed by 20b-install-gpu-pcie.sh — do not edit.
blacklist nouveau
options nouveau modeset=0
NOUVEAUCONF
# cmp, not a string compare: $(cat) strips the trailing newline on BOTH sides in some shells
# but not others, which made an already-correct file look different and rebuilt the initramfs
# (~20s) on every re-provision. Byte comparison is unambiguous.
if ! cmp -s "$NOUVEAU_TMP" "$NOUVEAU_CONF" 2>/dev/null; then
  echo "Blacklisting nouveau (+ initramfs rebuild)..."
  install -m 0644 "$NOUVEAU_TMP" "$NOUVEAU_CONF"
  update-initramfs -u
else
  echo "nouveau already blacklisted."
fi
rm -f "$NOUVEAU_TMP"

# ── P3. Proprietary driver ────────────────────────────────────────────────────
# PROPRIETARY, not -open: the open kernel modules are not the supported path on Turing.
# The -server flavour omits the desktop X/Wayland stack, useless on a headless k8s node.
if dpkg -l "$NVIDIA_DRIVER_PKG" 2>/dev/null | grep -q '^ii'; then
  echo "$NVIDIA_DRIVER_PKG already installed."
else
  echo "Installing $NVIDIA_DRIVER_PKG (builds the DKMS module — a few minutes)..."
  apt-get update -qq || echo "WARNING: apt-get update reported errors — continuing." >&2
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$NVIDIA_DRIVER_PKG"
fi

# ── P4. Is the module actually live? ──────────────────────────────────────────
if nvidia-smi -L >/dev/null 2>&1; then
  echo "nvidia driver is live:"
  nvidia-smi -L | sed 's/^/  /'
  nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader 2>/dev/null \
    | sed 's/^/  /' || true
  # ── P5. Persistence mode ────────────────────────────────────────────────────
  # Keeps the driver initialised when no client holds a context, so a pod's first CUDA
  # context does not pay driver init. Non-fatal.
  if nvidia-smi -pm 1 >/dev/null 2>&1; then
    echo "Persistence mode enabled."
  else
    echo "NOTE: could not enable persistence mode (non-fatal)."
  fi
else
  echo "nvidia kernel module is NOT loaded yet (expected on the first pass)." >&2
  REBOOT_REQUIRED=1
fi
