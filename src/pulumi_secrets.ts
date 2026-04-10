import * as pulumi from "@pulumi/pulumi";

export class PulumiSecrets {
    public readonly hcloudToken: pulumi.Output<string>;
    public readonly hetznerS3AccessKey: pulumi.Output<string>;
    public readonly hetznerS3SecretKey: pulumi.Output<string>;
    public readonly storageboxPwd: pulumi.Output<string>;
    public readonly argocdGithubDeployKey: pulumi.Output<string>;
    public readonly argocdServerSecretKey: pulumi.Output<string>;
    public readonly argocdAdminPasswordHash: pulumi.Output<string>;
    public readonly argocdAdminPasswordMtime: pulumi.Output<string>;
    public readonly sealedSecretsTlsCrt: pulumi.Output<string>;
    public readonly sealedSecretsTlsKey: pulumi.Output<string>;
    public readonly wgServerPrivateKey: pulumi.Output<string>;
    public readonly wgServerPublicKey: pulumi.Output<string>;
    public readonly wgAdminPrivateKey: pulumi.Output<string>;
    public readonly wgAdminPublicKey: pulumi.Output<string>;
    // Saved wildcard TLS certs — populated on cluster recreation (completeClusterTeardown=false).
    // cert-manager skips ACME issuance when the secret already exists, avoiding rate limits.
    public readonly wildcardTlsCert: pulumi.Output<string> | undefined;
    public readonly wildcardTlsKey: pulumi.Output<string> | undefined;
    public readonly argocdServerTlsCert: pulumi.Output<string> | undefined;
    public readonly argocdServerTlsKey: pulumi.Output<string> | undefined;

    constructor() {
        const projectConfig = new pulumi.Config();

        this.hcloudToken = projectConfig.requireSecret("hcloudToken");
        this.hetznerS3AccessKey = projectConfig.requireSecret("hetznerS3AccessKey");
        this.hetznerS3SecretKey = projectConfig.requireSecret("hetznerS3SecretKey");
        this.storageboxPwd = projectConfig.requireSecret("storageboxPwd");
        this.argocdGithubDeployKey = projectConfig.requireSecret("argocdGithubDeployKey");
        this.argocdServerSecretKey = projectConfig.requireSecret("argocdServerSecretKey");
        this.argocdAdminPasswordHash = projectConfig.requireSecret("argocdAdminPasswordHash");
        this.argocdAdminPasswordMtime = projectConfig.requireSecret("argocdAdminPasswordMtime");
        this.sealedSecretsTlsCrt = projectConfig.requireSecret("sealedSecretsTlsCrt");
        this.sealedSecretsTlsKey = projectConfig.requireSecret("sealedSecretsTlsKey");
        this.wgServerPrivateKey = projectConfig.requireSecret("wgServerPrivateKey");
        this.wgServerPublicKey = pulumi.output(projectConfig.require("wgServerPublicKey"));
        this.wgAdminPrivateKey = projectConfig.requireSecret("wgAdminPrivateKey");
        this.wgAdminPublicKey = pulumi.output(projectConfig.require("wgAdminPublicKey"));
        this.wildcardTlsCert = projectConfig.getSecret("wildcardTlsCert");
        this.wildcardTlsKey = projectConfig.getSecret("wildcardTlsKey");
        this.argocdServerTlsCert = projectConfig.getSecret("argocdServerTlsCert");
        this.argocdServerTlsKey = projectConfig.getSecret("argocdServerTlsKey");
    }
}

export const pulumi_secrets = new PulumiSecrets();
