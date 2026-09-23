/**
 * Project: edgecloudinfra
 * File: argocd.ts
 * Purpose: ArgoCD application and bootstrap components.
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
import { project_settings } from "../project_settings";
import { runtime_flags } from "../runtime_flags";
import type { ClusterNode } from "./nodes-k3s-types";

// Is the infra ArgoCD already self-managing its Helm release? Read from the Pulumi stack
// config latch (runtime_flags.argocdSelfManaged), NOT probed from the cluster — see the
// header comment on that flag for why the live probe was wrong. Once true, Pulumi must NOT
// construct the Helm Release: ArgoCD owns it via ServerSideApply, and a Pulumi create means
// `helm install` over a live release ("cannot re-use a name that is still in use").
// The latch is flipped by scripts/pulumi/argocdOwnershipLatch.sh and cleared by destroy.

// Construction-time probe: does a TLS secret already exist in argocd-infra? The reseed
// below pre-creates wildcard-tls / argocd-server-tls from saved Pulumi config so cert-manager
// skips ACME on a FRESH cluster (bootstrap or restore) — dodging Let's Encrypt rate limits.
// But on a steady-state `pulumi up` (e.g. make provision-mesh-node) cert-manager has ALREADY
// issued and OWNS these secrets (manager cert-manager-certificates-issuing, server-side-apply).
// A blind Pulumi `create` then fails "secrets already exists" and cascades (ArgoCD component
// errors → vip-cutover 'registration isn't pending'). Gating on targetState "restore" is
// insufficient: make bootstrap (fresh) sets it FALSE. So the correct signal is simply: seed
// ONLY when the live secret is absent. cert-manager keeps ownership on existing clusters — no
// two-writer conflict that could stomp a renewed cert. MUST NEVER throw (mirrors
// argocdSelfManaged): any error → treat as absent → seed is safe on a truly fresh cluster.
function tlsSecretExists(name: string): boolean {
    try {
        const out = require("child_process")
            .execSync(
                `kubectl --kubeconfig "\${HOME}/.kube/config" get secret ${name} ` +
                    "-n argocd-infra -o name 2>/dev/null || true",
                { encoding: "utf8", timeout: 15000 },
            )
            .toString()
            .trim();
        return out !== "";
    } catch {
        return false; // never throw → fresh cluster seeds
    }
}

// "App of Apps" structure with self-managed ArgoCD Helm release at the bottom.
// Pulumi
//   └── argocd-infra-app-of-apps     (watches deployment/argocd-infra/app-of-apps/)
//         └── wave0-argocd-infra  (watches deployment/argocd-infra/argocd-infra-self/)
//               └── argocd-infra-self    (reconciles the infra ArgoCD Helm release)
//         └── wave19-argocd-apps   (deploys the apps ArgoCD into ns argocd-apps)
// The infra ArgoCD lives in ns "argocd-infra" at host argocd-infra.<tld>.
export class ArgoCDComponent extends pulumi.ComponentResource {
    public readonly url: string;
    public readonly cliLoginCommand: pulumi.Output<string>;
    // The apps ArgoCD instance (deployed by wave19-argocd-apps into ns argocd-apps).
    // Shares the admin password hash; exposed here so the CLI helper / stack outputs
    // can target the second host.
    public readonly appsUrl: string;
    public readonly cliLoginCommandApps: pulumi.Output<string>;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        kubeconfigRaw: pulumi.Output<string>,
        controlPlane: ClusterNode,
        projectSettings: typeof project_settings,
        dependencies: {
            waitForGateway: command.local.Command;
            waitForCertManager: command.local.Command;
            sealedSecretsChart: helm.v3.Release;
        },
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("ecc:infra:ArgoCD", name, {}, opts);
        const { waitForGateway, waitForCertManager, sealedSecretsChart } = dependencies;

        const argocdUrl = `argocd-infra.${projectSettings.general.tld}`;
        this.url = argocdUrl;
        this.cliLoginCommand = pulumi.interpolate`argocd login ${argocdUrl} --username admin --password $(pulumi config get argocdAdminPasswordPlain) --grpc-web`;

        const argocdAppsUrl = `argocd-apps.${projectSettings.general.tld}`;
        this.appsUrl = argocdAppsUrl;
        this.cliLoginCommandApps = pulumi.interpolate`argocd login ${argocdAppsUrl} --username admin --password $(pulumi config get argocdAdminPasswordPlain) --grpc-web`;

        const argocdNs = new k8s.core.v1.Namespace(
            "argocd-infra",
            {
                metadata: { name: "argocd-infra" },
            },
            {
                provider: k8sProvider,
                parent: this,
                customTimeouts: { delete: "600s" },
                ignoreChanges: ["metadata.finalizers"],
            },
        );

        // Credentials for the Nextcloud S3 object store (injected into ArgoCD CMP env)
        const hetznerS3Secret = new k8s.core.v1.Secret(
            "hetzner-s3",
            {
                metadata: { name: "hetzner-s3", namespace: "argocd-infra" },
                stringData: {
                    accessKey: projectSettings.storage.objectStorage.accessKey,
                    secretKey: projectSettings.storage.objectStorage.secretKey,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [argocdNs] },
        );

        // SMTP transport for everything in argocd-infra that sends mail: the ArgoCD
        // notifications controller (pointed here by notifications.secret.name in
        // argocd-infra-self/values.yaml, which resolves `$host`/`$username`/`$password` from
        // these keys) and the wave-19 bootstrap-finished Job. Values live in the Pulumi stack
        // (scripts/secrets/setMail.sh), so they are injected here rather than sealed into git
        // — one owner, and present from the first `pulumi up` instead of after an ArgoCD sync.
        new k8s.core.v1.Secret(
            "smtp-credentials",
            {
                metadata: { name: "smtp-credentials", namespace: "argocd-infra" },
                stringData: {
                    host: projectSettings.mail.smtpRelay,
                    port: projectSettings.mail.smtpPort,
                    username: projectSettings.mail.smtpUsername,
                    password: projectSettings.mail.smtpPassword,
                    // Read as NOTIFY_TO by deployment/argocd-infra/notify/notify.yaml.
                    sendBootstrapFinishMailRecipient: projectSettings.mail.notifyRecipient,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [argocdNs] },
        );

        // Pre-delete: strip ArgoCD finalizer so Pulumi can delete the secret cleanly.
        // Depends on the secret → destroyed first during pulumi destroy.
        new command.local.Command(
            "hetzner-s3-pre-destroy",
            {
                create: "true",
                delete: 'kubectl patch secret hetzner-s3 -n argocd-infra --type=merge -p \'{"metadata":{"finalizers":[]}}\' 2>/dev/null || true',
            },
            { parent: this, dependsOn: [hetznerS3Secret] },
        );

        // Pre-create TLS secrets from saved Pulumi config so cert-manager skips
        // ACME issuance on cluster recreation (avoids Let's Encrypt rate limits).
        // cert-manager only issues a new cert when the secret does not exist — so we
        // seed ONLY when the live secret is absent (fresh bootstrap/restore). On a
        // steady-state up the secret exists and is cert-manager-owned; skip to avoid the
        // "already exists" create failure (see tlsSecretExists).
        if (
            projectSettings.tls.wildcardTlsCert &&
            projectSettings.tls.wildcardTlsKey &&
            !tlsSecretExists("wildcard-tls")
        ) {
            new k8s.core.v1.Secret(
                "wildcard-tls",
                {
                    metadata: { name: "wildcard-tls", namespace: "argocd-infra" },
                    type: "kubernetes.io/tls",
                    data: {
                        "tls.crt": projectSettings.tls.wildcardTlsCert,
                        "tls.key": projectSettings.tls.wildcardTlsKey,
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [argocdNs] },
            );
        }

        if (
            projectSettings.argocd.serverTlsCert &&
            projectSettings.argocd.serverTlsKey &&
            !tlsSecretExists("argocd-server-tls")
        ) {
            new k8s.core.v1.Secret(
                "argocd-server-tls",
                {
                    metadata: { name: "argocd-server-tls", namespace: "argocd-infra" },
                    type: "kubernetes.io/tls",
                    data: {
                        "tls.crt": projectSettings.argocd.serverTlsCert,
                        "tls.key": projectSettings.argocd.serverTlsKey,
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
                delete:
                    projectSettings.general.targetState === "destroy"
                        ? `pulumi config rm wildcardTlsCert --stack mystack 2>/dev/null || true; \
pulumi config rm wildcardTlsKey --stack mystack 2>/dev/null || true; \
pulumi config rm argocdServerTlsCert --stack mystack 2>/dev/null || true; \
pulumi config rm argocdServerTlsKey --stack mystack 2>/dev/null || true; \
echo "TLS cert config cleared (complete teardown)"`
                        : pulumi.interpolate`export KUBECONFIG=~/.kube/config; \
WILDCARD_CRT=$(kubectl get secret wildcard-tls -n argocd-infra -o jsonpath='{.data.tls\\.crt}' 2>/dev/null || true); \
WILDCARD_KEY=$(kubectl get secret wildcard-tls -n argocd-infra -o jsonpath='{.data.tls\\.key}' 2>/dev/null || true); \
ARGOCD_CRT=$(kubectl get secret argocd-server-tls -n argocd-infra -o jsonpath='{.data.tls\\.crt}' 2>/dev/null || true); \
ARGOCD_KEY=$(kubectl get secret argocd-server-tls -n argocd-infra -o jsonpath='{.data.tls\\.key}' 2>/dev/null || true); \
if [ -n "$WILDCARD_CRT" ] && [ -n "$WILDCARD_KEY" ]; then \
  pulumi config set --secret wildcardTlsCert "$WILDCARD_CRT" --stack mystack; \
  pulumi config set --secret wildcardTlsKey "$WILDCARD_KEY" --stack mystack; \
  echo "Saved wildcard-tls to Pulumi config"; \
else \
  echo "WARNING: wildcard-tls not found, skipping save"; \
fi; \
if [ -n "$ARGOCD_CRT" ] && [ -n "$ARGOCD_KEY" ]; then \
  pulumi config set --secret argocdServerTlsCert "$ARGOCD_CRT" --stack mystack; \
  pulumi config set --secret argocdServerTlsKey "$ARGOCD_KEY" --stack mystack; \
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
        // Aggressively removes ALL finalizers from all resources and namespace itself.
        const forceFinalizeArgocdNsOnDestroy =
            project_settings.general.targetState === "destroy"
                ? new command.local.Command(
                      "force-finalize-argocd-ns-on-destroy",
                      {
                          create: "echo 'argocd-infra namespace finalizer cleanup ready (runs on destroy only)'",
                          delete: pulumi.interpolate`export KUBECONFIG=~/.kube/config; \
echo "Starting force-finalize for argocd-infra namespace"; \
if kubectl get namespace argocd-infra >/dev/null 2>&1; then \
    echo "Removing finalizers from all argocd-infra resources..."; \
    kubectl -n argocd-infra get all,applications,appsets,repositories,clusterpolicies --no-headers -o name 2>/dev/null | \
        xargs -P 16 -I {} bash -c 'kubectl -n argocd-infra patch {} --type=json -p="[{\\"op\\":\\"remove\\",\\"path\\":\\"/metadata/finalizers\\"}]" 2>/dev/null && echo "Patched {}" || true' || true; \
    echo "Removing finalizers from namespace spec..."; \
    kubectl patch namespace argocd-infra --type=json -p="[{\\"op\\":\\"remove\\",\\"path\\":\\"/metadata/finalizers\\"}]" 2>/dev/null || true; \
    kubectl patch namespace argocd-infra --type=merge -p '{"spec":{"finalizers":[]}}' 2>/dev/null || true; \
    echo "Attempting finalize endpoint..."; \
    printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"argocd-infra","finalizers":[]},"spec":{"finalizers":[]}}' \
      | kubectl replace --raw "/api/v1/namespaces/argocd-infra/finalize" -f - 2>/dev/null || true; \
else \
    echo "argocd-infra namespace not found"; \
fi; \
echo "Force-finalize completed"`,
                          triggers: [],
                      },
                      { parent: this, dependsOn: [argocdNs] },
                  )
                : null;

        // Bootstrap the ArgoCD Helm release ONLY while Pulumi still owns it. Once the
        // ownership latch is set, ArgoCD owns this release via ServerSideApply; we drop it
        // from the program and (via retainOnDelete) retain the live objects instead of
        // running a helm upgrade that would collide over ownership.
        const selfManaged = runtime_flags.argocdSelfManaged;
        if (selfManaged) {
            // info (not debug): on the handoff run Pulumi drops the 'argocd' Release from the
            // program and logs it as `Release argocd deleted[retain]`, which reads alarmingly
            // like a teardown. This line explains it: only OWNERSHIP moved (Pulumi → ArgoCD
            // GitOps); the live release is retained and keeps running. On later steady-state
            // runs the Release is already gone from state, so this prints once per up as a
            // one-line reminder of who owns ArgoCD now — an acceptable trade for not scaring
            // anyone who sees the deleted[retain] line.
            pulumi.log.info(
                "ArgoCD ownership: latch argocdSelfManaged=true → 'argocd-infra-self' manages " +
                    "the Helm release via GitOps. Pulumi no longer manages the 'argocd' " +
                    "release; any `Release argocd deleted[retain]` above is the ownership " +
                    "handoff, NOT a teardown — the live release is retained. Upgrade ArgoCD " +
                    "via deployment/argocd-infra/argocd-infra-self/values.yaml, not Pulumi.",
                this,
            );
        }

        const argocdChart = selfManaged
            ? undefined
            : new helm.v3.Release(
                  "argocd",
                  {
                      // Release name kept "argocd" so service DNS only changes its <ns>
                      // segment (argocd-server.argocd-infra.svc). Namespace is argocd-infra.
                      name: "argocd",
                      chart: "argo-cd",
                      version: "10.9.1", // renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
                      namespace: "argocd-infra",
                      repositoryOpts: { repo: "https://argoproj.github.io/argo-helm" },
                      values: {
                          global: { domain: pulumi.interpolate`${argocdUrl}` },
                          configs: {
                              // Secrets cannot go in git — injected here by Pulumi only.
                              // All other values managed via GitOps:
                              // deployment/argocd-infra/argocd-infra-self/values.yaml
                              secret: {
                                  argocdServerAdminPassword:
                                      project_settings.argocd.adminPasswordHash,
                                  argocdServerAdminPasswordMtime:
                                      project_settings.argocd.adminPasswordMtime,
                                  extra: {
                                      "server.secretkey": project_settings.argocd.serverSecretKey,
                                  },
                              },
                              params: { "server.insecure": "true" },
                          },
                          // No ingress/httproute here: the cluster runs NO Ingress controller,
                          // and the Gateway (src/ingress.ts) does not exist yet at this point in
                          // the bootstrap. Until argocd-infra-self reconciles its own values.yaml
                          // (which enables server.httproute against the shared Gateway), ArgoCD is
                          // reached by port-forward — see scripts/runtime/argocdLoginCLI.sh.
                          server: {
                              service: { type: "ClusterIP" },
                              extraArgs: ["--insecure"],
                          },
                      },
                      waitForJobs: true,
                  },
                  {
                      provider: k8sProvider,
                      parent: this,
                      // Retain the live release when this resource leaves the program (self-mgmt
                      // handoff) instead of running helm uninstall. Precedent: app-of-apps below.
                      retainOnDelete: true,
                      dependsOn: [
                          argocdNs,
                          waitForGateway,
                          waitForCertManager,
                          ...(forceFinalizeArgocdNsOnDestroy
                              ? [forceFinalizeArgocdNsOnDestroy]
                              : []),
                      ],
                  },
              );

        // During bootstrap this is [the Helm release]; once self-managed it is [] so the
        // downstream dependsOn arrays stay valid without the (now-absent) release.
        const argocdChartDep = argocdChart ? [argocdChart] : [];

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
            { parent: this, dependsOn: [...argocdChartDep, k8sProvider] },
        );

        // Who receives ArgoCD alert mail. The recipient is a stack value, so it cannot sit in
        // git — and the CM's `subscriptions` field is no help: notifications-engine substitutes
        // `$key` from the Secret only in `service.*` entries, never in subscriptions.
        // An annotation on the `default` AppProject subscribes EVERY Application in it, and
        // naming no trigger means the CM's `defaultTriggers` (on-sync-failed,
        // on-health-degraded) decides when it fires.
        // argocd-server creates that AppProject itself, a moment after the chart is up, so
        // this waits for it rather than patching a resource that may not exist yet.
        new command.local.Command(
            "argocd-notification-subscription",
            {
                create: pulumi.interpolate`
        KUBECONFIG_FILE=$(mktemp)
        cat > "$KUBECONFIG_FILE" << 'KUBECFG'
${kubeconfigRaw}
KUBECFG
        trap "rm -f $KUBECONFIG_FILE" EXIT
        export KUBECONFIG="$KUBECONFIG_FILE"
        for i in $(seq 1 30); do
            kubectl -n argocd-infra get appproject default >/dev/null 2>&1 && break
            echo "Waiting for the default AppProject... ($i/30)" >&2
            sleep 5
        done
        kubectl -n argocd-infra annotate appproject default --overwrite \
            "notifications.argoproj.io/subscribe.email=$NOTIFY_RECIPIENT"`,
                // Keep the recipient out of the command string (and so out of state/logs).
                environment: { NOTIFY_RECIPIENT: projectSettings.mail.notifyRecipient },
                triggers: [projectSettings.mail.notifyRecipient],
            },
            { parent: this, dependsOn: [...argocdChartDep, waitForArgocdCrds] },
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
                    url: project_settings.argocd.git.repoUrl,
                    sshPrivateKey: project_settings.argocd.git.deployKey,
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [argocdNs, waitForArgocdCrds],
            },
        );

        // The apps ArgoCD (deployed by wave19-argocd-apps into ns argocd-apps) needs
        // the same git repo credentials to pull the private repo. Pre-create its
        // namespace + repo-creds secret here so the secret never lives in git; the
        // wave19 Helm release then deploys into this existing namespace (its
        // CreateNamespace becomes a no-op). The shared admin password hash is
        // injected by the wave19 Application's Helm parameters (same hash as infra).
        const argocdAppsNs = new k8s.core.v1.Namespace(
            "argocd-apps",
            { metadata: { name: "argocd-apps" } },
            {
                provider: k8sProvider,
                parent: this,
                customTimeouts: { delete: "600s" },
                ignoreChanges: ["metadata.finalizers"],
            },
        );

        new k8s.core.v1.Secret(
            "github-repo-creds-apps",
            {
                metadata: {
                    name: "argocd-repo-github-creds",
                    namespace: argocdAppsNs.metadata.name,
                    labels: { "argocd.argoproj.io/secret-type": "repository" },
                },
                stringData: {
                    type: "git",
                    url: project_settings.argocd.git.repoUrl,
                    sshPrivateKey: project_settings.argocd.git.deployKey,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [argocdAppsNs] },
        );

        // The argo-cd chart reads the admin password + server secret key from the
        // "argocd-secret" Secret. The apps values.yaml sets configs.secret.createSecret:
        // false so this Pulumi-managed secret (same admin hash as infra) is used
        // instead of one rendered from git. Pre-creating it keeps the hash/key out
        // of git while the wave19 Helm release supplies all non-secret values.
        new k8s.core.v1.Secret(
            "argocd-apps-secret",
            {
                metadata: {
                    name: "argocd-secret",
                    namespace: argocdAppsNs.metadata.name,
                    labels: {
                        "app.kubernetes.io/name": "argocd-secret",
                        "app.kubernetes.io/part-of": "argocd",
                    },
                },
                type: "Opaque",
                stringData: {
                    "admin.password": project_settings.argocd.adminPasswordHash,
                    "admin.passwordMtime": project_settings.argocd.adminPasswordMtime,
                    "server.secretkey": project_settings.argocd.serverSecretKey,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [argocdAppsNs] },
        );

        new k8s.apiextensions.CustomResource(
            "argocd-infra-app-of-apps",
            {
                apiVersion: "argoproj.io/v1alpha1",
                kind: "Application",
                metadata: { name: "argocd-infra-app-of-apps", namespace: argocdNs.metadata.name },
                spec: {
                    project: "default",
                    source: {
                        repoURL: project_settings.argocd.git.repoUrl,
                        targetRevision: project_settings.argocd.git.targetRevision,
                        path: "deployment/argocd-infra/app-of-apps",
                    },
                    destination: { name: "in-cluster", namespace: "default" },
                    syncPolicy: { automated: { prune: true, selfHeal: true } },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [...argocdChartDep, waitForArgocdCrds, sealedSecretsChart],
                retainOnDelete: true,
            },
        );

        this.registerOutputs({
            url: this.url,
            cliLoginCommand: this.cliLoginCommand,
            appsUrl: this.appsUrl,
            cliLoginCommandApps: this.cliLoginCommandApps,
        });
    }
}
