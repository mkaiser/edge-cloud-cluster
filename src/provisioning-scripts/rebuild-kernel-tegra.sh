#!/bin/bash
# rebuild-kernel-tegra.sh — rebuild the L4T kernel with the netfilter/XFRM options
# Cilium needs, on a Jetson/Tegra node.
#
# BOARD-AGNOSTIC: covers every box with /etc/nv_tegra_release (measured on Thor T5000 and
# Orin AGX, both L4T R39.2.1). Nothing here is board-specific — the L4T release, the source
# tarball, the kernel release string and the base .config are all derived at runtime from
# the RUNNING kernel and the box itself. The WANT map below is Cilium's requirement list,
# not a board property.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
#
# CONDITIONAL step: Jetson/Tegra nodes ONLY. Runs BEFORE 20-install-gpu.sh and
# 40-join-cluster.sh, because the k3s agent cannot host pods at all until the kernel
# supports what the Cilium agent needs.
#
# WHY THIS EXISTS
# ---------------
# NVIDIA's stock L4T kernel is built without several netfilter/XFRM options, and the Cilium
# agent therefore cannot start on a Jetson — the node goes Ready but NO pod gets a network
# ("plugin type=cilium-cni failed (add) ... dial unix /var/run/cilium/cilium.sock"). Two
# independent failures, in order:
#
#   1. L7 proxy: `iptables -t raw -A CILIUM_PRE_raw ... -j CT --notrack` fails with
#      "Extension CT revision 0 not supported" (no CONFIG_NETFILTER_XT_TARGET_CT).
#   2. Then FATAL: "creating netlink handle: protocol not supported" — the neighbor
#      reconciler calls safenetlink.NewHandle(nil), which asks vishvananda/netlink for a
#      handle with NO families, so it opens a socket for EVERY supported family
#      (NETLINK_ROUTE, NETLINK_XFRM, NETLINK_NETFILTER). NETLINK_XFRM is EPROTONOSUPPORT
#      without CONFIG_XFRM, and one bad family fails the whole handle. Cilium does not want
#      IPsec; it is incidental. Identical in Cilium 1.18.12 / 1.19.7 / 1.20.1, so NO version
#      bump fixes it.
#
#
#
# IDEMPOTENT: exits 0 immediately when the running kernel already has every required option
# (the normal case on re-provision) — a rebuild takes tens of minutes and must never be
# repeated for nothing. Use --force to rebuild anyway.
#
# Usage: rebuild-kernel-tegra.sh [--force] [--check-only] [--configure-only] [--jobs=N]
#   --check-only     report whether a rebuild is needed; exit 1 if it is. Changes nothing.
#   --configure-only fetch source + configure + verify the .config and the release string,
#                    then STOP before the (long) compile. Use this to prove the config first.
#   --force          rebuild even when the running kernel already satisfies everything.
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: rebuild-kernel-tegra.sh failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

FORCE=false
CHECK_ONLY=false
CONFIGURE_ONLY=false
JOBS=""
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=true ;;
    --check-only) CHECK_ONLY=true ;;
    --configure-only) CONFIGURE_ONLY=true ;;
    --jobs=*)     JOBS="${arg#--jobs=}" ;;
    *) echo "ERROR: unknown flag '$arg' (valid: --force, --check-only, --configure-only, --jobs=N)" >&2; exit 2 ;;
  esac
done

KREL="$(uname -r)"
SRC="/lib/modules/${KREL}/build"
WORK="/var/tmp/tegra-kbuild"
WORK_BASE_CONFIG_TMP="/var/tmp/tegra-kbuild-base.config"
STAMP="/var/lib/ecc-tegra-kernel-rebuilt"

# The options Cilium needs. `y` = built in, `m` = module. XFRM must be BUILT IN: the netlink
# family is registered by the core subsystem, not by a loadable module, so `m` would not
# make NETLINK_XFRM available at socket() time.
declare -A WANT=(
  [CONFIG_XFRM]=y
  [CONFIG_XFRM_USER]=y
  [CONFIG_INET_ESP]=m
  [CONFIG_NETFILTER_XT_TARGET_CT]=m
  [CONFIG_NETFILTER_XT_TARGET_TPROXY]=m
  [CONFIG_NETFILTER_XT_MATCH_SOCKET]=m
  [CONFIG_ISCSI_TCP]=m
  [CONFIG_WIREGUARD]=m
  # bpf_get_cgroup_classid() — Cilium hard-requires this BPF helper and dies at startup with
  #   "requirements failed: Require support for bpf_get_cgroup_classid() (Linux 5.7.0 or newer)"
  # which is MISLEADING: the kernel is 6.8, the helper is simply not compiled in. The helper is
  # gated on CONFIG_CGROUP_NET_CLASSID, which the stock L4T config leaves unset (as is
  # NET_CLS_CGROUP, its tc-classifier companion). Found only AFTER the XFRM/xt_CT rebuild
  # succeeded — the agent gets further and then fails on this instead.
  [CONFIG_CGROUP_NET_CLASSID]=y
  [CONFIG_NET_CLS_CGROUP]=m
  # ── The rest of Cilium's documented kernel requirements that stock L4T also lacks ──
  # Audited by diffing Cilium's own system_requirements.rst against /proc/config.gz on the
  # node, rather than discovering them one failed boot at a time (each round trip costs a
  # rebuild + a reboot + possibly a console rescue). INET_XFRM_MODE_TUNNEL is skipped: it was
  # removed from Linux in 4.x and Cilium's list is stale on that one.
  [CONFIG_XFRM_STATISTICS]=y
  # CONFIG_XFRM_OFFLOAD is deliberately NOT listed: it is a promptless `bool` that only gets
  # `select`ed by drivers needing hardware IPsec offload, so it cannot be set directly and
  # olddefconfig always drops an explicit request. Cilium lists it, but nothing here uses
  # IPsec (no encryption in src/cni.ts), and the agent does not check for it.
  [CONFIG_XFRM_ALGO]=m
  [CONFIG_NETFILTER_XT_MATCH_MARK]=m
  [CONFIG_NETFILTER_XT_TARGET_MARK]=m
  # The CONNMARK pair, alongside the MARK pair above: Cilium marks the CONNECTION, not just
  # the packet, so a reply is classified from conntrack rather than re-matched. Stock L4T
  # leaves all three CONNMARK symbols unset, so the rules fail to install the same way
  # xt_CT did ("Extension CONNMARK revision N not supported").
  # These two are backwards-compat shims that both `select NETFILTER_XT_CONNMARK` (the
  # combined connmark/CONNMARK module) — requesting the pair is what olddefconfig expects,
  # and the shared symbol follows on its own, so it is deliberately NOT listed here.
  # =m, not =y: both are tristate and depend on NF_CONNTRACK, which this kernel builds
  # modular (CONFIG_NF_CONNTRACK=m), so a =y request would be downgraded — the same trap
  # CONFIG_GENEVE documents below.
  [CONFIG_NETFILTER_XT_TARGET_CONNMARK]=m
  [CONFIG_NETFILTER_XT_MATCH_CONNMARK]=m
  [CONFIG_NETFILTER_XT_MATCH_COMMENT]=m
  [CONFIG_NETFILTER_XT_SET]=m
  [CONFIG_IP_SET]=m
  [CONFIG_IP_SET_HASH_IP]=m
  # VXLAN must be BUILT IN (=y): it is the cluster's tunnel protocol
  # (project_settings.network.cni.tunnelProtocol), and Cilium requires it non-modular.
  [CONFIG_VXLAN]=y
  # GENEVE can only be =m here: it is tristate and depends on IPV6, which this kernel builds
  # modular (CONFIG_IPV6=m), so olddefconfig silently downgrades a =y request to =m. Cilium's
  # doc asks for =y, but this cluster tunnels with VXLAN (network.cni.tunnelProtocol), not
  # Geneve, so a module is sufficient. Demanding =y here just makes the gate unsatisfiable.
  [CONFIG_GENEVE]=m
  # netkit is Cilium's newer datapath device; required by 1.18+ even when unused.
  [CONFIG_NETKIT]=y
  [CONFIG_CRYPTO_USER_API_HASH]=y
  [CONFIG_NET_CLS_ACT]=y
  [CONFIG_NET_CLS_BPF]=y
  [CONFIG_NET_SCH_INGRESS]=y
  [CONFIG_FIB_RULES]=y
  # BTF is what CO-RE relocation needs. Without it Cilium cannot load cil_sock4_post_bind
  # and friends, the datapath never initialises, and EVERY pod on the node hangs in
  # ContainerCreating ("Cilium API client timeout exceeded") while the agent still reports
  # 1/1 Running — readiness does not cover datapath init, which is what makes this
  # expensive to find. The agent's own log is the only place it says so:
  #   "no BTF found for kernel version 6.8.12-1021-tegra: not supported"
  # =y, not =m: it is a bool, emitted into vmlinux at build time.
  [CONFIG_DEBUG_INFO_BTF]=y
  # ⚠ The blocker is NOT the usual DEBUG_INFO dependency chain — measured on the board
  # (2026-09-16), the stock L4T config ALREADY has CONFIG_DEBUG_KERNEL=y, CONFIG_DEBUG_INFO=y
  # and CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y. What blocks BTF is:
  #
  #   CONFIG_DEBUG_INFO_REDUCED=y  — DEBUG_INFO_BTF `depends on !DEBUG_INFO_REDUCED`.
  #     Reduced DWARF omits the type information pahole needs to build BTF from, so with
  #     this set CONFIG_DEBUG_INFO_BTF is not even OFFERED (it is absent from
  #     /proc/config.gz entirely — not "is not set"), and olddefconfig drops a bare request
  #     for it without a word. Turning it OFF is the actual fix.
  #
  # Disabling REDUCED means full DWARF for every object: the build gets slower and vmlinux
  # and the .o tree get substantially bigger. That cost is unavoidable — it is the data BTF
  # is generated from. The shipped Image is unaffected (BTF adds a few MB; DWARF is stripped).
  [CONFIG_DEBUG_INFO_REDUCED]=n
  # The second half of the failure, also measured: CONFIG_PAHOLE_VERSION=0 in the stock
  # config — pahole was missing at NVIDIA's build time too, so even the DWARF that was there
  # never became BTF. The preflight below makes that impossible for our build.
)

# ── Is this even a Tegra/Jetson box? ─────────────────────────────────────────
if [ ! -e /etc/nv_tegra_release ]; then
  echo "Not an L4T/Tegra node (no /etc/nv_tegra_release) — nothing to do."
  exit 0
fi
echo "=== L4T kernel rebuild check ==="
echo "  kernel : $KREL"
echo "  L4T    : $(head -1 /etc/nv_tegra_release)"

# ── Read the RUNNING kernel's config ─────────────────────────────────────────
# /proc/config.gz is the authority — a .config in a source tree only says what SOME build
# was configured with, not what is booted.
running_config() {
  if [ -e /proc/config.gz ]; then zcat /proc/config.gz
  elif [ -e "/boot/config-${KREL}" ]; then cat "/boot/config-${KREL}"
  else return 1
  fi
}

# A required option is satisfied if it is =y, or =m when a module is acceptable.
# Anything is satisfiable by =y (built in is strictly stronger than a module).
# `n` is the opposite: the option must be OFF, which Kconfig writes as an absent line or a
# "# CONFIG_X is not set" comment — both mean unset, so neither matches "^CONFIG_X=".
opt_satisfied() {
  local opt="$1" want="$2" cfg="$3"
  local have
  have="$(grep -E "^${opt}=" <<<"$cfg" | head -1 | cut -d= -f2)"
  if [ "$want" = "n" ]; then
    [ -z "$have" ] && return 0
    return 1
  fi
  [ -z "$have" ] && return 1
  [ "$have" = "y" ] && return 0
  [ "$have" = "m" ] && [ "$want" = "m" ] && return 0
  return 1
}

MISSING=()
if CFG="$(running_config)"; then
  for opt in "${!WANT[@]}"; do
    opt_satisfied "$opt" "${WANT[$opt]}" "$CFG" || MISSING+=("$opt")
  done
else
  echo "WARNING: cannot read the running kernel config — assuming a rebuild is needed." >&2
  MISSING=("${!WANT[@]}")
fi

if [ "${#MISSING[@]}" -eq 0 ]; then
  echo "All required kernel options are present — no rebuild needed."
  # Belt-and-braces: the options can be present yet the XFRM netlink family still refuse, so
  # assert the thing we actually care about rather than trusting the config alone.
  if ! python3 -c 'import socket,sys
try: socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 6).close()
except OSError as e: sys.exit(1)' 2>/dev/null; then
    echo "WARNING: config looks right but NETLINK_XFRM still fails — investigate, do NOT" >&2
    echo "         assume this node can run the Cilium agent." >&2
    exit 1
  fi
  # Same shape for BTF: /sys/kernel/btf/vmlinux is the RUNTIME authority (it exists iff the
  # running kernel actually carries BTF), the way /proc/config.gz is the config authority.
  # A kernel can be configured with CONFIG_DEBUG_INFO_BTF and still ship none — if pahole was
  # missing at build time the kernel builds fine and silently omits it.
  if [ ! -e /sys/kernel/btf/vmlinux ]; then
    echo "WARNING: config looks right but /sys/kernel/btf/vmlinux is absent — Cilium's" >&2
    echo "         CO-RE relocations will fail, the datapath will never initialise, and" >&2
    echo "         every pod here will hang in ContainerCreating. Do NOT assume this node" >&2
    echo "         can run the agent. Rebuild with --force (pahole/dwarves must be present)." >&2
    exit 1
  fi
  echo "NETLINK_XFRM and /sys/kernel/btf/vmlinux verified. Nothing to do."
  exit 0
fi

echo "Missing/insufficient kernel options (${#MISSING[@]}):"
for o in "${MISSING[@]}"; do echo "  - $o (want ${WANT[$o]})"; done

if [ "$CHECK_ONLY" = "true" ]; then
  echo "--check-only: not rebuilding."
  exit 1
fi

# Is /boot/Image still exactly what nvidia-l4t-kernel shipped? The package's own md5sums
# answer that. It decides whether a snapshot is trustworthy: a pristine Image is by
# definition a bootable fallback; anything else might itself be a broken custom kernel, and
# snapshotting THAT gives a fallback that does not work — the failure you only discover at
# the console, with the box already down.
image_is_pristine() {
  local sums f
  for sums in /var/lib/dpkg/info/nvidia-l4t-kernel.md5sums \
              /var/lib/dpkg/info/nvidia-l4t-kernel:arm64.md5sums; do
    [ -f "$sums" ] || continue
    # md5sums lines are "<md5>  <path-without-leading-slash>"
    local want
    want="$(awk '$2 == "boot/Image" { print $1; exit }' "$sums")"
    [ -n "$want" ] || continue
    f="$(md5sum "$1" 2>/dev/null | cut -d" " -f1)"
    [ "$want" = "$f" ] && return 0 || return 1
  done
  return 2   # cannot tell: no md5sums entry
}

if [ -f "$STAMP" ] && [ "$FORCE" != "true" ]; then
  # A DELIBERATE ROLLBACK is not the dangerous case this guard exists for. The documented
  # rollback restores /boot/Image from Image.backup, so the running kernel is then the
  # PACKAGED one — byte-identical to what nvidia-l4t-kernel ships. Detect that and clear
  # the stamp instead of blocking: without this, every rollback leaves the node unable to
  # be re-provisioned until someone removes the file by hand, and the operator is pushed
  # towards --force, which would ALSO skip the genuine checks this guard is protecting.
  if image_is_pristine /boot/Image 2>/dev/null; then
    echo "  a previous rebuild was rolled back (running the packaged kernel again) —"
    echo "  clearing the stale stamp from $(cat "$STAMP") and rebuilding."
    rm -f "$STAMP"
  else
    echo "ERROR: a previous run of this script already rebuilt the kernel ($(cat "$STAMP"))," >&2
    echo "       yet the running kernel still lacks the options above, and /boot/Image is" >&2
    echo "       NOT the packaged kernel either — so this is not a clean rollback. The new" >&2
    echo "       kernel is either not booted (check /boot/extlinux/extlinux.conf and the" >&2
    echo "       boot menu) or the build silently dropped them. Refusing to rebuild" >&2
    echo "       blindly; use --force once you know why." >&2
    exit 1
  fi
fi

# ── Preconditions: real kernel SOURCE, not the headers tree ─────────────────
# ⚠ /lib/modules/<rel>/build is NOT kernel source on L4T. It is a ~4 KB headers-only tree
# for building OUT-OF-TREE modules: the directories (kernel/, net/, scripts/) exist but
# contain ZERO .c files, no arch/arm64/tools/gen-cpucaps.awk, and a stripped
# tools/include/tools/. Building from it dies partway through `archprepare`. Checking that
# those directories merely EXIST is not enough — count actual sources.
#
# The real source is NVIDIA's public_sources tarball for the matching L4T release, which
# ships kernel/kernel-jammy-src (or similar) inside. It is ~310 MB and there is no apt
# package for it, so it must be fetched (or pre-staged) per release.
#
# L4T_SOURCES_URL may be overridden for a different release or an internal mirror.
L4T_RELEASE="$(sed -n 's/^# R\([0-9]*\) (release), REVISION: \([0-9.]*\).*/r\1_release_v\2/p' /etc/nv_tegra_release | head -1)"
L4T_SOURCES_URL="${L4T_SOURCES_URL:-https://developer.nvidia.com/downloads/embedded/l4t/${L4T_RELEASE}/sources/public_sources.tbz2}"
KSRC="${KSRC:-/var/tmp/l4t-sources}"

have_real_source() {
  local d="$1"
  [ -f "$d/Makefile" ] || return 1
  [ -f "$d/arch/arm64/tools/gen-cpucaps.awk" ] || return 1
  # A real tree has tens of thousands of .c files; the headers tree has none.
  [ "$(find "$d/kernel" -maxdepth 1 -name '*.c' 2>/dev/null | wc -l)" -gt 10 ] || return 1
  return 0
}

# Find the source tree by SEARCHING for its landmark file rather than guessing a path:
# the tarball layout moves between L4T releases (R39 nests it at
# kernel/kernel/kernel-noble, named for the Ubuntu base, not a fixed "kernel-src").
find_srcdir() {
  local hit
  # No -maxdepth: R39 nests it 7 levels down (kernel/kernel/kernel-noble/...) and the depth
  # moves between releases, which is exactly why this searches instead of globbing.
  hit="$(find "$KSRC" -type f -path '*/arch/arm64/tools/gen-cpucaps.awk' 2>/dev/null | head -1)"
  [ -n "$hit" ] || return 1
  # strip the trailing arch/arm64/tools/gen-cpucaps.awk to get the tree root
  printf '%s\n' "${hit%/arch/arm64/tools/gen-cpucaps.awk}"
}

SRCDIR=""
# 1) already-extracted source from a previous run?
if cand="$(find_srcdir)" && have_real_source "$cand"; then SRCDIR="$cand"; fi

# 2) the shipped tree, on the off-chance a future L4T ships full source
if [ -z "$SRCDIR" ] && have_real_source "$SRC"; then SRCDIR="$SRC"; fi

if [ -z "$SRCDIR" ]; then
  echo "=== Fetching L4T public sources ($L4T_RELEASE) ==="
  echo "  url: $L4T_SOURCES_URL"
  echo "  NOTE ~310 MB download + extract; this is the only way to get real kernel source."
  mkdir -p "$KSRC"
  TB="$KSRC/public_sources.tbz2"
  if [ ! -s "$TB" ]; then
    curl -fL --retry 3 --retry-delay 5 -o "$TB" "$L4T_SOURCES_URL" || {
      echo "ERROR: could not download L4T public sources." >&2
      echo "       Stage the tarball manually at $TB (or set L4T_SOURCES_URL) and re-run." >&2
      exit 1
    }
  else
    echo "  using already-downloaded $TB"
  fi
  # The tarball nests kernel_src.tbz2 inside; extract only what we need.
  tar -xjf "$TB" -C "$KSRC" 2>/dev/null || tar -xf "$TB" -C "$KSRC"
  INNER="$(find "$KSRC" -name 'kernel_src*.tbz2' -o -name 'kernel_src*.tar*' 2>/dev/null | head -1)"
  if [ -n "$INNER" ]; then
    echo "  extracting inner $(basename "$INNER")"
    mkdir -p "$KSRC/kernel"
    tar -xf "$INNER" -C "$KSRC/kernel"
  fi
  if cand="$(find_srcdir)" && have_real_source "$cand"; then SRCDIR="$cand"; fi
fi

[ -n "$SRCDIR" ] || {
  echo "ERROR: no usable kernel SOURCE tree found after fetch/extract." >&2
  echo "       Searched $KSRC for any tree containing arch/arm64/tools/gen-cpucaps.awk." >&2
  echo "       Inspect that directory: the tarball layout changes between L4T releases." >&2
  exit 1
}
echo "Kernel source: $SRCDIR"
# ── Base .config ─────────────────────────────────────────────────────────────
# PREFER /proc/config.gz: it is the config the RUNNING kernel was actually built with, and it
# stays correct across iterations. $SRC/.config is fragile here — on a node this script has
# already rebuilt, /lib/modules/<rel>/build is a symlink to our own $WORK tree, and `make
# mrproper` in $WORK deletes the very .config we would be reading (a circular dependency that
# fails the second run with "cannot stat .../build/.config").
BASE_CONFIG=""
if [ -e /proc/config.gz ]; then
  BASE_CONFIG="$WORK_BASE_CONFIG_TMP"
  mkdir -p "$(dirname "$BASE_CONFIG")"
  zcat /proc/config.gz > "$BASE_CONFIG"
  echo "Base .config: /proc/config.gz (running kernel)"
elif [ -f "$SRC/.config" ] && [ ! -L "$SRC" ]; then
  BASE_CONFIG="$SRC/.config"
  echo "Base .config: $SRC/.config"
fi
[ -n "$BASE_CONFIG" ] && [ -s "$BASE_CONFIG" ] || {
  echo "ERROR: no usable base kernel .config (tried /proc/config.gz and $SRC/.config)." >&2
  exit 1
}

echo "=== Installing build dependencies ==="
apt-get update -qq || echo "WARNING: apt-get update reported errors — continuing." >&2
# libssl-dev is the one a stock Jetson lacks, and it fails the build LATE (certs/extract-cert).
# dwarves supplies pahole, which the kernel runs over vmlinux to EMIT BTF. Its absence is
# silent: the build succeeds, CONFIG_DEBUG_INFO_BTF stays =y in .config, and the booted
# kernel simply has no /sys/kernel/btf/vmlinux — which is the state this board was found in.
apt-get install -y build-essential bc bison flex libssl-dev libelf-dev rsync kmod cpio dwarves

# ── PREFLIGHT: pahole must exist, or the build silently produces a kernel with no BTF ──
# Hard failure, not a warning: a BTF-less kernel costs a full rebuild + a reboot to discover,
# and the node looks healthy the whole time (the cilium agent reports 1/1 Running).
if ! command -v pahole >/dev/null 2>&1; then
  echo "ERROR: pahole not found after installing 'dwarves'." >&2
  echo "       CONFIG_DEBUG_INFO_BTF needs it to emit BTF into vmlinux; without it the build" >&2
  echo "       SUCCEEDS and silently omits BTF, and Cilium's CO-RE relocations then fail on" >&2
  echo "       every boot. Install it manually and re-run rather than building without it." >&2
  exit 1
fi
echo "  pahole: $(pahole --version 2>&1 | head -1)"

# ── Snapshot: a bootable fallback BEFORE anything is replaced ────────────────
# A Jetson that will not boot needs physical access, so this is not optional, and neither
# is proving afterwards that what we wrote is actually usable.
#
# The PRIMARY rollback route is swapping the files back (Image.backup -> Image,
# initrd.backup -> initrd, modules .backup -> modules, then reboot). It works regardless of
# how the bootloader locates the kernel. The extlinux `backup` menu entry below is the
# SECONDARY route: on the Orin the menu has been observed to offer an entry and boot
# `primary` anyway, so it is written and verified but never relied on alone.
echo "=== Snapshotting current kernel + modules ==="

image_is_pristine /boot/Image; live_state=$?
case "$live_state" in
  0) echo "  /boot/Image matches nvidia-l4t-kernel (pristine stock kernel)" ;;
  1) echo "  /boot/Image does NOT match nvidia-l4t-kernel (already a custom kernel)" ;;
  *) echo "  WARNING: cannot verify /boot/Image against nvidia-l4t-kernel (no md5sums entry)" ;;
esac

if [ "$live_state" = "0" ]; then
  # Pristine: snapshot UNCONDITIONALLY, overwriting any older .backup. An existing backup of
  # unknown provenance is exactly the trap measured on the Orin (2026-09-21), where a
  # six-hour-old /boot/Image.backup made the `[ -f ] ||` guard skip and left a fallback
  # nobody could vouch for.
  cp -a /boot/Image /boot/Image.backup
  echo "  /boot/Image.backup refreshed from the pristine stock kernel"
elif [ -f /boot/Image.backup ] && image_is_pristine /boot/Image.backup; then
  echo "  /boot/Image.backup kept — it matches nvidia-l4t-kernel (pristine)"
elif [ "$FORCE" = "true" ]; then
  [ -f /boot/Image.backup ] || cp -a /boot/Image /boot/Image.backup
  echo "  WARNING: neither /boot/Image nor its backup is the packaged kernel; --force given," >&2
  echo "           continuing with a fallback of UNKNOWN provenance." >&2
else
  echo "ERROR: no trustworthy rollback kernel." >&2
  echo "       /boot/Image is not the one nvidia-l4t-kernel shipped, and" >&2
  echo "       /boot/Image.backup is $([ -f /boot/Image.backup ] && echo 'not it either' || echo 'absent')." >&2
  echo "       Snapshotting now would give a fallback that may not boot. Restore the stock" >&2
  echo "       kernel first (apt install --reinstall nvidia-l4t-kernel), or pass --force to" >&2
  echo "       proceed with an unverified fallback." >&2
  exit 1
fi

# Modules: same rule, keyed off the Image verdict — the two must be a matching pair, or the
# fallback is the CRC-mismatch hang that only the console recovers.
if [ "$live_state" = "0" ] || [ ! -d "/lib/modules/${KREL}.backup" ]; then
  rm -rf "/lib/modules/${KREL}.backup"
  cp -a "/lib/modules/${KREL}" "/lib/modules/${KREL}.backup"
  echo "  /lib/modules/${KREL}.backup refreshed"
else
  echo "  /lib/modules/${KREL}.backup kept"
fi

cp -a /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.bak.$(date +%s)" 2>/dev/null || true

# Add the fallback boot entry if it is not already there. Without it the backup Image is
# present but unreachable from the boot menu.
# ⚠ The regex MUST anchor at a non-comment line. NVIDIA ships this very entry as a
# COMMENTED-OUT template ("# LABEL backup"), so a pattern like '^\s*LABEL\s+backup' matches
# the template, the script concludes a fallback exists, and the node reboots with NO bootable
# fallback at all. Require a line that begins with LABEL, optionally indented, but NOT '#'.
if ! grep -qE '^[[:space:]]*LABEL[[:space:]]+backup([[:space:]]|$)' /boot/extlinux/extlinux.conf 2>/dev/null; then
  echo "  adding 'backup' boot entry to extlinux.conf"
  # The APPEND line is copied from the primary entry so the fallback boots with an identical
  # cmdline and root=. Resolve it FIRST: if the primary entry is formatted unusually the grep
  # yields nothing, and appending would produce a bootable-LOOKING entry with no cmdline at
  # all — a fallback that fails at the one moment it is needed.
  primary_append="$(grep -m1 -E '^[[:space:]]*APPEND[[:space:]]' /boot/extlinux/extlinux.conf | sed 's/^[[:space:]]*//')"
  if [ -z "$primary_append" ]; then
    echo "ERROR: no APPEND line found in /boot/extlinux/extlinux.conf — cannot build a" >&2
    echo "       fallback entry with a working cmdline. Nothing has been changed yet." >&2
    exit 1
  fi
  {
    echo ""
    echo "LABEL backup"
    echo "    MENU LABEL backup kernel (pre-ecc-rebuild)"
    echo "    LINUX /boot/Image.backup"
    echo "    INITRD /boot/initrd.backup"
    echo "    $primary_append"
  } >> /boot/extlinux/extlinux.conf
else
  echo "  'backup' boot entry already present"
fi

# Give a human time to actually SELECT the fallback. L4T's TIMEOUT is in DECISECONDS, so
# NVIDIA's stock `TIMEOUT 30` is THREE seconds — far too short to catch the menu on a box
# whose console you are watching precisely because the last boot went wrong. A fallback
# entry that cannot be reached in time is not a fallback. 150 = 15s, which still boots
# unattended without meaningful delay.
ECC_BOOT_TIMEOUT_DS="${ECC_BOOT_TIMEOUT_DS:-150}"
if grep -qE '^[[:space:]]*TIMEOUT[[:space:]]+[0-9]+' /boot/extlinux/extlinux.conf; then
  cur_to="$(grep -m1 -E '^[[:space:]]*TIMEOUT[[:space:]]+[0-9]+' /boot/extlinux/extlinux.conf | awk '{print $2}')"
  if [ "${cur_to:-0}" -lt "$ECC_BOOT_TIMEOUT_DS" ]; then
    sed -i -E "s|^([[:space:]]*)TIMEOUT[[:space:]]+[0-9]+|\1TIMEOUT ${ECC_BOOT_TIMEOUT_DS}|" \
      /boot/extlinux/extlinux.conf
    echo "  boot menu timeout raised ${cur_to} -> ${ECC_BOOT_TIMEOUT_DS} deciseconds ($((ECC_BOOT_TIMEOUT_DS/10))s)"
  else
    echo "  boot menu timeout already ${cur_to} deciseconds ($((cur_to/10))s)"
  fi
else
  sed -i "1i TIMEOUT ${ECC_BOOT_TIMEOUT_DS}" /boot/extlinux/extlinux.conf
  echo "  boot menu timeout set to ${ECC_BOOT_TIMEOUT_DS} deciseconds ($((ECC_BOOT_TIMEOUT_DS/10))s)"
fi

# ── Verify the entry we just wrote is really there and really complete ───────
# Re-READ the file rather than trusting the append: the previous run reported success and
# the entry was not in the file afterwards (root cause never established). This runs BEFORE
# /boot/Image is touched, so failing here is free — the box still boots what it booted.
verify_backup_entry() {
  awk '
    /^[[:space:]]*#/            { next }
    /^[[:space:]]*LABEL[[:space:]]+backup([[:space:]]|$)/ { inblk=1; seen=1; next }
    /^[[:space:]]*LABEL[[:space:]]/ { inblk=0 }
    inblk && /^[[:space:]]*LINUX[[:space:]]+\/boot\/Image\.backup([[:space:]]|$)/  { linux=1 }
    inblk && /^[[:space:]]*INITRD[[:space:]]+\/boot\/initrd\.backup([[:space:]]|$)/ { initrd=1 }
    inblk && /^[[:space:]]*APPEND[[:space:]]+[^[:space:]]/ { append=1 }
    END { exit !(seen && linux && initrd && append) }
  ' /boot/extlinux/extlinux.conf
}
if verify_backup_entry; then
  echo "  verified 'backup' entry in extlinux.conf:"
  sed -n '/^[[:space:]]*LABEL[[:space:]]\+backup/,/^[[:space:]]*$/p' /boot/extlinux/extlinux.conf | sed 's/^/    | /'
else
  echo "ERROR: the 'backup' entry in /boot/extlinux/extlinux.conf is missing or incomplete" >&2
  echo "       (needs an uncommented LABEL backup with LINUX /boot/Image.backup," >&2
  echo "       INITRD /boot/initrd.backup and a non-empty APPEND)." >&2
  echo "       Refusing to install a new kernel without a reachable fallback. Nothing has" >&2
  echo "       been changed yet — the box still boots its current kernel." >&2
  echo "       Current file:" >&2
  sed 's/^/         | /' /boot/extlinux/extlinux.conf >&2
  exit 1
fi

# ── Configure in a COPY of the tree ──────────────────────────────────────────
# Never build in /lib/modules/*/build: it is package-managed, so an apt operation mid-build
# can clobber it.
echo "=== Preparing build tree at $WORK ==="
rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$SRCDIR/." "$WORK/"
cd "$WORK"
make mrproper >/dev/null 2>&1 || true
cp -a "$BASE_CONFIG" "$WORK/.config"

# ── Repair the stripped tools/include/tools headers ─────────────────────────
# nvidia-l4t-kernel-headers ships a NEARLY complete tree, but tools/include/tools/ is
# stripped down to `nolibc` — so `scripts/sorttable.c` fails to build with
#   scripts/sorttable.c:36:10: fatal error: tools/be_byteshift.h: No such file or directory
# and `make scripts` dies before any real compilation. Only these two headers are missing.
# They are self-contained inline byte-swap helpers with no kernel-version coupling, embedded
# VERBATIM from upstream v6.8 (including the public get_unaligned_*/put_unaligned_* wrappers
# that sorttable.c actually calls — an abridged copy does not compile). Written only when
# absent, so a genuinely complete tree is left untouched.
mkdir -p "$WORK/tools/include/tools"
if [ ! -f "$WORK/tools/include/tools/be_byteshift.h" ]; then
  echo "  supplying missing tools/include/tools/be_byteshift.h"
  cat > "$WORK/tools/include/tools/be_byteshift.h" <<'HDR'
/* SPDX-License-Identifier: GPL-2.0 */
/* Verbatim from upstream linux v6.8 tools/include/tools/be_byteshift.h.
 * Supplied by provisioning: absent from nvidia-l4t-kernel-headers. */
#ifndef _TOOLS_BE_BYTESHIFT_H
#define _TOOLS_BE_BYTESHIFT_H

#include <stdint.h>

static inline uint16_t __get_unaligned_be16(const uint8_t *p)
{
	return p[0] << 8 | p[1];
}

static inline uint32_t __get_unaligned_be32(const uint8_t *p)
{
	return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

static inline uint64_t __get_unaligned_be64(const uint8_t *p)
{
	return (uint64_t)__get_unaligned_be32(p) << 32 |
	       __get_unaligned_be32(p + 4);
}

static inline void __put_unaligned_be16(uint16_t val, uint8_t *p)
{
	*p++ = val >> 8;
	*p++ = val;
}

static inline void __put_unaligned_be32(uint32_t val, uint8_t *p)
{
	__put_unaligned_be16(val >> 16, p);
	__put_unaligned_be16(val, p + 2);
}

static inline void __put_unaligned_be64(uint64_t val, uint8_t *p)
{
	__put_unaligned_be32(val >> 32, p);
	__put_unaligned_be32(val, p + 4);
}

static inline uint16_t get_unaligned_be16(const void *p)
{
	return __get_unaligned_be16((const uint8_t *)p);
}

static inline uint32_t get_unaligned_be32(const void *p)
{
	return __get_unaligned_be32((const uint8_t *)p);
}

static inline uint64_t get_unaligned_be64(const void *p)
{
	return __get_unaligned_be64((const uint8_t *)p);
}

static inline void put_unaligned_be16(uint16_t val, void *p)
{
	__put_unaligned_be16(val, p);
}

static inline void put_unaligned_be32(uint32_t val, void *p)
{
	__put_unaligned_be32(val, p);
}

static inline void put_unaligned_be64(uint64_t val, void *p)
{
	__put_unaligned_be64(val, p);
}

#endif /* _TOOLS_BE_BYTESHIFT_H */
HDR
fi
if [ ! -f "$WORK/tools/include/tools/le_byteshift.h" ]; then
  echo "  supplying missing tools/include/tools/le_byteshift.h"
  cat > "$WORK/tools/include/tools/le_byteshift.h" <<'HDR'
/* SPDX-License-Identifier: GPL-2.0 */
/* Verbatim from upstream linux v6.8 tools/include/tools/le_byteshift.h.
 * Supplied by provisioning: absent from nvidia-l4t-kernel-headers. */
#ifndef _TOOLS_LE_BYTESHIFT_H
#define _TOOLS_LE_BYTESHIFT_H

#include <stdint.h>

static inline uint16_t __get_unaligned_le16(const uint8_t *p)
{
	return p[0] | p[1] << 8;
}

static inline uint32_t __get_unaligned_le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | p[3] << 24;
}

static inline uint64_t __get_unaligned_le64(const uint8_t *p)
{
	return (uint64_t)__get_unaligned_le32(p + 4) << 32 |
	       __get_unaligned_le32(p);
}

static inline void __put_unaligned_le16(uint16_t val, uint8_t *p)
{
	*p++ = val;
	*p++ = val >> 8;
}

static inline void __put_unaligned_le32(uint32_t val, uint8_t *p)
{
	__put_unaligned_le16(val >> 16, p + 2);
	__put_unaligned_le16(val, p);
}

static inline void __put_unaligned_le64(uint64_t val, uint8_t *p)
{
	__put_unaligned_le32(val >> 32, p + 4);
	__put_unaligned_le32(val, p);
}

static inline uint16_t get_unaligned_le16(const void *p)
{
	return __get_unaligned_le16((const uint8_t *)p);
}

static inline uint32_t get_unaligned_le32(const void *p)
{
	return __get_unaligned_le32((const uint8_t *)p);
}

static inline uint64_t get_unaligned_le64(const void *p)
{
	return __get_unaligned_le64((const uint8_t *)p);
}

static inline void put_unaligned_le16(uint16_t val, void *p)
{
	__put_unaligned_le16(val, p);
}

static inline void put_unaligned_le32(uint32_t val, void *p)
{
	__put_unaligned_le32(val, p);
}

static inline void put_unaligned_le64(uint64_t val, void *p)
{
	__put_unaligned_le64(val, p);
}

#endif /* _TOOLS_LE_BYTESHIFT_H */
HDR
fi

# ── Kernel release string: MUST come out byte-identical ─────────────────────
# THE BIGGEST RISK IN THIS SCRIPT. The out-of-tree NVIDIA GPU modules
# (nvidia-l4t-kernel-nvgpu / -oot-modules / openrm) live in /lib/modules/<uname -r>/ and are
# built for this exact release. If the rebuild produces a different release string, modules
# install to a DIFFERENT directory, the GPU stack does not load after the reboot, and the
# node comes up looking perfectly healthy with NO GPU — which silently defeats the entire
# purpose of this node.
#
# The stock .config carries CONFIG_LOCALVERSION="" — the `-1021-tegra` ABI suffix is injected
# by NVIDIA's own packaging build (see /proc/version: built by "buildbrain"), NOT by the
# config. So `make kernelrelease` on the shipped .config yields a bare "6.8.12" and modules
# would land in /lib/modules/6.8.12/. We therefore pass LOCALVERSION explicitly, derived from
# the RUNNING kernel, and gate on the result.
KVER_BASE="$(make -s -C "$WORK" kernelversion)"          # e.g. 6.8.12
LOCALVERSION_SUFFIX="${KREL#$KVER_BASE}"                  # e.g. -1021-tegra
[ -n "$LOCALVERSION_SUFFIX" ] || {
  echo "ERROR: could not derive the LOCALVERSION suffix ($KREL vs $KVER_BASE)." >&2
  exit 1
}
export LOCALVERSION="$LOCALVERSION_SUFFIX"
echo "  kernel base    : $KVER_BASE"
echo "  LOCALVERSION   : $LOCALVERSION  (from the running $KREL)"
# CONFIG_LOCALVERSION_AUTO would append a git-describe suffix and break the match.
scripts/config --file .config --disable CONFIG_LOCALVERSION_AUTO

echo "=== Enabling required options via scripts/config ==="
# scripts/config, not sed on .config: Kconfig owns dependency resolution, and direct .config
# edits are silently overridden on ARM (upstream Cilium docs warn about exactly this).
for opt in "${!WANT[@]}"; do
  case "${WANT[$opt]}" in
    y) scripts/config --file .config --enable "$opt" ;;
    m) scripts/config --file .config --module "$opt" ;;
    n) scripts/config --file .config --disable "$opt" ;;
  esac
done
make olddefconfig >/dev/null


# ── GATE: verify the config BEFORE spending tens of minutes building ────────
# olddefconfig silently DROPS an option whose dependencies are unmet. That is precisely how
# this class of bug hides, so fail loudly here rather than after a long build + a reboot.
echo "=== Verifying the resulting .config ==="
BAD=0
for opt in "${!WANT[@]}"; do
  have="$(grep -E "^${opt}=" .config | head -1 | cut -d= -f2 || true)"
  if opt_satisfied "$opt" "${WANT[$opt]}" "$(cat .config)"; then
    printf '  %-40s %s\n' "$opt" "=$have"
  else
    printf '  %-40s %s\n' "$opt" "*** NOT ENABLED (dependencies unmet?) ***"
    BAD=1
  fi
done
[ "$BAD" -eq 0 ] || {
  echo "ERROR: at least one required option did not survive olddefconfig — NOT building." >&2
  echo "       Inspect its Kconfig dependencies in $WORK before retrying." >&2
  # CONFIG_DEBUG_INFO_BTF is the one whose dependency chain is not obvious: it needs
  # CONFIG_DEBUG_INFO, which is a promptless bool selected by the DWARF toolchain choice,
  # which is itself only offered under CONFIG_DEBUG_KERNEL. If BTF is what got dropped, say
  # so here rather than leaving the next person to rediscover the chain.
  if ! opt_satisfied CONFIG_DEBUG_INFO_BTF y "$(cat .config)"; then
    echo "" >&2
    echo "       CONFIG_DEBUG_INFO_BTF specifically: it depends on CONFIG_DEBUG_INFO, which" >&2
    echo "       is promptless and selected by the CONFIG_DEBUG_INFO_DWARF_* choice — which" >&2
    echo "       in turn needs CONFIG_DEBUG_KERNEL. Check those three in that order:" >&2
    echo "         grep -E '^CONFIG_DEBUG_(KERNEL|INFO)' $WORK/.config" >&2
    echo "       Without BTF the node joins, reports Ready, and no pod ever gets networking." >&2
  fi
  exit 1
}

# ── GATE: the release string must match the running kernel exactly ──────────
BUILT_REL="$(make -s kernelrelease)"
if [ "$BUILT_REL" != "$KREL" ]; then
  echo "ERROR: this build would produce kernel release '$BUILT_REL', but the running" >&2
  echo "       kernel is '$KREL'. Modules would install to /lib/modules/$BUILT_REL and the" >&2
  echo "       NVIDIA out-of-tree GPU modules would NOT load — the node would boot with no" >&2
  echo "       GPU. Refusing to build. Check LOCALVERSION / CONFIG_LOCALVERSION_AUTO." >&2
  exit 1
fi
echo "  kernel release : $BUILT_REL (matches running kernel)"

if [ "$CONFIGURE_ONLY" = "true" ]; then
  echo ""
  echo "--configure-only: stopping before the compile. Verified .config is at $WORK/.config"
  echo "Re-run without --configure-only to build and install."
  exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────
: "${JOBS:=$(nproc)}"
echo "=== Building kernel + modules (-j${JOBS}) — expect tens of minutes ==="
echo "  started: $(date -Is)"
make -j"$JOBS" LOCALVERSION="$LOCALVERSION" Image modules
echo "  finished: $(date -Is)"

# ── Install: modules FIRST, kernel second ───────────────────────────────────
# If the kernel is installed but the modules are not, a reboot lands on a kernel with no
# drivers. Modules first means the worst case is an unused module tree.
echo "=== Installing modules ==="
make LOCALVERSION="$LOCALVERSION" modules_install
depmod -a "$BUILT_REL"

# ── Rebuild NVIDIA's out-of-tree modules against THIS kernel ────────────────
# THIS IS THE STEP WHOSE ABSENCE BROKE THE FIRST TWO ATTEMPTS.
# /lib/modules/<rel>/updates/ holds ~116 NVIDIA out-of-tree modules (nvidia, nvgpu, host1x,
# display, pcie-endpoint, rtcpu, camera, nvethernet). `make modules_install` leaves them
# ALONE — which looks like good news but means they still carry version magic AND SYMBOL CRCs
# from NVIDIA's original build. This kernel keeps the same version string on purpose, but a
# changed config shifts exported-symbol CRCs, and vermagic shows `modversions`
# (CONFIG_MODVERSIONS=y), so every one of them is REJECTED at load. The boot then gets all
# the way through PCIe/USB/display enumeration and HANGS FOREVER in:
#     tegra-mc  memory-controller: sync_state() pending due to 8181200000.host1x
#     tegra186-emc: sync_state() pending due to ....pcie / .rtcpu / .display / .ahub
# because the memory controller waits on consumers whose drivers never probed. Recovery
# means PHYSICAL CONSOLE ACCESS: swap the .backup files back in from a rescue shell, or —
# if it still boots that far — pick the extlinux `backup` entry.
#
# Matching LOCALVERSION is necessary but NOT sufficient: it fixes the directory modules
# install into, not their ABI.
#
# NVIDIA supports exactly this rebuild: kernel/nvbuild.sh -m builds "NVIDIA OOT modules
# only", -i installs to INSTALL_MOD_PATH, and kernel_src_build_env.sh lists the components
# in OOT_SOURCE_LIST (nvethernetrm nvgpu nvidia-oot hwpm hardware nvdisplay
# build/nvidia-public/devicetree unifiedgpudisp). Their sources are SEPARATE tarballs inside
# public_sources.tbz2 — kernel_oot_modules_src.tbz2, kernel_nvgpu_src.tbz2 and the two
# display-driver tarballs — which are NOT extracted by the kernel_src extraction above.
NVBUILD="$(dirname "$SRCDIR")/../nvbuild.sh"
[ -f "$NVBUILD" ] || NVBUILD="$(find "$KSRC" -maxdepth 3 -name nvbuild.sh 2>/dev/null | head -1)"
OOT_ROOT="$(dirname "$NVBUILD")"

echo "=== Rebuilding NVIDIA out-of-tree modules against $BUILT_REL ==="
if [ ! -f "$NVBUILD" ]; then
  echo "ERROR: nvbuild.sh not found under $KSRC — cannot rebuild the oot modules." >&2
  exit 1
fi
echo "  nvbuild : $NVBUILD"

# Extract the oot source tarballs if they have not been unpacked yet.
L4T_SRC_TARBALLS="$KSRC/Linux_for_Tegra/source"
if [ -d "$L4T_SRC_TARBALLS" ]; then
  for t in kernel_oot_modules_src.tbz2 kernel_nvgpu_src.tbz2 \
           nvidia_kernel_display_driver_source.tbz2 \
           nvidia_unified_gpu_display_driver_source.tbz2; do
    [ -f "$L4T_SRC_TARBALLS/$t" ] || continue
    tar -xf "$L4T_SRC_TARBALLS/$t" -C "$OOT_ROOT" 2>/dev/null || true
  done
fi

# Verify every component nvbuild expects is present before invoking it — a missing directory
# makes nvbuild exit with a bare "Directory ... is not found".
OOT_MISSING=""
for d in nvethernetrm nvgpu nvidia-oot hwpm hardware nvdisplay unifiedgpudisp; do
  [ -d "$OOT_ROOT/$d" ] || OOT_MISSING="$OOT_MISSING $d"
done
if [ -n "$OOT_MISSING" ]; then
  echo "ERROR: missing oot source component(s):$OOT_MISSING" >&2
  echo "       Expected under $OOT_ROOT (from the *_src.tbz2 tarballs in $L4T_SRC_TARBALLS)." >&2
  exit 1
fi

# TWO SEPARATE INVOCATIONS, and the order matters. Reading nvbuild.sh: when DO_INSTALL is
# set (-i) it runs install_oot_modules and then `exit 0` **without ever building** — so
# passing `-m -o ... -i` in one go silently installs from an unbuilt tree and produces ZERO
# oot modules (observed: 0 .ko in updates/, no nvidia.ko). Build first, install second.
#
# KERNEL_HEADERS must point at the CONFIGURED kernel tree ($WORK) so the modules compile
# against our .config; OOT_OUT is nvbuild's own scratch/output dir.
OOT_OUT="${OOT_OUT:-/var/tmp/oot_out}"
(
  cd "$OOT_ROOT"
  export KERNEL_HEADERS="$WORK"
  export LOCALVERSION="$LOCALVERSION"
  bash ./nvbuild.sh -m -o "$OOT_OUT"                      # BUILD (no -i)
) || {
  echo "ERROR: the out-of-tree module rebuild FAILED." >&2
  echo "       Do NOT install this kernel: its oot modules would be stale and the node would" >&2
  echo "       hang at boot in tegra-mc sync_state(). The running kernel is untouched." >&2
  exit 1
}

# Now install them. INSTALL_MOD_DIR=updates is applied by nvbuild itself, so they land in
# /lib/modules/<rel>/updates/ exactly where the stock ones were.
(
  cd "$OOT_ROOT"
  export KERNEL_HEADERS="$WORK"
  export LOCALVERSION="$LOCALVERSION"
  export INSTALL_MOD_PATH="${OOT_INSTALL_MOD_PATH:-/}"
  bash ./nvbuild.sh -m -o "$OOT_OUT" -i                   # INSTALL
) || {
  echo "ERROR: installing the rebuilt out-of-tree modules FAILED." >&2
  exit 1
}
depmod -a "$BUILT_REL"

# GATE: the rebuilt oot modules must actually match this kernel. Check vermagic on the GPU
# driver — the single most important one, and the one whose absence looks like a healthy boot
# with no GPU.
NVKO="$(find "/lib/modules/${BUILT_REL}/updates" -name 'nvidia.ko*' 2>/dev/null | head -1)"
if [ -z "$NVKO" ]; then
  echo "ERROR: no nvidia.ko under /lib/modules/${BUILT_REL}/updates after the rebuild." >&2
  exit 1
fi
NVMAGIC="$(modinfo -F vermagic "$NVKO" 2>/dev/null | head -1)"
case "$NVMAGIC" in
  "$BUILT_REL"*) echo "  nvidia.ko vermagic: $NVMAGIC (matches)" ;;
  *) echo "ERROR: nvidia.ko vermagic is '$NVMAGIC', expected to start with '$BUILT_REL'." >&2
     echo "       Installing would strand the GPU stack. Refusing." >&2
     exit 1 ;;
esac
echo "  oot modules rebuilt: $(find "/lib/modules/${BUILT_REL}/updates" -name '*.ko*' | wc -l) .ko files"

# GATE 2: the rebuild must not LOSE an oot module the stock kernel shipped.
# nvidia.ko above is necessary but not sufficient — measured 2026-09-22 on the Orin, the
# rebuild produced a full-looking updates/ tree (184 .ko) that was MISSING nvethernet.ko,
# the Tegra Ethernet MAC driver. The consequence is not a missing NIC, which would be
# obvious: /etc/modprobe.d/nvidia-preferred-oot-modules.conf loads the in-tree tegra-mgbe
# ONLY when `modinfo nvethernet` fails, so the box silently fell back to the mainline stmmac
# driver. It bound the Aquantia PHY, reported "Link is Up - 1Gbps/Full", and then flapped
# Up/Down every ~90s with "Invalid PTP clock rate" / "PTP init failed" — a node that boots,
# shows an interface with a carrier, and has no usable network. On a remote box that is a
# console rescue.
#
# So diff the module NAME SET against the snapshot taken before the build. A name present in
# the backup and absent now is a regression, whatever the count says.
if [ -d "/lib/modules/${KREL}.backup/updates" ]; then
  _oot_names() { find "$1" -name '*.ko*' -printf '%f\n' 2>/dev/null | sed 's/\.ko.*$/.ko/' | sort -u; }
  MISSING_OOT="$(comm -23 <(_oot_names "/lib/modules/${KREL}.backup/updates") \
                          <(_oot_names "/lib/modules/${BUILT_REL}/updates"))"
  if [ -n "$MISSING_OOT" ]; then
    echo "ERROR: the rebuilt oot module set is MISSING modules the stock kernel shipped:" >&2
    echo "$MISSING_OOT" | sed 's/^/         /' >&2
    echo "       Refusing to install. Nothing has been replaced; the box still boots its" >&2
    echo "       current kernel. A missing driver here does NOT fail loudly at boot — an" >&2
    echo "       in-tree driver silently takes over the device (see nvethernet/tegra-mgbe" >&2
    echo "       in /etc/modprobe.d/nvidia-preferred-oot-modules.conf)." >&2
    exit 1
  fi
  echo "  oot module set: no module lost against the stock tree"
else
  echo "  WARNING: no /lib/modules/${KREL}.backup/updates to compare the oot set against" >&2
fi

# ── Regenerate the initrd — MANDATORY, and the step that broke the first attempt ──
# The initrd carries its OWN copies of the modules needed to reach the root filesystem
# (nvme, ext4, ...). Those copies have version magic for the kernel they were built for, so a
# NEW kernel rejects them and the boot dies in early userspace with:
#     ERROR: nvme0n1p1 not found
# ...then drops to an initramfs shell. The kernel and modules were fine; only the initrd was
# stale — recovery is the file swap back to /boot/initrd.backup (or the extlinux `backup`
# entry, which uses that same file).
#
# Build to a TEMP file and only move it into place on success: a truncated/failed initrd is
# just as unbootable as a stale one, and /boot/initrd is what the fallback entry uses too.
echo "=== Regenerating initrd for $BUILT_REL ==="
# Snapshot the CURRENT initrd, which still belongs to the kernel currently in /boot/Image
# (not replaced until further below). Refresh it unconditionally when that kernel is the
# pristine stock one, so the fallback pair Image.backup+initrd.backup always matches; only
# keep a pre-existing backup when the live pair is already custom.
if [ "$live_state" = "0" ] || [ ! -f /boot/initrd.backup ]; then
  cp -a /boot/initrd /boot/initrd.backup
  echo "  /boot/initrd.backup refreshed"
else
  echo "  /boot/initrd.backup kept (live kernel is not the packaged one)"
fi
# ⚠ KEEP THE IN-TREE ETHERNET DRIVER OUT OF THE INITRAMFS.
# This box runs initramfs-tools with MODULES=most, which sweeps in every driver matching the
# hardware — including the mainline stmmac family (dwmac-tegra.ko, stmmac.ko, …). NVIDIA's
# stock initrd is curated and carries ONLY nvethernet.ko for this device.
#
# Inside the initramfs udev binds by device match, and /etc/modprobe.d is NOT there, so the
# nvidia-preferred-oot-modules.conf rule that normally suppresses dwmac_tegra cannot apply.
# Whichever driver udev reaches first claims 6800000.ethernet. Measured 2026-09-22 on the
# Orin: dwmac-tegra won, nvethernet was never even attempted, and the node booted with
# "tegra-mgbe 6800000.ethernet end0" flapping Up/Down every ~90s — an interface with a
# carrier and no usable network. It is also why the regenerated initrd was 183 MB against
# the stock 11 MB.
#
# Blacklisting in /etc/modprobe.d would NOT fix it (not present in the initramfs); the
# exclusion has to be applied to the initramfs build itself.
# initramfs-tools has NO supported "omit driver" setting (omit_drivers is a dracut option
# and is silently ignored here), so the exclusion is a HOOK that removes the modules after
# the copy stage. It must be executable and is keyed to this repo by name.
INITRD_HOOK="/etc/initramfs-tools/hooks/ecc-tegra-no-stmmac"
if [ -d /etc/initramfs-tools/hooks ]; then
  cat > "$INITRD_HOOK" <<'EOF'
#!/bin/sh
# Installed by rebuild-kernel-tegra.sh. The Tegra MAC must be driven by NVIDIA's
# out-of-tree nvethernet, never by the in-tree stmmac/dwmac-tegra pair: inside the
# initramfs there is no /etc/modprobe.d to arbitrate, so whichever binds first keeps the
# device, and stmmac gives a link that flaps Up/Down with PTP init failures.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
# The whole stmmac directory: dwmac-tegra is the one that actually races nvethernet for
# 6800000.ethernet, but the siblings are other SoCs' glue drivers that can never match this
# hardware, so nothing here needs them and removing the lot keeps a future rename from
# reintroducing the race.
find "${DESTDIR}/lib/modules" -type d -name stmmac -path '*/net/ethernet/stmicro/*' \
     -exec rm -rf {} + 2>/dev/null || true
EOF
  chmod +x "$INITRD_HOOK"
  echo "  initramfs: hook installed to exclude the in-tree stmmac/dwmac drivers"
fi

if command -v update-initramfs >/dev/null 2>&1; then
  TMP_INITRD="/boot/initrd.new.$$"
  if update-initramfs -c -k "$BUILT_REL" >/dev/null 2>&1 && [ -f "/boot/initrd.img-$BUILT_REL" ]; then
    cp -a "/boot/initrd.img-$BUILT_REL" "$TMP_INITRD"
  elif mkinitramfs -o "$TMP_INITRD" "$BUILT_REL" >/dev/null 2>&1; then
    :
  else
    echo "ERROR: could not regenerate the initrd — NOT installing the new kernel." >&2
    echo "       Booting it with the old initrd fails with 'nvme0n1p1 not found'." >&2
    exit 1
  fi
  # Sanity-gate it: an initrd with no nvme module cannot mount this root fs.
  if command -v lsinitramfs >/dev/null 2>&1; then
    # Listed ONCE here and reused by every check below — see the pipefail/SIGPIPE note at
    # the nvethernet gate for why these must not pipe lsinitramfs into `grep -q`.
    INITRD_LIST="$(lsinitramfs "$TMP_INITRD" 2>/dev/null || true)"
    n_nvme="$(printf '%s\n' "$INITRD_LIST" | grep -c 'nvme' || true)"
    if [ "${n_nvme:-0}" -lt 1 ]; then
      echo "ERROR: the regenerated initrd contains no nvme module — refusing to install." >&2
      echo "       Add the driver via /etc/initramfs-tools/modules and re-run." >&2
      rm -f "$TMP_INITRD"; exit 1
    fi
    echo "  initrd contains $n_nvme nvme entries"
    # ⚠ List the initrd ONCE and match against the captured text. Do NOT pipe lsinitramfs
    # into `grep -q`: this script runs under `set -o pipefail`, and `grep -q` exits as soon
    # as it matches, so lsinitramfs is killed by SIGPIPE and the PIPELINE reports failure
    # even though the match succeeded. The nvme check above survives only because `grep -c`
    # reads to the end. Measured 2026-09-22: `nvethernet` sits at line 1010 of 1207, the
    # pipeline failed, and the gate reported the module absent from an initrd that
    # demonstrably contained it — blocking two otherwise good Phase C runs.
    #
    # The in-tree stmmac family must NOT be in here — see the hook above. If the hook did
    # not take effect, dwmac-tegra races nvethernet inside the initramfs and wins, and the
    # node boots with a flapping link and no usable network. Checked rather than assumed:
    # initramfs-tools silently ignores an unsupported exclusion directive.
    if printf '%s\n' "$INITRD_LIST" | grep -qE 'stmmac|dwmac'; then
      echo "ERROR: the regenerated initrd still contains the in-tree stmmac/dwmac drivers." >&2
      echo "       They would claim 6800000.ethernet before nvethernet is even tried." >&2
      echo "       Check the hook at $INITRD_HOOK. Refusing to install." >&2
      rm -f "$TMP_INITRD"; exit 1
    fi
    echo "  initrd carries no in-tree stmmac/dwmac (nvethernet will win)"
    if ! printf '%s\n' "$INITRD_LIST" | grep -q 'nvethernet'; then
      echo "ERROR: the regenerated initrd has no nvethernet.ko — the NIC would have no" >&2
      echo "       driver at all in early userspace. Refusing to install." >&2
      rm -f "$TMP_INITRD"; exit 1
    fi
    echo "  initrd carries nvethernet.ko"
  fi
  mv "$TMP_INITRD" /boot/initrd
  echo "  /boot/initrd regenerated (old one kept as /boot/initrd.backup)"
else
  echo "ERROR: no update-initramfs/mkinitramfs on this node — cannot regenerate the initrd." >&2
  echo "       Installing the kernel without it would make the node unbootable." >&2
  exit 1
fi

# ── Pre-flight the rollback, immediately before the point of no return ──────
# Everything up to here is reversible by doing nothing. The next line replaces the kernel
# the box boots, so assert NOW that every rollback precondition actually holds — the script
# used to install first and only describe the fallback afterwards.
echo "=== Pre-flight: rollback preconditions ==="
preflight_fail=0
pf() { # pf <ok?> <description>
  if [ "$1" = "0" ]; then echo "  OK   $2"; else echo "  FAIL $2" >&2; preflight_fail=1; fi
}
[ -s /boot/Image.backup ] && pf 0 "/boot/Image.backup exists and is non-empty" \
                          || pf 1 "/boot/Image.backup missing or empty"
[ -s /boot/initrd.backup ] && pf 0 "/boot/initrd.backup exists and is non-empty" \
                           || pf 1 "/boot/initrd.backup missing or empty"
[ -d "/lib/modules/${KREL}.backup" ] && pf 0 "/lib/modules/${KREL}.backup exists" \
                                     || pf 1 "/lib/modules/${KREL}.backup missing"
# The backup kernel and its module tree must be a matching PAIR — a stock Image with our
# modules (or the reverse) is the CRC-mismatch hang that only a console recovers.
if [ -d "/lib/modules/${KREL}.backup/kernel" ]; then
  pf 0 "/lib/modules/${KREL}.backup carries a kernel/ module tree"
else
  pf 1 "/lib/modules/${KREL}.backup has no kernel/ subtree — not a usable module set"
fi
verify_backup_entry && pf 0 "extlinux.conf still carries a complete 'backup' entry" \
                    || pf 1 "extlinux.conf lost its 'backup' entry since it was written"
if [ "$preflight_fail" != "0" ]; then
  echo "ERROR: rollback preconditions are not satisfied — refusing to install the new" >&2
  echo "       kernel. Nothing has been replaced; the box still boots its current kernel." >&2
  exit 1
fi

echo "=== Installing kernel Image ==="
cp -a arch/arm64/boot/Image /boot/Image
sync

# ── Protect the custom kernel from apt ───────────────────────────────────────
# Three packages own the files we just replaced, all pinned to this L4T revision:
#   nvidia-l4t-kernel              -> /boot/Image
#   nvidia-l4t-kernel-oot-modules  -> /lib/modules/<rel>/updates/*
#   nvidia-l4t-kernel-headers      -> /lib/modules/<rel>/build
# When NVIDIA ships a newer revision, `apt upgrade` restores ITS /boot/Image and updates/
# modules, and the node silently reboots into a kernel with no CONFIG_XFRM — Cilium dies, the
# node goes NotReady, and it reads as a brand-new failure with no link to an apt run days
# earlier. A PARTIAL replacement is worse: a stock Image with our modules (or vice versa) is
# the CRC-mismatch hang that only the console can recover.
#
# Holding them makes the next L4T bump a CONSCIOUS decision: re-run this script against the
# new release rather than inheriting a broken node. The cost is real and deliberate — held
# packages receive no security updates, and `apt upgrade` only prints a "kept back" note.
# Set ECC_KERNEL_APT_HOLD=0 to skip.
if [ "${ECC_KERNEL_APT_HOLD:-1}" = "1" ] && command -v apt-mark >/dev/null 2>&1; then
  echo "=== Holding the L4T kernel packages (custom kernel must not be silently replaced) ==="
  apt-mark hold nvidia-l4t-kernel nvidia-l4t-kernel-oot-modules nvidia-l4t-kernel-headers \
    2>/dev/null | sed 's/^/  /' || echo "  WARNING: apt-mark hold failed" >&2
  echo "  held: $(apt-mark showhold 2>/dev/null | tr '\n' ' ')"
  echo "  NOTE these packages now receive NO updates. On the next L4T release, unhold them,"
  echo "       upgrade, then re-run this script to rebuild against the new kernel."
fi

date -Is > "$STAMP"
echo ""
echo "=== Kernel rebuilt ==="
echo "  built release : $BUILT_REL"
echo "  running       : $KREL   (unchanged until reboot)"
echo "  fallback      : /boot/Image.backup + /boot/initrd.backup + /lib/modules/${KREL}.backup"
echo "                  (plus a verified 'backup' entry in extlinux.conf)"
echo ""
echo "REBOOT REQUIRED. After the reboot, run verify-kernel-tegra.sh — it performs all of the"
echo "below in order and exits non-zero on the first hard failure:"
echo "  0. cat /proc/version            # must NOT say buildbrain/crosstool-NG. uname -r"
echo "                                  # CANNOT tell the two apart: this build reproduces"
echo "                                  # the stock release string on purpose."
echo "  1. uname -r                     # must still be $KREL"
echo "  2. nvidia-smi                   # GPU stack intact (the real risk of this change)"
echo "  3. zcat /proc/config.gz | grep -E 'XFRM|XT_TARGET_CT|TPROXY|MATCH_SOCKET|ISCSI_TCP'"
echo "  4. ls -l /sys/kernel/btf/vmlinux   # must EXIST — Cilium's CO-RE needs it"
echo "  5. the NETLINK_XFRM socket test (re-run this script: it self-checks and exits 0)"
echo "  6. modprobe xt_CT && modprobe iscsi_tcp"
echo "Then re-provision + uncordon:"
echo "  make provision-mesh-node ARGS='<node-id>' && kubectl uncordon <node-id>"
echo ""
echo "TO ROLL BACK — swap the files back. This is the PRIMARY route: it works regardless of"
echo "how the bootloader locates the kernel, which the extlinux menu has been observed not to."
echo "  sudo cp -a /boot/Image.backup  /boot/Image"
echo "  sudo cp -a /boot/initrd.backup /boot/initrd"
echo "  sudo rm -rf /lib/modules/${KREL} && sudo cp -a /lib/modules/${KREL}.backup /lib/modules/${KREL}"
echo "  sudo reboot"
echo "Secondary: pick 'backup kernel (pre-ecc-rebuild)' in the extlinux boot menu."
