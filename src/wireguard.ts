/**
 * Project: edgecloudinfra
 * File: wireguard.ts
 * Purpose: Wireguard VPN configuration component.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import { project_settings as projectSettingsConfig } from "../project_settings";

// Pure WireGuard server — no web UI. Admin peer pre-configured from Pulumi secrets.
//
// wg.<tld> is NOT served by the wildcard record (src/dns.ts): that rrset lists EVERY
// control-plane public IP, which fits the DaemonSet-backed ingress but not this
// single-replica service. A dedicated headless Service + external-dns publishes it
// instead — see the DNS section at the bottom of this file.
export class WireguardComponent extends pulumi.ComponentResource {
    public readonly url: string;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        project_settings: typeof projectSettingsConfig,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("ecc:infra:Wireguard", name, {}, opts);
        this.url = `${project_settings.wireguard.subDomain}.${project_settings.general.tld}`;

        const wgNs = new k8s.core.v1.Namespace(
            "wireguard-ns",
            {
                metadata: { name: "wireguard-infra" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        const wgServerIp = project_settings.wireguard.serverAddr.split("/")[0]; // "10.0.2.1"

        // CoreDNS answers *.<tld> with wgServerIp so split-tunnel VPN clients reach cluster
        // services by hostname without needing the server's public IP.
        const corednsConfigMap = new k8s.core.v1.ConfigMap(
            "wireguard-coredns",
            {
                metadata: { name: "wireguard-coredns", namespace: "wireguard-infra" },
                data: {
                    Corefile: `.:53 {
    bind ${wgServerIp}
    template IN A ${project_settings.general.tld} {
        answer "{{ .Name }} 60 IN A ${wgServerIp}"
    }
    forward . 8.8.8.8 1.1.1.1
    cache 30
    errors
}
`,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [wgNs] },
        );

        // wg0.conf mounted into the container — server private key + one [Peer] per admin.
        // Stored in Pulumi secrets so the server identity survives cluster recreation.
        //
        // ⚠ EVERY ADMIN NEEDS ITS OWN KEYPAIR AND ITS OWN /32. WireGuard keeps a single
        // endpoint per peer, so two clients presenting the same key overwrite each other's
        // endpoint on every handshake and the server sends each one's replies to the other.
        // See the `admins` comment in project_settings.ts for the measured symptoms.
        const adminPeers = pulumi
            .all(project_settings.wireguard.admins.map((a) => pulumi.all([a.publicKey, a.addr])))
            .apply((pairs) =>
                pairs
                    .map(
                        ([publicKey, addr], i) =>
                            `[Peer]\n# ${project_settings.wireguard.admins[i].name}\nPublicKey = ${publicKey}\nAllowedIPs = ${addr}\n`,
                    )
                    .join("\n"),
            );

        const wgConfigSecret = new k8s.core.v1.Secret(
            "wireguard-config",
            {
                metadata: { name: "wireguard-config", namespace: "wireguard-infra" },
                stringData: {
                    "wg0.conf": pulumi.interpolate`[Interface]
Address = ${project_settings.wireguard.serverAddr}
ListenPort = ${project_settings.network.wireguardPort}
PrivateKey = ${project_settings.wireguard.wgServerPrivateKey}
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

${adminPeers}`,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [wgNs] },
        );

        const wgDeployment = new k8s.apps.v1.Deployment(
            "wireguard",
            {
                metadata: { name: "wireguard", namespace: "wireguard-infra" },
                spec: {
                    replicas: 1,
                    strategy: { type: "Recreate" },
                    selector: { matchLabels: { app: "wireguard" } },
                    template: {
                        metadata: { labels: { app: "wireguard" } },
                        spec: {
                            hostNetwork: true,
                            nodeSelector: { "node-role.kubernetes.io/control-plane": "true" },
                            tolerations: [
                                {
                                    key: "node-role.kubernetes.io/control-plane",
                                    operator: "Exists",
                                    effect: "NoSchedule",
                                },
                            ],
                            affinity: {
                                podAntiAffinity: {
                                    requiredDuringSchedulingIgnoredDuringExecution: [
                                        {
                                            labelSelector: { matchLabels: { app: "wireguard" } },
                                            topologyKey: "kubernetes.io/hostname",
                                        },
                                    ],
                                },
                            },
                            containers: [
                                {
                                    name: "wireguard",
                                    image: "linuxserver/wireguard:1.0.20250521", // renovate: datasource=docker depName=linuxserver/wireguard
                                    // NET_ADMIN only, and that is deliberate — SYS_MODULE is
                                    // NOT here. It can insert ANY kernel module, i.e. root on
                                    // the node, and this is the one pod that is also the only
                                    // inbound path once the public ports close.
                                    //
                                    // ⚠ THE MODULE IS A HOST CONCERN. sysctlTuningScript
                                    // (nodes-k3s-common.ts) writes
                                    // /etc/modules-load.d/wireguard.conf on every node, so the
                                    // module is present from boot and nothing here has to load
                                    // it. Do NOT add SYS_MODULE back if wg0 fails to come up —
                                    // that hides a missing drop-in on the node instead of
                                    // fixing it. Check `lsmod | grep wireguard` on the host
                                    // first.
                                    //
                                    // Measured 2026-09-03 on edgecloudinfra-dedicated0: a pod
                                    // with NET_ADMIN and no SYS_MODULE runs
                                    // `ip link add … type wireguard` successfully.
                                    securityContext: {
                                        capabilities: { add: ["NET_ADMIN"] },
                                        privileged: false,
                                    },
                                    env: [{ name: "LOG_CONFS", value: "false" }],
                                    ports: [
                                        {
                                            containerPort: project_settings.network.wireguardPort,
                                            protocol: "UDP",
                                            hostPort: project_settings.network.wireguardPort,
                                        },
                                    ],
                                    volumeMounts: [
                                        {
                                            name: "wg-config",
                                            mountPath: "/etc/wireguard/wg0.conf",
                                            subPath: "wg0.conf",
                                            readOnly: true,
                                        },
                                        {
                                            name: "host-modules",
                                            mountPath: "/lib/modules",
                                            readOnly: true,
                                        },
                                    ],
                                    resources: {
                                        requests: { cpu: "10m", memory: "32Mi" },
                                        limits: { cpu: "100m", memory: "64Mi" },
                                    },
                                    readinessProbe: {
                                        exec: { command: ["wg", "show", "wg0"] },
                                        initialDelaySeconds: 5,
                                        periodSeconds: 10,
                                    },
                                },
                                {
                                    // CoreDNS: resolves cluster hostnames to wgServerIp for split-tunnel VPN clients.
                                    name: "coredns",
                                    image: "docker.io/coredns/coredns:1.12.1", // renovate: datasource=docker depName=coredns/coredns
                                    args: ["-conf", "/etc/coredns/Corefile"],
                                    securityContext: {
                                        capabilities: { add: ["NET_BIND_SERVICE"] },
                                    },
                                    ports: [
                                        { name: "dns-udp", containerPort: 53, protocol: "UDP" },
                                    ],
                                    volumeMounts: [
                                        {
                                            name: "coredns-config",
                                            mountPath: "/etc/coredns",
                                        },
                                    ],
                                    resources: {
                                        requests: { cpu: "5m", memory: "32Mi" },
                                        limits: { cpu: "50m", memory: "64Mi" },
                                    },
                                },
                                {
                                    // Prometheus exporter for WireGuard peer statistics.
                                    // Reads wg0.conf to annotate peers with names; requires NET_ADMIN to call `wg show`.
                                    // https://github.com/MindFlavor/prometheus_wireguard_exporter
                                    name: "wg-exporter",
                                    image: "mindflavor/prometheus-wireguard-exporter:3.6.6", // renovate: datasource=docker depName=mindflavor/prometheus-wireguard-exporter
                                    args: [
                                        "--prepend_sudo=false",
                                        "--extract_names_config_files=/etc/wireguard/wg0.conf",
                                    ],
                                    ports: [
                                        { name: "metrics", containerPort: 9586, protocol: "TCP" },
                                    ],
                                    securityContext: {
                                        capabilities: { add: ["NET_ADMIN"] },
                                        privileged: false,
                                    },
                                    volumeMounts: [
                                        {
                                            name: "wg-config",
                                            mountPath: "/etc/wireguard/wg0.conf",
                                            subPath: "wg0.conf",
                                            readOnly: true,
                                        },
                                    ],
                                    resources: {
                                        requests: { cpu: "5m", memory: "16Mi" },
                                        limits: { cpu: "50m", memory: "32Mi" },
                                    },
                                },
                            ],
                            volumes: [
                                { name: "wg-config", secret: { secretName: "wireguard-config" } },
                                {
                                    name: "coredns-config",
                                    configMap: { name: "wireguard-coredns" },
                                },
                                {
                                    name: "host-modules",
                                    hostPath: { path: "/lib/modules", type: "Directory" },
                                },
                            ],
                        },
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [wgNs, wgConfigSecret, corednsConfigMap],
            },
        );

        // ClusterIP Service exposes the exporter port so Prometheus can scrape it.
        // hostNetwork pods don't get a ClusterIP automatically, so we need an explicit Service.
        new k8s.core.v1.Service(
            "wireguard-metrics-svc",
            {
                metadata: {
                    name: "wireguard-metrics",
                    namespace: "wireguard-infra",
                    labels: { app: "wireguard" },
                },
                spec: {
                    selector: { app: "wireguard" },
                    ports: [{ name: "metrics", port: 9586, targetPort: 9586, protocol: "TCP" }],
                    type: "ClusterIP",
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [wgNs, wgDeployment] },
        );

        // ── Public DNS for the admin endpoint: wg.<tld> → the node ACTUALLY running the pod ──
        //
        // The WG server is a single replica the scheduler may place on ANY control-plane node,
        // and only that node binds UDP wireguardPort (hostNetwork + hostPort). Resolving
        // wg.<tld> to a CP without the pod is a silent UDP black hole, so the name needs a
        // record specific to the current node rather than the wildcard's list of all CPs.
        //
        // Headless (clusterIP: None) + endpoints-type=NodeExternalIP makes external-dns resolve
        // each READY backing pod's node ExternalIP (external-dns source/service.go:
        // extractHeadlessEndpoints) and rewrite the record when the pod moves — no static IP to
        // go stale, no `pulumi up` to re-point it.
        //
        // NOT type: LoadBalancer. k3s ServiceLB schedules a klipper-lb DaemonSet declaring
        // HostPort == the service port on every eligible node (k3s
        // pkg/cloudprovider/servicelb.go); on the node already holding wireguardPort via
        // hostPort that pod cannot schedule. Headless sidesteps klipper and leaves the
        // hostNetwork datapath untouched.
        //
        // The port here is descriptive only — the datapath is the hostPort on the node, not
        // this Service. The selector is what external-dns needs to find the backing pod.
        new k8s.core.v1.Service(
            "wireguard-dns-svc",
            {
                metadata: {
                    name: "wireguard-dns",
                    namespace: "wireguard-infra",
                    labels: { app: "wireguard" },
                    annotations: {
                        "external-dns.alpha.kubernetes.io/hostname": this.url,
                        "external-dns.alpha.kubernetes.io/endpoints-type": "NodeExternalIP",
                    },
                },
                spec: {
                    selector: { app: "wireguard" },
                    clusterIP: "None",
                    ports: [
                        {
                            name: "wireguard",
                            port: project_settings.network.wireguardPort,
                            targetPort: project_settings.network.wireguardPort,
                            protocol: "UDP",
                        },
                    ],
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [wgNs, wgDeployment] },
        );

        // ServiceMonitor "wireguard" is declared in
        // deployment/argocd-infra/prometheus/kube-prometheus-stack/prometheus.yaml via
        // additionalServiceMonitors (it selects app: wireguard here) — the CRD
        // doesn't exist at Pulumi time, so it can't live in this component.

        this.registerOutputs({ url: this.url });
    }
}
