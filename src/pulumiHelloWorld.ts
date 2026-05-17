import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";

import { project_settings as ProjectSettings } from "../project_settings";

// Simple Nginx deployment used to verify cert-manager TLS provisioning and ingress routing.
// DNS is covered by the wildcard record (*.infra<N>.<zone>).
export class pulumiHelloWorldComponent extends pulumi.ComponentResource {
    public readonly url: string;
    public readonly urlOutput: pulumi.Output<string>;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        projectSettings: typeof ProjectSettings,
        ingress: {
            haproxyIngress: helm.v3.Release;
            waitForHaproxyIngress: command.local.Command;
        },
        certManager: {
            waitForCertManager: command.local.Command;
            letsEncryptStagingIssuer: k8s.apiextensions.CustomResource;
            letsEncryptProdIssuer: k8s.apiextensions.CustomResource;
        },
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:pulumiHelloWorld", name, {}, opts);

        const pulumiHelloWorldUrl = `${projectSettings.pulumiHelloWorld.subdomain}.${projectSettings.dns.tld}`;

        const pulumiHelloWorldNs = new k8s.core.v1.Namespace(
            "hello-pulumi-ns",
            {
                metadata: { name: "hello-pulumi" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        const pulumiHelloWorldDeployment = new k8s.apps.v1.Deployment(
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
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [ingress.haproxyIngress, pulumiHelloWorldNs],
            },
        );

        const pulumiHelloWorldService = new k8s.core.v1.Service(
            "hello-pulumi-svc",
            {
                metadata: { name: "hello-pulumi", namespace: "hello-pulumi" },
                spec: {
                    selector: { app: "hello-pulumi" },
                    ports: [{ port: 80, targetPort: 80 }],
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [pulumiHelloWorldNs] },
        );

        // cert-manager annotation triggers automatic TLS provisioning via rollout-profile issuer.
        new k8s.networking.v1.Ingress(
            "hello-pulumi-ingress",
            {
                metadata: {
                    name: "hello-pulumi",
                    namespace: "hello-pulumi",
                    annotations: {
                        "cert-manager.io/cluster-issuer": projectSettings.tls.certIssuerType,
                        "acme.cert-manager.io/dns01-provider": "hetzner",
                        "haproxy-ingress.github.io/ssl-redirect": "true",
                        "external-dns.alpha.kubernetes.io/exclude": "true", // use the wildcard record
                    },
                },
                spec: {
                    ingressClassName: "haproxy",
                    rules: [
                        {
                            host: pulumi.interpolate`${pulumiHelloWorldUrl}`,
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
                            hosts: [pulumi.interpolate`${pulumiHelloWorldUrl}`],
                            secretName: "hello-pulumi-tls",
                        },
                    ],
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [
                    ingress.waitForHaproxyIngress,
                    certManager.waitForCertManager,
                    pulumiHelloWorldService,
                    certManager.letsEncryptStagingIssuer,
                    certManager.letsEncryptProdIssuer,
                ],
            },
        );

        this.url = pulumiHelloWorldUrl;
        this.urlOutput = pulumi.output(`https://${pulumiHelloWorldUrl}`);
        this.registerOutputs({ url: pulumiHelloWorldUrl, urlOutput: this.urlOutput });
    }
}
