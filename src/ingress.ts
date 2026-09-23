/**
 * Project: edgecloudinfra
 * File: ingress.ts
 * Purpose: Gateway API ingress (Envoy Gateway) — controller, GatewayClass and the
 *          cluster-wide Gateway that terminates TLS for every app.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";
import type { ClusterNode } from "./nodes-k3s-types";

export class IngressComponent extends pulumi.ComponentResource {
    public readonly envoyGateway: helm.v3.Release;
    public readonly waitForGateway: command.local.Command;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        kubeconfigRaw: pulumi.Output<string>,
        controlPlane: ClusterNode,
        additionalCpNodes: ClusterNode[],
        certIssuers: {
            letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
            letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
        },
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("ecc:infra:Ingress", name, {}, opts);
        const { letsEncryptStagingIssuer, letsEncryptProdIssuer } = certIssuers;

        // Public entrypoints of the cluster. There is no cloud load balancer: the wildcard
        // DNS records (src/dns.ts) point straight at every control-plane node's public IP,
        // so the Envoy data plane must bind :80/:443 on the host (hostNetwork: true in the
        // proxy patch below) — that host bind, NOT the Service, is what actually serves
        // public traffic.
        //
        // These IPs must NOT be set as the Service's `externalIPs`. Kubernetes implements
        // externalIPs by programming a NAT rule on EVERY node in the cluster, so each mesh
        // node hijacks its own outbound TCP to the cloud public IP and redirects it to the
        // Service backend (the CP's PRIVATE IP), reachable only over the mesh. That is a
        // bootstrap dependency loop: a mesh node needs TCP/443 to the public IP to reach
        // headscale, but cannot have it while the mesh is down — so a node that drops off
        // can never reconnect on its own. It presents as UDP (WireGuard 41641, STUN 30478)
        // to the same IP answering normally while the TCP SYN never reaches the NIC, with
        // `ip daddr <public-ip> tcp dport 443 ... jump KUBE-EXT-...` counting up in
        // `nft list ruleset` on the node.
        // The IPs are published in the `envoy-gateway-public-ips` ConfigMap below instead.
        const cpPublicIps = pulumi
            .all([
                controlPlane.ipv4Address,
                controlPlane.ipv6Address,
                ...additionalCpNodes.map((n) => n.ipv4Address),
                ...additionalCpNodes.map((n) => n.ipv6Address),
            ])
            .apply((ips) => ips.filter(Boolean) as string[]);

        // Single source of truth for the envoy-gateway chart version: the Helm Release
        // below AND the Gateway API CRD upgrade that Helm cannot do (see there) must
        // always name the same chart, or the CRDs silently lag the controller.
        const ENVOY_GATEWAY_CHART_VERSION = "1.9.1"; // renovate: datasource=docker depName=docker.io/envoyproxy/gateway-helm

        const envoyGatewayNs = new k8s.core.v1.Namespace(
            "envoy-gateway-ns",
            {
                metadata: { name: "envoy-gateway-system" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        // Envoy Gateway. The chart bundles the Gateway API CRDs, so no separate
        // gateway-api CRD release is needed.
        // https://gateway.envoyproxy.io/docs/install/install-helm/
        //
        // ⚠ THE GATEWAY API VERSION IS TRANSITIVE — it is declared NOWHERE in this repo
        // and Renovate cannot see it. It rides along with the chart pin below:
        //
        //     gateway-helm v1.5.4  ->  Gateway API v1.3.0   (experimental channel)
        //     gateway-helm 1.9.1   ->  Gateway API v1.6.1   (experimental channel)  <- current
        //
        // So bumping this one line also upgrades every Gateway/HTTPRoute CRD in the
        // cluster. Envoy Gateway 1.9 REQUIRES Gateway API v1.6 (it reconciles TCPRoute
        // and UDPRoute via the v1 API), which is satisfied only because the chart carries
        // them. Read the release notes for EVERY intervening minor before bumping, and
        // verify the bundled version afterwards:
        //
        //   helm template eg oci://docker.io/envoyproxy/gateway-helm --version <v> \
        //     --include-crds | grep -m1 bundle-version
        //
        // The CRDs are a SUBCHART TEMPLATE (charts/crds/templates/), not a crds/
        // directory, so Helm does upgrade them in place — the usual "Helm never upgrades
        // CRDs" caveat does not apply here. The chart also installs a
        // ValidatingAdmissionPolicy (safe-upgrades.gateway.networking.k8s.io) that
        // REFUSES an experimental -> standard channel downgrade; this cluster is on the
        // experimental channel, so a chart that bundles the standard set would be
        // rejected at apply time rather than silently dropping fields.
        this.envoyGateway = new helm.v3.Release(
            "envoy-gateway",
            {
                name: "envoy-gateway",
                chart: "oci://docker.io/envoyproxy/gateway-helm",
                version: ENVOY_GATEWAY_CHART_VERSION,
                namespace: "envoy-gateway-system",
                values: {
                    // Controller only — the data plane shape is set by the EnvoyProxy CR below.
                    deployment: {
                        envoyGateway: {
                            resources: {
                                requests: { cpu: "100m", memory: "256Mi" },
                                limits: { memory: "1024Mi" },
                            },
                        },
                    },
                },
                waitForJobs: true,
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [envoyGatewayNs, letsEncryptStagingIssuer, letsEncryptProdIssuer],
            },
        );

        // Gateway API CRD upgrade — the one thing the Helm release above CANNOT do.
        //
        // The chart ships the Gateway API CRDs in charts/crds/crds/gatewayapi-crds.yaml:
        // a real Helm `crds/` DIRECTORY. Helm installs those exactly once, on first
        // install, and NEVER touches them on upgrade — by design, and with no flag to
        // override it. `helm get manifest envoy-gateway` returns ZERO CustomResourceDefinition
        // documents, so the CRDs are not part of the release at all and no amount of
        // re-applying the Release will move them.
        //
        // The failure that causes is silent. Bumping the chart v1.5.4 -> 1.9.1 upgraded the
        // controller but left the CRDs at Gateway API v1.3.0, and 1.9.x reconciles
        // TCPRoute/UDPRoute/TLSRoute/BackendTLSPolicy through the v1 API that only the v1.6
        // CRDs serve. The controller does not error — it logs `... CRD not found, skipping
        // <Kind> watch` at INFO and carries on, so those route kinds simply stop being
        // reconciled while everything reports healthy. Measured 2026-09-04.
        //
        // Hence this step: apply the CRDs the PINNED chart carries, straight from the chart,
        // so they can never disagree with the controller. Keyed on the chart version, so it
        // re-runs on exactly the event that matters — a chart bump — and is a no-op otherwise.
        //
        // Safety: --server-side is REQUIRED. These CRDs exceed the 262144-byte
        // last-applied-configuration annotation that client-side `kubectl apply` writes, and
        // a plain apply fails `metadata.annotations: Too long`. The chart also installs a
        // ValidatingAdmissionPolicy (safe-upgrades.gateway.networking.k8s.io, binding action
        // Deny) that refuses an experimental -> standard channel swap or a downgrade below
        // v1.5, so a wrong bundle is rejected at the API server rather than silently
        // narrowing every CRD.
        const gatewayApiCrds = new command.local.Command(
            "gateway-api-crds",
            {
                create: pulumi.interpolate`
        set -e
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        CHART_DIR=$(mktemp -d)
        trap "rm -f $KUBECONFIG_FILE; rm -rf $CHART_DIR" EXIT
        export KUBECONFIG="$KUBECONFIG_FILE"

        helm pull oci://docker.io/envoyproxy/gateway-helm \
            --version ${ENVOY_GATEWAY_CHART_VERSION} --untar --untardir "$CHART_DIR" >/dev/null
        CRD_FILE="$CHART_DIR/gateway-helm/charts/crds/crds/gatewayapi-crds.yaml"
        [ -f "$CRD_FILE" ] || { echo "gatewayapi-crds.yaml not found in chart ${ENVOY_GATEWAY_CHART_VERSION}" >&2; exit 1; }

        BUNDLE=$(grep -m1 'gateway.networking.k8s.io/bundle-version:' "$CRD_FILE" | awk '{print $2}')
        echo "Applying Gateway API CRDs bundle $BUNDLE from gateway-helm ${ENVOY_GATEWAY_CHART_VERSION}"
        kubectl apply --server-side --force-conflicts -f "$CRD_FILE"

        # Read the annotation with jq, NOT jsonpath. The annotation KEY contains dots, so a
        # jsonpath needs them backslash-escaped — and this string is a TS template literal,
        # so the escapes get eaten before the shell ever sees them. The result is an EMPTY
        # string rather than an error, which then fails the check below on a perfectly good
        # apply (measured 2026-09-04). jq indexes the key as a plain string, no escaping.
        LIVE=$(kubectl get crd gateways.gateway.networking.k8s.io -o json \
            | jq -r '.metadata.annotations["gateway.networking.k8s.io/bundle-version"]')
        [ "$LIVE" = "$BUNDLE" ] || { echo "CRD bundle is $LIVE, expected $BUNDLE" >&2; exit 1; }
        echo "Gateway API CRDs at $BUNDLE"`,
                triggers: [ENVOY_GATEWAY_CHART_VERSION],
            },
            { parent: this, dependsOn: [this.envoyGateway, k8sProvider] },
        );

        // Data-plane shape. NB: the EnvoyProxy CRD has NO first-class hostNetwork or
        // externalIPs field (verified against v1.5.4:
        // crds/generated/gateway.envoyproxy.io_envoyproxies.yaml — zero occurrences of
        // either). Both are only reachable through the StrategicMerge `patch` escape hatch,
        // which is x-kubernetes-preserve-unknown-fields. This is unsupported surface on the
        // most load-bearing part of the ingress path, so re-verify the rendered DaemonSet
        // carries hostNetwork after any chart bump.
        const envoyProxyConfig = new k8s.apiextensions.CustomResource(
            "envoy-proxy-config",
            {
                apiVersion: "gateway.envoyproxy.io/v1alpha1",
                kind: "EnvoyProxy",
                metadata: { name: "envoy-hostnetwork", namespace: "envoy-gateway-system" },
                spec: {
                    // Merge every Gateway under the `envoy` GatewayClass onto ONE Envoy
                    // infrastructure. Without this each Gateway gets its own DaemonSet,
                    // and under hostNetwork the second one's pods sit Pending forever on
                    // a :80/:443 hostPort conflict — which is what makes an app-owned
                    // Gateway (deployment/argocd-apps/gitlab renders its own `gitlab-gw`)
                    // possible at all.
                    //
                    // The cost: listeners must be unique on the (port, protocol, hostname)
                    // tuple ACROSS all merged Gateways. A duplicate is not a hard error —
                    // the newer listener (by timestamp) is silently rejected with
                    // Accepted=False, so check listener status, not just pod health.
                    // Exact hostnames beat the wildcard per Gateway API spec, so
                    // kas.<tld> on gitlab-gw and *.<tld> here coexist correctly.
                    mergeGateways: true,
                    provider: {
                        type: "Kubernetes",
                        kubernetes: {
                            // Bind the real listener ports inside the container. By default
                            // Envoy Gateway shifts privileged ports (443 → 10443) and relies
                            // on the Service to map them back. With hostNetwork there is no
                            // Service in the path, so without this Envoy would listen on
                            // :10443 of the host while DNS points at :443 — nothing serves,
                            // and it looks like a firewall fault rather than a config one.
                            useListenerPortAsContainerPort: true,
                            envoyDaemonSet: {
                                pod: {
                                    nodeSelector: {
                                        "node-role.kubernetes.io/control-plane": "true",
                                    },
                                },
                                container: {
                                    // Bind :80/:443 directly on the host (see
                                    // useListenerPortAsContainerPort above).
                                    //
                                    // runAsUser 0 is REQUIRED, not merely convenient: the
                                    // upstream envoyproxy/envoy:distroless image runs as
                                    // UID 65532, and adding NET_BIND_SERVICE only puts the
                                    // capability in the PERMITTED set. A non-root process
                                    // needs it in the AMBIENT set to actually use it, which
                                    // Kubernetes has no field for — so Envoy failed with
                                    // "cannot bind '0.0.0.0:80': Permission denied" while
                                    // the pod still reports 2/2 Running.
                                    // The capability is kept so the bind right is explicit.
                                    // Confined to control-plane nodes.
                                    //
                                    // runAsNonRoot: false MUST accompany runAsUser: 0. From
                                    // gateway-helm 1.9.x the controller injects
                                    // `runAsNonRoot: true` into the envoy and
                                    // shutdown-manager container securityContexts. Setting
                                    // only runAsUser leaves the pair self-contradictory and
                                    // the kubelet refuses the container outright:
                                    //   Error: container's runAsUser breaks non-root policy
                                    // It never starts, so the DaemonSet has no ready pod and
                                    // EVERY Gateway goes Programmed=False / "Envoy replicas
                                    // unavailable" — all public HTTPS down, while the
                                    // controller itself stays healthy and logs nothing.
                                    // Measured on the v1.5.4 -> 1.9.1 upgrade (v1.5.4 did
                                    // not inject the field, so runAsUser alone sufficed).
                                    securityContext: {
                                        runAsUser: 0,
                                        runAsNonRoot: false,
                                        capabilities: { add: ["NET_BIND_SERVICE"] },
                                    },
                                },
                                patch: {
                                    type: "StrategicMerge",
                                    value: {
                                        spec: {
                                            template: {
                                                spec: {
                                                    hostNetwork: true,
                                                    dnsPolicy: "ClusterFirstWithHostNet",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                            envoyService: {
                                type: "ClusterIP",
                                // Pin the Service name. Left unset, Envoy Gateway derives
                                // it from the infra resource — and under mergeGateways
                                // that is the GATEWAY CLASS, i.e. `envoy-<class>-<hash>`,
                                // not anything an in-cluster consumer can reference
                                // stably. Two depend on this name: the CoreDNS rewrite
                                // that keeps gitlab.<tld> resolving inside the cluster
                                // (argocd-apps/coredns-gitlab-internal) and the gitlab
                                // pages-dns PostSync hook.
                                //
                                // Safe under merging: EG applies this override
                                // unconditionally (`svc.Name = *envoyServiceConfig.Name`
                                // in internal/infrastructure/kubernetes/proxy,
                                // resource_provider.go), independent of merge mode.
                                name: "envoy-gateway-proxy",
                                // NB: no `patch` with spec.externalIPs here — that makes
                                // every mesh node black-hole its own traffic to the cloud
                                // public IP; see the cpPublicIps comment above.
                            },
                        },
                    },
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.envoyGateway] },
        );

        // The control-plane public IPs, published for in-cluster consumers that need to
        // build public DNS records — the Service carries no `externalIPs` to read them off
        // (see the cpPublicIps comment above).
        // Consumer: deployment/argocd-apps/gitlab/pages-dns.yaml, which hard-fails when it
        // finds no addresses — keep the ConfigMap name and the newline-separated `ipv4`/
        // `ipv6` keys in sync with it.
        new k8s.core.v1.ConfigMap(
            "envoy-gateway-public-ips",
            {
                metadata: {
                    name: "envoy-gateway-public-ips",
                    namespace: "envoy-gateway-system",
                },
                data: {
                    ipv4: cpPublicIps.apply((ips) =>
                        ips.filter((ip) => !ip.includes(":")).join("\n"),
                    ),
                    ipv6: cpPublicIps.apply((ips) =>
                        ips.filter((ip) => ip.includes(":")).join("\n"),
                    ),
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [envoyGatewayNs] },
        );

        const gatewayClass = new k8s.apiextensions.CustomResource(
            "gateway-class",
            {
                apiVersion: "gateway.networking.k8s.io/v1",
                kind: "GatewayClass",
                metadata: { name: "envoy" },
                spec: {
                    controllerName: "gateway.envoyproxy.io/gatewayclass-controller",
                    parametersRef: {
                        group: "gateway.envoyproxy.io",
                        kind: "EnvoyProxy",
                        name: "envoy-hostnetwork",
                        namespace: "envoy-gateway-system",
                    },
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [envoyProxyConfig, gatewayApiCrds] },
        );

        this.waitForGateway = new command.local.Command(
            "wait-for-gateway",
            {
                create: pulumi.interpolate`
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        trap "rm -f $KUBECONFIG_FILE" EXIT
        export KUBECONFIG="$KUBECONFIG_FILE"

        # 1) controller up
        for i in $(seq 1 90); do
            if kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=5s 2>/dev/null; then
                echo "envoy-gateway controller is ready"
                break
            fi
            echo "Waiting for envoy-gateway controller... ($i/90)" >&2
            sleep 2
            if [ "$i" = "90" ]; then
                echo "envoy-gateway controller did not become ready in 180s" >&2
                exit 1
            fi
        done

        # 2) GatewayClass accepted
        for i in $(seq 1 30); do
            if [ "$(kubectl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = "True" ]; then
                echo "GatewayClass envoy is Accepted"
                exit 0
            fi
            echo "Waiting for GatewayClass to be Accepted... ($i/30)" >&2
            sleep 2
        done
        echo "GatewayClass envoy was not Accepted in 60s" >&2
        kubectl get gatewayclass envoy -o yaml >&2 || true
        exit 1`,
                triggers: [this.envoyGateway.status],
            },
            {
                parent: this,
                dependsOn: [this.envoyGateway, gatewayApiCrds, gatewayClass, k8sProvider],
            },
        );

        this.registerOutputs({
            envoyGateway: this.envoyGateway,
            waitForGateway: this.waitForGateway,
        });
    }
}
