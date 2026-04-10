import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import type { ClusterOS, ROLLOUT_TYPE } from "./types";

export interface NetworkArgs {
    cluster: {
        name: string;
        os: ClusterOS;
        rolloutType: ROLLOUT_TYPE;
    };
    network: {
        privateRange: string;
        subnetRange: string;
    };
    hProvider: hcloud.Provider;
}

export class NetworkComponent extends pulumi.ComponentResource {
    public readonly network: hcloud.Network;
    public readonly subnet: hcloud.NetworkSubnet;
    public readonly firewall: hcloud.Firewall;

    constructor(name: string, args: NetworkArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:Network", name, {}, opts);

        const { cluster, network, hProvider } = args;
        const { name: clusterName, os: clusterOS, rolloutType } = cluster;
        const { privateRange: privateNetworkRange, subnetRange: privateSubnetRange } = network;
        const permissiveFirewall = rolloutType !== "Production";

        this.network = new hcloud.Network(
            `${clusterName}-net`,
            {
                name: "private-network",
                ipRange: privateNetworkRange,
                labels: { cluster: clusterName },
            },
            { provider: hProvider, parent: this },
        );

        this.subnet = new hcloud.NetworkSubnet(
            `${clusterName}-subnet`,
            {
                networkId: this.network.id.apply((id) => Number(id)),
                type: "server",
                networkZone: "eu-central",
                ipRange: privateSubnetRange,
            },
            { provider: hProvider, parent: this },
        );

        // Bootstrap rules: open ports needed during initial cluster setup.
        const bootstrapFirewallRules =
            clusterOS === "Talos"
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
                          sourceIps: [privateNetworkRange],
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
                          sourceIps: [privateNetworkRange],
                      },
                      {
                          direction: "in",
                          protocol: "udp",
                          port: "8472",
                          description: "Flannel VXLAN (pod network overlay between nodes)",
                          sourceIps: ["0.0.0.0/0", "::/0"],
                      },
                  ];

        // Production rules: only HTTP(S) and WireGuard exposed publicly.
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
                port: "51820",
                description: "WireGuard VPN tunnel",
                sourceIps: ["0.0.0.0/0", "::/0"],
            },
        ];

        this.firewall = new hcloud.Firewall(
            `${clusterName}-fw`,
            {
                rules: permissiveFirewall
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
