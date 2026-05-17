import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";

export class CertManagerComponent extends pulumi.ComponentResource {
    public readonly certManager: helm.v3.Release;
    public readonly certManagerNs: k8s.core.v1.Namespace;
    public readonly letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
    public readonly letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
    public readonly certIssuers: {
        letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
        letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
    };
    public readonly waitForCertManager: command.local.Command;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        kubeconfigRaw: pulumi.Output<string>,
        projectSettings: typeof project_settings,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:CertManager", name, {}, opts);

        this.certManagerNs = new k8s.core.v1.Namespace(
            "cert-manager-ns",
            {
                metadata: { name: "cert-manager" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        this.certManager = new helm.v3.Release(
            "cert-manager",
            {
                name: "cert-manager",
                chart: "cert-manager",
                version: "v1.20.2", // https://artifacthub.io/packages/helm/cert-manager/cert-manager
                namespace: "cert-manager",
                repositoryOpts: { repo: "https://charts.jetstack.io" },
                values: {
                    crds: { enabled: true },
                    // Use public DNS for ACME DNS-01 challenge verification instead of in-cluster CoreDNS
                    extraArgs: [
                        "--dns01-recursive-nameservers-only",
                        "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
                    ],
                    prometheus: {
                        enabled: true,
                        servicemonitor: {
                            // Disabled: ServiceMonitor CRDs don't exist at Pulumi time.
                            // The cert-manager ServiceMonitor is declared in
                            // deployment/kube-prometheus-stack/prometheus.yaml via additionalServiceMonitors.
                            enabled: false,
                        },
                    },
                },
                waitForJobs: true,
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.certManagerNs] },
        );

        const certManagerWebhookHetzner = new helm.v3.Release(
            "cert-manager-webhook-hetzner",
            {
                name: "cert-manager-webhook-hetzner",
                chart: "cert-manager-webhook-hetzner",
                version: "0.7.0", // https://github.com/hetzner/cert-manager-webhook-hetzner
                namespace: "cert-manager",
                repositoryOpts: { repo: "https://charts.hetzner.cloud" },
                values: {
                    groupName: "acme.hetzner.com",
                    certManager: {
                        namespace: "cert-manager",
                        serviceAccountName: this.certManager.status.apply((s) => s.name),
                    },
                },
                waitForJobs: true,
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [this.certManager, this.certManagerNs],
            },
        );

        const certManagerHetznerSecret = new k8s.core.v1.Secret(
            "cert-manager-hetzner-secret",
            {
                metadata: { name: "hetzner", namespace: "cert-manager" },
                stringData: { token: projectSettings.server.hcloudToken },
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.certManagerNs] },
        );

        const hetznerSolvers = [
            {
                dns01: {
                    webhook: {
                        groupName: "acme.hetzner.com",
                        solverName: "hetzner",
                        config: { tokenSecretKeyRef: { name: "hetzner", key: "token" } },
                    },
                },
            },
        ];

        this.letsEncryptStagingIssuer = new k8s.apiextensions.CustomResource(
            "letsencrypt-staging",
            {
                apiVersion: "cert-manager.io/v1",
                kind: "ClusterIssuer",
                metadata: { name: "letsencrypt-staging" },
                spec: {
                    acme: {
                        server: "https://acme-staging-v02.api.letsencrypt.org/directory",
                        email: project_settings.tls.letsEncrypt.email,
                        privateKeySecretRef: { name: "letsencrypt-staging-account-key" },
                        solvers: hetznerSolvers,
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [this.certManager, certManagerWebhookHetzner, certManagerHetznerSecret],
            },
        );

        this.letsEncryptProdIssuer = new k8s.apiextensions.CustomResource(
            "letsencrypt-prod",
            {
                apiVersion: "cert-manager.io/v1",
                kind: "ClusterIssuer",
                metadata: { name: "letsencrypt-prod" },
                spec: {
                    acme: {
                        server: "https://acme-v02.api.letsencrypt.org/directory",
                        email: project_settings.tls.letsEncrypt.email,
                        privateKeySecretRef: { name: "letsencrypt-prod-account-key" },
                        solvers: hetznerSolvers,
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [this.certManager, certManagerWebhookHetzner, certManagerHetznerSecret],
            },
        );

        this.certIssuers = {
            letsEncryptStagingIssuer: this.letsEncryptStagingIssuer,
            letsEncryptProdIssuer: this.letsEncryptProdIssuer,
        };

        this.waitForCertManager = new command.local.Command(
            "wait-for-cert-manager",
            {
                create: pulumi.interpolate`
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        trap "rm -f $KUBECONFIG_FILE" EXIT
        for i in $(seq 1 30); do
            if KUBECONFIG="$KUBECONFIG_FILE" kubectl -n cert-manager get pods -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q 'Running'; then
                echo "cert-manager is ready"
                exit 0
            fi
            echo "Waiting for cert-manager... ($i/30)" >&2
            sleep 2
        done
        echo "cert-manager did not become ready in 60s" >&2
        exit 1`,
                triggers: [this.certManager.status],
            },
            { parent: this, dependsOn: [this.certManager, k8sProvider] },
        );

        this.registerOutputs({
            certManager: this.certManager,
            certManagerNs: this.certManagerNs,
            letsEncryptStagingIssuer: this.letsEncryptStagingIssuer,
            letsEncryptProdIssuer: this.letsEncryptProdIssuer,
            certIssuers: this.certIssuers,
            waitForCertManager: this.waitForCertManager,
        });
    }
}
