#!/bin/bash
# 20-install-gpu.sh — GPU host enablement for NVIDIA GPU mesh nodes.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
#
# CONDITIONAL step: run ONLY on nodes that declare a `gpu` (project_settings ComputeNodeMesh
# .gpu). Runs BEFORE 40-join-cluster.sh so the nvidia container runtime is present when the
# k3s agent installs and generates its containerd config (k3s auto-detects
# nvidia-container-runtime at install time). No placeholders in this step.
#
# TWO PROVISIONING PATHS, selected by the `jetson-` prefix of --gpu=<type>:
#
#   jetson-*  (SoC / Tegra: jetson-thor, jetson-orin)  -> 20a-install-gpu-soc.sh
#     Assumes the box is ALREADY FLASHED with L4T — the GPU driver (nvidia-l4t-cuda, libcuda,
#     nvidia-smi) comes from the flash and is NOT installed there; there is no desktop CUDA
#     driver on Jetson. The flash does NOT give you the CUDA TOOLKIT (nvcc/ptxas), hence
#     nvidia-jetpack. Also pins the container runtime to mode=cdi + a CDI-refresh unit —
#     both Tegra-specific workarounds.
#
#   anything else (discrete PCIe: nvidia-turing-sm75) -> 20b-install-gpu-pcie.sh
#     Installs the PROPRIETARY desktop driver (open kernel modules are not the supported
#     path on Turing) and blacklists nouveau — which needs ONE REBOOT before the GPU is
#     usable. No CUDA toolkit (upstream x86 serving images carry their own). Leaves the
#     container runtime at mode=auto (NVML path), which is correct for discrete GPUs.
#
# This file owns the arg parsing, the dispatch, and the parts BOTH paths share
# (nvidia-container-toolkit + the k3s runtime check). The two path scripts are sourced,
# not exec'd, so they can set REBOOT_REQUIRED.
#
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 20-install-gpu.sh failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

# ── Arg parsing ───────────────────────────────────────────────────────────────
# GPU_TYPE is REQUIRED: "discrete" cannot be safely inferred from the absence of a driver,
# because a Jetson whose flash failed looks exactly the same.
GPU_TYPE=""
for arg in "$@"; do
  [[ "$arg" == --gpu=* ]] && GPU_TYPE="${arg#--gpu=}"
done
if [ -z "$GPU_TYPE" ]; then
  echo "ERROR: --gpu=<type> is required (e.g. --gpu=jetson-thor, --gpu=nvidia-turing-sm75)." >&2
  exit 1
fi

# Set to 1 by the PCIe path when the nvidia kernel module is not live yet.
REBOOT_REQUIRED=0

# The per-hardware paths live in sibling files and are SOURCED (not exec'd) so they can set
# REBOOT_REQUIRED. Every path that ships this script ships them under the SAME names, so a
# single lookup next to this file is enough.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dispatch to the per-hardware path ─────────────────────────────────────────
# Resolved into a variable FIRST, never inlined as `. "$(...)"`: inside command substitution
# a failure is discarded, so a missing sibling would call `.` with an empty argument — which
# sources STDIN — and fall through into the shared toolkit block below. The GPU step would
# then report success having installed no driver and written no CDI config.
case "$GPU_TYPE" in
  jetson-*) _gpu_sibling="20a-install-gpu-soc.sh" ;;
  *)        _gpu_sibling="20b-install-gpu-pcie.sh" ;;
esac
_gpu_path="$SCRIPT_DIR/$_gpu_sibling"
[ -f "$_gpu_path" ] || {
  echo "ERROR: cannot find $_gpu_sibling next to $0 — it must travel with this script." >&2
  exit 1; }
# shellcheck source=./20a-install-gpu-soc.sh
. "$_gpu_path"

# ── Shared: nvidia-container-toolkit ─────────────────────────────────────────
# Driver-independent, so it is worth doing even on a pass that still needs a reboot.
# ── 2. Install nvidia-container-toolkit (arm64) ──────────────────────────────
# Idempotent: skip the repo+install when the toolkit is already present (JetPack images
# frequently ship it). Otherwise add the official NVIDIA apt repo and install.
if command -v nvidia-ctk >/dev/null 2>&1; then
  echo "nvidia-container-toolkit already installed: $(nvidia-ctk --version 2>/dev/null | head -n1)"
else
  echo "Installing nvidia-container-toolkit from the NVIDIA apt repository..."
  # Tolerate a broken third-party repo (see 10-install-prereqs.sh); installs below are the gate.
  apt-get update -qq || echo "WARNING: apt-get update reported errors (a repo may be unreachable) — continuing." >&2
  apt-get install -y curl gnupg ca-certificates
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq || echo "WARNING: apt-get update reported errors (a repo may be unreachable) — continuing." >&2
  apt-get install -y nvidia-container-toolkit
  echo "nvidia-container-toolkit installed: $(nvidia-ctk --version 2>/dev/null | head -n1)"
fi


# ── Reboot gate (discrete path, first pass) ───────────────────────────────────
# Deliberately NOT rebooting from here: this script runs inside a single SSH session
# (command.remote.Command) and `reboot` kills that transport mid-command — the resource
# fails, 40-join-cluster.sh never runs, and a FAILED Pulumi Command rejects its Outputs
# (.claude/memory/pulumi-failed-command-rejects-outputs.md). Same two-pass, human-in-the-loop
# shape as rebuild-kernel-tegra.sh.
if [ "$REBOOT_REQUIRED" = "1" ]; then
  echo "" >&2
  echo "=================================================================" >&2
  echo "REBOOT REQUIRED — nouveau was blacklisted and/or the nvidia driver" >&2
  echo "was just installed, so the kernel module is not live yet." >&2
  echo "" >&2
  echo "  1. reboot this node" >&2
  echo "  2. verify:  nvidia-smi -L      (expect one line per GPU)" >&2
  echo "  3. re-run:  make provision-mesh-node ARGS='<node-id>'" >&2
  echo "=================================================================" >&2
  exit 1
fi

# ── 3. k3s picks up the nvidia containerd runtime automatically ───────────────
# k3s scans PATH for `nvidia-container-runtime` at agent start and, when found, templates
# an `nvidia` runtime handler into its containerd config. We do NOT hand-edit config.toml —
# k3s owns it and rewrites it on restart. The RuntimeClass `nvidia` (cluster-side, deployed
# by deployment/argocd-infra/nvidia-gpu) maps runtimeClassName:nvidia -> this handler.
#
# 40-join-cluster.sh installs/starts the k3s agent AFTER this step, so the generated config
# will already include the nvidia runtime. Verify it once the config exists (present here
# only on a re-provision where the agent was installed earlier; first-join verification is
# advisory).
CONFIG_GLOB="/var/lib/rancher/k3s/agent/etc/containerd/config.toml*"
# shellcheck disable=SC2086
if ls $CONFIG_GLOB >/dev/null 2>&1; then
  if grep -lq 'nvidia' $CONFIG_GLOB 2>/dev/null; then
    echo "k3s containerd config already contains an 'nvidia' runtime handler."
  else
    echo "NOTE: k3s containerd config exists but has no 'nvidia' runtime yet — it will be" >&2
    echo "      regenerated when the k3s agent (re)starts in 40-join-cluster.sh." >&2
  fi
else
  echo "k3s not yet installed — the nvidia runtime will be templated when the agent installs."
fi


echo "=== GPU host enablement done ($GPU_TYPE) ==="
