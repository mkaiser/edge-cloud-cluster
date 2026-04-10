import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";

export interface HelloPulumiArgs {
    k8sProvider: k8s.Provider;
    dns: {
        tld: string;
    };
    ingress: {
        haproxyIngress: helm.v3.Release;
        waitForHaproxyIngress: command.local.Command;
    };
    certManager: {
        waitForCertManager: command.local.Command;
        certIssuerType: string;
        letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
        letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
    };
}

// Simple Nginx deployment used to verify cert-manager TLS provisioning and ingress routing.
// DNS is covered by the wildcard record (*.infra<N>.<zone>).
export class HelloPulumiComponent extends pulumi.ComponentResource {
    public readonly url: string;
    constructor(name: string, args: HelloPulumiArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:HelloPulumi", name, {}, opts);

        const { k8sProvider, dns, ingress, certManager } = args;

        const { tld } = dns;
        const { haproxyIngress, waitForHaproxyIngress } = ingress;
        const {
            certIssuerType,
            waitForCertManager,
            letsEncryptStagingIssuer,
            letsEncryptProdIssuer,
        } = certManager;

        const helloPulumiUrl = `hello-pulumi.${tld}`;
        this.url = helloPulumiUrl;

        const helloPulumiNs = new k8s.core.v1.Namespace(
            "hello-pulumi-ns",
            {
                metadata: { name: "hello-pulumi" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        const helloPulumiDeployment = new k8s.apps.v1.Deployment(
            "hello-pulumi",
            {
                metadata: { name: "hello-pulumi", namespace: "hello-pulumi" },
                spec: {
                    replicas: 1,
                    selector: { matchLabels: { app: "hello-pulumi" } },
                    template: {
                        metadata: { labels: { app: "hello-pulumi" } },
                        spec: {
                            containers: [
                                {
                                    name: "hello-pulumi",
                                    image: "nginx:alpine",
                                    ports: [{ containerPort: 80 }],
                                    volumeMounts: [
                                        { name: "html", mountPath: "/usr/share/nginx/html" },
                                    ],
                                },
                            ],
                            initContainers: [
                                {
                                    name: "init-html",
                                    image: "busybox:1.36",
                                    command: [
                                        "sh",
                                        "-c",
                                        `cat > /html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Hello Pulumi</title></head>
<body style="font-family: sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);">
<div style="text-align: center; color: white;">
<h1>Hello from Pulumi!</h1>
<p>Served via haproxy-ingress</p>
<p>Hostname: <span id="host"></span></p>
<script>document.getElementById('host').textContent = location.hostname;</script>
</div>
</body>
</html>
EOF`,
                                    ],
                                    volumeMounts: [{ name: "html", mountPath: "/html" }],
                                },
                            ],
                            volumes: [{ name: "html", emptyDir: {} }],
                        },
                    },
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [haproxyIngress, helloPulumiNs] },
        );

        const helloPulumiService = new k8s.core.v1.Service(
            "hello-pulumi-svc",
            {
                metadata: { name: "hello-pulumi", namespace: "hello-pulumi" },
                spec: {
                    selector: { app: "hello-pulumi" },
                    ports: [{ port: 80, targetPort: 80 }],
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [helloPulumiNs] },
        );

        // cert-manager annotation triggers automatic TLS provisioning via rollout-profile issuer.
        new k8s.networking.v1.Ingress(
            "hello-pulumi-ingress",
            {
                metadata: {
                    name: "hello-pulumi",
                    namespace: "hello-pulumi",
                    annotations: {
                        "cert-manager.io/cluster-issuer": certIssuerType,
                        "acme.cert-manager.io/dns01-provider": "hetzner",
                        "haproxy-ingress.github.io/ssl-redirect": "true",
                        "external-dns.alpha.kubernetes.io/exclude": "true", // use the wildcard record
                    },
                },
                spec: {
                    ingressClassName: "haproxy",
                    rules: [
                        {
                            host: pulumi.interpolate`${helloPulumiUrl}`,
                            http: {
                                paths: [
                                    {
                                        path: "/",
                                        pathType: "Prefix",
                                        backend: {
                                            service: { name: "hello-pulumi", port: { number: 80 } },
                                        },
                                    },
                                ],
                            },
                        },
                    ],
                    tls: [
                        {
                            hosts: [pulumi.interpolate`${helloPulumiUrl}`],
                            secretName: "hello-pulumi-tls",
                        },
                    ],
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [
                    waitForHaproxyIngress,
                    waitForCertManager,
                    helloPulumiService,
                    letsEncryptStagingIssuer,
                    letsEncryptProdIssuer,
                ],
            },
        );

        this.registerOutputs({ url: this.url });
    }
}
