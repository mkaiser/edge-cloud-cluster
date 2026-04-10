/**
 * Project: edgecloudinfra
 * File: index.ts
 * Purpose: Pulumi program entry point and infrastructure orchestration.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

// Pulumi program entry point — orchestration only.
// Infrastructure configuration lives in project_settings.ts.
// Each component lives in src/<module>.ts.
// Pulumi API docs: https://www.pulumi.com/registry/packages/hcloud/

import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";

import {
    cluster,
    network as networkSettings,
    dns,
    nodes,
    blockStorage,
    objectStorage,
    wireguard,
    features,
    github,
    letsEncrypt,
    backupStorage,
} from "./project_settings";
import { pulumi_secrets } from "./src/pulumi_secrets";

import { NetworkComponent } from "./src/network";
import { K3sNodesComponent } from "./src/nodes/k3s";
import { TalosNodesComponent } from "./src/nodes/talos";
import { StorageComponent } from "./src/storage";
import { DnsComponent } from "./src/dns";
import { CertManagerComponent } from "./src/certmanager";
import { IngressComponent } from "./src/ingress";
import { ExternalDnsComponent } from "./src/externaldns";
import { SealedSecretsComponent } from "./src/sealedsecrets";
import { ArgoCDComponent } from "./src/argocd";
import { WireguardComponent } from "./src/wireguard";
import { HelloPulumiComponent } from "./src/hellopulumi";

// Hetzner provider
const hProvider = new hcloud.Provider("hcloud", { token: pulumi_secrets.hcloudToken });

/////////////////////
// Network & Firewall
/////////////////////
const networkComponent = new NetworkComponent("network", {
    cluster,
    network: networkSettings,
    hProvider,
});

/////////////////////
// Nodes (OS-specific)
/////////////////////
const nodesSharedArgs = {
    cluster,
    controlPlaneNodes: nodes.controlPlane,
    workerNodes: nodes.workers,
    network: networkComponent.network,
    firewall: networkComponent.firewall,
    hProvider,
    networkSettings: {
        privateRange: networkSettings.privateRange,
        gateway: networkSettings.gateway,
    },
    objectStorageSettings: {
        baseEndpoint: objectStorage.baseEndpoint,
        bucketName: objectStorage.etcdBucketName,
        bucketFolderEtcd: cluster.os === "Talos" ? "talos-etcd" : "k3s-etcd",
    },
    pulumiSecrets: pulumi_secrets,
};

const nodesComponent =
    cluster.os === "Talos"
        ? new TalosNodesComponent("nodes", {
              ...nodesSharedArgs,
              talosVersion: cluster.talosVersion,
              kubernetesVersion: cluster.talosKubernetesVersion,
          })
        : new K3sNodesComponent("nodes", {
              ...nodesSharedArgs,
              backupClusterToS3: cluster.backupClusterToS3,
              etcdBucketName: objectStorage.etcdBucketName,
              backupClusterToS3Interval: cluster.backupClusterToS3Interval,
          });

const { controlPlane, controlPlanePrivateIp, k8sProvider, additionalCpNodes, kubeconfigRaw } =
    nodesComponent;
// machineSecrets only exists on the Talos component — cast so TypeScript knows the shape.
const machineSecrets =
    cluster.os === "Talos" ? (nodesComponent as TalosNodesComponent).machineSecrets : undefined;

const platformContext = {
    k8sProvider,
    kubeconfigRaw,
    pulumiSecrets: pulumi_secrets,
};

/////////////////////
// Storage
/////////////////////

new StorageComponent("storage", {
    k8sProvider,
    hProvider,
    network: networkComponent.network,
    pulumiSecrets: pulumi_secrets,
    cluster,
    controlPlaneNodes: nodes.controlPlane,
    objectStorage,
    backupStorage,
    blockStorage,
    features,
});

/////////////////////
// DNS
/////////////////////

new DnsComponent("dns", {
    hProvider,
    dns,
    controlPlane,
    additionalCpNodes,
});

/////////////////////
// Cert Manager
/////////////////////

const certManager = new CertManagerComponent("cert-manager", {
    ...platformContext,
    letsEncrypt,
});

const certIssuers = {
    letsEncryptStagingIssuer: certManager.letsEncryptStagingIssuer,
    letsEncryptProdIssuer: certManager.letsEncryptProdIssuer,
};

/////////////////////
// HAProxy Ingress
/////////////////////

const ingress = new IngressComponent("ingress", {
    k8sProvider,
    kubeconfigRaw,
    controlPlane,
    additionalCpNodes,
    certIssuers,
});

/////////////////////
// External DNS
/////////////////////

new ExternalDnsComponent("external-dns", { k8sProvider, pulumiSecrets: pulumi_secrets });

/////////////////////
// Sealed Secrets + etcd backup credentials
/////////////////////

const sealedSecrets = new SealedSecretsComponent("sealed-secrets", {
    k8sProvider,
    pulumiSecrets: pulumi_secrets,
});

/////////////////////
// OpenDesk secrets (injected into ArgoCD CMP env, not stored in git plaintext)
/////////////////////

// Credentials for the Nextcloud S3 object store
// Referenced by name in the ArgoCD Application plugin env (valueFrom.secretKeyRef).
new k8s.core.v1.Secret(
    "hetzner-s3",
    {
        metadata: { name: "hetzner-s3", namespace: "argocd" },
        stringData: {
            accessKey: pulumi_secrets.hetznerS3AccessKey,
            secretKey: pulumi_secrets.hetznerS3SecretKey,
        },
    },
    { provider: k8sProvider },
);

/////////////////////
// ArgoCD
/////////////////////

let argocdComponent: ArgoCDComponent | undefined;

if (cluster.enableArgoCD) {
    argocdComponent = new ArgoCDComponent("argocd", {
        ...platformContext,
        controlPlane,
        settings: {
            tld: dns.tld,
            certIssuerType: cluster.certIssuerType,
            githubRepoUrl: github.repoUrl,
            completeClusterTeardown: cluster.completeClusterTeardown,
        },
        dependencies: {
            waitForHaproxyIngress: ingress.waitForHaproxyIngress,
            waitForCertManager: certManager.waitForCertManager,
            sealedSecretsChart: sealedSecrets.sealedSecretsChart,
        },
    });
}

/////////////////////
// Hello Pulumi (debug demo)
/////////////////////

let helloPulumiComponent: HelloPulumiComponent | undefined;

if (features.enablePulumiHelloWorld) {
    helloPulumiComponent = new HelloPulumiComponent("hello-pulumi", {
        k8sProvider,
        dns,
        ingress: {
            haproxyIngress: ingress.haproxyIngress,
            waitForHaproxyIngress: ingress.waitForHaproxyIngress,
        },
        certManager: {
            waitForCertManager: certManager.waitForCertManager,
            certIssuerType: cluster.certIssuerType,
            ...certIssuers,
        },
    });
}

/////////////////////
// WireGuard VPN
/////////////////////

const wireguardComponent = new WireguardComponent("wireguard", {
    k8sProvider,
    pulumiSecrets: pulumi_secrets,
    wireguard,
    dns,
});

/////////////////////
// Outputs — view with: pulumi stack output [--show-secrets]
/////////////////////

// Talos-specific
export const connectTalosctlCommand =
    cluster.os === "Talos"
        ? pulumi.interpolate`talosctl --talosconfig <(pulumi stack output talosconfig --show-secrets) --nodes ${controlPlane.ipv4Address} --endpoints ${controlPlane.ipv4Address}`
        : "N/A (Debian/K3s — use SSH instead)";

export const talosconfig =
    cluster.os === "Talos" && machineSecrets !== undefined
        ? pulumi.secret(
              pulumi
                  .all([machineSecrets.clientConfiguration, controlPlane.ipv4Address])
                  .apply(([cc, nodeIp]) =>
                      JSON.stringify({
                          context: "default",
                          contexts: {
                              default: {
                                  endpoints: [nodeIp],
                                  nodes: [nodeIp],
                                  ca: cc.caCertificate,
                                  crt: cc.clientCertificate,
                                  key: cc.clientKey,
                              },
                          },
                      }),
                  ),
          )
        : "N/A (Debian/K3s)";

// Debian-specific
export const connectSshControlPlaneCommand =
    cluster.os !== "Talos"
        ? pulumi.interpolate`ssh root@${controlPlane.ipv4Address} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`
        : "N/A (Talos — use talosctl instead)";

// Common
export const controlPlaneIP = controlPlane.ipv4Address;
export const networkID = networkComponent.network.id;
export const kubeconfig = pulumi.secret(kubeconfigRaw);
export const kubeconfigVpn = pulumi.secret(
    pulumi
        .all([kubeconfigRaw, controlPlanePrivateIp])
        .apply(([kc, privateIp]) =>
            kc.replace(/https:\/\/[^:]+:6443/g, `https://${privateIp}:6443`),
        ),
);
export const controlPlanePrivateIP = controlPlanePrivateIp;
export const kubeConfigCmd =
    "mkdir -p ~/.kube && pulumi stack output kubeconfig --show-secrets > ~/.kube/config";

export const hetznerS3BaseEndpoint = objectStorage.baseEndpoint;
export const hetznerS3EtcdBucket = objectStorage.etcdBucketName;
export const certIssuerType = cluster.certIssuerType;

export const argocdURL = cluster.enableArgoCD
    ? pulumi.interpolate`https://${argocdComponent!.url}`
    : "ArgoCD disabled";
export const argocdCliCommand = cluster.enableArgoCD
    ? argocdComponent!.cliLoginCommand
    : "ArgoCD disabled";

export const wireguardSaveConfig = pulumi.interpolate`pulumi stack output wireguardClientConfig --show-secrets > wg-admin.conf`;

// WireGuard admin client config — copy to ~/.config/wireguard/wg0.conf or import into your WireGuard client.
// Routes only the cluster subnet through the VPN.
export const wireguardClientConfig = pulumi.secret(pulumi.interpolate`[Interface]
Address = ${wireguard.adminAddr}
PrivateKey = ${pulumi_secrets.wgAdminPrivateKey}

[Peer]
PublicKey = ${pulumi_secrets.wgServerPublicKey}
Endpoint = ${wireguardComponent.url}:51820
AllowedIPs = ${wireguard.vpnSubnet}, ${networkSettings.privateRange}
PersistentKeepalive = 25
`);

export const helloPulumi = features.enablePulumiHelloWorld
    ? `https://${helloPulumiComponent!.url}`
    : "Hello World example disabled";
