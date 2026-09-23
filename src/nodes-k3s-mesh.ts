/**
 * Project: edgecloudinfra
 * File: nodes-k3s-mesh.ts
 * Purpose: Everything for on-premise MESH nodes — machines adopted over SSH that join the
 *          cluster over the headscale/tailscale mesh (NOT physically at the network edge;
 *          "mesh" = SSH-adopted + VPN-joined). Two responsibilities live here:
 *
 *          1. MeshNodeInitProvisioner — provisions an on-premise mesh node as the cluster-init
 *             control-plane (Stage B). Unlike cloud/robot CPs, a mesh init CP:
 *               - is reached over SSH as its configured ssh{user,host,port} + a Pulumi-held key
 *                 (NOT root@public-ipv4 via the agent) — exposed to the base flow as the
 *                 ProvisionResult.sshTarget;
 *               - advertises its apiserver on its LOCAL-network IP (the mesh node's LAN), so
 *                 "direct" followers on the same site can reach it without the VPN;
 *               - has no Hetzner private net / kube-vip VIP / installimage step.
 *             SCOPE: only the INIT CP may be a mesh node provisioned synchronously here; "vpn"
 *             followers join in a later mesh pass (provisionWorker throws).
 *
 *          2. MeshNodesComponent — provisions pre-existing on-premise mesh nodes (the whole
 *             nodes.mesh list) into the k3s cluster over SSH: install Tailscale, join the
 *             headscale mesh, install the k3s agent, label/tag the node. Instantiated only when
 *             runtime_flags.meshProvisioning.vpnReady is true (set by `make provision-mesh-node`), run as a
 *             SECOND pass after the cloud cluster + VPN/mesh are up — never during `make bootstrap`.
 *
 *          The join logic is the shared set of scripts under src/provisioning-scripts/ (single
 *          source of truth, also used by scripts/provisioning/generateProvisioningScripts.sh).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import { runtime_flags } from "../runtime_flags";
import type { ComputeNodeCloud, ComputeNodeMesh } from "../project_settings_types";
import { descriptionAnnotateCmd } from "./nodes-k3s-common";
import type {
    ClusterComputeNode,
    ProviderProvisioner,
    ProvisionResult,
    SshTarget,
} from "./nodes-k3s-base";

// The ecc/* label keys. Declared once in project_settings.applicationPlacements;
// never write the literal here (checkSiteAnchors.py fails the commit on one).
const ECC = project_settings.applicationPlacements.labels;

// Tegra/Jetson boards need the L4T kernel rebuild before Cilium can run.
// Keyed on `gpu` (a CLOSED union) not `hardware` (a free-form string): a typo in
// `hardware` fails OPEN and silently skips the rebuild, which is how a node joins with a
// stock kernel and no pod gets a network. The failure modes are asymmetric — gating on
// `gpu` and being wrong only means a non-Tegra box runs the script, which exits 0 in ~1s
// on the missing /etc/nv_tegra_release. Same `jetson-` prefix 20-install-gpu.sh dispatches
// on, so a future jetson-* board needs no change here.
const isJetson = (n: ComputeNodeMesh) => n.gpu?.startsWith("jetson-") ?? false;

const NODE_PROVISIONING_DIR = path.join(__dirname, "provisioning-scripts");
const readTpl = (f: string) => fs.readFileSync(path.join(NODE_PROVISIONING_DIR, f), "utf8");
// base64 so scripts (with quotes/newlines/secrets) inline safely into the remote
// command — the mesh node sshd doesn't allow SSH setenv (AcceptEnv), so env vars fail.
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

// Ship the provisioning scripts over the command's STDIN, not inside the command string.
//
// ⚠ The scripts MUST NOT be inlined into `create`. That string becomes one argv element for
// the remote `/bin/bash`, and argv is capped (MAX_ARG_STRLEN, 128 KiB on Linux) — the whole
// set of base64 blobs blows past it. Nodes carrying the extra templates (`nestedRuntime`
// and/or the Jetson kernel+GPU pair) die with a bare `/bin/bash: Argument list too long`
// while leaner nodes stay just under the cap. Inlined, it kills the run even on the
// skip-provision path: the kernel rejects the exec before the script's first line, so the
// BOX_OK/NODE_PRESENT guard never gets a chance to exit 0.
//
// Format: one `<name> <base64>` line per script. `stageScripts` below re-splits it remotely,
// so `create` stays a few hundred bytes regardless of how many templates a node needs.
const stdinPayload = (files: Record<string, string>) =>
    Object.entries(files)
        // ⚠ TRAILING newline is required. `read` returns non-zero on a final line that has no
        // terminator, so a `while read` loop SILENTLY DROPS the last entry — the last map
        // entry never gets written and its step dies with exit 127 "No such file or
        // directory". The splitter below also handles a missing terminator, so both sides
        // are belt-and-braces.
        .map(([name, body]) => `${name} ${b64(body)}\n`)
        .join("");

// Remote-side splitter for `stdinPayload`. Reads stdin, writes /tmp/<name>.
// `|| [ -n "$_n" ]` keeps the final unterminated line (see the note above).
//
// ⚠ This ALWAYS runs to completion, even on the skip-provision path, and the BOX_OK/
// NODE_PRESENT guard is evaluated only AFTER it returns (`$_ecc_skip` below). Exiting
// before stdin is drained is what broke unibi-recslab-orin-eval on 2026-09-23: pulumi was
// still streaming the ~300 KB payload when the remote shell exited at the guard, so the
// write hit a closed reader and pulumi reported `error: EOF` for a command that had
// already printed its skip line and returned 0. The bigger the payload the more reliably
// it loses the race, which is why it surfaced on the one node carrying every template
// (Jetson kernel rebuild + verify, the GPU trio, data disk, Longhorn disks) and not on the
// ~170 KB nodes. `$_ecc_skip` keeps the drain free of side effects in that case: the
// payload is consumed and discarded rather than written to /tmp.
const stageScripts = `while read -r _n _b64 || [ -n "$_n" ]; do
  [ -n "$_n" ] || continue
  [ "$_ecc_skip" = "true" ] && continue
  printf '%s' "$_b64" | base64 -d > "/tmp/$_n"
done`;

// ─────────────────────────────────────────────────────────────────────────────
// MeshNodeInitProvisioner — an on-premise mesh node as the cluster-init CP (Stage B).
// ─────────────────────────────────────────────────────────────────────────────
export class MeshNodeInitProvisioner implements ProviderProvisioner {
    public readonly provider = "mesh" as const;

    constructor(private readonly cfg: pulumi.Config) {}

    private mesh(n: ClusterComputeNode): ComputeNodeMesh {
        return n as ComputeNodeMesh;
    }

    // SSH target for the base flow to orchestrate this mesh init CP: the configured mesh
    // user/host/port + the Pulumi-held private key, with sudo for privileged remote ops.
    private sshTargetFor(node: ComputeNodeMesh): SshTarget {
        return {
            user: node.ssh.user,
            host: node.ssh.endpoint,
            port: node.ssh.port,
            sudoPrefix: "sudo ",
            privateKey: this.cfg.requireSecret(node.ssh.key),
        };
    }

    // Provision the mesh box as the cluster-init CP over SSH. Delivers the base-generated
    // userData script in-place (base64), runs it as the mesh user with sudo. The script
    // writes /etc/rancher/k3s/config.yaml + installs k3s (INSTALL_K3S_SKIP_START=true) and
    // touches /var/lib/k3s-install-complete; the base flow then starts k3s + fetches the
    // token/kubeconfig over sshTarget.
    provisionControlPlane(args: {
        node: ClusterComputeNode;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        const node = this.mesh(args.node);
        if (!this.cfg.get(node.ssh.key)) {
            throw new pulumi.RunError(
                `mesh init node '${node.id}': Pulumi secret '${node.ssh.key}' is not set ` +
                    `(pulumi config set --secret ${node.ssh.key} "$(cat <key>)").`,
            );
        }
        const privateKey = this.cfg.requireSecret(node.ssh.key);

        // Deliver + run the cluster-init userData over SSH. Idempotent: the base userData
        // re-runs whenever it changes (the Command triggers on it); k3s install is skip-start
        // so re-runs only rewrite config + reinstall the binary, never wipe etcd.
        const provision = new command.remote.Command(
            `mesh-init-provision-${node.id}`,
            {
                connection: {
                    host: node.ssh.endpoint,
                    port: node.ssh.port,
                    user: node.ssh.user,
                    privateKey,
                },
                create: args.userData.apply(
                    (ud) => `set -e
umask 077
echo ${b64(ud)} | base64 -d > /tmp/k3s-init.sh
sudo bash /tmp/k3s-init.sh
rm -f /tmp/k3s-init.sh`,
                ),
                triggers: [args.userData, node.ssh.endpoint, String(node.ssh.port)],
            },
            { parent: args.parent, dependsOn: args.dependsOn },
        );

        // The ClusterNode view for DNS/ingress/SSH targeting. For a mesh box the public
        // address is its ssh.endpoint (an IP or resolvable name); it carries no Hetzner-assigned
        // IPv6, so hasIpv6=false (DNS skips the AAAA record).
        const clusterNode = {
            name: pulumi.output(args.nodeName),
            ipv4Address: pulumi.output(node.ssh.endpoint),
            ipv6Address: pulumi.output(""),
            hasIpv6: false,
        };

        return {
            node: clusterNode,
            // The init CP advertises on its LAN IP; the base userData detects it
            // (privateNetworkSetupScript) and exports PRIVATE_IP. We don't know it statically
            // here, so expose ssh.endpoint as the best-effort "private" address for consumers that
            // need an endpoint (kubeconfig rewrite falls back to the public path anyway).
            privateIp: pulumi.output(node.ssh.endpoint),
            resource: provision,
            sshTarget: this.sshTargetFor(node),
        };
    }

    // Mesh workers/CP followers do NOT come up through the synchronous base flow — they join
    // over the mesh in a later pass. The base flow never calls this for a mesh init cluster
    // (followers are filtered out of extraCps/workers).
    provisionWorker(_args: {
        node: ClusterComputeNode;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        throw new pulumi.RunError(
            "MeshNodeInitProvisioner.provisionWorker is not implemented: mesh followers join in " +
                "a later mesh pass (Stage B2/B3), not the synchronous base flow.",
        );
    }

    // No private-net peer discovery for a mesh init CP (followers join over the mesh later).
    discoverPeerCpIpScript(_peer: ComputeNodeCloud | undefined): pulumi.Input<string> {
        return 'PEER_IP=""';
    }

    // Host-prep for a mesh init CP: detect the primary LAN iface + IP (the default-route
    // interface) and export PRIVATE_IFACE + PRIVATE_IP — the contract the base userData
    // relies on for advertise-address / node-ip. The mesh box advertises the
    // apiserver on this LAN address so same-site "direct" followers can reach it.
    //
    // DELIBERATELY no publicGuardScript() here (unlike robot/hcloud): mesh nodes have no
    // public IP — they sit behind NAT on their site LAN — and on mesh the default-route
    // iface IS the LAN iface carrying k3s, VXLAN and SSH. A default-drop on it would brick
    // the node, reachable afterwards only with physical/NAT-side access. If a mesh init CP
    // ever gets a genuine public IP, it needs a variant that guards the public iface only.
    privateNetworkSetupScript(_node: ClusterComputeNode): string {
        return `
    # Mesh init CP: advertise on the primary LAN interface (default-route iface).
    PRIVATE_IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
    if [ -z "$PRIVATE_IFACE" ]; then
        echo "ERROR: mesh init CP could not detect a default-route LAN interface" >&2
        exit 1
    fi
    PRIVATE_IP=$(ip -o -4 addr show dev "$PRIVATE_IFACE" | awk '{split($4,a,"/"); print a[1]; exit}')
    if [ -z "$PRIVATE_IP" ]; then
        echo "ERROR: mesh init CP could not detect a LAN IP on $PRIVATE_IFACE" >&2
        exit 1
    fi
    echo "Mesh init CP advertising on $PRIVATE_IP (iface $PRIVATE_IFACE)" >&2`;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MeshNodesComponent — provisions the whole nodes.mesh list over SSH (second pass).
// ─────────────────────────────────────────────────────────────────────────────
export interface MeshNodesArgs {
    kubeconfigRaw: pulumi.Output<string>;
    // CP0 SSH target for the k3s node-token fetch (_local-fetch-cluster-inputs.sh), run from the
    // devcontainer over the admin WG tunnel. MUST be the CP0 PRIVATE IP: Production firewalls
    // public SSH shut, and the private IP is WG-reachable in both postures.
    controlPlaneSshHost: pulumi.Output<string>;
}

// Skip-check contract version — part of mesh-skipcheck-*'s triggers. Bump it when the skip-check's
// stdout contract changes, or to retire stale cached verdicts. A cached verdict is normally what
// makes a steady-state apply a no-op, but a cached FALSE is the dangerous direction: it sends a
// healthy node down the destructive cordon/drain/re-join path.
const SKIPCHECK_CONTRACT = "v3-absent-vs-notready";

export class MeshNodesComponent extends pulumi.ComponentResource {
    constructor(name: string, args: MeshNodesArgs, opts?: pulumi.ComponentResourceOptions) {
        super("ecc:infra:MeshNodes", name, {}, opts);

        const cfg = new pulumi.Config();
        // Cluster teardown: the mesh boxes are going away, so there is nothing to
        // SSH-provision — and an OFFLINE mesh box (home/lab machine that is simply powered off)
        // would make its mesh-provision remote.Command's SSH DIAL time out and hard-fail the whole
        // `pulumi up` teardown sync (the boxOk skip is INSIDE the remote script, which never runs
        // because the connection itself never opens). So we do NOT instantiate the remote
        // provision Command at all; the teardown proceeds regardless of whether the boxes are
        // reachable. The local kubectl Commands (skipcheck/fetch/detach/label) still run — they
        // target the reachable CP, not the boxes — and detach even cleans up the node/headscale
        // objects, which is the right thing here.
        //
        // BOTH teardown states, not just "destroy": `make shutdown` runs `pulumi dn` as well, so
        // an unreachable box hard-fails the SSH dial there for exactly the same reason.
        const teardown =
            project_settings.general.targetState === "destroy" ||
            project_settings.general.targetState === "shutdown";
        const filter = runtime_flags.meshProvisioning.filter;
        // Force re-provision (ARGS='<id> --force'): make every skip-check report BOX_OK=false
        // so detach + k3s re-join + Tailscale re-auth run even when the node is already Ready.
        const force = runtime_flags.meshProvisioning.force;
        // Per-run nonce, non-empty ONLY on a force run (see project_settings). Included in the
        // detach/provision triggers so a repeat force is a real change; empty otherwise, so an
        // ordinary `make up` keeps both as no-ops.
        const forceNonce = runtime_flags.meshProvisioning.forceNonce;
        // Boxes the pre-flight SSH probe in scripts/pulumi/provisionMeshNodes.sh found unreachable
        // this run. Their provision Command is not instantiated — same trick and same reason as
        // `teardown` above: the boxOk gate lives INSIDE the remote script, so it cannot help before
        // SSH connects, and an offline box burns 10 dials (~176s) before hard-failing. Everything
        // else about a skipped node still reconciles (its labels/fingerprint are kubectl-side), and
        // it stays instantiated so nothing is deleted from state.
        const skip = new Set(runtime_flags.meshProvisioning.skip);
        // `enabled: false` (default true) parks a node: no SSH dial, no k8s objects. Checked
        // BEFORE the id filter so an explicit ARGS=<id> on a disabled node fails loudly with
        // "disabled" rather than the misleading "no mesh node matches" below.
        const all = project_settings.nodes.mesh as ComputeNodeMesh[];
        if (filter !== "all" && all.some((n) => n.id === filter && n.enabled === false)) {
            throw new pulumi.RunError(
                `mesh node '${filter}' has enabled:false in project_settings.nodes.mesh — ` +
                    `set it to true to provision it.`,
            );
        }
        const nodes = all.filter(
            (n) => n.enabled !== false && (filter === "all" || n.id === filter),
        );
        // Catch the half-edit that broke the Orin once: `hardware` corrected to a Jetson
        // string while `gpu` still says otherwise (or the reverse). The rebuild gates on
        // `gpu`, so only that one is load-bearing — but a disagreement means someone edited
        // one of the two and stopped, and the result is a Tegra box joining on a stock
        // kernel with no pod network. Warn rather than throw: `hardware` is free-form
        // documentation, so a legitimately unusual value must not block a provision.
        for (const n of nodes) {
            const hwJetson = (n.hardware ?? "").includes("jetson");
            if (hwJetson !== isJetson(n)) {
                pulumi.log.warn(
                    `mesh node '${n.id}': gpu='${n.gpu ?? "(none)"}' and hardware='${n.hardware ?? "(none)"}' ` +
                        `disagree on whether this is a Jetson. The L4T kernel rebuild follows 'gpu', ` +
                        `so it will ${isJetson(n) ? "RUN" : "be SKIPPED"}. Fix whichever is wrong.`,
                );
            }
        }
        if (nodes.length === 0) {
            throw new pulumi.RunError(
                `No mesh node matches meshNodeProvisionFilter='${filter}' in project_settings.nodes.mesh.`,
            );
        }

        const headscaleUrl = `https://vpn.${project_settings.general.tld}`;
        const cleanupTpl = readTpl("00-cleanup-node.sh"); // no placeholders
        const prereqTpl = readTpl("10-install-prereqs.sh"); // no placeholders
        const vpnTpl = readTpl("30-connect-vpn.sh");
        // GPU host enablement: a dispatcher plus one script per hardware class. The
        // dispatcher picks the path from --gpu=<type> (jetson-* => SoC, else discrete PCIe)
        // and SOURCES the sibling, so all three must be uploaded together.
        // no placeholders; run only for nodes declaring k3sDataDisk
        const dataDiskTpl = readTpl("05-prepare-data-disk.sh");
        // no placeholders; run only for nodes declaring extraLonghornDisks
        const lhDiskTpl = readTpl("06-prepare-longhorn-disks.sh");
        const gpuTpl = readTpl("20-install-gpu.sh"); // no placeholders; run only for gpu nodes
        const gpuSocTpl = readTpl("20a-install-gpu-soc.sh"); // sourced by 20-install-gpu.sh
        const gpuPcieTpl = readTpl("20b-install-gpu-pcie.sh"); // sourced by 20-install-gpu.sh
        // Jetson kernel rebuild. Runs only for jetson-* nodes (isJetson) and is a no-op
        // (exit 0, ~1s) when the running kernel already satisfies every required option — it
        // reads /proc/config.gz and additionally probes NETLINK_XFRM, so it cannot be fooled
        // by a config that looks right. See src/provisioning-scripts/rebuild-kernel-tegra.sh.
        const kernelTpl = readTpl("rebuild-kernel-tegra.sh"); // no placeholders
        // Shipped with the rebuild, not run by it: the rebuild ends by telling the operator to
        // reboot and then run this. It has to already be on the box for that to be possible.
        const kernelVerifyTpl = readTpl("verify-kernel-tegra.sh"); // no placeholders
        const nestedTpl = readTpl("50-install-nested-runtime.sh"); // run only for nestedRuntime nodes
        const joinTpl = readTpl("40-join-cluster.sh");
        const fetchScript = readTpl("_local-fetch-cluster-inputs.sh");

        for (const node of nodes) {
            if (!cfg.get(node.ssh.key)) {
                throw new pulumi.RunError(
                    `mesh node '${node.id}': Pulumi secret '${node.ssh.key}' is not set ` +
                        `(pulumi config set --secret ${node.ssh.key} "$(cat <key>)").`,
                );
            }
            const sshPrivateKey = cfg.getSecret(node.ssh.key);

            // Longhorn disk tags: the node's storageScope list (overlapping disk tags, Option
            // B). Each tag selects the matching longhorn-<scope> StorageClass (see storage.ts).
            //
            // The default /var/lib/longhorn disk first, then any extraLonghornDisks the node
            // declares. Extra disks default to the node's storageScope, which is the only
            // shape that is guaranteed to have both a StorageClass and a RecurringJob backup
            // group behind it (validateClusterNodes rejects a tag carried by no node).
            const meshDisks = [
                { path: "/var/lib/longhorn", allowScheduling: true, tags: node.storageScope },
                ...(node.extraLonghornDisks ?? []).map((d) => ({
                    path: d.path,
                    allowScheduling: d.allowScheduling ?? true,
                    tags: d.tags ?? node.storageScope,
                })),
            ];
            const meshDiskCfg = JSON.stringify(meshDisks);

            // ── Two-tier reconcile fingerprints ──────────────────────────────────────
            // The expensive SSH box flow (detach + k3s re-join) is gated on fpBox: only the
            // fields baked INTO the box at join time. id → k3s --node-name; ssh.* → how we
            // reach it; advertiseRoutes → `tailscale up --advertise-routes` on the box (it is
            // NOT a kubectl label, so changing it must actually re-run the join). Everything
            // else (site/hardware/kvm/description/storageScope) is a kubectl label/annotate on
            // the live node (Tier 1, mesh-label-*) and must NOT trigger a re-join. It also
            // excludes the rotating Tailscale authkey / k3s token — fetch.stdout changes every
            // run, so including it would re-provision every run.
            //
            // `gpu` is deliberately NOT in fpBox, even though it drives a HOST INSTALL
            // (20-install-gpu.sh). `node.gpu ?? null` perturbs the hash even for nodes with no
            // GPU at all, and mesh-skipcheck-*/label-*/detach-*/provision-* ALL trigger on
            // fpBox — so adding it replaces ~22 resources across every mesh node. Replacing
            // mesh-provision-* re-dials every box over SSH, and an offline mesh node then
            // hard-fails the whole program.
            //
            // `k3sDataDisk` is excluded for the same reasons, and is safe to exclude for one
            // more: it only matters on a node that cannot join without it, so such a node is
            // never Ready with the field unapplied — it is absent or NotReady, which already
            // takes the full SSH flow. Adding the field to a node that IS Ready means its root
            // could host /var/lib/rancher after all, so there is nothing to fix mid-flight;
            // relocating it needs a re-provision (`make provision-mesh-node ARGS='<id>'`).
            //
            // It would not buy the safety it appears to, either: the provision command's gate
            // is `BOX_OK == true || NODE_PRESENT == true`, so a Ready node with a stale
            // fingerprint reports NODE_PRESENT=true → Tier-1 label reconcile only, no SSH flow,
            // no driver install. Adding a GPU to a LIVE node needs
            // `make provision-mesh-node ARGS='<id>'` (implies --force) regardless; that is the
            // documented procedure (doc/mesh-node-management.md), not something a fingerprint
            // can repair. gpu IS in fpLabels below — the cheap kubectl-only tier.
            const sha = (s: string) =>
                crypto.createHash("sha256").update(s).digest("hex").slice(0, 16);
            const fpBox = sha(
                JSON.stringify([
                    node.id,
                    node.ssh.endpoint,
                    node.ssh.port,
                    node.ssh.user,
                    node.advertiseRoutes ?? null,
                ]),
            );
            // Tier-1 label fingerprint: re-apply labels whenever any label-relevant field changes.
            const fpLabels = sha(
                JSON.stringify([
                    node.site,
                    node.hardware ?? null,
                    node.kvm ?? false,
                    node.description ?? null,
                    node.storageScope,
                    // Longhorn disks are an ANNOTATION + a live-CR patch, both applied by the
                    // Tier-1 command below — so this belongs here and NOT in fpBox, exactly like
                    // storageScope above. In fpBox it would drain the node, run
                    // 00-cleanup-node.sh --wipe-storage (`rm -rf /var/lib/longhorn`) and re-join
                    // it — destroying every replica on the node to add a disk to it.
                    node.extraLonghornDisks ?? null,
                    node.gpu ?? null,
                    node.nestedRuntime ?? null,
                    node.edaBuilder ?? null,
                    // Both are label-only, so they belong in fpLabels and NOT in fpBox:
                    // enrolling or retiring an AD DC node, or correcting a LAN address, must
                    // reconcile with a kubectl label — never with a drain and re-join.
                    node.lanIp ?? null,
                    node.adDc ?? null,
                    // ecc/fileserver-lan compares node.site against THIS, so moving the appliance
                    // to another site must re-label every node — including ones whose own fields
                    // are untouched. Without it the label would silently keep the old answer.
                    project_settings.storage.fileserver.site,
                ]),
            );

            // 0. Skip-check: THREE-state, because "not fully provisioned" splits into two cases
            //    with very different costs:
            //      BOX_OK=true  NODE_PRESENT=true  — Ready + fingerprint matches → skip everything.
            //      BOX_OK=false NODE_PRESENT=true  — the node IS joined and Ready, but its
            //                                        ecc/provision-fingerprint is missing/stale.
            //                                        The BOX is fine; only the kubectl-side
            //                                        reconcile is missing. Tier 1 ONLY — a
            //                                        cordon/drain/re-join would evict this node's
            //                                        pods to fix an annotation.
            //      BOX_OK=false NODE_PRESENT=false — not joined (or NotReady) → full SSH flow.
            //    The middle state is what a node is left in when mesh-label is skipped by the
            //    label→provision abort (see the mesh-label comment): Ready, no fingerprint, no
            //    ecc/* labels — invisible to every mesh-pinned workload and never skippable,
            //    because there is no fingerprint to compare. Without this state a plain
            //    `make provision-mesh-node` would "repair" it by DESTROYING it.
            //
            //    Triggers on fpBox ONLY — never on a per-run value like a timestamp. A trigger
            //    that changes every run REPLACES this command every run, which makes boxOk
            //    unknown at plan time and in turn forces detach/provision (which embed
            //    ${boxOk} in `create`) to UPDATE every run — churn with an empty diff. With an
            //    fpBox trigger the skip-check only re-runs when the box identity actually
            //    changes; on steady-state applies its cached stdout stays BOX_OK=true, so
            //    nothing downstream churns.
            //    Trade-off: a node broken out-of-band is NOT auto-detected on a no-op apply — fix
            //    it with a `--force` re-provision (or by changing an fpBox field).
            const skipcheck = new command.local.Command(
                `mesh-skipcheck-${node.id}`,
                {
                    create: pulumi.interpolate`
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
# ⚠ RETRY BEFORE CONCLUDING "NOT READY". This read decides whether the provision command
# takes the FULL DESTRUCTIVE PATH, and that path runs 00-cleanup-node.sh --wipe-storage —
# which does \`rm -rf /var/lib/longhorn\` (00-cleanup-node.sh:226). Every Longhorn replica on
# the box is destroyed and the disk returns with a NEW UUID, orphaning the replica CRs that
# still name the old one; Longhorn then reports the volume \`faulted\` and loops "All replicas
# are failed … Bringing up 0 replicas for auto-salvage" forever, because auto-salvage needs a
# running engine and the engine cannot start while the volume is faulted. That is
# unrecoverable without a backup restore.
# Measured 2026-08-30: a hand-run \`pulumi up\` caught all three unibi-lab nodes in a transient
# NotReady window, wiped every replica on them, and left ad-onprem-0 down for 14 h with two
# unrecoverable AD volumes.
#
# How long to wait depends on WHY the node is not Ready, and the two cases pull in opposite
# directions — so they are told apart by the kubectl exit code, not by an empty READY:
#
#   node object ABSENT (kubectl exits non-zero) — it never joined, or was pruned. There is no
#   Ready condition for polling to produce, and this is the ordinary first-provision path, so
#   decide immediately rather than delaying every new node.
#
#   node object PRESENT but NotReady — it joined once and is flapping now. This is precisely
#   the case that cost us the volumes, so outlast the node's OWN recovery mechanisms: k3s-agent
#   is Restart=always, cni-offload.service Wants= it, and mesh-endpoint-watchdog.timer re-forms
#   the VPN path on a 5-MINUTE cycle (30-connect-vpn.sh:509). A budget shorter than that cycle
#   still wipes a healthy box that a watchdog run was about to recover, so poll past it.
ATTEMPTS=25; INTERVAL=15   # 24 sleeps = 6 min, one full watchdog cycle plus margin
READY=""; FP=""; _attempt=1
while :; do
  if READY=$(kubectl get node ${node.id} -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null); then
    FP=$(kubectl get node ${node.id} -o jsonpath='{.metadata.annotations.ecc/provision-fingerprint}' 2>/dev/null || true)
  else
    READY=""; FP=""
    echo "node ${node.id}: not registered in the API — no Ready condition to wait for, so this is a fresh or pruned node and the full provision flow is correct." >&2
    break
  fi
  [ "$READY" = "True" ] && break
  [ "$_attempt" -ge "$ATTEMPTS" ] && break
  echo "node ${node.id}: registered but Ready='$READY' on attempt $_attempt/$ATTEMPTS — re-checking in $INTERVAL s (the NotReady branch WIPES /var/lib/longhorn, and the node's own watchdog runs on a 5-min cycle)." >&2
  sleep "$INTERVAL"
  _attempt=$((_attempt+1))
done
# A --force re-provision must take the full destructive path even on a Ready node, so it reports
# NODE_PRESENT=false too — otherwise the Tier-1-only branch below would swallow it.
${force ? 'echo "BOX_OK=false"; echo "NODE_PRESENT=false"; echo "(force)"; exit 0' : "true"}
if [ "$READY" = "True" ] && [ "$FP" = "${fpBox}" ]; then
  echo "BOX_OK=true"; echo "NODE_PRESENT=true"
elif [ "$READY" = "True" ]; then
  echo "BOX_OK=false"; echo "NODE_PRESENT=true"
  echo "node ${node.id} is Ready but its ecc/provision-fingerprint is missing/stale — Tier-1 label-only reconcile (no drain/re-join)." >&2
else
  echo "BOX_OK=false"; echo "NODE_PRESENT=false"
fi`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    triggers: [fpBox, SKIPCHECK_CONTRACT, force ? "force" : "noforce"],
                },
                { parent: this },
            );
            const boxOk = skipcheck.stdout.apply((out) =>
                out.includes("BOX_OK=true") ? "true" : "false",
            );
            // Tier-1-only gate: a Ready node that merely lacks its fingerprint/labels needs the
            // kubectl reconcile, NOT the SSH flow. detach + provision honour this in ADDITION to
            // boxOk; mesh-label ignores it and always reconciles (it IS the Tier-1 path).
            const nodePresent = skipcheck.stdout.apply((out) =>
                out.includes("NODE_PRESENT=true") ? "true" : "false",
            );

            // Cluster-identity fingerprint: sha256 of the kubeconfig's cluster CA.
            //
            // This is what makes `fetch` re-run when the CLUSTER is recreated. Neither
            // controlPlaneSshHost nor fetchScript changes on a recreate — the CP keeps its
            // private IP and the script is a file in git — so without this trigger Pulumi
            // considers `fetch` unchanged and replays its CACHED stdout, handing every mesh
            // node the PREVIOUS cluster's join token. k3s rejects that with
            //   "token CA hash does not match the Cluster CA certificate hash: <new> != <old>"
            // and retries forever, so the node never joins and the provision fails late.
            //
            // The kubeconfig CA is precisely the right key: it is the same CA whose hash k3s
            // embeds in the node-token (verified — the kubeconfig CA sha256 and the token's
            // hash are byte-identical), it is already an input to this component, and it
            // changes on every cluster recreate. Hashing rather than using it directly keeps
            // the (secret) CA out of the trigger value, which Pulumi stores in plain state.
            //
            // NB the token itself cannot be a trigger here: it is an OUTPUT of this very
            // command, so referencing it would be circular.
            const clusterCaFp = args.kubeconfigRaw.apply((kc) => {
                const m = /certificate-authority-data:\s*(\S+)/.exec(kc);
                // No match => emit a constant, NOT a random/throwing value: an unparseable
                // kubeconfig must not silently start re-running fetch on every up. The
                // controlPlaneSshHost trigger still covers a CP change in that case.
                return m
                    ? crypto.createHash("sha256").update(Buffer.from(m[1], "base64")).digest("hex")
                    : "no-ca-in-kubeconfig";
            });

            // 1. Fetch dynamic inputs from the live cluster (mint key, route approve,
            //    token, CP VPN IP, k3s version, headscale CA). Emits KEY=VALUE on stdout.
            const fetch = new command.local.Command(
                `mesh-fetch-${node.id}`,
                {
                    create: pulumi.interpolate`
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
export CP0_SSH_HOST="${args.controlPlaneSshHost}"
export HEADSCALE_URL="${headscaleUrl}"
export MESH_TIER="on-premise-resident"
bash src/provisioning-scripts/_local-fetch-cluster-inputs.sh`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    triggers: [args.controlPlaneSshHost, fetchScript, clusterCaFp],
                },
                { parent: this },
            );

            // Parse the KEY=VALUE stdout into individual Outputs.
            const v = (key: string) =>
                fetch.stdout.apply((out) => {
                    const line = out.split("\n").find((l) => l.startsWith(`${key}=`));
                    return line ? line.slice(key.length + 1) : "";
                });
            const tsAuthkey = v("MESH_TS_AUTHKEY");
            const k3sToken = v("MESH_K3S_TOKEN");
            const k3sVersion = v("MESH_K3S_VERSION");
            const caB64 = v("MESH_HEADSCALE_CA_B64");

            // 1b. Detach this node from the cluster BEFORE re-joining. On a re-provision
            //     (esp. after changing node.id or storageScope) the agent re-registers a fresh
            //     k3s/Longhorn node object, but the OLD one lingers — stale Longhorn disk tags +
            //     ghost replicas (the symptom: two node objects, the renamed one carrying the new
            //     storageScope while the live one keeps the old tags). Cordon → drain (evict pods,
            //     let Longhorn rebuild replicas onto healthy peers) → delete the node object, so the
            //     re-join below comes up clean. No-op on first provision (node absent → --ignore-not-found).
            //     Scope is intentionally just THIS node.id (no cluster-wide sweep): hand-joined nodes
            //     and renamed leftovers are NOT touched here — clean those by hand.
            const detach = new command.local.Command(
                `mesh-detach-${node.id}`,
                {
                    create: pulumi.interpolate`
if [ "${boxOk}" = "true" ] || [ "${nodePresent}" = "true" ]; then
  echo "box ${node.id} needs no SSH re-provision (BOX_OK=${boxOk} NODE_PRESENT=${nodePresent}) — skip detach"; exit 0
fi
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
if kubectl get node ${node.id} >/dev/null 2>&1; then
  echo "Detaching existing node ${node.id} before re-provision…"
  # A --force re-provision must cordon+drain the node FIRST (evict pods, let Longhorn
  # rebuild replicas onto healthy peers) before it is deleted and re-joined — otherwise
  # workloads are killed abruptly by the node delete. Only a Ready node can be drained:
  # an unreachable/NotReady node can't evict pods, so drain would hang the full timeout;
  # for those, go straight to delete.
  READY=$(kubectl get node ${node.id} -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
  if [ "$READY" = "True" ]; then
    echo "Cordoning ${node.id}…"
    kubectl cordon ${node.id} || true
    echo "Draining ${node.id} (evicting pods before re-provision)…"
    kubectl drain ${node.id} --ignore-daemonsets --delete-emptydir-data \
      --force --timeout=120s || echo "WARNING: drain of ${node.id} timed out/failed — deleting anyway." >&2
  else
    echo "Node ${node.id} is NotReady — skipping drain, deleting directly." >&2
  fi
  kubectl delete node ${node.id} --ignore-not-found --wait=false
  # Longhorn node CR is normally GC'd with the k8s node; delete explicitly in case it lingers.
  kubectl delete nodes.longhorn.io ${node.id} -n longhorn-system --ignore-not-found --wait=false || true
else
  echo "Node ${node.id} not present — nothing to detach (first provision)."
fi
# Delete any existing headscale machine entry named ${node.id} BEFORE the box re-registers.
# The re-join wipes tailscale state and re-registers with --hostname; headscale would otherwise
# KEEP the old record and de-dup the given name to ${node.id}-1, -2, … (orphan buildup). Deleting
# it first lets the fresh registration reuse the base name and leaves no orphan. VPN identity only.
# Same by-name delete as scripts/provisioning/decomissionNode.sh (headscale ns pod + json filter).
HS_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/name=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl get pods -n headscale -l app=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$HS_POD" ]; then
  HS_IDS=$(kubectl exec -n headscale "$HS_POD" -- headscale nodes list --output json 2>/dev/null \
    | NODE_ID=${node.id} python3 -c "
import sys, json, os
want = os.environ['NODE_ID']
data = json.load(sys.stdin)
nodes = data if isinstance(data, list) else data.get('nodes', [])
print(' '.join(str(n['id']) for n in nodes
      if (n.get('given_name') or n.get('givenName') or n.get('name')) == want))" 2>/dev/null || true)
  for HID in $HS_IDS; do
    echo "Deleting stale headscale entry id=$HID (name ${node.id}) before re-join…"
    kubectl exec -n headscale "$HS_POD" -- headscale nodes delete --identifier "$HID" --force >/dev/null 2>&1 || true
  done
fi`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    // Re-run when the box identity changes (id/ssh.*), NOT on every
                    // authkey/token rotation. The boxOk gate above no-ops it when unchanged.
                    // forceNonce is what makes a REPEAT force re-run this (see its definition).
                    triggers: [fpBox, forceNonce],
                },
                { parent: this, dependsOn: [fetch, skipcheck] },
            );

            // 2. Build the final (placeholder-substituted) scripts in TS — avoids
            //    fragile remote sed over secret values; pass them via env.
            // Subnet routes this node advertises into the mesh (usually none). Substituted
            // BEFORE the authkey: TS_AUTHKEY_PLACEHOLDER is a global replace and this token
            // must already be gone, or a key containing that literal could disturb it.
            const advertiseRoutes = (node.advertiseRoutes ?? []).join(",");
            const vpnFinal = pulumi.all([tsAuthkey, caB64]).apply(([key, ca]) =>
                vpnTpl
                    .replace(/HEADSCALE_URL_PLACEHOLDER/g, headscaleUrl)
                    .replace(/TS_ADVERTISE_ROUTES_PLACEHOLDER/g, advertiseRoutes)
                    .replace(/TS_AUTHKEY_PLACEHOLDER/g, key)
                    .replace(/HEADSCALE_CA_B64_PLACEHOLDER/g, ca),
            );
            const joinFinal = pulumi
                .all([k3sToken, k3sVersion])
                .apply(([token, ver]) =>
                    joinTpl
                        .replace(/K3S_TOKEN_PLACEHOLDER/g, token)
                        .replace(/K3S_VERSION_PLACEHOLDER/g, ver),
                );

            // 3. Provision the mesh box over SSH (idempotent: --force re-joins).
            // Scripts are base64-inlined into the command (NOT SSH env vars: the mesh
            // sshd rejects setenv). base64 is shell-safe (A–Za–z0–9+/=).
            // NOT instantiated in two cases — this is the ONLY Command that dials the (possibly
            // offline) mesh box, so gating it here is what lets both flows proceed past an
            // unreachable node:
            //   • teardown       — `make destroy` must not depend on the boxes being powered on.
            //   • skip.has(id)   — the pre-flight SSH probe found this box unreachable this run.
            if (skip.has(node.id)) {
                pulumi.log.warn(
                    `mesh node '${node.id}': SSH-unreachable at pre-flight — box provisioning ` +
                        `skipped this run; its k8s labels/fingerprint still reconcile.`,
                );
            }
            const provision =
                teardown || skip.has(node.id)
                    ? undefined
                    : new command.remote.Command(
                          `mesh-provision-${node.id}`,
                          {
                              connection: {
                                  host: node.ssh.endpoint,
                                  port: node.ssh.port,
                                  user: node.ssh.user,
                                  privateKey: sshPrivateKey,
                              },
                              // The scripts travel via `stdin` (see stdinPayload/stageScripts);
                              // `create` only stages them and runs them in order.
                              stdin: pulumi.all([vpnFinal, joinFinal]).apply(([vpn, join]) =>
                                  stdinPayload({
                                      "00-cleanup-node.sh": cleanupTpl,
                                      ...(node.k3sDataDisk
                                          ? { "05-prepare-data-disk.sh": dataDiskTpl }
                                          : {}),
                                      ...(node.extraLonghornDisks?.length
                                          ? { "06-prepare-longhorn-disks.sh": lhDiskTpl }
                                          : {}),
                                      "10-install-prereqs.sh": prereqTpl,
                                      "30-connect-vpn.sh": vpn,
                                      ...(isJetson(node)
                                          ? {
                                                "rebuild-kernel-tegra.sh": kernelTpl,
                                                "verify-kernel-tegra.sh": kernelVerifyTpl,
                                            }
                                          : {}),
                                      ...(node.gpu
                                          ? {
                                                "20-install-gpu.sh": gpuTpl,
                                                "20a-install-gpu-soc.sh": gpuSocTpl,
                                                "20b-install-gpu-pcie.sh": gpuPcieTpl,
                                            }
                                          : {}),
                                      ...(node.nestedRuntime
                                          ? { "50-install-nested-runtime.sh": nestedTpl }
                                          : {}),
                                      "40-join-cluster.sh": join,
                                  }),
                              ),
                              create: pulumi.interpolate`set -e
# WARNING: decide the skip here but do NOT exit yet — stdin must be drained first (see the
# note on stageScripts). Exiting at this point leaves pulumi writing the payload into a
# closed reader, which it reports as "error: EOF" even though the command printed its skip
# line and returned 0.
if [ "${boxOk}" = "true" ] || [ "${nodePresent}" = "true" ]; then
  _ecc_skip=true
else
  _ecc_skip=false
fi
umask 077
${stageScripts}
if [ "$_ecc_skip" = "true" ]; then
  echo "box ${node.id} needs no SSH re-provision (BOX_OK=${boxOk} NODE_PRESENT=${nodePresent}) — skip provision"; exit 0
fi
# --wipe-storage: this branch only runs for a node that is genuinely absent from the API or
# still NotReady after the skip-check has polled it for a full 6 minutes, i.e. a real
# re-provision, which cannot work without a clean Longhorn tree. The flag is what makes 00-cleanup-node.sh's guard
# distinguish that from an accidental invocation on a healthy node.
sudo bash /tmp/00-cleanup-node.sh --wipe-storage
${
    // Nodes whose ROOT CANNOT HOST /var/lib/rancher (netboot/live: root is an overlay, and
    // overlayfs cannot stack on overlayfs, so containerd's snapshotter never initialises).
    // Runs AFTER the cleanup — which deletes /var/lib/rancher/k3s and would otherwise be
    // deleting through a symlink this step had just created — and BEFORE the join, so the
    // path is already redirected when the agent installs.
    node.k3sDataDisk
        ? `sudo env ECC_DATA_DISK_LABEL=${node.k3sDataDisk.label} ECC_DATA_DISK_SUBDIR=${node.k3sDataDisk.subdir} bash /tmp/05-prepare-data-disk.sh`
        : "true # root filesystem can host /var/lib/rancher — no data disk needed"
}
${
    // Extra Longhorn disks: mount them (persistently, via fstab) BEFORE the join, so every
    // path named in node.longhorn.io/default-disks-config is a real filesystem by the time
    // longhorn-manager first inspects this node. Unmounted, Longhorn would happily create
    // the disk on the ROOT filesystem at that path and fill the OS disk instead.
    node.extraLonghornDisks?.length
        ? `sudo env ECC_LONGHORN_DISKS='${node.extraLonghornDisks
              .map((d) => `${d.label}:${d.path}`)
              .join(";")}' bash /tmp/06-prepare-longhorn-disks.sh`
        : "true # no extra Longhorn disks on this node"
}
sudo bash /tmp/10-install-prereqs.sh
${
    // Jetson: the stock L4T kernel lacks options the Cilium agent
    // hard-requires (XFRM/NETLINK_XFRM, xt_CT, TPROXY,
    // CGROUP_NET_CLASSID, ...), so the node joins Ready but NO pod
    // gets a network. Runs between 10 and 20: unnumbered because it
    // straddles a reboot rather than being a step in the sequence.
    //
    // A rebuild needs a REBOOT, and we deliberately do NOT reboot
    // from here: the only recovery from a bad Jetson kernel is the
    // extlinux menu, i.e. physical console. Auto-rebooting a remote
    // box mid-provision is how you strand it. So on a node that
    // still needs the rebuild we run it and then FAIL LOUDLY — a
    // human reboots, verifies, and re-runs provisioning. On an
    // already-patched node the script exits 0 in ~1s and this whole
    // block is invisible.
    isJetson(node)
        ? `if sudo bash /tmp/rebuild-kernel-tegra.sh --check-only; then
  echo "kernel already has the required options — continuing"
else
  echo "=== Jetson kernel rebuild required — running it now (~10 min) ==="
  sudo bash /tmp/rebuild-kernel-tegra.sh
  echo "" >&2
  echo "ERROR: this node needs a REBOOT to boot the rebuilt kernel, so provisioning stops" >&2
  echo "       here on purpose. It was NOT joined to the cluster." >&2
  echo "  1. reboot the node" >&2
  echo "  2. verify:  sudo bash /tmp/verify-kernel-tegra.sh  (exits non-zero on any problem)" >&2
  echo "     To roll back, swap the files back — this works regardless of how the" >&2
  echo "     bootloader finds the kernel, which the extlinux menu has been observed not to:" >&2
  echo "       sudo cp -a /boot/Image.backup /boot/Image && sudo cp -a /boot/initrd.backup /boot/initrd && sudo reboot" >&2
  echo "  3. re-run:  make provision-mesh-node ARGS='${node.id}'" >&2
  exit 1
fi`
        : "true # not a Jetson — no kernel rebuild"
}
${node.gpu ? `sudo bash /tmp/20-install-gpu.sh --gpu=${node.gpu}` : "true # no GPU on this node"}
# ECC_NODE_NAME makes the tailnet name equal the k8s node name (30-connect-vpn.sh).
# Passed through \`sudo env\` because sudo drops the caller's environment: without it the
# node registers under its box hostname, and headscale — which de-duplicates by name —
# renames the next re-provision to <name>-1, -2, … leaving orphans nothing can correlate
# back to a k8s node.
sudo env ECC_NODE_NAME=${node.id} bash /tmp/30-connect-vpn.sh
sudo bash /tmp/40-join-cluster.sh --node-name=${node.id}${node.gpu ? ` --gpu=${node.gpu}` : ""} --force
${node.nestedRuntime ? `sudo bash /tmp/50-install-nested-runtime.sh --runtime=${node.nestedRuntime}` : "true # no nested-container runtime on this node"}
# NOTE: /tmp/verify-kernel-tegra.sh is deliberately NOT removed — the operator needs it on
# the box after the reboot, which happens long after this command has returned.
rm -f /tmp/00-cleanup-node.sh /tmp/05-prepare-data-disk.sh /tmp/06-prepare-longhorn-disks.sh /tmp/10-install-prereqs.sh /tmp/rebuild-kernel-tegra.sh /tmp/20-install-gpu.sh /tmp/20a-install-gpu-soc.sh /tmp/20b-install-gpu-pcie.sh /tmp/50-install-nested-runtime.sh /tmp/30-connect-vpn.sh /tmp/40-join-cluster.sh`,
                              // Re-run when the box identity changes (id/ssh.*) — NOT on authkey/
                              // token rotation, which would re-join every run. The boxOk gate above
                              // no-ops it when unchanged.
                              //
                              // ⚠ `forceNonce` MUST be in here. fpBox covers only
                              // id/ssh.*/advertiseRoutes, none of which change when you re-run
                              // `make provision-mesh-node ARGS=<id>` against an already-provisioned
                              // box — Pulumi would see the resource as unchanged and SKIP it while
                              // the shell wrapper had already printed "will be cordoned, drained and
                              // re-joined", so a no-op force run looks exactly like a real one.
                              // forceNonce is non-empty ONLY on a force run, so ARGS=<id> (force
                              // implied) always re-runs while an ordinary `make up` — and
                              // ARGS='<id> --no-force' — stay cheap no-ops.
                              triggers: [fpBox, forceNonce],
                          },
                          { parent: this, dependsOn: [fetch, detach, skipcheck] },
                      );

            // 4. Tier-1 reconcile: apply mesh labels + the Longhorn per-scope disk tags. This is
            //    the CHEAP path — pure kubectl against the live node, idempotent (--overwrite).
            //    It runs whenever any label-relevant field changes (fpLabels) OR a (re)provision
            //    happened, INDEPENDENT of the box flow: editing site/hardware/kvm/description/
            //    storageScope reconciles here with NO drain/SSH/k3s re-join. Also stamps
            //    ecc/provision-fingerprint=fpBox so the next run's skip-check can compare.
            const labels: string[] = [
                // node-role.* must be set via kubectl (kubelet may not self-assign it).
                // Empty value → ROLE column shows "mesh" (k8s reads only the key for ROLE).
                "node-role.kubernetes.io/mesh=",
                "node.kubernetes.io/mesh-worker=true",
                `${ECC.site}=${node.site}`,
                // Reachability of the fileserver appliance's LAN, as a CAPABILITY rather than a
                // location. Every consumer that pins itself to the appliance's site (csi-driver-nfs
                // and so every static NFS PV, the truenas jobs, image-registry, gitlab-s3-proxy,
                // the [eda] runner's /artifacts mount) actually needs a ROUTE to that LAN — and
                // "is a mesh node" is NOT that route: the cloud CPs run `tailscale up` without
                // --accept-routes (mesh-gateway/daemonset.yaml), and mesh sites other than the
                // fileserver's have no path to it either. So this is narrower than ecc/mesh and
                // wider than a hostname pin, which is exactly the set those consumers want.
                //
                // Derived from storage.fileserver.site — the ONE place the appliance's location is
                // declared (project_settings.ts). No new settings field, and no manifest needs to
                // repeat the site name to express "where the appliance is".
                ...(node.site === project_settings.storage.fileserver.site
                    ? [`${ECC.fileserverLan}=true`]
                    : []),
                ...(node.hardware ? [`ecc/hardware=${node.hardware}`] : []),
                ...(node.kvm ? [`${ECC.kvm}=true`] : []),
                // Capability vs. model, deliberately SPLIT. `ecc/gpu=true` answers "does this
                // node have a GPU at all" — that is what almost every consumer actually wants,
                // and an equality nodeSelector can match it. `ecc/gpu-model` carries the
                // specific SoC for the few workloads that are CUDA-arch sensitive (a Thor is
                // sm_110; an Orin is not, so a container built for one will not run on the
                // other). A single model-valued label would force every consumer to hardcode
                // the model, because no equality selector could then express "any GPU".
                ...(node.gpu ? [`${ECC.gpu}=true`, `${ECC.gpuModel}=${node.gpu}`] : []),
                ...(node.nestedRuntime ? [`${ECC.nestedRuntime}=${node.nestedRuntime}`] : []),
                // Per-runtime boolean label, so a pod can select on the handler it needs
                // rather than on a single-valued label. Keep in sync with the nodeSelector
                // in deployment/argocd-apps/remote-desktop/desktop-gvisor.yaml.
                ...(node.nestedRuntime === "gvisor" ? [`${ECC.nestedRuntimeGvisor}=true`] : []),
                // EDA image-build host — what the shared [eda] runner's node_selector matches.
                // A capability label instead of a hostname pin, so a build can land on any
                // enrolled node. Keep in step with scripts/provisioning/generateProvisioningScripts.sh
                // and adoptProvisionedNodes.sh, or a node drifts on rejoin.
                ...(node.edaBuilder ? [`${ECC.edaBuilder}=true`] : []),
                // The node's own site-LAN address, and whether it runs an on-prem AD DC.
                //
                // WHY LABELS AND NOT MANIFEST ANCHORS: this is per-node state that several
                // unrelated consumers need (the DC StatefulSet, the AD replication Job, the
                // TrueNAS configure Job). As anchors each would carry its own copy of one
                // address, propagated by a regex scraper whose orphan check is a stderr
                // warning with no non-zero exit — a shape that fails silently and only
                // surfaces on a recreate. As labels there is one value, read from the live
                // node, and reconciled HERE in Tier 1: adding, moving or retiring a DC node
                // is a `kubectl label`, with no drain, no SSH and no k3s re-join.
                //
                // ⚠ ecc/lan-ip is the DECLARED address (a DHCP reservation lives on the box,
                // not here). The DC pod derives its actual LAN address from the node's
                // default-route NIC and refuses to start when the two disagree — see the
                // resolve-node-config initContainer in samba-ad/statefulset-onprem.yaml.
                ...(node.lanIp ? [`${ECC.lanIp}=${node.lanIp}`] : []),
                ...(node.adDc ? [`${ECC.adDc}=true`] : []),
            ];
            new command.local.Command(
                `mesh-label-${node.id}`,
                {
                    create: pulumi.interpolate`
TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
printf '%s' "$KUBECONFIG_CONTENT" > "$TMPKC"
export KUBECONFIG="$TMPKC"
# ⚠ ON A FORCE RUN, WAIT FOR THE NODE OBJECT TO BE REPLACED FIRST.
# This command has no dependsOn edge to mesh-provision (see the triggers comment below), so
# it starts CONCURRENTLY with detach+provision. On a force run detach DELETES the node object
# and the box re-joins as a brand-new one — so labelling "the node that is present right now"
# labels the doomed object: mesh-label finishes in ~1s, detach deletes the node seconds later,
# provision re-joins a minute later, and the node comes back with NO ecc/* labels and no
# fingerprint while the run reports rc=0. The symptom is a node stuck at ROLES=<none> after a
# "successful" reprovision, repelling every mesh-pinned pod (taint present, selectors unmatched).
# So on force: capture the CURRENT uid and wait until it changes (or the node disappears)
# before doing anything. Non-force labels immediately — no replacement is expected.
${
    force
        ? `OLD_UID=$(kubectl get node ${node.id} -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
if [ -n "$OLD_UID" ]; then
  echo "force: waiting for ${node.id} to be replaced (old uid $OLD_UID)…"
  # Same skip/teardown short-circuit as the wait-for-register loop below: with no provision
  # Command there is no detach+re-join in flight, so the uid can never change and the full
  # 240×5s is dead time.
  for i in $(seq 1 ${teardown || skip.has(node.id) ? 1 : 240}); do
    NEW_UID=$(kubectl get node ${node.id} -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    [ "$NEW_UID" != "$OLD_UID" ] && break
    sleep 5
  done
fi`
        : "true # non-force: no replacement expected"
}
# Only wait-for-register when the node isn't present yet (a fresh/re-join is in flight);
# if it's already there (the common re-run), label immediately — no needless wait.
# This loop is ALSO what orders this command after mesh-provision: there is deliberately no
# dependsOn edge to it (see the triggers comment below), so on a FIRST provision this command
# starts concurrently and must outwait the whole SSH flow. A cold first join installs Tailscale
# + k3s and, on nested-runtime nodes, the runtime handler — well past 5 min, hence the 240×5s cap.
#
# There is nothing to outwait when no provision Command exists for this node — teardown, or the
# pre-flight SSH probe already found the box unreachable (skip). Waiting the full 240×5s then is
# pure dead time, and because these are the LAST resources in the graph they would set the
# wall-clock of the whole mesh phase. One probe is enough — a box that could not be dialled
# cannot have registered.
if ! kubectl get node ${node.id} >/dev/null 2>&1; then
  echo "Waiting for node ${node.id} to register..."
  for i in $(seq 1 ${teardown || skip.has(node.id) ? 1 : 240}); do
    kubectl get node ${node.id} >/dev/null 2>&1 && break
    sleep 5
  done
fi
# A node that never registered is a hard error ONLY when it was already present at skip-check
# time (NODE_PRESENT=true) — then its absence now is real breakage. Otherwise this run is a
# first/re-provision whose SSH flow may legitimately have failed for its OWN reasons, and that
# failure is already reported as the mesh-provision resource error; failing here too would add
# nothing but a second red herring. Same during teardown, where the box may just be powered off.
if ! kubectl get node ${node.id} >/dev/null 2>&1; then
  if [ "${nodePresent}" = "true" ] && [ "${teardown ? "true" : "false"}" = "false" ]; then
    echo "ERROR: node ${node.id} was Ready at skip-check but is now gone — cannot label." >&2
    exit 1
  fi
  echo "SKIP: node ${node.id} did not register — nothing to label (see the mesh-provision result for why)." >&2
  exit 0
fi
kubectl label node ${node.id} ${labels.join(" ")} --overwrite
# ecc/fileserver-lan must be REMOVED explicitly when this node is no longer at the appliance's
# site — \`kubectl label --overwrite\` above only ever adds, so moving the appliance would leave
# the old site's nodes still claiming the LAN. A stale \`true\` is the dangerous direction: it
# sends csi-driver-nfs and every static NFS PV to a node with no route to the export, where
# CreateVolume times out (DeadlineExceeded) and PVCs stay Pending with nothing pointing at
# routing. Same both-directions handling as the ecc/gpu taint below.
${
    node.site === project_settings.storage.fileserver.site
        ? ""
        : `kubectl label node ${node.id} ${ECC.fileserverLan}- 2>/dev/null || true`
}
# GPU nodes are a SCARCE, dedicated resource — a single card per box. Taint them so the node
# is opt-in only: a GPU consumer tolerates ecc/gpu, everything else is excluded by DEFAULT.
# The reason is PLACEMENT, not capability: Longhorn does attach on a Jetson (the kernel
# rebuild in rebuild-kernel-tegra.sh provides CONFIG_ISCSI_TCP), but GPU-node RAM should not go to a
# Postgres and DB state should not sit behind a lab-LAN WireGuard hop. A taint expresses that
# centrally; a per-app nodeAffinity blocklist would need every NEW app to remember to copy it.
# NB the taint is applied HERE via kubectl, not in the k3s join config next to ecc/mesh: the
# join file is only read at join time, so putting it there would make adding/removing a GPU
# require a destructive re-join. Both directions are handled so that clearing gpu in
# project_settings actually un-taints the node instead of silently leaving it unschedulable.
${
    node.gpu
        ? `kubectl taint node ${node.id} ${ECC.gpu}=true:NoSchedule --overwrite`
        : `kubectl taint node ${node.id} ${ECC.gpu}- 2>/dev/null || true`
}
kubectl label node ${node.id} node.longhorn.io/create-default-disk=config --overwrite
kubectl annotate node ${node.id} 'node.longhorn.io/default-disks-config=${meshDiskCfg}' --overwrite
# ⚠ THE ANNOTATION ALONE IS NOT ENOUGH ON A LIVE NODE. Longhorn reads
# default-disks-config ONLY when it first creates the node's disks; afterwards it never
# re-reads it. So adding a disk (or changing tags) via the annotation on a joined node is a
# silent no-op: everything reports green and nothing happens. adoptProvisionedNodes.sh has
# carried this same patch since the manual path hit it; this is the Pulumi-side equivalent.
#
# ADDITIVE BY PATH, deliberately: entries are merged in by path and nothing is ever removed.
# A disk that disappears from settings stays in the CR — dropping it here would orphan any
# replicas living on it, and Longhorn's own eviction (decomissionNode.sh) is the supported
# way to retire one. Tags of existing disks ARE reconciled, keyed on path, so a disk keeps
# its identity while its scopes follow settings.
if kubectl get nodes.longhorn.io -n longhorn-system ${node.id} >/dev/null 2>&1; then
  _lh_patch=$(kubectl get nodes.longhorn.io -n longhorn-system ${node.id} -o json \\
    | ECC_DISKS='${meshDiskCfg}' python3 -c "
import json, os, sys
want = {d['path']: d for d in json.loads(os.environ['ECC_DISKS'])}
node = json.load(sys.stdin)
disks = node.get('spec', {}).get('disks', {})
# Reconcile the disks Longhorn already knows, matched on PATH (the key is an opaque
# Longhorn-generated name, never parse it).
seen = set()
for d in disks.values():
    w = want.get(d.get('path'))
    if not w:
        continue
    seen.add(d['path'])
    d['tags'] = w['tags']
    d['allowScheduling'] = w['allowScheduling']
# Add the ones it does not. The key must be stable across runs or every apply would add a
# duplicate entry for the same path; derive it from the path.
for path, w in want.items():
    if path in seen:
        continue
    key = 'ecc-' + path.strip('/').replace('/', '-')
    disks[key] = {
        'path': path,
        'allowScheduling': w['allowScheduling'],
        'tags': w['tags'],
        'storageReserved': 0,
    }
print(json.dumps({'spec': {'disks': disks}}))
" 2>/dev/null || true)
  if [ -n "$_lh_patch" ]; then
    kubectl patch nodes.longhorn.io -n longhorn-system ${node.id} --type merge -p "$_lh_patch" >/dev/null \\
      && echo "  Longhorn disks reconciled from settings." \\
      || echo "  NOTE: could not patch Longhorn disks — set them in the Longhorn UI (Node -> Edit node and disks)."
  fi
fi
${descriptionAnnotateCmd(node.id, node.description, "kubectl")}
# Stamp the box fingerprint so the skip-check no-ops the SSH flow next run.
kubectl annotate node ${node.id} ecc/provision-fingerprint=${fpBox} --overwrite
echo "Mesh node ${node.id} reconciled (per-scope Longhorn disk + ecc/* + fingerprint)."`,
                    environment: { KUBECONFIG_CONTENT: args.kubeconfigRaw },
                    // Deliberately NOT keyed on, nor dependsOn, mesh-provision. A remote.Command
                    // that fails to register REJECTS its urn AND id AND stdout (the engine
                    // synthesizes "resource … failed to register" and passes it to
                    // resolveURN/resolveID — @pulumi/pulumi/runtime/resource.js). BOTH a serialized
                    // `triggers` entry and a `dependsOn` edge await those rejected Outputs
                    // (dependsOn awaits r.urn.promise()), and the rejection then surfaces as an
                    // UNHANDLED PROGRAM EXCEPTION rather than a resource error — so ONE unreachable
                    // box aborts the whole `pulumi up` and every resource not yet registered is
                    // lost, defeating --continue-on-error entirely. The node then stays Ready in
                    // the cluster with no ecc/* labels and no fingerprint, because this Command
                    // never ran and never entered state.
                    //
                    // Nothing is lost by not triggering on provision.stdout: fpBox is what DECIDES
                    // whether a provision happens at all (skipcheck/detach/provision all trigger on
                    // fpBox alone), so any run that provisions fires this trigger too, and
                    // nodePresent covers the out-of-band-drift case better. Ordering comes from the
                    // wait-for-register loop in `create` — which is the thing that actually needs
                    // provision to have finished — and the command is idempotent (--overwrite), so
                    // overlapping a provision is harmless.
                    //
                    // controlPlaneSshHost is a cluster-identity token: on a cluster RECREATE the
                    // boxes (fpBox) and label set (fpLabels) are identical and provision no-ops
                    // (same box fingerprint), so none of those triggers fire — the Command stays
                    // cached and never labels the NEW cluster's freshly-registered nodes. The
                    // init-CP host changes on every fresh cluster, so it re-asserts ecc/* labels
                    // on recreate without needing a destructive --force re-join. (Same recreate
                    // hazard as the kubeconfig-cascade: node-scoped kubectl keyed on node-stable
                    // fingerprints must also key on cluster identity.)
                    //
                    // forceNonce is REQUIRED here, same as on mesh-provision. Without it a run
                    // that FAILED to join leaves nodePresent="false" in state; the retry that
                    // finally succeeds computes nodePresent=false again (skip-check runs BEFORE
                    // the join), so the whole trigger tuple is unchanged and Pulumi serves this
                    // Command from cache — the node comes up Ready with NO ecc/* labels and
                    // ROLES=<none>, repelling every mesh-pinned pod.
                    triggers: [fpLabels, fpBox, nodePresent, args.controlPlaneSshHost, forceNonce],
                },
                // skipcheck only — a local kubectl Command against the reachable CP, so it cannot
                // fail on box reachability. It also ensures the node-present check below reflects
                // this run's box decision.
                { parent: this, dependsOn: [skipcheck] },
            );
        }

        this.registerOutputs({});
    }
}
