/**
 * Project: edgecloudinfra
 * File: network.ts
 * Purpose: Network component for Pulumi infra — hcloud private network, subnets, firewall,
 *          and (when the cluster includes Hetzner Robot/dedicated nodes) the Robot vSwitch
 *          that bridges those boxes onto the private network plus the Robot firewall that
 *          mirrors the hcloud firewall rules onto those (non-hcloud-API) dedicated boxes.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import type { ComputeNodeCloudDedicated } from "../project_settings_types";

export class NetworkComponent extends pulumi.ComponentResource {
    public readonly network: hcloud.Network;
    public readonly subnet: hcloud.NetworkSubnet;
    public readonly vswitchSubnet?: hcloud.NetworkSubnet;
    public readonly vipRoute?: hcloud.NetworkRoute;
    public readonly firewall: hcloud.Firewall;

    constructor(
        name: string,
        hProvider: hcloud.Provider,
        projectSettings: typeof project_settings,
        opts?: pulumi.ComponentResourceOptions,
        // Import IDs for resources that survived a prior incomplete destroy (resolved in
        // main.ts via the hcloud API). When set, Pulumi adopts the existing resource
        // instead of erroring on "name/id already used". Undefined on a fresh create.
        imports?: { networkId?: string; serverSubnetId?: string; vswitchSubnetId?: string },
    ) {
        super("ecc:infra:Network", name, {}, opts);

        // Robot (dedicated) nodes need a vSwitch bridged into this network. exposeRoutesToVswitch
        // is required for routes to propagate to the vSwitch; harmless when there are none.
        // enabled:false parks a node → it is never built, so it gets no vSwitch bridge.
        const robotNodes = projectSettings.nodes.cloud.filter(
            (n) => n.provider === "robot" && n.enabled !== false,
        ) as ComputeNodeCloudDedicated[];

        // Effective firewall rule set (single source of truth in project_settings.network.firewall).
        // Bootstrap adds SSH/k3s-API/etcd on top of the always-on production rules; Production
        // drops them so the admin WireGuard tunnel is the only way in.
        //
        // Consumed by the hcloud Cloud firewall (below) AND rendered into the host nftables
        // allow-list on every public node (publicGuardScript, src/nodes-k3s-common.ts). The Robot
        // firewall canNOT express this set — its input chain caps at 10 rules and every rule needs
        // an explicit ip_version, so the allow-list would need 12 (see robotFirewallEnsureScript).
        const { bringUpRules, alwaysRules } = projectSettings.network.firewall;
        const effectiveFirewallRules =
            projectSettings.general.targetState === "production"
                ? [...alwaysRules]
                : [...bringUpRules, ...alwaysRules];

        // hcloud private-network name = "<cluster>-<site-of-direct-node>". The L2 segment
        // a "direct" cloud/robot node sits on IS this Hetzner private network, so its site
        // (e.g. "hetzner-fsn1") names it — qualified by the cluster name so it's unique per
        // deployment (a bare "private-network" collides with a leftover from a prior cluster). Falls
        // back to "<cluster>-net" when no direct node exists (e.g. a mesh-init cluster with only vpn
        // cloud followers, which still need the hcloud net but define no direct site here).
        const directNode = projectSettings.nodes.cloud.find(
            (n) => n.clusterLink === "direct" && n.enabled !== false,
        );
        const networkName = directNode
            ? `${projectSettings.general.name}-${directNode.site}`
            : `${projectSettings.general.name}-net`;

        this.network = new hcloud.Network(
            `${projectSettings.general.name}-net`,
            {
                name: networkName,
                ipRange: projectSettings.network.privateRange,
                exposeRoutesToVswitch: true,
                labels: { cluster: projectSettings.general.name },
            },
            { provider: hProvider, parent: this, import: imports?.networkId },
        );

        // Cloud-VM subnet ("server" type). Narrower than network.subnetRange (the umbrella the
        // mesh advertises) so it doesn't overlap the vswitch subnet below.
        this.subnet = new hcloud.NetworkSubnet(
            `${projectSettings.general.name}-subnet`,
            {
                networkId: this.network.id.apply((id) => Number(id)),
                type: "server",
                networkZone: "eu-central",
                ipRange: projectSettings.network.serverSubnetRange,
            },
            { provider: hProvider, parent: this, import: imports?.serverSubnetId },
        );

        // ── kube-vip routed VIP → cloud-CP gateway ───────────────────────────────────────
        // The k3s API VIP (network.vip) is a /32 OUTSIDE both subnets, so it needs an explicit
        // Hetzner network route to be reachable. kube-vip ARP-announces it on the holder's
        // segment, but Hetzner only delivers a network-route gateway on the cloud SERVER subnet
        // (it will not route a gateway onto the robot vSwitch L2) — so the gateway, and thus the
        // VIP holder, is a cloud server-subnet CP. The kube-vip DaemonSet agrees, with one
        // documented exception: when a cloud server-subnet CP EXISTS only those nodes may hold
        // the VIP (a robot/vSwitch holder would black-hole it cross-segment, and robot/mesh CPs
        // fall back to the mesh endpoint); when NONE exists, the lone dedicated CP holds the
        // VIP on its own segment, where there is no cross-segment problem to solve. That second
        // branch is what runs today. With a cloud CP present, the route makes the VIP reachable
        // from BOTH the cloud and the robot vSwitch segments.
        // See doc/kube-vip-cross-segment.md.
        //
        // Gateway = the "direct" cloud CP's private IP (the server-subnet control plane).
        //
        // ⚠ NO ROUTE IS CREATED IN THE CURRENT TOPOLOGY, and that is correct. `directCloudCp`
        // needs an ENABLED hcloud node with clusterLink:"direct"; today every hcloud node is
        // enabled:false and the only control plane is the robot box, so `vipGateway` is
        // undefined and this block is skipped. Nothing needs the route: the VIP is announced
        // by kube-vip on the robot CP's own vSwitch segment (the DaemonSet's lone-dedicated-CP
        // branch), and every consumer arrives over the admin WireGuard tunnel or over
        // tailscale, not through the Hetzner private network. The route becomes load-bearing
        // again the moment a cloud CP is enabled — which is also when the VIP moves to the
        // cloud segment.
        //
        // With a single cloud CP the route is static; with ≥2 cloud CPs it must follow the
        // kube-vip leader (TODO: route-follows-leader controller — deferred until
        // multi-cloud-CP; see plans/prompts/code-issues.md item 1).
        const directCloudCp = projectSettings.nodes.cloud.find(
            (n) => n.clusterLink === "direct" && n.provider === "hcloud" && n.enabled !== false,
        );
        const vipGateway = directCloudCp?.privateIp;

        // ⚠ THE DANGEROUS STATE IS NOT "no route" — it is "a cloud CP exists AND no route".
        // kube-vip moves the VIP to the cloud server subnet as soon as one appears (its
        // eligibility check), and without the route nothing on the robot vSwitch segment can
        // reach it there: the API VIP silently stops answering for everything that is not on
        // the cloud segment. Catch it at PREVIEW time rather than after the apply, because by
        // then the thing that reports the failure is the cluster's own API endpoint.
        const enabledCloudServerCp = projectSettings.nodes.cloud.find(
            (n) =>
                n.enabled !== false &&
                n.provider === "hcloud" &&
                n.k8sRole !== "worker" &&
                (n.privateIp ?? "").startsWith("10.0.0."),
        );
        if (enabledCloudServerCp && !vipGateway) {
            throw new Error(
                `network: '${enabledCloudServerCp.id}' is an enabled hcloud control plane on ` +
                    `the server subnet, but no node has clusterLink:"direct" — so no ` +
                    `hcloud.NetworkRoute is created for the VIP (${projectSettings.network.vip}). ` +
                    `kube-vip will move the VIP to the cloud segment and nothing on the robot ` +
                    `vSwitch will reach it. Set clusterLink:"direct" on that node.`,
            );
        }

        if (!vipGateway) {
            // Not an error: with no enabled cloud CP the VIP is announced by kube-vip on the
            // holder's OWN segment (the DaemonSet's lone-dedicated-CP branch) and every
            // consumer arrives over WireGuard or tailscale. Said out loud on every up so the
            // posture is stated rather than rediscovered by reading this file.
            pulumi.log.info(
                `network: no enabled hcloud node with clusterLink:"direct", so no VIP route ` +
                    `is created. ${projectSettings.network.vip} is reachable on the holder's ` +
                    `own segment and over the admin WireGuard / tailscale paths only — which ` +
                    `is correct for this topology. See src/network.ts and ` +
                    `doc/kube-vip-cross-segment.md.`,
                this,
            );
        }

        if (vipGateway) {
            this.vipRoute = new hcloud.NetworkRoute(
                `${projectSettings.general.name}-vip-route`,
                {
                    networkId: this.network.id.apply((id) => Number(id)),
                    destination: `${projectSettings.network.vip}/32`,
                    gateway: vipGateway,
                },
                { provider: hProvider, parent: this, dependsOn: [this.subnet] },
            );
        }

        // ── Robot vSwitch → vswitch subnet (only when there are robot nodes) ────────────
        if (robotNodes.length > 0) {
            // One Robot vSwitch carries a single VLAN; all robot nodes share it. Take the VLAN
            // from the first robot node (validated unique-per-vSwitch by convention) and attach
            // every robot serverId. The Robot vSwitch lifecycle is NOT covered by any Pulumi
            // provider, so it's driven via the Robot webservice API in a local Command.
            const vlanId = robotNodes[0].vlanId;
            const serverIds = robotNodes.map((n) => n.serverId);
            const vswitchName = `${projectSettings.general.name}-vswitch`;

            const vswitchCmd = new command.local.Command(
                `${name}-robot-vswitch`,
                {
                    // Force bash: the scripts use bash arrays/[[ ]]; the default /bin/sh (dash)
                    // would syntax-error.
                    interpreter: ["/bin/bash", "-c"],
                    environment: {
                        ROBOT_USER: projectSettings.hetzner.robotUser ?? pulumi.output(""),
                        ROBOT_PASS: projectSettings.hetzner.robotPassword ?? pulumi.output(""),
                    },
                    // create/update: ensure the vSwitch exists, every robot server is attached,
                    // and the attachment is `ready`. Emits ONLY the vSwitch id on stdout.
                    create: this.robotVswitchEnsureScript(vswitchName, vlanId, serverIds),
                    update: this.robotVswitchEnsureScript(vswitchName, vlanId, serverIds),
                    // delete: intentionally a NO-OP. The Robot vSwitch PERSISTS across
                    // `make destroy` — cancelling it triggers a Hetzner cancellation email and
                    // a re-create on the next `up` re-attaches (each cancel/recreate churns).
                    // create finds-or-reuses by name, so a persistent vSwitch is just reused.
                    delete: this.robotVswitchPersistScript(vswitchName),
                    triggers: [vswitchName, String(vlanId), serverIds.join(",")],
                },
                { parent: this },
            );

            // hcloud "vswitch"-type subnet referencing the Robot vSwitch id (stdout above).
            // Auto-import when it survived a prior incomplete destroy (import id = "<net>-<range>").
            this.vswitchSubnet = new hcloud.NetworkSubnet(
                `${projectSettings.general.name}-vswitch-subnet`,
                {
                    networkId: this.network.id.apply((id) => Number(id)),
                    type: "vswitch",
                    networkZone: "eu-central",
                    ipRange: projectSettings.network.vswitchRange,
                    vswitchId: vswitchCmd.stdout.apply((s) => Number(s.trim())),
                },
                {
                    provider: hProvider,
                    parent: this,
                    dependsOn: [vswitchCmd],
                    import: imports?.vswitchSubnetId,
                },
            );

            // Robot firewall — the dedicated boxes are NOT in the hcloud API, so the hcloud
            // Cloud firewall (below) does not cover them. This is a COARSE outer layer only
            // (drop rpcbind/111, allow the rest); the actual allow-list enforcement on robot
            // boxes is the host nftables table (publicGuardScript) — the Robot API cannot
            // express our rule set within its limits. See robotFirewallEnsureScript.
            new command.local.Command(
                `${name}-robot-firewall`,
                {
                    interpreter: ["/bin/bash", "-c"],
                    environment: {
                        ROBOT_USER: projectSettings.hetzner.robotUser ?? pulumi.output(""),
                        ROBOT_PASS: projectSettings.hetzner.robotPassword ?? pulumi.output(""),
                    },
                    create: this.robotFirewallEnsureScript(serverIds),
                    update: this.robotFirewallEnsureScript(serverIds),
                    // delete: disable the Robot firewall (no managed rules left).
                    delete: this.robotFirewallDisableScript(serverIds),
                    // Re-run on server-set change OR when the ensure script changes.
                    triggers: [serverIds.join(","), this.robotFirewallEnsureScript(serverIds)],
                },
                { parent: this },
            );
        }

        // hcloud Cloud firewall — attaches to hcloud VMs; enforces the full allow-list
        // (no rule cap here). Dedicated/robot boxes are not in the hcloud API — their
        // allow-list enforcement is the host nft table (publicGuardScript); the Robot
        // firewall above is only the coarse 111-drop outer layer. Note this firewall does
        // NOT filter private-network traffic; on hcloud nodes that gap is covered by the
        // same host nft table baked into their userData.
        this.firewall = new hcloud.Firewall(
            `${projectSettings.general.name}-fw`,
            { rules: effectiveFirewallRules },
            { provider: hProvider, parent: this },
        );

        this.registerOutputs({
            network: this.network,
            subnet: this.subnet,
            vswitchSubnet: this.vswitchSubnet,
            vipRoute: this.vipRoute,
            firewall: this.firewall,
        });
    }

    // ── Robot vSwitch helpers (webservice API; no Pulumi provider exists) ───────────────
    // robot-ws auth via $ROBOT_USER/$ROBOT_PASS (Command environment). All endpoints are
    // form-encoded. The vSwitch attach is async: a server goes `in process` → `ready`.

    private robotVswitchEnsureScript(
        vswitchName: string,
        vlanId: number,
        serverIds: number[],
    ): string {
        const api = "https://robot-ws.your-server.de";
        const serverArgs = serverIds.map((id) => `--data-urlencode "server[]=${id}"`).join(" ");
        return `set -euo pipefail
if [ -z "\${ROBOT_USER:-}" ] || [ -z "\${ROBOT_PASS:-}" ]; then
    echo "ERROR: hetznerRobotUser/hetznerRobotPass not set in Pulumi config" >&2; exit 1
fi
AUTH=(-u "\${ROBOT_USER}:\${ROBOT_PASS}")

# Find our vSwitch by name (NOT cancelled), else create it.
# NB: the Robot vSwitch API returns FLAT objects ({"id":..,"name":..}), no "vswitch" envelope.
LIST=$(curl -s "\${AUTH[@]}" ${api}/vswitch)
VS_ID=$(printf '%s' "$LIST" | python3 -c "import sys,json
d=json.load(sys.stdin)
print(next((v['id'] for v in d if v.get('name')=='${vswitchName}' and not v.get('cancelled')), ''))" 2>/dev/null || echo "")

if [ -z "$VS_ID" ]; then
    echo "Creating Robot vSwitch '${vswitchName}' (vlan ${vlanId})…" >&2
    CREATED=$(curl -s "\${AUTH[@]}" ${api}/vswitch \\
        --data-urlencode "name=${vswitchName}" --data-urlencode "vlan=${vlanId}")
    VS_ID=$(printf '%s' "$CREATED" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -z "$VS_ID" ]; then echo "ERROR: vSwitch create failed: $CREATED" >&2; exit 1; fi
fi
echo "vSwitch id=$VS_ID" >&2

# Attach each robot server (idempotent: Robot ignores already-attached; non-fatal on 409).
curl -s "\${AUTH[@]}" ${api}/vswitch/$VS_ID/server ${serverArgs} >/dev/null 2>&1 || true

# Wait for every requested server to reach status 'ready' (~minutes; async attach).
for i in $(seq 1 60); do
    DETAIL=$(curl -s "\${AUTH[@]}" ${api}/vswitch/$VS_ID)
    NOT_READY=$(printf '%s' "$DETAIL" | python3 -c "import sys,json
want=set(${JSON.stringify(serverIds)})
d=json.load(sys.stdin)
servers={s.get('server_number'):s.get('status') for s in d.get('server',[])}
missing=[str(n) for n in want if servers.get(n)!='ready']
print(','.join(missing))" 2>/dev/null || echo "parse-error")
    if [ -z "$NOT_READY" ]; then
        echo "All robot servers attached + ready on vSwitch $VS_ID." >&2
        printf '%s' "$VS_ID"
        exit 0
    fi
    echo "  waiting for vSwitch attach ready ($i/60) — not ready: $NOT_READY" >&2
    sleep 10
done
echo "ERROR: vSwitch $VS_ID servers not 'ready' within ~10 min" >&2
exit 1
`;
    }

    // Delete handler: NO-OP by design. The Robot vSwitch (and its server attachment) PERSISTS
    // across `make destroy` so it is reused on the next create — cancelling it triggers a
    // Hetzner cancellation email and needless churn. To remove it, cancel manually in the Robot
    // UI/API. The ensure script finds-or-reuses by name, so persistence is the steady state.
    private robotVswitchPersistScript(vswitchName: string): string {
        return `echo "robot vSwitch '${vswitchName}' left in place (persists across destroy; reused on next create)." >&2
exit 0
`;
    }

    // ── Robot firewall (webservice API; no Pulumi provider) ─────────────────────────────
    // POST /firewall/{server-number} replaces the box's whole ruleset. The Robot firewall is
    // a STATELESS packet filter on the switch port (distinct from the hcloud Cloud firewall,
    // which only covers hcloud VMs).
    //
    // We DO NOT mirror the project_settings allow-list here. Measured API limits (probed
    // live against POST /firewall/<id>, 2026-07-10; each shape tested in isolation and the
    // original ruleset restored):
    //   • hard cap of 10 rules PER CHAIN (input and output are separate budgets)
    //   • ip_version is MANDATORY on every input rule — omitted OR empty ⇒ 400
    //     INVALID_INPUT invalid:["rules"], so every rule costs ×2 (ipv4 + ipv6).
    //     (GET responses show Hetzner's own defaults with ip_version:null — that shape is
    //     read-only; the API rejects it on write. Do not infer write shapes from GET.)
    //   • dst_port takes at most THREE comma-separated ports ("80,443,22" ok,
    //     "22,80,443,6443" ⇒ 400) or ONE range ("3478-3479" ok); protocol=icmp is accepted.
    // Budget: (tcp_tokens + udp_tokens + icmp) × 2 families + 2 default-drops. Production
    // needs exactly 10/10 (zero headroom); Bootstrap (adds tcp 22 + 6443 ⇒ a second tcp
    // token) needs 12/10 and CANNOT fit. Hence: the real default-drop allow-list lives in
    // the host nftables table (publicGuardScript, nodes-k3s-common.ts), which has no rule
    // cap, and this layer stays a minimal coarse filter: drop the DDoS-reflectable
    // rpcbind/portmapper 111 (BSI CERT-Bund report; pulled in by nfs-common for Longhorn
    // RWX, which does not need portmapper), allow the rest.
    //
    // A second POST while a prior apply is still "in process" returns 409 — that is NOT a
    // rule error; the script waits for status "active" before posting.
    private robotFirewallEnsureScript(serverIds: number[]): string {
        const api = "https://robot-ws.your-server.de";
        // 4× drop rpcbind/111 (tcp+udp × ipv4+ipv6) then allow-all per family = 6 input
        // rules. filter_ipv6=true so the ipv6 drops take effect (rpcbind also listens on
        // [::]:111).
        const robotRules = [
            {
                ip_version: "ipv4",
                protocol: "tcp",
                port: "111",
                action: "discard",
                name: "drop-rpcbind-tcp4",
            },
            {
                ip_version: "ipv4",
                protocol: "udp",
                port: "111",
                action: "discard",
                name: "drop-rpcbind-udp4",
            },
            {
                ip_version: "ipv6",
                protocol: "tcp",
                port: "111",
                action: "discard",
                name: "drop-rpcbind-tcp6",
            },
            {
                ip_version: "ipv6",
                protocol: "udp",
                port: "111",
                action: "discard",
                name: "drop-rpcbind-udp6",
            },
            { ip_version: "ipv4", action: "accept", name: "allow-all-v4" },
            { ip_version: "ipv6", action: "accept", name: "allow-all-v6" },
        ];
        // Guardrail for future edits: the API hard-rejects an 11th input rule (400), which
        // would strand the box on its previous ruleset mid-deploy. Fail the preview instead.
        if (robotRules.length > 10) {
            throw new Error(
                `Robot firewall input chain has ${robotRules.length} rules — the API caps at ` +
                    `10 per chain. Trim the ruleset (the allow-list belongs in the host nft ` +
                    `layer, publicGuardScript).`,
            );
        }
        const rulesJson = JSON.stringify(robotRules);
        return `set -euo pipefail
if [ -z "\${ROBOT_USER:-}" ] || [ -z "\${ROBOT_PASS:-}" ]; then
    echo "ERROR: hetznerRobotUser/hetznerRobotPass not set in Pulumi config" >&2; exit 1
fi
AUTH=(-u "\${ROBOT_USER}:\${ROBOT_PASS}")

# Build the form-encoded body (curl --data-urlencode args). Each rule carries a mandatory
# ip_version. Emitted as NUL-separated tokens so values with spaces survive.
build_form() {
  RULES_JSON='${rulesJson}' python3 - "$1" <<'PY'
import json, os, sys
sid = sys.argv[1]
rules = json.loads(os.environ["RULES_JSON"])
# filter_ipv6=true so the ipv6 rules take effect (else IPv6 is unfiltered).
args = ["status=active", "whitelist_hos=true", "filter_ipv6=true"]
i = 0
def add(field, val):
    args.append(f"rules[input][{i}][{field}]=" + str(val))
for r in rules:
    add("ip_version", r["ip_version"])
    add("name", r.get("name","rule"))
    add("action", r["action"])
    if r.get("protocol"): add("protocol", r["protocol"])
    if r.get("port"):     add("dst_port", r["port"])
    i += 1
# NUL-TERMINATED (not just separated): a trailing NUL after the last token too, so
# bash 'read -d ""' yields the final element (without it read returns non-zero on the
# unterminated last token and drops it → a rule missing its action → 400 invalid:["rules"]).
sys.stdout.write("".join(a + "\\0" for a in args))
PY
}

# Applies are async: POST returns 202 and status goes "in process" for ~40-90s; a POST in
# that window is answered 409 (NOT a rule problem). Wait for "active" before posting.
# Returns 0 once the box reports a terminal status, 1 if it never does. The CALLER decides
# what to do with 1 — see the call sites.
#
# ⚠ It used to print a WARNING and return 0 regardless, so a box stuck "in process" got a
# second POST on top of the first. That is the exact condition the API answers 409, and the
# 409 path below then retries a THIRD time. Reporting the timeout truthfully lets the caller
# fail instead of piling writes onto a box that is already mid-apply.
wait_settle() {
    for i in $(seq 1 30); do
        ST=$(curl -s "\${AUTH[@]}" ${api}/firewall/$1 | python3 -c 'import sys,json; print(json.load(sys.stdin)["firewall"]["status"])' 2>/dev/null || echo "")
        [ "$ST" = "active" ] || [ "$ST" = "disabled" ] && return 0
        echo "  firewall $1 status='\$ST' — waiting ($i/30)…" >&2
        sleep 10
    done
    echo "  firewall $1 never reached 'active'/'disabled' in ~5 min (last status: '\$ST')." >&2
    return 1
}

for SID in ${serverIds.join(" ")}; do
    echo "Applying Robot firewall to server $SID…" >&2
    CURL_ARGS=()
    while IFS= read -r -d '' kv; do CURL_ARGS+=(--data-urlencode "$kv"); done < <(build_form "$SID")
    # A box that never settles is NOT ours to overwrite: something else is applying, or the
    # box is wedged. Posting anyway races that change and can leave either ruleset on it.
    # This layer is load-bearing (the only Robot-level filter), so fail the deploy instead of
    # applying blind — the previous ruleset stays in force meanwhile.
    if ! wait_settle "$SID"; then
        echo "  ERROR: refusing to POST a firewall to $SID while it is still applying." >&2
        echo "         Re-run once 'GET ${api}/firewall/$SID' reports status active." >&2
        exit 1
    fi
    # mktemp, not /tmp/robot-fw-resp.$$ — this runs on whoever's machine ran \`pulumi up\`,
    # and a predictable name in a world-writable directory is a symlink target.
    RESP_FILE=$(mktemp) || { echo "  ERROR: mktemp failed" >&2; exit 1; }
    HTTP=$(curl -s -o "$RESP_FILE" -w '%{http_code}' "\${AUTH[@]}" -X POST ${api}/firewall/$SID "\${CURL_ARGS[@]}")
    RESP=$(cat "$RESP_FILE"; rm -f "$RESP_FILE")
    case "$HTTP" in
        200|202)
            echo "  Robot firewall applied to $SID (HTTP $HTTP)." >&2 ;;
        409)
            # Still in process despite the settle wait (racing change from elsewhere).
            # One retry after a further settle; a second 409 fails the deploy.
            echo "  409 (in process) on $SID — settling once more and retrying…" >&2
            if ! wait_settle "$SID"; then
                echo "  ERROR: $SID still applying after a second wait; not retrying." >&2
                exit 1
            fi
            HTTP2=$(curl -s -o /dev/null -w '%{http_code}' "\${AUTH[@]}" -X POST ${api}/firewall/$SID "\${CURL_ARGS[@]}")
            if [ "$HTTP2" != "200" ] && [ "$HTTP2" != "202" ]; then
                echo "  ERROR: Robot firewall POST for $SID failed again (HTTP $HTTP2)" >&2; exit 1
            fi
            echo "  Robot firewall applied to $SID on retry (HTTP $HTTP2)." >&2 ;;
        *)
            # 400 invalid:["rules"] etc. — the ruleset itself is wrong. This layer is
            # load-bearing (only Robot-level filter on the box): fail the deploy loudly.
            echo "  ERROR: Robot firewall POST for $SID failed (HTTP $HTTP): $RESP" >&2
            exit 1 ;;
    esac
done
exit 0
`;
    }

    // Delete handler: disable the Robot firewall (drop our managed ruleset). Tolerant of
    // missing creds (skip) so `make destroy` never blocks on it.
    private robotFirewallDisableScript(serverIds: number[]): string {
        const api = "https://robot-ws.your-server.de";
        return `set -uo pipefail
if [ -z "\${ROBOT_USER:-}" ] || [ -z "\${ROBOT_PASS:-}" ]; then
    echo "robot firewall disable: creds not set — skipping" >&2; exit 0
fi
AUTH=(-u "\${ROBOT_USER}:\${ROBOT_PASS}")
for SID in ${serverIds.join(" ")}; do
    curl -s "\${AUTH[@]}" -X POST ${api}/firewall/$SID --data-urlencode "status=disabled" >/dev/null 2>&1 || true
    echo "robot firewall disabled on $SID (tolerant)." >&2
done
exit 0
`;
    }
}
