/**
 * Project: edgecloudinfra
 * File: nodes-k3s-dispatch.ts
 * Purpose: Provider-neutral cluster entry point. K3sNodesComponent is the component used by
 *          main.ts to bring up the k3s cluster; it dispatches each node in
 *          project_settings.nodes.cloud to the matching provisioner by `provider`:
 *          "hcloud" → HetznerCloudProvisioner (nodes-k3s-hetzner-cloud.ts),
 *          "robot"  → HetznerDedicatedProvisioner (nodes-k3s-hetzner-robot.ts).
 *
 *          This wiring layer lives apart from nodes-k3s-base.ts (the abstract flow) so the
 *          base class never imports its concrete provisioners — keeping the dependency
 *          direction one-way (concrete → abstract).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import type { NetworkComponent } from "./network";
import { AbstractK3sNodes } from "./nodes-k3s-base";
import { HetznerCloudProvisioner } from "./nodes-k3s-hetzner-cloud";
import { HetznerDedicatedProvisioner } from "./nodes-k3s-hetzner-robot";
import { MeshNodeInitProvisioner } from "./nodes-k3s-mesh";

// ─────────────────────────────────────────────────────────────────────────────
// Cluster component. Dispatches per node.provider to the right provisioner so a
// mixed hcloud + robot list co-provisions one cluster.
// ─────────────────────────────────────────────────────────────────────────────
export class K3sNodesComponent extends AbstractK3sNodes {
    constructor(
        name: string,
        networkComponent: NetworkComponent,
        hProvider: hcloud.Provider,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        // Provisioners are built here (not on `this`, which isn't available until after
        // super()) and captured by the dispatch closure. super() then runs the whole
        // bring-up flow, calling the closure per node. Dispatch is by node kind:
        //   mesh node (no `provider`, has `ssh`) → MeshNodeInitProvisioner (the init CP, Stage B);
        //   provider:"hcloud" → cloud VM; provider:"robot" → dedicated/robot.
        const cloudProvisioner = new HetznerCloudProvisioner(networkComponent, hProvider);
        const dedicatedProvisioner = new HetznerDedicatedProvisioner(new pulumi.Config());
        const meshProvisioner = new MeshNodeInitProvisioner(new pulumi.Config());
        super(
            "ecc:nodes:K3sNodes",
            name,
            (node) => {
                if (!("provider" in node)) return meshProvisioner; // mesh init CP
                return node.provider === "hcloud" ? cloudProvisioner : dedicatedProvisioner;
            },
            opts,
        );
    }
}
