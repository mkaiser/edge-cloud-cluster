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

import { project_settings } from "./project_settings";
import { runtime_flags } from "./runtime_flags";

import { NetworkComponent } from "./src/network";
import { K3sNodesComponent } from "./src/nodes-k3s-dispatch";
import { CniComponent } from "./src/cni";
import { CoreDnsComponent } from "./src/coredns";
import { MeshNodesComponent } from "./src/nodes-k3s-mesh";
import { StorageComponent } from "./src/storage";
import { DnsComponent } from "./src/dns";
import { CertManagerComponent } from "./src/certmanager";
import { IngressComponent } from "./src/ingress";
import { ExternalDnsComponent } from "./src/externaldns";
import { SealedSecretsComponent } from "./src/sealedsecrets";
import { ArgoCDComponent } from "./src/argocd";
import { VipCutoverComponent } from "./src/vip-cutover";
import { WireguardComponent } from "./src/wireguard";
import { LonghornRestoreComponent } from "./src/longhorn-restore";

// Hetzner provider
const hProvider = new hcloud.Provider("hcloud", { token: project_settings.hetzner.hcloudToken });

async function main() {
    /////////////////////
    // Network & Firewall
    // Auto-import: if a network with this name survived a prior incomplete destroy,
    // pass its ID as the import target so Pulumi manages it instead of erroring.
    /////////////////////
    // enabled:false parks a node (never built) → skip it, else the network name could be
    // derived from a cloud node that will not exist. Must match src/network.ts exactly.
    const directNode = project_settings.nodes.cloud.find(
        (n) => n.clusterLink === "direct" && n.enabled !== false,
    );
    const networkName = directNode
        ? `${project_settings.general.name}-${directNode.site}`
        : `${project_settings.general.name}-net`;

    const netImports: { networkId?: string; serverSubnetId?: string; vswitchSubnetId?: string } =
        {};
    try {
        const existing = await hcloud.getNetwork({ name: networkName }, { provider: hProvider });
        netImports.networkId = String(existing.id);
        // Subnets survive an incomplete destroy and must be imported
        // (import id = "<network-id>-<ip_range>"). getNetwork() doesn't return subnets, so
        // query the Hetzner API directly and match by the configured ranges.
        const serverSubnetRange = project_settings.network.serverSubnetRange;
        const vswitchRange = project_settings.network.vswitchRange;
        // Resolve the secret token Output to a plain string for the REST call. requireSecret
        // wraps the configured value; read it back synchronously via a fresh Config.
        const token = new pulumi.Config().requireSecret("hcloudToken");
        const tokenValue = await new Promise<string>((resolve) => token.apply((t) => resolve(t)));
        const resp = await fetch(`https://api.hetzner.cloud/v1/networks/${existing.id}`, {
            headers: { Authorization: `Bearer ${tokenValue}` },
        });
        const subnets: { type: string; ip_range: string }[] = resp.ok
            ? ((await resp.json()).network?.subnets ?? [])
            : [];
        const hasServerSubnet = subnets.some(
            (s) => s.type === "server" && s.ip_range === serverSubnetRange,
        );
        const hasVswitchSubnet = subnets.some(
            (s) => s.type === "vswitch" && s.ip_range === vswitchRange,
        );
        if (hasServerSubnet) {
            netImports.serverSubnetId = `${existing.id}-${serverSubnetRange}`;
        }
        if (hasVswitchSubnet) {
            netImports.vswitchSubnetId = `${existing.id}-${vswitchRange}`;
        }
        const importedSubnets = [
            hasServerSubnet ? `server subnet ${serverSubnetRange}` : null,
            hasVswitchSubnet ? `vswitch subnet ${vswitchRange}` : null,
        ]
            .filter(Boolean)
            .join(", ");
        // debug (not info): the network is re-imported on every steady-state run — surfacing it
        // as a Diagnostic each `pulumi up` is pure noise. Kept for `pulumi up --debug`.
        pulumi.log.debug(
            `Found orphaned network '${networkName}' (ID: ${netImports.networkId}) — importing.` +
                (importedSubnets ? ` Also importing ${importedSubnets}.` : ""),
        );
    } catch {
        // Network doesn't exist — normal path on first create
    }

    const networkComponent = new NetworkComponent(
        "network",
        hProvider,
        project_settings,
        undefined,
        netImports,
    );

    /////////////////////
    // Nodes (OS-specific)
    /////////////////////
    const nodesComponent = new K3sNodesComponent("nodes", networkComponent, hProvider);

    const { controlPlane, k8sProvider, additionalCpNodes, cloudWorkers, kubeconfigRaw } =
        nodesComponent;

    /////////////////////
    // On-premise mesh nodes (second pass only)
    /////////////////////
    // Provisioned over SSH by `make provision-mesh-node` AFTER the cloud cluster + VPN mesh
    // are up — gated off by default so `make bootstrap` never attempts mesh-node SSH.
    if (runtime_flags.meshProvisioning.vpnReady) {
        new MeshNodesComponent("mesh-nodes", {
            kubeconfigRaw,
            // CP0 PRIVATE IP, not the public IP: mesh-fetch (_local-fetch-cluster-inputs.sh)
            // SSHes CP0 for the k3s node-token from the DEVCONTAINER over the admin WG
            // tunnel. In Production posture public SSH (22) is firewalled shut, so the
            // public IP fails ("cannot SSH root@<public>"); the private IP is WG-reachable
            // in BOTH postures.
            controlPlaneSshHost: nodesComponent.controlPlanePrivateIp,
        });
    }

    /////////////////////
    // CNI (Cilium) — MUST be the first k8s component.
    /////////////////////
    // k3s runs with flannel-backend: none, so until this chart is installed every node is
    // NotReady with no pod network and NOTHING else can schedule — including ArgoCD, which is
    // why the CNI is bootstrapped by Pulumi rather than only by an ArgoCD Application.
    // Everything below depends on it implicitly; the explicit dependsOn on storage makes the
    // ordering a hard edge rather than a lucky one.
    /////////////////////

    const cniComponent = new CniComponent("cni", k8sProvider);

    /////////////////////
    // CoreDNS — MUST be installed before anything that resolves a Service name.
    /////////////////////
    // k3s runs with `disable: coredns`, so until this chart is installed there is no cluster
    // DNS at all. ArgoCD cannot be the installer: it needs DNS to reach its own repo-server
    // and to fetch the chart. Longhorn is the first casualty downstream — its manager dies on
    // the admission webhook it cannot resolve. See src/coredns.ts.
    /////////////////////

    const coreDnsComponent = new CoreDnsComponent("coredns", k8sProvider, {
        dependsOn: [cniComponent],
    });

    /////////////////////
    // Storage
    /////////////////////

    const storageComponent = new StorageComponent(
        "storage",
        k8sProvider,
        networkComponent,
        kubeconfigRaw,
        // Longhorn's DaemonSets cannot become healthy on a node without a pod network, and its
        // manager resolves longhorn-admission-webhook through cluster DNS at startup.
        { dependsOn: [cniComponent, coreDnsComponent] },
    );

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
    // Gateway API Ingress (Envoy Gateway)
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

    const externalDns = new ExternalDnsComponent("external-dns", k8sProvider);

    /////////////////////
    // Sealed Secrets + etcd backup credentials
    /////////////////////

    const sealedSecrets = new SealedSecretsComponent("sealed-secrets", k8sProvider);

    /////////////////////
    // Longhorn volume restore (only when targetState is "restore")
    // Runs after Longhorn is up (storageComponent.longhornChart) but BEFORE ArgoCD
    // so restored PVCs are ready when application workloads start.
    /////////////////////

    let longhornRestore: LonghornRestoreComponent | undefined;
    if (project_settings.general.targetState === "restore") {
        longhornRestore = new LonghornRestoreComponent(
            "longhorn-restore",
            { kubeconfigRaw },
            {
                dependsOn: [storageComponent.longhornBackupTarget],
            },
        );
    }

    /////////////////////
    // ArgoCD
    /////////////////////

    const argocdComponent = new ArgoCDComponent(
        "argocd",
        k8sProvider,
        kubeconfigRaw,
        controlPlane,
        project_settings,
        {
            waitForGateway: ingress.waitForGateway,
            waitForCertManager: certManager.waitForCertManager,
            sealedSecretsChart: sealedSecrets.sealedSecretsChart,
        },
        longhornRestore ? { dependsOn: [longhornRestore] } : undefined,
    );

    /////////////////////
    // VIP cutover (post-ArgoCD) — repoint nodes/kubeconfig/WG from the init-CP IP to the
    // routed k3s API VIP once kube-vip (ArgoCD wave 0) is live. Makes the init CP non-special
    // so its loss doesn't strand the API endpoint. dependsOn ArgoCD so the VIP exists; an
    // active VIP-health gate inside the component guards the actual repoint.
    /////////////////////

    const vipCutover = new VipCutoverComponent(
        "vip-cutover",
        {
            initCp: controlPlane,
            followers: [...(additionalCpNodes || []), ...(cloudWorkers || [])],
            kubeconfigRaw,
        },
        { dependsOn: [argocdComponent] },
    );

    /////////////////////
    // WireGuard VPN
    /////////////////////

    // WireGuard is the VPN that carries kubectl traffic to the apiserver. On destroy,
    // Pulumi deletes in reverse dependency order, so WireGuard must outlive every k8s
    // component whose namespace has to finalize THROUGH that VPN — otherwise the tunnel
    // dies first and those namespace deletes hang on an unreachable apiserver (which is
    // exactly what stranded longhorn-system, argocd-*, cert-manager-ns, etc.). Depending
    // on those components forces them (and their namespaces) to be torn down before
    // WireGuard, so the tunnel stays up until the last k8s resource is gone.
    const wireguardComponent = new WireguardComponent("wireguard", k8sProvider, project_settings, {
        dependsOn: [
            storageComponent,
            certManager,
            ingress,
            externalDns,
            sealedSecrets,
            argocdComponent,
        ],
    });

    /////////////////////
    // Outputs — view with: pulumi stack output [--show-secrets]
    /////////////////////

    return {
        connectSshControlPlaneCommand: pulumi.interpolate`ssh root@${controlPlane.ipv4Address} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`,

        // Public IPs (IPv4 + IPv6) — all control planes / workers
        server_controlPlanePublicIPs_compact: pulumi
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
            ),
        server_workerPublicIPs_compact: pulumi
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
            ),
        // Private IPs — init-CP Hetzner private IP + kube-vip VIP; used by wgAdminUp.sh
        server_privateIPs_for_wg_check: nodesComponent.controlPlanePrivateIp.apply(
            (cp0) => `${cp0} ${project_settings.network.vip}`,
        ),

        hetznerNetworkID: networkComponent.network.id,

        // Exported kubeconfig. Since the stable-hostname change (network.apiServerHost) the
        // kubeconfigRaw server is the constant admin hostname, so the VIP-cutover rewrite
        // (IP-pattern based) is a no-op pass-through: WHICH IP the name resolves to is decided
        // by the devcontainer /etc/hosts entry (scripts/runtime/setKubeApiHost.sh — public IP
        // at create/teardown/breakglass, VIP once the WG tunnel is up).
        kubeconfig: pulumi.secret(vipCutover.kubeconfigViaVip),

        kubeConfigCmd:
            "mkdir -p ~/.kube && pulumi stack output kubeconfig --show-secrets 2>/dev/null > ~/.kube/config",

        certIssuerType: project_settings.tls.certIssuerType,

        portalURL: `https://id.${project_settings.general.tld}`,

        argocdURL: pulumi.interpolate`https://${argocdComponent.url}`,
        argocdCliCommand: argocdComponent.cliLoginCommand,
        argocdAppsURL: pulumi.interpolate`https://${argocdComponent.appsUrl}`,
        argocdAppsCliCommand: argocdComponent.cliLoginCommandApps,
        argocdAdminPasswordPlain: "pulumi config get argocdAdminPasswordPlain",

        // WireGuard admin client config — copy to ~/.config/wireguard/wg0.conf or import into
        // your WireGuard client. Split-tunnel: only the VPN subnet and the cluster private
        // range route through the VPN, never a default route.
        //
        // DNS = the VPN server IP: the CoreDNS sidecar in the wireguard pod (src/wireguard.ts)
        // answers *.<dns.tld> with 10.0.2.1, so cluster hostnames resolve to the VPN-side
        // address and the server's public IP never has to appear in AllowedIPs. That works
        // because the wireguard pod and the Envoy data plane are both control-plane-scheduled
        // and Envoy binds :80/:443 with hostNetwork, so 10.0.2.1:443 IS the gateway.
        //
        // ⚠ AllowedIPs is deliberately NARROWER than privateRange (10.0.0.0/16). Mesh nodes
        // (10.0.10.x) are inside that /16 but are NOT reachable through this tunnel: the
        // mesh-gateway advertises only subnetRange into the tailnet, so a mesh node has no
        // return route for the VPN subnet. Claiming the /16 made a mesh node look DOWN rather
        // than out of scope. Reach mesh nodes by their public ssh.endpoint
        // (scripts/runtime/sshConnectNode.sh).
        //
        // ⚠ THE VIP NEEDS ITS OWN /32. network.vip (10.0.3.100) lies OUTSIDE subnetRange
        // (10.0.0.0/23), so dropping from the /16 without listing it explicitly would take the
        // k3s API out of the tunnel and break kubectl for every admin.
        // One client config per admin, keyed by name (wireguardClientConfigs.admin1, .admin2).
        // Each carries that admin's OWN private key and OWN /32 Address — two admins must
        // never share a config, or their tunnels fight over the server-side endpoint.
        // wgAdminUp.sh selects one via WG_ADMIN (default admin1).
        wireguardClientConfigs: pulumi.secret(
            pulumi
                .all(
                    project_settings.wireguard.admins.map((a) =>
                        pulumi
                            .all([
                                a.addr,
                                a.privateKey,
                                project_settings.wireguard.wgServerPublicKey,
                                wireguardComponent.url,
                            ])
                            .apply(
                                ([addr, privateKey, serverPublicKey, url]) => `[Interface]
Address = ${addr}
PrivateKey = ${privateKey}
DNS = ${project_settings.wireguard.serverAddr.split("/")[0]}

[Peer]
PublicKey = ${serverPublicKey}
Endpoint = ${url}:${project_settings.network.wireguardPort}
AllowedIPs = ${project_settings.wireguard.vpnSubnet}, ${project_settings.network.subnetRange}, ${project_settings.network.vip}/32
PersistentKeepalive = 25
`,
                            ),
                    ),
                )
                .apply((confs) =>
                    Object.fromEntries(
                        confs.map((c, i) => [project_settings.wireguard.admins[i].name, c]),
                    ),
                ),
        ),
    };
}

module.exports = main();
