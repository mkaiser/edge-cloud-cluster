import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";

export class IngressComponent extends pulumi.ComponentResource {
    public readonly haproxyIngress: helm.v3.Release;
    public readonly waitForHaproxyIngress: command.local.Command;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        kubeconfigRaw: pulumi.Output<string>,
        controlPlane: hcloud.Server,
        additionalCpNodes: hcloud.Server[],
        certIssuers: {
            letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
            letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
        },
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:Ingress", name, {}, opts);
        const { letsEncryptStagingIssuer, letsEncryptProdIssuer } = certIssuers;

        // haproxy-ingress in DaemonSet + hostNetwork mode: binds to port 80/443 on each node.
        // https://haproxy-ingress.github.io/docs/getting-started/
        const haproxyIngressNs = new k8s.core.v1.Namespace(
            "haproxy-ingress-ns",
            {
                metadata: { name: "haproxy-ingress" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        this.haproxyIngress = new helm.v3.Release(
            "haproxy-ingress",
            {
                name: "haproxy-ingress",
                chart: "haproxy-ingress",
                version: "0.16.1", // https://haproxy-ingress.github.io/
                namespace: "haproxy-ingress",
                repositoryOpts: { repo: "https://haproxy-ingress.github.io/charts" },
                values: {
                    fullnameOverride: "haproxy-ingress",
                    controller: {
                        kind: "DaemonSet",
                        hostNetwork: true,
                        dnsPolicy: "ClusterFirstWithHostNet",
                        nodeSelector: { "node-role.kubernetes.io/control-plane": "true" },
                        ingressClassResource: { enabled: true, default: true },
                        service: {
                            type: "ClusterIP",
                            externalIPs: pulumi
                                .all([
                                    controlPlane.ipv4Address,
                                    controlPlane.ipv6Address,
                                    ...additionalCpNodes.map((n) => n.ipv4Address),
                                    ...additionalCpNodes.map((n) => n.ipv6Address),
                                ])
                                .apply((ips) => ips.filter(Boolean)),
                        },
                        publishService: { enabled: false },
                        extraArgs: {
                            "publish-address": pulumi
                                .all([
                                    controlPlane.ipv4Address,
                                    controlPlane.ipv6Address,
                                    ...additionalCpNodes.map((n) => n.ipv4Address),
                                    ...additionalCpNodes.map((n) => n.ipv6Address),
                                ])
                                .apply((ips) => ips.join(",")),
                            "default-ssl-certificate": "argocd/infra-wildcard-tls",
                        },
                        resources: {
                            requests: { cpu: "100m", memory: "90Mi" },
                            limits: { cpu: "500m", memory: "256Mi" },
                        },
                        // openDesk recommends tuning bufsize and maxhdr
                        // bind-ip-addr-http: "[::]" creates a dual-stack socket (IPv4 + IPv6) on Linux
                        config: {
                            "config-global": "tune.bufsize 65536\ntune.http.maxhdr 256",
                            "bind-ip-addr-http": "[::]",
                            // Set X-Forwarded-Proto so apps behind TLS termination
                            // (e.g. XWiki OIDC callback) know the original scheme was HTTPS.
                            "config-frontend":
                                "http-request set-header X-Forwarded-Proto https if { ssl_fc }",
                        },
                        stats: {
                            port: 1936,
                        },
                    },
                    metrics: {
                        enabled: true,
                        serviceMonitor: {
                            // Disabled: ServiceMonitor CRDs don't exist at Pulumi time.
                            // The haproxy-ingress ServiceMonitor is declared in
                            // deployment/kube-prometheus-stack/prometheus.yaml via additionalServiceMonitors.
                            enabled: false,
                        },
                    },
                },
                waitForJobs: true,
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [haproxyIngressNs, letsEncryptStagingIssuer, letsEncryptProdIssuer],
            },
        );

        this.waitForHaproxyIngress = new command.local.Command(
            "wait-for-haproxy-ingress",
            {
                create: pulumi.interpolate`
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        trap "rm -f $KUBECONFIG_FILE" EXIT
        for i in $(seq 1 90); do
            if KUBECONFIG="$KUBECONFIG_FILE" kubectl -n haproxy-ingress rollout status daemonset/haproxy-ingress --timeout=5s 2>/dev/null; then
                echo "haproxy-ingress is ready"
                exit 0
            fi
            echo "Waiting for haproxy-ingress... ($i/90)" >&2
            sleep 2
        done
        echo "haproxy-ingress did not become ready in 180s" >&2
        exit 1`,
                triggers: [this.haproxyIngress.status],
            },
            { parent: this, dependsOn: [this.haproxyIngress, k8sProvider] },
        );

        this.registerOutputs({
            haproxyIngress: this.haproxyIngress,
            waitForHaproxyIngress: this.waitForHaproxyIngress,
        });
    }
}
