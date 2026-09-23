#!/bin/bash
# 00-cleanup-node.sh — full mesh-node clean-slate.
#
# Run ON the mesh node (lab/home PC) as root to remove ALL stale state left
# behind after a cluster was destroyed (`make destroy`) but the node was not
# torn down. Stale tailscaled + k3s-agent keep beaconing the now-dead control
# URL / DERP / apiserver; a university IDS can rate-limit or blackhole the host
# for that, which then makes a later legitimate `tailscale up` time out even
# though plain HTTPS:443 still works.
#
# Removes: tailscale identity, the project's persistent route + MagicDNS resolved
# drop-ins, any half-joined k3s agent, THE WHOLE k3s STATE TREE (see below), and the
# stale mesh route. Idempotent.
#
# This script runs FIRST on every `make provision-mesh-node` (src/nodes-k3s-mesh.ts
# inlines it as /tmp/00-cleanup-node.sh before the prereq/VPN/join steps), so a provision always
# starts from a clean slate rather than adopting whatever the previous cluster left. That
# ordering is what makes the k3s wipe below effective — do not make it conditional.
#
# Usage (on the mesh node):
#   sudo bash 00-cleanup-node.sh                   # refuses if /var/lib/longhorn holds replicas
#   sudo bash 00-cleanup-node.sh --wipe-storage    # wipe them too (what a real re-provision needs)
# Then re-provision from the dev box:
#   make provision-mesh-node ARGS=<node-id>
#
# ⚠ --wipe-storage GUARDS THE ONE UNRECOVERABLE ACTION IN THIS SCRIPT. Everything else here
# is re-derivable — tailscale identity, k3s state, routes all come back on the next provision.
# `rm -rf /var/lib/longhorn` does not: the disk returns with a NEW UUID, so every replica CR
# still naming the old one is orphaned, Longhorn reports the volume `faulted`, and it loops
# "All replicas are failed … Bringing up 0 replicas for auto-salvage" forever — auto-salvage
# needs a running engine and the engine will not start while the volume is faulted. Only a
# backup restore recovers it.
#
# On 2026-08-30 a hand-run `pulumi up` reached this script on three HEALTHY unibi-lab nodes
# (the mesh skip-check had sampled them NotReady during a VPN blip) and destroyed every
# replica on all three, taking ad-onprem-0 down for 14 h with two unrecoverable AD volumes.
# The skip-check now retries before choosing that path, but a retry narrows the window rather
# than closing it — so the destructive step itself now requires the flag, and the callers that
# genuinely mean it pass it explicitly.
#
# The flag is REQUIRED only when there is something to lose: a node with no replicas (a fresh
# box, or one already cleaned) wipes unconditionally, so first-time provisioning is unaffected.
set -euo pipefail
trap 'echo "ERROR: 00-cleanup-node.sh failed at line $LINENO" >&2' ERR

WIPE_STORAGE=false
for _arg in "$@"; do
  case "$_arg" in
    --wipe-storage) WIPE_STORAGE=true ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument '$_arg' (try --help)" >&2; exit 2 ;;
  esac
done

# Re-exec with sudo if not root — pass the flags through, or the guard silently re-arms.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

# ── PREFLIGHT: decide about the storage wipe BEFORE destroying anything ──────────────────
# ⚠ THIS CHECK MUST RUN FIRST — do not move it down next to the `rm -rf /var/lib/longhorn`
# it guards. A refusal raised there lands AFTER tailscaled has been stopped, the tailscale
# identity wiped and the whole k3s state tree deleted: storage survives, but the node is
# broken and needs a full re-provision. A guard that fires halfway through is not a guard,
# just a slower failure. Refuse before the first destructive step or not at all.
#
# ⚠ THE DEFAULT DISK IS NOT THE ONLY DISK. A mesh node may declare extraLonghornDisks
# (project_settings ComputeNodeMesh) — additional Longhorn disks on separate filesystems,
# e.g. /mnt/storage1. Those hold replicas exactly like /var/lib/longhorn does, and a guard
# that only looks at the default path would report "nothing to lose" while the node is
# holding live data elsewhere. This script never wipes those paths (it only rm -rf's
# /var/lib/longhorn), but it DOES destroy the node's Longhorn identity, which orphans every
# replica on every disk. So the count must cover all of them.
#
# Discovery is by DISK MARKER, not by settings: a longhorn-disk.cfg file is what makes a
# directory a Longhorn disk, so scanning for it finds every disk this node actually has
# without the script needing to know what settings say. Depth 3 keeps the find cheap while
# covering the /mnt/<x>/ layout extraLonghornDisks uses.
_lh_replicas=0
_lh_paths=""
for _lh_d in /var/lib/longhorn $(find /mnt -maxdepth 3 -name longhorn-disk.cfg -printf '%h\n' 2>/dev/null); do
  [ -d "$_lh_d/replicas" ] || continue
  _n=$(find "$_lh_d/replicas" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  [ "$_n" -gt 0 ] || continue
  _lh_replicas=$((_lh_replicas + _n))
  _lh_paths="${_lh_paths}    $_lh_d: $_n
"
done
if [ "$_lh_replicas" -gt 0 ] && [ "$WIPE_STORAGE" != "true" ]; then
  echo "" >&2
  echo "REFUSING to run: this node holds $_lh_replicas Longhorn replica director(ies)." >&2
  printf '%s' "$_lh_paths" >&2
  echo "  Nothing has been changed on this node." >&2
  echo "" >&2
  echo "  Wiping them is UNRECOVERABLE — the disk returns with a new UUID, every replica CR" >&2
  echo "  naming the old one is orphaned, and Longhorn loops 'Bringing up 0 replicas for" >&2
  echo "  auto-salvage' forever. Only a backup restore brings the volume back." >&2
  echo "" >&2
  echo "  NB only /var/lib/longhorn is deleted outright; replicas on any OTHER disk listed" >&2
  echo "  above survive on disk but are orphaned all the same, because this script destroys" >&2
  echo "  the node's Longhorn identity that their volumes reference." >&2
  echo "" >&2
  echo "  If you really are re-provisioning this node from scratch, re-run with:" >&2
  echo "    sudo bash \$0 --wipe-storage" >&2
  echo "  If you did NOT expect to see this, something reached 00-cleanup-node.sh that should not" >&2
  echo "  have — check why (a mesh node sampled NotReady during a routine apply is the known" >&2
  echo "  case) before forcing it." >&2
  echo "" >&2
  exit 1
fi
[ "$_lh_replicas" -gt 0 ] \
  && echo "--wipe-storage: will destroy $_lh_replicas Longhorn replica director(ies) as requested." >&2

# Progress is reported by the `step` lines below, NOT by `set -x`. Tracing every command in
# this script buried the provisioning transcript in ~250 lines of `+ rm -f ...` — noise that
# scrolled the ACTIONABLE output (the storage-wipe refusal, the leftover-chain counts) off
# the screen. The phase markers say what is happening; a command that matters explains
# itself with an echo of its own, and a failure still names its line via the ERR trap.
step() { echo "  -> $*"; }

step "tailscale: disconnect, wipe identity, stop"
# ⚠ ORDER MATTERS: `down`/`logout` talk to tailscaled over its local socket, so they must run
# BEFORE the daemon is stopped. `logout` is what deregisters the node from headscale; stopping
# first leaves the machine registered there and reduces cleanup to the local `rm -rf` below.
# The socket gate keeps a node that never had tailscale (a first provision) from emitting the
# CLI's two-line "Failed to connect to local Tailscale daemon" stderr, which reads as a fault
# in the provisioning transcript and is not one.
if [ -S /var/run/tailscale/tailscaled.sock ]; then
    tailscale down 2>/dev/null || true
    tailscale logout 2>/dev/null || true
fi
systemctl stop tailscaled 2>/dev/null || true
rm -rf /var/lib/tailscale

step "route + DNS drop-ins"
# Remove persistent route + DNS drop-ins this project installed
rm -f /etc/systemd/system/tailscaled.service.d/vpn-routes.conf
rm -f /etc/systemd/system/tailscale.service.d/vpn-routes.conf
# Legacy: the MagicDNS split-route drop-in. 30-connect-vpn.sh no longer writes one
# (tailscaled programs resolved itself); kept so older-revision nodes are still cleaned up.
rm -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf

step "DNS pointer guard"
# ⚠ MUST come BEFORE the resolv.conf hand-back below, not after. The guard's whole job is to
# re-write `nameserver 127.0.0.2` whenever it finds the file pointing elsewhere — so a guard
# left running would simply undo the restored resolved symlink on its next tick (within 5 min,
# or immediately on the next NetworkManager event) and re-point a decommissioned node at a
# dnsmasq that is about to be deleted.
systemctl disable --now ecc-dns-pointer-guard.timer 2>/dev/null || true
systemctl stop ecc-dns-pointer-guard.service 2>/dev/null || true
rm -f /etc/systemd/system/ecc-dns-pointer-guard.timer \
      /etc/systemd/system/ecc-dns-pointer-guard.service \
      /usr/local/bin/ecc-dns-pointer-guard \
      /etc/NetworkManager/dispatcher.d/51-ecc-dns-pointer-guard
systemctl daemon-reload 2>/dev/null || true

# Hand DNS back to tailscaled as we found it. 30-connect-vpn.sh turns accept-dns OFF so its
# split-DNS pointer survives; a node being returned should behave like a stock tailscale host
# again. Harmless if tailscale is already gone (it is logged out above).
tailscale set --accept-dns=true 2>/dev/null || true

step "AD-zone resolver: stop, hand /etc/resolv.conf back"
# AD-zone resolver (installed on every mesh node): stop the unit and give /etc/resolv.conf back to
# systemd-resolved. Leaving it would point a decommissioned node at a dnsmasq forwarding to a
# cluster it is no longer part of — i.e. ALL name resolution on that box would break.
if [ -f /etc/systemd/system/ecc-ad-dns.service ]; then
    systemctl disable --now ecc-ad-dns.service 2>/dev/null || true
    rm -f /etc/systemd/system/ecc-ad-dns.service /etc/dnsmasq.d/ecc-ad-zone.conf
    systemctl daemon-reload 2>/dev/null || true
    if [ ! -L /etc/resolv.conf ] && [ -e /run/systemd/resolve/stub-resolv.conf ]; then
        rm -f /etc/resolv.conf
        ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
fi
rmdir /etc/systemd/system/tailscaled.service.d 2>/dev/null || true

step "cluster-subnet mesh-route unit"
# Remove the cluster-subnet mesh-route unit (current name + the legacy hetzner-private one).
for u in cluster-mesh-route hetzner-private-route; do
    systemctl disable "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/${u}.service"
done

step "k3s agent: uninstall"
# Tear down any half-joined k3s agent from the old cluster (this also removes the k3s
# containerd config tree, including any config-v3.toml.d/*.toml drop-ins we wrote).
#
# ⚠ Both of these are GENERATED BY k3s and carry their own `set -x`, so they trace ~40 lines
# of `+ rm -f ...` into the provisioning transcript. We cannot edit them (k3s rewrites them
# on every install), so their stdout is dropped here. stderr is KEPT: a real failure still
# surfaces, and the `|| true` is what stops a partially-installed agent aborting the run.
[ -x /usr/local/bin/k3s-agent-uninstall.sh ] && /usr/local/bin/k3s-agent-uninstall.sh >/dev/null || true
[ -x /usr/local/bin/k3s-killall.sh ] && /usr/local/bin/k3s-killall.sh >/dev/null || true

step "k3s state tree (cached cluster CA + token)"
# Wipe the k3s state tree UNCONDITIONALLY — the uninstaller is not enough, and this is the
# difference between a clean re-provision and a node that cannot join.
#
# WHY: /var/lib/rancher/k3s/agent/ caches the CLUSTER CA (client-ca.crt, server-ca.crt,
# the kubelet/proxy kubeconfigs). A re-provision against a RECREATED cluster hands the node
# a token issued by the NEW CA while the agent still trusts the OLD one, and k3s fails with
#   "token CA hash does not match the Cluster CA certificate hash: <new> != <old>"
# in an endless retry loop. Observed on home-martin-vm0: the token and
# the CP agreed with each other, so it read like a token bug — it was stale node-local CA.
#
# The uninstaller does not reliably clear it: it may be ABSENT (a box joined by other means,
# or a previous partial cleanup removed it), and `[ -x ] && ...` above then silently does
# nothing. Note that guard does NOT abort the script — bash exempts the final command of an
# `&&` list from `set -e` (verified) — so the failure mode is a silent skip, not an error.
#
# Removing the tree is safe: every file in it is re-created at join time from the token and
# the CP. It holds no local-only state worth keeping on a node that is being re-provisioned.
# /etc/rancher/k3s goes too — config.yaml is rewritten by 40-join-cluster.sh, and a stale
# one can carry settings (e.g. an old flannel-conf) into the new join.
systemctl stop k3s-agent 2>/dev/null || true
rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
# The token also lives in the unit's env file, which the uninstaller leaves behind when it
# is not the thing that created it.
rm -f /etc/systemd/system/k3s-agent.service.env /etc/systemd/system/k3s.service.env

step "Longhorn replica data"
# Longhorn replica data. NOTHING ELSE REMOVES THIS — not k3s-agent-uninstall.sh (it knows
# only about k3s), not `make destroy` (mesh nodes are adopted with create-only
# remote.Command resources, so pulumi has no delete path to the box at all), and not
# Longhorn itself once the cluster holding its CRDs is gone.
#
# Left alone these reach hundreds of records and hundreds of GiB of replica directories,
# every one a PVC UID from a DEAD cluster. That is not merely untidy — it takes the node
# over Longhorn's default storage-minimal-available-percentage (25%) floor, so its disk goes
# Schedulable=False with reason DiskPressure and a NEW volume cannot place its only replica:
# an hour-plus of ContainerCreating against a volume faulted for want of space nothing is
# using.
#
# ⚠ WHY THIS IS SAFE HERE AND WOULD NOT BE ELSEWHERE. 00-cleanup-node.sh runs on DECOMMISSION —
# the node is being wiped and re-provisioned, and a replica directory is meaningless without
# the Longhorn CRDs that index it. Do NOT lift this into a recreate path: on a recreate the
# PVs are Retain precisely so data survives, and a single-replica volume has no second copy
# to rebuild from.
#
# ⚠ SINGLE-NODE SITES MAKE THIS FATAL RATHER THAN DEGRADED. A site with one node (home-martin)
# has exactly one disk carrying its storageScope tag, so there is no other candidate for
# Longhorn to fall back to when that disk is refused — the volume simply never schedules.
# The WHOLE tree, not just replicas/: longhorn-disk.cfg pins the disk's UUID identity, and a
# re-provisioned node that keeps it re-registers as the OLD disk — inheriting its recorded
# scheduled/allocated figures while the replicas backing them are gone. metadata/ and
# engine-binaries/ are likewise per-cluster. Longhorn recreates all of it on first sync.
# The refusal happens up front (see the preflight near the top) — by the time execution
# reaches here the caller has either passed --wipe-storage or the node had nothing to lose.
rm -rf /var/lib/longhorn

step "node-local image + build stores"
# Node-local CONTAINER IMAGE and BUILD stores. These are hostPath volumes (not PVs, not
# containerd's own store), so nothing else in this script or in k3s-agent-uninstall.sh touches
# them, and they are the largest thing left on a decommissioned box: measured 2026-08-30 on
# unibi-lab-pcie-tb-s, 237 GB after a single `module load` — the Vivado 2024.1 image alone is
# 86.8 GB decompressed.
#
#   /var/lib/remote-desktop-gvisor-podman   desktop podman graphroot (desktop-gvisor.yaml)
#   /var/lib/xilinx-build                   [eda] runner buildah storage + extracted installer
#                                           media (app-of-apps/gitlab-runner-eda.yaml)
#   /var/lib/desktop-scratch                desktop scratch (desktop-gvisor.yaml)
#
# ⚠ REMOVED UNCONDITIONALLY, unlike Longhorn's data above, and the reason is the opposite one:
# nothing here is irreplaceable. Every image is reproducible from the lab-local registry
# (datapool/images, which is off-box and survives), and the extracted media is
# regenerable from /artifacts. So there is no "second copy" argument for keeping it.
#
# ⚠ THIS IS ALSO A DATA-RETENTION MATTER, not just disk space: these stores hold LICENSED
# VENDOR TOOLING (Xilinx/Vivado, HyperLynx). A box leaving the estate must not carry it away.
#
# Idempotent: absent paths are a no-op.
rm -rf /var/lib/remote-desktop-gvisor-podman /var/lib/xilinx-build /var/lib/desktop-scratch

step "nested-container runtime"
# Remove the nested-container runtime installs this project laid down
# (50-install-nested-runtime.sh). The k3s containerd drop-ins went with the agent uninstall above; drop the
# binaries, shims and runtime configs here. Removed unconditionally: labels are only ever
# added, never cleared, so leaving one behind lets a re-provisioned node advertise a runtime
# it no longer has. Idempotent.
rm -f /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /etc/containerd/runsc.toml

step "CNI leftovers (links, conflists)"
# CNI leftovers. k3s-agent-uninstall.sh deletes flannel's own links and iptables rules but
# knows NOTHING about Cilium: its state lives in eBPF maps under /sys/fs/bpf plus the
# cilium_* devices, and neither is touched by the k3s uninstaller. Left behind, a re-adopted
# node inherits stale maps and interfaces from the previous cluster.
# Also drop any CNI conflist: a leftover 10-flannel.conflist sorts BEFORE Cilium's
# 05-cilium.conflist by name and can win, so the node comes up on a CNI that no longer
# exists. Idempotent — every step is a no-op when absent.
for l in cilium_vxlan cilium_host cilium_net cilium_geneve cilium_wg0; do
    ip link del "$l" 2>/dev/null || true
done
# Per-pod veths (lxc<hash>) are removed with their netns when the agent is killed above;
# sweep any orphans left by an unclean shutdown.
for l in $(ip -o link show 2>/dev/null | awk -F': ' '/ lxc[0-9a-f]{6}/{print $2}' | cut -d@ -f1); do
    ip link del "$l" 2>/dev/null || true
done
# ⚠ DETACH THE SOCKET-LB CGROUP PROGRAMS. This is separate from the eBPF MAPS under
# /sys/fs/bpf and from /var/run/cilium: the `cil_sock*` programs are attached to the cgroup
# root at /run/cilium/cgroupv2, which nothing below touches. Left attached, the NEXT agent
# attaches its own generation alongside them (AttachFlags is `multi`), so the node ends up
# with TWO generations — 22 programs instead of 11 — and the STALE one wins the connect()
# rewrite. The old maps then send ClusterIP traffic to whatever pod IP the previous cluster
# had there, and since pod IPs are recycled it usually lands on a live pod that refuses the
# port.
#
# Symptom, which points nowhere near the CNI: pods on the node cannot reach ANY ClusterIP —
# CoreDNS included — so DNS fails for INTERNAL and EXTERNAL names alike. Downstream that
# looks like: a CSI controller cannot resolve its storage host and every PVC fails to
# provision, the registry crashloops, longhorn-manager sits at 1/2. Every cilium table
# (`service list`, `bpf lb list`, the raw maps) reads CORRECT throughout, because socket-LB
# rewrites in the pod's socket before the packet reaches the datapath those tables describe.
#
# Until this ran here, the only known fix was a REBOOT (an agent restart ADDS a generation
# rather than replacing one). Detaching at cleanup is what makes a re-provision sufficient.
# Check with: bpftool cgroup show /run/cilium/cgroupv2 | grep -c cil_sock   (11 = healthy)
# A REBOOT remains the reliable fallback if the counts below do not reach 0.
# ⚠ The guard below is why this must announce itself when it does NOT run. A missing bpftool
# (Thor's L4T image has none; every x86 node has one incidentally) makes the whole detach a
# no-op, and because the WARN used to live INSIDE the `if`, cleanup logged a clean run while
# nothing was detached — the node came back with two generations and only a reboot fixed it.
# 10-install-prereqs.sh now installs bpftool, so this should not trigger; say so loudly if it does.
if ! command -v bpftool >/dev/null 2>&1; then
    echo "  WARN: bpftool NOT FOUND — socket-LB cgroup programs were NOT detached. This node will come back with TWO generations of cil_sock* and ClusterIP/NodePort traffic on it may break. REBOOT the node after provisioning, or install bpftool and re-run." >&2
elif [ ! -d /run/cilium/cgroupv2 ]; then
    echo "  socket-LB cgroup programs: /run/cilium/cgroupv2 absent — nothing attached, nothing to detach."
fi
if command -v bpftool >/dev/null 2>&1 && [ -d /run/cilium/cgroupv2 ]; then
    # ⚠ EVERY bpftool call here needs `|| true`, not just the greps. The directory can exist
    # while no cgroup is mounted on it (exactly the state a wiped node is in), and bpftool
    # then exits 255 with "can't query bpf programs attached to ...: No such device or
    # address". Under `set -euo pipefail` that rc propagates out of the pipeline and aborts
    # the whole cleanup — measured on the ecc216 bootstrap, which died at this block on
    # unibi-hclab-thor-eval and failed the run. It only surfaced once bpftool was actually
    # installed on that box: before that, `command -v bpftool` was false and none of this ran.
    # ⚠ `grep -c` PRINTS 0 and EXITS 1 on no match, so `grep -c ... || echo 0` yields the
    # two-line string "0\n0", which never equals "0" — the WARN below then fires on a
    # perfectly clean node and tells the reader to reboot it for nothing. Count with awk
    # instead: one value, always rc=0.
    _cg_before=$({ bpftool cgroup show /run/cilium/cgroupv2 2>/dev/null || true; } | awk '/cil_sock/{n++} END{print n+0}')
    # ⚠ These are BPF_LINK attachments, so `bpftool cgroup detach` CANNOT remove them —
    # it fails with a bare "Error: failed to detach program" (rc=255) on every single one.
    # Do NOT reduce this to `cgroup detach ... 2>/dev/null || true`: that swallows the error
    # entirely, so the trace shows every detach followed by `+ true` and reads as a clean run
    # while the count stays unchanged and NOTHING is detached — the node then comes back with
    # two generations. `bpftool link show | grep -c cgroup` returning a large number is the
    # tell that links, not plain attachments, are in play.
    # Detach by LINK id; keep the cgroup path as a fallback for a genuinely link-less
    # attachment, and report failures instead of hiding them.
    if bpftool link show >/dev/null 2>&1; then
        { bpftool link show 2>/dev/null || true; } \
            | awk '/^[0-9]+: cgroup /{id=$1; sub(":","",id); print id}' \
            | while IFS= read -r lid; do
                [ -n "$lid" ] || continue
                bpftool link detach id "$lid" >/dev/null 2>&1 || true
              done
    fi
    # Fallback for any non-link attachment left over.
    { bpftool cgroup show /run/cilium/cgroupv2 2>/dev/null || true; } | awk '/cil_sock/{print $1, $2}' \
        | while read -r id atype; do
            [ -n "$id" ] || continue
            bpftool cgroup detach /run/cilium/cgroupv2 "$atype" id "$id" >/dev/null 2>&1 || true
          done
    _cg_after=$({ bpftool cgroup show /run/cilium/cgroupv2 2>/dev/null || true; } | awk '/cil_sock/{n++} END{print n+0}')
    echo "  socket-LB cgroup programs: ${_cg_before} -> ${_cg_after} (0 expected; the next agent attaches one fresh generation)"
    [ "${_cg_after}" = "0" ] || echo "  WARN: socket-LB programs survived cleanup — the node will come back with TWO generations and ClusterIP traffic may hit recycled pod IPs. A REBOOT is the reliable fallback." >&2
fi
# ⚠ REMOVE CILIUM'S IPTABLES CHAINS. Neither the k3s uninstaller nor anything above knows
# about them, and they are NOT covered by the eBPF/cgroup cleanup: cilium keeps a classic
# iptables layer (masquerade, proxy marks, NOTRACK) in chains named CILIUM_* across the
# nat/filter/mangle/raw tables, reached from the builtin chains via "cilium-feeder" jumps.
#
# Why leaving them behind is fatal on a re-provision. At startup the agent RENAMES its
# existing chains to OLD_CILIUM_*, installs a fresh CILIUM_* set, then deletes the OLD_*
# ones. That delete reconstructs each rule spec from the CURRENT config — so when the node's
# pod CIDR changed (a re-adopted node gets whatever CIDR the new cluster's IPAM hands out,
# e.g. 10.42.5.0/24 -> 10.42.3.0/24), the constructed `-D` matches nothing:
#
#   iptables rules full reconciliation failed, will retry another one later
#     failed to remove old backup rules: unable to run 'iptables -t nat -D OLD_CILIUM_POST_nat
#     -s 10.42.5.0/24 ! -d <old-ip>/24 ... -j MASQUERADE': Bad rule (does a matching rule exist)
#
# The agent ABORTS full reconciliation on that error and retries every ~10s forever, so it
# never installs the masquerade rule: CILIUM_POST_nat stays EMPTY while the feeder jumps
# still point at the OLD_* chains. Pods then have NO SNAT to the internet.
#
# Symptom, which points nowhere near iptables: the HOST reaches the internet fine (42ms to
# S3) while every POD on the node gets connect=0.000000 and hangs until timeout. That
# surfaces as gitlab-registry crashlooping — it logs "storage backend redirection
# enabled" then blocks on its first S3 call and never binds :5000/:5001, so the liveness
# probe kills it. `kubectl exec` into pods on the node also hangs. Cilium's own tables all
# read correct, exactly as with the socket-LB case above.
#
# Check with: iptables -t nat -S | grep -c OLD_CILIUM   (0 = clean)
#             iptables -t nat -S CILIUM_POST_nat        (must contain a MASQUERADE rule)
for t in nat filter mangle raw; do
    # Drop the feeder jumps FIRST — a chain with references cannot be deleted.
    #
    # ⚠ MUST go through `eval`. The feeder rules carry a quoted comment
    # (`--comment "cilium-feeder: CILIUM_PRE_nat"`), and passing the `iptables -S` line
    # unquoted word-splits it into `'"cilium-feeder:' 'CILIUM_PRE_nat"'` — iptables then
    # rejects the spec, every `-D` silently fails into `|| true`, the jumps survive, and the
    # `-X` below cannot delete a still-referenced chain. Observed on home-martin-vm0
    #: 20 chains left behind while the log looked like a clean run, because the
    # only evidence was a bare `+ true` in the trace.
    #
    # `|| true` on the grep is REQUIRED: under `set -o pipefail` an already-clean node (no
    # cilium jumps at all) makes grep exit 1, which aborts the whole script at this line.
    iptables -t "$t" -S 2>/dev/null | { grep -E '^-A .* -j (OLD_)?CILIUM' || true; } | sed 's/^-A /-D /' \
        | while IFS= read -r rule; do
            eval "iptables -t \"\$t\" $rule" 2>/dev/null \
                || echo "  WARN: could not delete feeder jump: iptables -t $t $rule" >&2
          done
    for c in $(iptables -t "$t" -S 2>/dev/null | awk '/^-N (OLD_)?CILIUM/{print $2}'); do
        iptables -t "$t" -F "$c" 2>/dev/null || true
        iptables -t "$t" -X "$c" 2>/dev/null \
            || echo "  WARN: chain $c ($t) still referenced — not deleted" >&2
    done
done
_ipt_left=$(for t in nat filter mangle raw; do iptables -t "$t" -S 2>/dev/null; done | grep -c CILIUM || true)
echo "  cilium iptables chains remaining: ${_ipt_left} (0 expected)"
[ "${_ipt_left}" = "0" ] || echo "  WARN: cilium iptables chains survived cleanup — a re-adopted node may lose pod egress (see the comment above)." >&2

umount /sys/fs/bpf 2>/dev/null || true
rm -rf /var/run/cilium /etc/cni/net.d/*cilium* /etc/cni/net.d/*flannel* 2>/dev/null || true

step "stale mesh route"
# Drop the stale mesh route if still present
MESH_RANGE="10.0.10.0/23" # automatically updated from project-settings:network.meshRange
ip route del "$MESH_RANGE" 2>/dev/null || true

step "reload systemd, restart resolved"
systemctl daemon-reload
systemctl restart systemd-resolved 2>/dev/null || true

echo "Clean. Now re-run from the dev box: make provision-mesh-node ARGS=<node-id>"
