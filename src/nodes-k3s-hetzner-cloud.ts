/**
 * Project: edgecloudinfra
 * File: nodes-k3s-hetzner-cloud.ts
 * Purpose: Hetzner Cloud (hcloud) provisioner for k3s nodes. Machines are hcloud.Server
 *          resources configured via cloud-init userData; the cluster bring-up flow lives in
 *          AbstractK3sNodes (nodes-k3s-base.ts), and the per-provider dispatch entry point
 *          (K3sNodesComponent) lives in nodes-k3s-dispatch.ts.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import { project_settings } from "../project_settings";
import type { ComputeNodeCloud, ComputeNodeCloudVm } from "../project_settings_types";
import type { NetworkComponent } from "./network";
import { privateNetworkSetupScript, peerCpIpScript } from "./nodes-k3s-common";
import type { ProviderProvisioner, ProvisionResult } from "./nodes-k3s-base";

// ─────────────────────────────────────────────────────────────────────────────
// Hetzner Cloud provisioner: creates hcloud.Server VMs on the private network,
// configured by cloud-init userData. Peer-CP discovery uses the Hetzner Cloud API.
// ─────────────────────────────────────────────────────────────────────────────
export class HetznerCloudProvisioner implements ProviderProvisioner {
    public readonly provider = "hcloud" as const;

    constructor(
        private readonly networkComponent: NetworkComponent,
        private readonly hProvider: hcloud.Provider,
    ) {}

    // Both CP and worker are the same hcloud.Server shape; only dependsOn differs,
    // which the base flow supplies. `node` is narrowed to the hcloud VM variant.
    private createServer(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        const node = args.node as ComputeNodeCloudVm;
        const { network, firewall } = this.networkComponent;
        // Uniform naming for ALL cloud nodes (no init-CP special-case): the Pulumi
        // resource suffix is the node id, and the hcloud server name is the k3s node-name
        // (${clusterName}-${id}, passed in as args.nodeName) — so peer-CP discovery by name
        // works for the initial CP too.
        const server = new hcloud.Server(
            `${project_settings.general.name}-server-k3s-${node.id}`,
            {
                name: args.nodeName,
                serverType: node.serverType.toLowerCase(),
                image: node.os,
                location: node.location,
                sshKeys: [node.ssh.key],
                networks: [
                    {
                        networkId: network.id.apply((id) => Number(id)),
                        ip: node.privateIp,
                    },
                ],
                firewallIds: [firewall.id.apply((id) => Number(id))],
                userData: args.userData,
            },
            {
                provider: this.hProvider,
                parent: args.parent,
                dependsOn: args.dependsOn,
                ignoreChanges: ["userData"],
            },
        );
        return {
            node: server,
            privateIp: server.networks.apply((networks) => networks![0].ip),
            resource: server,
        };
    }

    provisionControlPlane(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        return this.createServer(args);
    }

    provisionWorker(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        return this.createServer(args);
    }

    // Resolve the peer control-plane's public IP. Discovery depends on the PEER's provider
    // (not this provisioner): an hcloud peer is found via the Hetzner Cloud API by its
    // node-name; a robot peer uses its configured publicIp. Empty when there is no peer.
    discoverPeerCpIpScript(peer: ComputeNodeCloud | undefined): pulumi.Input<string> {
        return peerCpIpScript(peer);
    }

    // Hetzner Cloud VMs get a DHCP 10.0.x private iface; the common DHCP-detection
    // script handles iface discovery + the mesh→private SNAT gateway.
    privateNetworkSetupScript(_node: ComputeNodeCloud): string {
        return privateNetworkSetupScript;
    }
}
