/**
 * Project: edgecloudinfra
 * File: nodes-k3s-common.ts
 * Purpose: Provider-AGNOSTIC k3s provisioning building blocks — bash snippets and small
 *          config builders reused across every node kind (Hetzner cloud VM, Hetzner
 *          dedicated/robot, on-premise mesh, and future SECA providers).
 *
 *          Nothing here is Hetzner-specific: these produce k3s config.yaml fragments,
 *          host-prep shell, swap/longhorn/CNI setup, and the etcd-S3 backup blocks.
 *          The provider-specific machine creation (hcloud.Server vs SSH) lives in the
 *          per-provider files; the SSH join/token/kubeconfig orchestration lives in
 *          nodes-k3s-base.ts.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import { project_settings } from "../project_settings";
import { TARGET_STATES } from "../project_settings_types";
import type {
    SwapBehavior,
    ComputeNodeCloud,
    ComputeNodeCloudDedicated,
} from "../project_settings_types";

// Peer control-plane IP discovery for the initial-CP join-or-init probe. Emits a bash
// fragment setting PEER_IP to the peer's public IP (empty when there is no peer). Discovery
// depends on the PEER's provider, not the asking provisioner: an hcloud peer is looked up
// via the Hetzner Cloud API by node-name; a robot peer uses its configured publicIp. Shared
// by both provisioners so a mixed robot/cloud CP set resolves either peer kind correctly.
export const peerCpIpScript = (peer: ComputeNodeCloud | undefined): pulumi.Input<string> => {
    if (!peer) return `PEER_IP=""`;
    const clusterName = project_settings.general.name.toLowerCase();
    if (peer.provider === "robot") {
        return `PEER_IP="${(peer as ComputeNodeCloudDedicated).publicIp}"`;
    }
    // hcloud peer: resolve its public IP from the Hetzner Cloud API by node-name.
    return pulumi.interpolate`PEER_IP=$(curl -sf -H "Authorization: Bearer ${project_settings.hetzner.hcloudToken}" \
                "https://api.hetzner.cloud/v1/servers?name=${clusterName}-${peer.id}" | \
                jq -r '.servers[0].public_net.ipv4.ip // ""' 2>/dev/null || echo "")`;
};

// Hard wall-clock cap for local provisioning Commands. SSH/wait loops that get stuck
// (unreachable node, missing agent key, hung API) are aborted with SIGTERM, then
// SIGKILL 10s later, instead of blocking `make bootstrap` for the full internal loop
// budget. timeout exits 124 on expiry → the Pulumi step fails fast with a clear error
// rather than hanging. Applied as the Command `interpreter` so it wraps the whole
// create/update script (`timeout … /bin/bash -c "<script>"`). Internal wait loops are
// sized to finish (and print diagnostics) just under this cap.
export const LOCAL_CMD_TIMEOUT_SECS = 600;
export const abortAfter = (secs: number = LOCAL_CMD_TIMEOUT_SECS): string[] => [
    "timeout",
    "--kill-after=10s",
    `${secs}s`,
    "/bin/bash",
    "-c",
];

// CNI config.yaml keys, written on EVERY k3s SERVER (cp0 + additional CPs).
//
// k3s ships flannel + its own kube-router network-policy controller; both are turned off so
// Cilium owns the datapath. Consequences if any of these is
// missing on one node: `flannel-backend: none` absent ⇒ that node runs flannel alongside
// Cilium and pods get two CNI plugins fighting over the same veth; `disable-network-policy`
// absent ⇒ kube-router programs iptables rules Cilium does not know about.
//
// cluster-cidr / service-cidr were NEVER declared before this migration — the pod CIDR
// existed only inside flannel's net-conf and the service CIDR was left at the k3s default.
// Cilium needs both explicit, and they are cluster-wide values that must be IDENTICAL on
// every server: k3s stores them in etcd at cluster-init, and a follower disagreeing about
// service-cidr will not converge.
//
// disable-kube-proxy pairs with Cilium's kubeProxyReplacement=true (src/cni.ts): Cilium's
// eBPF datapath takes over Service forwarding entirely. The two MUST move together — with
// only one set, either nothing programs Services or kube-proxy and Cilium both do.
// NB k3s runs kube-proxy IN-PROCESS inside the agent, not as a DaemonSet, so there is
// nothing to `kubectl delete`; this flag is the only off switch. It is defined SERVER-side
// only (k3s pkg/cli/cmds/server.go) and agents fetch the setting from the server at startup
// (pkg/agent/config/config.go getKubeProxyDisabled), so setting it here covers every node.
export const k3sCniServerConfig = [
    "flannel-backend: none",
    "disable-network-policy: true",
    "disable-kube-proxy: true",
    `cluster-cidr: ${project_settings.network.cni.podCidr}`,
    `service-cidr: ${project_settings.network.cni.serviceCidr}`,
].join("\n");

// ⚠ `coredns` is disabled here and replaced by deployment/argocd-infra/coredns (the official
// coredns/helm chart), for the same reason traefik and servicelb are: k3s ships CoreDNS as a
// PLAIN MANIFEST (manifests/coredns.yaml), not a Helm chart, so there is no HelmChartConfig
// to override it and k3s re-applies the file over any edit. Its fixed manifest cannot express
// what this cluster needs — a toleration for the `ecc/mesh` taint every mesh node carries, so
// CoreDNS can actually run at each site instead of being pinned to the one untainted cloud
// node, plus per-site topology spread, a PDB and the cluster-proportional autoscaler.
//
// ⚠ Disabling coredns ALSO stops k3s maintaining the `NodeHosts` key of the coredns ConfigMap:
// pkg/server/server.go passes `!Skips["coredns"]` to node.Register, so the node controller
// that writes node-name -> node-IP host entries goes away with it. That is accepted and the
// hosts block is dropped: nothing in deployment/ resolves bare node hostnames, and node
// addresses are already anchored in project_settings.ts.
export const k3sDisableFlags =
    project_settings.general.loadBalancerProvider === "hetzner-ccm"
        ? "disable:\n  - servicelb\n  - traefik\n  - coredns"
        : "disable:\n  - traefik\n  - coredns";
// Nodes with swap (node.swap > 0) additionally get a kubelet config file
// (kubelet-arg=config=…) that sets failSwapOn:false + memorySwap.swapBehavior —
// see swapKubeletArg / swapSetupScript. failSwapOn is set in that config file
// (NOT the --fail-swap-on flag) to avoid the kubelet flag-vs-config conflict error.
export const k3sServerCloudProviderConfig =
    project_settings.general.loadBalancerProvider === "hetzner-ccm"
        ? "disable-cloud-controller: true\nkubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
        : "kubelet-arg:\n  - max-pods=300";
// max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping heavy workloads
export const k3sWorkerCloudProviderConfig =
    project_settings.general.loadBalancerProvider === "hetzner-ccm"
        ? "kubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
        : "kubelet-arg:\n  - max-pods=300";
// max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping heavy workloads
// Per-node kubelet-arg list item: point the kubelet at the swap config file
// (only written when the node has swap > 0). Appends under the existing
// kubelet-arg: block in config.yaml. Empty string when the node has no swap.
export const swapKubeletArg = (gib?: number) =>
    gib && gib > 0 ? "\n  - config=/etc/rancher/k3s/kubelet-swap.yaml" : "";

// Shared bash snippet: install Longhorn host prerequisites (open-iscsi + nfs).
// CRITICAL: the previous one-liner `apt-get update -qq && apt-get install ...`
// aborted the whole step (under set -e) whenever the FIRST `apt-get update` at
// first boot hit a flaky/unready Debian mirror ("Some index files failed to
// download"), silently skipping open-iscsi → Longhorn managers CrashLoopBackOff
// ("iscsiadm: No such file or directory"). Retry apt-get update a few times,
// tolerate its failure (install can still use cached/partial indexes), and retry
// the install itself. Never let a transient mirror blip leave a node without iscsi.
export const longhornPrereqScript = `
    for i in 1 2 3 4 5; do apt-get update -qq && break || { echo "apt-get update failed (try $i) — retrying"; sleep 5; }; done
    for i in 1 2 3 4 5; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common open-iscsi && break
        echo "apt-get install open-iscsi failed (try $i) — apt-get update + retry"; apt-get update -qq || true; sleep 5
    done
    command -v iscsiadm >/dev/null || { echo "FATAL: iscsiadm still not installed after retries" >&2; exit 1; }
    systemctl enable --now iscsid
`;

// Shared bash snippet: set timezone for Debian/Ubuntu nodes.
export const timezoneSetupScript = `
    timedatectl set-timezone ${project_settings.general.timezone} || {
        ln -sf /usr/share/zoneinfo/${project_settings.general.timezone} /etc/localtime
        echo ${project_settings.general.timezone} > /etc/timezone
    }
`;

// Shared bash snippet: kernel tuning required for heavy workloads (GitLab, Nextcloud).
// inotify defaults (128 instances, 8192 watches) are exhausted by the number of
// pods/containers running on a single node, causing "too many open files" in GitLab migrations.
//
// tcp_congestion_control=bbr is the mesh fix, and it is worth far more than it looks.
// CUBIC treats ANY packet loss as congestion and collapses its window. The cloud→lab path
// carries ~0.2% steady loss at a 12.7 ms RTT, and with the mesh MSS of 1140 the Mathis
// bound (MSS / (RTT * sqrt(loss))) works out at ~16-18 Mbit/s — which is EXACTLY what CUBIC
// delivered. The link itself was never the limit: UDP over the same path sustained
// 397 Mbit/s at 0.77% loss. BBR models bandwidth+RTT instead of reacting to loss, so it
// ignores that sparse loss.
//
// Measured cloud→lab, single stream:
//   node↔node over tailscale : cubic 17 Mbit/s -> bbr 477-482 Mbit/s   (28x)
//   pod↔pod (Cilium/VXLAN)   : cubic 38-88     -> bbr 335 Mbit/s       (~5x)
// The reverse direction (lab→cloud, already fast at ~280 Mbit/s pod-level) is unchanged,
// so this is not a trade-off. fq is BBR's companion qdisc — BBR is pacing-based and
// misbehaves without it.
//
// Applies to EVERY node, not just mesh: it is strictly better on a lossless path too,
// and the CP is the sender for cloud→mesh traffic, so the CP is where it matters most.
export const sysctlTuningScript = `
    cat >> /etc/sysctl.d/99-k8s.conf << 'SYSCTL'
fs.inotify.max_user_instances = 4096
fs.inotify.max_user_watches = 1048576
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
    modprobe tcp_bbr 2>/dev/null || true
    grep -qxF 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
    # wireguard: loaded on the HOST at boot so the admin-VPN pod (src/wireguard.ts) does not
    # have to load it itself. That pod is hostNetwork and currently holds SYS_MODULE purely
    # for this — a capability that can insert arbitrary kernel modules, i.e. root-equivalent,
    # on the one pod that is also the only inbound path under Production posture.
    modprobe wireguard 2>/dev/null || true
    grep -qxF 'wireguard' /etc/modules-load.d/wireguard.conf 2>/dev/null || echo 'wireguard' > /etc/modules-load.d/wireguard.conf
    sysctl --system
    # Verify: if the module is missing the sysctl silently keeps the old value.
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]; then
        echo "WARN: tcp_congestion_control is not bbr (module missing?) — cloud->mesh will be ~17 Mbit/s" >&2
    fi
`;

// Per-node bash snippet: create + enable a swapfile (node.swap GiB) as an
// OOM cushion. Idempotent; persists via /etc/fstab; low swappiness so swap is a
// safety margin, not a hot path. Also writes the kubelet swap config file
// (failSwapOn:false so the kubelet starts with swap present, + the node's
// memorySwap.swapBehavior, default NoSwap). Empty string when the node has no
// swap configured. Paired with swapKubeletArg (the config= flag).
export const swapSetupScript = (gib?: number, behavior?: SwapBehavior) =>
    gib && gib > 0
        ? `
    if ! swapon --show=NAME --noheadings | grep -q '/swapfile'; then
        fallocate -l ${gib}G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((${gib} * 1024))
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo 'vm.swappiness = 10' > /etc/sysctl.d/99-swap.conf
        sysctl -w vm.swappiness=10 || true
        echo "Swap enabled: ${gib}G"
    fi
    mkdir -p /etc/rancher/k3s
    cat > /etc/rancher/k3s/kubelet-swap.yaml << 'KUBELETSWAP'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: ${behavior ?? "NoSwap"}
KUBELETSWAP
`
        : "";

// ── Host firewall: public-NIC default-drop allow-list ───────────────────────────────────
// Renders the bash fragment that installs the `inet public_guard` nftables table: a
// stateful default-drop on the PUBLIC NIC only, allowing exactly the public rules from
// project_settings.network.firewall (targetState-gated). This is the ONLY enforcement
// layer on robot/dedicated boxes — the Robot firewall caps at 10 rules per chain with a
// mandatory ip_version per rule and cannot express this allow-list (12 rules in Bootstrap);
// see robotFirewallEnsureScript in network.ts. On hcloud VMs it is defense-in-depth behind
// the hcloud Cloud firewall, and the only layer that filters private-network traffic.
//
// Included by the robot and hcloud host-prep fragments below/in the robot provisioner.
// MESH NODES MUST NOT INCLUDE IT: they have no public IP (NAT'd LAN sites), and on mesh
// the default-route iface IS the LAN iface carrying k3s/VXLAN/SSH — this policy would
// default-drop the node's own cluster plane and brick every mesh node at once. A future
// mesh init CP WITH a public IP would need a guarded variant (see nodes-k3s-mesh.ts).
function publicFirewallPorts(targetState = project_settings.general.targetState): {
    tcp: number[];
    udp: number[];
} {
    const { bringUpRules, alwaysRules } = project_settings.network.firewall;
    const rules =
        targetState === "production" ? [...alwaysRules] : [...bringUpRules, ...alwaysRules];
    // Public rules only: private-source rules (e.g. etcd 2380 from privateRange) arrive on
    // the private iface, which the guard accepts wholesale — they'd be dead rules here.
    const pub = rules.filter((r) => (r.sourceIps ?? []).includes("0.0.0.0/0"));
    const ports = (proto: string) =>
        pub
            .filter((r) => r.protocol === proto && r.port)
            .map((r) => Number(r.port))
            .sort((a, b) => a - b);
    return { tcp: ports("tcp"), udp: ports("udp") };
}

// The mesh_antiloop interface set, rendered as an nft anonymous set from
// project_settings.network.cni.overlayInterfaces. One source for all three copies of the
// table: this one interpolates it, the node-guard DaemonSet and 10-install-prereqs.sh build
// the same string in shell from their anchored OVERLAY_IFACES assignment.
function nftOverlayIfaceSet(): string {
    const names = project_settings.network.cni.overlayInterfaces.trim().split(/\s+/);
    if (names.length === 0 || names[0] === "") {
        // An empty set is an nft SYNTAX ERROR, and this table loads before the CNI exists —
        // a broken ruleset here means no anti-recursion guard at all on a fresh node.
        throw new Error(
            "network.cni.overlayInterfaces is empty — mesh_antiloop needs at least one device name",
        );
    }
    return `{ ${names.map((n) => `"${n}"`).join(", ")} }`;
}

// A teardown or a shutdown must never render the HARDENED guard. Those paths reopen public
// 22/6443 over the admin WireGuard tunnel so the Pulumi k8s provider (whose kubeconfig points
// at the public IP) can delete Helm releases — but if ANY guard input changed since the last
// apply, the teardown-sync `pulumi up` re-applies this script in the same pass and slams that
// door shut again, and every k8s call after it fails "cluster unreachable" (hit 2026-09-03).
// This needs no special case: "destroy" and "shutdown" are open postures in TargetState, so
// during either the guard can only ever open.
export function publicGuardScript(targetState = project_settings.general.targetState): string {
    const { tcp, udp } = publicFirewallPorts(targetState);
    // Defense against an empty set rendering `dport { }` (nft syntax error) if the rule
    // lists are ever emptied: omit the line entirely.
    const tcpRule = tcp.length ? `tcp dport { ${tcp.join(", ")} } counter accept` : "";
    const udpRule = udp.length ? `udp dport { ${udp.join(", ")} } counter accept` : "";
    return `
    # ── Host firewall: default-drop on the public NIC (inet public_guard) ──────────
    # Generated from project_settings.network.firewall (targetState: ${targetState}).
    # Only the public NIC is filtered: the first rule accepts every other interface
    # (VLAN/private, wg0, tailscale0, cilium_*/lxc*, veth*, lo), so the cluster plane
    # is untouched. A public box without nft or a default route must FAIL provisioning —
    # continuing silently would leave it unfiltered on the internet.
    if ! command -v nft >/dev/null 2>&1; then
        echo "ERROR: nft not found — refusing to leave a public node unfiltered" >&2
        exit 1
    fi
    PUB_IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
    if [ -z "$PUB_IFACE" ]; then
        echo "ERROR: no default-route iface — cannot identify the public NIC" >&2
        exit 1
    fi
    # /etc/nftables.conf is what Debian's nftables.service loads at boot — writing it here
    # is what makes the policy survive a reboot.
    # DELIBERATELY no \`flush ruleset\`: Cilium and k3s own their own tables and a reload
    # would wipe them. The add-empty/delete/define triple below is the nftables
    # idiom for atomically replacing ONE table, idempotent at boot and on re-runs.
    cat > /etc/nftables.conf << NFTCONF
#!/usr/sbin/nft -f
# Managed by Pulumi (publicGuardScript, src/nodes-k3s-common.ts) — do not edit.
# Default-drop allow-list for the public NIC ($PUB_IFACE). targetState: ${targetState}.
table inet public_guard {}
delete table inet public_guard
table inet public_guard {
    chain input {
        type filter hook input priority filter; policy drop;
        # Everything that is not the public NIC is the cluster/VPN plane — accept.
        iifname != "$PUB_IFACE" counter accept
        ct state invalid drop
        ct state established,related accept
        # ICMP incl. PMTUD (frag-needed/packet-too-big) and IPv6 NDP — dropping icmpv6
        # would break IPv6 neighbor discovery entirely.
        meta l4proto { icmp, ipv6-icmp } counter accept
        # DHCP client lease renewal (hcloud VMs configure the public NIC via DHCP).
        udp sport 67 udp dport 68 accept
        ${tcpRule}
        ${udpRule}
        counter comment "dropped-public"
    }
}
# Anti tunnel-recursion: tailscaled advertises the pod-overlay addresses as WG endpoint
# candidates; peers that pick them push WireGuard INTO the pod overlay that itself rides on
# tailscale0 → recursive encapsulation flood (see src/provisioning-scripts/10-install-prereqs.sh
# for the full story — mesh nodes get the same table via a standalone unit). The port is
# tailscaled --port, interpolated below from project_settings.network.tailscalePort — the
# same single source the other two copies now read through their anchored TS_PORT=
# assignment. (No backticks in this note: it lives inside a TS template literal, where a
# backtick would close the string.) Inner/overlay traffic never uses it.
#
# THE INTERFACE SET comes from project_settings.network.cni.overlayInterfaces — the same
# single source the other two copies read through an anchored assignment. It is DELIBERATELY
# A SUPERSET, and these rules fail OPEN and SILENTLY: nft
# matches iifname by string, so a name that does not exist simply never matches, the ruleset
# still loads clean, and the flood returns with no alert (500+ GB/node in hours, 15-20%
# loss, tailscaled at 150% CPU). Listing a device that does not exist costs nothing, which
# is what lets these rules load before the CNI creates its devices:
#   cilium_vxlan  - the VXLAN tunnel device
#   cilium_host   - the cilium host-side device carrying the node's pod-CIDR router address
#   cilium_net    - its veth peer
#   lxc*          - per-pod veth interfaces (per-pod suffix, hence the wildcard)
table inet mesh_antiloop {}
delete table inet mesh_antiloop
table inet mesh_antiloop {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname ${nftOverlayIfaceSet()} udp sport ${project_settings.network.tailscalePort} counter drop
        iifname ${nftOverlayIfaceSet()} udp dport ${project_settings.network.tailscalePort} counter drop
    }
    chain output {
        type filter hook output priority filter; policy accept;
        oifname ${nftOverlayIfaceSet()} udp sport ${project_settings.network.tailscalePort} counter drop
        oifname ${nftOverlayIfaceSet()} udp dport ${project_settings.network.tailscalePort} counter drop
    }
}
NFTCONF
    nft -f /etc/nftables.conf
    # Load at every boot, before k3s starts.
    systemctl enable nftables.service 2>/dev/null || true
    # Drop a leftover rpcbind-only table if one is still present — the default-drop policy
    # already covers port 111.
    nft delete table inet rpcbind_guard 2>/dev/null || true
    echo "public_guard active on $PUB_IFACE (tcp: ${tcp.join(",") || "-"} udp: ${udp.join(",") || "-"})" >&2
`;
}

// Remove the publicGuardScript() output from a rendered userData blob, for EVERY target
// state. Used to build a guard-NORMALIZED trigger for the robot Phase-2 provision command:
// the guard fragment is targetState-dependent, so triggering Phase-2 on the raw userData would
// re-run the whole k3s-setup over SSH on every posture flip. Robot nodes instead re-apply the
// guard at runtime via a dedicated firewall command (robot-firewall-<id>), so Phase-2 must
// ignore guard-only deltas. Stripping every state's rendering makes the normalized string
// identical regardless of which state rendered the userData.
//
// ⚠ EVERY state, not just the two distinct PORT sets: the guard embeds its targetState in a
// generated comment, so "restore" and "destroy" render differently from "bootstrap" even
// though all three open the same ports. Iterating TARGET_STATES is what keeps this exhaustive
// when a state is added.
// Idempotent no-op if no guard is present (hcloud/mesh callers don't need it).
export function stripPublicGuard(userData: string): string {
    let out = userData;
    for (const state of TARGET_STATES) {
        out = out.split(publicGuardScript(state)).join("");
    }
    return out;
}

// Shared bash snippet: private network route setup + exports PRIVATE_IP.
// NOTE: this is the Hetzner-Cloud (DHCP) variant — it detects the private iface by a
// 10.0.x address and writes a DHCP systemd-networkd config. Robot/vSwitch nodes need a
// static-VLAN variant (see HetznerDedicatedProvisioner). Kept here because the cloud-VM
// path is the common case and the SNAT/forwarding tail is provider-agnostic.
// The public_guard fragment is baked into the VM's cloud-init userData, so on an EXISTING
// hcloud VM a later targetState flip does not re-render it (userData has ignoreChanges) —
// there the hcloud Cloud firewall, which does update, is the enforcing layer.
export const privateNetworkSetupScript = `
    ufw disable || true
${publicGuardScript()}
    PRIVATE_IFACE=""
    for i in $(seq 1 30); do
        PRIVATE_IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\\.0\\./ {print $2; exit}')
        [ -n "$PRIVATE_IFACE" ] && break
        sleep 1
    done
    if [ -n "$PRIVATE_IFACE" ]; then
        PRIVATE_IP=$(ip -o -4 addr show dev "$PRIVATE_IFACE" | awk '{split($4,a,"/"); print a[1]}')
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-hcloud-private-route.network << ROUTECONF
[Match]
Name=\${PRIVATE_IFACE}

[Network]
DHCP=yes

[Route]
Destination=${project_settings.network.privateRange}
Gateway=${project_settings.network.gateway}
ROUTECONF
        ip route add ${project_settings.network.privateRange} via ${project_settings.network.gateway} dev "\${PRIVATE_IFACE}" onlink || true
        # Persist IP forwarding for WireGuard
        cat > /etc/sysctl.d/99-wireguard.conf << SYSCTLWG
net.ipv4.ip_forward = 1
SYSCTLWG
        sysctl --system || true

        # ── Mesh → private-network gateway (mesh API HA) ──────────────────────────
        # Mesh nodes live in the tailscale mesh (${project_settings.network.meshRange}); the k3s
        # apiserver is advertised on the private network (${project_settings.network.subnetRange}, the CP
        # advertise-address). The k3s agent load-balancer learns ALL control-plane
        # endpoints (private IPs) from the kubernetes EndpointSlice + etcd and fails
        # over across them — but only if the mesh can actually REACH those private IPs.
        # SNAT mesh→private traffic out the private iface so every CP acts as a
        # mesh↔private gateway: mesh reaches any live CP's apiserver, so killing cp0
        # transparently fails over to cp1/cp2. mesh-gateway already advertises
        # ${project_settings.network.subnetRange} into the mesh; this is the missing forwarding leg.
        # Source-IP is rewritten to the CP. Irrelevant for the apiserver (auth is
        # token/cert, not source-IP) and for pod traffic (which rides the CNI's VXLAN,
        # not node IPs). NB: NetworkPolicy IS enforced under Cilium — but this rule
        # only rewrites NODE-plane source addresses, which no pod policy selects on.
        # In non-HA (single cp0) this is a harmless no-op path used by the mesh.
        iptables -t nat -C POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "\${PRIVATE_IFACE}" -j MASQUERADE 2>/dev/null \\
          || iptables -t nat -A POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "\${PRIVATE_IFACE}" -j MASQUERADE
        # Persist across reboots (iptables rules are not durable by default).
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/mesh-private-snat.service << 'SNATSVC'
[Unit]
Description=SNAT tailscale mesh -> Hetzner private network (mesh API HA gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'IFACE=$(ip -o -4 addr show | awk "\\$4 ~ /^10\\.0\\./ {print \\$2; exit}"); [ -n "$IFACE" ] && (iptables -t nat -C POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$IFACE" -j MASQUERADE)'

[Install]
WantedBy=multi-user.target
SNATSVC
        systemctl daemon-reload || true
        systemctl enable mesh-private-snat.service || true
    else
        echo "WARNING: private network interface not found" >&2
        PRIVATE_IP=""
    fi
`;

// etcd S3 snapshot bucket (single source of truth for the backup blocks below).
export const etcdBucket = project_settings.storage.objectStorage.buckets.find(
    (b) => b.key === "etcd",
)!;

// k3s config.yaml block enabling scheduled etcd→S3 snapshots (cp0 only).
export const etcdS3ConfigBlock =
    project_settings.general.backupToS3IntervalHour > 0
        ? pulumi.interpolate`etcd-s3: true
etcd-s3-folder: k3s-etcd
# Take etcd snapshots every N hours (config: general.backupToS3IntervalHour).
etcd-snapshot-schedule-cron: "0 */${project_settings.general.backupToS3IntervalHour} * * *"
etcd-snapshot-retention: 72`
        : pulumi.output("# etcd-s3 backup disabled (backupToS3IntervalHour=0)");

export const etcdS3SecretsBlock =
    project_settings.general.backupToS3IntervalHour > 0
        ? pulumi.interpolate`etcd-s3-endpoint: ${project_settings.storage.objectStorage.baseEndpoint}
etcd-s3-bucket: ${etcdBucket.name}
etcd-s3-access-key: ${project_settings.storage.objectStorage.accessKey}
etcd-s3-secret-key: ${project_settings.storage.objectStorage.secretKey}`
        : pulumi.output("");

export const s3ConnectivityCheck =
    project_settings.general.backupToS3IntervalHour > 0
        ? pulumi.interpolate`S3_HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${etcdBucket.name}.${project_settings.storage.objectStorage.baseEndpoint}/")
if [ "$S3_HTTP" = "000" ]; then
    echo "ERROR: S3 bucket unreachable (HTTP $S3_HTTP)" >&2; exit 1
fi`
        : pulumi.output("# S3 connectivity check skipped (backup disabled)");

// Longhorn disk config builder for Hetzner-hosted (cloud/robot) nodes — they always back
// the "cloud" storage scope. The disk tag drives replica isolation via the StorageClass
// diskSelector (see src/storage.ts): cloud apps never replicate onto mesh-node disks across
// the WAN, and vice-versa. (Mesh nodes carry their own per-scope tags from node.storageScope;
// see src/nodes-k3s-mesh.ts.)
// Encoded in TypeScript so it can be safely embedded in SSH commands and
// k3s config.yaml node-annotation values without heredoc/quoting issues.
// storageReserved=0 lets Longhorn schedule against (almost) the whole disk;
// the global "Storage Minimal Available Percentage" setting (default 25%) still
// keeps a safety margin per disk. A flat 80GiB reserve here starved smaller
// worker disks (e.g. CPX32 ~118GiB usable → DiskPressure, replicas unscheduled,
// volumes faulted), so reserve a *percentage* of the disk instead of a constant.
export const longhornDiskCfgFor = (tag: "cloud") =>
    JSON.stringify([
        {
            path: "/var/lib/longhorn",
            allowScheduling: true,
            storageReserved: 0,
            tags: [tag],
        },
    ]);

// A node's free-text `description` (project_settings) is surfaced as the node annotation
// `ecc/description`. Annotations (not labels) because the value is free-form with spaces.
// View it via `kubectl describe node <n>` or
// `kubectl get node <n> -o jsonpath='{.metadata.annotations.ecc/description}'`
// (the default `kubectl get nodes` table does not render annotations).
//
// Returns a `kubectl annotate …` command fragment, or "" when there is no description.
// `kubectlPrefix` lets callers pick the binary in scope ("kubectl --kubeconfig=…" on the
// orchestrator vs "k3s kubectl" when run on cp0 itself). The value is single-quoted and
// any embedded single quotes are escaped ('\''…'\''), so arbitrary text is shell-safe.
export const descriptionAnnotateCmd = (
    nodeName: string,
    description: string | undefined,
    kubectlPrefix: string,
): string => {
    if (!description) return "";
    const safe = description.replace(/'/g, `'\\''`);
    return `${kubectlPrefix} annotate node ${nodeName} 'ecc/description=${safe}' --overwrite >/dev/null 2>&1 || true`;
};
