import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import type { PulumiSecrets } from "./pulumi_secrets";

export interface ExternalDnsArgs {
    k8sProvider: k8s.Provider;
    pulumiSecrets: PulumiSecrets;
}

// Creates the namespace and hetzner-dns-token secret that the external-dns Helm chart
// (deployed via ArgoCD) expects. The secret is created here so it never touches git.
export class ExternalDnsComponent extends pulumi.ComponentResource {
    constructor(name: string, args: ExternalDnsArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:ExternalDns", name, {}, opts);

        const { k8sProvider, pulumiSecrets } = args;

        const externalDnsNs = new k8s.core.v1.Namespace(
            "external-dns-ns",
            {
                metadata: { name: "external-dns" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        new k8s.core.v1.Secret(
            "external-dns-hetzner-secret",
            {
                metadata: { name: "hetzner-dns-token", namespace: "external-dns" },
                stringData: { token: pulumiSecrets.hcloudToken },
            },
            { provider: k8sProvider, parent: this, dependsOn: [externalDnsNs] },
        );

        this.registerOutputs({});
    }
}
