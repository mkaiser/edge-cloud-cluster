import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import type { NetworkComponent } from "./network";

export class StorageComponent extends pulumi.ComponentResource {
    public readonly hcloudSecret: k8s.core.v1.Secret;
    public readonly csiDriver: helm.v3.Release;
    public readonly longhornChart!: helm.v3.Release;
    public readonly longhornBackupTarget!: command.local.Command;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        networkComponent: NetworkComponent,
        kubeconfigRaw: pulumi.Output<string>,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:Storage", name, {}, opts);

        this.hcloudSecret = new k8s.core.v1.Secret(
            "hcloud-secret",
            {
                metadata: { name: "hcloud", namespace: "kube-system" },
                stringData: {
                    token: project_settings.general.hcloudToken,
                    network: networkComponent.network.id.apply((id) => String(id)),
                },
            },
            { provider: k8sProvider, parent: this },
        );

        const hcloudCcm =
            project_settings.server.os !== "Talos" &&
            project_settings.server.loadBalancerProvider === "hetzner-ccm"
                ? new helm.v3.Release(
                      "hcloud-ccm",
                      {
                          chart: "hcloud-cloud-controller-manager",
                          version: "1.31.1",
                          namespace: "kube-system",
                          repositoryOpts: { repo: "https://charts.hetzner.cloud" },
                      },
                      { provider: k8sProvider, parent: this, dependsOn: [this.hcloudSecret] },
                  )
                : null;

        this.csiDriver = new helm.v3.Release(
            "hcloud-csi",
            {
                chart: "hcloud-csi",
                version: "2.21.2",
                namespace: "kube-system",
                repositoryOpts: { repo: "https://charts.hetzner.cloud" },
                values: {
                    storageClasses: [
                        {
                            name: "hcloud-ssd-volumes",
                            defaultStorageClass: false,
                            reclaimPolicy: "Retain",
                        },
                    ],
                    // Restrict the CSI node DaemonSet to Hetzner Cloud nodes only.
                    // Edge/external worker nodes lack the Hetzner metadata server
                    // so the csi-driver container crashes on them.
                    // csi.hetzner.cloud/location is applied by hcloud-ccm to every
                    // Hetzner node regardless of region; Exists covers all locations.
                    node: {
                        affinity: {
                            nodeAffinity: {
                                requiredDuringSchedulingIgnoredDuringExecution: {
                                    nodeSelectorTerms: [
                                        {
                                            matchExpressions: [
                                                {
                                                    key: "csi.hetzner.cloud/location",
                                                    operator: "Exists",
                                                },
                                            ],
                                        },
                                    ],
                                },
                            },
                        },
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [this.hcloudSecret, ...(hcloudCcm ? [hcloudCcm] : [])],
            },
        );

        const s3CsiDriver = new helm.v3.Release(
            "csi-s3",
            {
                chart: "csi-s3",
                version: "0.43.7",
                namespace: "kube-system",
                repositoryOpts: { repo: "https://yandex-cloud.github.io/k8s-csi-s3/charts" },
                values: {
                    storageClass: { create: false },
                    secret: {
                        create: true,
                        name: "csi-s3-secret",
                        accessKey: project_settings.storage.objectStorage.accessKey,
                        secretKey: project_settings.storage.objectStorage.secretKey,
                        endpoint: pulumi.interpolate`https://${project_settings.storage.objectStorage.baseEndpoint}`,
                    },
                },
            },
            { provider: k8sProvider, parent: this },
        );

        new k8s.storage.v1.StorageClass(
            "hcloud-s3",
            {
                metadata: { name: "hcloud-s3" },
                provisioner: "ru.yandex.s3.csi",
                parameters: {
                    mounter: "geesefs",
                    options: "--memory-limit 1000 --dir-mode 0777 --file-mode 0666",
                    "csi.storage.k8s.io/provisioner-secret-name": "csi-s3-secret",
                    "csi.storage.k8s.io/provisioner-secret-namespace": "kube-system",
                    "csi.storage.k8s.io/controller-publish-secret-name": "csi-s3-secret",
                    "csi.storage.k8s.io/controller-publish-secret-namespace": "kube-system",
                    "csi.storage.k8s.io/node-stage-secret-name": "csi-s3-secret",
                    "csi.storage.k8s.io/node-stage-secret-namespace": "kube-system",
                    "csi.storage.k8s.io/node-publish-secret-name": "csi-s3-secret",
                    "csi.storage.k8s.io/node-publish-secret-namespace": "kube-system",
                },
                reclaimPolicy: "Delete",
            },
            { provider: k8sProvider, parent: this, dependsOn: [s3CsiDriver] },
        );

        // Namespace, SA, and S3 credentials for Longhorn — seeded before ArgoCD wave 0
        // so the Helm pre-upgrade hook can run on fresh install (needs longhorn-service-account).
        const longhornNs = new k8s.core.v1.Namespace(
            "longhorn-system-ns",
            { metadata: { name: "longhorn-system" } },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "5m" } },
        );

        const longhornS3Secret = new k8s.core.v1.Secret(
            "longhorn-s3-credentials",
            {
                metadata: { name: "longhorn-s3-credentials", namespace: "longhorn-system" },
                stringData: {
                    AWS_ACCESS_KEY_ID: project_settings.storage.objectStorage.accessKey,
                    AWS_SECRET_ACCESS_KEY: project_settings.storage.objectStorage.secretKey,
                    AWS_ENDPOINTS: pulumi.interpolate`https://${project_settings.storage.objectStorage.baseEndpoint}`,
                    VIRTUAL_HOSTED_STYLE: "false",
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [longhornNs], retainOnDelete: true },
        );

        // Bootstrap Longhorn so the restore step can run before ArgoCD starts.
        // retainOnDelete: longhorn-pre-destroy handles kubectl cleanup on destroy;
        // Pulumi must not helm-uninstall (finalizers would deadlock namespace deletion).
        this.longhornChart = new helm.v3.Release(
            "longhorn",
            {
                chart: "longhorn",
                version: "1.12.0", // renovate: datasource=helm depName=longhorn registryUrl=https://charts.longhorn.io
                namespace: "longhorn-system",
                repositoryOpts: { repo: "https://charts.longhorn.io" },
                values: {
                    defaultSettings: {
                        defaultReplicaCount: 2,
                        createDefaultDiskLabeledNodes: true,
                        dataLocality: "best-effort",
                        replicaSoftAntiAffinity: true,
                        recurringFailedJobsHistoryLimit: 14,
                        recurringSuccessfulJobsHistoryLimit: 14,
                    },
                    persistence: {
                        defaultClass: true,
                        defaultClassReplicaCount: 2,
                        reclaimPolicy: "Retain",
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [longhornNs, longhornS3Secret],
                retainOnDelete: true,
                customTimeouts: { create: "10m" },
            },
        );

        // Wait until Longhorn engine images are deployed and longhorn-manager is fully ready.
        // Must complete before the backup target is configured and before ArgoCD wave 2
        // can create PVCs (postgresql helm hooks etc.).
        const longhornReady = new command.local.Command(
            "longhorn-ready",
            {
                create: `TMPKC=$(mktemp)
cleanup() { rm -f "$TMPKC"; }
trap cleanup EXIT
printf '%s\n' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"

i=0
while [ "$i" -lt 60 ]; do
  NOT_DEPLOYED=$(kubectl get engineimage -n longhorn-system \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.state}{"\\n"}{end}' \
    2>/dev/null | grep -v '=deployed' | grep -v '^$' || true)
  TOTAL_EI=$(kubectl get engineimage -n longhorn-system \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  DESIRED=$(kubectl get daemonset longhorn-manager -n longhorn-system \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  READY=$(kubectl get daemonset longhorn-manager -n longhorn-system \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  if [ -z "$NOT_DEPLOYED" ] && [ "$TOTAL_EI" -gt 0 ] && \
     [ "$DESIRED" -gt 0 ] && [ "$READY" = "$DESIRED" ]; then
    echo "Longhorn ready: $TOTAL_EI engine image(s) deployed, longhorn-manager $READY/$DESIRED."
    exit 0
  fi
  echo "Attempt $i/60 — engineimages: total=$TOTAL_EI not-deployed=\${NOT_DEPLOYED:-none}; manager: $READY/$DESIRED"
  sleep 10
  i=$((i+1))
done
echo "ERROR: Longhorn not ready after 10 minutes"
exit 1`,
                delete: "true",
                environment: { KUBECONFIG_CONTENT: kubeconfigRaw },
            },
            { parent: this, dependsOn: [this.longhornChart], customTimeouts: { create: "12m" } },
        );

        // Configure the S3 backup target before the restore step runs.
        // Longhorn Helm chart already creates BackupTarget "default" with an empty spec,
        // so we patch it via SSA (--server-side --force-conflicts) instead of creating.
        const longhornBucket = project_settings.storage.objectStorage.buckets.find(
            (b) => b.key === "longhornBackup",
        )!;
        this.longhornBackupTarget = new command.local.Command(
            "longhorn-backup-target",
            {
                create: `TMPKC=$(mktemp)
cleanup() { rm -f "$TMPKC"; }
trap cleanup EXIT
printf '%s\n' "$KUBECONFIG_CONTENT" > "$TMPKC"
kubectl --kubeconfig="$TMPKC" apply --server-side --force-conflicts --validate=false -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: "s3://${longhornBucket.name}@${longhornBucket.location}/"
  credentialSecret: longhorn-s3-credentials
  pollInterval: 5m0s
EOF`,
                delete: "true",
                environment: { KUBECONFIG_CONTENT: kubeconfigRaw },
            },
            { parent: this, dependsOn: [longhornReady] },
        );

        for (const bucket of project_settings.storage.objectStorage.buckets) {
            const endpoint = `https://${bucket.location}.your-objectstorage.com`;
            new command.local.Command(
                `ensure-s3-bucket-${bucket.key}`,
                {
                    create: [
                        `aws s3api head-bucket`,
                        `  --bucket "${bucket.name}"`,
                        `  --endpoint-url "${endpoint}"`,
                        `  --region "${bucket.location}"`,
                        `  2>/dev/null`,
                        `|| aws s3api create-bucket`,
                        `  --bucket "${bucket.name}"`,
                        `  --endpoint-url "${endpoint}"`,
                        `  --region "${bucket.location}"`,
                    ].join(" \\\n"),
                    delete: project_settings.general.completeClusterTeardown
                        ? `aws s3 rb s3://${bucket.name} --force --endpoint-url "${endpoint}" --region "${bucket.location}"`
                        : "true",
                    environment: {
                        AWS_ACCESS_KEY_ID: project_settings.storage.objectStorage.accessKey,
                        AWS_SECRET_ACCESS_KEY: project_settings.storage.objectStorage.secretKey,
                        AWS_DEFAULT_REGION: bucket.location,
                        AWS_PAGER: "",
                    },
                },
                { parent: this },
            );
        }

        // On destroy: fully drain longhorn-system before the namespace is deleted.
        // Runs before longhornNs deletion (dependsOn), preventing the namespace from
        // getting stuck in Terminating when webhook pods are already gone.
        new command.local.Command(
            "longhorn-pre-destroy",
            {
                create: "true",
                delete: [
                    // Every kubectl call is wrapped with `timeout 30` so no single
                    // command can block the destroy indefinitely.
                    // Stop ArgoCD from re-creating Longhorn resources during the destroy window.
                    "timeout 30 kubectl delete application longhorn -n argocd --ignore-not-found 2>/dev/null || true",
                    // Remove admission webhooks that block CR deletion once their pods are gone.
                    "timeout 30 kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true",
                    "timeout 30 kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true",
                    // Scale down all workloads so pods terminate gracefully.
                    "timeout 30 kubectl scale deployment --all -n longhorn-system --replicas=0 2>/dev/null || true",
                    "timeout 30 kubectl scale daemonset --all -n longhorn-system --replicas=0 2>/dev/null || true",
                    // Strip finalizers from ALL Longhorn CRs (dynamic discovery avoids stale hardcoded lists).
                    "for crd in $(timeout 30 kubectl get crd -o name 2>/dev/null | grep '\\.longhorn\\.io'); do",
                    "  kind=$(timeout 15 kubectl get \"$crd\" -o jsonpath='{.spec.names.plural}' 2>/dev/null || true)",
                    '  [ -z "$kind" ] && continue',
                    '  timeout 30 kubectl get "${kind}" -n longhorn-system -o name 2>/dev/null | while read r; do',
                    '    timeout 15 kubectl patch "$r" -n longhorn-system --type=merge -p \'{"metadata":{"finalizers":[]}}\' 2>/dev/null || true',
                    "  done",
                    "done",
                    // Delete all CRD instances so nothing blocks namespace deletion.
                    "for crd in $(timeout 30 kubectl get crd -o name 2>/dev/null | grep '\\.longhorn\\.io'); do",
                    "  kind=$(timeout 15 kubectl get \"$crd\" -o jsonpath='{.spec.names.plural}' 2>/dev/null || true)",
                    '  [ -z "$kind" ] && continue',
                    '  timeout 60 kubectl delete "${kind}" --all -n longhorn-system --force --grace-period=0 2>/dev/null || true',
                    "done",
                    // Force-terminate any remaining pods.
                    "timeout 30 kubectl delete pods -n longhorn-system --all --force --grace-period=0 2>/dev/null || true",
                    // Delete the namespace now so Pulumi sees a 404 (= already gone = success).
                    // If it gets stuck in Terminating, strip its own finalizers via the finalize API.
                    "timeout 30 kubectl delete namespace longhorn-system --force --grace-period=0 2>/dev/null || true",
                    "for i in $(seq 1 24); do",
                    "  PHASE=$(timeout 10 kubectl get namespace longhorn-system -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)",
                    '  [ "$PHASE" = "gone" ] || [ -z "$PHASE" ] && break',
                    '  if [ "$PHASE" = "Terminating" ]; then',
                    "    timeout 10 kubectl get namespace longhorn-system -o json 2>/dev/null \\",
                    "      | python3 -c \"import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))\" \\",
                    "      | timeout 15 kubectl replace --raw /api/v1/namespaces/longhorn-system/finalize -f - 2>/dev/null || true",
                    "  fi",
                    "  sleep 5",
                    "done",
                ].join("\n"),
            },
            {
                parent: this,
                dependsOn: [longhornNs, this.longhornChart],
                customTimeouts: { delete: "20m" },
            },
        );

        this.registerOutputs({
            hcloudSecret: this.hcloudSecret,
            csiDriver: this.csiDriver,
        });
    }
}
