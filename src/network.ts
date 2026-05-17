import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import { project_settings } from "../project_settings";

export class NetworkComponent extends pulumi.ComponentResource {
    public readonly network: hcloud.Network;
    public readonly subnet: hcloud.NetworkSubnet;
    public readonly firewall: hcloud.Firewall;

    constructor(
        name: string,
        hProvider: hcloud.Provider,
        projectSettings: typeof project_settings,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:Network", name, {}, opts);

        this.network = new hcloud.Network(
            `${projectSettings.general.name}-net`,
            {
                name: "private-network",
                ipRange: projectSettings.network.privateRange,
                labels: { cluster: projectSettings.general.name },
            },
            { provider: hProvider, parent: this },
        );

        this.subnet = new hcloud.NetworkSubnet(
            `${projectSettings.general.name}-subnet`,
            {
                networkId: this.network.id.apply((id) => Number(id)),
                type: "server",
                networkZone: "eu-central",
                ipRange: projectSettings.network.subnetRange,
            },
            { provider: hProvider, parent: this },
        );

        // Bootstrap rules: open ports needed during initial cluster setup.
        const bootstrapFirewallRules =
            projectSettings.server.os === "Talos"
                ? [
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "50000",
                          description: "Talos API (apid) for talosctl management",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "6443",
                          description: "Kubernetes API server",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "2380",
                          description: "etcd peer (HA control plane, private network only)",
                          sourceIps: [projectSettings.network.privateRange],
                      },
                      {
                          direction: "in",
                          protocol: "udp",
                          port: "8472",
                          description: "Flannel VXLAN (pod network overlay between nodes)",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                  ]
                : [
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "22",
                          description: "SSH login",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "6443",
                          description: "Kubernetes API server",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                      {
                          direction: "in",
                          protocol: "tcp",
                          port: "2380",
                          description: "etcd peer (HA control plane, private network only)",
                          sourceIps: [projectSettings.network.privateRange],
                      },
                      {
                          direction: "in",
                          protocol: "udp",
                          port: "8472",
                          description: "Flannel VXLAN (pod network overlay between nodes)",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                  ];

        // Production rules: only HTTP(S), Jitsi Meet and WireGuard exposed publicly.
        const productionFirewallRules = [
            {
                direction: "in",
                protocol: "tcp",
                port: "80",
                description: "HTTP (haproxy ingress, redirects to HTTPS)",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "443",
                description: "HTTPS (haproxy ingress TLS)",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
            {
                direction: "in",
                protocol: "udp",
                port: "10000",
                description: "Jitsi Video Bridge ICE port",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "4443",
                description: "Jitsi Video Bridge TCP fallback",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
            {
                direction: "in",
                protocol: "udp",
                port: "51820",
                description: "WireGuard VPN tunnel",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
        ];

        this.firewall = new hcloud.Firewall(
            `${projectSettings.general.name}-fw`,
            {
                rules:
                    projectSettings.general.rolloutType !== "Production"
                        ? [...bootstrapFirewallRules, ...productionFirewallRules]
                        : [...productionFirewallRules],
            },
            { provider: hProvider, parent: this },
        );

        this.registerOutputs({
            network: this.network,
            subnet: this.subnet,
            firewall: this.firewall,
        });
    }
}
