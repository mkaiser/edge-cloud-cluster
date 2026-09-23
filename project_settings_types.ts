/**
 * Project: edgecloudinfra
 * File: project_settings_types.ts
 * Purpose: Shared domain types used across all modules. The actual settings live
 *          in project_settings.ts; only type/interface definitions belong here.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

export type NodeOs = "debian-13" | "ubuntu-24.04";
export type LoadBalancerProvider = "hetzner-ccm" | "k3s-servicelb";
// What this apply drives the cluster toward: firewall posture AND data disposition in one
// value. Written by the make targets (phase_set_target_state in scripts/pulumi/_lifecycle.sh),
// not by hand in normal use.
//
//   "bootstrap"  — bring-up: public SSH 22 + k3s API 6443 open, fresh etcd.
//   "restore"    — same posture, but k3s restores etcd from S3 and Longhorn restores volumes.
//   "production" — 22 and 6443 CLOSED; the admin WireGuard tunnel is the only way in.
//   "shutdown"   — graceful stop: servers, DNS and network go away, but the S3 buckets are
//                  KEPT and the TLS certs are saved back to the stack. `make shutdown` sets
//                  this, then sets "restore" when it finishes — that is the state it leaves.
//   "destroy"    — full teardown: S3 buckets deleted, saved TLS certs cleared, ArgoCD
//                  namespaces force-finalized, mesh SSH Commands skipped.
//
// ⚠ It does NOT select the TLD — that is derived from general.subdomain alone. Deriving the
// TLD from this value would mean a lifecycle transition silently rewrote every manifest's
// domain.
//
// "production" is the ONLY closed posture: bootstrap, restore, shutdown and destroy all keep
// 22/6443 open, because each of them is an operation that needs to reach the cluster and
// ends either with the cluster serving or with the servers deleted.
//
// Declared as a const array with the type derived from it, so anything that must enumerate
// every state (stripPublicGuard in src/nodes-k3s-common.ts) cannot silently miss a new one.
export const TARGET_STATES = ["bootstrap", "restore", "production", "shutdown", "destroy"] as const;
export type TargetState = (typeof TARGET_STATES)[number];
export type CertType = "letsencrypt-prod" | "letsencrypt-staging";

export type LonghornReplicaCount = "auto" | 1 | 2 | 3;

// kubelet memorySwap.swapBehavior (requires node.swap > 0 + fail-swap-on=false):
//   "NoSwap"      — default; pods CANNOT use swap (only non-pod/system processes can,
//                   e.g. k3s/etcd — that already protects the control-plane from OOM).
//   "LimitedSwap" — Burstable pods MAY use swap, capped proportionally to their memory
//                   request. Guaranteed and BestEffort pods still never swap.
//                   (UnlimitedSwap was removed in k8s; not an option.)
export type SwapBehavior = "NoSwap" | "LimitedSwap";

// The Kubernetes role a cluster node joins as.
export type K8sRole = "controlplane" | "worker";

// How a node connects to the cluster control-plane:
//   "init"   — this node runs `cluster-init` on initial bring-up (exactly one across the
//              whole cluster: cloud + mesh). Provider-agnostic; replaces the old
//              initialCpNode flag.
//   "direct" — joins the init CP over a SHARED local network (no VPN). Declared via a common
//              `site` (cloud/robot on the Hetzner private net; on-premise nodes on the same
//              LAN as an on-premise init CP). Direct followers come up in pass 1 and can
//              carry the cluster while the mesh/ArgoCD bring-up completes.
//   "vpn"    — joins the init CP over the headscale/tailscale mesh (tailscale0), in a 2nd pass
//              after the in-cluster headscale is up. Cloud OR mesh.
export type ClusterLink = "init" | "direct" | "vpn";

// Common interface for EVERY node (Hetzner-hosted cluster node + on-premise mesh node).
// Cloud nodes always back the "cloud" storage scope; mesh nodes declare their own
// `storageScope` list (see ComputeNodeMesh).
export interface ComputeNode {
    id: string; // node name + k3s node-name (idiom: "<site>-<role/hw><n>", e.g. "fsn1-cp0")
    k8sRole: K8sRole; // "Kubernetes type": control plane or worker
    // SSH connection descriptor for this node.
    //   endpoint — where ssh connects: a hostname, IPv4, or IPv6. Optional; when omitted
    //     cloud/robot nodes fall back to their public IPv4 (root@publicIp:22, today's behaviour).
    //     Mesh nodes have no public IP, so they REQUIRE it (narrowed in ComputeNodeMesh).
    //   key — Pulumi config key to look up the private key at provisioning time
    //     (projectConfig.getSecret(node.ssh.key)). For Hetzner-hosted nodes this must also
    //     match the key name registered in Hetzner Cloud/Robot.
    //   port/user — SSH port/user overrides; default 22 / "root".
    ssh: {
        endpoint?: string; // hostname | IPv4 | IPv6; omitted → cloud/robot use publicIp
        key: string; // Pulumi config key for the SSH private key
        port?: number; // default 22
        user?: string; // default "root"
    };
    // Temporarily exclude this node from provisioning WITHOUT deleting its block.
    // Default (omitted) = true. What `false` MEANS differs by node kind, because the two
    // kinds have opposite ownership — read this before parking a cloud node:
    //
    //   mesh  — the box is pre-existing and only SSH-adopted, so Pulumi owns nothing to
    //           destroy. `false` simply skips the provisioning pass: no SSH dial, no k8s
    //           objects. This is the intended, safe use (an unreachable box otherwise
    //           HARD-FAILS the whole sync on the SSH dial, since the in-script BOX_OK skip
    //           never runs). An already-joined node keeps running untouched.
    //
    //   cloud — Pulumi CREATES the server. Dropping it from the program is a DESTROY, not a
    //           pause: `pulumi up` would delete the hcloud server (and its disks) on the next
    //           apply. So `false` here is only legal for a node that is not yet built; it is
    //           REJECTED by validateClusterNodes for the init CP, and must not be used to
    //           "pause" a live cloud node. Use it to stage a not-yet-wanted node's config.
    //
    // Deliberately NOT honored by src/storage.ts for mesh nodes: storageScope still counts
    // toward the longhorn-<scope> StorageClasses and their replica targets, so parking a node
    // is a provisioning pause, not a storage migration. Retiring a mesh node for real is
    // scripts/provisioning/decomissionNode.sh.
    enabled?: boolean;
    // Free-text note surfaced as the node annotation ecc/description (every node kind).
    // e.g. "transient testbed server in hetComp Lab with PCIe gen6".
    description?: string;
    // Whether the node exposes /dev/kvm for hardware virtualization
    // (-> node label ecc/kvm=true; windows/KVM workloads require this). Defaults to false.
    // Typically true on dedicated/robot and on-premise bare-metal; false on cloud VMs.
    kvm?: boolean;
    // How this node reaches the cluster control-plane. Required on EVERY node. Exactly one
    // node across the whole cluster (cloud + mesh) must be "init" (the cluster-init CP).
    // Legality is enforced by validateClusterNodes (see below).
    clusterLink: ClusterLink;
    // The place this node sits — its failure-and-latency domain (one LAN = one site).
    // Required on EVERY node. Drives join topology, the `ecc/site` node label, and the
    // primary Longhorn storage scope. Place-only names:
    //   - cloud/robot: e.g. "hetzner-fsn1" (the one Hetzner private net + Robot vSwitch).
    //   - on-premise: the LAN name, e.g. "unibi-lab1", "unibi-lab2", "home-martin".
    // Topology rule: every "direct" node (INCLUDING the init CP) must share the SAME `site` —
    // that's how they reach the init CP without the VPN. "vpn" nodes still declare their
    // `site` (documents where they sit) but join over the mesh regardless. Enforced by
    // validateClusterNodes.
    site: string;
}

// A Hetzner-hosted node on the private network (cloud VM or dedicated server).
// clusterLink is inherited from ComputeNode: a cloud/robot node is "init" or "direct"
// today; it may also be "vpn" once the init CP is on-premise (see validateClusterNodes).
export interface ComputeNodeCloudBase extends ComputeNode {
    // Narrow the base ComputeNode.ssh: cloud/robot must set key/port/user explicitly.
    // endpoint stays OPTIONAL — an hcloud VM's public IP isn't known until Pulumi creates the
    // server, and a robot box derives it from its (required) publicIp; when omitted the
    // provisioner falls back to root@<public-ip>:22.
    ssh: { endpoint?: string; key: string; port: number; user: string };
    os: NodeOs; // OS image for this node (hcloud image name / installimage target)
    // hcloud datacenter ("fsn1") / Robot datacenter — the literal Hetzner placement passed
    // to the hcloud API (distinct from the place-only `site`, e.g. "hetzner-fsn1").
    location: string;
    // Static private-network IP within network.subnetRange. Optional for hcloud VMs
    // (Hetzner auto-assigns if omitted); required for provider:"robot" nodes (vSwitch).
    // Validated at load time: must be a valid IPv4, inside subnetRange, outside meshRange,
    // and must not collide with network.vip, network.gateway, or another node's privateIp.
    privateIp?: string;
    swap?: number; // swapfile size in GiB to create on the node (0/undefined = no swap)
    swapBehavior?: SwapBehavior; // kubelet memorySwap.swapBehavior; only effective with swap > 0; default "NoSwap"
}

// Cloud VM: an hcloud server created by Pulumi (@pulumi/hcloud).
export interface ComputeNodeCloudVm extends ComputeNodeCloudBase {
    provider: "hcloud"; // discriminant
    serverType: string; // hcloud server type, e.g. "CPX32"
}

// Dedicated (Robot) server: ordered MANUALLY in Hetzner Robot, then adopted by
// serverId. Connected to the hcloud private network via a Hetzner vSwitch.
export interface ComputeNodeCloudDedicated extends ComputeNodeCloudBase {
    provider: "robot"; // discriminant
    serverId: number; // Robot server number (adopt an existing, manually-ordered server)
    image: string; // installimage OS, e.g. "Debian 13"
    vlanId: number; // vSwitch VLAN id (4000-4091)
    privateIp: string; // required for robot: vSwitch needs a static IP (narrows base's optional)
    // Public IPv4 of the Robot box. Robot servers are not in the hcloud API, so unlike
    // hcloud VMs (where .ipv4Address comes from the Server resource) the address must be
    // configured here. Used for: SSH provisioning, peer-CP discovery, and DNS/ingress
    // (the ClusterNode.ipv4Address the robot path returns).
    publicIp: string;
    publicIpv6?: string; // optional public IPv6 (for DNS AAAA / ingress); empty if unset
}

// Discriminated union (on `provider`) for the unified cluster node list.
export type ComputeNodeCloud = ComputeNodeCloudVm | ComputeNodeCloudDedicated;

// Network constraints passed to validateClusterNodes for IP checks.
export interface NodeNetworkConstraints {
    subnetRange: string; // e.g. "10.0.0.0/23" — umbrella; every privateIp must be within this
    serverSubnetRange: string; // e.g. "10.0.0.0/24" — hcloud (provider:"hcloud") privateIps
    vswitchRange: string; // e.g. "10.0.1.0/24" — robot (provider:"robot") privateIps
    meshRange: string; // e.g. "10.0.10.0/23" — privateIp must NOT be in this
    vip: string; // kube-vip VIP — privateIp must not collide
    gateway: string; // subnet gateway — privateIp must not collide
}

function ipToInt(ip: string): number {
    const [a, b, c, d] = ip.split(".").map(Number);
    return ((a << 24) | (b << 16) | (c << 8) | d) >>> 0;
}

function cidrBounds(cidr: string): { first: number; last: number } {
    const [base, bits] = cidr.split("/");
    const mask = bits === "32" ? 0xffffffff : ~((1 << (32 - Number(bits))) - 1) >>> 0;
    const first = (ipToInt(base) & mask) >>> 0;
    const last = (first | (~mask >>> 0)) >>> 0;
    return { first, last };
}

function isIpInCidr(ip: string, cidr: string): boolean {
    const n = ipToInt(ip);
    const { first, last } = cidrBounds(cidr);
    return n >= first && n <= last;
}

function isValidIpv4(ip: string): boolean {
    const parts = ip.split(".");
    return (
        parts.length === 4 &&
        parts.every((p) => /^\d+$/.test(p) && Number(p) >= 0 && Number(p) <= 255)
    );
}

// Config-time invariants for the whole cluster (cloud + mesh). Throws on misconfiguration.
// clusterLink selects the topology: exactly one node is "init" (runs cluster-init on the
// INITIAL bring-up); once the cluster has multiple healthy CPs (etcd HA) the init node is
// not special any more (see the join-or-init logic in src/nodes-k3s-base.ts).
//
// Topology: the init node may be cloud/robot OR an on-premise mesh node. "direct" followers
// (incl. the init CP) must all share ONE non-empty `site` — they reach the init CP over that
// shared network without the VPN, in pass 1. Exactly ONE site holds the "direct" CP+followers
// (the init site); everything else joins over the mesh ("vpn") in a 2nd pass after the
// in-cluster headscale is up. There is no provider-implied link: a LAN peer of an on-premise
// init CP is "direct"; a cloud node joining an on-premise init CP is "vpn".
export function validateClusterNodes(
    cluster: ComputeNodeCloud[],
    mesh: ComputeNodeMesh[],
    network?: NodeNetworkConstraints,
): void {
    // ── ids unique across BOTH lists (k3s node-names share one namespace) ──
    const allIds = [...cluster.map((n) => n.id), ...mesh.map((n) => n.id)];
    const dupId = allIds.find((id, i) => allIds.indexOf(id) !== i);
    if (dupId) throw new Error(`project_settings.nodes: duplicate node id "${dupId}"`);

    // ── at least one control-plane across cloud + mesh (the init CP may be a mesh node) ──
    const allNodes = [...cluster, ...mesh];
    const cps = allNodes.filter((n) => n.k8sRole === "controlplane");
    if (cps.length === 0)
        throw new Error("project_settings.nodes: at least one controlplane node required");

    // ── site is required on EVERY node (the place / failure-and-latency domain) ──
    for (const n of allNodes) {
        if (!n.site)
            throw new Error(
                `project_settings.nodes "${n.id}": site is required on every node ` +
                    `(e.g. "hetzner-fsn1" for cloud/robot, or the LAN name for on-premise)`,
            );
    }

    // ── storageScope is required (≥1 entry) on every mesh node; first entry = primary scope ──
    for (const n of mesh) {
        if (!Array.isArray(n.storageScope) || n.storageScope.length === 0)
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": storageScope is required and must have ` +
                    `at least one entry (the first is the primary scope, e.g. ["unibi-lab1","unibi"])`,
            );
        if (n.storageScope.some((s) => !s))
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": storageScope contains an empty tag`,
            );
        // ── advertiseRoutes: well-formed CIDRs, and not overlapping the overlay itself ──
        // A malformed entry makes `tailscale up --advertise-routes` fail on the box, which
        // surfaces as a provisioning error far from its cause; catch the shape here.
        for (const r of n.advertiseRoutes ?? []) {
            const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/.exec(r);
            if (!m)
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": advertiseRoutes entry "${r}" is not ` +
                        `an IPv4 CIDR (e.g. "192.168.1.0/24")`,
                );
            const octets = [m[1], m[2], m[3], m[4]].map(Number);
            const prefix = Number(m[5]);
            if (octets.some((o) => o > 255) || prefix > 32)
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": advertiseRoutes entry "${r}" is out of ` +
                        `range (octets ≤255, prefix ≤32)`,
                );
            // Advertising the mesh range itself would have every node claim to route the
            // overlay — a routing loop, not a subnet router.
            if (network?.meshRange && r === network.meshRange)
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": advertiseRoutes must not contain the ` +
                        `mesh range itself (${r}); advertise the site LAN, not the overlay`,
                );
        }
        // ── extraLonghornDisks: shape, and tags that actually resolve to a StorageClass ──
        // Every failure here is silent at runtime, which is why it is caught at load:
        // a bad path breaks provisioning (see the field's doc comment), and an unbacked tag
        // produces a disk that no StorageClass selects and no RecurringJob group covers.
        const extraPaths = new Set<string>();
        for (const d of n.extraLonghornDisks ?? []) {
            if (!d.label)
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": extraLonghornDisks entry has an empty ` +
                        `label (use the filesystem LABEL from \`blkid -L\`, e.g. "storage1")`,
                );
            if (!d.path || !d.path.startsWith("/"))
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": extraLonghornDisks entry "${d.label}" ` +
                        `needs an absolute path (e.g. "/mnt/storage1"), got "${d.path}"`,
                );
            // /var/lib/longhorn is the DEFAULT disk this field adds to, so naming it again is
            // either a duplicate or an attempt to relocate the default — which cannot work:
            // 00-cleanup-node.sh does `rm -rf /var/lib/longhorn`, and rm cannot remove a
            // mountpoint (EBUSY aborts the whole provisioning run under set -e).
            if (d.path === "/var/lib/longhorn" || d.path.startsWith("/var/lib/longhorn/"))
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": extraLonghornDisks path "${d.path}" ` +
                        `must not be /var/lib/longhorn or under it — that is the default disk, and ` +
                        `00-cleanup-node.sh rm -rf's it (rm cannot remove a mountpoint: EBUSY aborts ` +
                        `the provisioning run). Mount elsewhere, e.g. "/mnt/${d.label}"`,
                );
            if (extraPaths.has(d.path))
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": extraLonghornDisks has two entries for ` +
                        `path "${d.path}"; each disk needs its own mount point`,
                );
            extraPaths.add(d.path);
            if (d.tags && d.tags.length === 0)
                throw new Error(
                    `project_settings.nodes.mesh "${n.id}": extraLonghornDisks entry "${d.label}" ` +
                        `has an empty tags list; omit tags to inherit the node's storageScope`,
                );
            for (const t of d.tags ?? []) {
                if (!t)
                    throw new Error(
                        `project_settings.nodes.mesh "${n.id}": extraLonghornDisks entry ` +
                            `"${d.label}" contains an empty tag`,
                    );
                // The load-bearing check. A tag carried by no node's storageScope gets no
                // longhorn-<scope> StorageClass (src/storage.ts derives them from storageScope)
                // and no RecurringJob group (applyProjectSettings.py likewise) — so volumes on
                // it would take zero snapshots and zero backups, with nothing to show for it.
                // Three scopes had already drifted out that way before the groups were generated.
                if (!mesh.some((o) => (o.storageScope ?? []).includes(t)))
                    throw new Error(
                        `project_settings.nodes.mesh "${n.id}": extraLonghornDisks entry ` +
                            `"${d.label}" has tag "${t}", which no mesh node carries in its ` +
                            `storageScope (have: ` +
                            `${[...new Set(mesh.flatMap((o) => o.storageScope ?? []))].join(", ") || "none"}). ` +
                            `src/storage.ts mints one longhorn-<scope> StorageClass per storageScope ` +
                            `tag, so this one would not exist, and the scope would also be absent ` +
                            `from the Longhorn RecurringJob groups — zero snapshots and zero backups, ` +
                            `silently. Add the tag to a node's storageScope, or drop it here.`,
                    );
            }
        }
    }

    // ── exactly one "init" node across cloud + mesh ──
    const inits = allNodes.filter((n) => n.clusterLink === "init");
    if (inits.length !== 1)
        throw new Error(
            `project_settings.nodes: exactly one node must have clusterLink: "init" ` +
                `(found ${inits.length}: [${inits.map((n) => n.id).join(", ")}])`,
        );
    const initNode = inits[0];
    if (initNode.k8sRole !== "controlplane")
        throw new Error(
            `project_settings.nodes: the init node "${initNode.id}" must have k8sRole "controlplane"`,
        );

    // ── enabled:false legality ──
    // The init CP is the cluster: parking it leaves nothing to join. Reject outright, on
    // either node kind, before the "at least one enabled cloud node" check below.
    if (initNode.enabled === false)
        throw new Error(
            `project_settings.nodes: the init node "${initNode.id}" cannot have enabled:false ` +
                `(it runs cluster-init — parking it leaves no control-plane to join)`,
        );
    // A cloud node is CREATED by Pulumi, so removing it from the program destroys the server
    // and its disks — enabled:false is a staging flag for a not-yet-built node, never a pause
    // button for a live one. Guard the foot-gun where it is cheap to guard: never let the
    // whole cloud list be parked (that would tear down the cluster on the next `pulumi up`).
    const enabledCloud = cluster.filter((n) => n.enabled !== false);
    if (cluster.length > 0 && enabledCloud.length === 0)
        throw new Error(
            `project_settings.nodes.cloud: every cloud node has enabled:false. Cloud nodes are ` +
                `Pulumi-created, so this would DESTROY the cluster on the next apply. Use ` +
                `enabled:false only to stage a node that is not built yet.`,
        );

    // ── "direct" legality: shared `site` with the init CP (the single init site) ──
    // Every "direct" follower must sit on the SAME site as the init CP, so they can reach it
    // over that shared LAN without the VPN. "vpn" nodes may sit anywhere. The init CP may be
    // cloud/robot OR an on-premise mesh node — only its site is constrained, not its kind.
    // (Presence of `site` is already guaranteed by the per-node check above.)
    const directNodes = allNodes.filter((n) => n.clusterLink === "direct");
    if (directNodes.length > 0) {
        for (const n of directNodes) {
            if (n.site !== initNode.site)
                throw new Error(
                    `project_settings.nodes "${n.id}": clusterLink "direct" but its site ` +
                        `"${n.site}" differs from the init CP "${initNode.id}" site ` +
                        `"${initNode.site}" — direct followers must share the init CP's site`,
                );
        }
    }

    if (!network) return;

    for (const n of cluster) {
        // robot nodes must always have a privateIp (vSwitch requires it)
        if (n.provider === "robot" && !n.privateIp)
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": provider "robot" requires privateIp`,
            );

        if (!n.privateIp) continue;

        if (!isValidIpv4(n.privateIp))
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": privateIp "${n.privateIp}" is not a valid IPv4 address`,
            );
        if (!isIpInCidr(n.privateIp, network.subnetRange))
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": privateIp "${n.privateIp}" is not inside subnetRange ${network.subnetRange}`,
            );
        // Per-provider subnet membership: hcloud VMs live in the "server" subnet, robot boxes
        // in the "vswitch" subnet. These hcloud NetworkSubnets must not overlap, so a misplaced
        // IP (e.g. a robot IP in the cloud /24) would collide at deploy time — reject it here.
        if (n.provider === "hcloud" && !isIpInCidr(n.privateIp, network.serverSubnetRange))
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": provider "hcloud" privateIp "${n.privateIp}" ` +
                    `must be inside serverSubnetRange ${network.serverSubnetRange}`,
            );
        if (n.provider === "robot" && !isIpInCidr(n.privateIp, network.vswitchRange))
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": provider "robot" privateIp "${n.privateIp}" ` +
                    `must be inside vswitchRange ${network.vswitchRange}`,
            );
        if (isIpInCidr(n.privateIp, network.meshRange))
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": privateIp "${n.privateIp}" overlaps meshRange ${network.meshRange}`,
            );
        if (n.privateIp === network.vip)
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": privateIp "${n.privateIp}" conflicts with network.vip`,
            );
        if (n.privateIp === network.gateway)
            throw new Error(
                `project_settings.nodes.cloud "${n.id}": privateIp "${n.privateIp}" conflicts with network.gateway`,
            );
    }

    const ips = cluster.map((n) => n.privateIp).filter(Boolean) as string[];
    const dupIp = ips.find((ip, i) => ips.indexOf(ip) !== i);
    if (dupIp) throw new Error(`project_settings.nodes.cloud: duplicate privateIp "${dupIp}"`);
}

// Config-time invariants for the on-prem AD domain controllers. Throws on misconfiguration.
//
// WHY A SECOND VALIDATOR AND NOT MORE CHECKS IN validateClusterNodes: these are invariants
// BETWEEN two settings blocks (nodes.mesh and fileserver), not properties of a node on its
// own, and they gate a workload — the DCs — whose misplacement is silent. A DC on a node
// with no route to the appliance still comes up Healthy and still replicates; only SMB and
// NFS logins fail, which reads as a permissions problem.
export function validateAdPlacement(
    mesh: ComputeNodeMesh[],
    fileserver: { site: string; labCidr?: string },
): void {
    const dcs = mesh.filter((n) => n.adDc && n.enabled !== false);

    // ── at least one, or the site has no local directory at all ──
    // ⚠ ONE is ALLOWED, and is the current deliberate choice: the single DC runs on the VM
    // hosted BY the appliance, so the two share a failure domain and there is no state where
    // the fileserver is up and its directory is not.
    //
    // Know what one costs, because it is not nothing: a DC pod restart or a host reboot is a
    // site-wide auth outage with only the cloud DC left, and lab clients reach that over the
    // mesh — the least reliable link in the system. It is also what makes the TrueNAS repair
    // path in truenas/configure-job.yaml reachable at all: that path fires when the appliance
    // cannot resolve a principal, it LEAVES the domain (deleting FS-1$), and it did so
    // unattended on 2026-08-31 while the site had exactly one DC. The retry discipline there
    // now rejects a transient, but a genuinely long outage still qualifies.
    //
    // Raising this is a one-line change: add `adDc: true` to another lab node and re-run
    // updateConfigFromProjectSettings.sh, which derives the StatefulSet replica count from
    // this same list.
    if (dcs.length < 1)
        throw new Error(
            `project_settings.nodes.mesh: at least one enabled node must set adDc: true. ` +
                `With none, the lab site has no local directory: every SMB and NFS login ` +
                `depends on reaching the cloud DC over the mesh.`,
        );

    // ── all at the fileserver's site: a DC elsewhere cannot serve the appliance ──
    for (const n of dcs) {
        if (n.site !== fileserver.site)
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": adDc is set but site is "${n.site}", ` +
                    `not the fileserver's site "${fileserver.site}". The appliance has only a ` +
                    `LAN address, so a DC at another site is unroutable from it.`,
            );
    }

    // ── lanIp: present, well-formed, inside the site LAN, and unique ──
    // The DC binds this address for the real AD ports; a wrong one is not a silent
    // degradation, it is a DC that answers nothing on the LAN.
    const seen = new Map<string, string>();
    for (const n of dcs) {
        if (!n.lanIp)
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": adDc requires lanIp (the node's own ` +
                    `address on the site LAN, e.g. "192.168.1.194")`,
            );
        if (!isValidIpv4(n.lanIp))
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": lanIp "${n.lanIp}" is not an IPv4 address`,
            );
        if (fileserver.labCidr && !isIpInCidr(n.lanIp, fileserver.labCidr))
            throw new Error(
                `project_settings.nodes.mesh "${n.id}": lanIp "${n.lanIp}" is outside the site ` +
                    `LAN ${fileserver.labCidr} (fileserver.labCidr)`,
            );
        const other = seen.get(n.lanIp);
        if (other)
            throw new Error(
                `project_settings.nodes.mesh: "${n.id}" and "${other}" both claim lanIp ` +
                    `"${n.lanIp}" — each DC needs its own LAN address`,
            );
        seen.set(n.lanIp, n.id);
    }
}

// Fail fast on a placement default that no node satisfies. Separate from validateClusterNodes
// because these are invariants BETWEEN applicationPlacements and nodes, and because the
// failure is SILENT in two different ways: a meshSite no node carries leaves every anchored
// nodeSelector unschedulable, and a meshStorageScope no node carries means the
// longhorn-<scope> StorageClass is never created, so every anchored PVC sits Pending forever
// while the app reports only "waiting for volume".
export function validatePlacementDefaults(
    cloud: ComputeNode[],
    mesh: ComputeNodeMesh[],
    placements: {
        meshSite: string;
        meshStorageScope: string;
        ryaxStorageScope: string;
        cloudSite: string;
    },
): void {
    const enabledMesh = mesh.filter((n) => n.enabled !== false);
    const enabledCloud = cloud.filter((n) => n.enabled !== false);

    // Disabled nodes are declared-but-not-joined, so they must not satisfy a default — the
    // label or disk tag they would have carried does not exist on the cluster.
    const meshSites = new Set(enabledMesh.map((n) => n.site));
    if (!meshSites.has(placements.meshSite))
        throw new Error(
            `project_settings.applicationPlacements.meshSite "${placements.meshSite}" matches ` +
                `no enabled mesh node's site (have: ${[...meshSites].join(", ") || "none"}). ` +
                `Every app anchored to it would be unschedulable.`,
        );

    // Every scope-valued default, checked the same way: src/storage.ts mints one
    // longhorn-<scope> StorageClass per distinct scope of an ENABLED node, so a default
    // naming a scope outside that set points at a class that is never created.
    const scopes = new Set(enabledMesh.flatMap((n) => n.storageScope));
    for (const [key, scope] of [
        ["meshStorageScope", placements.meshStorageScope],
        ["ryaxStorageScope", placements.ryaxStorageScope],
    ] as const)
        if (!scopes.has(scope))
            throw new Error(
                `project_settings.applicationPlacements.${key} "${scope}" is not a ` +
                    `storageScope of any enabled mesh node (have: ` +
                    `${[...scopes].join(", ") || "none"}). src/storage.ts creates one ` +
                    `longhorn-<scope> StorageClass per distinct scope, so this one would ` +
                    `not exist and every anchored PVC would sit Pending forever.`,
            );

    const cloudSites = new Set(enabledCloud.map((n) => n.site));
    if (!cloudSites.has(placements.cloudSite))
        throw new Error(
            `project_settings.applicationPlacements.cloudSite "${placements.cloudSite}" matches ` +
                `no enabled cloud node's site (have: ${[...cloudSites].join(", ") || "none"}).`,
        );
}

// On-premise mesh node: a pre-existing machine (OS installed) reached over SSH that joins
// the cluster over the headscale/tailscale mesh ("mesh" = adopted over SSH + VPN-joined,
// NOT physically at the network edge). Pulumi does NOT create it (not an hcloud server); it
// is provisioned in-place via command.remote.Command (install Tailscale + k3s-agent).
// See src/nodes-k3s-mesh.ts.
export interface ComputeNodeMesh extends ComputeNode {
    // id doubles as the k3s node-name AND selects a single node for
    // `make provision-mesh-node ARGS=<id>` (runtime_flags.meshProvisioning.filter).
    // The same id appears in runtime_flags.meshProvisioning.skip when the pre-flight SSH probe finds the
    // box unreachable — that omits only its SSH provision Command, not the node itself.
    // A mesh box has no public IP, so endpoint/port/user are REQUIRED here (narrowed from the
    // base ComputeNode.ssh, where they are optional cloud/robot-defaulted fields).
    ssh: {
        endpoint: string; // SSH host — hostname or IP, e.g. "jump.your-domain.tld"
        key: string; // Pulumi config key for the SSH private key
        port: number; // e.g. 1717
        user: string; // e.g. "cape"
    };
    // NOTE: `enabled` is inherited from ComputeNode. On a mesh node it is a pure
    // provisioning pause (no SSH dial, nothing torn down) — see the base declaration.
    hardware?: string; // -> node label ecc/hardware; free-form HW tag, e.g. "pcie-gen6"
    // The MACHINE THIS NODE RUNS ON, when it is not bare metal. Absent (the normal case)
    // means the node IS the box. Present means something else has to create the box before
    // the node can exist at all, and `kind` selects which provisioner does that.
    //
    // ⚠ THIS IS A CREATION DEPENDENCY, NOT A PLACEMENT HINT. A node with `host` set cannot
    // be brought up by the mesh join alone: the box must be created on the host first.
    // Keeping it declarative here is what lets a recreate know the box has to be rebuilt,
    // rather than silently provisioning a node that has nowhere to live.
    //
    // For kind "truenas" that first step is a VM booting an autoinstall ISO — see
    // doc/truenas-vm.md for the procedure. NOT a container: TrueNAS's registry carries only
    // `ubuntu:*:default` images, which ship no cloud-init, and the init/initenv/inituser
    // fields are accepted, stored, read back — then silently ignored at boot, so a container
    // cannot provision itself. (scripts/provisioning/createTrueNasContainer.sh still implements
    // the container path and is kept for throwaway/probe work; it is NOT the node path.)
    //
    // Modelled as a DISCRIMINATED UNION rather than a free-form bag so a second host type
    // (proxmox, libvirt) adds a variant instead of accumulating loosely-related keys.
    host?: {
        // Which provisioner owns the box. The only implemented kind today.
        kind: "truenas";
        // The appliance's API address — the LITERAL LAN IP, same value and same reasoning
        // as fileserver.endpoint: the AD zone publishes the on-prem DC's MESH address, so
        // resolving the appliance by name would route LAN traffic over the overlay.
        endpoint: string;
        // ZFS pool the guest's disk (zvol) lives on.
        pool: string;
        // ⚠ PIN THE GUEST'S MAC, or a recreate silently loses its DHCP reservation.
        // TrueNAS assigns a FRESH RANDOM MAC every time a VM is created, so deleting and
        // rebuilding one (createTrueNasVM.sh --force) hands the guest a new identity: the
        // router's reservation still points at the OLD MAC, the guest takes some other
        // address out of the pool, and every inbound port-forward that targets the reserved
        // IP — including the ssh.port this node is reached on — goes dead. Nothing errors;
        // the VM boots fine and is simply not where anything expects it.
        // Measured 2026-08-29: rebuilding unibi-lab-fs-vm moved it off 192.168.1.194 and
        // left epi.techfak:3004 refusing.
        // Set this to the MAC the router reservation is keyed to; createTrueNasVM.sh passes
        // it to vm.device.create so the guest keeps one stable identity across recreates.
        mac?: string;
        // ⚠ KEY NAMES, NEVER VALUES. Both resolve against the Pulumi stack
        // (`pulumi config get <key>`), which is the source of truth for this credential —
        // deployment/argocd-infra/truenas/sealSecrets.sh DERIVES the sealed manifests from
        // these, not the other way round.
        // No credential belongs in this file; see the note at fileserver.
        userNameKey: string; // e.g. "truenasAdminUser"
        passwordKey: string; // e.g. "truenasAdminPassword"
    };
    // GPU type. When set, the mesh-join pipeline runs the GPU host install step
    // (20-install-gpu.sh) and stamps the labels ecc/gpu=true + ecc/gpu-model=<type>
    // plus the ecc/gpu=true:NoSchedule taint (GPU nodes are opt-in only).
    //
    // The VALUE NAMES THE CUDA ARCH, not the board — that is what decides whether a
    // serving image runs here at all (a container built for sm_110 will not run on
    // sm_75). Hence "nvidia-turing-sm75" rather than "rtx2070"/"smartmirror". Put the
    // human-readable board tag in `hardware` instead.
    //
    // The `jetson-` PREFIX selects the provisioning path in 20-install-gpu.sh:
    //   * jetson-*  (SoC/Tegra) — assumes JetPack (L4T) is already FLASHED (the CUDA
    //     driver ships with the flash); installs nvidia-jetpack for the CUDA toolkit
    //     (vLLM needs on-node ptxas) and pins the container runtime to mode=cdi.
    //   * anything else (discrete PCIe) — installs the proprietary desktop driver +
    //     blacklists nouveau (needs ONE reboot), no CUDA toolkit (upstream x86 images
    //     carry their own), and leaves the container runtime at mode=auto.
    // Archs: Thor=Blackwell sm_110; Orin=Ampere sm_87 — both on JetPack 7 / L4T R39.2.1,
    // so both take the same kernel rebuild (doc/provision-jetson.md). An sm_110 image still
    // must NOT be scheduled on the Orin.
    // Turing=sm_75 discrete (8 GB per card, no FP8, no NVFP4).
    gpu?: "jetson-thor" | "jetson-orin" | "nvidia-turing-sm75";
    // Nested-container runtime for this node. When set, the mesh-join pipeline runs
    // 50-install-nested-runtime.sh (installs the runtime + wires a k3s containerd
    // config-v3.toml.d drop-in + restarts the agent) and stamps the node label
    // ecc/nested-runtime=<type>. This lets a pod on this node run inner OCI containers
    // WITHOUT being privileged — the remote-desktop Model-B path (a module runs as its
    // own container inside the desktop pod; e.g. HyperLynx).
    //   "gvisor" — userspace syscall interception (runsc): native overlay storage, and no
    //              /dev/kvm needed.
    //
    // sysbox-ce was evaluated and is BROKEN on Ubuntu 25.10 / kernel 6.17 / k3s containerd
    // 2.3 (sysfs "mount through procfd" EPERM, no fix, v0.7.0 is the newest release) — do
    // not add it back without re-validating on the live kernel.
    //
    // ⚠ UNLIKE `gpu`, this is in fpLabels but NOT fpBox (src/nodes-k3s-mesh.ts), so
    // changing it RE-LABELS the node WITHOUT re-provisioning it. A plain `make up` would
    // therefore advertise ecc/nested-runtime-<type> while the handler binary is not
    // installed, and pods selecting that RuntimeClass hang in ContainerCreating. Install
    // the handler FIRST (50-install-nested-runtime.sh on the box, or
    // `make provision-mesh-node ARGS='<id>'` which implies --force and drains), THEN let
    // the label reconcile. See doc/nested-container-runtime.md.
    // See doc/nested-container-runtime.md for the full rule.
    nestedRuntime?: "gvisor";
    // Mark this node as an EDA image-build host (-> node label ecc/eda-builder=true), which
    // is what the shared [eda] GitLab runner's node_selector matches. A capability label
    // rather than a hostname pin, so a build can land on any enrolled node; and a DEDICATED
    // label rather than reusing ecc/site, so adding a future lab node does not silently
    // enroll it as a ~115 GB-per-build host.
    //
    // ⚠ An EDA build needs BOTH: this label AND ecc/site: unibi-hclab. The csi-driver-nfs
    // controller and node DaemonSet are nodeSelector'd to that site, so the installer-media
    // PVC cannot mount anywhere else ("driver name nfs.csi.k8s.io not found").
    //
    // ⚠ /build-scratch is a node-local hostPath, so its flock only serialises builds ON ONE
    // NODE. Enrolling more nodes is safe ONLY while the runner keeps concurrent=1 (one build
    // at a time cluster-wide, wherever it lands). Raising concurrent AND widening nodes
    // reintroduces the race where a second job's `rm -rf` deletes a 115 GB extraction from
    // under an in-flight tar. See app-of-apps/gitlab-runner-eda.yaml.
    edaBuilder?: boolean;
    // Relocate /var/lib/rancher onto a node-local disk, for a node whose ROOT FILESYSTEM
    // CANNOT HOST IT. When set, the mesh-join pipeline runs 05-prepare-data-disk.sh before
    // the prereqs; when absent (the normal case) that step never runs and the node is
    // untouched.
    //
    // WHY THIS EXISTS: k3s puts containerd's snapshotter under
    // /var/lib/rancher/k3s/agent/containerd, and OVERLAYFS CANNOT BE STACKED ON OVERLAYFS —
    // the kernel rejects the mount with EINVAL. On a netboot/live node, whose root IS an
    // overlay (squashfs + tmpfs), the agent therefore never starts; it loops on
    //   "overlayfs" snapshotter cannot be enabled for ".../containerd",
    //   try using "fuse-overlayfs" or "native"
    // and the join fails after ~300s with no other symptom. Measured 2026-09-09 on
    // budapest-emdc-node7. This is a property of live-booted nodes in general, not of one
    // site, which is why it is declared per node rather than special-cased in a script.
    //
    // It is also where the SIZE goes: ~10 GB of image layers after a single join, which on
    // such a node would otherwise sit in a RAM-backed tmpfs.
    //
    // ⚠ A SYMLINK is used, never a bind mount: 00-cleanup-node.sh does
    // `rm -rf /var/lib/rancher/k3s`, and rm cannot remove a MOUNTPOINT (EBUSY under set -e,
    // which aborts the whole provisioning run). Through a symlink it unlinks the child and
    // leaves the link itself intact.
    //
    // ⚠ Longhorn is deliberately NOT relocated. /var/lib/longhorn is deleted outright by
    // the cleanup step, so a symlink there is unlinked on every provision and silently
    // recreated on the root filesystem. A live node is wipe-on-reboot anyway, so nothing
    // durable may live on it wherever the bytes sit.
    k3sDataDisk?: {
        // ext4/xfs filesystem LABEL of the target partition (`blkid -L <label>`), not a
        // /dev path — nvme enumeration is not stable across boots.
        label: string;
        // Subdirectory created on that filesystem to hold our data. REQUIRED, and it must
        // name the owner: these disks are frequently SHARED with another tenant (at the
        // EMDC the same partition also carries a foreign live-boot persistence volume with
        // its own SSH keys). Everything we write stays inside this one directory, and the
        // step never touches anything else on the filesystem.
        subdir: string;
    };
    // description is inherited from ComputeNode (-> node annotation ecc/description).
    // The Longhorn replication scopes this node's disk participates in (overlapping disk
    // tags — Option B). Required, ≥1 entry; the FIRST entry is the primary scope (used for
    // backup dedup). Each distinct scope across all mesh nodes yields one `longhorn-<scope>`
    // StorageClass (see src/storage.ts). A scope shared across LANs (e.g. "unibi") is a
    // cross-LAN redundant class; a scope unique to one LAN is strict-local.
    storageScope: string[];
    // ADDITIONAL Longhorn disks on this node, beyond the default /var/lib/longhorn. Optional;
    // omit it and the node keeps exactly one disk, which is the shape every node had before
    // this field existed.
    //
    // WHY: a box can have far more spindles than the OS disk. smartmirror1 carries two spare
    // 916 GiB SSDs that the cluster simply did not use — the pool saw 457 GiB of its ~2.3 TiB.
    //
    // ⚠ MOUNT THE FILESYSTEM YOURSELF, OUTSIDE /var/lib/longhorn. This field only tells
    // Longhorn that a path is a disk; it neither formats nor mounts. Two traps, both measured
    // and both documented at length in src/provisioning-scripts/05-prepare-data-disk.sh:
    //   - A mountpoint UNDER /var/lib/longhorn breaks provisioning outright: 00-cleanup-node.sh
    //     runs `rm -rf /var/lib/longhorn`, and rm cannot remove a mountpoint — it fails EBUSY
    //     and, under `set -e`, aborts the entire run.
    //   - A SYMLINK at /var/lib/longhorn is unlinked by that same cleanup, after which Longhorn
    //     silently recreates a real directory on the root filesystem — a node that advertises
    //     RAM as disk.
    // Use a path like /mnt/<label> and neither applies.
    //
    // ⚠ `tags` defaults to the node's storageScope, and that default is the SAFE case. A tag
    // that appears on no node's storageScope gets NO longhorn-<scope> StorageClass
    // (src/storage.ts derives them from storageScope) and NO RecurringJob group
    // (scripts/environment/applyProjectSettings.py does the same) — i.e. volumes on it would
    // take zero snapshots and zero backups, silently. validateClusterNodes rejects that.
    //
    // Replica counts do NOT change: src/storage.ts counts NODES carrying a scope, not disks,
    // so extra disks add capacity without altering any replica target.
    extraLonghornDisks?: Array<{
        // ext4/xfs filesystem LABEL (`blkid -L <label>`), not a /dev path — sd*/nvme*
        // enumeration is not stable across boots. Used by the host-side mount step.
        label: string;
        // Absolute mount point, which is also the Longhorn disk path. Must NOT be
        // /var/lib/longhorn or a path under it (see above).
        path: string;
        // Longhorn disk tags. Defaults to this node's storageScope. Every tag must already
        // be carried by some node's storageScope — see the warning above.
        tags?: string[];
        // Passed straight through to Longhorn. Defaults to true. false parks a disk as
        // present-but-unused (it holds no new replicas) without removing it.
        allowScheduling?: boolean;
    }>;
    // Site LAN subnets this node advertises INTO the mesh (`tailscale up --advertise-routes`),
    // making that LAN reachable from every other mesh node — the node acts as a subnet router.
    //
    // WHY: cluster pods and cloud nodes have no route to a site LAN. A cloud pod resolving a
    // LAN address gets it via the node's DEFAULT gateway, i.e. the public internet, and the
    // connection dies. Advertising the subnet is what turns a site-local service into one the
    // rest of the cluster can address by its real LAN IP.
    //
    // Concretely: the Samba AD lab DC listens on its LAN address for TrueNAS and the
    // laptops, but without the advertised subnet the cloud DC cannot replicate from it —
    // `ip route get <lan-ip>` on a cloud node resolves via the PUBLIC gateway. The
    // alternative is publishing the DC's MESH address, which forces LAN clients onto the
    // overlay. Advertising the subnet removes that trade-off: every party can use the real
    // LAN address.
    //
    // ⚠ Advertising alone is NOT enough — headscale holds each advertised route DISABLED until
    // an operator approves it (`headscale nodes approve-routes`). Consumers additionally need
    // `--accept-routes`, which 30-connect-vpn.sh already passes on both join paths.
    //
    // ⚠ Do not advertise a subnet that overlaps the mesh range or the pod/service CIDRs, and
    // do not advertise the same LAN from two nodes unless you intend HA failover between them.
    // Omit entirely for a node that is not a subnet router (the normal case).
    advertiseRoutes?: string[];
    // This node's own address on its site LAN (-> node label ecc/lan-ip).
    //
    // NOT the mesh address (headscale assigns that in join order and it is unknowable here)
    // and NOT `host.endpoint` (that is the APPLIANCE hosting a VM node, not the node). It is
    // the address a client on the same LAN dials — the only one a non-mesh client can route,
    // which is why the AD zone alone is not enough for the TrueNAS appliance.
    //
    // ⚠ IT IS A DECLARATION, NOT THE SOURCE OF TRUTH. The address is a DHCP reservation, so
    // reality lives on the box. This value exists so the expectation is reviewable in git and
    // so consumers can read it off the node label instead of each carrying its own copy; the
    // AD DC pod DERIVES its actual LAN address from the node's default-route NIC and fails
    // LOUDLY when the two disagree. Declared and actual may differ — they may not differ
    // silently.
    //
    // Required on any node with `adDc: true` (validateAdPlacement). Optional elsewhere, where
    // it is documentation plus a label nothing consumes yet.
    lanIp?: string;
    // Run an on-prem Samba AD domain controller here (-> node label ecc/ad-dc=true).
    //
    // A CAPABILITY LABEL, NOT A HOSTNAME PIN — the StatefulSet selects on it with a REQUIRED
    // podAntiAffinity on hostname, so one DC lands per enrolled node and the site survives
    // losing any one of them. Pinning the DC to a single named node instead puts every
    // Kerberos/LDAP/SMB login at the site behind one box, and arms the TrueNAS FAULTED
    // repair path (truenas/configure-job.yaml), which leaves the domain and deletes FS-1$.
    //
    // ⚠ THE STATEFULSET'S `replicas` MUST EQUAL THE NUMBER OF NODES CARRYING THIS FLAG.
    // The anti-affinity is required, so a surplus replica sits Pending forever. It is derived
    // from this list by updateConfigFromProjectSettings.sh and anchored onto the `replicas:`
    // line — do not hand-edit that number.
    //
    // ⚠ SCALING DOWN IS NOT SYMMETRIC. Removing this flag deletes a DC, and a deleted DC
    // leaves an orphaned object in AD. Demote it FIRST (`samba-tool domain demote`, or
    // `--remove-other-dead-server` from a survivor) — there is deliberately no preStop demote
    // hook, which would fire on every ordinary eviction.
    //
    // Requirements on the node: same `site` as the fileserver, a `lanIp`, amd64 (the samba
    // image), and no taint the DC pod does not tolerate — it tolerates `ecc/mesh` only, so a
    // GPU node is excluded for free.
    adDc?: boolean;
}
