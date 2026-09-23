/**
 * Project: edgecloudinfra
 * File: nodes-k3s-types.ts
 * Purpose: Provider-neutral types shared across the k3s node-provisioning hierarchy
 *          (Hetzner cloud VMs, Hetzner dedicated/robot, future SECA).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";

// Provider-neutral view of a provisioned cluster node. This is the abstraction
// boundary between node provisioning and the downstream consumers (DNS, ingress,
// argocd) that only need a name + public addresses. `hcloud.Server` is structurally
// assignable to this (it exposes all three as Output<string>), so the Hetzner cloud
// path returns Servers directly; the robot path builds a literal.
export interface ClusterNode {
    name: pulumi.Output<string>;
    ipv4Address: pulumi.Output<string>;
    ipv6Address: pulumi.Output<string>;
    // Whether ipv6Address is a real address (statically known). hcloud VMs always get
    // one (Hetzner-assigned) → true; a robot node only has IPv6 if publicIpv6 is set.
    // DNS uses this to skip AAAA records for nodes with no IPv6 (empty value → API 422).
    // Optional so hcloud.Server stays structurally assignable; treated as true when
    // absent (hcloud servers, the pre-existing behaviour).
    hasIpv6?: boolean;
}
