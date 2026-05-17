// Shared domain types used across all modules.
import * as pulumi from "@pulumi/pulumi";

export type ClusterOS = "Talos" | "debian-13" | "ubuntu-24.04";
export type LoadBalancerProvider = "hetzner-ccm" | "k3s-servicelb";
export type ROLLOUT_TYPE = "Testing" | "Production" | "Bootstrap";
export type CERT_TYPE = "letsencrypt-production" | "letsencrypt-staging";

export interface ComputeNode {
    id: string;
    serverType: string;
    location: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// General
// ─────────────────────────────────────────────────────────────────────────────
const baseDomain = "your-domain.tld"; //
const subdomain = "test"; // adapt/increment to avoid hitting Let's Encrypt rate limits and DNS caching issues (see README.md)
const projectConfig = new pulumi.Config();

export const project_settings = {
    general: {
        name: "edgecloudinfra".toLowerCase(),
        baseDomain,
        subdomain,
        timezone: "Europe/Berlin",
        rolloutType: "Testing" as ROLLOUT_TYPE,
        completeClusterTeardown: true,
    },
    server: {
        serverSshKey: "sshkey_ed25519_pxCloudEdgeInfra_Martin",
        os: "debian-13" as ClusterOS,
        talosVersion: "v1.13.2", // renovate: datasource=github-releases depName=siderolabs/talos
        talosKubernetesVersion: "1.36.1", // renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
        loadBalancerProvider: "k3s-servicelb" as LoadBalancerProvider,
        backupClusterToS3: true,
        backupClusterToS3IntervalHour: 1,
        restoreClusterFromS3Backup: false,
        hcloudToken: projectConfig.requireSecret("hcloudToken"),
    },
    tls: {
        certIssuerType: "letsencrypt-staging" as CERT_TYPE,
        letsEncrypt: { email: "it@cape-project.eu" },
        wildcardTlsCert: projectConfig.getSecret("wildcardTlsCert"),
        wildcardTlsKey: projectConfig.getSecret("wildcardTlsKey"),
        sealedSecretsTlsCrt: projectConfig.requireSecret("sealedSecretsTlsCrt"),
        sealedSecretsTlsKey: projectConfig.requireSecret("sealedSecretsTlsKey"),
    },
    network: {
        privateRange: "10.0.0.0/16",
        subnetRange: "10.0.0.0/23",
        gateway: "10.0.0.1",
    },
    dns: {
        zoneName: baseDomain,
        baseDomain,
        subdomain,
        tld: `${subdomain}.${baseDomain}`,
    },
    // ─────────────────────────────────────────────────────────────────────────────
    // Nodes (2026-04-04)
    // Server types at hetzner:
    // hcloud server-type list -o columns=name,location,cores,memory | awk '$2 ~ /fsn1/ {print}'
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
    nodes: {
        controlPlane: [
            {
                id: "cp0",
                // serverType: "CX53",
                serverType: "CPX62",
                location: "fsn1",
            },
            // {
            //     id: "cp1",
            //     serverType: "CPX62",
            //     location: "fsn1",
            // },
        ] as ComputeNode[],
        workers: [
            {
                id: "w0",
                // serverType: "CX53",
                serverType: "CPX62",
                location: "fsn1",
            },
        ] as ComputeNode[],
    },
    storage: {
        blockStorage: {
            // reserved for future use
        },
        objectStorage: {
            baseEndpoint: "nbg1.your-objectstorage.com",
            buckets: [
                { key: "etcd", name: "edgecloud-etcd", location: "nbg1" },
                { key: "longhornBackup", name: "edgecloud-longhorn-backup", location: "nbg1" },
                { key: "gitlab", name: "edgecloud-gitlab", location: "nbg1" },
                { key: "nextcloud", name: "edgecloud-nextcloud", location: "nbg1" },
                { key: "headscale", name: "edgecloud-headscale", location: "nbg1" },
                { key: "mattermost", name: "edgecloud-mattermost", location: "nbg1" },
                { key: "zulip", name: "edgecloud-zulip", location: "nbg1" },
            ],
            accessKey: projectConfig.requireSecret("hetznerS3AccessKey"),
            secretKey: projectConfig.requireSecret("hetznerS3SecretKey"),
        },
    },
    mail: { smtpRelay: "mail.your-server.de", spfInclude: "" },
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
        enabled: true,
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
