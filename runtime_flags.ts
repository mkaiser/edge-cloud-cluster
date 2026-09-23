/**
 * Project: edgecloudinfra
 * File: runtime_flags.ts
 * Purpose: Per-run flags that steer a `pulumi up`, kept OUT of project_settings.ts.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

/*
These are NOT settings. Every value here comes from the Pulumi STACK CONFIG
(`pulumi config set …`), written by the Makefile targets and scripts/pulumi/*; none of them
is edited by hand, and none is scraped out of this file as text. That is the whole reason
they live here rather than in project_settings.ts, where every line is either a human
decision or a value some perl/sed pass reads back out — so layout there is load-bearing and
layout here is free.

project_settings.ts answers "how is this cluster configured"; this file answers "what is
this particular run doing".
*/

import * as pulumi from "@pulumi/pulumi";

const projectConfig = new pulumi.Config();

export const runtime_flags = {
    // Force a from-scratch OS reinstall of robot (dedicated) boxes: rescue mode +
    // hardware-reset + installimage, wiping all prior-cluster state (stale etcd, k3s,
    // network). Set to a fresh timestamp by `make bootstrap` (fresh) so it fires exactly
    // once per fresh build, and left unchanged across a routine `pulumi up` so a healthy
    // cluster is never re-wiped. Empty = honor the on-box install marker (no reinstall).
    robotForceReinstall: projectConfig.get("robotForceReinstall") ?? "",

    // Ownership latch for the infra ArgoCD Helm release. false = Pulumi bootstraps and owns
    // the `argocd` release; true = `argocd-infra-self` owns it via GitOps and Pulumi must NOT
    // construct the Release (it would `helm install` over a live one).
    //
    // ⚠ This MUST be a durable latch, not a live probe. The handoff is IRREVERSIBLE — Pulumi
    // drops the Release from state while `retainOnDelete` keeps the live release running — so
    // the two directions are not symmetric: guessing "not self-managed" when it IS costs a
    // hard `cannot re-use a name that is still in use` failure, while the latch simply
    // records what already happened. It used to be a construction-time `kubectl` probe of
    // `argocd-infra-self`'s sync status, which was fail-open (any error → bootstrap) and so
    // read the cluster at the WORST possible moment: `make bootstrap --complete` runs three
    // `pulumi up` passes, and pass 3 (mesh provisioning) starts seconds after production
    // hardening rewrites ~/.kube/config and re-pins the API endpoint to the private VIP. One
    // transient there flipped the answer back to false and pass 3 tried to re-install the
    // release pass 2 had just handed over (measured 2026-09-04, ecc197).
    //
    // Set true by scripts/pulumi/argocdOwnershipLatch.sh once the handoff is observed, and
    // reset to false by destroy (no cluster ⇒ no release to own). Same shape as
    // meshProvisioning.vpnReady below: a script decides once, the program only reads.
    argocdSelfManaged: projectConfig.getBoolean("argocdSelfManaged") ?? false,

    meshProvisioning: {
        // Timing gate: mesh nodes are SSH-provisioned only once the VPN/headscale mesh is up
        // — never during `make bootstrap` (the VPN isn't up yet). `make provision-mesh-node`
        // sets this true after a VPN-readiness preflight and LEAVES it true, so a later
        // `make up` keeps MeshNodesComponent instantiated and reconciles the mesh nodes to a
        // no-op via the skip-check instead of deleting them. `make bootstrap` resets it.
        vpnReady: projectConfig.getBoolean("meshVpnReady") ?? false,
        // "all" or a single ComputeNodeMesh id (`make provision-mesh-node ARGS=<id>`).
        // ⚠ Narrowing this DROPS every other mesh node from the program (see the filter in
        // src/nodes-k3s-mesh.ts) — silently, since a node absent from the list produces no
        // message at all. It is therefore reset to "all" by scripts/pulumi/up.sh, the
        // whole-stack apply path; without that reset a `make provision-mesh-node ARGS=<id>`
        // left every later `make up` scoped to that one node.
        filter: projectConfig.get("meshNodeProvisionFilter") ?? "all",
        // Re-provision (detach + k3s re-join + Tailscale re-auth) even when the node is
        // already Ready with a matching fingerprint. Set by `ARGS='<id> --force'`, and reset
        // to false alongside `filter` by up.sh.
        force: projectConfig.getBoolean("meshNodeProvisionForce") ?? false,
        // ⚠ This, not `force`, is what makes a REPEAT force actually re-provision: `force` is
        // a boolean, so two consecutive `ARGS=<id> --force` runs yield the same trigger value
        // and Pulumi reports "N unchanged" while the wrapper claims the node is being
        // re-joined. Stamped per force-run by provisionMeshNodes.sh; empty otherwise, so an
        // ordinary `make up` never re-provisions anything.
        forceNonce: projectConfig.get("meshNodeProvisionForceNonce") ?? "",
        // Ids whose SSH provision Command must NOT be created this run — written by the
        // pre-flight SSH probe in provisionMeshNodes.sh for boxes it found unreachable. The
        // node stays fully INSTANTIATED (skipcheck/fetch/detach/label still run against the
        // reachable CP, so its labels reconcile and nothing leaves state); only the Command
        // that DIALS the box is omitted. Dropping the node from nodes.mesh instead would make
        // Pulumi DELETE its mesh-* resources.
        // Comma-separated, not a Pulumi list: a shell script writes it, and `pulumi config
        // set` writes a scalar (a list needs repeated --path writes).
        skip: (projectConfig.get("meshNodeProvisionSkip") ?? "")
            .split(",")
            .map((s) => s.trim())
            .filter((s) => s.length > 0),
    },
};
