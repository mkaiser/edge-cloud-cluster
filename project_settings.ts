/**
 * Project: edgecloudinfra
 * File: project_settings.ts
 * Purpose: Shared project settings and types.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

/*
This file is considered the single source of truth for all project settings. 
After changing any value here, run scripts/environment/updateConfigFromProjectSettings.sh to propagate the values set
here to the deployment YAML manifests in /deployment/ (which cannot import TypeScript). 
*/

// Shared domain types used across all modules.
import * as pulumi from "@pulumi/pulumi";

export type ClusterOS = "debian-13" | "ubuntu-24.04";
export type LoadBalancerProvider = "hetzner-ccm" | "k3s-servicelb";
export type ROLLOUT_TYPE = "Testing" | "Production" | "Bootstrap";
export type CERT_TYPE = "letsencrypt-production" | "letsencrypt-staging";

export interface ComputeNode {
    id: string;
    serverType: string;
    location: string;
    longhornTag?: "cloud" | "edge"; // default "cloud"; "edge" pins replicas to edge-only StorageClass
    swap?: number; // swapfile size in GiB to create on the node (0/undefined = no swap)
    swapBehavior?: SwapBehavior; // kubelet memorySwap.swapBehavior; only effective with swap > 0; default "NoSwap"
}

export type LonghornReplicaCount = "auto" | 1 | 2 | 3;

// kubelet memorySwap.swapBehavior (requires node.swap > 0 + fail-swap-on=false):
//   "NoSwap"      — default; pods CANNOT use swap (only non-pod/system processes can,
//                   e.g. k3s/etcd — that already protects the control-plane from OOM).
//   "LimitedSwap" — Burstable pods MAY use swap, capped proportionally to their memory
//                   request. Guaranteed and BestEffort pods still never swap.
//                   (UnlimitedSwap was removed in k8s; not an option.)
export type SwapBehavior = "NoSwap" | "LimitedSwap";

// On-premise edge node: a pre-existing machine (OS installed) reached over SSH.
// Pulumi does NOT create it (not an hcloud server); it is provisioned in-place via
// command.remote.Command (install Tailscale + k3s-agent). See src/nodes-k3s-on-premise.ts.
export interface EdgeNode {
    id: string; // node name + k3s node-name, e.g. "ubuntu-vm"
    sshHost: string; // e.g. "epi.techfak.uni-bielefeld.de"
    sshPort: number; // e.g. 1717
    sshUser: string; // e.g. "cape"
    location?: string; // -> node label ecc/location
    hardware?: string; // -> node label ecc/hardware
    kvm?: boolean; // -> node label ecc/kvm (windows requires this)
    longhornTag?: "cloud" | "edge"; // default "edge"
}

// Placement tier for an app/namespace:
//   cloud — essential, cluster-critical; restored at cloud creation; runs on cloud
//   flex  — non-essential; placed where resources are free (cloud or edge), one tier
//           at a time; optional placement.ecc/prefer: edge|cloud biases scheduling
//   edge  — edge-only (e.g. needs KVM); never scheduled on cloud
export type PlacementTier = "cloud" | "flex" | "edge";

// ─────────────────────────────────────────────────────────────────────────────
// General
// ─────────────────────────────────────────────────────────────────────────────
const clusterName = "edgecloudinfra"; // pulumi project / resource name prefix + S3 bucket name prefix
const baseDomain = "cape-project.eu"; //
const subdomain = "ecc135"; // adapt/increment to avoid hitting Let's Encrypt rate limits and DNS caching issues (see README.md)
const projectConfig = new pulumi.Config();

// headscale/tailscale mesh prefix (edge node VPN IPs). cp0 joins the mesh first and
// deterministically gets the first host address — derive it so it can never drift from
// the prefix. Used as the k3s API endpoint edge nodes reach (k3s-api.ts.internal).
const meshRange = "10.0.10.0/23";
const nthHostOf = (cidr: string, n: number): string => {
    const [base] = cidr.split("/");
    const o = base.split(".").map(Number);
    let acc = (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] + n;
    return [(acc >>> 24) & 255, (acc >>> 16) & 255, (acc >>> 8) & 255, acc & 255].join(".");
};
const firstHostOf = (cidr: string): string => nthHostOf(cidr, 1); // ".0" network -> ".1" first host
const cp0MeshIp = firstHostOf(meshRange); // "10.0.10.1"
// All control-plane mesh IPs, in mesh-join order (cp0 first → .1, cp1 → .2, cp2 → .3).
// `allocation: sequential` (wave8-headscale.yaml) + cp0 always joining first makes these
// deterministic. Published as the k3s-api.ts.internal A-record set so the k3s-agent
// client-LB fails over across live CPs instead of depending on cp0 alone. HA → 3 CPs;
// non-HA → only cp0 exists, so just [cp0MeshIp].
// MUST equal general.highAvailability below (kept as a separate literal so
// updateConfigFromProjectSettings.sh can regex `highAvailability: true|false` on that line).
// Drives how many CP mesh IPs we publish: HA → cp0/cp1/cp2 (.1/.2/.3); non-HA → cp0 only.
const highAvailability = false;
const cpMeshIps = highAvailability
    ? [nthHostOf(meshRange, 1), nthHostOf(meshRange, 2), nthHostOf(meshRange, 3)]
    : [cp0MeshIp];

export const project_settings = {
    general: {
        name: clusterName,
        baseDomain,
        subdomain,
        highAvailability: false, // when true: enforces ≥3 control-plane nodes at deploy time
        timezone: "Europe/Berlin",
        rolloutType: "Testing" as ROLLOUT_TYPE,
        completeClusterTeardown: projectConfig.getBoolean("completeClusterTeardown") ?? false,
        hcloudToken: projectConfig.requireSecret("hcloudToken"),
        backupToS3IntervalHour: 1, // etcd + Longhorn backup interval in hours; 0 disables backup
        restoreClusterFromS3Backup: projectConfig.getBoolean("restoreClusterFromS3Backup") ?? true,
    },
    placement: {
        // Namespaces/apps not explicitly tagged "flex"/"edge" (via the
        // placement.ecc/tier annotation on their ArgoCD Application) are
        // treated as this tier. "cloud" = restored at cluster creation, runs on cloud.
        defaultTier: "cloud" as PlacementTier,
    },
    edgeProvisioning: {
        // Gate: edge nodes are provisioned only by `make provision-edge` (a second
        // pass after the VPN/mesh is up), never during `make create`. Defaults false
        // so the cloud create never attempts SSH to edge hosts. The runner sets it.
        enabled: projectConfig.getBoolean("provisionEdgeNodes") ?? false,
        // "all" or a single EdgeNode id to provision (set by `make provision-edge ARGS=`).
        filter: projectConfig.get("edgeProvisionFilter") ?? "all",
        // Private key trusted by the edge hosts (cape@…); required only when enabled.
        sshPrivateKey: projectConfig.getSecret("edgeSshPrivateKey"),
    },
    server: {
        serverSshKey: "sshkey_ed25519_pxCloudEdgeInfra_Martin",
        os: "debian-13" as ClusterOS,
        loadBalancerProvider: "k3s-servicelb" as LoadBalancerProvider,
    },
    tls: {
        certIssuerType: "letsencrypt-staging" as CERT_TYPE,
        letsEncrypt: { email: "it@cape-project.eu" },
        wildcardTlsCert: projectConfig.getSecret("wildcardTlsCert"),
        wildcardTlsKey: projectConfig.getSecret("wildcardTlsKey"),
        sealedSecretsTlsCrt: projectConfig.requireSecret("sealedSecretsTlsCrt"),
        sealedSecretsTlsKey: projectConfig.requireSecret("sealedSecretsTlsKey"),
    },
    // ─────────────────────────────────────────────────────────────────────────────
    // Network — SINGLE SOURCE OF TRUTH for all cluster network ranges/addresses.
    // src/*.ts read these directly. YAML deployment manifests (which cannot import TS)
    // are kept in sync by scripts/environment/updateConfigFromProjectSettings.sh, which
    // rewrites the hardcoded values in wave8-headscale.yaml, mesh-gateway/daemonset.yaml
    // and kube-vip/daemonset.yaml. After changing any value here, run that script.
    // ─────────────────────────────────────────────────────────────────────────────
    network: {
        privateRange: "10.0.0.0/16",
        // Hetzner private subnet (control-plane advertise-address range, kube-vip ARP net).
        subnetRange: "10.0.0.0/23",
        gateway: "10.0.0.1",
        // kube-vip virtual IP for the k3s API (HA across control-plane nodes, ARP on the
        // private subnet). Consumed by kube-vip/daemonset.yaml `address` + CP tls-san.
        vip: "10.0.0.100",
        // headscale/tailscale mesh prefix (edge node VPN IPs, 10.0.10.1–10.0.11.255).
        // Matches wave8-headscale.yaml `prefixes.v4` and the edge-provisioning routes.
        // Used by the CP mesh↔private-network gateway SNAT so edge nodes (mesh) can reach
        // the k3s apiserver advertised on the private network (10.0.0.x) — enables the
        // built-in k3s agent load-balancer failover across all control-plane nodes (HA).
        meshRange,
        // cp0's mesh IP = first host of meshRange (cp0 joins first). This is the k3s API
        // endpoint edge nodes use (k3s-api.ts.internal → cp0MeshIp, see wave8 extra_records)
        // and a CP tls-san. Derived so it can never drift from meshRange.
        cp0MeshIp,
        // All CP mesh IPs (cp0/cp1/cp2 = .1/.2/.3 in HA). Published as the
        // k3s-api.ts.internal A-record SET in headscale extra_records so the k3s-agent
        // client-LB fails over across live CPs — removes the cp0 SPOF in name resolution.
        cpMeshIps,
        // Tailscale WireGuard direct data port. Opened inbound on the Hetzner firewall
        // (src/network.ts) AND pinned on tailscaled via --port (mesh-gateway daemonset) so
        // the firewalled port actually carries direct WireGuard — otherwise tailscaled
        // binds a random port, no direct path forms, and edge↔cloud is DERP-relay-only.
        tailscalePort: 41641,
    },
    // ─────────────────────────────────────────────────────────────────────────────
    // High-availability replica targets — SINGLE SOURCE OF TRUTH for essential-pod
    // replica/instance counts. src/*.ts may read these directly; YAML/Helm manifests
    // (which can't import TS) are kept in sync by
    // scripts/environment/updateConfigFromProjectSettings.sh, which rewrites the
    // integer on any line carrying a `# project-settings: ha.<key>` anchor and flips
    // the anti-affinity boolean on any `# project-settings: haAffinity.<key>` anchor.
    // The script picks `max` when general.highAvailability is true, else `min` (and
    // sets the affinity boolean to general.highAvailability). After editing this map,
    // run that script and commit the rewritten manifests.
    // ─────────────────────────────────────────────────────────────────────────────
    ha: {
        replicas: {
            cnpgOperator: { min: 1, max: 2 }, // CNPG operator (leader-elected); HA so a CP loss doesn't stall DB failover
            headscalePg: { min: 1, max: 3 }, // CNPG quorum (odd)
            authentikPg: { min: 1, max: 3 }, // CNPG quorum (odd)
            headplane: { min: 1, max: 1 }, // NOT scalable: RWO PVC → 2nd replica Multi-Attach fails. Pinned 1.
            authentikRedis: { min: 1, max: 1 }, // no redis HA wired up yet; left at 1
            seaweedfsMaster: { min: 1, max: 1 }, // 3 masters fail liveness (/cluster/status timeout) → CrashLoop. Durability is on Longhorn (see seaweedfs values). Pinned 1.
            seaweedfsVolume: { min: 1, max: 2 },
            seaweedfsFiler: { min: 1, max: 2 },
            argocdServer: { min: 1, max: 2 },
            argocdController: { min: 2, max: 2 }, // already 2; pinned stable
            argocdNotifications: { min: 1, max: 1 }, // singleton controller
            certManager: { min: 1, max: 2 },
            certManagerWebhook: { min: 1, max: 2 }, // admission path — most HA-relevant
            certManagerCainjector: { min: 1, max: 2 },
            sealedSecrets: { min: 1, max: 2 },
        } as Record<string, { min: number; max: number }>,
    },
    dns: {
        zoneName: baseDomain,
        baseDomain,
        subdomain,
        tld: `${subdomain}.${baseDomain}`,
    },
    // ─────────────────────────────────────────────────────────────────────────────
    // Nodes (2026-06-12)
    // Server types at hetzner:
    // hcloud server-type list -o columns=name,location,cores,memory | awk '$2 ~ /fsn1/ {print}'
    //
    // Cost-Optimized:
    // CX23 (2CPU/4GB/40GB) 4€
    // CX33 (4CPU/8GB/80GB) 6,5€
    // CX43 (8CPU/16GB/160GB) 12€
    // CX53 (16CPU/32GB/320GB) 22,5€

    // regular performance:
    // CPX22 (2CPU/4GB/80GB) 8€
    // CPX32 (4CPU/8GB/160GB) 14€
    // CPX42 (8CPU/16GB/320GB) 25,5€
    // CPX52 (12CPU/24GB/480GB) 35,5€
    // CPX62 (16CPU/32GB/640GB) 50,5€

    // Geneneral Purpose:
    // CCX13 (2CPU/8GB/80GB) 16€
    // CCX23 (4CPU/16GB/160GB) 31,5€
    // CCX33 (8CPU/32GB/240GB) 62,49€

    // Locations: fsn1 (Falkenstein)  nbg1 (Nürnberg)  hel1 (Helsinki)
    // WARNING: SSD volumes must be in the same location as the nodes that use them.
    // ─────────────────────────────────────────────────────────────────────────────
    nodes: {
        controlPlane: [
            {
                id: "cp0",
                serverType: "CPX32",
                // serverType: "CX33",
                location: "fsn1",
                swap: 16, // GiB
                swapBehavior: "LimitedSwap", // see SwapBehavior type (NoSwap | LimitedSwap)
            },
            {
                id: "cp1",
                serverType: "CPX32",
                location: "fsn1",
                swap: 16, // GiB
                swapBehavior: "LimitedSwap", // see SwapBehavior type (NoSwap | LimitedSwap)
            },
            {
                id: "cp2",
                serverType: "CPX32",
                location: "fsn1",
                swap: 16, // GiB
                swapBehavior: "LimitedSwap", // see SwapBehavior type (NoSwap | LimitedSwap)
            },
        ] as ComputeNode[],
        workers: [
            {
                id: "w0",
                serverType: "CPX32",
                location: "fsn1",
                swap: 16, // GiB
                swapBehavior: "LimitedSwap", // see SwapBehavior type (NoSwap | LimitedSwap)
            },
        ] as ComputeNode[],
        // On-premise edge nodes (SSH-provisioned, not hcloud). Provisioned by a
        // second pass: `make provision-edge [ARGS=<id>]` (NOT during `make create`,
        // since the VPN/mesh isn't up until ~15 min after pulumi finishes).
        edge: [
            {
                id: "cape-vm-lab",
                sshHost: "epi.techfak.uni-bielefeld.de",
                sshPort: 1717,
                sshUser: "cape",
                location: "unibi-lab",
                kvm: false,
            },
            {
                id: "pcie6-server-lab",
                sshHost: "epi.techfak.uni-bielefeld.de",
                sshPort: 3001,
                sshUser: "cape",
                location: "unibi-lab",
                kvm: true,
            },
            {
                id: "pcie6-desktop-lab",
                sshHost: "epi.techfak.uni-bielefeld.de",
                sshPort: 3002,
                sshUser: "cape",
                location: "unibi-lab",
                kvm: true,
            },
            {
                // only accessible when connected via VPN to martin's home network
                id: "minipc-martin",
                sshHost: "192.168.178.150",
                sshPort: 22,
                sshUser: "cape",
                location: "martinHome",
                kvm: true,
            },
            {
                // only accessible when connected via VPN to martin's home network
                id: "cape-vm-martin",
                sshHost: "192.168.178.83",
                sshPort: 22,
                sshUser: "cape",
                location: "martinHome",
                kvm: false,
            },
        ] as EdgeNode[],
    },
    storage: {
        longhorn: {
            // "auto": min(3, cloudNodeCount) — replicas never exceed cloud node count
            //         (soft anti-affinity), so redundancy grows as cloud nodes are added.
            // 1 | 2 | 3: explicit override regardless of node count.
            // The effective count is derived from node topology in src/storage.ts.
            // Pinned to 1: the cloud tier is kept deliberately lean (1 small CP + 1
            // small worker) to control cost — the worker disk (CPX32, ~118Gi) is far
            // too small to hold a full mirror of the ~270Gi the apps provision, so
            // replica=2 over-commits it (DiskPressure → faulted volumes). Capacity and
            // redundancy are intended to come from edge nodes (e.g. pcie6-server), not
            // more cloud servers. Raise this only after adding a larger cloud node.
            replicaCount: 1 as LonghornReplicaCount,
        },
        objectStorage: {
            baseEndpoint: "nbg1.your-objectstorage.com",
            // Pulumi-owned buckets only — cluster infra that exists BEFORE ArgoCD:
            //   etcd           — k3s etcd-S3 snapshots (configured in nodes-k3s-cloud.ts)
            //   longhornBackup — Longhorn BackupTarget (src/storage.ts)
            // Each ArgoCD-deployed APP now owns its own bucket via a Sync-hook Job
            // co-located with its manifests (deployment/{apps,infra}/<app>/s3-buckets-job.yaml):
            //   gitlab, nextcloud, authentik, headscale, zulip(+avatars).
            // Full-teardown wipe of ALL live buckets: scripts/environment/deleteS3Buckets.sh.
            buckets: [
                { key: "etcd", name: `${clusterName}-etcd`, location: "nbg1" },
                { key: "longhornBackup", name: `${clusterName}-longhorn-backup`, location: "nbg1" },
            ],
            accessKey: projectConfig.requireSecret("hetznerS3AccessKey"),
            secretKey: projectConfig.requireSecret("hetznerS3SecretKey"),
        },
    },
    mail: {
        // All mail settings live in the Pulumi stack (set via scripts/secrets/setMailCredentials.sh):
        //   smtpServer, smtpPort, smtpUsername, smtpPassword
        // requireSecret so the hostname stays encrypted in Pulumi.mystack.yaml (public
        // repo). NB it's still published in the public SPF DNS record (see src/dns.ts).
        smtpRelay: projectConfig.requireSecret("smtpServer"),
        spfInclude: "",
    },
    wireguard: {
        subDomain: "wg",
        vpnSubnet: "10.0.2.0/24",
        serverAddr: "10.0.2.1/24",
        adminAddr: "10.0.2.2/32",
        wgServerPrivateKey: projectConfig.requireSecret("wgServerPrivateKey"),
        wgServerPublicKey: projectConfig.requireSecret("wgServerPublicKey"),
        wgAdminPrivateKey: projectConfig.requireSecret("wgAdminPrivateKey"),
        wgAdminPublicKey: projectConfig.requireSecret("wgAdminPublicKey"),
    },
    pulumiHelloWorld: {
        enabled: false,
        subdomain: "pulumi-hello-world",
    },
    argocd: {
        enabled: true,
        githubDeployKey: projectConfig.requireSecret("argocdGithubDeployKey"),
        serverSecretKey: projectConfig.requireSecret("argocdServerSecretKey"),
        adminPasswordPlain: projectConfig.requireSecret("argocdAdminPasswordPlain"),
        adminPasswordHash: projectConfig.requireSecret("argocdAdminPasswordHash"),
        adminPasswordMtime: projectConfig.requireSecret("argocdAdminPasswordMtime"),
        serverTlsCert: projectConfig.getSecret("argocdServerTlsCert"),
        serverTlsKey: projectConfig.getSecret("argocdServerTlsKey"),
        gitRepoUrl: "git@github.com:paraXent/infra.git",
    },
};
