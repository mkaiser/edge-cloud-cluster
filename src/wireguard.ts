import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import { project_settings as projectSettingsConfig } from "../project_settings";

// Pure WireGuard server — no web UI. Admin peer pre-configured from Pulumi secrets.
// DNS is covered by the wildcard record (*.infra<N>.<zone>).
export class WireguardComponent extends pulumi.ComponentResource {
    public readonly url: string;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        project_settings: typeof projectSettingsConfig,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:Wireguard", name, {}, opts);
        this.url = `${project_settings.wireguard.subDomain}.${project_settings.dns.tld}`;

        const wgNs = new k8s.core.v1.Namespace(
            "wireguard-ns",
            {
                metadata: { name: "wireguard-infra" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        // wg0.conf mounted into the container — server private key + admin peer public key pre-configured.
        // Stored in Pulumi secrets so the server identity survives cluster recreation.
        const wgConfigSecret = new k8s.core.v1.Secret(
            "wireguard-config",
            {
                metadata: { name: "wireguard-config", namespace: "wireguard-infra" },
                stringData: {
                    "wg0.conf": pulumi.interpolate`[Interface]
Address = ${project_settings.wireguard.serverAddr}
ListenPort = 51820
PrivateKey = ${project_settings.wireguard.wgServerPrivateKey}
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# admin
PublicKey = ${project_settings.wireguard.wgAdminPublicKey}
AllowedIPs = ${project_settings.wireguard.adminAddr}
`,
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
                                    securityContext: {
                                        capabilities: { add: ["NET_ADMIN", "SYS_MODULE"] },
                                        privileged: false,
                                    },
                                    env: [{ name: "LOG_CONFS", value: "false" }],
                                    ports: [
                                        { containerPort: 51820, protocol: "UDP", hostPort: 51820 },
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
                                    // Prometheus exporter for WireGuard peer statistics.
                                    // Reads wg0.conf to annotate peers with names; requires NET_ADMIN to call `wg show`.
                                    // https://github.com/MindFlavor/prometheus_wireguard_exporter
                                    name: "wg-exporter",
                                    image: "mindflavor/prometheus-wireguard-exporter:3.6.6",
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
                                    name: "host-modules",
                                    hostPath: { path: "/lib/modules", type: "Directory" },
                                },
                            ],
                        },
                    },
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [wgNs, wgConfigSecret] },
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

        // ServiceMonitor is declared in deployment/kube-prometheus-stack/prometheus.yaml
        // via additionalServiceMonitors — CRDs don't exist at Pulumi time.

        this.registerOutputs({ url: this.url });
    }
}
