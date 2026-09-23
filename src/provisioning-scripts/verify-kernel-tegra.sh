#!/bin/bash
# verify-kernel-tegra.sh — post-reboot verification for a rebuilt L4T kernel.
#
# Run ON THE NODE after rebooting into a kernel built by rebuild-kernel-tegra.sh, BEFORE
# re-joining it to the cluster. Ordered so the most damaging failure is caught first.
#
# Exits non-zero on the FIRST hard failure, so it is safe to chain:
#   sudo bash verify-kernel-tegra.sh && make provision-mesh-node ARGS='<id>'
#
# Usage: verify-kernel-tegra.sh
set -uo pipefail

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "=== Post-reboot kernel verification ($(date -Is)) ==="
echo "kernel: $(uname -r)"

# 0. BEFORE ANYTHING ELSE: is this actually OUR kernel? uname -r CANNOT tell — the rebuild
#    deliberately reproduces the stock release string byte-for-byte (so the NVIDIA oot
#    modules keep loading from /lib/modules/<rel>), so a box that fell back to the stock
#    kernel reports the same "6.8.12-1021-tegra". Only /proc/version distinguishes them:
#    NVIDIA's build farm stamps "buildbrain@..." and a crosstool-NG toolchain, ours stamps
#    the node's own hostname and its distro gcc. Measured 2026-09-21 on the Orin: the
#    rebuild completed cleanly, the box booted the STOCK kernel anyway, and every other
#    check below would still have passed on config alone had the stock config matched.
echo "--- 0. Running kernel provenance"
PROCVER="$(cat /proc/version 2>/dev/null || echo '')"
if grep -qEi 'buildbrain|crosstool-NG' <<<"$PROCVER"; then
  bad "/proc/version says NVIDIA's build farm — you are on the STOCK kernel, not the rebuild."
  echo "        $PROCVER"
  echo "        The rebuild did not take effect: the bootloader is still loading the stock"
  echo "        /boot/Image. Check /boot/extlinux/extlinux.conf and that /boot/Image is the"
  echo "        rebuilt one; do NOT join this node."
else
  ok "/proc/version is a local build (no buildbrain/crosstool-NG stamp)"
fi

# 1. GPU FIRST. A release-string mismatch installs modules to the wrong directory and the
#    NVIDIA out-of-tree stack silently does not load — the node then looks perfectly healthy
#    with no GPU, which is the worst outcome because nothing else complains.
echo "--- 1. NVIDIA GPU stack (the top risk of a kernel rebuild)"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  ok "nvidia-smi: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
else
  bad "nvidia-smi does not work — the GPU stack did not load for $(uname -r)."
  echo "        Check that /lib/modules/$(uname -r) contains the nvidia oot modules, and"
  echo "        that the built release string matched the previous kernel exactly."
fi

# 1b. The Tegra oot drivers must be the ones actually BOUND to their devices. A missing oot
#     module does not fail loudly: /etc/modprobe.d/nvidia-preferred-oot-modules.conf loads
#     the in-tree driver only when the oot one is absent, so the device silently changes
#     hands. Measured 2026-09-22 on the Orin — nvethernet.ko was missing from the rebuild,
#     the mainline tegra-mgbe/stmmac driver took the NIC, reported "Link is Up - 1Gbps/Full"
#     and then flapped Up/Down every ~90s. The box had an interface with a carrier and no
#     usable network.
echo "--- 1b. Tegra out-of-tree drivers bound to their devices"
for iface in /sys/class/net/*/; do
  ifname="$(basename "$iface")"
  [ "$ifname" = "lo" ] && continue
  drv="$(basename "$(readlink -f "$iface/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "$drv" ] || continue
  case "$drv" in
    tegra-mgbe|stmmac*|dwmac*)
      bad "$ifname is driven by the IN-TREE '$drv', not NVIDIA's out-of-tree nvethernet."
      echo "        The oot module is missing or failed to load, so the in-tree driver took"
      echo "        the device. Expect a link that comes up and then flaps. Check:"
      echo "          modinfo nvethernet   # must resolve"
      echo "          ls /lib/modules/$(uname -r)/updates/drivers/net/ethernet/nvidia/nvethernet/"
      ;;
    nvethernet) ok "$ifname driven by nvethernet (NVIDIA out-of-tree)" ;;
  esac
done

# 2. The kernel options this rebuild exists for.
echo "--- 2. Kernel config options"
CFG=""
if [ -e /proc/config.gz ]; then CFG="$(zcat /proc/config.gz)"
elif [ -e "/boot/config-$(uname -r)" ]; then CFG="$(cat "/boot/config-$(uname -r)")"
fi
if [ -z "$CFG" ]; then
  warn "cannot read the running kernel config — relying on the runtime probes below."
else
  for pair in CONFIG_XFRM:y CONFIG_XFRM_USER:y CONFIG_INET_ESP:m \
              CONFIG_NETFILTER_XT_TARGET_CT:m CONFIG_NETFILTER_XT_TARGET_TPROXY:m \
              CONFIG_NETFILTER_XT_MATCH_SOCKET:m CONFIG_ISCSI_TCP:m CONFIG_WIREGUARD:m \
              CONFIG_NETFILTER_XT_TARGET_CONNMARK:m CONFIG_NETFILTER_XT_MATCH_CONNMARK:m \
              CONFIG_DEBUG_INFO_BTF:y; do
    opt="${pair%:*}"; want="${pair#*:}"
    have="$(grep -E "^${opt}=" <<<"$CFG" | head -1 | cut -d= -f2)"
    if [ "$have" = "y" ] || { [ "$have" = "m" ] && [ "$want" = "m" ]; }; then
      ok "$opt=$have"
    else
      bad "$opt is ${have:-unset} (want $want)"
    fi
  done
fi

# 3. The actual runtime symptom Cilium hit. The config can look right and the family still
#    refuse, so probe the socket rather than trusting the config.
echo "--- 3. netlink families (Cilium's neighbor reconciler opens ALL of these)"
python3 - <<'PY' || FAIL=1
import socket, errno, sys
bad = 0
for name, proto in (("NETLINK_ROUTE",0),("NETLINK_XFRM",6),("NETLINK_NETFILTER",12)):
    try:
        socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, proto).close()
        print(f"  \033[32mPASS\033[0m  {name}")
    except OSError as e:
        print(f"  \033[31mFAIL\033[0m  {name}: {errno.errorcode.get(e.errno, e.errno)}")
        bad = 1
sys.exit(bad)
PY

# 4. BTF. The config above says what was REQUESTED; this says what the running kernel HAS.
#    They diverge when pahole was missing at build time — the build succeeds and silently
#    emits no BTF. Without it Cilium cannot apply CO-RE relocations to its eBPF programs
#    ("no BTF found for kernel version ...: not supported"), the datapath never initialises,
#    and every pod scheduled here hangs in ContainerCreating while the agent reports 1/1
#    Running. Checked separately from section 2 for exactly that reason.
echo "--- 4. BTF (Cilium's CO-RE relocations)"
if [ -e /sys/kernel/btf/vmlinux ]; then
  ok "/sys/kernel/btf/vmlinux present ($(stat -c %s /sys/kernel/btf/vmlinux 2>/dev/null || echo '?') bytes)"
else
  bad "/sys/kernel/btf/vmlinux absent — the kernel carries no BTF."
  echo "        Cilium's datapath will not load. Rebuild with pahole (dwarves) installed:"
  echo "        sudo bash rebuild-kernel-tegra.sh --force"
fi

# 5. The modules Cilium's iptables layer and Longhorn need.
echo "--- 5. Loadable modules"
for m in xt_CT iscsi_tcp xt_connmark; do
  if modprobe "$m" 2>/dev/null; then ok "modprobe $m"; else bad "modprobe $m"; fi
done
# The L7 proxy rule that crash-looped the agent: assert it can actually be installed.
if iptables -t raw -N ECC_VERIFY_raw 2>/dev/null; then
  if iptables -t raw -A ECC_VERIFY_raw -m mark --mark 0x200/0xf00 -j CT --notrack 2>/dev/null; then
    ok "iptables -j CT --notrack (the rule that crash-looped the cilium agent)"
  else
    bad "iptables -j CT --notrack still rejected"
  fi
  iptables -t raw -F ECC_VERIFY_raw 2>/dev/null; iptables -t raw -X ECC_VERIFY_raw 2>/dev/null
else
  warn "could not create a scratch iptables chain — skipped the CT target probe."
fi
# The CONNMARK pair, same shape: the config can read right and iptables still reject the
# extension. Its own chain in `mangle`, NOT the `raw` one above — CONNMARK is not valid in
# raw, so reusing that chain would fail for the wrong reason and read as a missing module.
if iptables -t mangle -N ECC_VERIFY_mangle 2>/dev/null; then
  if iptables -t mangle -A ECC_VERIFY_mangle -j CONNMARK --save-mark 2>/dev/null; then
    ok "iptables -j CONNMARK --save-mark"
  else
    bad "iptables -j CONNMARK --save-mark rejected (xt_CONNMARK target missing)"
  fi
  if iptables -t mangle -A ECC_VERIFY_mangle -m connmark --mark 0x200/0xf00 -j ACCEPT 2>/dev/null; then
    ok "iptables -m connmark --mark"
  else
    bad "iptables -m connmark --mark rejected (xt_connmark match missing)"
  fi
  iptables -t mangle -F ECC_VERIFY_mangle 2>/dev/null; iptables -t mangle -X ECC_VERIFY_mangle 2>/dev/null
else
  warn "could not create a scratch mangle chain — skipped the CONNMARK probes."
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL CHECKS PASSED — safe to re-provision and uncordon ==="
  echo "  make provision-mesh-node ARGS='<node-id>'"
  echo "  kubectl uncordon <node-id>"
  echo "Then watch the cilium agent for >=5 min and confirm restart count stays 0."
  exit 0
fi
echo "=== CHECKS FAILED — do NOT re-join the node yet ==="
echo "To roll back, SWAP THE FILES BACK (primary route — works regardless of how the"
echo "bootloader finds the kernel, which the extlinux menu has been observed not to):"
echo "  sudo cp -a /boot/Image.backup  /boot/Image"
echo "  sudo cp -a /boot/initrd.backup /boot/initrd"
echo "  sudo rm -rf /lib/modules/$(uname -r) && \\"
echo "    sudo cp -a /lib/modules/$(uname -r).backup /lib/modules/$(uname -r)"
echo "  sudo reboot"
echo "Secondary: select the 'backup kernel (pre-ecc-rebuild)' entry in the extlinux menu."
exit 1
