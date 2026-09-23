/**
 * Project: edgecloudinfra
 * File: cni.ts
 * Purpose: Cilium CNI — the cluster pod network.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import { project_settings, haReplicas } from "../project_settings";

// ─────────────────────────────────────────────────────────────────────────────
// Cilium.
//
// WHY IT IS INSTALLED BY PULUMI AND NOT ONLY BY ARGOCD: nothing can be scheduled until pods
// have a network, and that includes ArgoCD itself. k3s runs with `flannel-backend: none`
// (src/nodes-k3s-common.ts k3sCniServerConfig), so between k3s starting and this chart being
// installed every node is NotReady with no CNI. Pulumi therefore bootstraps it here, and
// deployment/argocd-infra/app-of-apps/wave0-cilium.yaml adopts the SAME release afterwards
// (ServerSideApply) so day-2 upgrades are a git push. The two version pins must be kept in
// sync — each carries a comment pointing at the other.
//
// WHY THE DATAPATH IS VXLAN AND NOT NATIVE ROUTING: native routing would collapse the
// VXLAN-inside-WireGuard MTU stack, but it needs every node to hold a route to every other
// node's PodCIDR. Cilium's only built-in mechanism (autoDirectNodeRoutes) requires all nodes
// on one L2 network, and mesh nodes are reachable only via tailscale0 — a point-to-point L3
// TUN with no ARP/neighbour. Cilium's BGP control plane does NOT solve this: it only
// advertises outward to external routers and explicitly "does not program the datapath".
// Distributing pod routes over the mesh needs static per-peer routes or a separate BGP daemon
// (FRR/kube-router); that is its own plan, deliberately not bundled with the CNI swap.
// ─────────────────────────────────────────────────────────────────────────────

// The address the Cilium agent/operator dial to reach the apiserver before there is a pod
// network. It MUST be an address that exists from the node's first boot: at this point in the
// bootstrap no pod is running, so anything pod-provided is unreachable by construction.
//
// NOT the kube-vip VIP (network.vip): kube-vip is itself a pod, so it cannot be up before the
// CNI it would be serving. Pointing here at the VIP deadlocks the bootstrap — the agent's
// `config` init container spends 60s on "Establishing connection to apiserver", dies with
// "network is unreachable", the operator does the same, and the Helm release times out.
//
// The init CP's vSwitch address is configured on the NIC by the provisioning script itself, so
// it answers on :6443 as soon as k3s is up. Derived from the node marked clusterLink:"init"
// rather than hardcoded so a cluster recreate with a different init box stays correct.
function initCpApiHost(): string {
    const initCp = project_settings.nodes.cloud.find(
        (n) => n.enabled !== false && n.clusterLink === "init",
    );
    if (!initCp?.privateIp) {
        throw new Error(
            "cni: no enabled node with clusterLink:'init' and a privateIp in project_settings.nodes.cloud — " +
                "Cilium needs a node-owned apiserver address to bootstrap against.",
        );
    }
    return initCp.privateIp;
}

export class CniComponent extends pulumi.ComponentResource {
    public readonly ciliumChart: helm.v3.Release;

    constructor(name: string, k8sProvider: k8s.Provider, opts?: pulumi.ComponentResourceOptions) {
        super("ecc:infra:Cni", name, {}, opts);

        this.ciliumChart = new helm.v3.Release(
            "cilium",
            {
                name: "cilium",
                chart: "cilium",
                version: "1.20.2", // renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
                namespace: "kube-system",
                repositoryOpts: { repo: "https://helm.cilium.io" },
                values: {
                    // ── Datapath ────────────────────────────────────────────────────────
                    routingMode: "tunnel",
                    tunnelProtocol: "vxlan",
                    tunnelPort: project_settings.network.cni.tunnelPort,

                    // THE NUMBER THAT MUST NOT BE LOST. Chart default is 0 = auto-detect from
                    // the primary NIC (~1450), which knows nothing about the tailscale path.
                    // Mesh nodes tunnel over tailscale0 (WireGuard MTU 1280) and VXLAN adds
                    // 50B, so an auto-detected MTU silently drops large frames (API watch
                    // streams, kubectl logs, SA-token responses, Longhorn gRPC) while small
                    // ones pass — a mesh node that is Ready with crash-looping pods.
                    // This is the DEVICE MTU, not the pod MTU: Cilium installs a route MTU of
                    // (device - 50) on remote pod CIDRs, so pods actually get 1180. Do NOT
                    // raise this to 1280 — see project_settings.network.cni.mtu.
                    MTU: project_settings.network.cni.mtu,

                    // ── IPAM ────────────────────────────────────────────────────────────
                    // MUST be "kubernetes". The chart defaults to "cluster-pool", which would
                    // have Cilium allocate pod CIDRs from its own 10.0.0.0/8 default — that
                    // overlaps the Hetzner private plane (10.0.0.0/16) AND the mesh range
                    // (10.0.10.0/23), i.e. the pod network would collide with the node
                    // network on a cluster whose overlay runs through it. "kubernetes" makes
                    // Cilium consume the per-node PodCIDRs k3s allocates from cluster-cidr.
                    ipam: { mode: "kubernetes" },
                    k8s: {
                        // Wait for Kubernetes to hand out this node's PodCIDR instead of
                        // starting without one.
                        requireIPv4PodCIDR: true,
                    },

                    // ── kube-proxy: REPLACED ────────────────────────────────────────────
                    // Cilium's eBPF datapath owns Service forwarding. MUST stay paired with
                    // `disable-kube-proxy: true` in k3sCniServerConfig (src/nodes-k3s-common.ts):
                    // k3s runs kube-proxy IN-PROCESS, so without that flag both would program
                    // Services at once.
                    //
                    // The sensitive consumer is headscale's DERP/STUN NodePort (30478,
                    // externalTrafficPolicy: Local): it needs the client source IP preserved so
                    // tailscale can hole-punch, and a regression degrades SILENTLY to DERP relay
                    // rather than failing. Healthy looks like: every peer direct — mesh↔mesh on
                    // the LAN (192.168.1.x:41641), mesh↔cloud on the public IP — and same-LAN
                    // pod-to-pod at ~1.6ms. Peers with curAddr empty / relayed, or that latency
                    // jumping to ~12ms, points here.
                    kubeProxyReplacement: true,

                    // ── socket-LB: enabled, but BYPASSED INSIDE POD NAMESPACES ──────
                    // hostNamespaceOnly is the load-bearing half. socket-LB rewrites the
                    // destination at connect()/sendmsg() in the caller's cgroup, which only
                    // works when the calling process shares the host's netns view. gVisor
                    // runs under its own netstack (and a VM-based runtime under its own guest
                    // kernel), so the hook never fires and the ClusterIP passes untranslated —
                    // and with kubeProxyReplacement above there is no kube-proxy iptables
                    // fallback to mask it. Upstream names this case exactly: "due to the
                    // Pod's nature the socket-level loadbalancer is ineffective (e.g.,
                    // KubeVirt, Kata Containers, gVisor)" — see
                    // Documentation/network/kubernetes/kubeproxy-free.rst, which warns to set
                    // hostNamespaceOnly=true whenever kubeProxyReplacement is on. It re-enables service lookup in the tc BPF
                    // program at the veth, which the sandbox's traffic DOES traverse.
                    //
                    // The diagnostic shape when this is wrong: pod networking is entirely fine
                    // and only service VIPs fail — a sandboxed pod reaches external IPs, node
                    // IPs and other pods' IPs, but every ClusterIP (incl. 10.43.0.10:53) times out,
                    // while a runc pod on the SAME node is fine. socketLB.enabled alone does
                    // NOT fix it; hostNamespaceOnly is the load-bearing half.
                    //
                    // It presents as an identity fault, not a network one: no DNS means SSSD
                    // never reaches the Authentik LDAP outpost, so `id testuser` says "no such
                    // user" for a user that EXISTS in AD, while the pods sit Running 2/2 with
                    // zero warning events.
                    //
                    // ⚠ After any change here check every node for duplicate generations:
                    //     bpftool cgroup show /run/cilium/cgroupv2 | grep -c cil_sock
                    // 11 = healthy, 22 = two generations attached `multi` (stale one sends
                    // ClusterIP traffic to a RECYCLED pod IP; only a reboot clears it).
                    // Keep in sync with deployment/argocd-infra/app-of-apps/wave0-cilium.yaml.
                    socketLB: { enabled: true, hostNamespaceOnly: true },

                    // ── Local Redirect Policy ───────────────────────────────────────────
                    // Steers ClusterIP traffic to a node-local backend. Required by the
                    // node-local DNS cache (deployment/argocd-infra/node-local-dns): the
                    // stock upstream nodelocaldns intercepts the DNS VIP with its own
                    // iptables NOTRACK rules, which assumes a kube-proxy data path that
                    // kubeProxyReplacement: true removes. A CiliumLocalRedirectPolicy needs
                    // no kubelet change and no pod restarts.
                    //
                    // kubeProxyReplacement + socketLB.hostNamespaceOnly + this flag is
                    // verbatim Cilium's supported setup #2. LRP works at the tc loadbalancer
                    // as well as the socket one, so the redirect still reaches the
                    // gVisor/Kata pods hostNamespaceOnly exists for.
                    //
                    // ⚠ NOT the flat `localRedirectPolicy` key — deprecated upstream in
                    // favour of this one. Keep in sync with wave0-cilium.yaml.
                    localRedirectPolicies: { enabled: true },

                    // ── Policy: ENFORCING (default-allow) ───────────────────────────────
                    // "default" enforces, but DEFAULT-ALLOW: an endpoint is unrestricted until
                    // some policy selects it. This value is what makes Kubernetes NetworkPolicy
                    // and CiliumNetworkPolicy real, and it is what bounds the Hermes agent's
                    // egress.
                    //
                    // ⚠ Do NOT go back to "never" to debug one namespace: "never" disables
                    // CiliumNetworkPolicy too (upstream docs: "even if rules do select specific
                    // endpoints"), so it is all-or-nothing, cluster-wide.
                    policyEnforcementMode: "default",

                    // ── Envoy: SOCKET COLLISION AVOIDANCE ───────────────────────────────
                    // Cilium ships Envoy as a standalone DaemonSet, and Envoy Gateway
                    // (src/ingress.ts) runs its own Envoy. BOTH use hostNetwork, so they share
                    // one abstract-socket namespace, and both default to --base-id 0 → both
                    // derive @envoy_domain_socket_parent_0. The loser dies with "unable to bind
                    // domain socket with base_id=0, errno=98", which stalls the wave-1 barrier
                    // and leaves the app waves undeployed. Distinct base IDs keep them
                    // coexisting. Keep in sync with wave0-cilium.yaml.
                    envoy: {
                        baseID: 42,
                    },

                    // Leader-elected, and off the datapath: forwarding continues without it,
                    // but IPAM and CiliumIdentity GC stop, so no NEW pod gets an IP. The count
                    // follows highAvailability (min 1 / max 2) rather than being pinned here —
                    // the chart's default of 2 cannot schedule on a single-CP cluster, where
                    // the surplus pod sits Pending on host ports and reports the app Degraded,
                    // stalling the wave-1 barrier.
                    operator: {
                        replicas: haReplicas("ciliumOperator"),
                        prometheus: { enabled: true, metricsService: true },
                    },

                    // ── Observability ───────────────────────────────────────────────────
                    // Hubble is how policy drops are read (`hubble observe --verdict DROPPED`,
                    // which needs `relay`). The UI is deliberately NOT routed — no HTTPRoute,
                    // no Ingress; it is a ClusterIP reached by
                    //   kubectl -n kube-system port-forward svc/hubble-ui 12000:80
                    // Publishing a live flow view of the whole cluster behind the shared
                    // wildcard is not worth the surface, and the CLI covers the drop-hunting
                    // case. Keep `ui` on while tightening NetworkPolicy (plans/policy-enforcement.md)
                    // — the flow graph is what makes a default-deny rollout tractable.
                    hubble: {
                        enabled: true,
                        relay: { enabled: true },
                        ui: { enabled: true },
                        // Flow metrics are where policy DROPS become a number to alert on;
                        // `hubble observe --verdict DROPPED` only shows them to someone
                        // already looking. dns is query-only and ignores AAAA: the full form
                        // and httpV2 carry per-request label sets and are the ones that hurt
                        // cardinality, and httpV2 also needs L7 visibility policies to see
                        // anything at all.
                        metrics: {
                            enabled: ["drop", "tcp", "flow", "icmp", "dns:query;ignoreAAAA"],
                        },
                        // Recent flows cached per agent for `hubble observe` / the UI to read
                        // back — 4x the chart default of 4095. Measured 2026-09-03: ~500
                        // flows/s cluster-wide, so the default held about 8 SECONDS of history
                        // and anything not read inside that window was gone before anyone
                        // could look. 16383 buys ~30s for a few MB per agent; raise it
                        // (2^n-1, max 65535) if drop-hunting keeps arriving too late.
                        // ⚠ Not a fix for hubble_lost_events_total{source=
                        // "hubble_ring_buffer"}, which climbs at every capacity because a
                        // bounded ring that wraps evicts unread flows by definition. The
                        // other two sources are the real fault signal.
                        eventBufferCapacity: "16383",
                    },

                    // ⚠ metricsService, NOT serviceMonitor. The chart creates the
                    // cilium-agent / cilium-operator metrics Services only when
                    // serviceMonitor.enabled or metricsService is set, and its
                    // ServiceMonitors require the Prometheus operator CRDs — absent at
                    // wave 0, since kube-prometheus-stack is wave 2 and this release is the
                    // CNI everything else waits for. So the chart publishes the Services
                    // and the ServiceMonitors live with Prometheus, as
                    // additionalServiceMonitors in its values. cilium-envoy needs nothing
                    // here: envoy.prometheus.enabled defaults true and Envoy runs as the
                    // standalone DaemonSet.
                    // Keep in sync with deployment/argocd-infra/app-of-apps/wave0-cilium.yaml.
                    prometheus: { enabled: true, metricsService: true },

                    // ── API reachability ────────────────────────────────────────────────
                    // The agent must reach the apiserver BEFORE kube-proxy has programmed the
                    // kubernetes ClusterIP (chicken-and-egg on a fresh node). This is the init
                    // CP's own vSwitch IP — see initCpApiHost() for why it must not be the VIP.
                    k8sServiceHost: initCpApiHost(),
                    k8sServicePort: project_settings.network.k3sApiPort,

                    // NB: tolerations are NOT overridden. The chart already defaults the agent
                    // to `- operator: Exists`, which is exactly what mesh nodes need against
                    // ecc/mesh=true:NoSchedule. Narrowing it would leave mesh nodes without an
                    // agent, hence permanently NotReady.
                },
                // The CNI is the precondition for every other pod in the cluster; a partial
                // rollout is worse than a failed one.
                waitForJobs: true,
            },
            { provider: k8sProvider, parent: this },
        );
    }
}
