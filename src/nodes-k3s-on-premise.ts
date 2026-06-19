/**
 * Project: edgecloudinfra
 * File: nodes-k3s-on-premise.ts
 * Purpose: Provision pre-existing on-premise edge nodes (SSH) into the k3s cluster.
 *
 * Edge nodes are NOT created by Pulumi (the OS is already installed); they are
 * configured in-place over SSH via command.remote.Command: install Tailscale, join
 * the headscale mesh, install the k3s agent. The join logic is the shared set of
 * scripts under scripts/edge-provisioning/ (single source of truth, also used by
 * scripts/runtime/generateEdgeJoinScript.sh).
 *
 * This component is instantiated only when edgeProvisioning.enabled is true (set by
 * `make provision-edge`), run as a SECOND pass after the cloud cluster + VPN/mesh are
 * up — never during `make create` (the mesh isn't ready until ~15 min after pulumi).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as fs from "fs";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import { project_settings, EdgeNode } from "../project_settings";

const EDGE_DIR = path.join(__dirname, "..", "scripts", "edge-provisioning");
const readTpl = (f: string) => fs.readFileSync(path.join(EDGE_DIR, f), "utf8");
// base64 so scripts (with quotes/newlines/secrets) inline safely into the remote
// command — the edge sshd doesn't allow SSH setenv (AcceptEnv), so env vars fail.
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

export interface OnPremiseNodesArgs {
    kubeconfigRaw: pulumi.Output<string>;
    controlPlaneSshHost: pulumi.Output<string>; // CP0 public IP — for token + TLS-SAN
}

export class OnPremiseNodesComponent extends pulumi.ComponentResource {
    constructor(name: string, args: OnPremiseNodesArgs, opts?: pulumi.ComponentResourceOptions) {
        super("ecc:infra:OnPremiseNodes", name, {}, opts);

        const sshKey = project_settings.edgeProvisioning.sshPrivateKey;
        if (!sshKey) {
            throw new pulumi.RunError(
                "edgeProvisioning.enabled is true but the Pulumi secret 'edgeSshPrivateKey' is not set " +
                    '(pulumi config set --secret edgeSshPrivateKey "$(cat <key>)").',
            );
        }

        const filter = project_settings.edgeProvisioning.filter;
        const nodes = (project_settings.nodes.edge as EdgeNode[]).filter(
            (n) => filter === "all" || n.id === filter,
        );
        if (nodes.length === 0) {
            throw new pulumi.RunError(
                `No edge node matches edgeProvisionFilter='${filter}' in project_settings.nodes.edge.`,
            );
        }

        const headscaleUrl = `https://vpn.${project_settings.dns.tld}`;
        const cleanupTpl = readTpl("cleanupNode.sh"); // no placeholders
        const prereqTpl = readTpl("10-install-prereqs.sh"); // no placeholders
        const vpnTpl = readTpl("20-connect-vpn.sh");
        const joinTpl = readTpl("30-join-cluster.sh");
        const fetchScript = readTpl("00-fetch-cluster-inputs.sh");
        // Longhorn edge disk: tag "edge" so the longhorn-edge StorageClass selects it.
        const edgeDiskCfg = JSON.stringify([
            { path: "/var/lib/longhorn", allowScheduling: true, tags: ["edge"] },
        ]);

        for (const node of nodes) {
            // 1. Fetch dynamic inputs from the live cluster (mint key, route approve,
            //    token, CP VPN IP, k3s version, headscale CA). Emits KEY=VALUE on stdout.
            const fetch = new command.local.Command(
                `edge-fetch-${node.id}`,
                {
                    create: pulumi.interpolate`
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
export CP0_SSH_HOST="${args.controlPlaneSshHost}"
export HEADSCALE_URL="${headscaleUrl}"
export EDGE_TIER="on-premise-resident"
bash scripts/edge-provisioning/00-fetch-cluster-inputs.sh`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    triggers: [args.controlPlaneSshHost, fetchScript],
                },
                { parent: this },
            );

            // Parse the KEY=VALUE stdout into individual Outputs.
            const v = (key: string) =>
                fetch.stdout.apply((out) => {
                    const line = out.split("\n").find((l) => l.startsWith(`${key}=`));
                    return line ? line.slice(key.length + 1) : "";
                });
            const tsAuthkey = v("EDGE_TS_AUTHKEY");
            const cp0VpnIp = v("EDGE_CP0_VPN_IP");
            const k3sToken = v("EDGE_K3S_TOKEN");
            const k3sVersion = v("EDGE_K3S_VERSION");
            const caB64 = v("EDGE_HEADSCALE_CA_B64");

            // 2. Build the final (placeholder-substituted) scripts in TS — avoids
            //    fragile remote sed over secret values; pass them via env.
            const vpnFinal = pulumi.all([tsAuthkey, caB64]).apply(([key, ca]) =>
                vpnTpl
                    .replace(/HEADSCALE_URL_PLACEHOLDER/g, headscaleUrl)
                    .replace(/TS_AUTHKEY_PLACEHOLDER/g, key)
                    .replace(/HEADSCALE_CA_B64_PLACEHOLDER/g, ca),
            );
            const joinFinal = pulumi
                .all([cp0VpnIp, k3sToken, k3sVersion])
                .apply(([ip, token, ver]) =>
                    joinTpl
                        .replace(/CP0_VPN_IP_PLACEHOLDER/g, ip)
                        .replace(/K3S_TOKEN_PLACEHOLDER/g, token)
                        .replace(/K3S_VERSION_PLACEHOLDER/g, ver),
                );

            // 3. Provision the edge box over SSH (idempotent: --force re-joins).
            // Scripts are base64-inlined into the command (NOT SSH env vars: the edge
            // sshd rejects setenv). base64 is shell-safe (A–Za–z0–9+/=).
            const provision = new command.remote.Command(
                `edge-provision-${node.id}`,
                {
                    connection: {
                        host: node.sshHost,
                        port: node.sshPort,
                        user: node.sshUser,
                        privateKey: sshKey,
                    },
                    create: pulumi.interpolate`set -e
umask 077
echo ${b64(cleanupTpl)} | base64 -d > /tmp/edge-00.sh && sudo bash /tmp/edge-00.sh
echo ${b64(prereqTpl)} | base64 -d > /tmp/edge-10.sh && sudo bash /tmp/edge-10.sh
echo ${vpnFinal.apply(b64)} | base64 -d > /tmp/edge-20.sh && sudo bash /tmp/edge-20.sh
echo ${joinFinal.apply(b64)} | base64 -d > /tmp/edge-30.sh && sudo bash /tmp/edge-30.sh --node-name=${node.id} --force
rm -f /tmp/edge-00.sh /tmp/edge-10.sh /tmp/edge-20.sh /tmp/edge-30.sh`,
                    // Re-run when the (substituted) scripts change — vpnFinal/joinFinal
                    // embed the key/token/IP, so this also covers fetch-output changes.
                    triggers: [
                        cleanupTpl,
                        prereqTpl,
                        vpnFinal,
                        joinFinal,
                        node.sshHost,
                        String(node.sshPort),
                    ],
                },
                { parent: this, dependsOn: [fetch] },
            );

            // 4. Post-join: wait for the node to register, then apply edge labels +
            //    the Longhorn "edge" disk tag (so longhorn-edge + windows scheduling work).
            const labels: string[] = [
                // node-role.* must be set via kubectl (kubelet may not self-assign it);
                // shows as ROLE "edge" in `kubectl get nodes`.
                "node-role.kubernetes.io/edge=edge",
                "node.kubernetes.io/edge-worker=true",
                ...(node.location ? [`ecc/location=${node.location}`] : []),
                ...(node.hardware ? [`ecc/hardware=${node.hardware}`] : []),
                ...(node.kvm ? ["ecc/kvm=true"] : []),
            ];
            new command.local.Command(
                `edge-label-${node.id}`,
                {
                    create: pulumi.interpolate`
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
echo "Waiting for node ${node.id} to register..."
for i in $(seq 1 60); do
  kubectl get node ${node.id} >/dev/null 2>&1 && break
  sleep 5
done
kubectl get node ${node.id} >/dev/null 2>&1 || { echo "ERROR: node ${node.id} never registered" >&2; exit 1; }
kubectl label node ${node.id} ${labels.join(" ")} --overwrite
kubectl label node ${node.id} node.longhorn.io/create-default-disk=config --overwrite
kubectl annotate node ${node.id} 'node.longhorn.io/default-disks-config=${edgeDiskCfg}' --overwrite
echo "Edge node ${node.id} labeled (edge Longhorn disk + ecc/*)."`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    triggers: [provision.stdout],
                },
                { parent: this, dependsOn: [provision] },
            );
        }

        this.registerOutputs({});
    }
}
