/**
 * Project: edgecloudinfra
 * File: storage.ts
 * Purpose: Storage component and Longhorn handling.
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
import type { NetworkComponent } from "./network";

// The ecc/* label keys. Declared once in project_settings.applicationPlacements;
// never write the literal here (checkSiteAnchors.py fails the commit on one).
const ECC = project_settings.applicationPlacements.labels;

// ─────────────────────────────────────────────────────────────────────────────
// High-availability guard.
//
// highAvailability.enabled is an explicit intent flag. When set, the cluster
// must have ≥3 control-plane nodes (etcd quorum) — otherwise the deploy fails
// fast with a clear message instead of silently running degraded.
// ─────────────────────────────────────────────────────────────────────────────
// enabled:false parks a node (never built) → exclude it: the HA "≥3 CPs" check and the
// Longhorn replica derivation must count only nodes that will actually exist.
const enabledCloud = project_settings.nodes.cloud.filter((n) => n.enabled !== false);
const controlPlaneNodes = enabledCloud.filter((n) => n.k8sRole === "controlplane");
if (project_settings.highAvailability.enabled && controlPlaneNodes.length < 3) {
    throw new pulumi.RunError(
        `highAvailability.enabled requires ≥3 control-plane nodes; currently ` +
            `${controlPlaneNodes.length} configured in project_settings.ts`,
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Longhorn replica count — derived from cloud-node topology, not hardcoded.
//
// Every nodes.cloud node is Hetzner-hosted (cloud disks) and counts as a replica
// target for the default `longhorn` StorageClass. Mesh nodes live in nodes.mesh and
// are excluded by construction: mixing cloud and mesh replicas in one volume forces
// every write to wait for a WAN round-trip — mesh-local data uses the per-scope
// `longhorn-<scope>` StorageClasses instead.
//
// With "auto": replicas track the cloud node count, capped at 3. Soft
// anti-affinity means asking for more replicas than nodes would just pile copies
// on one disk, so we never exceed the node count.
//   1 node  → 1 replica  (no wasted double-reservation on a single disk)
//   2 nodes → 2 replicas
//   3+ nodes → 3
// An explicit 1 | 2 | 3 overrides the derivation regardless of node count.
// ─────────────────────────────────────────────────────────────────────────────
const longhornNodeCount = enabledCloud.length;
const longhornReplicaCount: number =
    project_settings.storage.longhorn.replicaCount === "auto"
        ? Math.max(1, Math.min(3, longhornNodeCount))
        : project_settings.storage.longhorn.replicaCount;

// Mesh nodes are managed by Pulumi only when listed in nodes.mesh. When present,
// the default `longhorn` class is pinned to cloud disks/nodes and one
// `longhorn-<scope>` class is created per distinct storage scope for mesh-local
// workloads.
// Disabled entries are declared-but-not-joined, so they must NOT count toward scope
// replica targets — a scope whose only other node is disabled would ask Longhorn for
// more replicas than there are nodes carrying the tag, and the volume then never
// schedules an engine (it sits `detached`, attach returns 200, nothing starts).
const meshNodes = project_settings.nodes.mesh.filter((n) => n.enabled !== false);
const hasMeshNodes = meshNodes.length > 0;

// The set of distinct storageScope tags across all mesh nodes, in first-seen order.
// Each becomes one `longhorn-<scope>` StorageClass (diskSelector: "<scope>"). A scope
// shared across LANs (e.g. "unibi") spans those LANs → cross-LAN redundancy; a scope
// unique to one LAN keeps replicas strictly local.
const storageScopes: string[] = [...new Set(meshNodes.flatMap((n) => n.storageScope))];

// How many mesh nodes carry a given scope tag → replica target for that scope's class
// (capped at 3; a single-node scope is replica 1, with S3 backup as the net).
//
// NODES, not disks — and that is deliberate. `replicaSoftAntiAffinity: true` below makes
// Longhorn prefer distinct NODES for a volume's replicas, so a node contributing several
// disks (extraLonghornDisks) still buys one failure domain, not several. Counting disks here
// would inflate the replica target past the number of machines that can actually hold one,
// and the surplus replica would sit unschedulable.
const nodesCarryingScope = (scope: string): number =>
    meshNodes.filter((n) => n.storageScope.includes(scope)).length;

export class StorageComponent extends pulumi.ComponentResource {
    public readonly hcloudSecret: k8s.core.v1.Secret;
    public readonly csiDriver: helm.v3.Release | null;
    public readonly longhornChart!: helm.v3.Release;
    public readonly longhornBackupTarget!: command.local.Command;

    constructor(
        name: string,
        k8sProvider: k8s.Provider,
        networkComponent: NetworkComponent,
        kubeconfigRaw: pulumi.Output<string>,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("ecc:infra:Storage", name, {}, opts);

        this.hcloudSecret = new k8s.core.v1.Secret(
            "hcloud-secret",
            {
                metadata: { name: "hcloud", namespace: "kube-system" },
                stringData: {
                    token: project_settings.hetzner.hcloudToken,
                    network: networkComponent.network.id.apply((id) => String(id)),
                },
            },
            { provider: k8sProvider, parent: this },
        );

        const hcloudCcm =
            project_settings.general.loadBalancerProvider === "hetzner-ccm"
                ? new helm.v3.Release(
                      "hcloud-ccm",
                      {
                          chart: "hcloud-cloud-controller-manager",
                          version: "1.37.0",
                          namespace: "kube-system",
                          repositoryOpts: { repo: "https://charts.hetzner.cloud" },
                      },
                      { provider: k8sProvider, parent: this, dependsOn: [this.hcloudSecret] },
                  )
                : null;

        // The hcloud CSI driver is only usable when the Hetzner CCM runs:
        // CCM applies the csi.hetzner.cloud/location label that the node
        // DaemonSet's affinity requires, and the csi-driver container reaches
        // the cloud metadata server (169.254.169.254) — absent on robot/mesh
        // nodes. Without CCM the controller Deployment crash-loops and the
        // node DaemonSet schedules nothing, so skip the release entirely.
        this.csiDriver =
            hcloudCcm === null
                ? null
                : new helm.v3.Release(
                      "hcloud-csi",
                      {
                          chart: "hcloud-csi",
                          version: "2.23.0",
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
                              // Mesh/external worker nodes lack the Hetzner metadata server
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
                          dependsOn: [this.hcloudSecret, hcloudCcm],
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
                version: "1.12.1", // renovate: datasource=helm depName=longhorn registryUrl=https://charts.longhorn.io
                namespace: "longhorn-system",
                repositoryOpts: { repo: "https://charts.longhorn.io" },
                values: {
                    // Mesh nodes carry the ecc/mesh=true:NoSchedule taint. Longhorn must
                    // tolerate it on BOTH component families or the mesh node stays
                    // storage-dead (no manager → mesh disk never initialized → longhorn-<scope>
                    // PVCs fail with "specified disk tag <scope> does not exist"):
                    //   - global.tolerations → user-deployed components (manager + CSI plugin
                    //     DaemonSets, driver-deployer, UI).
                    //   - defaultSettings.taintToleration → system-managed components
                    //     (instance-manager, engine-image, share-manager); semicolon-
                    //     separated kubectl-taint syntax, NOT a list.
                    // Tolerations only PERMIT scheduling — DaemonSets still land on every
                    // node, which is exactly what we want so the mesh node gets a manager
                    // that initializes its scope-tagged disk. Only set when mesh nodes exist
                    // so cloud-only clusters are byte-identical (no needless DaemonSet roll).
                    //
                    // ecc/gpu IS TOLERATED TOO — deliberately. GPU nodes are tainted
                    // `ecc/gpu=true:NoSchedule` so the scarce single-GPU box is opt-in for
                    // GPU CONSUMERS. Longhorn is not one: it is the storage plane, and a
                    // node that carries a storageScope must be able to host replicas of it.
                    // Without this, a GPU node is counted by nodesCarryingScope() (it has
                    // the scope in project_settings) but never appears in nodes.longhorn.io,
                    // so the class asks for more replicas than can exist and volumes sit
                    // degraded in an endless rebuild loop — e.g. a scope whose only carrier
                    // is GPU-tainted asks for 1 replica with ZERO nodes available.
                    ...(hasMeshNodes
                        ? {
                              global: {
                                  tolerations: [
                                      {
                                          key: ECC.mesh,
                                          operator: "Equal",
                                          value: "true",
                                          effect: "NoSchedule",
                                      },
                                      {
                                          key: ECC.gpu,
                                          operator: "Equal",
                                          value: "true",
                                          effect: "NoSchedule",
                                      },
                                  ],
                              },
                          }
                        : {}),
                    defaultSettings: {
                        // Replica count tracks node topology (see project_settings.ts).
                        // Single node → 1 (no pointless double-reservation on one disk);
                        // grows as control-plane/mesh nodes are added.
                        defaultReplicaCount: longhornReplicaCount,
                        createDefaultDiskLabeledNodes: true,
                        dataLocality: "best-effort",
                        replicaSoftAntiAffinity: true,
                        // Auto-spread replicas onto newly-added nodes so redundancy
                        // self-corrects on scale-out without manual rebalancing.
                        replicaAutoBalance: "best-effort",
                        recurringFailedJobsHistoryLimit: 14,
                        recurringSuccessfulJobsHistoryLimit: 14,
                        // Longhorn schedules against PROVISIONED replica size, not
                        // actual usage, and the default disk keeps a 30% reserve.
                        // On the cloud node that left ~350G schedulable against
                        // ~347G of thin-provisioned claims that were only ~32G full
                        // (one 53.7G volume held 1.1G), so the next app's PVCs went
                        // `faulted` with "insufficient storage" on a disk that was
                        // in fact 71% free. Raise further only alongside a real
                        // utilisation check — this permits genuine overcommit.
                        //
                        // 150 → 200 on 2026-09-15, with that check. The small mesh disk
                        // unibi-hclab-fs-vm (57.7G, the outlier among 0.9–1.8T peers on the
                        // same `unibi-hclab` tag) hit DiskPressure at 70.0G scheduled against
                        // a 60.6G limit, while being 50% PHYSICALLY FREE. It refused to place
                        // guacamole-pg's 5G replica, so remote-desktop's Guacamole database
                        // crash-looped on `chmod pgdata: input/output error` for ~4h. Measured
                        // across every `unibi-hclab` volume at the time: 248G provisioned vs
                        // 16.8G actually used = 6.8%, nothing above 66%. 200% is the smallest
                        // step that clears it (80.8G limit, +10.8G headroom); it does not make
                        // the disk itself bigger — fs-vm stays the real constraint.
                        storageOverProvisioningPercentage: 200,
                        // ⚠ RECLAIM REPLICA DIRECTORIES FROM DEAD CLUSTERS. A recreate
                        // leaves every mesh node's /var/lib/longhorn/replicas populated:
                        // `make destroy` has no delete path to a mesh box (they are adopted
                        // with create-only remote.Command resources) and the k3s uninstaller
                        // knows nothing about Longhorn, so without this the records accumulate
                        // across every cluster recreate — hundreds of them, hundreds of GiB.
                        // Enough to push a mesh disk under Longhorn's default 25%
                        // storageMinimalAvailablePercentage floor (not set here), at which it goes
                        // Schedulable=False (DiskPressure) and volumes cannot place replicas:
                        // an hour-plus of ContainerCreating against a faulted volume, for
                        // space nothing is using.
                        // ⚠ A SINGLE-NODE SITE HAS NO FALLBACK: one node carrying a
                        // storageScope tag usually means one candidate disk, so a refused disk
                        // is a volume that never schedules rather than one that degrades.
                        // (A node declaring extraLonghornDisks has more than one candidate —
                        // but they share a machine, so this still holds at node granularity.)
                        // Only ever deletes replicas with no owning volume, so this cannot
                        // touch live data. Grace period is Longhorn's default 300s.
                        orphanResourceAutoDeletion: "replica-data",

                        // ⚠ A DEAD MESH BOX OTHERWISE STRANDS ITS VOLUMES INDEFINITELY.
                        // Kubernetes marks an unreachable node NotReady but never force-deletes
                        // its pods — it cannot tell "rebooting" from "gone". Those pods sit
                        // Terminating holding their VolumeAttachments, and the CSI detach they
                        // wait on can never complete because that needs the unreachable node.
                        // The replacement pod then blocks on "Volume is already used by pod(s)
                        // <old>" with no timeout. Measured 2026-09-14: one lab box dropped and
                        // litellm + four ryax pods hung ~25 min until the pods and their
                        // VolumeAttachments were deleted by hand. Longhorn breaks the tie
                        // because it knows what Kubernetes does not — whether the volume's
                        // replicas are reachable elsewhere. Both workload kinds: the stuck pods
                        // were Deployments, which `delete-statefulset-pod` would not cover.
                        nodeDownPodDeletionPolicy: "delete-both-statefulset-and-deployment-pod",

                        // System-managed component toleration for the mesh + gpu taints (see
                        // above). Semicolon-separated kubectl-taint syntax, NOT a list — and
                        // it must stay in step with global.tolerations or the system-managed
                        // components (instance-manager, engine-image, share-manager) stay off
                        // GPU nodes even though the manager runs there, which is the same
                        // storage-dead node by a subtler route.
                        ...(hasMeshNodes
                            ? {
                                  taintToleration: `${ECC.mesh}=true:NoSchedule; ${ECC.gpu}=true:NoSchedule`,
                              }
                            : {}),
                    },
                    // Don't let the chart create its default class named "longhorn";
                    // we create an explicit `longhorn-cloud` default class below
                    // (cloud disk/node selectors) plus per-scope `longhorn-<scope>`.
                    persistence: {
                        defaultClass: false,
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

        // Default StorageClass `longhorn-cloud` (replaces the chart's "longhorn").
        // Replicas pinned to cloud-tagged disks/nodes when mesh nodes exist, so
        // cloud-app replicas never land on a mesh node across the WAN. On cloud-only
        // clusters the selector is omitted (every disk is a cloud disk).
        new k8s.storage.v1.StorageClass(
            "longhorn-cloud",
            {
                metadata: {
                    name: "longhorn-cloud",
                    annotations: { "storageclass.kubernetes.io/is-default-class": "true" },
                },
                provisioner: "driver.longhorn.io",
                allowVolumeExpansion: true,
                reclaimPolicy: "Retain",
                volumeBindingMode: "Immediate",
                parameters: {
                    numberOfReplicas: String(longhornReplicaCount),
                    staleReplicaTimeout: "30",
                    dataLocality: "best-effort",
                    fsType: "ext4",
                    // diskSelector only (NOT nodeSelector): Longhorn nodeSelector matches
                    // NODE tags, which we don't set — we tag DISKS (see nodes-k3s). A disk
                    // tag is sufficient to keep cloud replicas off mesh-node disks.
                    ...(hasMeshNodes ? { diskSelector: "cloud" } : {}),
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.longhornChart] },
        );

        // `longhorn-cloud-db`: cloud disks, but opted OUT of the `default` RecurringJob
        // group and into `cnpg` (backup-daily only, NO hourly snapshot — see
        // deployment/argocd-infra/longhorn-system/recurring-jobs.yaml).
        //
        // Rationale: CNPG volumes carry their own continuous WAL archiving + scheduled base
        // backups to S3, giving PITR — strictly better recovery than a crash-consistent
        // block snapshot. Both the cadence (ScheduledBackup spec.schedule) and the window
        // (barmanObjectStore retentionPolicy) are set per cluster in each app's
        // postgres.yaml.
        //
        // Meanwhile they are the WORST case for hourly block snapshots: Postgres recycles
        // WAL segments by rewriting the same 16MB files in place, so even an idle cluster
        // dirties ~0.3Gi of blocks per hour. Left in the hourly group, 10 CNPG volumes
        // reach ~90% of all disk usage (253Gi of snapshots) and starve the cloud disk.
        //
        // NB: Longhorn applies the `default` group only to volumes with NO
        // recurringJobSelector, so setting a selector here is what removes these volumes
        // from `default` — the daily Longhorn S3 backup is deliberately retained as a
        // volume-level net beneath the barman archive.
        new k8s.storage.v1.StorageClass(
            "longhorn-cloud-db",
            {
                metadata: { name: "longhorn-cloud-db" },
                provisioner: "driver.longhorn.io",
                allowVolumeExpansion: true,
                reclaimPolicy: "Retain",
                volumeBindingMode: "Immediate",
                parameters: {
                    numberOfReplicas: String(longhornReplicaCount),
                    staleReplicaTimeout: "30",
                    dataLocality: "best-effort",
                    fsType: "ext4",
                    ...(hasMeshNodes ? { diskSelector: "cloud" } : {}),
                    recurringJobSelector: `[{"name":"cnpg","isGroup":true}]`,
                },
            },
            { provider: k8sProvider, parent: this, dependsOn: [this.longhornChart] },
        );

        // Per-scope mesh StorageClasses: one `longhorn-<scope>` per distinct storageScope
        // tag across all mesh nodes. Replicas pin to that scope's disks (diskSelector:
        // "<scope>") so reads+writes stay within the scope. A scope unique to one LAN is
        // strict-local; a scope shared across LANs (e.g. "unibi") spans them (cross-LAN
        // redundant, replicating over WireGuard — enable only when the interconnect is fast).
        // Replica count = min(3, #mesh nodes carrying that scope); a single-node scope is
        // replica 1 (S3 backup is the net). Each class joins its own per-scope RecurringJob
        // backup group (see deployment/argocd-infra/longhorn-system/recurring-jobs.yaml).
        for (const scope of storageScopes) {
            const scopeReplicaCount = Math.max(1, Math.min(3, nodesCarryingScope(scope)));
            new k8s.storage.v1.StorageClass(
                `longhorn-${scope}`,
                {
                    metadata: { name: `longhorn-${scope}` },
                    provisioner: "driver.longhorn.io",
                    allowVolumeExpansion: true,
                    reclaimPolicy: "Retain",
                    volumeBindingMode: "Immediate",
                    parameters: {
                        numberOfReplicas: String(scopeReplicaCount),
                        staleReplicaTimeout: "30",
                        dataLocality: "best-effort",
                        diskSelector: scope,
                        recurringJobSelector: `[{"name":"${scope}","isGroup":true}]`,
                    },
                },
                { provider: k8sProvider, parent: this, dependsOn: [this.longhornChart] },
            );
        }

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

        // Reconcile replica count on EXISTING volumes to match the topology-derived
        // default. The Helm `defaultReplicaCount` only applies to newly-created
        // volumes, so without this a scale-out (1→2→3 nodes) would never add
        // replicas to volumes that already exist. Re-runs whenever the desired
        // count changes (triggers); `replicaAutoBalance` then places the extra
        // replica on the new node. Patching down (e.g. 2→1) frees space immediately.
        new command.local.Command(
            "longhorn-reconcile-replica-count",
            {
                create: `TMPKC=$(mktemp)
cleanup() { rm -f "$TMPKC"; }
trap cleanup EXIT
printf '%s\\n' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"

TARGET=${longhornReplicaCount}
echo "Reconciling Longhorn volumes to numberOfReplicas=$TARGET"
for v in $(kubectl get volumes.longhorn.io -n longhorn-system -o name 2>/dev/null); do
  kubectl -n longhorn-system patch "$v" --type=merge \\
    -p "{\\"spec\\":{\\"numberOfReplicas\\":$TARGET}}" >/dev/null 2>&1 \\
    && echo "  patched $v -> $TARGET" || echo "  WARN: failed to patch $v"
done
kubectl get replicas.longhorn.io -n longhorn-system -o json 2>/dev/null | python3 -c "
import json,sys
from collections import defaultdict
data=json.load(sys.stdin)
by_vol=defaultdict(list)
for r in data['items']:
    by_vol[r['spec']['volumeName']].append(r['metadata']['name'])
for vol,replicas in by_vol.items():
    for extra in replicas[$TARGET:]:
        print(extra)
" | xargs -r kubectl delete replica.longhorn.io -n longhorn-system
echo "  Extra replicas removed"`,
                delete: "true",
                environment: { KUBECONFIG_CONTENT: kubeconfigRaw },
                triggers: [longhornReplicaCount],
            },
            { parent: this, dependsOn: [longhornReady] },
        );

        // Pulumi-owned S3 buckets. This list is CLOSED at two entries (etcd,
        // longhornBackup) — both are consumed BEFORE ArgoCD exists, which is the only
        // reason they live here:
        //   etcd           — written into cp0's k3s config.yaml in cloud-init
        //                    (nodes-k3s-common.ts), i.e. before any Kubernetes at all.
        //   longhornBackup — gated by the pre-ArgoCD restore step (longhorn-restore.ts),
        //                    and it is a CLUSTER-WIDE target (every PVC, incl. the `cnpg`
        //                    RecurringJob group) so no single app could own it.
        // A NEW bucket almost certainly belongs to one app instead: give it a Sync-hook
        // Job in that app's own manifests and keep it out of Pulumi. Pattern to copy:
        // deployment/argocd-infra/loki/s3-buckets-job.yaml. See doc/backup-restore.md.
        const bucketCommands: Record<string, command.local.Command> = {};
        for (const bucket of project_settings.storage.objectStorage.buckets) {
            const endpoint = `https://${bucket.location}.your-objectstorage.com`;
            bucketCommands[bucket.key] = new command.local.Command(
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
                    // ⚠ RETRY, AND TREAT AN ABSENT BUCKET AS SUCCESS. Both failure modes were
                    // hit destroying ecc212 (2026-09-16) and each aborts the whole teardown
                    // with 89 resources still in the stack:
                    //   - `BucketNotEmpty` on a bucket that IS empty. Hetzner object storage is
                    //     eventually consistent, so `rb --force` deletes every object and then
                    //     races its own DeleteBucket. The identical command succeeded on a
                    //     manual retry a minute later.
                    //   - `NoSuchBucket` once the bucket is actually gone — which is the state
                    //     a retry of a half-finished destroy starts from, so failing here makes
                    //     the teardown unresumable.
                    // Idempotent either way: the post-condition is "bucket does not exist".
                    delete:
                        project_settings.general.targetState === "destroy"
                            ? [
                                  `for i in 1 2 3 4 5; do`,
                                  `  aws s3api head-bucket --bucket "${bucket.name}"`,
                                  `    --endpoint-url "${endpoint}" --region "${bucket.location}" 2>/dev/null || exit 0;`,
                                  `  aws s3 rb s3://${bucket.name} --force`,
                                  `    --endpoint-url "${endpoint}" --region "${bucket.location}" && exit 0;`,
                                  `  echo "bucket ${bucket.name}: delete attempt $i failed, retrying in 15s" >&2;`,
                                  `  sleep 15;`,
                                  `done;`,
                                  `aws s3api head-bucket --bucket "${bucket.name}"`,
                                  `  --endpoint-url "${endpoint}" --region "${bucket.location}" 2>/dev/null || exit 0;`,
                                  `echo "ERROR: bucket ${bucket.name} still exists after 5 attempts" >&2; exit 1`,
                              ].join(" ")
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

        // Configure the S3 backup target before the restore step runs.
        // Longhorn Helm chart already creates BackupTarget "default" with an empty spec,
        // so we patch it via SSA (--server-side --force-conflicts) instead of creating.
        //
        // DELIBERATE DUPLICATE of deployment/argocd-infra/longhorn-system/backup-target.yaml —
        // do not "clean up" either copy. Pulumi seeds the target here because the restore
        // step (longhorn-restore.ts) hard-fails if it is not `available` and runs BEFORE
        // ArgoCD is installed; ArgoCD's longhorn-config app (sync-wave 2) then owns it in
        // steady state and self-heals it. Keep the two specs identical.
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
            // dependsOn the bucket: without it Pulumi may patch the target before the
            // bucket exists, leaving it unavailable until Longhorn's next 5m poll — which
            // races the restore step's own 5-minute availability budget.
            {
                parent: this,
                dependsOn: [longhornReady, bucketCommands["longhornBackup"]],
            },
        );

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
                    "timeout 30 kubectl delete application longhorn -n argocd-infra --ignore-not-found 2>/dev/null || true",
                    // Remove admission webhooks that block CR deletion once their pods are gone.
                    "timeout 30 kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true",
                    "timeout 30 kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true",
                    // Scale down all workloads so pods terminate gracefully.
                    "timeout 30 kubectl scale deployment --all -n longhorn-system --replicas=0 2>/dev/null || true",
                    "timeout 30 kubectl scale daemonset --all -n longhorn-system --replicas=0 2>/dev/null || true",
                    // Strip finalizers from ALL Longhorn CRs (dynamic discovery avoids stale hardcoded lists).
                    // We do NOT `kubectl delete` the CRs: once their finalizers are gone, namespace
                    // termination garbage-collects them. Deleting each CR instead would walk hundreds
                    // of snapshots one process at a time (~4min on a busy cluster) for no benefit — the
                    // data lives on the replica disks / control-plane etcd and is freed when Pulumi
                    // deletes the servers + volumes regardless. Patches run in parallel (xargs -P) so
                    // even thousands of CRs clear in seconds. Each kind's strip is bounded by
                    // `timeout 120`.
                    "for crd in $(timeout 30 kubectl get crd -o name 2>/dev/null | grep '\\.longhorn\\.io'); do",
                    "  kind=$(timeout 15 kubectl get \"$crd\" -o jsonpath='{.spec.names.plural}' 2>/dev/null || true)",
                    '  [ -z "$kind" ] && continue',
                    '  timeout 120 kubectl get "${kind}" -n longhorn-system -o name 2>/dev/null \\',
                    '    | xargs -r -P 16 -I{} timeout 15 kubectl patch {} -n longhorn-system --type=merge -p \'{"metadata":{"finalizers":[]}}\' 2>/dev/null || true',
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
            ...(this.csiDriver ? { csiDriver: this.csiDriver } : {}),
        });
    }
}
