import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import { project_settings } from "../project_settings";

export class SealedSecretsComponent extends pulumi.ComponentResource {
    public readonly sealedSecretsChart: helm.v3.Release;

    constructor(name: string, k8sProvider: k8s.Provider, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:SealedSecrets", name, {}, opts);

        // Pre-create TLS keypair so the controller uses it on first start (no restart needed).
        // Stored in Pulumi config so it survives cluster recreates.
        const sealedSecretsKey = new k8s.core.v1.Secret(
            "sealed-secrets-key",
            {
                metadata: {
                    name: "sealed-secrets-key",
                    namespace: "kube-system",
                    labels: { "sealedsecrets.bitnami.com/sealed-secrets-key": "active" },
                },
                type: "kubernetes.io/tls",
                stringData: {
                    "tls.crt": project_settings.tls.sealedSecretsTlsCrt,
                    "tls.key": project_settings.tls.sealedSecretsTlsKey,
                },
            },
            { provider: k8sProvider, parent: this },
        );

        this.sealedSecretsChart = new helm.v3.Release(
            "sealed-secrets",
            {
                name: "sealed-secrets",
                chart: "sealed-secrets",
                version: "2.18.5", // https://github.com/bitnami-labs/sealed-secrets/releases
                namespace: "kube-system",
                repositoryOpts: { repo: "https://bitnami-labs.github.io/sealed-secrets" },
                values: {
                    fullnameOverride: "sealed-secrets-controller",
                    secretName: "sealed-secrets-key",
                },
                waitForJobs: true,
            },
            { provider: k8sProvider, parent: this, dependsOn: [sealedSecretsKey] },
        );

        this.registerOutputs({ sealedSecretsChart: this.sealedSecretsChart });
    }
}
