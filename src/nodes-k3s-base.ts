/**
 * Project: edgecloudinfra
 * File: nodes-k3s-base.ts
 * Purpose: Provider-AGNOSTIC k3s cluster bring-up flow. Owns the single co-provisioning
 *          sequence (cp0 init/join → wait-ready → token → kubeconfig → additional CPs →
 *          workers) and all the SSH-driven orchestration Commands, which only need a
 *          node's public IP + SSH access. Per-provider machine creation and a handful of
 *          provider-specific details are delegated to a ProviderProvisioner strategy.
 *
 *          project_settings.nodes.cloud is ONE mixed list (hcloud + robot); the base
 *          dispatches per node on `node.provider` to the matching provisioner. Concrete
 *          provisioners live in nodes-k3s-hetzner-cloud.ts (hcloud) and
 *          nodes-k3s-hetzner-robot.ts (robot); a future SECA provisioner implements the
 *          same hooks. The per-provider dispatcher (K3sNodesComponent) is in
 *          nodes-k3s-dispatch.ts.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import { runtime_flags } from "../runtime_flags";
import type { ComputeNodeCloud, ComputeNodeMesh } from "../project_settings_types";
import type { ClusterNode } from "./nodes-k3s-types";
import {
    abortAfter,
    k3sCniServerConfig,
    k3sDisableFlags,
    k3sServerCloudProviderConfig,
    k3sWorkerCloudProviderConfig,
    swapKubeletArg,
    longhornPrereqScript,
    timezoneSetupScript,
    sysctlTuningScript,
    swapSetupScript,
    etcdBucket,
    etcdS3ConfigBlock,
    etcdS3SecretsBlock,
    s3ConnectivityCheck,
    longhornDiskCfgFor,
    descriptionAnnotateCmd,
} from "./nodes-k3s-common";

// The ecc/* label keys. Declared once in project_settings.applicationPlacements;
// never write the literal here (checkSiteAnchors.py fails the commit on one).
const ECC = project_settings.applicationPlacements.labels;

// k3s apiserver port (single source of truth in project_settings.network).
const k3sApiPort = project_settings.network.k3sApiPort;

// Any node the base flow may provision: a Hetzner cloud/robot node OR (when it is the
// cluster-init CP, Stage B) an on-premise mesh node.
export type ClusterComputeNode = ComputeNodeCloud | ComputeNodeMesh;

// ─────────────────────────────────────────────────────────────────────────────
// SSH target descriptor — how the base flow's orchestration Commands reach a node.
// Cloud/robot nodes are reached as `root@<public-ipv4>` on port 22 with the local
// SSH agent's key (today's behaviour). An mesh init CP is reached as its configured
// ssh{user,host,port} with a Pulumi-held private key and sudo for privileged ops.
// ─────────────────────────────────────────────────────────────────────────────
export interface SshTarget {
    user: string; // "root" for cloud/robot; node.ssh.user for mesh
    host: pulumi.Input<string>; // the public IPv4 (cloud/robot) or ssh.endpoint (mesh)
    port: number; // 22 for cloud/robot; node.ssh.port for mesh
    // Prefix for commands that need privilege on the remote (e.g. "sudo "); empty for
    // root logins. Applied by callers that run privileged remote commands.
    sudoPrefix: string;
    // Private key for the SSH connection. Undefined → rely on the local ssh-agent (cloud/
    // robot, today's behaviour). Set → an explicit key written to a temp file per command
    // (mesh, whose key is a Pulumi secret, not in the agent).
    privateKey?: pulumi.Output<string>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider strategy. The base flow builds each node's userData (provider-agnostic)
// and the SSH orchestration; the provisioner decides HOW a machine is created and
// the few provider-specific shell fragments.
// ─────────────────────────────────────────────────────────────────────────────
export interface ProvisionResult {
    node: ClusterNode; // public addresses for DNS/ingress + SSH targeting
    privateIp: pulumi.Output<string>; // node's private-network IP
    // The underlying machine resource (hcloud.Server, or the robot SSH provisioning
    // Command). The base flow's orchestration Commands dependsOn this so they wait for
    // the machine to exist / be provisioned before SSHing in.
    resource: pulumi.Resource;
    // How the base flow SSHes into this node for orchestration (token fetch, kubeconfig,
    // readiness probes). Optional for back-compat: absent → root@node.ipv4Address :22 via
    // the local agent (cloud/robot). The mesh init provisioner sets it explicitly.
    sshTarget?: SshTarget;
}

export interface ProviderProvisioner {
    // "hcloud" | "robot" for the Hetzner provisioners; "mesh" for the on-premise init CP.
    readonly provider: ComputeNodeCloud["provider"] | "mesh";

    // Create a control-plane machine (the init CP or an additional CP) running `userData`.
    // hcloud → hcloud.Server(cloud-init userData); robot/mesh → SSH base64-inlined script.
    // `node` is ClusterComputeNode because the init CP may be an mesh node (Stage B);
    // additional (cloud) CPs always pass a ComputeNodeCloud, which is assignable.
    provisionControlPlane(args: {
        node: ClusterComputeNode;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult;

    // Create a worker machine running `userData`. Cloud-only in practice (mesh followers
    // join in a later pass); the mesh provisioner throws here. `node` is widened to
    // ClusterComputeNode only for signature uniformity across provisioners.
    provisionWorker(args: {
        node: ClusterComputeNode;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult;

    // Bash that, when sourced in the initial-CP join-or-init script, sets PEER_IP to the
    // public IP of the peer control-plane `peer` (else empty when peer is undefined).
    // hcloud → Hetzner API curl by the peer's node-name; robot → echo the peer's configured
    // publicIp; mesh → empty (no private-net peers). `peer` is the first additional
    // control-plane node (always cloud), not a magic "cp1".
    discoverPeerCpIpScript(peer: ComputeNodeCloud | undefined): pulumi.Input<string>;

    // Host-prep snippet that detects the node's reachable iface and exports PRIVATE_IFACE +
    // PRIVATE_IP (the advertise/node-ip the userData uses). hcloud → DHCP 10.0.x detection;
    // robot → static vSwitch VLAN; mesh → primary LAN iface/IP.
    privateNetworkSetupScript(node: ClusterComputeNode): string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Abstract component owning the cluster bring-up flow.
// ─────────────────────────────────────────────────────────────────────────────
export abstract class AbstractK3sNodes extends pulumi.ComponentResource {
    public readonly controlPlane: ClusterNode;
    public readonly controlPlanePrivateIp: pulumi.Output<string>;
    public readonly k8sProvider: k8s.Provider;
    public readonly additionalCpNodes: ClusterNode[];
    public readonly cloudWorkers: ClusterNode[];
    public readonly kubeconfigRaw: pulumi.Output<string>;

    // Resolves the provisioner for a given node's provider. With a mixed hcloud+robot
    // list this dispatches per node; an all-hcloud cluster returns the same provisioner
    // for every node. Passed as a constructor arg (not an abstract method) because the
    // bring-up flow runs inside super() — before a subclass could assign instance state.
    private readonly provisionerFor: (node: ClusterComputeNode) => ProviderProvisioner;

    constructor(
        type: string,
        name: string,
        provisionerFor: (node: ClusterComputeNode) => ProviderProvisioner,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super(type, name, {}, opts);
        this.provisionerFor = provisionerFor;

        // Unified node list → derive the initial-CP / additional-CP / worker views.
        // The initial CP (runs cluster-init) is selected by clusterLink === "init" across
        // BOTH cloud and mesh (Stage B: an on-premise node may be the init CP). Its k3s
        // node-name derives from its own id, like every other node.
        //
        // Additional CPs / workers built SYNCHRONOUSLY here are cloud-only "direct" peers
        // (they share the init CP's site). "vpn" followers — and ANY follower when the init
        // CP is a mesh node — join in a later mesh pass (nodes-k3s-mesh.ts), NOT here.
        // enabled:false parks a node: it is declared but must NOT be provisioned. For cloud
        // nodes Pulumi CREATES the server, so a parked node dropped here is simply never
        // built (the intended staging behaviour) — without this filter bootstrap wrongly
        // created every enabled:false hcloud node. validateClusterNodes already guarantees
        // the init CP is enabled and ≥1 cloud node is enabled, so this cannot empty the init
        // search or the cluster. Mesh nodes are filtered separately in nodes-k3s-mesh.ts.
        const cloud = project_settings.nodes.cloud.filter((n) => n.enabled !== false);
        const mesh = project_settings.nodes.mesh;
        const initialCpNode: ClusterComputeNode = [...cloud, ...mesh].find(
            (n) => n.clusterLink === "init",
        )!;
        // Synchronous (pass-1) followers: cloud "direct" CPs/workers only. When the init CP
        // is a mesh node, cloud nodes are "vpn" (2nd pass) → these lists are empty here.
        const extraCps = cloud.filter(
            (n) => n.k8sRole === "controlplane" && n.clusterLink === "direct",
        );
        const workers = cloud.filter((n) => n.k8sRole === "worker" && n.clusterLink === "direct");

        const clusterName = project_settings.general.name.toLowerCase();

        /////////////////////
        // Initial control plane (cluster-init)
        /////////////////////

        const initialCpProvisioner = this.provisionerFor(initialCpNode);
        const initialCpName = `${clusterName}-${initialCpNode.id}`;

        // Is the init CP an on-premise mesh node? Mesh nodes have an `ssh` block and no
        // `provider`. When true, the init CP advertises on its LAN IP (not a Hetzner private
        // IP), is reached over SSH as the mesh user, and skips Hetzner-private specifics
        // (kube-vip VIP SAN, S3 restore on the box). swap/swapBehavior are cloud-only fields.
        const initIsMesh = !("provider" in initialCpNode);
        const initCloud = initialCpNode as ComputeNodeCloud; // valid only when !initIsMesh
        const initSwap = initIsMesh ? undefined : initCloud.swap;
        const initSwapBehavior = initIsMesh ? undefined : initCloud.swapBehavior;

        const primaryCpUserData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${initialCpProvisioner.privateNetworkSetupScript(initialCpNode)}
    ${timezoneSetupScript}
${sysctlTuningScript}
${swapSetupScript(initSwap, initSwapBehavior)}
${longhornPrereqScript}

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << 'KCONFIG'
cluster-init: true
${k3sDisableFlags}
${k3sCniServerConfig}
${k3sServerCloudProviderConfig}${swapKubeletArg(initSwap)}
${etcdS3ConfigBlock}
kube-controller-manager-arg:
  - "node-monitor-grace-period=300s"
  - "node-monitor-period=30s"
KCONFIG
PUBLIC_IP=$(ip -o -4 addr show | awk '$4 !~ /^10\\./ && $4 !~ /^127\\./ {split($4,a,"/"); print a[1]; exit}')
cat >> /etc/rancher/k3s/config.yaml << KCONFIG_SECRETS
# Stable across recreates so an etcd S3 snapshot stays decryptable — see the
# k3sClusterToken comment in project_settings.ts.
token: ${project_settings.general.k3sClusterToken}
node-name: ${initialCpName}
advertise-address: \$PRIVATE_IP
node-ip: \$PRIVATE_IP
# tls-san: ${project_settings.network.vip} = kube-vip private VIP; ${project_settings.network.cpMeshIps[0]} = cp0's headscale/tailscale IP;
# k3s-api.ts.internal = headscale MagicDNS name → ${project_settings.network.cpMeshIps[0]} (the endpoint mesh nodes use).
# cp0 always joins the headscale mesh first (during bootstrap, before any mesh node), so it
# deterministically gets .1 of the ${project_settings.network.meshRange} prefix. Mesh nodes connect to the API at
# https://k3s-api.ts.internal:6443 (they can't reach the private VIP — cp0 doesn't forward
# ${project_settings.network.subnetRange} off tailscale0), so both the DNS name and the IP must be SANs or mesh TLS fails.
# ${project_settings.network.apiServerHost} = the devcontainer-side stable admin endpoint name (see project_settings
# network.apiServerHost) — the select-kubeconfig/provider kubeconfig points at it, /etc/hosts flips the IP.
tls-san:
  - \$PUBLIC_IP
  - \$PRIVATE_IP
${initIsMesh ? "" : `  - ${project_settings.network.vip}\n`}  - ${project_settings.network.cpMeshIps[0]}
  - k3s-api.ts.internal
  - ${project_settings.network.apiServerHost}
${etcdS3SecretsBlock}
KCONFIG_SECRETS
chmod 600 /etc/rancher/k3s/config.yaml

# NOTE: no flannel-conf.json and no flannel-iface — k3s runs with flannel-backend: none and
# Cilium owns the pod network (src/cni.ts). The MTU constraint is a property of tunnelling
# over tailscale0, not of any one CNI, so it lives in Cilium's MTU value
# (project_settings.network.cni.mtu = 1230 — see the full rationale there). Mesh nodes tunnel
# over tailscale0, whose WireGuard MTU is 1280, and VXLAN adds 50 bytes. Left at Cilium's
# auto-detected ~1450 (from the 1500 underlay), encapsulated packets exceed 1280, so large
# frames (API watch streams, kubectl logs, SA-token responses, Longhorn gRPC) are silently
# dropped while small ones (heartbeats, handshakes) pass — an intermittently-"Ready" mesh node
# whose pods crash-loop on lost API connections.
# NB 1230 is the DEVICE MTU; Cilium derives the pod route MTU as device-50, so the effective
# pod MTU is 1180 on every REMOTE-CIDR path, cloud↔cloud included.

${s3ConnectivityCheck}

# Idempotent k3s install: skip the network fetch if the binary is already present. The
# get.k3s.io installer reaches out to update.k3s.io/github for the release channel + hash,
# which occasionally returns a bad/self-signed TLS cert (transient upstream) and aborts the
# whole provision under \`set -e\`. A re-provision (e.g. a config delta, NOT a reinstall —
# Phase 1 wipes the disk and removes the binary) must not re-hit that flaky download when
# k3s is already installed. On a fresh box the binary is absent → installs normally.
if command -v k3s >/dev/null 2>&1; then
    echo "k3s already installed ($(k3s --version 2>/dev/null | head -1)) — skipping installer download." >&2
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${project_settings.general.k3sVersion} INSTALL_K3S_SKIP_START=true sh -
fi

if [ "${project_settings.general.targetState === "restore"}" = "true" ]; then
    # WARNING: DO NOT USE the k3s etcd-snapshot ls subcommand HERE. It is SERVER-side: it opens
    # /var/lib/rancher/k3s/server/token before it ever reaches S3, and on a node being
    # provisioned that file does not exist yet (the token is read OFF the running server by
    # get-k3s-token, so it cannot exist before k3s first starts). It therefore dies with
    #   level=fatal msg="Error: open /var/lib/rancher/k3s/server/token: no such file or directory"
    # regardless of the --etcd-s3* flags. Measured 2026-09-05/06 on ecc199 and ecc200: the
    # failure was invisible because the stderr was discarded and the restore silently degraded
    # to a FRESH cluster (rc=0, green, no data) — the one failure an operator cannot see.
    # A manual check on an already-running node passes, which is what made this look fixed.
    #
    # List the bucket directly instead: plain S3, no k3s state required. The name sorts
    # lexically by the unix timestamp the snapshot name ends with, so sort+tail gives the
    # newest; shutdown-snapshot-* and etcd-snapshot-* share that suffix format.
    # curl --aws-sigv4, not the aws CLI: the robot image does not ship awscli, and installing
    # it mid-provision to read one listing would be a second failure point.
    SNAPSHOT_NAME=$(curl -sS --aws-sigv4 "aws:amz:${etcdBucket.location}:s3" \
        --user "${project_settings.storage.objectStorage.accessKey}:${project_settings.storage.objectStorage.secretKey}" \
        "https://${etcdBucket.name}.${project_settings.storage.objectStorage.baseEndpoint}/?list-type=2&prefix=k3s-etcd/" \
        2>/tmp/k3s-snapshot-ls.err \
        | grep -oE '<Key>[^<]*</Key>' | sed -e 's|<Key>||g' -e 's|</Key>||g' \
        | grep snapshot | sort | tail -1 | sed 's|^k3s-etcd/||' || echo "")
    SNAPSHOT="$SNAPSHOT_NAME"
    if [ -z "$SNAPSHOT" ] && [ -s /tmp/k3s-snapshot-ls.err ]; then
        echo "s3 ls stderr:" >&2
        head -10 /tmp/k3s-snapshot-ls.err >&2
    fi
    if [ -n "$SNAPSHOT" ]; then
        echo "Restoring etcd from: $SNAPSHOT" >&2
        # --cluster-reset needs the apiserver ports to itself. If k3s is already running
        # (a re-run over a half-provisioned node, or FORCE_CREATE over a live one) the reset
        # dies instantly with
        #   level=fatal msg="Error: listen tcp 127.0.0.1:6444: bind: address already in use"
        # and, because the call is followed by || true, provisioning carried on as if the
        # restore had worked: rc=0, a green cluster, and none of the data. Measured
        # 2026-09-06 on ecc200 — the restore-probe ConfigMap was absent afterwards.
        # --cluster-reset needs the cluster token, and it must be the SAME token the snapshot
        # was encrypted with. config.yaml above pins it from general.k3sClusterToken, so write
        # it to the server dir rather than letting k3s mint a fresh one — starting k3s to
        # generate a token produces a DIFFERENT key and the reset then aborts with
        #   level=fatal msg="bootstrap data already found and encrypted with different token"
        # after having already restored and defragmented the etcd data. Measured 2026-09-06.
        mkdir -p /var/lib/rancher/k3s/server
        printf '%s' "${project_settings.general.k3sClusterToken}" > /var/lib/rancher/k3s/server/token
        chmod 600 /var/lib/rancher/k3s/server/token
        systemctl stop k3s 2>/dev/null || true
        sleep 5
        k3s server --cluster-reset --cluster-reset-restore-path="$SNAPSHOT" \
            --etcd-s3 \
            --etcd-s3-endpoint=${project_settings.storage.objectStorage.baseEndpoint} \
            --etcd-s3-access-key=${project_settings.storage.objectStorage.accessKey} \
            --etcd-s3-secret-key=${project_settings.storage.objectStorage.secretKey} \
            --etcd-s3-bucket=${etcdBucket.name} \
            --etcd-s3-folder=k3s-etcd 2>&1 | tee /tmp/k3s-cluster-reset.log | tail -10
        # VERIFY the reset actually happened. k3s exits 0 on some paths that did nothing, and
        # a silently-skipped restore is indistinguishable from a successful one afterwards.
        if grep -qiE 'level=fatal|address already in use' /tmp/k3s-cluster-reset.log; then
            echo "ERROR: etcd cluster-reset FAILED — refusing to continue with an unrestored cluster." >&2
            grep -iE 'level=fatal|address already in use' /tmp/k3s-cluster-reset.log | head -5 >&2
            exit 1
        fi
    else
        # WARNING: FAIL, do not fall back. make restore was ASKED to restore; coming up empty
        # cluster instead is the one outcome the operator cannot detect from a green cluster,
        # and it destroys the evidence (the next backup overwrites the state that would have
        # explained it). A bootstrap is one command away if a fresh cluster is what is wanted.
        echo "ERROR: targetState=restore but no S3 snapshot was found in s3://${etcdBucket.name}/k3s-etcd." >&2
        echo "       Refusing to start a FRESH cluster under a restore: that would look like" >&2
        echo "       success while silently discarding the data. Check the bucket and the" >&2
        echo "       objectStorage credentials, or run make bootstrap for a fresh cluster." >&2
        exit 1
    fi
fi

touch /var/lib/k3s-install-complete
echo "K3s install complete — waiting for Pulumi to start K3s" >&2
`;

        const initialCp = initialCpProvisioner.provisionControlPlane({
            node: initialCpNode,
            nodeName: initialCpName,
            userData: primaryCpUserData,
            parent: this,
        });
        this.controlPlane = initialCp.node;
        this.controlPlanePrivateIp = initialCp.privateIp;

        // A robot OS reinstall (nodes-k3s-hetzner-robot.ts Phase 1, keyed on
        // robotForceReinstall) WIPES the disk — k3s binary/config/state are gone. The init CP's
        // own IP does NOT change across a reinstall, so every downstream Command below that keys
        // ONLY on the init-CP IP would be skipped by Pulumi, leaving stale outputs: k3s is never
        // (re)started (systemctl enable --now lives in k3s-init-cp-join-or-init), and
        // get-kubeconfig/select-kubeconfig serve the PREVIOUS cluster's kubeconfig. ArgoCD then
        // dials a :6443 with nothing listening → "connection refused". Threading
        // robotForceReinstall into their triggers ties k3s-start + token + kubeconfig re-fetch to
        // every reinstall (it also re-fires on a fresh `make bootstrap`, which is correct — that
        // IS a from-scratch cluster). Harmless for a cloud/mesh init CP (value just rides along).
        const reinstallTrigger = runtime_flags.robotForceReinstall;

        // SSH target for orchestrating the init CP. Cloud/robot: root@ipv4 :22 via the agent
        // (default). Mesh: the provisioner supplies ssh{user,host,port}+key + sudo.
        //
        // ⚠ A MESH INIT CP IS NOT SUPPORTED HERE. The init-CP orchestration Commands below
        // SSH as a hardcoded `root@${ipv4}` on :22 via the local agent, which is true for
        // cloud and robot boxes and false for a mesh node (own user, own port, key held as a
        // Pulumi secret rather than in the agent, sudo rather than root).
        //
        // `initialCp.sshTarget` already carries the right values — MeshNodeInitProvisioner
        // populates it — so supporting one means rendering the ssh invocation from that target
        // across k3s-init-cp-join-or-init, wait-for-k3s-setup-init-cp-ready, get-k3s-token,
        // get-kubeconfig and select-kubeconfig, including materialising the key into a temp
        // file for the mesh case.
        //
        // Deliberately not done speculatively: this is the cluster-boot path for EVERY
        // cluster, it cannot be verified without actually booting one from a mesh node, and
        // helpers written ahead of that rot silently — three of them sat here unused and were
        // removed rather than kept as a half-finished API. ─────────────────────────────────

        /////////////////////
        // K3s initial-CP start: join an existing cluster or cluster-init.
        /////////////////////

        // Peer probe: if another control-plane is already up (a re-create where extra CPs
        // survived), the initial CP joins it instead of re-initing (avoids split-brain). The
        // peer is the first ADDITIONAL control-plane node (by its real id), not a magic "cp1".
        // Undefined for a single-CP cluster → no peer → the initial CP cluster-inits.
        const peerCp = extraCps[0];
        const peerDiscovery = initialCpProvisioner.discoverPeerCpIpScript(peerCp);

        const k3sInitCpJoinOrInit = new command.local.Command(
            "k3s-init-cp-join-or-init",
            {
                create: pulumi.all([initialCp.node.ipv4Address, peerDiscovery]).apply(
                    ([initIp, discoverPeerIp]) => `
            set -euo pipefail

            echo "Waiting for K3s install to complete on the initial CP (${initialCpName}, ${initIp})..." >&2
            INSTALL_DONE=false
            for i in $(seq 1 100); do
                if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    root@${initIp} 'test -f /var/lib/k3s-install-complete' 2>/dev/null; then
                    INSTALL_DONE=true
                    break
                fi
                sleep 5
            done
            if [ "$INSTALL_DONE" != "true" ]; then
                echo "ERROR: initial CP (${initialCpName}, ${initIp}) not reachable / install marker absent after ~500s." >&2
                echo "       Check SSH auth: the agent must hold the node key (sshkey-ecc-cloud)." >&2
                exit 1
            fi

            ${discoverPeerIp}

            JOIN_MODE=false
            if [ -n "$PEER_IP" ] && [ "${project_settings.general.targetState === "restore"}" != "true" ]; then
                if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$PEER_IP" \
                    'k3s kubectl get --raw="/readyz" 2>/dev/null | grep -q "^ok$"' 2>/dev/null; then
                    JOIN_MODE=true
                fi
            fi

            if $JOIN_MODE; then
                echo "Existing cluster found on peer CP ($PEER_IP) — reconfiguring the initial CP to join" >&2
                PEER_TOKEN=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$PEER_IP" \
                    'cat /var/lib/rancher/k3s/server/node-token')
                PEER_PRIVATE_IP=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 root@"$PEER_IP" \
                    "ip -4 addr show | awk '/inet.*10\\./{split(\$2,a,\"/\");print a[1];exit}'")
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initIp} \
                    "sed -i '/^cluster-init:/d' /etc/rancher/k3s/config.yaml && \
                     printf 'server: https://%s:${k3sApiPort}\\ntoken: %s\\n' '$PEER_PRIVATE_IP' '$PEER_TOKEN' \
                         >> /etc/rancher/k3s/config.yaml && \
                     systemctl enable --now k3s"
                echo "initial CP started in join mode" >&2
            else
                echo "No existing cluster (or restore mode) — starting the initial CP with cluster-init" >&2
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initIp} \
                    'systemctl enable --now k3s'
            fi
        `,
                ),
                triggers: [initialCp.node.ipv4Address, reinstallTrigger],
                interpreter: abortAfter(),
            },
            { parent: this, dependsOn: [initialCp.resource] },
        );

        // Control-plane nodes (cp0 + additional CPs) are always cloud — etcd quorum
        // members must not live on intermittently-connected mesh hardware.
        // longhornDiskCfgFor (imported) is the disk-tag builder; see nodes-k3s-common.ts.
        const longhornDiskCfg = longhornDiskCfgFor("cloud");
        const longhornAnnotateB64 = Buffer.from(
            [
                `k3s kubectl label node ${initialCpName} node.longhorn.io/create-default-disk=config --overwrite >/dev/null 2>&1 || true`,
                `k3s kubectl annotate node ${initialCpName} 'node.longhorn.io/default-disks-config=${longhornDiskCfg}' --overwrite >/dev/null 2>&1 || true`,
                // ecc/site = failure/latency domain. Mesh nodes get it in nodes-k3s-mesh.ts;
                // cloud/CP nodes must get it here too so ecc/site is present on EVERY node —
                // required for topologySpreadConstraints across ecc/site (e.g. spreading the
                // GitLab registry replicas one-per-site: cloud vs unibi-hclab).
                `k3s kubectl label node ${initialCpName} ${ECC.site}=${initialCpNode.site} --overwrite >/dev/null 2>&1 || true`,
                initialCpNode.kvm
                    ? `k3s kubectl label node ${initialCpName} ${ECC.kvm}=true --overwrite >/dev/null 2>&1 || true`
                    : "",
                descriptionAnnotateCmd(initialCpName, initialCpNode.description, "k3s kubectl"),
            ]
                .filter(Boolean)
                .join("\n"),
        ).toString("base64");

        const waitForInitCpSetupReady = new command.local.Command(
            "wait-for-k3s-setup-init-cp-ready",
            {
                create: pulumi.interpolate`for i in $(seq 1 560); do
        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} \
            'k3s kubectl get --raw="/readyz" 2>/dev/null | grep -q "^ok$" && [ -s /var/lib/rancher/k3s/server/node-token ]' 2>/dev/null; then
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} \
                'k3s kubectl label node ${initialCpName} node-role.kubernetes.io/control-plane=true --overwrite >/dev/null 2>&1 || true' 2>/dev/null || true
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} \
                'echo ${longhornAnnotateB64} | base64 -d | bash' 2>/dev/null || true
            echo "K3s setup is complete"
            exit 0
        fi
        echo "Waiting for K3s setup... ($i/560)" >&2
        sleep 1
    done
    echo "K3s setup failed to complete within ~560 seconds" >&2
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} \
        'systemctl status k3s --no-pager -l | tail -n 80; journalctl -u k3s --no-pager -n 120 | tail -n 120' 2>/dev/null || true
    exit 1`,
                triggers: [initialCp.node.ipv4Address, reinstallTrigger],
                interpreter: abortAfter(),
            },
            { parent: this, dependsOn: [k3sInitCpJoinOrInit] },
        );

        const getK3SToken = new command.local.Command(
            "get-k3s-token",
            {
                create: pulumi.interpolate`ssh -T -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} cat /var/lib/rancher/k3s/server/node-token`,
                triggers: [initialCp.node.ipv4Address, reinstallTrigger],
                interpreter: abortAfter(),
            },
            { parent: this, dependsOn: [waitForInitCpSetupReady] },
        );

        const getKubeconfig = new command.local.Command(
            "get-kubeconfig",
            {
                create: pulumi.interpolate`ssh -T -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://${initialCp.node.ipv4Address}:6443|g"`,
                triggers: [initialCp.node.ipv4Address, reinstallTrigger],
                interpreter: abortAfter(),
            },
            { parent: this, dependsOn: [getK3SToken] },
        );

        // On a full cluster teardown, PREFER the public (init-CP-IP) endpoint. The private
        // endpoint is the kube-vip VIP, reached over the admin WireGuard tunnel via the
        // in-cluster wireguard pod — which `pulumi destroy` deletes early, severing the
        // provider's API path mid-run and wedging the whole teardown. The box's own public
        // :6443 is a direct path that stays up until the node itself is deleted (last), so
        // it survives the wireguard/VIP teardown. Normal operation keeps private-first (the
        // VIP is the HA endpoint that survives init-CP loss). `make bootstrap` leaves 22/6443
        // open; `make production` closes them, but the destroy path reopens 6443 first
        // (destroyCluster.sh Step 0.5) so the public probe below succeeds there too.
        const teardown = project_settings.general.targetState === "destroy";
        // emit_stable: whatever endpoint the probe found reachable, the EMITTED kubeconfig
        // always points at the constant admin hostname (network.apiServerHost). The k8s
        // provider consumes this output — its content must NEVER change across posture
        // flips/teardown, or the provider is replaced and every k8s resource cascades into a
        // create-replacement ("already exists" storm — this is what a Bootstrap→Production
        // harden does if the endpoint moves). Which IP the name resolves to is a devcontainer
        // /etc/hosts
        // concern (scripts/runtime/setKubeApiHost.sh): public IP during create/teardown/
        // breakglass, VIP once the admin WG tunnel is up (wgAdminUp.sh).
        const emitStable = (kcVar: string) =>
            `sed "s|server: https://[^ ]*$|server: https://${project_settings.network.apiServerHost}:${k3sApiPort}|" "${kcVar}"`;
        const probePrivate = `    if kubectl --kubeconfig="$PRIVATE_KC" get --raw='/readyz' >/dev/null 2>&1; then
        ${emitStable("$PRIVATE_KC")}
        exit 0
    fi`;
        const probePublic = `    if kubectl --kubeconfig="$PUBLIC_KC" get --raw='/readyz' >/dev/null 2>&1; then
        ${emitStable("$PUBLIC_KC")}
        exit 0
    fi`;
        const probeOrder = teardown
            ? `${probePublic}\n${probePrivate}`
            : `${probePrivate}\n${probePublic}`;

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

SSH_PRIVATE_KC=$(ssh -T -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${initialCp.node.ipv4Address} cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://${this.controlPlanePrivateIp}:6443|g")
printf '%s\n' "$SSH_PRIVATE_KC" > "$PRIVATE_KC"

for i in $(seq 1 110); do
${probeOrder}
    echo "Waiting for a reachable K3s API endpoint... (attempt $i/110)" >&2
    sleep 5
done
echo "No reachable K3s API endpoint found in time" >&2
exit 1`,
                // targetState MUST be a trigger, for two reasons that used to be two separate
                // flags. A "destroy" flips the endpoint preference above, so without it this
                // Command doesn't re-run on destroy and the provider keeps the stale private
                // (VIP-over-WG) kubeconfig that the teardown severs. And hardening to
                // "production" firewalls the box's PUBLIC IP:6443 shut — if this probe last
                // picked the public endpoint (as it does during bring-up, before the private
                // path is up), the cached kubeconfigRaw would point at a severed endpoint and
                // mesh-fetch's kubectl times out ~20 min. Re-probing on either transition
                // re-selects a reachable (private-first) endpoint.
                triggers: [
                    initialCp.node.ipv4Address,
                    project_settings.general.targetState,
                    reinstallTrigger,
                ],
                interpreter: abortAfter(),
            },
            { parent: this, dependsOn: [getKubeconfig] },
        );

        this.kubeconfigRaw = selectKubeconfig.stdout;

        /////////////////////
        // Additional Control Planes — sequential (etcd allows one learner at a time)
        /////////////////////

        this.additionalCpNodes = [];
        let cpJoinBarrier: pulumi.Resource = waitForInitCpSetupReady;

        for (const node of extraCps) {
            const provisioner = this.provisionerFor(node);
            const nodeName = `${clusterName}-${node.id}`;
            const userData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${provisioner.privateNetworkSetupScript(node)}
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
${swapSetupScript(node.swap, node.swapBehavior)}
${longhornPrereqScript}

PUBLIC_IP=$(ip -o -4 addr show | awk '$4 !~ /^10\\./ && $4 !~ /^127\\./ {split($4,a,"/"); print a[1]; exit}')
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG_JOIN
node-name: ${nodeName}
server: https://${this.controlPlanePrivateIp}:${k3sApiPort}
token: ${getK3SToken.stdout}
advertise-address: \$PRIVATE_IP
node-ip: \$PRIVATE_IP
tls-san:
  - \$PUBLIC_IP
  - \$PRIVATE_IP
  - ${project_settings.network.vip}
  - ${project_settings.network.apiServerHost}
disable:
${project_settings.general.loadBalancerProvider === "hetzner-ccm" ? "  - servicelb" : ""}
  - traefik
${k3sCniServerConfig}
${k3sServerCloudProviderConfig}${swapKubeletArg(node.swap)}
KCONFIG_JOIN
chmod 600 /etc/rancher/k3s/config.yaml

# No flannel-conf.json / flannel-iface: Cilium owns the pod network (src/cni.ts). cluster-cidr
# and service-cidr above MUST match cp0 exactly — k3s stores them in etcd at cluster-init and a
# follower that disagrees about service-cidr will not converge. See the cp0 block for the MTU
# rationale — that constraint lives in Cilium's MTU value.

# Idempotent install — see the cp0 block: skip the flaky get.k3s.io/update.k3s.io fetch
# when the binary is already present (a config-delta re-provision must not re-download).
if command -v k3s >/dev/null 2>&1; then
    echo "k3s already installed — skipping installer download." >&2
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${project_settings.general.k3sVersion} INSTALL_K3S_SKIP_START=true sh -
fi
systemctl enable --now k3s
echo "K3s additional control plane (${nodeName}) setup complete"
`;
            const cp = provisioner.provisionControlPlane({
                node,
                nodeName,
                userData,
                parent: this,
                dependsOn: [cpJoinBarrier, waitForInitCpSetupReady, getK3SToken],
            });

            const cpDescAnnotate = descriptionAnnotateCmd(
                nodeName,
                node.description,
                `kubectl --kubeconfig="$TMPKC"`,
            );
            const cpKvmLabel = node.kvm
                ? `kubectl --kubeconfig="$TMPKC" label node ${nodeName} ${ECC.kvm}=true --overwrite >/dev/null 2>&1 || true`
                : "";
            // ecc/site on every node (see init-CP comment) — enables topologySpread across sites.
            const cpSiteLabel = `kubectl --kubeconfig="$TMPKC" label node ${nodeName} ${ECC.site}=${node.site} --overwrite >/dev/null 2>&1 || true`;
            const waitForCpJoin = new command.local.Command(
                `wait-for-k3s-join-${node.id}`,
                {
                    create: pulumi.interpolate`
                TMPKC=$(mktemp)
                cat > "$TMPKC" << 'KUBECFG'
${this.kubeconfigRaw}
KUBECFG
                trap 'rm -f "$TMPKC"' EXIT
                for i in $(seq 1 110); do
                    if ! kubectl --kubeconfig="$TMPKC" get --raw='/readyz' >/dev/null 2>&1; then
                        echo "Waiting for ${nodeName}... (attempt $i/110) | apiserver unavailable"
                        sleep 5
                        continue
                    fi
                    READY=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
                    if [ "$READY" = "True" ]; then
                        kubectl --kubeconfig="$TMPKC" label node ${nodeName} node-role.kubernetes.io/control-plane=true --overwrite >/dev/null 2>&1 || true
                        kubectl --kubeconfig="$TMPKC" label node ${nodeName} node.longhorn.io/create-default-disk=config --overwrite >/dev/null 2>&1 || true
                        kubectl --kubeconfig="$TMPKC" annotate node ${nodeName} 'node.longhorn.io/default-disks-config=${longhornDiskCfg}' --overwrite >/dev/null 2>&1 || true
                        ${cpKvmLabel}
                        ${cpSiteLabel}
                        ${cpDescAnnotate}
                        echo "${nodeName} is Ready"
                        exit 0
                    fi
                    STATUS_LINE=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} --no-headers 2>/dev/null || true)
                    if [ -n "$STATUS_LINE" ]; then
                        echo "Waiting for ${nodeName}... (attempt $i/110) | $STATUS_LINE"
                    else
                        echo "Waiting for ${nodeName}... (attempt $i/110) | node not registered yet"
                    fi
                    sleep 5
                done
                echo "${nodeName} not ready within ~9 minutes" >&2
                kubectl --kubeconfig="$TMPKC" get nodes -o wide || true
                kubectl --kubeconfig="$TMPKC" describe node ${nodeName} || true
                echo "--- SSH debug on ${nodeName} (${cp.node.ipv4Address}) ---" >&2
                ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${cp.node.ipv4Address} \
                  'hostname; date; ip -brief a; systemctl is-active k3s || true; systemctl status k3s --no-pager -l | tail -n 80; journalctl -u k3s --no-pager -n 120 | tail -n 120' || true
                exit 1
                `,
                    triggers: [cp.node.ipv4Address],
                    interpreter: abortAfter(),
                },
                {
                    parent: this,
                    dependsOn: [cp.resource, waitForInitCpSetupReady, getK3SToken, getKubeconfig],
                },
            );

            this.additionalCpNodes.push(cp.node);
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

        this.cloudWorkers = workers.flatMap((node) => {
            const provisioner = this.provisionerFor(node);
            const nodeName = `${clusterName}-${node.id}`;
            const workerDiskCfg = longhornDiskCfgFor("cloud"); // Hetzner-hosted nodes always back cloud disks
            const workerUserData = pulumi.interpolate`#!/usr/bin/env bash
set -euo pipefail
${provisioner.privateNetworkSetupScript(node)}
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
${swapSetupScript(node.swap, node.swapBehavior)}
${longhornPrereqScript}
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << KCONFIG_WORKER
node-ip: \$PRIVATE_IP
${k3sWorkerCloudProviderConfig}${swapKubeletArg(node.swap)}
node-label:
  - 'node.longhorn.io/create-default-disk=config'
KCONFIG_WORKER
chmod 600 /etc/rancher/k3s/config.yaml

# No CNI keys here on purpose: flannel-backend/disable-network-policy/cluster-cidr/service-cidr
# are SERVER-only. The agent inherits the pod network from the cluster, and Cilium's DaemonSet
# configures the datapath on this node once it joins (src/cni.ts). Passing a server-only key
# here makes the agent refuse to start ("flag provided but not defined").

# Idempotent install — see the cp0 block: skip the flaky get.k3s.io/update.k3s.io fetch
# when the binary is already present (a config-delta re-provision must not re-download).
if command -v k3s >/dev/null 2>&1; then
    echo "k3s already installed — skipping installer download." >&2
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${project_settings.general.k3sVersion} K3S_URL=https://${this.controlPlanePrivateIp}:${k3sApiPort} K3S_TOKEN=${getK3SToken.stdout} sh -
fi
echo "K3s worker setup complete"
`;
            // NB: the Longhorn disk-config node-annotation is applied post-join via
            // kubectl below — the k3s *agent* binary rejects a `node-annotation:` config
            // key ("flag provided but not defined: -node-annotation"); only the server
            // accepts it. node-label is fine on the agent.
            const worker = provisioner.provisionWorker({
                node,
                nodeName,
                userData: workerUserData,
                parent: this,
                dependsOn: [cpJoinBarrier],
            });

            const workerDescAnnotate = descriptionAnnotateCmd(
                nodeName,
                node.description,
                `kubectl --kubeconfig="$TMPKC"`,
            );
            const workerKvmLabel = node.kvm
                ? `kubectl --kubeconfig="$TMPKC" label node ${nodeName} ${ECC.kvm}=true --overwrite >/dev/null 2>&1 || true`
                : "";
            // ecc/site on every node (see init-CP comment) — enables topologySpread across sites.
            const workerSiteLabel = `kubectl --kubeconfig="$TMPKC" label node ${nodeName} ${ECC.site}=${node.site} --overwrite >/dev/null 2>&1 || true`;
            // Wait for the worker to register Ready, then apply the Longhorn disk-config
            // annotation (agents can't set node-annotation in config.yaml; see above).
            new command.local.Command(
                `wait-for-k3s-join-${node.id}`,
                {
                    create: pulumi.interpolate`
                TMPKC=$(mktemp)
                cat > "$TMPKC" << 'KUBECFG'
${this.kubeconfigRaw}
KUBECFG
                trap 'rm -f "$TMPKC"' EXIT
                for i in $(seq 1 110); do
                    if ! kubectl --kubeconfig="$TMPKC" get --raw='/readyz' >/dev/null 2>&1; then
                        echo "Waiting for ${nodeName}... (attempt $i/110) | apiserver unavailable"
                        sleep 5
                        continue
                    fi
                    READY=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
                    if [ "$READY" = "True" ]; then
                        kubectl --kubeconfig="$TMPKC" label node ${nodeName} node.longhorn.io/create-default-disk=config --overwrite >/dev/null 2>&1 || true
                        kubectl --kubeconfig="$TMPKC" annotate node ${nodeName} 'node.longhorn.io/default-disks-config=${workerDiskCfg}' --overwrite >/dev/null 2>&1 || true
                        ${workerKvmLabel}
                        ${workerSiteLabel}
                        ${workerDescAnnotate}
                        echo "${nodeName} is Ready"
                        exit 0
                    fi
                    STATUS_LINE=$(kubectl --kubeconfig="$TMPKC" get node ${nodeName} --no-headers 2>/dev/null || true)
                    if [ -n "$STATUS_LINE" ]; then
                        echo "Waiting for ${nodeName}... (attempt $i/110) | $STATUS_LINE"
                    else
                        echo "Waiting for ${nodeName}... (attempt $i/110) | node not registered yet"
                    fi
                    sleep 5
                done
                echo "${nodeName} not ready within ~9 minutes" >&2
                kubectl --kubeconfig="$TMPKC" get nodes -o wide || true
                kubectl --kubeconfig="$TMPKC" describe node ${nodeName} || true
                echo "--- SSH debug on ${nodeName} (${worker.node.ipv4Address}) ---" >&2
                ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${worker.node.ipv4Address} \
                  'hostname; date; ip -brief a; systemctl is-active k3s-agent || true; systemctl status k3s-agent --no-pager -l | tail -n 80; journalctl -u k3s-agent --no-pager -n 120 | tail -n 120' || true
                exit 1
                `,
                    interpreter: abortAfter(),
                },
                { parent: this, dependsOn: [worker.resource] },
            );

            return [worker.node];
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
