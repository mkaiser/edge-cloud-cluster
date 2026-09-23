#!/bin/bash
# 10-install-prereqs.sh — Install Longhorn storage prerequisites on an mesh node.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
# No placeholders in this step.
#
# Run as root or with sudo.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

# ── /etc/hosts must resolve `localhost` ───────────────────────────────────────────────
# ⚠ NOT cosmetic, and NOT guaranteed by the OS image. Ubuntu autoinstall images have been
# seen carrying ONLY `127.0.1.1 <installer-hostname>` with no localhost line at all
# (measured on unibi-hclab-bender and unibi-hclab-fs-vm, ecc212 2026-09-16).
#
# Go binaries then fall through to DNS for `localhost`, and cluster DNS does not answer it:
# node-local-dns forwards its catch-all zone to the node's own resolver by design, so the
# name NXDOMAINs. csi-driver-nfs is the first casualty — node-driver-registrar and
# liveness-probe both bind a localhost address and die with
#     listen tcp: lookup localhost on 10.43.0.10:53: no such host
# The driver never registers, so NFS PVs cannot mount (`driver name nfs.csi.k8s.io not found
# in the list of registered CSI drivers`) while the PVs sit Bound and the fileserver looks
# healthy. It reads as a storage fault and is a hosts-file one.
#
# The tell that this is per-NODE and not a cluster DNS bug: a node WITH the line runs the
# same DaemonSet pod 3/3 with zero restarts.
if ! grep -qE '^127\.0\.0\.1[[:space:]]+localhost' /etc/hosts; then
  echo "=== /etc/hosts has no localhost entry — adding one ==="
  printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n' >> /etc/hosts
fi

# The node's OWN hostname needs an entry too, and it is a SEPARATE check: a box can carry the
# localhost line above and still not resolve `$(hostname)`, so the block above skips it.
# Measured on unibi-hclab-thor-eval (ecc215): /etc/hosts held ONLY `127.0.0.1 localhost`, and
# every sudo call paid a full resolver timeout first — `sudo: unable to resolve host thor:
# Temporary failure in name resolution` on each privileged command in a provisioning run.
# 127.0.1.1 (not .0.1) is the Debian/Ubuntu convention for a machine's own name, which is why
# the autoinstall images carry `127.0.1.1 <installer-hostname>`.
# ⚠ Test RESOLUTION, not the file's contents. A node may resolve its own name from DNS
# instead (bender answers 192.168.1.192 from the lab resolver and needs no hosts entry), so
# grepping /etc/hosts would add a redundant line there. getent asks the real NSS stack, which
# is what sudo does. Only a name that resolves NOWHERE gets an entry.
_hn=$(hostname)
if [ -n "${_hn:-}" ] && ! getent hosts "${_hn}" >/dev/null 2>&1; then
  echo "=== ${_hn} does not resolve (no DNS answer, no /etc/hosts entry) — adding a hosts entry ==="
  printf '127.0.1.1\t%s\n' "${_hn}" >> /etc/hosts
fi

echo "=== Installing Longhorn prerequisites ==="
# Wait for the dpkg lock instead of dying on it. An adopted box runs unattended-upgrades (and
# apt-daily.timer) on its own schedule, so ANY apt call here can collide with one already in
# flight — the collision is a plain `E: Sperre /var/lib/dpkg/lock-frontend konnte nicht
# erlangt werden`, exit 100, and under `set -e` that aborts the whole provision.
# It hits one node at a time and a re-run usually "fixes" it, which is exactly what makes a
# pure timing artefact easy to misread as a flaky box.
# Written as an apt.conf.d drop-in rather than a flag on each call site: it covers all ~23
# apt invocations across every provisioning script (including ones added later) and applies
# to the pulumi and manual join paths alike. 300s comfortably outlasts a routine
# unattended-upgrades run; a genuinely stuck lock still fails, just slower.
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ecc-lock-timeout <<'APTCONF'
DPkg::Lock::Timeout "300";
APTCONF

# Adopted machines often carry stray third-party apt repos (e.g. a Helm repo at baltocdn.com)
# whose InRelease fetch fails behind a captive portal/proxy. A single broken repo must NOT
# abort provisioning — tolerate the update failure here and let the install below be the real
# gate (a genuinely unresolvable package still fails). Without this, `set -e` kills the run.
apt-get update -qq || echo "WARNING: apt-get update reported errors (a repo may be unreachable) — continuing." >&2
# open-iscsi/dmsetup are REQUIRED by Longhorn — do not swallow a real install failure here.
# qrencode is used by 30-connect-vpn.sh in keyless mode to render the registration URL as a
# scannable QR on the node's console (tiny package; harmless on the Pulumi/keyed path too).
# curl is a hard prereq of 30-connect-vpn.sh (tailscale apt keyring + the headscale reachability
# check) and of 40-join-cluster.sh (get.k3s.io). It is NOT guaranteed on an adopted box —
# unibi-lab-pcie-tb-d had none, and 30-connect-vpn.sh died with exit 127 ("curl: Kommando nicht
# gefunden") AFTER this script had reported success. 15-/16- install it themselves; installing it
# unconditionally here means no later step has to.
apt-get install -y curl open-iscsi nfs-common cryptsetup dmsetup qrencode
systemctl enable iscsid --now

# bpftool — REQUIRED by 00-cleanup-node.sh to detach Cilium's socket-LB cgroup programs on a
# re-provision. That block is guarded by `command -v bpftool`, so a missing binary skips the
# whole detach SILENTLY and the node comes back carrying two generations of `cil_sock*`
# (22 attachments instead of 11); the stale one wins the connect() rewrite and resolves
# against dead maps. Measured on unibi-hclab-thor-eval (ecc215): bpftool was absent on that
# box and present on every x86 node, so only the Tegra node was affected — its registry
# NodePort was dead for ~2h and only a REBOOT cleared it.
#
# ⚠ Ubuntu ships bpftool via a VERSION-MATCHED linux-tools-<uname -r> package plus a wrapper
# at /usr/sbin/bpftool that refuses to run anything else ("WARNING: bpftool not found for
# kernel 6.8.12-1021"). No linux-tools exists for the Tegra kernel, so the wrapper can never
# be satisfied there. bpftool talks to the kernel over the stable bpf(2) syscall and is not
# tied to the running release for what cleanup needs (link show / link detach), so any recent
# build works — verified v7.4.0/libbpf v1.4 against 6.8.12-1021-tegra, listing all 11
# attachments correctly. Install whichever linux-tools is available and symlink the REAL
# binary over the wrapper so `command -v bpftool` resolves to something that runs.
if ! /usr/sbin/bpftool version >/dev/null 2>&1; then
  apt-get install -y "linux-tools-$(uname -r)" 2>/dev/null \
    || apt-get install -y linux-tools-generic 2>/dev/null \
    || echo "WARNING: no linux-tools package installed — bpftool may be unavailable." >&2
  # Pick the newest real binary the package dropped and put it ahead of the wrapper.
  _bt=$(ls -1d /usr/lib/linux-tools/*/bpftool 2>/dev/null | sort -V | tail -1)
  if [ -n "${_bt:-}" ] && [ -x "$_bt" ]; then
    ln -sf "$_bt" /usr/local/sbin/bpftool
    echo "  bpftool: $("$_bt" version 2>/dev/null | head -1) -> /usr/local/sbin/bpftool"
  fi
fi
# Fail loudly rather than leaving the cleanup silently disabled on the next re-provision.
command -v bpftool >/dev/null 2>&1 \
  || echo "WARNING: bpftool still not on PATH — 00-cleanup-node.sh cannot detach socket-LB cgroup programs, and a re-provision of this node will need a REBOOT to clear them." >&2
modprobe iscsi_tcp 2>/dev/null || true
echo "iscsi_tcp" > /etc/modules-load.d/iscsi.conf

# nfsd — REQUIRED on any node that may host a Longhorn RWX volume's share-manager.
#
# Longhorn serves RWX through an NFS-Ganesha share-manager pod, and it places that pod on a
# node holding one of the volume's replicas — there is no share-manager node selector in
# v1.12. Ganesha needs the nfsd kernel module; without it the pod starts, never writes
# /var/run/ganesha.pid, fails its readiness probe, and the volume's engine dies:
#   Readiness probe failed: cat: /var/run/ganesha.pid: No such file or directory
#   Engine of volume <pvc> dead unexpectedly ... Robustness to faulted
# Consumers then hang forever in ContainerCreating on
#   AttachVolume.Attach failed ... "Waiting for volume share to be available".
#
# `nfs-common` (installed above) provides the NFS CLIENT and does NOT load nfsd. A node whose
# nfsd.ko is present but unloaded cannot host a share-manager while Longhorn still reports it
# perfectly healthy (KernelModulesLoaded=True) — Longhorn only checks CLIENT-side modules.
#
# Tolerant of failure: a kernel genuinely lacking nfsd.ko should not abort provisioning —
# such a node simply never hosts a share-manager, which Longhorn handles by picking another.
modprobe nfsd 2>/dev/null || echo "WARNING: nfsd module unavailable — this node cannot host a Longhorn RWX share-manager." >&2
echo "nfsd" > /etc/modules-load.d/nfsd.conf

# multipathd (pulled in as a dep of open-iscsi on Ubuntu) claims Longhorn's iSCSI LUNs on
# attach/boot, wrapping /dev/sdX in a dm-multipath device it holds exclusively. Longhorn then
# fails to mount with "already mounted or mount point busy" / kernel "Can't open blockdev" and
# CNPG/app pods hang in Init after a node reboot — even though Longhorn's own CRDs show the
# volume attached/healthy. Blacklist Longhorn's LUNs (SCSI vendor IET / product VIRTUAL-DISK)
# so multipathd ignores them; real multipathed SAN disks (if any) are still managed.
mkdir -p /etc/multipath/conf.d
cat > /etc/multipath/conf.d/longhorn.conf <<'MPATH'
# Managed by provisioning (10-install-prereqs.sh) — do not edit.
# Exclude Longhorn iSCSI devices from DM-Multipath (Longhorn prerequisite).
blacklist {
    device {
        vendor  "IET"
        product "VIRTUAL-DISK"
    }
}
MPATH
# Some minimal images ship no /etc/multipath.conf, so conf.d is not read; ensure a base file
# exists (empty is fine — the drop-in above supplies the blacklist).
[ -f /etc/multipath.conf ] || printf 'defaults {\n    user_friendly_names yes\n}\n' > /etc/multipath.conf
# Reload if multipathd is running; harmless no-op if it isn't installed/active.
if systemctl is-active --quiet multipathd 2>/dev/null; then
  # Flush any maps it already built over Longhorn LUNs, then reload the new blacklist.
  multipath -F 2>/dev/null || true
  systemctl reload multipathd 2>/dev/null || systemctl restart multipathd 2>/dev/null || true
fi

# Some distro iperf3 packages (notably Debian/Ubuntu on arm64 — e.g. the Thor node) ship an
# iperf3.service unit that is enabled-by-default and binds 0.0.0.0:5201 at boot. The
# mesh-monitoring iperf3-server DaemonSet runs with hostNetwork:true and also binds host
# :5201, so it loses the race and CrashLoopBackOffs with "unable to start listener ...
# Address in use". The DaemonSet is the intended provider; mask the distro service so it can
# never come back (disable alone would re-enable on package upgrade). Harmless no-op where the
# unit doesn't exist.
if systemctl list-unit-files iperf3.service --no-legend 2>/dev/null | grep -q iperf3; then
  systemctl disable --now iperf3.service 2>/dev/null || true
  systemctl mask iperf3.service 2>/dev/null || true
  echo "Masked distro iperf3.service (frees host :5201 for mesh-iperf3-server DaemonSet)."
fi

# ── Anti tunnel-recursion: block tailscale WG/disco over the CNI overlay ──────────────
# tailscaled advertises EVERY local address as a WireGuard endpoint candidate — including
# the pod-overlay addresses (10.42.x.0/.1). A peer that selects such an endpoint sends its
# WG/disco packets INTO the pod overlay, which itself rides on tailscale0 (the mesh node's
# k3s node-ip is its tailscale address) → recursive encapsulation (WG-in-VXLAN-in-WG)
# that re-enters the tunnel until the packet is dropped — 500+ GB of self-generated traffic
# per node in hours, 15-20% loss on ALL mesh paths, tailscaled at 150% CPU.
# Upstream tailscale only excludes zerotier/wt0 from endpoint discovery
# (net/netmon/state.go isProblematicInterface) — there is no knob for CNI interfaces, so
# enforce at the host firewall: drop tailscale's UDP port on the overlay interfaces. The
# disco prober then marks 10.42.x candidates unreachable and real LAN/WAN endpoints win.
# Legit pod/VXLAN-inner traffic never uses this port. The port is tailscaled --port; it is
# declared ONCE below as $TS_PORT with an anchor comment so
# updateConfigFromProjectSettings.sh keeps it tracking project_settings.network.tailscalePort.
# Do NOT inline the number into the nft rules: a wrong port there does not error, it just
# stops matching, and the flood comes back silently (see the superset note below).
# Own table + oneshot unit (NOT /etc/nftables.conf): Ubuntu's nftables.service is
# disabled by default and its stock conf starts with `flush ruleset`, which would wipe
# the k3s/kube-proxy tables if ever enabled.
#
# THE INTERFACE SET IS DELIBERATELY A SUPERSET, and this is load-bearing: iifname/oifname
# match by STRING, so a device that does not (yet) exist never matches, the ruleset still
# loads clean, and the flood above returns with NO alert. That property is what lets the
# rules load before the CNI creates its devices — and it is also why a stale name here is
# a silent regression. Cilium's devices only: cilium_vxlan, cilium_host, cilium_net and
# the per-pod lxc* veths.
apt-get install -y nftables
TS_PORT=41641 # automatically updated from project-settings:network.tailscalePort
OVERLAY_IFACES="cilium_vxlan cilium_host cilium_net lxc*" # automatically updated from project-settings:network.cniOverlayInterfaces
# Build the nft anonymous set from the anchored space-separated list. An EMPTY set is an nft
# syntax error, and this table loads before the CNI exists — a broken ruleset means no
# anti-recursion guard at all, so fail loudly instead.
[ -n "$OVERLAY_IFACES" ] || { echo "ERROR: OVERLAY_IFACES is empty" >&2; exit 1; }
IF_SET=""; for _i in $OVERLAY_IFACES; do IF_SET="$IF_SET\"$_i\", "; done
IF_SET="{ ${IF_SET%, } }"
# Heredoc UNQUOTED so $TS_PORT and $IF_SET expand. Nothing else in the body uses $.
cat > /etc/mesh-antiloop.nft <<NFT
#!/usr/sbin/nft -f
# Managed by provisioning (10-install-prereqs.sh) — do not edit.
# Drop tailscale WG/disco (udp ${TS_PORT}) on CNI overlay interfaces to prevent
# tunnel-in-tunnel recursion (the CNI tunnel runs over tailscale0).
table inet mesh_antiloop {}
delete table inet mesh_antiloop
table inet mesh_antiloop {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname ${IF_SET} udp sport ${TS_PORT} counter drop
        iifname ${IF_SET} udp dport ${TS_PORT} counter drop
    }
    chain output {
        type filter hook output priority filter; policy accept;
        oifname ${IF_SET} udp sport ${TS_PORT} counter drop
        oifname ${IF_SET} udp dport ${TS_PORT} counter drop
    }
}
NFT
cat > /etc/systemd/system/mesh-antiloop.service <<'UNIT'
[Unit]
Description=Block tailscale WG/disco over CNI overlay interfaces (anti tunnel-recursion)
# Before k3s so the guard is in place before the CNI/tailscale paths come up; not a
# hard dependency — the rules are also valid with no k3s at all.
Before=k3s-agent.service k3s.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/mesh-antiloop.nft
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mesh-antiloop.service
echo "mesh_antiloop nftables guard active (udp ${TS_PORT} blocked on cilium_*/lxc* overlay ifaces)."

echo "Longhorn prerequisites installed. iscsid: $(systemctl is-active iscsid)"
