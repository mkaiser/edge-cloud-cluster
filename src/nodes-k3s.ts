import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as k8s from "@pulumi/kubernetes";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import type { NetworkComponent } from "./network";

export class K3sNodesComponent extends pulumi.ComponentResource {
    public readonly controlPlane: hcloud.Server;
    public readonly controlPlanePrivateIp: pulumi.Output<string>;
    public readonly k8sProvider: k8s.Provider;
    public readonly additionalCpNodes: hcloud.Server[];
    public readonly cloudWorkers: hcloud.Server[];
    public readonly kubeconfigRaw: pulumi.Output<string>;

    constructor(
        name: string,
        networkComponent: NetworkComponent,
        hProvider: hcloud.Provider,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:nodes:K3sNodes", name, {}, opts);
        const { network, firewall } = networkComponent;

        const k3sDisableFlags =
            project_settings.server.loadBalancerProvider === "hetzner-ccm"
                ? "disable:\n  - servicelb\n  - traefik"
                : "disable:\n  - traefik";
        const k3sServerCloudProviderConfig =
            project_settings.server.loadBalancerProvider === "hetzner-ccm"
                ? "disable-cloud-controller: true\nkubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
                : "kubelet-arg:\n  - max-pods=300";
        // max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping opendesk
        const k3sWorkerCloudProviderConfig =
            project_settings.server.loadBalancerProvider === "hetzner-ccm"
                ? "kubelet-arg:\n  - cloud-provider=external\n  - max-pods=200"
                : "kubelet-arg:\n  - max-pods=300";
        // max-pods= 200 is required, because the standard value of 110 is too low for bootstrapping opendesk

        // Shared bash snippet: set timezone for Debian/Ubuntu nodes.
        const timezoneSetupScript = `
    timedatectl set-timezone ${project_settings.general.timezone} || {
        ln -sf /usr/share/zoneinfo/${project_settings.general.timezone} /etc/localtime
        echo ${project_settings.general.timezone} > /etc/timezone
    }
`;

        // Shared bash snippet: kernel tuning required for heavy workloads (GitLab, openDesk).
        // inotify defaults (128 instances, 8192 watches) are exhausted by the number of
        // pods/containers running on a single node, causing "too many open files" in GitLab migrations.
        const sysctlTuningScript = `
    cat >> /etc/sysctl.d/99-k8s.conf << 'SYSCTL'
fs.inotify.max_user_instances = 4096
fs.inotify.max_user_watches = 1048576
fs.file-max = 1048576
SYSCTL
    sysctl --system
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
Destination=${project_settings.network.privateRange}
Gateway=${project_settings.network.gateway}
ROUTECONF
        ip route add ${project_settings.network.privateRange} via ${project_settings.network.gateway} dev "\${PRIVATE_IFACE}" onlink || true
        # Persist IP forwarding for WireGuard
        cat > /etc/sysctl.d/99-wireguard.conf << SYSCTLWG
net.ipv4.ip_forward = 1
SYSCTLWG
        sysctl --system || true
    else
        echo "WARNING: private network interface not found" >&2
        PRIVATE_IP=""
    fi
`;

        const etcdS3ConfigBlock =
            project_settings.general.backupToS3IntervalHour > 0
                ? pulumi.interpolate`etcd-s3: true
etcd-s3-folder: ${project_settings.server.os === "Talos" ? "talos-etcd" : "k3s-etcd"}
# Take etcd snapshots every N hours (config: general.backupToS3IntervalHour).
etcd-snapshot-schedule-cron: "0 */${project_settings.general.backupToS3IntervalHour} * * *"
etcd-snapshot-retention: 144`
                : pulumi.output("# etcd-s3 backup disabled (backupToS3IntervalHour=0)");

        const etcdBucket = project_settings.storage.objectStorage.buckets.find(
            (b) => b.key === "etcd",
        )!;
        const etcdS3SecretsBlock =
            project_settings.general.backupToS3IntervalHour > 0
                ? pulumi.interpolate`etcd-s3-endpoint: ${project_settings.storage.objectStorage.baseEndpoint}
etcd-s3-bucket: ${etcdBucket.name}
etcd-s3-access-key: ${project_settings.storage.objectStorage.accessKey}
etcd-s3-secret-key: ${project_settings.storage.objectStorage.secretKey}`
                : pulumi.output("");

        const s3ConnectivityCheck =
            project_settings.general.backupToS3IntervalHour > 0
                ? pulumi.interpolate`S3_HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${etcdBucket.name}.${project_settings.storage.objectStorage.baseEndpoint}/")
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
${sysctlTuningScript}
apt-get update -qq && apt-get install -y nfs-common open-iscsi && systemctl enable --now iscsid

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << 'KCONFIG'
cluster-init: true
${k3sDisableFlags}
${k3sServerCloudProviderConfig}
${etcdS3ConfigBlock}
kube-controller-manager-arg:
  - "node-monitor-grace-period=300s"
  - "node-monitor-period=30s"
KCONFIG
PUBLIC_IP=$(ip -o -4 addr show | awk '$4 !~ /^10\\./ && $4 !~ /^127\\./ {split($4,a,"/"); print a[1]; exit}')
cat >> /etc/rancher/k3s/config.yaml << KCONFIG_SECRETS
node-name: ${project_settings.general.name.toLowerCase()}-cp0
advertise-address: \$PRIVATE_IP
node-ip: \$PRIVATE_IP
flannel-iface: \$PRIVATE_IFACE
tls-san:
  - \$PUBLIC_IP
  - \$PRIVATE_IP
  - 10.0.0.100
${etcdS3SecretsBlock}
KCONFIG_SECRETS
chmod 600 /etc/rancher/k3s/config.yaml

# Custom flannel config: force VNI=1 (k3s defaults to VNI=0 on Debian 13, workers use VNI=1).
cat > /etc/rancher/k3s/flannel-conf.json << 'FLANNEL_CONF'
{
  "Network": "10.42.0.0/16",
  "EnableIPv6": false,
  "EnableIPv4": true,
  "IPv6Network": "::/0",
  "Backend": {
    "Type": "vxlan",
    "VNI": 1,
    "Port": 8472
  }
}
FLANNEL_CONF
echo "flannel-conf: /etc/rancher/k3s/flannel-conf.json" >> /etc/rancher/k3s/config.yaml

${s3ConnectivityCheck}

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -

if [ "${project_settings.general.restoreClusterFromS3Backup}" = "true" ]; then
    SNAPSHOT=$(k3s etcd-snapshot ls \
        --etcd-s3-endpoint=${project_settings.storage.objectStorage.baseEndpoint} \
        --etcd-s3-access-key=${project_settings.storage.objectStorage.accessKey} \
        --etcd-s3-secret-key=${project_settings.storage.objectStorage.secretKey} \
        --etcd-s3-bucket=${etcdBucket.name} \
        --etcd-s3-folder=${project_settings.server.os === "Talos" ? "talos-etcd" : "k3s-etcd"} \
        2>/dev/null | awk 'NR>1{print $1}' | sort | tail -1 || echo "")
    if [ -n "$SNAPSHOT" ]; then
        echo "Restoring etcd from: $SNAPSHOT" >&2
        k3s server --cluster-reset --cluster-reset-restore-path="$SNAPSHOT" \
            --etcd-s3 \
            --etcd-s3-endpoint=${project_settings.storage.objectStorage.baseEndpoint} \
            --etcd-s3-access-key=${project_settings.storage.objectStorage.accessKey} \
            --etcd-s3-secret-key=${project_settings.storage.objectStorage.secretKey} \
            --etcd-s3-bucket=${etcdBucket.name} \
            --etcd-s3-folder=${project_settings.server.os === "Talos" ? "talos-etcd" : "k3s-etcd"} 2>&1 | tail -10 || true
    else
        echo "No S3 snapshot found — fresh start" >&2
    fi
fi

touch /var/lib/k3s-install-complete
echo "K3s install complete — waiting for Pulumi to start K3s" >&2
`;

        this.controlPlane = new hcloud.Server(
            `${project_settings.general.name}-server-k3s-cp0`,
            {
                name: `${project_settings.general.name.toLowerCase()}-cp0`,
                serverType: project_settings.nodes.controlPlane[0].serverType.toLowerCase(),
                image: project_settings.server.os,
                location: project_settings.nodes.controlPlane[0].location,
                sshKeys: [project_settings.server.serverSshKey],
                networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                firewallIds: [firewall.id.apply((id) => Number(id))],
                userData: primaryCpUserData,
            },
            {
                provider: hProvider,
                parent: this,
                ignoreChanges: ["userData"],
            },
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
                create: pulumi
                    .all([this.controlPlane.ipv4Address, project_settings.general.hcloudToken])
                    .apply(
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
                "https://api.hetzner.cloud/v1/servers?name=${project_settings.general.name.toLowerCase()}-cp1" | \
                jq -r '.servers[0].public_net.ipv4.ip // ""' 2>/dev/null || echo "")

            JOIN_MODE=false
            if [ -n "$CP1_IP" ] && [ "${project_settings.general.restoreClusterFromS3Backup}" != "true" ]; then
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

        // Longhorn disk config shared across all node types (CP0, additional CPs, workers).
        // Encoded in TypeScript so it can be safely embedded in SSH commands and
        // k3s config.yaml node-annotation values without heredoc/quoting issues.
        const longhornDiskCfg = JSON.stringify([
            {
                path: "/var/lib/longhorn",
                allowScheduling: true,
                storageReserved: 0,
                tags: ["local-ssd"],
            },
        ]);
        const cp0NodeName = `${project_settings.general.name.toLowerCase()}-cp0`;
        const longhornAnnotateB64 = Buffer.from(
            [
                `k3s kubectl label node ${cp0NodeName} node.longhorn.io/create-default-disk=config --overwrite >/dev/null 2>&1 || true`,
                `k3s kubectl annotate node ${cp0NodeName} 'node.longhorn.io/default-disks-config=${longhornDiskCfg}' --overwrite >/dev/null 2>&1 || true`,
            ].join("\n"),
        ).toString("base64");

        const waitForK3sCp0SetupReady = new command.local.Command(
            "wait-for-k3s-setup-cp0-ready",
            {
                create: pulumi.interpolate`for i in $(seq 1 900); do
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
            'k3s kubectl get --raw="/readyz" 2>/dev/null | grep -q "^ok$" && [ -s /var/lib/rancher/k3s/server/node-token ]' 2>/dev/null; then
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
                'k3s kubectl label node ${cp0NodeName} node-role.kubernetes.io/control-plane=true --overwrite >/dev/null 2>&1 || true' 2>/dev/null || true
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} \
                'echo ${longhornAnnotateB64} | base64 -d | bash' 2>/dev/null || true
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

        const selectKubeconfig = new command.local.Command(
            "select-kubeconfig",
            {
                create: pulumi.interpolate`PUBLIC_KC=$(mktemp)
PRIVATE_KC=$(mktemp)
cleanup() {
    rm -f "$PUBLIC_KC" "$PRIVATE_KC"
}
trap cleanup EXIT

cat > "$PUBLIC_KC" << 'KUBECFG_PUBLIC'
${getKubeconfig.stdout}
KUBECFG_PUBLIC

SSH_PRIVATE_KC=$(ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${this.controlPlane.ipv4Address} cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://${this.controlPlanePrivateIp}:6443|g")
printf '%s\n' "$SSH_PRIVATE_KC" > "$PRIVATE_KC"

for i in $(seq 1 180); do
    if kubectl --kubeconfig="$PRIVATE_KC" get --raw='/readyz' >/dev/null 2>&1; then
        cat "$PRIVATE_KC"
        exit 0
    fi
    if kubectl --kubeconfig="$PUBLIC_KC" get --raw='/readyz' >/dev/null 2>&1; then
        cat "$PUBLIC_KC"
        exit 0
    fi
    echo "Waiting for a reachable K3s API endpoint... (attempt $i/180)" >&2
    sleep 5
done
echo "No reachable K3s API endpoint found in time" >&2
exit 1`,
                triggers: [this.controlPlane.ipv4Address],
            },
            { parent: this, dependsOn: [getKubeconfig] },
        );

        this.kubeconfigRaw = selectKubeconfig.stdout;

        /////////////////////
        // Additional Control Planes — sequential (etcd allows one learner at a time)
        /////////////////////

        this.additionalCpNodes = [];
        let cpJoinBarrier: pulumi.Resource = waitForK3sCp0SetupReady;

        for (const node of project_settings.nodes.controlPlane.slice(1)) {
            const nodeName = `${project_settings.general.name.toLowerCase()}-${node.id}`;
            const userData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${privateNetworkSetupScript}
    # Route to WireGuard VPN subnet via primary control plane private IP
    if [ -n "\$PRIVATE_IFACE" ]; then
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-wireguard-route.network << ROUTECONF_WG
[Match]
Name=\${PRIVATE_IFACE}

[Route]
Destination=${project_settings.wireguard.vpnSubnet}
Gateway=${this.controlPlanePrivateIp}
ROUTECONF_WG
        ip route add ${project_settings.wireguard.vpnSubnet} via ${this.controlPlanePrivateIp} dev "\$PRIVATE_IFACE" onlink || true
    fi
${timezoneSetupScript}
${sysctlTuningScript}
apt-get update -qq && apt-get install -y nfs-common open-iscsi && systemctl enable --now iscsid

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
  - 10.0.0.100
disable:
${project_settings.server.loadBalancerProvider === "hetzner-ccm" ? "  - servicelb" : ""}
  - traefik
${k3sServerCloudProviderConfig}
KCONFIG_JOIN
chmod 600 /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -
systemctl enable --now k3s
echo "K3s additional control plane (${nodeName}) setup complete"
`;
            const server = new hcloud.Server(
                `${project_settings.general.name}-server-k3s-${node.id}`,
                {
                    name: nodeName,
                    serverType: node.serverType.toLowerCase(),
                    image: project_settings.server.os,
                    location: node.location,
                    sshKeys: [project_settings.server.serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                    userData,
                },
                {
                    provider: hProvider,
                    parent: this,
                    dependsOn: [cpJoinBarrier, waitForK3sCp0SetupReady, getK3SToken],
                    ignoreChanges: ["userData"],
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
                        kubectl --kubeconfig="$TMPKC" label node ${nodeName} node.longhorn.io/create-default-disk=config --overwrite >/dev/null 2>&1 || true
                        kubectl --kubeconfig="$TMPKC" annotate node ${nodeName} 'node.longhorn.io/default-disks-config=${longhornDiskCfg}' --overwrite >/dev/null 2>&1 || true
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
                // If the cluster becomes unreachable mid-destroy (VMs already gone),
                // treat K8s resource deletions as successful instead of erroring.
                deleteUnreachable: true,
            },
            { parent: this, dependsOn: [cpJoinBarrier, selectKubeconfig] },
        );

        /////////////////////
        // Workers
        /////////////////////

        this.cloudWorkers = project_settings.nodes.workers.map((node) => {
            const nodeName = `${project_settings.general.name.toLowerCase()}-${node.id}`;
            const workerUserData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${privateNetworkSetupScript}
    # Route to WireGuard VPN subnet via primary control plane private IP
    if [ -n "\$PRIVATE_IFACE" ]; then
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-wireguard-route.network << ROUTECONF_WG
[Match]
Name=\${PRIVATE_IFACE}

[Route]
Destination=${project_settings.wireguard.vpnSubnet}
Gateway=${this.controlPlanePrivateIp}
ROUTECONF_WG
        ip route add ${project_settings.wireguard.vpnSubnet} via ${this.controlPlanePrivateIp} dev "\$PRIVATE_IFACE" onlink || true
    fi
    ${timezoneSetupScript}
${sysctlTuningScript}
apt-get update -qq && apt-get install -y nfs-common open-iscsi && systemctl enable --now iscsid
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG_WORKER
node-ip: \$PRIVATE_IP
flannel-iface: \$PRIVATE_IFACE
${k3sWorkerCloudProviderConfig}
node-label:
  - 'node.longhorn.io/create-default-disk=config'
node-annotation:
  - 'node.longhorn.io/default-disks-config=${longhornDiskCfg}'
KCONFIG_WORKER
chmod 600 /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | K3S_URL=https://${this.controlPlanePrivateIp}:6443 K3S_TOKEN=${getK3SToken.stdout} sh -
echo "K3s worker setup complete"
`;
            return new hcloud.Server(
                `${project_settings.general.name}-server-k3s-${node.id}`,
                {
                    name: nodeName,
                    serverType: node.serverType.toLowerCase(),
                    image: project_settings.server.os,
                    location: node.location,
                    sshKeys: [project_settings.server.serverSshKey],
                    networks: [{ networkId: network.id.apply((id) => Number(id)) }],
                    firewallIds: [firewall.id.apply((id) => Number(id))],
                    userData: workerUserData,
                },
                {
                    provider: hProvider,
                    parent: this,
                    dependsOn: [cpJoinBarrier],
                    ignoreChanges: ["userData"],
                },
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
