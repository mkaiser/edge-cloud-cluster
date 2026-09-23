#!/bin/bash
# 40-join-cluster.sh — Install k3s agent and join the cluster over the VPN.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual; fills placeholders via sed)
#   - src/nodes-k3s-mesh.ts (Pulumi remote.Command; fills placeholders via env-subst)
# DO NOT COMMIT a filled-in copy (contains the k3s node token).
#
# Prerequisite: 30-connect-vpn.sh completed (tailscale up).
# Placeholders: K3S_TOKEN_PLACEHOLDER, K3S_VERSION_PLACEHOLDER
# Args: --node-name=<name>, --force (non-interactive re-provision)
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 40-join-cluster.sh failed at line $LINENO" >&2' ERR

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

FORCE=false
NODE_NAME=""
GPU_TYPE=""   # non-empty on a Jetson GPU node (see 20-install-gpu.sh): sets ecc/gpu=true +
              # ecc/gpu-model=<type> and the ecc/gpu=true:NoSchedule taint (opt-in GPU box)
for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
  [[ "$arg" == --node-name=* ]] && NODE_NAME="${arg#--node-name=}"
  [[ "$arg" == --gpu=* ]] && GPU_TYPE="${arg#--gpu=}"
done

K3S_TOKEN="K3S_TOKEN_PLACEHOLDER"
K3S_VERSION="K3S_VERSION_PLACEHOLDER"
# Hetzner private subnet (where the k3s apiserver is advertised) — kept in sync with
# project_settings.ts by scripts/environment/updateConfigFromProjectSettings.sh.
SUBNET_RANGE="10.0.0.0/23" # automatically updated from project-settings:network.subnetRange
# Pod CIDR, used by the pod->cluster-subnet SNAT below.
POD_CIDR="10.42.0.0/16" # automatically updated from project-settings:network.podCidr
# Connect to the API via the headscale MagicDNS name k3s-api.ts.internal, which resolves
# to cp0's tailscale IP (see deployment/argocd-infra/app-of-apps/wave8-headscale.yaml extra_records;
# repointed from the kube-vip VIP 10.0.0.100 to 10.0.10.1). Mesh nodes reach cp0 directly
# over the tailscale mesh; they CANNOT reach the private VIP 10.0.0.100 (cp0 doesn't forward
# 10.0.0.0/23 off tailscale0), which made the agent's local LB (127.0.0.1:6444) time out
# (Ready=Unknown, failed PVC fetches, pod crash-loops). The DNS name (vs a raw IP) survives
# control-plane IP changes / HA. Requires MagicDNS up at join + the name in the API cert SAN.
K3S_URL="https://k3s-api.ts.internal:6443"

# ── Verify VPN is connected ───────────────────────────────────────────────────
echo "=== Checking VPN connection ==="
command -v tailscale &>/dev/null || {
  echo "ERROR: tailscale not found. Run 30-connect-vpn.sh first." >&2; exit 1
}
MESH_VPN_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$MESH_VPN_IP" ] || {
  echo "ERROR: No tailscale VPN IP. Run 30-connect-vpn.sh first." >&2
  tailscale status >&2; exit 1
}
echo "VPN IP: $MESH_VPN_IP"

# ── Check for existing k3s-agent installation ────────────────────────────────
K3S_INSTALLED=false
if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  K3S_INSTALLED=true
  echo "k3s-agent service is active."
elif systemctl list-unit-files k3s-agent.service 2>/dev/null | grep -q k3s-agent; then
  K3S_INSTALLED=true
  echo "k3s-agent service is installed but not active."
elif [ -x /usr/local/bin/k3s ] && [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
  K3S_INSTALLED=true
  echo "k3s binary found (service not registered)."
fi

if [ "$K3S_INSTALLED" = "true" ]; then
  if [ "$FORCE" = "true" ]; then
    echo "Force flag set — uninstalling existing k3s-agent..."
  else
    printf "Existing k3s-agent installation detected. Uninstall and rejoin? [y/N] "
    read -r REPLY </dev/tty
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Skipping — node not changed."; exit 0 ;;
    esac
  fi
  systemctl stop k3s-agent 2>/dev/null || true
  /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
  # Drop the resolved split-routes. tailscale-magicdns.conf is LEGACY — 30-connect-vpn.sh
  # no longer writes one (tailscaled programs resolved itself), so this only clears it from
  # nodes provisioned by an older revision. ad-zone.conf IS current and is
  # re-created on rejoin by 30-connect-vpn.sh (on every mesh node); it must go here too, or a
  # node that has left the cluster keeps a resolver pointing at a DC it can no longer reach.
  if [ -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf ] \
     || [ -f /etc/systemd/resolved.conf.d/ad-zone.conf ]; then
    rm -f /etc/systemd/resolved.conf.d/tailscale-magicdns.conf
    rm -f /etc/systemd/resolved.conf.d/ad-zone.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  echo "Uninstalled."
fi

# ── Route to the cluster subnet over the mesh (HA-aware) ─────────────────────
# SUBNET_RANGE (10.0.0.0/23) is where the k3s apiserver is advertised (CP
# advertise-address). This is NOT provider-specific: cloud CPs advertise their Hetzner
# private subnet, an mesh init CP advertises its LAN subnet — either way this node reaches
# it over the mesh. The k3s agent load-balancer learns ALL CP endpoints and fails over
# across them, so this node must reach the cluster subnet via WHICHEVER CP is alive, not a
# fixed one. Every CP advertises SUBNET_RANGE into the mesh and SNATs mesh→subnet (see
# src/nodes-k3s-base.ts + _local-fetch-cluster-inputs.sh route approval). We let tailscale own
# this route (dev tailscale0, no fixed `via`): with --accept-routes (set in 30-connect-vpn.sh)
# tailscaled installs it and points the next-hop at a live CP, failing over automatically.
# A fixed `via <CP>` would pin the next-hop and BREAK failover, so we deliberately omit one.
# In non-HA there is only the init CP, so this resolves to it — identical to before.
echo ""
echo "=== Installing route to the cluster subnet over the mesh (tailscale-managed, HA) ==="
ip route replace "$SUBNET_RANGE" dev tailscale0 2>/dev/null || true
echo "Route $SUBNET_RANGE -> dev tailscale0 (headscale-managed next-hop)"

# NB: unquoted heredoc so $SUBNET_RANGE expands now; the runtime shell vars ($i, $(seq…))
# are escaped (\$) so they are evaluated by systemd at boot, not when this file is written.
cat > /etc/systemd/system/cluster-mesh-route.service << ROUTE_SVC
[Unit]
Description=Route to the cluster subnet via tailscale (HA, headscale-managed next-hop)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 60); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; ip route replace ${SUBNET_RANGE} dev tailscale0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
ROUTE_SVC
systemctl daemon-reload
systemctl enable cluster-mesh-route
echo "Persistent route service enabled."

# ── SNAT pod traffic destined for the cluster subnet ────────────────────────────
# The route above gets pod→SUBNET_RANGE packets onto tailscale0, but they leave with the
# POD ip as source (10.42.x.y). WireGuard cryptokey routing only accepts the peer's own
# mesh address, so every one is silently discarded at the far end — the packet is visible
# leaving `tailscale0 Out` in tcpdump and simply never arrives.
#
# Symptom if missing: the NODE reaches the apiserver fine (kubelet is host-sourced, so is
# any hostNetwork pod), the node shows Ready, cross-node POD-to-POD works because that is
# VXLAN-encapsulated with a node source — but ordinary pods cannot reach the apiserver by
# its host ip OR by the kubernetes ClusterIP. Concretely: longhorn-manager sits at 1/2
# forever on `dial tcp 10.43.0.1:443: i/o timeout` during leader election, so mesh nodes
# never register a Longhorn node object, so any PVC bound to a mesh storageClass stays
# Pending and its pod never schedules.
#
# This is the mesh-side mirror of the CP-side rule (`-s 10.0.10.0/23 -d 10.0.0.0/23 -j
# MASQUERADE`, src/nodes-k3s-base.ts): each side rewrites its pod/mesh traffic to a source
# the other end's WireGuard will accept.
echo ""
echo "=== Installing pod->cluster-subnet SNAT (WireGuard cryptokey routing) ==="
MESH_SNAT_IP="${MESH_VPN_IP}"
if [ -n "$MESH_SNAT_IP" ]; then
    # ⚠ DROP STALE RULES FIRST, and match on the RULE SHAPE, not on --to-source.
    # A plain `-C ... --to-source $MESH_SNAT_IP || -A` looks idempotent but is not: the
    # node's mesh IP is reassigned by headscale on a cluster RECREATE, so a surviving rule
    # carries the OLD address. The -C probe (which includes the NEW ip) then misses it and
    # appends, leaving BOTH rules — and iptables takes the FIRST match, so pods keep being
    # SNATed to another node's mesh address and WireGuard silently drops every packet.
    # For example: pcie-tb-s had `--to-source 10.0.10.2` (pcie-tb-d's new ip) ahead
    # of its own 10.0.10.4, and cape-vm had 10.0.10.4 ahead of its own 10.0.10.3 — both
    # nodes Ready, longhorn-manager stuck 1/2, every mesh PVC Pending. Only the node that
    # had been 00-cleanup-node.sh'd was correct.
    while iptables -t nat -S POSTROUTING 2>/dev/null \
            | grep -q -- "-s ${POD_CIDR} -d ${SUBNET_RANGE} -o tailscale0 -j SNAT"; do
        STALE=$(iptables -t nat -S POSTROUTING 2>/dev/null \
                | grep -m1 -- "-s ${POD_CIDR} -d ${SUBNET_RANGE} -o tailscale0 -j SNAT")
        # shellcheck disable=SC2086
        iptables -t nat -D ${STALE#-A } || break
        echo "  removed pre-existing pod SNAT rule:${STALE#-A POSTROUTING}"
    done
    iptables -t nat -A POSTROUTING -s "$POD_CIDR" -d "$SUBNET_RANGE" \
        -o tailscale0 -j SNAT --to-source "$MESH_SNAT_IP"
    echo "Pod SNAT installed: ${POD_CIDR} -> $SUBNET_RANGE out tailscale0 as $MESH_SNAT_IP"
else
    echo "WARN: MESH_VPN_IP empty; skipping pod->subnet SNAT (pods will NOT reach the apiserver)" >&2
fi

# Persist it: iptables rules do not survive a reboot, and unlike the route there is no
# tailscale-managed equivalent. Same wait-for-tailscale0 shape as cluster-mesh-route.
cat > /etc/systemd/system/cluster-mesh-snat.service << SNAT_SVC
[Unit]
Description=SNAT pod traffic to the cluster subnet over tailscale (WireGuard cryptokey routing)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 60); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; while iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s ${POD_CIDR} -d ${SUBNET_RANGE} -o tailscale0 -j SNAT"; do S=\$(iptables -t nat -S POSTROUTING | grep -m1 -- "-s ${POD_CIDR} -d ${SUBNET_RANGE} -o tailscale0 -j SNAT"); iptables -t nat -D \${S#-A } || break; done; iptables -t nat -A POSTROUTING -s ${POD_CIDR} -d ${SUBNET_RANGE} -o tailscale0 -j SNAT --to-source ${MESH_VPN_IP}'

[Install]
WantedBy=multi-user.target
SNAT_SVC
systemctl daemon-reload
systemctl enable cluster-mesh-snat
echo "Persistent pod-SNAT service enabled."

# ── cilium_vxlan tx-offload off (VXLAN-over-WireGuard checksum repair) ──────────
# Cilium's VXLAN runs over tailscale0 here. With tx-udp-segmentation / generic
# checksum offload on the tunnel device, the VXLAN outer UDP checksum is left
# wrong for the userspace WireGuard path (no NIC fixup), so the peer drops frames
# as UdpInCsumErrors — cloud↔mesh pod traffic silently breaks. Disable both.
# The cloud (CP) side does the same in deployment/argocd-infra/mesh-gateway/daemonset.yaml.
#
# This is a property of VXLAN-over-userspace-WireGuard, not of any one CNI.
#
# WHY A TIMER, not a single boot-time oneshot: the CNI recreates its tunnel device
# on EVERY agent restart, and each recreation resets the offloads back to ON.
# A `RemainAfterExit` oneshot wired only to multi-user.target fires at most once
# and never re-applies, leaving offloads silently ON (rising UdpInCsumErrors, 3-5%
# TCP retransmits, flappy mesh) after any later agent restart. The timer re-asserts
# every minute; ethtool -K is idempotent.
command -v ethtool >/dev/null 2>&1 || (apt-get install -y ethtool >/dev/null 2>&1 || apk add --no-cache ethtool >/dev/null 2>&1) || true
cat > /etc/systemd/system/cni-offload.service << 'OFFLOAD_SVC'
[Unit]
Description=Disable cilium_vxlan tx offload (VXLAN-over-WireGuard checksum repair)
After=k3s-agent.service
Wants=k3s-agent.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 120); do ip link show cilium_vxlan >/dev/null 2>&1 && break; sleep 1; done; ethtool -K cilium_vxlan tx-udp-segmentation off tx-checksum-ip-generic off 2>/dev/null || true'
OFFLOAD_SVC
cat > /etc/systemd/system/cni-offload.timer << 'OFFLOAD_TIMER'
[Unit]
Description=Re-assert cilium_vxlan tx offload off (the CNI resets it on restart)

[Timer]
# Fire ~30s after boot, then every minute; Persistent so a missed tick after a
# suspend/downtime runs on resume.
OnBootSec=30s
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
OFFLOAD_TIMER
systemctl daemon-reload
systemctl enable --now cni-offload.timer 2>/dev/null || systemctl enable cni-offload.timer
echo "Persistent cni-offload timer enabled (re-asserts every 1min)."

# ── Install k3s agent ─────────────────────────────────────────────────────────
echo ""
echo "=== Install k3s agent ==="
mkdir -p /etc/rancher/k3s
# ⚠ create-default-disk MUST be 'config', not 'true'. 'true' tells Longhorn "create a plain default disk and
# IGNORE node.longhorn.io/default-disks-config", so the disk comes up with NO tags and every
# per-scope StorageClass (diskSelector = the storageScope tag) fails outright:
#   failed to provision volume with StorageClass "longhorn-home-martin":
#     message=specified disk tag home-martin does not exist
# (windows-vm-storage sat Pending 5h48m / 52 failures this way.)
# This is also a RACE between two writers: kubelet re-asserts this label from config.yaml on
# every start, while mesh-label-* sets 'config' via kubectl afterwards. Whoever runs last
# wins, which is why some nodes came back tagged and others did not. Keeping both at 'config'
# removes the race instead of relying on ordering.
# Tell-tale of a disk created under 'true': its path has a TRAILING SLASH
# (/var/lib/longhorn/) vs /var/lib/longhorn for one created from the config annotation.
#
# NB these notes live OUTSIDE the heredoc on purpose. KCONFIG is unquoted because the body
# interpolates ${MESH_VPN_IP}/${NODE_NAME}/${GPU_TYPE}, so backticks inside it would be
# command substitution, not punctuation — `config` in a comment ran as a command and printed
# three "config: command not found" lines per node on every mesh provision.
cat > /etc/rancher/k3s/config.yaml << KCONFIG
node-ip: ${MESH_VPN_IP}
${NODE_NAME:+node-name: ${NODE_NAME}}
node-label:
  - 'node.longhorn.io/create-default-disk=config'
  - 'node.kubernetes.io/mesh-worker=true'
${GPU_TYPE:+  - 'ecc/gpu=true'}
${GPU_TYPE:+  - 'ecc/gpu-model=${GPU_TYPE}'}
node-taint:
  - 'ecc/mesh=true:NoSchedule'
${GPU_TYPE:+  - 'ecc/gpu=true:NoSchedule'}
KCONFIG

# No CNI keys in the agent config: Cilium owns the pod network (src/cni.ts), and the keys
# that select the CNI are SERVER-only — this is an agent, so it inherits them from the
# cluster.
#
# The MTU constraint is a property of the path, not of the CNI. This node tunnels over
# tailscale0 (WireGuard MTU 1280) and VXLAN adds ~50B, so the pod MTU must be 1230 or large
# frames (API watch streams, kubectl logs, Longhorn gRPC) are silently dropped while small
# ones pass — an intermittently-"Ready" node whose pods crash-loop. It is set once,
# cluster-wide, as Cilium's MTU (project_settings.network.cni.mtu).

echo "  API server : $K3S_URL"
echo "  node-ip    : $MESH_VPN_IP"
echo "  node-name  : ${NODE_NAME:-$(hostname)}"
[ -n "$GPU_TYPE" ] && echo "  gpu        : $GPU_TYPE (ecc/gpu=true + ecc/gpu-model labels, ecc/gpu taint, nvidia runtime)"
echo "  interface  : tailscale0"
echo "  version    : ${K3S_VERSION:-latest}"

# INSTALL_K3S_SKIP_START=true: the k3s installer normally does `systemctl start k3s-agent`
# and BLOCKS on the start job. On a first join the agent's initial startup (image pulls, CRI
# bring-up, CNI) routinely exceeds systemd's start-job timeout, so the START JOB is marked
# failed even though the process stays up and goes Ready seconds later. The installer then
# returns non-zero → `set -e` + the ERR trap abort THIS script → the caller
# (the provision-mesh-node-* driver) never runs the post-join label/annotate/uncordon block,
# leaving the node cordoned + unlabelled. So we skip the installer's blocking start and start
# the unit ourselves non-blocking, then poll for readiness below.
K3S_INSTALL_ENV=(INSTALL_K3S_SKIP_START=true K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN")
[ -n "$K3S_VERSION" ] && K3S_INSTALL_ENV+=(INSTALL_K3S_VERSION="$K3S_VERSION")
# Idempotent install: skip the get.k3s.io/update.k3s.io fetch when the agent binary is
# already present. That download occasionally returns a bad/self-signed TLS cert (transient
# upstream) and aborts under `set -e`; a re-adoption of an already-joined mesh node must not
# re-hit it. Fresh node → binary absent → installs normally.
if command -v k3s >/dev/null 2>&1; then
    echo "k3s already installed ($(k3s --version 2>/dev/null | head -1)) — skipping installer download."
else
    curl -sfL https://get.k3s.io | env "${K3S_INSTALL_ENV[@]}" sh -
fi

echo ""
echo "=== Starting k3s-agent (non-blocking) and waiting for readiness ==="
systemctl enable k3s-agent >/dev/null 2>&1 || true
# --no-block: don't fail if the first start job exceeds systemd's timeout; we verify below.
systemctl start --no-block k3s-agent 2>/dev/null || true

# Wait for the agent to be up and STABLE. "Ready" for a k3s node is decided by the control
# plane (kubelet posting status), which the caller already polls via `kubectl get node`. Here
# we only need the local service to be running and not crash-looping: require k3s-agent active
# for a short stability window. A genuinely-broken unit (bad token, unreachable API) flips to
# failed / keeps restarting and never satisfies this.
JOINED=false
STABLE=0
for i in $(seq 1 60); do
  if systemctl is-failed --quiet k3s-agent; then
    echo "k3s-agent entered failed state — logs:" >&2
    journalctl -u k3s-agent --no-pager -n 40 >&2 || true
    STABLE=0
  elif systemctl is-active --quiet k3s-agent; then
    STABLE=$((STABLE + 1))
    [ "$STABLE" -ge 3 ] && { JOINED=true; break; }   # active across ~15s → converged
  else
    STABLE=0
  fi
  sleep 5
done

if [ "$JOINED" != "true" ]; then
  echo "ERROR: k3s-agent did not stay running after ~300s." >&2
  systemctl status k3s-agent --no-pager -l >&2 || true
  exit 1
fi

echo ""
echo "=== Node joined ==="
echo "Verify from devcontainer: kubectl get nodes"
