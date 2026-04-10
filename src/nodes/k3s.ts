import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as command from "@pulumi/command";
import type { ClusterOS, LoadBalancerProvider, ControlPlaneNode, WorkerNode } from "../types";
import type { PulumiSecrets } from "../pulumi_secrets";

export interface K3sArgs {
    cluster: {
        name: string;
        nameLower: string;
        os: ClusterOS;
        serverSshKey: string;
        loadBalancerProvider: LoadBalancerProvider;
        restoreClusterFromS3Backup: boolean;
        timezone: string;
    };
    controlPlaneNodes: ControlPlaneNode[];
    workerNodes: WorkerNode[];
    network: hcloud.Network;
    firewall: hcloud.Firewall;
    hProvider: hcloud.Provider;
    pulumiSecrets: PulumiSecrets;
    networkSettings: {
        privateRange: string;
        gateway: string;
    };
    objectStorageSettings: {
        baseEndpoint: string;
        bucketName: string;
        bucketFolderEtcd: string;
    };
    backupClusterToS3: boolean;
    etcdBucketName: string;
    backupClusterToS3Interval: number;
}

export class K3sNodesComponent extends pulumi.ComponentResource {
    public readonly controlPlane: hcloud.Server;
    public readonly controlPlanePrivateIp: pulumi.Output<string>;
    public readonly k8sProvider: k8s.Provider;
    public readonly additionalCpNodes: hcloud.Server[];
    public readonly cloudWorkers: hcloud.Server[];
    public readonly kubeconfigRaw: pulumi.Output<string>;

    constructor(name: string, args: K3sArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:nodes:K3sNodes", name, {}, opts);

        const {
            cluster,
            controlPlaneNodes,
            workerNodes,
            network,
            firewall,
            hProvider,
            pulumiSecrets,
            networkSettings,
            objectStorageSettings,
            backupClusterToS3,
            etcdBucketName,
            backupClusterToS3Interval,
        } = args;
        const clusterName = cluster.name;
        const clusterNameLower = cluster.nameLower;
        const clusterOS = cluster.os;
        const serverSshKey = cluster.serverSshKey;
        const loadBalancerProvider = cluster.loadBalancerProvider;
        const restoreClusterFromS3Backup = cluster.restoreClusterFromS3Backup;
        const timezone = cluster.timezone;
        const hcloudToken = pulumiSecrets.hcloudToken;
        const { privateRange: privateNetworkRange, gateway: privateNetworkGateway } =
            networkSettings;
        const {
            baseEndpoint: hetznerS3BaseEndpoint,
            bucketName: hetznerS3BucketName,
            bucketFolderEtcd: hetznerS3BucketFolderEtcd,
        } = objectStorageSettings;

        const useHetznerCcm = loadBalancerProvider === "hetzner-ccm";
        const k3sDisableFlags = useHetznerCcm
            ? "disable:\n  - servicelb\n  - traefik"
            : "disable:\n  - traefik";
        const k3sServerCloudProviderConfig = useHetznerCcm
            ? "disable-cloud-controller: true\nkubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
            : "kubelet-arg:\n  - max-pods=200";
        // max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping opendesk
        const k3sWorkerCloudProviderConfig = useHetznerCcm
            ? "kubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
            : "kubelet-arg:\n  - max-pods=200";
        // max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping opendesk

        // Shared bash snippet: set timezone for Debian/Ubuntu nodes.
        const timezoneSetupScript = `
    timedatectl set-timezone ${timezone} || {
        ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime
        echo ${timezone} > /etc/timezone
    }
`;

        // Shared bash snippet: private network route setup + exports PRIVATE_IP.
        const privateNetworkSetupScript = `
    ufw disable || true
    PRIVATE_IFACE=""
    for i in $(seq 1 30); do
        PRIVATE_IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\\.0\\./ {print $2; exit}')
        [ -n "$PRIVATE_IFACE" ] && break
        sleep 1
    done
    if [ -n "$PRIVATE_IFACE" ]; then
        PRIVATE_IP=$(ip -o -4 addr show dev "$PRIVATE_IFACE" | awk '{split($4,a,"/"); print a[1]}')
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-hcloud-private-route.network << ROUTECONF
[Match]
Name=\${PRIVATE_IFACE}

[Network]
DHCP=yes

[Route]
Destination=${privateNetworkRange}
Gateway=${privateNetworkGateway}
ROUTECONF
        ip route add ${privateNetworkRange} via ${privateNetworkGateway} dev "\${PRIVATE_IFACE}" onlink || true
    else
        echo "WARNING: private network interface not found" >&2
        PRIVATE_IP=""
    fi
`;

        const etcdS3BucketName = etcdBucketName;

        const etcdS3ConfigBlock = backupClusterToS3
            ? pulumi.interpolate`etcd-s3: true
etcd-s3-folder: ${hetznerS3BucketFolderEtcd}
# Take etcd snapshots every N hours (config: backupClusterToS3Interval).
etcd-snapshot-schedule-cron: "0 */${backupClusterToS3Interval} * * *"
etcd-snapshot-retention: 144`
            : pulumi.output("# etcd-s3 backup disabled (backupClusterToS3=false)");

        const etcdS3SecretsBlock = backupClusterToS3
            ? pulumi.interpolate`etcd-s3-endpoint: ${hetznerS3BaseEndpoint}
etcd-s3-bucket: ${etcdS3BucketName}
etcd-s3-access-key: ${pulumiSecrets.hetznerS3AccessKey}
etcd-s3-secret-key: ${pulumiSecrets.hetznerS3SecretKey}`
            : pulumi.output("");

        const s3ConnectivityCheck = backupClusterToS3
            ? pulumi.interpolate`S3_HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${etcdS3BucketName}.${hetznerS3BaseEndpoint}/")
if [ "$S3_HTTP" = "000" ]; then
    echo "ERROR: S3 bucket unreachable (HTTP $S3_HTTP)" >&2; exit 1
fi`
            : pulumi.output("# S3 connectivity check skipped (backup disabled)");

        /////////////////////
        // Control Plane 0
        /////////////////////

        const primaryCpUserData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${privateNetworkSetupScript}
    ${timezoneSetupScript}
apt-get update -qq && apt-get install -y nfs-common

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << 'KCONFIG'
cluster-init: true
${k3sDisableFlags}
${k3sServerCloudProviderConfig}
${etcdS3ConfigBlock}
KCONFIG
PUBLIC_IP=$(ip -o -4 addr show | awk '$4 !~ /^10\\./ && $4 !~ /^127\\./ {split($4,a,"/"); print a[1]; exit}')
cat >> /etc/rancher/k3s/config.yaml << KCONFIG_SECRETS
node-name: ${clusterNameLower}-cp0
advertise-address: \$PRIVATE_IP
node-ip: \$PRIVATE_IP
tls-san:
  - \$PUBLIC_IP
  - \$PRIVATE_IP
${etcdS3SecretsBlock}
KCONFIG_SECRETS
chmod 600 /etc/rancher/k3s/config.yaml

${s3ConnectivityCheck}

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -

if [ "${restoreClusterFromS3Backup}" = "true" ]; then
    SNAPSHOT=$(k3s etcd-snapshot ls \
        --etcd-s3-endpoint=${hetznerS3BaseEndpoint} \
        --etcd-s3-access-key=${pulumiSecrets.hetznerS3AccessKey} \
        --etcd-s3-secret-key=${pulumiSecrets.hetznerS3SecretKey} \
        --etcd-s3-bucket=${etcdS3BucketName} \
        --etcd-s3-folder=${hetznerS3BucketFolderEtcd} \
        2>/dev/null | awk 'NR>1{print $1}' | sort | tail -1 || echo "")
    if [ -n "$SNAPSHOT" ]; then
        echo "Restoring etcd from: $SNAPSHOT" >&2
        k3s server --cluster-reset --cluster-reset-restore-path="$SNAPSHOT" \
            --etcd-s3 \
            --etcd-s3-endpoint=${hetznerS3BaseEndpoint} \
            --etcd-s3-access-key=${pulumiSecrets.hetznerS3AccessKey} \
            --etcd-s3-secret-key=${pulumiSecrets.hetznerS3SecretKey} \
            --etcd-s3-bucket=${etcdS3BucketName} \
            --etcd-s3-folder=${hetznerS3BucketFolderEtcd} 2>&1 | tail -10 || true
    else
        echo "No S3 snapshot found — fresh start" >&2
    fi
fi

touch /var/lib/k3s-install-complete
echo "K3s install complete — waiting for Pulumi to start K3s" >&2
`;

        const cp0Type = controlPlaneNodes[0].serverType;
        const cp0Location = controlPlaneNodes[0].location;
        this.controlPlane = new hcloud.Server(
            `${clusterName}-server-k3s-cp0`,
            {
                name: `${clusterNameLower}-cp0`,
                serverType: cp0Type.toLowerCase(),
                image: clusterOS,
                location: cp0Location,
                sshKeys: [serverSshKey],
                networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                firewallIds: [firewall.id.apply((id) => Number(id))],
                userData: primaryCpUserData,
            },
            { provider: hProvider, parent: this },
        );

        this.controlPlanePrivateIp = this.controlPlane.networks.apply(
            (networks) => networks![0].ip,
        );

        /////////////////////
        // K3s cp0 start: join existing cluster or cluster-init
        /////////////////////

        const k3sCp0JoinOrInit = new command.local.Command(
            "k3s-cp0-join-or-init",
            {
                create: pulumi.all([this.controlPlane.ipv4Address, hcloudToken]).apply(
                    ([cp0Ip, token]) => `
            set -euo pipefail

            echo "Waiting for K3s install to complete on cp0 (${cp0Ip})..." >&2
            for i in $(seq 1 180); do
                if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    root@${cp0Ip} 'test -f /var/lib/k3s-install-complete' 2>/dev/null; then
                    break
                fi
                sleep 5
            done

            CP1_IP=$(curl -sf -H "Authorization: Bearer ${token}" \
                "https://api.hetzner.cloud/v1/servers?name=${clusterNameLower}-cp1" | \
                jq -r '.servers[0].public_net.ipv4.ip // ""' 2>/dev/null || echo "")

            JOIN_MODE=false
            if [ -n "$CP1_IP" ] && [ "${restoreClusterFromS3Backup}" != "true" ]; then
                if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$CP1_IP" \
                    'k3s kubectl get --raw="/readyz" 2>/dev/null | grep -q "^ok$"' 2>/dev/null; then
                    JOIN_MODE=true
                fi
            fi

            if $JOIN_MODE; then
                echo "Existing cluster found on cp1 ($CP1_IP) — reconfiguring cp0 to join" >&2
                PEER_TOKEN=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$CP1_IP" \
                    'cat /var/lib/rancher/k3s/server/node-token')
                PEER_PRIVATE_IP=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$CP1_IP" \
                    "ip -4 addr show | awk '/inet.*10\\./{split(\$2,a,\"/\");print a[1];exit}'")
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${cp0Ip} \
                    "sed -i '/^cluster-init:/d' /etc/rancher/k3s/config.yaml && \
                     printf 'server: https://%s:6443\\ntoken: %s\\n' '$PEER_PRIVATE_IP' '$PEER_TOKEN' \
                         >> /etc/rancher/k3s/config.yaml && \
                     systemctl enable --now k3s"
                echo "cp0 started in join mode" >&2
            else
                echo "No existing cluster (or restore mode) — starting cp0 with cluster-init" >&2
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${cp0Ip} \
                    'systemctl enable --now k3s'
            fi
        `,
                ),
                triggers: [this.controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [this.controlPlane] },
        );

        const waitForK3sCp0SetupReady = new command.local.Command(
            "wait-for-k3s-setup-cp0-ready",
            {
                create: pulumi.interpolate`for i in $(seq 1 900); do
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
            'k3s kubectl get --raw="/readyz" 2>/dev/null | grep -q "^ok$" && [ -s /var/lib/rancher/k3s/server/node-token ]' 2>/dev/null; then
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
                'k3s kubectl label node ${clusterNameLower}-cp0 node-role.kubernetes.io/control-plane=true --overwrite >/dev/null 2>&1 || true' 2>/dev/null || true
            echo "K3s setup is complete"
            exit 0
        fi
        echo "Waiting for K3s setup (expected: up to 15m)... ($i/900)" >&2
        sleep 1
    done
    echo "K3s setup failed to complete within 900 seconds" >&2
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
        'systemctl status k3s --no-pager -l | tail -n 80; journalctl -u k3s --no-pager -n 120 | tail -n 120' 2>/dev/null || true
    exit 1`,
                triggers: [this.controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [k3sCp0JoinOrInit] },
        );

        const getK3SToken = new command.local.Command(
            "get-k3s-token",
            {
                create: pulumi.interpolate`ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} cat /var/lib/rancher/k3s/server/node-token`,
                triggers: [this.controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [waitForK3sCp0SetupReady] },
        );

        const getKubeconfig = new command.local.Command(
            "get-kubeconfig",
            {
                create: pulumi.interpolate`ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://${this.controlPlane.ipv4Address}:6443|g"`,
                triggers: [this.controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [getK3SToken] },
        );

        this.kubeconfigRaw = getKubeconfig.stdout;

        /////////////////////
        // Additional Control Planes — sequential (etcd allows one learner at a time)
        /////////////////////

        this.additionalCpNodes = [];
        let cpJoinBarrier: pulumi.Resource = waitForK3sCp0SetupReady;

        for (const node of controlPlaneNodes.slice(1)) {
            const nodeName = `${clusterNameLower}-${node.id}`;
            const userData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${privateNetworkSetupScript}
${timezoneSetupScript}
apt-get update -qq && apt-get install -y nfs-common

PUBLIC_IP=$(ip -o -4 addr show | awk '$4 !~ /^10\\./ && $4 !~ /^127\\./ {split($4,a,"/"); print a[1]; exit}')
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG_JOIN
node-name: ${nodeName}
server: https://${this.controlPlanePrivateIp}:6443
token: ${getK3SToken.stdout}
advertise-address: \$PRIVATE_IP
node-ip: \$PRIVATE_IP
tls-san:
  - \$PUBLIC_IP
  - \$PRIVATE_IP
disable:
${useHetznerCcm ? "  - servicelb" : ""}
  - traefik
${k3sServerCloudProviderConfig}
KCONFIG_JOIN
chmod 600 /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -
systemctl enable --now k3s
echo "K3s additional control plane (${nodeName}) setup complete"
`;
            const server = new hcloud.Server(
                `${clusterName}-server-k3s-${node.id}`,
                {
                    name: nodeName,
                    serverType: node.serverType.toLowerCase(),
                    image: clusterOS,
                    location: node.location,
                    sshKeys: [serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                    userData,
                },
                {
                    provider: hProvider,
                    parent: this,
                    dependsOn: [cpJoinBarrier, waitForK3sCp0SetupReady, getK3SToken],
                },
            );

            const waitForCpJoin = new command.local.Command(
                `wait-for-k3s-join-${node.id}`,
                {
                    create: pulumi.interpolate`
                TMPKC=$(mktemp)
                cat > "$TMPKC" << 'KUBECFG'
${this.kubeconfigRaw}
KUBECFG
                trap 'rm -f "$TMPKC"' EXIT
                for i in $(seq 1 180); do
                    if ! kubectl --kubeconfig="$TMPKC" get --raw='/readyz' >/dev/null 2>&1; then
                        echo "Waiting for ${nodeName}... (attempt $i/180) | apiserver unavailable"
                        sleep 5
                        continue
                    fi
                    READY=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
                    if [ "$READY" = "True" ]; then
                        kubectl --kubeconfig="$TMPKC" label node ${nodeName} node-role.kubernetes.io/control-plane=true --overwrite >/dev/null 2>&1 || true
                        echo "${nodeName} is Ready"
                        exit 0
                    fi
                    STATUS_LINE=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} --no-headers 2>/dev/null || true)
                    if [ -n "$STATUS_LINE" ]; then
                        echo "Waiting for ${nodeName}... (attempt $i/180) | $STATUS_LINE"
                    else
                        echo "Waiting for ${nodeName}... (attempt $i/180) | node not registered yet"
                    fi
                    sleep 5
                done
                echo "${nodeName} not ready after 15 minutes" >&2
                kubectl --kubeconfig="$TMPKC" get nodes -o wide || true
                kubectl --kubeconfig="$TMPKC" describe node ${nodeName} || true
                echo "--- SSH debug on ${nodeName} (${server.ipv4Address}) ---" >&2
                ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${server.ipv4Address} \
                  'hostname; date; ip -brief a; systemctl is-active k3s || true; systemctl status k3s --no-pager -l | tail -n 80; journalctl -u k3s --no-pager -n 120 | tail -n 120' || true
                exit 1
                `,
                    triggers: [server.ipv4Address],
                },
                {
                    parent: this,
                    dependsOn: [server, waitForK3sCp0SetupReady, getK3SToken, getKubeconfig],
                },
            );

            this.additionalCpNodes.push(server);
            cpJoinBarrier = waitForCpJoin;
        }

        // k8sProvider waits for ALL control plane nodes to be Ready.
        this.k8sProvider = new k8s.Provider(
            "k8s",
            {
                kubeconfig: this.kubeconfigRaw,
                suppressDeprecationWarnings: true,
                enableServerSideApply: true,
            },
            { parent: this, dependsOn: [cpJoinBarrier] },
        );

        /////////////////////
        // Workers
        /////////////////////

        const workerUserData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${privateNetworkSetupScript}
    ${timezoneSetupScript}
apt-get update -qq && apt-get install -y nfs-common
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG_WORKER
node-ip: \$PRIVATE_IP
${k3sWorkerCloudProviderConfig}
KCONFIG_WORKER
chmod 600 /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | K3S_URL=https://${this.controlPlanePrivateIp}:6443 K3S_TOKEN=${getK3SToken.stdout} sh -
echo "K3s worker setup complete"
`;

        this.cloudWorkers = workerNodes.map((node) => {
            const nodeName = `${clusterNameLower}-${node.id}`;
            return new hcloud.Server(
                `${clusterName}-server-k3s-${node.id}`,
                {
                    name: nodeName,
                    serverType: node.serverType.toLowerCase(),
                    image: clusterOS,
                    location: node.location,
                    sshKeys: [serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                    userData: workerUserData,
                },
                { provider: hProvider, parent: this, dependsOn: [cpJoinBarrier] },
            );
        });

        this.registerOutputs({
            controlPlane: this.controlPlane,
            controlPlanePrivateIp: this.controlPlanePrivateIp,
            k8sProvider: this.k8sProvider,
            additionalCpNodes: this.additionalCpNodes,
            cloudWorkers: this.cloudWorkers,
            kubeconfigRaw: this.kubeconfigRaw,
        });
    }
}
