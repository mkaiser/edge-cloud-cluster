/**
 * Project: edgecloudinfra
 * File: main.ts
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

import { project_settings } from "./project_settings";

import { NetworkComponent } from "./src/network";
import { K3sNodesComponent } from "./src/nodes-k3s";
import { TalosNodesComponent } from "./src/nodes-talos";
import { StorageComponent } from "./src/storage";
import { DnsComponent } from "./src/dns";
import { CertManagerComponent } from "./src/certmanager";
import { IngressComponent } from "./src/ingress";
import { ExternalDnsComponent } from "./src/externaldns";
import { SealedSecretsComponent } from "./src/sealedsecrets";
import { ArgoCDComponent } from "./src/argocd";
import { WireguardComponent } from "./src/wireguard";
import { pulumiHelloWorldComponent } from "./src/pulumiHelloWorld";

// Hetzner provider
const hProvider = new hcloud.Provider("hcloud", { token: project_settings.server.hcloudToken });

/////////////////////
// Network & Firewall
/////////////////////
const networkComponent = new NetworkComponent("network", hProvider, project_settings);

/////////////////////
// Nodes (OS-specific)
/////////////////////
const nodesComponent =
    project_settings.server.os === "Talos"
        ? new TalosNodesComponent("nodes", networkComponent, hProvider)
        : new K3sNodesComponent("nodes", networkComponent, hProvider);

const { controlPlane, k8sProvider, additionalCpNodes, cloudWorkers, kubeconfigRaw } =
    nodesComponent;

// machineSecrets only exists on the Talos component — cast so TypeScript knows the shape.
const machineSecrets =
    project_settings.server.os === "Talos"
        ? (nodesComponent as TalosNodesComponent).machineSecrets
        : undefined;

/////////////////////
// Storage
/////////////////////

new StorageComponent("storage", k8sProvider, networkComponent);

/////////////////////
// DNS
/////////////////////

new DnsComponent("dns", hProvider, project_settings, controlPlane, additionalCpNodes);

/////////////////////
// Cert Manager
/////////////////////

const certManager = new CertManagerComponent(
    "cert-manager",
    k8sProvider,
    kubeconfigRaw,
    project_settings,
);

/////////////////////
// HAProxy Ingress
/////////////////////

const ingress = new IngressComponent(
    "ingress",
    k8sProvider,
    kubeconfigRaw,
    controlPlane,
    additionalCpNodes,
    certManager.certIssuers,
);

/////////////////////
// External DNS
/////////////////////

new ExternalDnsComponent("external-dns", k8sProvider);

/////////////////////
// Sealed Secrets + etcd backup credentials
/////////////////////

const sealedSecrets = new SealedSecretsComponent("sealed-secrets", k8sProvider);

/////////////////////
// OpenDesk secrets (injected into ArgoCD CMP env, not stored in git plaintext)
/////////////////////

// Credentials for the Nextcloud S3 object store
new k8s.core.v1.Secret(
    "hetzner-s3",
    {
        metadata: { name: "hetzner-s3", namespace: "argocd" },
        stringData: {
            accessKey: project_settings.storage.objectStorage.accessKey,
            secretKey: project_settings.storage.objectStorage.secretKey,
        },
    },
    { provider: k8sProvider },
);

/////////////////////
// ArgoCD
/////////////////////

let argocdComponent: ArgoCDComponent | undefined;

if (project_settings.argocd.enabled) {
    argocdComponent = new ArgoCDComponent(
        "argocd",
        k8sProvider,
        kubeconfigRaw,
        controlPlane,
        project_settings,
        {
            waitForHaproxyIngress: ingress.waitForHaproxyIngress,
            waitForCertManager: certManager.waitForCertManager,
            sealedSecretsChart: sealedSecrets.sealedSecretsChart,
        },
    );
}

/////////////////////
// Pulumi Hello World (debug demo)
/////////////////////

let pulumiHelloWorldComponentInstance: pulumiHelloWorldComponent | undefined;

if (project_settings.pulumiHelloWorld.enabled) {
    pulumiHelloWorldComponentInstance = new pulumiHelloWorldComponent(
        "hello-pulumi",
        k8sProvider,
        project_settings,
        {
            haproxyIngress: ingress.haproxyIngress,
            waitForHaproxyIngress: ingress.waitForHaproxyIngress,
        },
        {
            waitForCertManager: certManager.waitForCertManager,
            letsEncryptStagingIssuer: certManager.letsEncryptStagingIssuer,
            letsEncryptProdIssuer: certManager.letsEncryptProdIssuer,
        },
    );
}

/////////////////////
// WireGuard VPN
/////////////////////

const wireguardComponent = new WireguardComponent("wireguard", k8sProvider, project_settings);

/////////////////////
// Outputs — view with: pulumi stack output [--show-secrets]
/////////////////////

// Talos-specific
export const connectTalosctlCommand =
    project_settings.server.os === "Talos"
        ? pulumi.interpolate`talosctl --talosconfig <(pulumi stack output talosconfig --show-secrets) --nodes ${controlPlane.ipv4Address} --endpoints ${controlPlane.ipv4Address}`
        : "N/A (Debian/K3s — use SSH instead)";

export const talosconfig =
    project_settings.server.os === "Talos" && machineSecrets !== undefined
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
    project_settings.server.os !== "Talos"
        ? pulumi.interpolate`ssh root@${controlPlane.ipv4Address} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`
        : "N/A (Talos — use talosctl instead)";

// Common
export const server_controlPlaneIPs_compact = pulumi
    .all(
        [controlPlane, ...(additionalCpNodes || [])].map((cp) => ({
            name: cp.name,
            ipv4: cp.ipv4Address,
            ipv6: cp.ipv6Address,
        })),
    )
    .apply((nodes) =>
        nodes
            .map((node) => `name: ${node.name}, ipv4: ${node.ipv4}, ipv6: ${node.ipv6}`)
            .join("\n"),
    );
export const server_workerNodeIPs_compact = pulumi
    .all(
        cloudWorkers.map((worker) => ({
            name: worker.name,
            ipv4: worker.ipv4Address,
            ipv6: worker.ipv6Address,
        })),
    )
    .apply((nodes) =>
        nodes.map(
            (node, index) =>
                `number: ${index}, name: "${node.name}", ipv4: "${node.ipv4}", ipv6: "${node.ipv6}"`,
        ),
    );
export const hetznerNetworkID = networkComponent.network.id;
export const kubeconfig = pulumi.secret(kubeconfigRaw);

export const kubeConfigCmd =
    "mkdir -p ~/.kube && pulumi stack output kubeconfig --show-secrets 2>/dev/null > ~/.kube/config";

export const certIssuerType = project_settings.tls.certIssuerType;

export const argocdURL = project_settings.argocd.enabled
    ? pulumi.interpolate`https://${argocdComponent!.url}`
    : "ArgoCD disabled";
export const argocdCliCommand = project_settings.argocd.enabled
    ? argocdComponent!.cliLoginCommand
    : "ArgoCD disabled";
export const argocdAdminPasswordPlain = "pulumi config get argocdAdminPasswordPlain";

// WireGuard admin client config — copy to ~/.config/wireguard/wg0.conf or import into your WireGuard client.
// Routes only the cluster subnet through the VPN.
export const wireguardClientConfig = pulumi.secret(pulumi.interpolate`[Interface]
Address = ${project_settings.wireguard.adminAddr}
PrivateKey = ${project_settings.wireguard.wgAdminPrivateKey}

[Peer]
PublicKey = ${project_settings.wireguard.wgServerPublicKey}
Endpoint = ${wireguardComponent.url}:51820
AllowedIPs = ${project_settings.wireguard.vpnSubnet}, ${project_settings.network.privateRange}
PersistentKeepalive = 25
`);

export const pulumiHelloWorldURL = project_settings.pulumiHelloWorld.enabled
    ? pulumiHelloWorldComponentInstance!.urlOutput
    : "Pulumi Hello World example disabled";
