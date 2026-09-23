#!/bin/bash
# 20a-install-gpu-soc.sh — SoC/Tegra (Jetson) GPU host enablement.
#
# SOURCED by 20-install-gpu.sh when --gpu=jetson-* — NOT executed standalone.
# Inherits: set -euo pipefail, root, $GPU_TYPE. Runs as part of the mesh-join pipeline.
#
# Assumes the box is ALREADY FLASHED with L4T: the driver (nvidia-l4t-cuda, libcuda,
# nvidia-smi) comes from the flash. What the flash omits is the CUDA TOOLKIT, hence §1.
# §2b/§2c are Tegra-specific container-runtime workarounds and MUST NOT run on discrete
# PCIe nodes (mode=auto is correct there).

echo "=== GPU host enablement (Nvidia Jetson / L4T: $GPU_TYPE) ==="

# ── 1. JetPack meta-package + CUDA toolkit ────────────────────────────────────
# The FLASH gives us the DRIVER (nvidia-l4t-cuda, libcuda.so, nvidia-smi) but NOT the
# CUDA TOOLKIT — a freshly-flashed R39 box has no nvcc and no /usr/local/cuda at all.
# That matters beyond compiling: TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas is what makes
# the vLLM v1 engine's runtime triton kernels work (the bundled wheel ships no ptxas), so
# without the toolkit inference fails at the FIRST REQUEST rather than at startup.
#
# Everything here comes from the L4T apt repo that the flash already configured
# (repo.download.nvidia.com/jetson/{common,som} rNN.N) — no extra keyring or repo needed,
# and the versions are the ones matched to THIS L4T release.
#
# Idempotent + tolerant: a node whose flash already carries these skips the install, and a
# failure is a WARNING rather than fatal. Rationale: the container toolkit + k3s runtime
# wiring below is what gates SCHEDULING, and a node that can schedule GPU pods but lacks
# nvcc is still useful. A hard failure here would abort provisioning entirely.
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "L4T driver present:"
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null \
    || nvidia-smi 2>/dev/null | head -4 || true
elif command -v tegrastats >/dev/null 2>&1; then
  echo "tegrastats present (JetPack/L4T detected), but nvidia-smi is missing." >&2
else
  echo "WARNING: neither nvidia-smi nor tegrastats found — is JetPack (L4T) flashed?" >&2
fi

# Derive the CUDA toolkit package from the DRIVER's own CUDA version, rather than pinning a
# literal. `nvidia-smi` reports the highest CUDA the driver supports (e.g. 13.2 on driver
# 595.78); the toolkit must NOT be newer than that. Hardcoding a version here would silently
# rot on the next L4T bump — and an image built against a too-new toolkit dies at GPU init
# with CUDA error 803.
CUDA_VER="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)"
if [ -n "$CUDA_VER" ]; then
  CUDA_PKG="cuda-toolkit-${CUDA_VER%%.*}-${CUDA_VER##*.}"   # 13.2 -> cuda-toolkit-13-2
  echo "Driver supports CUDA $CUDA_VER -> installing $CUDA_PKG"
else
  CUDA_PKG=""
  echo "WARNING: could not read the driver's CUDA version from nvidia-smi." >&2
fi

if [ -x /usr/local/cuda/bin/nvcc ]; then
  echo "CUDA toolkit already installed: $(/usr/local/cuda/bin/nvcc --version 2>/dev/null | tail -1)"
else
  apt-get update -qq || echo "WARNING: apt-get update reported errors — continuing." >&2
  # nvidia-jetpack pulls the full runtime+dev set (cuDNN, TensorRT, VPI). It is large but is
  # the NVIDIA-supported way to get a coherent JetPack userspace; the toolkit alone is not
  # enough for TensorRT-backed workloads.
  if apt-get install -y nvidia-jetpack; then
    echo "nvidia-jetpack installed."
  else
    echo "WARNING: 'nvidia-jetpack' failed — falling back to the CUDA toolkit alone." >&2
    [ -n "$CUDA_PKG" ] && { apt-get install -y "$CUDA_PKG" \
      || echo "WARNING: '$CUDA_PKG' failed to install." >&2; }
  fi
fi

# Put nvcc/ptxas on PATH for every login shell. /usr/local/cuda is a symlink the toolkit
# maintains, so this survives a CUDA minor bump. Written as a profile.d drop-in rather than
# edited into a user's dotfiles so it applies to root and to CI shells alike.
if [ -d /usr/local/cuda/bin ]; then
  cat > /etc/profile.d/cuda.sh <<'CUDAENV'
# Managed by provisioning (20-install-gpu.sh) — do not edit.
export PATH=/usr/local/cuda/bin:$PATH
export CUDA_HOME=/usr/local/cuda
CUDAENV
  chmod 0644 /etc/profile.d/cuda.sh
  echo "CUDA on PATH via /etc/profile.d/cuda.sh: $(/usr/local/cuda/bin/nvcc --version 2>/dev/null | tail -1)"
  # ptxas is what the vLLM triton runtime path needs; flag its absence explicitly because the
  # failure it causes ("Cannot find ptxas") surfaces much later, at the first inference call.
  [ -x /usr/local/cuda/bin/ptxas ] \
    || echo "WARNING: /usr/local/cuda/bin/ptxas missing — triton kernels will fail at inference." >&2
else
  echo "WARNING: /usr/local/cuda/bin absent — nvcc/ptxas unavailable on this node." >&2
fi


# ── 2b. Force the nvidia container runtime into CDI mode ─────────────────────
# The runtime defaults to mode="auto", which on Tegra resolves to the "csv" mode and
# then FAILS at container-create with `unsupported device id: tegra` (csv can't resolve
# the L4T iGPU). A valid CDI spec IS produced on Jetson by the nvidia-cdi-refresh.service
# (/var/run/cdi/nvidia.yaml, kind nvidia.com/gpu, device 0 = the iGPU). Pin mode=cdi so
# the runtime uses that spec — the NVIDIA-intended path for Jetson. Without this, GPU
# pods run but see NO GPU (torch.cuda.is_available()=False → vLLM "Failed to infer device
# type"), because containerd 2.x ignored the alternative (cdi.k8s.io/*) annotation path.
echo "Setting nvidia-container-runtime mode=cdi..."
nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi
# Ensure a CDI spec exists now (the refresh service regenerates it on driver changes, but
# generate once so the very first GPU pod after provisioning has it). Non-fatal: the
# systemd path unit also maintains it.
nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml 2>/dev/null \
  || echo "NOTE: 'nvidia-ctk cdi generate' failed — relying on nvidia-cdi-refresh.service." >&2
nvidia-ctk cdi list 2>/dev/null | sed 's/^/  cdi: /' || true

# ── 2c. Make the CDI spec survive a reboot ───────────────────────────────────
# The spec at /var/run/cdi/nvidia.yaml is what `mode=cdi` resolves nvidia.com/gpu against,
# and /var/run is TMPFS — so it is wiped on every boot. NVIDIA ships nvidia-cdi-refresh
# .service/.path to regenerate it, but neither covers the boot case correctly:
#   * the .path unit only triggers on driver/toolkit INSTALL-or-UPGRADE (PathChanged on
#     modules.dep / nvidia-ctk), which does not happen on a plain reboot;
#   * the .service has NO ordering against the GPU driver actually being loaded. Its
#     ExecCondition only greps modules.dep for nvidia.ko, which is already true before the
#     module is live. So at boot it runs too early, `nvidia-ctk cdi generate` dies with
#       "failed to initialize NVML: Driver Not Loaded"
#     exits 1, and leaves /var/run/cdi EMPTY while the unit reads enabled-but-failed.
#
# Symptom: every GPU pod (starting with nvidia-device-plugin itself) CrashLoopBackOffs on
#   "failed to inject CDI devices: unresolvable CDI devices nvidia.com/gpu=all"
# which looks like a driver/GPU fault but is purely this ordering race. Observed on the Thor
# after each reboot; it needed a manual `systemctl restart nvidia-cdi-refresh` + deleting the
# plugin pod, i.e. the node did NOT come up usable unattended.
#
# Fix: a drop-in that waits for the driver to answer before generating, and retries. We add a
# drop-in rather than editing NVIDIA's unit so a toolkit upgrade cannot silently revert it.
echo "Installing nvidia-cdi-refresh drop-in (wait for the driver before generating)..."
mkdir -p /etc/systemd/system/nvidia-cdi-refresh.service.d
cat > /etc/systemd/system/nvidia-cdi-refresh.service.d/10-wait-for-driver.conf <<'CDIDROPIN'
# Managed by provisioning (20-install-gpu.sh) — do not edit.
# NVIDIA's unit races the GPU bring-up at boot in TWO ways:
#  1. nvidia-ctk runs before the driver answers -> "failed to initialize NVML: Driver Not
#     Loaded", exit 1, and /var/run/cdi (tmpfs) is left EMPTY.
#  2. Even once nvidia-smi answers, the DRM device nodes are still appearing, and their
#     NUMBERING IS NOT STABLE ACROSS BOOTS. A spec generated too early bakes in names that
#     never materialise (seen: spec referencing /dev/dri/card0 while the node ended up with
#     card1..card3), and every GPU pod then dies with
#       failed to stat CDI host device "/dev/dri/card0": no such file or directory
# Either way the symptom is the device plugin CrashLooping and nvidia.com/gpu never becoming
# allocatable. So: wait for the driver, wait for /dev/dri to STOP changing, generate, then
# verify every device the spec references actually exists — and fail (with Restart) if not.
[Unit]
After=local-fs.target systemd-modules-load.service systemd-udev-settle.service
Wants=systemd-udev-settle.service
[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do nvidia-smi -L >/dev/null 2>&1 && exit 0; sleep 2; done; echo "nvidia driver never came up" >&2; exit 1'
# Wait for DRM enumeration to settle: same `ls /dev/dri` twice in a row, 3s apart.
ExecStartPre=/bin/sh -c 'prev=""; for i in $(seq 1 30); do cur=$(ls /dev/dri 2>/dev/null | sort | tr "\n" " "); [ -n "$cur" ] && [ "$cur" = "$prev" ] && exit 0; prev="$cur"; sleep 3; done; exit 0'
ExecStart=
ExecStart=/bin/sh -c '/usr/bin/nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml'
# Verify the generated spec only names devices that exist; otherwise fail so Restart retries
# once udev has settled further.
# Verify the DEVICE NODES the spec declares. These are `path:` entries under `deviceNodes:`
# (NOT `hostPath:`, which is for mounted libraries). Do NOT hand-roll a character-class regex
# either: [a-z0-9/]* truncates real names (by-path -> "by", nvidia-modeset -> "nvidia") and
# then reports missing devices that were never in the spec — that false alarm made this very
# unit fail after a clean boot.
ExecStartPost=/bin/sh -c 'grep -oE "path: /dev/[^ ]+" /var/run/cdi/nvidia.yaml | awk "{print \$2}" | sort -u | while read -r d; do [ -e "$d" ] || { echo "CDI spec references missing device $d" >&2; exit 1; }; done; echo "CDI spec verified"'
Restart=on-failure
RestartSec=15
StartLimitBurst=6
[Install]
WantedBy=multi-user.target
CDIDROPIN
# The stock unit's ExecCondition greps modules.dep, which is satisfied even when the module is
# not loaded; harmless once ExecStartPre gates on nvidia-smi.
systemctl daemon-reload
systemctl enable nvidia-cdi-refresh.service >/dev/null 2>&1 || true
echo "  drop-in installed; CDI spec will be regenerated after the driver is up on every boot."

