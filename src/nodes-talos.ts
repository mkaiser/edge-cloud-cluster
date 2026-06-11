import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as command from "@pulumi/command";
import * as talos from "@pulumiverse/talos";
import { project_settings } from "../project_settings";
import type { NetworkComponent } from "./network";

export class TalosNodesComponent extends pulumi.ComponentResource {
    public readonly controlPlane: hcloud.Server;
    public readonly controlPlanePrivateIp: pulumi.Output<string>;
    public readonly k8sProvider: k8s.Provider;
    public readonly additionalCpNodes: hcloud.Server[];
    public readonly cloudWorkers: hcloud.Server[];
    public readonly kubeconfigRaw: pulumi.Output<string>;
    public readonly machineSecrets: talos.machine.Secrets;

    constructor(
        name: string,
        networkComponent: NetworkComponent,
        hProvider: hcloud.Provider,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:nodes:TalosNodes", name, {}, opts);
        const { network, firewall } = networkComponent;

        /////////////////////
        // Talos Image Upload
        // https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/cloud-platforms/hetzner
        /////////////////////

        const talosSchematic = new talos.imagefactory.Schematic(
            "talos-hcloud-schematic",
            {
                schematic: `customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
`,
            },
            { parent: this },
        );

        const talosImageUrls = talos.imagefactory.getUrlsOutput({
            talosVersion: project_settings.server.talosVersion,
            schematicId: talosSchematic.id,
            platform: "hcloud",
            architecture: "amd64",
        });

        const talosImageUpload = new command.local.Command(
            "upload-talos-image",
            {
                create: pulumi.interpolate`
        set -uo pipefail
        export HCLOUD_TOKEN="${project_settings.general.hcloudToken}"
        EXISTING=$(hcloud image list -t snapshot -o noheader -o columns=id,description | grep "talos-${project_settings.server.talosVersion}" | head -1 | awk '{print $1}' || true)
        if [ -n "$EXISTING" ]; then
            echo "$EXISTING"
            exit 0
        fi
        echo "Uploading Talos ${project_settings.server.talosVersion} image to Hetzner..." >&2
        hcloud-upload-image upload \
            --image-url "${talosImageUrls.urls.diskImage}" \
            --architecture x86 \
            --compression xz \
            --description "talos-${project_settings.server.talosVersion}" \
            --labels talos-version=${project_settings.server.talosVersion} >&2 || { echo "hcloud-upload-image failed" >&2; exit 1; }
        SNAPSHOT_ID=$(hcloud image list -t snapshot -o noheader -o columns=id,description | grep "talos-${project_settings.server.talosVersion}" | head -1 | awk '{print $1}' || true)
        if [ -z "$SNAPSHOT_ID" ]; then
            echo "ERROR: Talos image upload succeeded but snapshot not found" >&2
            exit 1
        fi
        echo "$SNAPSHOT_ID"
    `,
                triggers: [project_settings.server.talosVersion],
            },
            { parent: this },
        );

        const talosImageId = talosImageUpload.stdout.apply((id) => id.trim());

        /////////////////////
        // Machine Secrets & Configuration
        /////////////////////

        this.machineSecrets = new talos.machine.Secrets(
            "talos-machine-secrets",
            {
                talosVersion: project_settings.server.talosVersion,
            },
            { parent: this },
        );

        const cpConfigPatches = [
            ...(project_settings.server.loadBalancerProvider === "hetzner-ccm"
                ? [
                      JSON.stringify({
                          cluster: {
                              externalCloudProvider: {
                                  enabled: true,
                                  manifests: [
                                      "https://raw.githubusercontent.com/hetznercloud/hcloud-cloud-controller-manager/main/deploy/ccm-networks.yaml",
                                  ],
                              },
                          },
                      }),
                  ]
                : []),
            JSON.stringify({
                machine: {
                    features: {
                        kubernetesTalosAPIAccess: {
                            enabled: true,
                            allowedRoles: ["os:etcd:backup"],
                            allowedKubernetesNamespaces: ["talos-backup"],
                        },
                    },
                },
            }),
            JSON.stringify({
                machine: {
                    network: { interfaces: [{ interface: "eth1", dhcp: true }] },
                    ...(project_settings.server.loadBalancerProvider === "hetzner-ccm"
                        ? { kubelet: { extraArgs: { "cloud-provider": "external" } } }
                        : {}),
                    kernel: { modules: [{ name: "wireguard" }] },
                },
            }),
        ];

        const cpConfig = talos.machine.getConfigurationOutput({
            clusterName: project_settings.general.name,
            machineType: "controlplane",
            clusterEndpoint: pulumi.interpolate`https://${project_settings.general.name.toLowerCase()}-cp0:6443`,
            machineSecrets: this.machineSecrets.machineSecrets,
            talosVersion: project_settings.server.talosVersion,
            kubernetesVersion: project_settings.server.talosKubernetesVersion,
            docs: false,
            examples: false,
            configPatches: cpConfigPatches,
        });

        const workerConfigPatches = [
            JSON.stringify({
                machine: {
                    network: { interfaces: [{ interface: "eth1", dhcp: true }] },
                    ...(project_settings.server.loadBalancerProvider === "hetzner-ccm"
                        ? { kubelet: { extraArgs: { "cloud-provider": "external" } } }
                        : {}),
                    kernel: { modules: [{ name: "wireguard" }] },
                },
            }),
        ];

        const workerConfig = talos.machine.getConfigurationOutput({
            clusterName: project_settings.general.name,
            machineType: "worker",
            clusterEndpoint: pulumi.interpolate`https://${project_settings.general.name.toLowerCase()}-cp0:6443`,
            machineSecrets: this.machineSecrets.machineSecrets,
            talosVersion: project_settings.server.talosVersion,
            kubernetesVersion: project_settings.server.talosKubernetesVersion,
            docs: false,
            examples: false,
            configPatches: workerConfigPatches,
        });

        /////////////////////
        // Control Plane 0
        /////////////////////

        this.controlPlane = new hcloud.Server(
            `${project_settings.general.name}-server-talos-cp0`,
            {
                name: `${project_settings.general.name.toLowerCase()}-cp0`,
                serverType: project_settings.nodes.controlPlane[0].serverType.toLowerCase(),
                image: talosImageId,
                location: project_settings.nodes.controlPlane[0].location,
                sshKeys: [project_settings.server.serverSshKey],
                networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                firewallIds: [firewall.id.apply((id) => Number(id))],
            },
            { provider: hProvider, parent: this, dependsOn: [talosImageUpload] },
        );

        this.controlPlanePrivateIp = this.controlPlane.networks.apply(
            (networks) => networks![0].ip,
        );

        const cp0ConfigApply = new talos.machine.ConfigurationApply(
            "talos-cp0-config",
            {
                clientConfiguration: this.machineSecrets.clientConfiguration,
                machineConfigurationInput: cpConfig.machineConfiguration,
                node: this.controlPlane.ipv4Address,
                endpoint: this.controlPlane.ipv4Address,
                configPatches: [
                    pulumi
                        .all([this.controlPlane.ipv4Address, this.controlPlanePrivateIp])
                        .apply(([publicIp, privateIp]) =>
                            JSON.stringify({
                                machine: {
                                    certSANs: [publicIp, privateIp],
                                    nodeLabels: {
                                        "node-role.kubernetes.io/control-plane": "control-plane",
                                    },
                                },
                                cluster: {
                                    controlPlane: { endpoint: `https://${privateIp}:6443` },
                                },
                            }),
                        ),
                ],
            },
            { parent: this, dependsOn: [this.controlPlane] },
        );

        /////////////////////
        // Bootstrap & Kubeconfig
        /////////////////////

        const talosBootstrap = project_settings.general.restoreClusterFromS3Backup
            ? new command.local.Command(
                  "talos-bootstrap-restore",
                  {
                      create: pulumi
                          .all([
                              this.machineSecrets.clientConfiguration,
                              this.controlPlane.ipv4Address,
                              project_settings.storage.objectStorage.accessKey,
                              project_settings.storage.objectStorage.secretKey,
                          ])
                          .apply(([clientConfig, nodeIp, s3Key, s3Secret]) => {
                              const talosconfig = JSON.stringify({
                                  context: "default",
                                  contexts: {
                                      default: {
                                          endpoints: [nodeIp],
                                          nodes: [nodeIp],
                                          ca: clientConfig.caCertificate,
                                          crt: clientConfig.clientCertificate,
                                          key: clientConfig.clientKey,
                                      },
                                  },
                              });
                              return `
                set -euo pipefail
                TALOSCONFIG=$(mktemp)
                echo '${talosconfig}' > "$TALOSCONFIG"
                trap "rm -f $TALOSCONFIG" EXIT
                export AWS_ACCESS_KEY_ID="${s3Key}"
                export AWS_SECRET_ACCESS_KEY="${s3Secret}"
                LATEST=$(aws s3 ls s3://${project_settings.storage.objectStorage.buckets.find((b) => b.key === "etcd")!.name}/talos-etcd/ \
                    --endpoint-url https://${project_settings.storage.objectStorage.baseEndpoint} \
                    2>/dev/null | sort | tail -1 | awk '{print $4}' || echo "")
                if [ -n "$LATEST" ]; then
                    aws s3 cp "s3://${project_settings.storage.objectStorage.buckets.find((b) => b.key === "etcd")!.name}/talos-etcd/$LATEST" /tmp/etcd-snapshot.db \
                        --endpoint-url https://${project_settings.storage.objectStorage.baseEndpoint}
                    echo "Restoring etcd from: $LATEST" >&2
                    talosctl --talosconfig "$TALOSCONFIG" --nodes ${nodeIp} --endpoints ${nodeIp} \
                        bootstrap --recover-from=/tmp/etcd-snapshot.db
                    rm -f /tmp/etcd-snapshot.db
                else
                    echo "No S3 snapshot found — fresh bootstrap" >&2
                    talosctl --talosconfig "$TALOSCONFIG" --nodes ${nodeIp} --endpoints ${nodeIp} bootstrap
                fi
            `;
                          }),
                      triggers: [this.controlPlane.ipv4Address],
                  },
                  { parent: this, dependsOn: [cp0ConfigApply] },
              )
            : new command.local.Command(
                  "talos-bootstrap",
                  {
                      create: pulumi
                          .all([
                              this.machineSecrets.clientConfiguration,
                              this.controlPlane.ipv4Address,
                          ])
                          .apply(([clientConfig, nodeIp]) => {
                              const talosconfig = JSON.stringify({
                                  context: "default",
                                  contexts: {
                                      default: {
                                          endpoints: [nodeIp],
                                          nodes: [nodeIp],
                                          ca: clientConfig.caCertificate,
                                          crt: clientConfig.clientCertificate,
                                          key: clientConfig.clientKey,
                                      },
                                  },
                              });
                              return `
                set -euo pipefail
                TALOSCONFIG=$(mktemp)
                echo '${talosconfig}' > "$TALOSCONFIG"
                trap "rm -f $TALOSCONFIG" EXIT
                echo "Waiting to see if cp0 auto-joins an existing etcd cluster..." >&2
                for i in $(seq 1 18); do
                    STATUS=$(talosctl --talosconfig "$TALOSCONFIG" --nodes ${nodeIp} --endpoints ${nodeIp} service etcd 2>/dev/null || true)
                    if echo "$STATUS" | grep -q "Running"; then
                        echo "etcd is Running — cp0 joined an existing cluster, skipping bootstrap." >&2
                        exit 0
                    fi
                    echo "Attempt $i/18: etcd not yet running, waiting 5s..." >&2
                    sleep 5
                done
                echo "etcd did not auto-start — bootstrapping a fresh cluster." >&2
                talosctl --talosconfig "$TALOSCONFIG" --nodes ${nodeIp} --endpoints ${nodeIp} bootstrap
            `;
                          }),
                      triggers: [this.controlPlane.ipv4Address],
                  },
                  { parent: this, dependsOn: [cp0ConfigApply] },
              );

        const talosKubeconfig = new talos.cluster.Kubeconfig(
            "talos-kubeconfig",
            {
                clientConfiguration: this.machineSecrets.clientConfiguration,
                node: this.controlPlane.ipv4Address,
                endpoint: this.controlPlane.ipv4Address,
                timeouts: { create: "10m" },
            },
            { parent: this, dependsOn: [talosBootstrap] },
        );

        this.kubeconfigRaw = talosKubeconfig.kubeconfigRaw;

        this.k8sProvider = new k8s.Provider(
            "k8s",
            {
                kubeconfig: this.kubeconfigRaw,
                suppressDeprecationWarnings: true,
                enableServerSideApply: true,
                // If the cluster becomes unreachable mid-destroy (VMs already gone),
                // treat K8s resource deletions as successful instead of erroring.
                deleteUnreachable: true,
            },
            { parent: this, dependsOn: [talosKubeconfig] },
        );

        /////////////////////
        // Additional Control Planes
        /////////////////////

        this.additionalCpNodes = project_settings.nodes.controlPlane.slice(1).map((node) => {
            const server = new hcloud.Server(
                `${project_settings.general.name}-server-talos-${node.id}`,
                {
                    name: `${project_settings.general.name.toLowerCase()}-${node.id}`,
                    serverType: node.serverType.toLowerCase(),
                    image: talosImageId,
                    location: node.location,
                    sshKeys: [project_settings.server.serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                },
                { provider: hProvider, parent: this, dependsOn: [talosBootstrap] },
            );

            new talos.machine.ConfigurationApply(
                `talos-${node.id}-config`,
                {
                    clientConfiguration: this.machineSecrets.clientConfiguration,
                    machineConfigurationInput: cpConfig.machineConfiguration,
                    node: server.ipv4Address,
                    endpoint: server.ipv4Address,
                    configPatches: [
                        pulumi
                            .all([server.ipv4Address, server.networks])
                            .apply(([publicIp, networks]) => {
                                const privateIp = networks![0].ip;
                                return JSON.stringify({
                                    machine: {
                                        certSANs: [publicIp, privateIp],
                                        nodeLabels: {
                                            "node-role.kubernetes.io/control-plane":
                                                "control-plane",
                                        },
                                    },
                                    cluster: {
                                        controlPlane: { endpoint: `https://${privateIp}:6443` },
                                    },
                                });
                            }),
                    ],
                },
                { parent: this, dependsOn: [server] },
            );

            return server;
        });

        /////////////////////
        // Workers
        /////////////////////

        this.cloudWorkers = project_settings.nodes.workers.map((node) => {
            const worker = new hcloud.Server(
                `${project_settings.general.name}-server-talos-${node.id}`,
                {
                    name: `${project_settings.general.name.toLowerCase()}-${node.id}`,
                    serverType: node.serverType.toLowerCase(),
                    image: talosImageId,
                    location: node.location,
                    sshKeys: [project_settings.server.serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                },
                { provider: hProvider, parent: this, dependsOn: [talosBootstrap] },
            );

            new talos.machine.ConfigurationApply(
                `talos-${node.id}-config`,
                {
                    clientConfiguration: this.machineSecrets.clientConfiguration,
                    machineConfigurationInput: workerConfig.machineConfiguration,
                    node: worker.ipv4Address,
                    endpoint: worker.ipv4Address,
                    configPatches: [
                        worker.ipv4Address.apply((publicIp) =>
                            JSON.stringify({
                                machine: {
                                    certSANs: [publicIp],
                                    nodeLabels: { "node-role.kubernetes.io/worker": "worker" },
                                },
                            }),
                        ),
                    ],
                },
                { parent: this, dependsOn: [worker] },
            );

            return worker;
        });

        this.registerOutputs({
            controlPlane: this.controlPlane,
            controlPlanePrivateIp: this.controlPlanePrivateIp,
            k8sProvider: this.k8sProvider,
            additionalCpNodes: this.additionalCpNodes,
            cloudWorkers: this.cloudWorkers,
            kubeconfigRaw: this.kubeconfigRaw,
            machineSecrets: this.machineSecrets,
        });
    }
}
