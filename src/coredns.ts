/**
 * Project: edgecloudinfra
 * File: coredns.ts
 * Purpose: CoreDNS — the cluster's DNS, bootstrapped by Pulumi.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import { project_settings } from "../project_settings";

// ─────────────────────────────────────────────────────────────────────────────
// CoreDNS.
//
// WHY IT IS INSTALLED BY PULUMI AND NOT ONLY BY ARGOCD — the same reason as the CNI, one
// layer up. k3s runs with `disable: coredns` (src/nodes-k3s-common.ts k3sDisableFlags), so
// until this chart is installed the cluster has NO name resolution at all, and ArgoCD cannot
// be the thing that installs it: the repo-server resolves `argocd-repo-server` through
// 10.43.0.10 to serve a manifest, and the coredns chart itself is fetched from
// coredns.github.io. Both need DNS, so an ArgoCD-only CoreDNS deadlocks the bootstrap —
// app-of-apps sits ComparisonError "lookup argocd-repo-server ... i/o timeout", the
// repo-server CrashLoopBackOffs, and nothing downstream (longhorn's admission webhook first)
// can resolve a Service. Measured on the ecc211 bring-up, 2026-09-16.
//
// deployment/argocd-infra/app-of-apps/wave0-coredns.yaml adopts the SAME release afterwards
// (ServerSideApply) so day-2 changes are a git push. The two version pins and the values
// below must be kept in sync — each carries a comment pointing at the other.
// ─────────────────────────────────────────────────────────────────────────────

export class CoreDnsComponent extends pulumi.ComponentResource {
    public readonly corednsChart: helm.v3.Release;

    constructor(name: string, k8sProvider: k8s.Provider, opts?: pulumi.ComponentResourceOptions) {
        super("ecc:infra:CoreDns", name, {}, opts);

        const labels = project_settings.applicationPlacements.labels;

        this.corednsChart = new helm.v3.Release(
            "coredns",
            {
                name: "coredns",
                chart: "coredns",
                version: "1.47.1", // renovate: datasource=helm depName=coredns registryUrl=https://coredns.github.io/helm
                namespace: "kube-system",
                repositoryOpts: { repo: "https://coredns.github.io/helm" },
                values: {
                    // ⚠ The Service name and label MUST stay kube-dns. kubelet writes
                    // /etc/resolv.conf from --cluster-dns and every consumer selects on
                    // k8s-app=kube-dns: the node-local cache's kube-dns-upstream Service, the
                    // CiliumLocalRedirectPolicy that steers DNS to it, and this cluster's
                    // Prometheus scrape config. The chart would otherwise name everything
                    // `coredns`.
                    fullnameOverride: "coredns",
                    k8sAppLabelOverride: "kube-dns",
                    service: {
                        name: "kube-dns",
                        // ⚠ PINNED, not allocated. k3s derives kubelet's --cluster-dns from
                        // serviceCidr (the .10 address) and writes it into every pod's
                        // resolv.conf, so this Service must claim exactly that IP or the whole
                        // cluster resolves against nothing.
                        clusterIP: project_settings.network.cni.clusterDnsIp,
                        clusterIPs: [],
                    },

                    // ── Placement: one replica per site, not one pod on the cloud node ────
                    // The autoscaler owns the replica COUNT (below); these decide WHERE they
                    // land. Tolerating ecc/mesh is the entire point of self-managing this
                    // chart — k3s's fixed manifest has no such toleration, so its single
                    // replica could only ever run on the one untainted cloud node.
                    tolerations: [
                        { key: "CriticalAddonsOnly", operator: "Exists" },
                        {
                            key: "node-role.kubernetes.io/control-plane",
                            operator: "Exists",
                            effect: "NoSchedule",
                        },
                        {
                            key: labels.mesh,
                            operator: "Equal",
                            value: "true",
                            effect: "NoSchedule",
                        },
                    ],
                    // Spread across SITES first, then hosts. ScheduleAnyway on both:
                    // DoNotSchedule is what left k3s's extra replicas Pending, and a DNS pod
                    // that does not run is worse than one sharing a site.
                    topologySpreadConstraints: [
                        {
                            maxSkew: 1,
                            topologyKey: labels.site,
                            whenUnsatisfiable: "ScheduleAnyway",
                            labelSelector: { matchLabels: { "k8s-app": "kube-dns" } },
                        },
                        {
                            maxSkew: 1,
                            topologyKey: "kubernetes.io/hostname",
                            whenUnsatisfiable: "ScheduleAnyway",
                            labelSelector: { matchLabels: { "k8s-app": "kube-dns" } },
                        },
                    ],

                    // ── Replica count follows the fleet ──────────────────────────────────
                    // cluster-proportional-autoscaler is the upstream-standard way to size
                    // CoreDNS. nodesPerReplica 2 with min 2 gives every site local DNS at
                    // today's 7 nodes / 4 sites; preventSinglePointFailure keeps >= 2 whenever
                    // there is more than one node.
                    autoscaler: {
                        enabled: true,
                        coresPerReplica: 256,
                        nodesPerReplica: 2,
                        min: 2,
                        max: 6,
                        preventSinglePointFailure: true,
                    },

                    podDisruptionBudget: { maxUnavailable: 1 },

                    priorityClassName: "system-cluster-critical",

                    rbac: { create: true },

                    // ⚠ `service`, not `monitor`, and the ArgoCD side must match. A
                    // ServiceMonitor is a monitoring.coreos.com/v1 resource, and those CRDs
                    // arrive with kube-prometheus-stack at wave 2 — long after this release and
                    // after the wave-0 app that adopts it. Rendering one at either point fails
                    // on the missing kind. This publishes the coredns-metrics Service only;
                    // deployment/argocd-infra/prometheus/kube-prometheus-stack/prometheus.yaml
                    // adopts it as an additionalServiceMonitor, exactly as it does for cilium.
                    prometheus: { service: { enabled: true } },

                    // ── The `coredns-custom` ConfigMap ───────────────────────────────────
                    // ⚠ LOAD-BEARING, and easy to drop when porting k3s's Corefile: several
                    // apps publish extra DNS config by writing keys into the `coredns-custom`
                    // ConfigMap (samba-ad, gitlab, remote-desktop, truenas). Without the mount
                    // AND both imports below, those keys are silently ignored — the ConfigMap
                    // exists, looks right, and does nothing, while `fs-1.ad.base.internal`
                    // NXDOMAINs from every pod. Measured on ecc211 2026-09-16.
                    //
                    // `optional: true` matches k3s: the ConfigMap is created by whichever app
                    // needs it first, so CoreDNS must start fine before it exists.
                    extraVolumes: [
                        {
                            name: "custom-config-volume",
                            configMap: { name: "coredns-custom", optional: true },
                        },
                    ],
                    extraVolumeMounts: [
                        {
                            name: "custom-config-volume",
                            mountPath: "/etc/coredns/custom",
                            readOnly: true,
                        },
                    ],
                    // `*.server` holds WHOLE server blocks (`ad.base.internal:53 { … }`), so it
                    // must sit OUTSIDE the `.:53` block — which is exactly where the chart puts
                    // `extraConfig`. The in-block `*.override` counterpart is an `import` plugin
                    // in `servers[].plugins` below. Both halves are needed; k3s ships both.
                    extraConfig: {
                        import: { parameters: "/etc/coredns/custom/*.server" },
                    },

                    // ── Corefile ─────────────────────────────────────────────────────────
                    // Carried across from k3s's Corefile. k3s's version reads the file
                    // /etc/coredns/NodeHosts; that FILE is deliberately not carried over,
                    // because k3s populated it from its own node controller
                    // (pkg/server/server.go passes !Skips["coredns"] to node.Register) and
                    // disabling k3s's CoreDNS stops it being maintained — a stale hosts file
                    // is worse than none. Nothing in deployment/ resolves bare node hostnames,
                    // and node addresses are anchored in project_settings.ts.
                    //
                    // ⚠ THE `hosts` PLUGIN ITSELF MUST STAY, even with no file to read. With
                    // no argument it serves the container's own /etc/hosts, and that is the
                    // ONLY thing in the chain that answers `localhost`. Dropping it NXDOMAINs
                    // localhost cluster-wide, which breaks every hostNetwork +
                    // ClusterFirstWithHostNet pod that binds or probes a localhost address:
                    // csi-driver-nfs's node-driver-registrar and liveness-probe both die with
                    //     listen tcp: lookup localhost on 10.43.0.10:53: no such host
                    // and the CSI driver never registers, so NFS PVs cannot mount at all
                    // (`driver name nfs.csi.k8s.io not found in the list of registered CSI
                    // drivers`) even though the PVs are Bound. Measured on ecc211 and ecc212.
                    // `fallthrough` is what lets everything else continue to the kubernetes
                    // plugin; without it this block would answer for names it must not.
                    servers: [
                        {
                            // ⚠ `use_tcp` is what makes the chart publish the TCP service
                            // port. Without it kube-dns has ONLY udp-53, so DNS-over-TCP has
                            // no path at all (any response >512 bytes) AND the
                            // CiliumLocalRedirectPolicy cannot map its frontend, leaving the
                            // node-local cache inert. k3s's Service ships dns/dns-tcp/metrics;
                            // this is the chart's equivalent. Measured on ecc211 2026-09-16.
                            zones: [{ zone: ".", use_tcp: true }],
                            port: 53,
                            plugins: [
                                { name: "errors" },
                                { name: "health", configBlock: "lameduck 10s" },
                                { name: "ready" },
                                {
                                    name: "kubernetes",
                                    parameters: "cluster.local in-addr.arpa ip6.arpa",
                                    configBlock:
                                        "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30",
                                },
                                // Serves the container's own /etc/hosts — the only answer for
                                // `localhost` in the cluster. See the block comment above.
                                // ⚠ The two entries are EXPLICIT on purpose. The plugin does
                                // read the container's own /etc/hosts, but CoreDNS runs from a
                                // distroless image whose /etc/hosts does NOT carry a localhost
                                // line, so relying on it still NXDOMAINs (verified on ecc212:
                                // the plugin loaded cleanly and `localhost.` still failed).
                                {
                                    name: "hosts",
                                    configBlock:
                                        "127.0.0.1 localhost\n::1 localhost\nttl 60\nreload 15s\nfallthrough",
                                },
                                { name: "prometheus", parameters: "0.0.0.0:9153" },
                                { name: "forward", parameters: ". /etc/resolv.conf" },
                                { name: "cache", parameters: 30 },
                                { name: "loop" },
                                { name: "reload" },
                                { name: "loadbalance" },
                                // In-block half of the coredns-custom wiring (see extraConfig
                                // above for the `*.server` half). `*.override` holds plugin
                                // lines that extend THIS server block, so it belongs inside it.
                                {
                                    name: "import",
                                    parameters: "/etc/coredns/custom/*.override",
                                },
                            ],
                        },
                    ],
                },
                // Nothing else can resolve a Service until these pods answer, so the bootstrap
                // waits here rather than racing the first consumer.
                atomic: true,
                timeout: 600,
            },
            { provider: k8sProvider, parent: this },
        );

        this.registerOutputs({ corednsChart: this.corednsChart });
    }
}
