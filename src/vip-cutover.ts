/**
 * Project: edgecloudinfra
 * File: vip-cutover.ts
 * Purpose: Post-bootstrap "VIP cutover" — once ArgoCD has brought up kube-vip and the
 *          routed k3s API VIP (network.vip) is live, repoint every node's k3s `server:`
 *          endpoint, the WireGuard route gateway, and the exported kubeconfig FROM the
 *          init-CP's private IP TO the VIP. After this, the init CP is no longer special:
 *          losing it does not strand the API endpoint (the k3s agent client-LB already
 *          fails over across live CPs at runtime; this makes the PERSISTED endpoint the VIP
 *          so a later `pulumi up`, the kubeconfig, and WG routing all survive init-CP loss).
 *
 *          Ordering (why this is a separate, post-ArgoCD step): nodes are provisioned in
 *          K3sNodesComponent FIRST and must join via the init-CP IP — the VIP does not exist
 *          until ArgoCD (much later) syncs the wave-0 kube-vip DaemonSet. Gating joins on the
 *          VIP would deadlock (VIP ⇐ kube-vip ⇐ ArgoCD ⇐ cluster-up ⇐ joins). So we join via
 *          the init CP, then cut over here with `dependsOn: [argocd]` + an ACTIVE VIP health
 *          gate (poll https://VIP:6443/healthz) before touching anything.
 *
 *          Single-CP / lone-dedicated: the VIP resolves to that one CP's own IP, so the
 *          cutover is a harmless no-op-equivalent (server already effectively the VIP).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import type { ClusterNode } from "./nodes-k3s-types";

const k3sApiPort = project_settings.network.k3sApiPort;
const vip = project_settings.network.vip;
const vpnSubnet = project_settings.wireguard.vpnSubnet;

export interface VipCutoverArgs {
    // Init CP (used as the SSH host for the VIP health gate + kubeconfig re-export).
    initCp: ClusterNode;
    // Follower nodes whose `server:` endpoint + WG route get repointed to the VIP.
    // (The init CP is itself a server/etcd member — it has no `server:` join line — so it
    // is NOT in this list.)
    followers: ClusterNode[];
    // Raw kubeconfig (init-CP-IP form) to rewrite to the VIP for export.
    kubeconfigRaw: pulumi.Output<string>;
}

export class VipCutoverComponent extends pulumi.ComponentResource {
    // Kubeconfig pointing at the VIP (HA endpoint). Falls back to the input unchanged if
    // the VIP never came up (the rewrite step degrades gracefully).
    public readonly kubeconfigViaVip: pulumi.Output<string>;

    constructor(name: string, args: VipCutoverArgs, opts?: pulumi.ComponentResourceOptions) {
        super("ecc:infra:VipCutover", name, {}, opts);

        // ── 1. Active gate: wait until the VIP actually answers ──────────────────────────
        // SSH the init CP and poll https://VIP:6443/healthz. kube-vip (ArgoCD wave 0) must
        // hold the VIP before we repoint anything at it. Tolerant: warns + continues after
        // the timeout so a VIP that never comes up (e.g. misconfig) does not wedge the whole
        // deploy — the followers simply keep their init-CP `server:` (still HA via client-LB).
        const waitForVip = new command.local.Command(
            `${name}-wait-for-vip`,
            {
                create: pulumi.interpolate`set -uo pipefail
HOST=${args.initCp.ipv4Address}
echo "vip-cutover: waiting for the k3s API VIP ${vip}:${k3sApiPort} to be live (via $HOST)…" >&2
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        root@"$HOST" "curl -sk --max-time 4 https://${vip}:${k3sApiPort}/healthz -o /dev/null -w '%{http_code}'" 2>/dev/null \
        | grep -qE '^(200|401|403)$'; then
        echo "vip-cutover: VIP ${vip} is live (attempt $i)." >&2
        echo "ready"; exit 0
    fi
    echo "vip-cutover: VIP not live yet ($i/60)…" >&2
    sleep 5
done
echo "vip-cutover: WARNING — VIP ${vip} not live after ~5 min; continuing (followers keep init-CP server)." >&2
echo "timeout"`,
                triggers: [args.initCp.ipv4Address, vip],
            },
            { parent: this, dependsOn: opts?.dependsOn },
        );

        // ── 2. Repoint each follower's `server:` + WG route to the VIP ───────────────────
        // Idempotent: only rewrites when the VIP gate reported "ready"; sed targets the
        // existing `server:` line (any host) → the VIP, fixes the WG route, restarts k3s.
        const repointDeps: pulumi.Resource[] = [waitForVip];
        args.followers.forEach((node, idx) => {
            const repoint = new command.local.Command(
                `${name}-repoint-${idx}`,
                {
                    create: pulumi.interpolate`set -uo pipefail
if [ "${waitForVip.stdout}" != "ready" ]; then
    echo "vip-cutover: VIP not live — skipping repoint of ${node.ipv4Address}." >&2
    exit 0
fi
HOST=${node.ipv4Address}
echo "vip-cutover: repointing ${node.name} ($HOST) server:/WG → VIP ${vip}…" >&2
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$HOST" '
set -e
CFG=/etc/rancher/k3s/config.yaml
if grep -q "^server:" "$CFG"; then
    sed -i "s|^server: https://.*:${k3sApiPort}|server: https://${vip}:${k3sApiPort}|" "$CFG"
fi
# WireGuard route gateway → VIP (best-effort; both the live route and the persisted unit).
ip route replace ${vpnSubnet} via ${vip} 2>/dev/null || true
if [ -f /etc/systemd/network/10-wireguard-route.network ]; then
    sed -i "s|^Gateway=.*|Gateway=${vip}|" /etc/systemd/network/10-wireguard-route.network || true
fi
# Restart whichever k3s unit is active (CP followers run k3s; workers run k3s-agent) so it
# re-seeds its client-LB from the new server URL. A CP restart briefly drops one CP; the
# others (incl. the init CP) keep serving the API throughout.
if systemctl is-active --quiet k3s; then systemctl restart k3s
elif systemctl is-active --quiet k3s-agent; then systemctl restart k3s-agent; fi
echo "  repointed."
' 2>&1 | sed "s/^/  /" >&2 || echo "vip-cutover: WARNING repoint of $HOST failed (continuing)." >&2`,
                    triggers: [node.ipv4Address, vip],
                },
                { parent: this, dependsOn: [waitForVip] },
            );
            repointDeps.push(repoint);
        });

        // ── 3. Kubeconfig pointing at the VIP ────────────────────────────────────────────
        // Rewrite the init-CP-IP server URL in the kubeconfig to the VIP when the VIP came up
        // (else leave it unchanged — still valid via the init CP). Pure transform via apply so
        // it cannot fail the deploy. repointDeps is referenced so this resolves conceptually
        // after the node repoints (the value itself only depends on the gate + raw kubeconfig).
        void repointDeps;
        this.kubeconfigViaVip = pulumi
            .all([waitForVip.stdout, args.kubeconfigRaw])
            .apply(([vipState, kc]) =>
                vipState === "ready"
                    ? kc.replace(
                          new RegExp(`https://[0-9.]+:${k3sApiPort}`, "g"),
                          `https://${vip}:${k3sApiPort}`,
                      )
                    : kc,
            );

        this.registerOutputs({ kubeconfigViaVip: this.kubeconfigViaVip });
    }
}
