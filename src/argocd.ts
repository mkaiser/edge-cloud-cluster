import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";
import type { PulumiSecrets } from "./pulumi_secrets";

export interface ArgoCDArgs {
    k8sProvider: k8s.Provider;
    kubeconfigRaw: pulumi.Output<string>;
    controlPlane: hcloud.Server;
    pulumiSecrets: PulumiSecrets;
    settings: {
        tld: string;
        certIssuerType: string;
        githubRepoUrl: string;
        completeClusterTeardown: boolean;
    };
    dependencies: {
        waitForHaproxyIngress: command.local.Command;
        waitForCertManager: command.local.Command;
        sealedSecretsChart: helm.v3.Release;
    };
}

// "App of Apps" structure with self-managed ArgoCD Helm release at the bottom.
// Pulumi
//   └── argocd-main-app     (watches deployment/apps/)
//         └── argocd-infra  (watches deployment/argocd/)
//               └── argocd-self  (reconciles the ArgoCD Helm release)
export class ArgoCDComponent extends pulumi.ComponentResource {
    public readonly url: string;
    public readonly cliLoginCommand: pulumi.Output<string>;

    constructor(name: string, args: ArgoCDArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:ArgoCD", name, {}, opts);

        const { k8sProvider, kubeconfigRaw, controlPlane, pulumiSecrets, settings, dependencies } =
            args;

        const { tld, certIssuerType, githubRepoUrl, completeClusterTeardown } = settings;
        const { waitForHaproxyIngress, waitForCertManager, sealedSecretsChart } = dependencies;

        const argocdUrl = `argocd.${tld}`;
        this.url = argocdUrl;
        this.cliLoginCommand = pulumi.interpolate`argocd login ${argocdUrl} --username admin --password $(pulumi config get argocdAdminPasswordPlain) --grpc-web`;

        const argocdNs = new k8s.core.v1.Namespace(
            "argocd",
            {
                metadata: { name: "argocd" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "180s" } },
        );

        // Pre-create TLS secrets from saved Pulumi config so cert-manager skips
        // ACME issuance on cluster recreation (avoids Let's Encrypt rate limits).
        // cert-manager only issues a new cert when the secret does not exist.
        if (pulumiSecrets.wildcardTlsCert && pulumiSecrets.wildcardTlsKey) {
            new k8s.core.v1.Secret(
                "infra-wildcard-tls",
                {
                    metadata: { name: "infra-wildcard-tls", namespace: "argocd" },
                    type: "kubernetes.io/tls",
                    data: {
                        "tls.crt": pulumiSecrets.wildcardTlsCert,
                        "tls.key": pulumiSecrets.wildcardTlsKey,
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [argocdNs] },
            );
        }

        if (pulumiSecrets.argocdServerTlsCert && pulumiSecrets.argocdServerTlsKey) {
            new k8s.core.v1.Secret(
                "argocd-server-tls",
                {
                    metadata: { name: "argocd-server-tls", namespace: "argocd" },
                    type: "kubernetes.io/tls",
                    data: {
                        "tls.crt": pulumiSecrets.argocdServerTlsCert,
                        "tls.key": pulumiSecrets.argocdServerTlsKey,
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [argocdNs] },
            );
        }

        // On destroy: save certs to Pulumi config (cluster recreation) or
        // delete saved certs from config (complete teardown).
        new command.local.Command(
            "save-or-clear-tls-certs",
            {
                create: "echo 'TLS cert save/clear ready (runs on destroy only)'",
                delete: completeClusterTeardown
                    ? `pulumi config rm wildcardTlsCert --stack edgecloudinfra 2>/dev/null || true; \
pulumi config rm wildcardTlsKey --stack edgecloudinfra 2>/dev/null || true; \
pulumi config rm argocdServerTlsCert --stack edgecloudinfra 2>/dev/null || true; \
pulumi config rm argocdServerTlsKey --stack edgecloudinfra 2>/dev/null || true; \
echo "TLS cert config cleared (complete teardown)"`
                    : pulumi.interpolate`export KUBECONFIG=~/.kube/config; \
WILDCARD_CRT=$(kubectl get secret infra-wildcard-tls -n argocd -o jsonpath='{.data.tls\\.crt}' 2>/dev/null || true); \
WILDCARD_KEY=$(kubectl get secret infra-wildcard-tls -n argocd -o jsonpath='{.data.tls\\.key}' 2>/dev/null || true); \
ARGOCD_CRT=$(kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\\.crt}' 2>/dev/null || true); \
ARGOCD_KEY=$(kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\\.key}' 2>/dev/null || true); \
if [ -n "$WILDCARD_CRT" ] && [ -n "$WILDCARD_KEY" ]; then \
  pulumi config set --secret wildcardTlsCert "$WILDCARD_CRT" --stack edgecloudinfra; \
  pulumi config set --secret wildcardTlsKey "$WILDCARD_KEY" --stack edgecloudinfra; \
  echo "Saved infra-wildcard-tls to Pulumi config"; \
else \
  echo "WARNING: infra-wildcard-tls not found, skipping save"; \
fi; \
if [ -n "$ARGOCD_CRT" ] && [ -n "$ARGOCD_KEY" ]; then \
  pulumi config set --secret argocdServerTlsCert "$ARGOCD_CRT" --stack edgecloudinfra; \
  pulumi config set --secret argocdServerTlsKey "$ARGOCD_KEY" --stack edgecloudinfra; \
  echo "Saved argocd-server-tls to Pulumi config"; \
else \
  echo "WARNING: argocd-server-tls not found, skipping save"; \
fi`,
                triggers: [],
            },
            { parent: this },
        );

        // No-op command used as a destroy-order hook:
        // argocd chart → this command (delete hook) → argocd namespace
        // Optimized to only patch resources with finalizers (xargs parallel execution).
        const forceFinalizeArgocdNsOnDestroy = completeClusterTeardown
            ? new command.local.Command(
                  "force-finalize-argocd-ns-on-destroy",
                  {
                      create: "echo 'argocd namespace finalizer cleanup ready (runs on destroy only)'",
                      delete: pulumi.interpolate`export KUBECONFIG=~/.kube/config; \
if kubectl get namespace argocd >/dev/null 2>&1; then \
    kubectl -n argocd get all,applications,appsets --no-headers -o name 2>/dev/null | \
        xargs -P 8 -I {} bash -c 'kubectl -n argocd patch {} --type=json -p="[{\\"op\\":\\"remove\\",\\"path\\":\\"/metadata/finalizers\\"}]" 2>/dev/null || true' || true; \
    kubectl patch namespace argocd --type=merge -p '{"spec":{"finalizers":[]}}' 2>/dev/null || true; \
    printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"argocd"},"spec":{"finalizers":[]}}' \
      | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f - 2>/dev/null || true; \
fi; \
echo "argocd namespace finalizer cleanup completed"`,
                      triggers: [],
                  },
                  { parent: this, dependsOn: [argocdNs] },
              )
            : null;

        const argocdChart = new helm.v3.Release(
            "argocd",
            {
                name: "argocd",
                chart: "argo-cd",
                version: "9.5.0", // https://artifacthub.io/packages/helm/argo/argo-cd
                namespace: "argocd",
                repositoryOpts: { repo: "https://argoproj.github.io/argo-helm" },
                values: {
                    global: { domain: pulumi.interpolate`${argocdUrl}` },
                    configs: {
                        // Secrets cannot go in git — injected here by Pulumi only.
                        // All other values managed via GitOps: deployment/argocd/values.yaml
                        secret: {
                            argocdServerAdminPassword: pulumiSecrets.argocdAdminPasswordHash,
                            argocdServerAdminPasswordMtime: pulumiSecrets.argocdAdminPasswordMtime,
                            extra: { "server.secretkey": pulumiSecrets.argocdServerSecretKey },
                        },
                        params: { "server.insecure": "true" },
                    },
                    // Ingress set here so ArgoCD is reachable immediately after bootstrap,
                    // before argocd-self reconciles deployment/argocd/values.yaml.
                    server: {
                        service: { type: "ClusterIP" },
                        extraArgs: ["--insecure"],
                        ingress: {
                            enabled: true,
                            ingressClassName: "haproxy",
                            hosts: [pulumi.interpolate`${argocdUrl}`],
                            annotations: {
                                "cert-manager.io/cluster-issuer": certIssuerType,
                                "haproxy-ingress.github.io/ssl-redirect": "true",
                            },
                            tls: [
                                {
                                    secretName: "argocd-server-tls",
                                    hosts: [pulumi.interpolate`${argocdUrl}`],
                                },
                            ],
                        },
                    },
                },
                waitForJobs: true,
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [
                    argocdNs,
                    waitForHaproxyIngress,
                    waitForCertManager,
                    ...(forceFinalizeArgocdNsOnDestroy ? [forceFinalizeArgocdNsOnDestroy] : []),
                ],
            },
        );

        const waitForArgocdCrds = new command.local.Command(
            "wait-for-argocd-crds",
            {
                create: pulumi.interpolate`
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        trap "rm -f $KUBECONFIG_FILE" EXIT
        for i in $(seq 1 30); do
            if KUBECONFIG="$KUBECONFIG_FILE" kubectl get crd applications.argoproj.io 2>/dev/null; then
                echo "ArgoCD CRDs are ready"
                exit 0
            fi
            echo "Waiting for ArgoCD CRDs... ($i/30)" >&2
            sleep 5
        done
        echo "ArgoCD CRDs did not become available" >&2
        exit 1`,
                triggers: [controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [argocdChart, k8sProvider] },
        );

        new k8s.core.v1.Secret(
            "github-repo-creds",
            {
                metadata: {
                    name: "argocd-repo-github-creds",
                    namespace: argocdNs.metadata.name,
                    labels: { "argocd.argoproj.io/secret-type": "repository" },
                },
                stringData: {
                    type: "git",
                    url: githubRepoUrl,
                    sshPrivateKey: pulumiSecrets.argocdGithubDeployKey,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [argocdChart] },
        );

        new k8s.apiextensions.CustomResource(
            "argocd-main-app",
            {
                apiVersion: "argoproj.io/v1alpha1",
                kind: "Application",
                metadata: { name: "argocd-main-app", namespace: argocdNs.metadata.name },
                spec: {
                    project: "default",
                    source: {
                        repoURL: githubRepoUrl,
                        targetRevision: "main",
                        path: "deployment/apps",
                    },
                    destination: { name: "in-cluster", namespace: "default" },
                    syncPolicy: { automated: { prune: true, selfHeal: true } },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [argocdChart, waitForArgocdCrds, sealedSecretsChart],
            },
        );

        this.registerOutputs({
            url: this.url,
            cliLoginCommand: this.cliLoginCommand,
        });
    }
}
