import type {
    ClusterOS,
    LoadBalancerProvider,
    ROLLOUT_TYPE,
    CERT_TYPE,
    ControlPlaneNode,
    WorkerNode,
} from "./src/types";

// Re-export types so callers can import them from one place.
export type {
    ClusterOS,
    LoadBalancerProvider,
    ROLLOUT_TYPE,
    CERT_TYPE,
    ControlPlaneNode,
    WorkerNode,
};

// ─────────────────────────────────────────────────────────────────────────────
// Cluster
// ─────────────────────────────────────────────────────────────────────────────
const _clusterName = "edgecloudinfra"; // TODO @user: adapt

export const cluster = {
    name: _clusterName,
    nameLower: _clusterName.toLowerCase(), // K8s normalises node names to lowercase
    baseDomain: "your-domain.tld", // TODO @user: adapt
    testSubdomainPrefix: "test", // TODO @user: adapt
    testNumber: 34, // // TODO @user: adapt increment for each test to avoid hitting Let's Encrypt rate limits and DNS caching issues (see README.md)
    rolloutType: "Testing" as ROLLOUT_TYPE, // TODO @user: adapt. First use "Bootstrap", then "Production" (alternatively try "Testing" before as tesing uses letsencrpy staging certs)
    serverSshKey: "sshkey_ed25519_pxCloudEdgeInfra_Martin", // TODO @user: adapt  Hetzner SSH key name registered in the cloud project.
    os: "debian-13" as ClusterOS, // TODO @user: adapt  "Talos" (immutable, API-managed) | "debian-13" (Ubuntu 24.04 + K3s)
    certIssuerType: "letsencrypt-staging" as CERT_TYPE, // "letsencrypt-production" | "letsencrypt-staging"
    talosVersion: "v1.12.5",
    talosKubernetesVersion: "1.32.0",
    timezone: "Europe/Berlin", // TODO @user: adaptimezone applied to Debian/Ubuntu nodes during cloud-init bootstrap.
    loadBalancerProvider: "k3s-servicelb" as LoadBalancerProvider, // "hetzner-ccm" (managed Hetzner LBs, billable) | "k3s-servicelb" (built-in, no extra cost)

    backupClusterToS3: true, // Enable built-in K3s etcd snapshots to S3.
    backupClusterToS3Interval: 1, // Snapshot interval in hours (used as: 0 */N * * *).
    restoreClusterFromS3Backup: false, // Restore latest etcd snapshot from S3 on server setup. Reset to false after successful restore.

    enableArgoCD: true, // set to false for a highly stripped environment for testing

    completeClusterTeardown: true, // DANGEROUS: if set to true ALL resource including SSD Volumes will be deleted!
};

// ─────────────────────────────────────────────────────────────────────────────
// Shared external service settings
// ─────────────────────────────────────────────────────────────────────────────
export const github = {
    repoUrl: "git@github.com:owner/repo.git",
};

export const letsEncrypt = {
    email: "admin@your-domain.tld",
};

const usesTestingSubdomains = cluster.rolloutType === "Testing";

// ─────────────────────────────────────────────────────────────────────────────
// Network
// ─────────────────────────────────────────────────────────────────────────────
export const network = {
    privateRange: "10.0.0.0/16",
    subnetRange: "10.0.1.0/24",
    gateway: "10.0.0.1",
};

// ─────────────────────────────────────────────────────────────────────────────
// DNS
// ─────────────────────────────────────────────────────────────────────────────
const _testSubdomain = usesTestingSubdomains
    ? `${cluster.testSubdomainPrefix}${cluster.testNumber}`
    : "";

const joinDomain = (subdomain: string, baseDomain: string): string =>
    subdomain ? `${subdomain}.${baseDomain}` : baseDomain;

export const dns = {
    zoneName: cluster.baseDomain,
    baseDomain: cluster.baseDomain,
    testNumber: cluster.testNumber,
    testSubdomain: _testSubdomain,
    tld: joinDomain(_testSubdomain, cluster.baseDomain),
};

// ─────────────────────────────────────────────────────────────────────────────
// Nodes (2026-04-04)
// Server types:
//
// Cost-Optimized:
// CX23 (2CPU/4GB/40GB) 3€
// CX33 (4CPU/8GB/80GB) 5€
// CX43 (8CPU/16GB/160GB) 9€
// CX53 (16CPU/32GB/320GB) 16€

// regular performance:
// CPX22 (2CPU/4GB/80GB) 6€
// CPX32 (4CPU/8GB/160GB) 10€
// CPX42 (8CPU/16GB/320GB) 20€
// CPX52 (12CPU/24GB/480GB) 28€
// CPX62 (16CPU/32GB/640GB) 38€

// Geneneral Purpose:
// CCX13 (2CPU/8GB/80GB) 12€
// CCX23 (4CPU/16GB/160GB) 24€
// CCX33 (8CPU/32GB/240GB) 48€

// Locations: fsn1 (Falkenstein)  nbg1 (Nürnberg)  hel1 (Helsinki)
// WARNING: SSD volumes must be in the same location as the nodes that use them.
// ─────────────────────────────────────────────────────────────────────────────
export const nodes = {
    // 3 CP nodes for HA: quorum=2, rolling upgrades never lose quorum.
    // TODO @user: adapt.
    controlPlane: [
        { id: "cp0", serverType: "CX53", location: "fsn1" }, // cp0 is mandatory!
        { id: "cp1", serverType: "CX53", location: "fsn1" }, // for HA, this should be the same as cp0
        // { id: "cp2", serverType: "CX53", location: "nbg1" }, // third CP in different DC for resilience
    ] as ControlPlaneNode[],
    workers: [
        // { id: "w0", serverType: "CX53", location: "fsn1" },
        // { id: "w1", serverType: "CX53", location: "fsn1" },
    ] as WorkerNode[],
};

// ─────────────────────────────────────────────────────────────────────────────
// Storage
// ─────────────────────────────────────────────────────────────────────────────
export const blockStorage = {
    // Backing SSD volume for the in-cluster NFS server (hcloud-nfs-ssd-volumes StorageClass).
    // Must be in the same location as the control plane node that runs the NFS pod.
    nfsSsdVolumeSize: "100Gi", // resize via: hcloud volume resize <id> --size <new>
};

// ─────────────────────────────────────────────────────────────────────────────
// Hetzner S3 Object Storage
// ─────────────────────────────────────────────────────────────────────────────
export const objectStorage = {
    // Base endpoint for Hetzner Object Storage (region host, no bucket prefix).
    baseEndpoint: "nbg1.your-objectstorage.com", // TODO @user: adapt.
    // Bucket for K3s / Talos etcd snapshots.
    etcdBucketName: "edgecloud-etcd", // TODO @user: adapt.
};

// ─────────────────────────────────────────────────────────────────────────────
// Storagebox
// ─────────────────────────────────────────────────────────────────────────────
export const backupStorage = {
    host: "u445411.your-storagebox.de", // TODO @user: adapt.
    user: "u445411-sub3", // TODO @user: adapt.
};

// ─────────────────────────────────────────────────────────────────────────────
// WireGuard VPN
// ─────────────────────────────────────────────────────────────────────────────
export const wireguard = {
    subDomain: "wg",
    vpnSubnet: "10.0.2.0/24",
    serverAddr: "10.0.2.1/24",
    adminAddr: "10.0.2.2/32",
};

// ─────────────────────────────────────────────────────────────────────────────
// Feature Flags
// ─────────────────────────────────────────────────────────────────────────────
export const features = {
    enablePulumiHelloWorld: false,
    // Test pods that validate each StorageClass
    enableTestS3Storage: false,
    enableTestSsdVolume: false,
    enableTestSsdVolumeNfs: false,
};
