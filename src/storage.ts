import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as helm from "@pulumi/kubernetes/helm";
import * as command from "@pulumi/command";
import type { ClusterOS, ControlPlaneNode, LoadBalancerProvider } from "./types";
import type { PulumiSecrets } from "./pulumi_secrets";

export interface StorageArgs {
    k8sProvider: k8s.Provider;
    hProvider: hcloud.Provider;
    pulumiSecrets: PulumiSecrets;
    network: hcloud.Network;
    cluster: {
        os: ClusterOS;
        loadBalancerProvider: LoadBalancerProvider;
        completeClusterTeardown: boolean;
    };
    controlPlaneNodes: ControlPlaneNode[];
    objectStorage: {
        baseEndpoint: string;
    };
    backupStorage: {
        host: string;
    };
    blockStorage: {
        nfsSsdVolumeSize: string;
    };
    features: {
        enableTestS3Storage: boolean;
        enableTestSsdVolume: boolean;
        enableTestSsdVolumeNfs: boolean;
    };
}

export class StorageComponent extends pulumi.ComponentResource {
    public readonly hcloudSecret: k8s.core.v1.Secret;
    public readonly csiDriver: helm.v3.Release;
    public readonly nfsCsiDriver: helm.v3.Release;
    public readonly nfsServerProvisioner: helm.v3.Release;

    constructor(name: string, args: StorageArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:Storage", name, {}, opts);

        const {
            k8sProvider,
            hProvider,
            network,
            pulumiSecrets,
            cluster,
            controlPlaneNodes,
            objectStorage,
            backupStorage,
            blockStorage,
            features,
        } = args;

        const { os: clusterOS, loadBalancerProvider, completeClusterTeardown } = cluster;
        const { baseEndpoint: hetznerS3BaseEndpoint } = objectStorage;
        const { host: storageboxHost } = backupStorage;
        const { nfsSsdVolumeSize } = blockStorage;
        const nfsSsdVolumeLocation = controlPlaneNodes[0].location;
        const { enableTestS3Storage, enableTestSsdVolume, enableTestSsdVolumeNfs } = features;

        const useHetznerCcm = loadBalancerProvider === "hetzner-ccm";

        // Secret must be named "hcloud" in kube-system — CSI driver and CCM look for this exact name.
        this.hcloudSecret = new k8s.core.v1.Secret(
            "hcloud-secret",
            {
                metadata: { name: "hcloud", namespace: "kube-system" },
                stringData: {
                    token: pulumiSecrets.hcloudToken,
                    network: network.id.apply((id) => String(id)),
                },
            },
            { provider: k8sProvider, parent: this },
        );

        // For Debian/K3s in Hetzner CCM mode, deploy external cloud-controller-manager.
        const hcloudCcm =
            clusterOS !== "Talos" && useHetznerCcm
                ? new helm.v3.Release(
                      "hcloud-ccm",
                      {
                          chart: "hcloud-cloud-controller-manager",
                          version: "v1.30.1", // https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases
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
                version: "2.20.0", // https://github.com/hetznercloud/helm-charts
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
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [this.hcloudSecret, ...(hcloudCcm ? [hcloudCcm] : [])],
            },
        );

        this.nfsCsiDriver = new helm.v3.Release(
            "nfs-csi",
            {
                chart: "csi-driver-nfs",
                version: "4.13.1", // https://github.com/kubernetes-csi/csi-driver-nfs
                namespace: "kube-system",
                repositoryOpts: {
                    repo: "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts",
                },
            },
            { provider: k8sProvider, parent: this },
        );

        // StorageClass: Hetzner Storagebox (NFS)
        new k8s.storage.v1.StorageClass(
            "hcloud-storagebox",
            {
                metadata: { name: "hcloud-storagebox" },
                provisioner: "nfs.csi.k8s.io",
                parameters: { server: storageboxHost, share: "/", mountPermissions: "0770" },
                reclaimPolicy: "Retain",
                volumeBindingMode: "Immediate",
                mountOptions: ["nfsvers=3", "hard", "noatime"],
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.nfsCsiDriver] },
        );

        // S3 CSI Driver
        const s3CsiDriver = new helm.v3.Release(
            "csi-s3",
            {
                chart: "csi-s3",
                version: "v0.43.4", //  https://github.com/yandex-cloud/k8s-csi-s3/releases
                namespace: "kube-system",
                repositoryOpts: { repo: "https://yandex-cloud.github.io/k8s-csi-s3/charts" },
                values: {
                    storageClass: { create: false },
                    secret: {
                        create: true,
                        name: "csi-s3-secret",
                        accessKey: pulumiSecrets.hetznerS3AccessKey,
                        secretKey: pulumiSecrets.hetznerS3SecretKey,
                        endpoint: pulumi.interpolate`https://${hetznerS3BaseEndpoint}`,
                    },
                },
            },
            { provider: k8sProvider, parent: this },
        );

        const storageS3 = new k8s.storage.v1.StorageClass(
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

        /////////////////////
        // In-cluster NFS shared storage (NFS-Ganesha over SSD)
        /////////////////////

        // Auto-imports the volume if it already exists (survives pulumi down due to retainOnDelete).
        const existingVolumeId =
            require("child_process")
                .execSync(
                    `hcloud volume list -o noheader -o columns=id,name | awk '$2 == "volume-ssd-infra" {print $1}'`,
                    { encoding: "utf-8", timeout: 10000 },
                )
                .trim() || undefined;

        const volumeSsdInfra = new hcloud.Volume(
            "volume-ssd-infra",
            {
                name: "volume-ssd-infra",
                size: parseInt(nfsSsdVolumeSize),
                location: nfsSsdVolumeLocation,
                format: "ext4",
                labels: { "managed-by": "pulumi", purpose: "infra-nfs-backing" },
            },
            {
                provider: hProvider,
                parent: this,
                // completeClusterTeardown=true → full wipe, delete the volume.
                // completeClusterTeardown=false → cluster recreation, keep NFS data.
                retainOnDelete: !completeClusterTeardown,
                ...(existingVolumeId ? { import: existingVolumeId } : {}),
            },
        );

        const removePvFinalizer = completeClusterTeardown
            ? new command.local.Command(
                  "remove-pv-finalizer",
                  {
                      create: "echo 'PV finalizer removal ready (runs on destroy only)'",
                      delete: pulumi.interpolate`export KUBECONFIG=~/.kube/config; \
kubectl patch pv pv-ssd-infra -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true; \
echo "PV finalizer removed"`,
                      triggers: [],
                  },
                  { parent: this },
              )
            : null;

        const pvSsdInfra = new k8s.core.v1.PersistentVolume(
            "pv-ssd-infra",
            {
                metadata: { name: "pv-ssd-infra" },
                spec: {
                    capacity: { storage: nfsSsdVolumeSize },
                    accessModes: ["ReadWriteOnce"],
                    persistentVolumeReclaimPolicy: "Retain",
                    storageClassName: "hcloud-ssd-volumes",
                    csi: {
                        driver: "csi.hetzner.cloud",
                        volumeHandle: volumeSsdInfra.id.apply((id) => String(id)),
                        fsType: "ext4",
                    },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                retainOnDelete: true,
                dependsOn: [
                    this.csiDriver,
                    volumeSsdInfra,
                    ...(removePvFinalizer ? [removePvFinalizer] : []),
                ],
            },
        );

        const nfsNs = new k8s.core.v1.Namespace(
            "nfs-server-ns",
            {
                metadata: { name: "nfs-server" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        const nfsServerBackingPvc = new k8s.core.v1.PersistentVolumeClaim(
            "nfs-server-backing-pvc",
            {
                metadata: {
                    name: "nfs-server-data",
                    namespace: "nfs-server",
                    annotations: { "pulumi.com/skipAwait": "true" },
                },
                spec: {
                    storageClassName: "hcloud-ssd-volumes",
                    volumeName: "pv-ssd-infra",
                    accessModes: ["ReadWriteOnce"],
                    resources: { requests: { storage: nfsSsdVolumeSize } },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [pvSsdInfra, nfsNs],
                ignoreChanges: ["spec"],
                retainOnDelete: true,
            },
        );

        this.nfsServerProvisioner = new helm.v3.Release(
            "nfs-server-provisioner",
            {
                chart: "nfs-server-provisioner",
                version: "1.8.0", // https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner/releases
                namespace: "nfs-server",
                repositoryOpts: {
                    repo: "https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/",
                },
                timeout: 600, // seconds — Hetzner volume attach can be slow on first run
                waitForJobs: true,
                values: {
                    persistence: { enabled: true, existingClaim: "nfs-server-data" },
                    storageClass: {
                        create: true,
                        name: "hcloud-nfs-ssd-volumes",
                        defaultClass: false,
                        reclaimPolicy: "Retain",
                    },
                    securityContext: { capabilities: { add: ["DAC_READ_SEARCH", "SYS_RESOURCE"] } },
                    nodeSelector: {
                        "node-role.kubernetes.io/control-plane": "true",
                        "csi.hetzner.cloud/location": nfsSsdVolumeLocation,
                    },
                    tolerations: [
                        {
                            key: "node-role.kubernetes.io/control-plane",
                            operator: "Exists",
                            effect: "NoSchedule",
                        },
                    ],
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [nfsServerBackingPvc] },
        );

        const testingStorageNs = new k8s.core.v1.Namespace(
            "testing-storage-ns",
            {
                metadata: { name: "testing-storage" },
            },
            { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
        );

        new k8s.core.v1.PersistentVolumeClaim(
            "testing-nfs-pvc",
            {
                metadata: {
                    name: "testing-nfs",
                    namespace: "testing-storage",
                    annotations: { "pulumi.com/skipAwait": "true" },
                },
                spec: {
                    storageClassName: "hcloud-nfs-ssd-volumes",
                    accessModes: ["ReadWriteMany"],
                    resources: { requests: { storage: "5Gi" } },
                },
            },
            {
                provider: k8sProvider,
                parent: this,
                dependsOn: [testingStorageNs, this.nfsServerProvisioner],
                ignoreChanges: ["spec"],
            },
        );

        /////////////////////
        // Test Storage Pods (optional, gated by feature flags)
        /////////////////////

        const storageTestScript = `#!/bin/sh
set -e
DATAFILE=/data/persistence-test.log
echo "=== $(date -Iseconds) | Pod start ===" >> "$DATAFILE"
echo "Pod: $HOSTNAME" >> "$DATAFILE"
COUNT=$(grep -c "Pod start" "$DATAFILE" || true)
echo "Volume is mounted and writable"
echo "This pod has started $COUNT time(s)"
cat "$DATAFILE"
tail -f /dev/null`;

        if (enableTestS3Storage) {
            const ns = new k8s.core.v1.Namespace(
                "test-s3-ns",
                { metadata: { name: "test-s3-storage" } },
                { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
            );
            const pvc = new k8s.core.v1.PersistentVolumeClaim(
                "test-s3-pvc",
                {
                    metadata: {
                        name: "test-s3-pvc",
                        namespace: "test-s3-storage",
                        annotations: { "pulumi.com/skipAwait": "true" },
                    },
                    spec: {
                        storageClassName: "hcloud-s3",
                        accessModes: ["ReadWriteMany"],
                        resources: { requests: { storage: "1Gi" } },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns, storageS3] },
            );
            const cm = new k8s.core.v1.ConfigMap(
                "test-s3-script",
                {
                    metadata: { name: "test-s3-script", namespace: "test-s3-storage" },
                    data: { "run.sh": storageTestScript },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns] },
            );
            new k8s.apps.v1.Deployment(
                "test-s3-deployment",
                {
                    metadata: { name: "test-s3", namespace: "test-s3-storage" },
                    spec: {
                        replicas: 1,
                        selector: { matchLabels: { app: "test-s3" } },
                        template: {
                            metadata: { labels: { app: "test-s3" } },
                            spec: {
                                containers: [
                                    {
                                        name: "tester",
                                        image: "busybox:1.36",
                                        command: ["sh", "/scripts/run.sh"],
                                        volumeMounts: [
                                            { name: "data", mountPath: "/data" },
                                            { name: "script", mountPath: "/scripts" },
                                        ],
                                    },
                                ],
                                volumes: [
                                    {
                                        name: "data",
                                        persistentVolumeClaim: { claimName: "test-s3-pvc" },
                                    },
                                    {
                                        name: "script",
                                        configMap: { name: "test-s3-script", defaultMode: 0o755 },
                                    },
                                ],
                            },
                        },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [pvc, cm] },
            );
        }

        if (enableTestSsdVolume) {
            const ns = new k8s.core.v1.Namespace(
                "test-ssd-ns",
                { metadata: { name: "test-ssd-volume" } },
                { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
            );
            const pvc = new k8s.core.v1.PersistentVolumeClaim(
                "test-ssd-pvc",
                {
                    metadata: {
                        name: "test-ssd-pvc",
                        namespace: "test-ssd-volume",
                        annotations: { "pulumi.com/skipAwait": "true" },
                    },
                    spec: {
                        storageClassName: "hcloud-ssd-volumes",
                        accessModes: ["ReadWriteOnce"],
                        resources: { requests: { storage: "10Gi" } },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns, this.csiDriver] },
            );
            const cm = new k8s.core.v1.ConfigMap(
                "test-ssd-script",
                {
                    metadata: { name: "test-ssd-script", namespace: "test-ssd-volume" },
                    data: { "run.sh": storageTestScript },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns] },
            );
            new k8s.apps.v1.Deployment(
                "test-ssd-deployment",
                {
                    metadata: { name: "test-ssd", namespace: "test-ssd-volume" },
                    spec: {
                        replicas: 1,
                        selector: { matchLabels: { app: "test-ssd" } },
                        template: {
                            metadata: { labels: { app: "test-ssd" } },
                            spec: {
                                containers: [
                                    {
                                        name: "tester",
                                        image: "busybox:1.36",
                                        command: ["sh", "/scripts/run.sh"],
                                        volumeMounts: [
                                            { name: "data", mountPath: "/data" },
                                            { name: "script", mountPath: "/scripts" },
                                        ],
                                    },
                                ],
                                volumes: [
                                    {
                                        name: "data",
                                        persistentVolumeClaim: { claimName: "test-ssd-pvc" },
                                    },
                                    {
                                        name: "script",
                                        configMap: { name: "test-ssd-script", defaultMode: 0o755 },
                                    },
                                ],
                            },
                        },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [pvc, cm] },
            );
        }

        if (enableTestSsdVolumeNfs) {
            const ns = new k8s.core.v1.Namespace(
                "test-nfs-ns",
                { metadata: { name: "test-ssd-volume-nfs" } },
                { provider: k8sProvider, parent: this, customTimeouts: { delete: "60s" } },
            );
            const pvc = new k8s.core.v1.PersistentVolumeClaim(
                "test-nfs-pvc",
                {
                    metadata: {
                        name: "test-nfs-pvc",
                        namespace: "test-ssd-volume-nfs",
                        annotations: { "pulumi.com/skipAwait": "true" },
                    },
                    spec: {
                        storageClassName: "hcloud-nfs-ssd-volumes",
                        accessModes: ["ReadWriteMany"],
                        resources: { requests: { storage: "1Gi" } },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns, this.nfsServerProvisioner] },
            );
            const cm = new k8s.core.v1.ConfigMap(
                "test-nfs-script",
                {
                    metadata: { name: "test-nfs-script", namespace: "test-ssd-volume-nfs" },
                    data: { "run.sh": storageTestScript },
                },
                { provider: k8sProvider, parent: this, dependsOn: [ns] },
            );
            new k8s.apps.v1.Deployment(
                "test-nfs-deployment",
                {
                    metadata: { name: "test-nfs", namespace: "test-ssd-volume-nfs" },
                    spec: {
                        replicas: 1,
                        selector: { matchLabels: { app: "test-nfs" } },
                        template: {
                            metadata: { labels: { app: "test-nfs" } },
                            spec: {
                                containers: [
                                    {
                                        name: "tester",
                                        image: "busybox:1.36",
                                        command: ["sh", "/scripts/run.sh"],
                                        volumeMounts: [
                                            { name: "data", mountPath: "/data" },
                                            { name: "script", mountPath: "/scripts" },
                                        ],
                                    },
                                ],
                                volumes: [
                                    {
                                        name: "data",
                                        persistentVolumeClaim: { claimName: "test-nfs-pvc" },
                                    },
                                    {
                                        name: "script",
                                        configMap: { name: "test-nfs-script", defaultMode: 0o755 },
                                    },
                                ],
                            },
                        },
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [pvc, cm] },
            );
        }

        this.registerOutputs({
            hcloudSecret: this.hcloudSecret,
            csiDriver: this.csiDriver,
            nfsCsiDriver: this.nfsCsiDriver,
            nfsServerProvisioner: this.nfsServerProvisioner,
        });
    }
}
