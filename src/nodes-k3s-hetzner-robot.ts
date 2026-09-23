/**
 * Project: edgecloudinfra
 * File: nodes-k3s-hetzner-robot.ts
 * Purpose: Hetzner DEDICATED (Robot) provisioner for k3s nodes.
 *
 *          Robot boxes are ordered manually in Hetzner Robot and OS-installed via
 *          installimage; Pulumi ADOPTS them (it does not create the machine). Unlike
 *          hcloud VMs there is no cloud-init userData, so the same k3s setup script the
 *          base flow generates is delivered IN-PLACE over SSH (command.remote.Command,
 *          base64-inlined — the on-premise pattern). The script is idempotent because
 *          ignoreChanges:["userData"] does NOT apply here: a Command re-runs whenever its
 *          trigger (the script) changes.
 *
 *          The private network is a Hetzner vSwitch reached over a VLAN-tagged sub-iface
 *          (<base>.<vlanId>) with a STATIC IP — see privateNetworkSetupScript below. Peer
 *          discovery uses the configured publicIp (Robot is not in the hcloud API).
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import { runtime_flags } from "../runtime_flags";
import type { ComputeNodeCloud, ComputeNodeCloudDedicated } from "../project_settings_types";
import {
    abortAfter,
    peerCpIpScript,
    publicGuardScript,
    stripPublicGuard,
} from "./nodes-k3s-common";
import type { ProviderProvisioner, ProvisionResult } from "./nodes-k3s-base";

// base64 so the (quoted/multiline/secret-bearing) setup script inlines safely into the
// remote command — same rationale as the mesh path (sshd rejects SSH setenv).
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

export class HetznerDedicatedProvisioner implements ProviderProvisioner {
    public readonly provider = "robot" as const;

    constructor(private readonly cfg: pulumi.Config) {}

    private node(n: ComputeNodeCloud): ComputeNodeCloudDedicated {
        return n as ComputeNodeCloudDedicated;
    }

    // Provision (adopt) a Robot box over SSH. Two phases:
    //   1. OS install (installimage) — only when the box is in RESCUE mode and the
    //      installed-OS marker is absent. Wipes the disk, reboots into the OS. Guarded
    //      so routine config changes NEVER re-wipe (and never touch etcd data).
    //   2. k3s setup — the base-generated cloud-init-style script, run on the installed
    //      OS. CP and worker share the delivery; the userData already differs by role.
    private provision(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        const node = this.node(args.node);
        if (!this.cfg.get(node.ssh.key)) {
            throw new pulumi.RunError(
                `robot node '${node.id}': Pulumi secret '${node.ssh.key}' is not set ` +
                    `(pulumi config set --secret ${node.ssh.key} "$(cat <key>)").`,
            );
        }
        const privateKey = this.cfg.requireSecret(node.ssh.key);

        // Host the own-OS remote Commands (Phase 2 provision + Phase 3 firewall) SSH to.
        // An explicit ssh.endpoint (e.g. a jump host) always wins. Otherwise the choice is
        // targetState-gated: in "production" the host firewall DROPS public :22 (public_guard),
        // so a re-provision / posture reload MUST come in over the private IP via the admin
        // WireGuard tunnel — which `make production` guarantees is up before it hardens. In
        // Bootstrap the private network / WG may not exist yet (fresh create), and public :22
        // is open, so the public IP is the only reachable path. (Phase 1's installimage SSH is
        // separate — it always targets publicIp:22, the RESCUE system, before any of this.)
        const ownOsHost =
            node.ssh.endpoint ??
            (project_settings.general.targetState === "production"
                ? node.privateIp
                : node.publicIp);

        // ── Phase 1: OS install via installimage (rescue-only, marker-guarded) ──────
        // Runs as a LOCAL command (not remote) because installimage reboots the box,
        // which would kill a single remote SSH session. The local side SSHes in itself
        // (explicit key in a temp file) and polls for the box to return on the installed
        // OS. To force a clean rebuild: set the box back to rescue (Robot API + reset)
        // — that removes the installed OS, so the next `pulumi up` reinstalls.
        const installOs = new command.local.Command(
            `robot-installos-${node.id}`,
            {
                create: privateKey.apply((key) => this.installOsScript(node, key)),
                // Robot creds for the rescue+reset API calls (only used on a force reinstall).
                environment: {
                    ROBOT_USER: project_settings.hetzner.robotUser ?? pulumi.output(""),
                    ROBOT_PASS: project_settings.hetzner.robotPassword ?? pulumi.output(""),
                },
                // Keyed on the box identity AND robotForceReinstall: a routine config change
                // never re-installs, but a fresh `make bootstrap` bumps robotForceReinstall to a
                // new value, firing a one-time rescue + from-scratch installimage.
                triggers: [node.publicIp, String(node.serverId), runtime_flags.robotForceReinstall],
                interpreter: abortAfter(1500), // installimage + reboot can take ~10-15 min
            },
            { parent: args.parent, dependsOn: args.dependsOn },
        );

        // ── Phase 2: k3s setup (runs on the installed OS) ───────────────────────────
        const provisionCmd = new command.remote.Command(
            `robot-provision-${node.id}`,
            {
                connection: {
                    // Node's own-OS login (ownOsHost: endpoint → private-in-Production → public).
                    host: ownOsHost,
                    port: node.ssh.port,
                    user: node.ssh.user,
                    privateKey,
                },
                // GUARD-NORMALIZED create body: strip publicGuardScript() (the host firewall,
                // which is targetState-dependent) from the k3s-setup script this Command runs.
                // A command.remote.Command re-executes its `create` whenever the create TEXT
                // changes — independent of `triggers`. If the raw guard-bearing userData were
                // embedded here, a Bootstrap↔Production flip would change those guard bytes and
                // re-run this whole k3s-setup over SSH on a live node (which also re-runs the
                // flaky k3s installer). The guard is owned entirely by firewallCmd (Phase 3)
                // below, which always runs on a fresh provision and re-applies on posture flips
                // via `nft -f`. So the provision body never needs — and must not embed — the
                // guard: stripping it makes `create` identical across postures ⇒ no re-run.
                create: args.userData.apply(stripPublicGuard).apply(
                    (script) => `set -e
umask 077
echo ${b64(script)} | base64 -d > /tmp/k3s-setup.sh
bash /tmp/k3s-setup.sh
rm -f /tmp/k3s-setup.sh`,
                ),
                // Re-run when the generated script changes — AND on a forced reinstall.
                // A reinstall (Phase 1) wipes the disk, so k3s is gone even though userData
                // is unchanged; without robotForceReinstall here Pulumi would skip Phase 2
                // and the box would boot a fresh OS with no k3s (no /var/lib/k3s-install-complete),
                // hanging k3s-init forever. Sharing the trigger ties Phase 2 to every reinstall.
                // The trigger is guard-normalized for the same reason as the create body above,
                // so only real k3s/VLAN/config deltas (or a reinstall) re-run Phase 2.
                triggers: [
                    args.userData.apply(stripPublicGuard),
                    runtime_flags.robotForceReinstall,
                ],
            },
            { parent: args.parent, dependsOn: [installOs, ...(args.dependsOn ?? [])] },
        );

        // ── Phase 3: host firewall re-apply (runtime posture flips) ─────────────────
        // publicGuardScript() is the ONLY ingress filter on a robot box (no hcloud Cloud
        // firewall in front), and it is targetState-gated. A flip to "production" must
        // tighten it at RUNTIME — a plain `nft -f` reload of /etc/nftables.conf, no k3s
        // re-run, no reboot. This command carries ONLY the guard fragment (self-contained:
        // it detects the public NIC, writes /etc/nftables.conf, reloads, and re-enables the
        // boot unit — see publicGuardScript). It triggers ONLY on the guard content, so it
        // fires on posture flips and nothing else. Mirrors the hcloud path, where the Cloud
        // firewall updates in place (there userData has ignoreChanges). dependsOn provisionCmd
        // so it runs after the node is fully set up (and after any reinstall re-provision).
        const firewallCmd = new command.remote.Command(
            `robot-firewall-${node.id}`,
            {
                connection: {
                    host: ownOsHost,
                    port: node.ssh.port,
                    user: node.ssh.user,
                    privateKey,
                },
                create: `set -e\n${publicGuardScript()}`,
                triggers: [publicGuardScript()],
            },
            { parent: args.parent, dependsOn: [provisionCmd] },
        );
        // Registered for its side effect (parent-tracked); NOT returned as `resource` — the base
        // flow's join/kubeconfig orchestration must wait on provisionCmd, not on a firewall
        // reload that is irrelevant to (and would needlessly serialize) those steps.
        void firewallCmd;

        // Robot is not in the hcloud API: addresses come from config, not a resource.
        const node_: ProvisionResult["node"] = {
            name: pulumi.output(args.nodeName),
            ipv4Address: pulumi.output(node.publicIp),
            ipv6Address: pulumi.output(node.publicIpv6 ?? ""),
            hasIpv6: !!node.publicIpv6,
        };
        return {
            node: node_,
            privateIp: pulumi.output(node.privateIp),
            resource: provisionCmd,
        };
    }

    provisionControlPlane(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        return this.provision(args);
    }

    provisionWorker(args: {
        node: ComputeNodeCloud;
        nodeName: string;
        userData: pulumi.Output<string>;
        parent: pulumi.ComponentResource;
        dependsOn?: pulumi.Resource[];
    }): ProvisionResult {
        return this.provision(args);
    }

    // Map node.os → the installimage tarball glob in /root/images (rescue system).
    // Resolved on-box (newest match) so we don't hardcode the patch version.
    private imageGlobFor(os: ComputeNodeCloudDedicated["os"]): string {
        switch (os) {
            case "debian-13":
                return "Debian-13*-trixie-amd64-base.tar.zst";
            case "ubuntu-24.04":
                return "Ubuntu-2404-*-amd64-base.tar.zst";
            default:
                throw new pulumi.RunError(`robot installimage: unsupported os "${os}".`);
        }
    }

    // LOCAL bash: install the OS via installimage iff the box is in rescue / unmarked.
    // SSHes to the box itself (key in a temp file), runs installimage, reboots, and waits
    // for the installed OS to return — then writes the marker. Idempotent: if the box is
    // already on the installed OS with the marker, it's a no-op.
    private installOsScript(node: ComputeNodeCloudDedicated, privateKey: string): string {
        const host = node.publicIp;
        const imageGlob = this.imageGlobFor(node.os);
        // autosetup config: 2× NVMe RAID1, swap+boot+root, the resolved image.
        // HOSTNAME is the k3s node-name; SSH keys are copied from rescue's authorized_keys
        // by installimage automatically (verified to contain sshkey-ecc-dedicated).
        const cluster = project_settings.general.name.toLowerCase();
        // installimage HOSTNAME = the k3s node-name, derived from the node id (NOT a magic
        // "cp0" — the initial CP is selected by clusterLink: "init", named after its id).
        const hostName = `${cluster}-${node.id}`;
        const autosetup = [
            "DRIVE1 /dev/nvme0n1",
            "DRIVE2 /dev/nvme1n1",
            "SWRAID 1",
            "SWRAIDLEVEL 1",
            "BOOTLOADER grub",
            `HOSTNAME ${hostName}`,
            "PART swap swap 2G",
            "PART /boot ext3 1024M",
            "PART /     ext4 all",
            "IMAGE __IMAGE__",
        ].join("\n");
        const ssh = `ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEYF"`;
        const robotApi = "https://robot-ws.your-server.de";
        const forceReinstall = runtime_flags.robotForceReinstall;
        // On a fresh create (robotForceReinstall non-empty) put the box back into rescue and
        // hardware-reset it, BEFORE the marker check — so installimage runs on a clean disk
        // and wipes all prior-cluster state (stale etcd/k3s/network). Skipped (empty) on
        // routine runs, where the marker no-op below preserves the installed OS.
        const forceRescueBlock = forceReinstall
            ? `
echo "robot ${node.id}: robotForceReinstall set — activating rescue + hardware reset for a from-scratch install…" >&2
if [ -z "\${ROBOT_USER:-}" ] || [ -z "\${ROBOT_PASS:-}" ]; then
    echo "ERROR: hetznerRobotUser/hetznerRobotPass not set — cannot activate rescue for forced reinstall." >&2
    exit 1
fi
RAUTH=(-u "\${ROBOT_USER}:\${ROBOT_PASS}")

# The rescue system has NO authorized_keys unless we attach our registered Robot key —
# otherwise it boots with a random root password and our key-based SSH can't get in
# (so the "hostname == rescue" probe below would never succeed). Look up the registered
# key fingerprint(s) and pass each as authorized_key so key-auth works in rescue.
KEY_FPS=$(curl -s "\${RAUTH[@]}" ${robotApi}/key \\
    | python3 -c "import sys,json; print(' '.join(k['key']['fingerprint'] for k in json.load(sys.stdin)))" 2>/dev/null || echo "")
KEY_ARGS=()
for fp in $KEY_FPS; do KEY_ARGS+=(--data-urlencode "authorized_key[]=$fp"); done
if [ \${#KEY_ARGS[@]} -eq 0 ]; then
    echo "ERROR: no SSH keys registered in Hetzner Robot — rescue would have no authorized_keys." >&2
    echo "       Register the node key in Robot (Server > Key management) and retry." >&2
    exit 1
fi

# Enable the rescue system (linux) for the next boot, with our key(s) authorized.
RESCUE_RESP=$(curl -s "\${RAUTH[@]}" -X POST ${robotApi}/boot/${node.serverId}/rescue \\
    --data-urlencode 'os=linux' "\${KEY_ARGS[@]}")
if printf '%s' "$RESCUE_RESP" | grep -q '"error"'; then
    echo "ERROR: rescue activation failed: $RESCUE_RESP" >&2
    exit 1
fi
# Hardware-reset into the freshly-armed rescue system.
RESET_RESP=$(curl -s "\${RAUTH[@]}" -X POST ${robotApi}/reset/${node.serverId} \\
    --data-urlencode 'type=hw')
if printf '%s' "$RESET_RESP" | grep -q '"error"'; then
    echo "ERROR: hardware reset failed: $RESET_RESP" >&2
    exit 1
fi

echo "robot ${node.id}: waiting for the box to come up in rescue…" >&2
for i in $(seq 1 60); do
    sleep 10
    if ${ssh} root@${host} '[ "$(cat /etc/hostname)" = "rescue" ]' 2>/dev/null; then
        echo "robot ${node.id}: in rescue after ~$((i*10))s." >&2
        break
    fi
    if [ "$i" = "60" ]; then
        echo "ERROR: robot ${node.id} did not return in rescue within ~10 min." >&2
        exit 1
    fi
done
`
            : "";
        return `set -euo pipefail
KEYF=$(mktemp); chmod 600 "$KEYF"
cat > "$KEYF" << 'PRIVKEY'
${privateKey}
PRIVKEY
trap 'rm -f "$KEYF"' EXIT
${forceRescueBlock}
# Already installed (marker present, not rescue)? → no-op. (On a forced reinstall the box is
# now in rescue, so this is skipped and installimage runs.)
if ${ssh} root@${host} 'test -f /etc/ecc-os-installed && [ "$(cat /etc/hostname)" != "rescue" ]' 2>/dev/null; then
    echo "robot ${node.id}: OS already installed (marker present) — skipping installimage." >&2
    exit 0
fi

# Must be in rescue to run installimage. If it's an installed OS WITHOUT our marker,
# refuse to wipe (could be a hand-installed box with data) — operator must set rescue.
IS_RESCUE=$(${ssh} root@${host} '[ "$(cat /etc/hostname)" = "rescue" ] && echo yes || echo no' 2>/dev/null || echo unreachable)
if [ "$IS_RESCUE" != "yes" ]; then
    echo "ERROR: robot ${node.id} (${host}) is not in rescue mode (state: $IS_RESCUE) and has no" >&2
    echo "       ecc-os-installed marker. Refusing to installimage (would wipe disk)." >&2
    echo "       To (re)install: boot the box into rescue (Robot API/UI) + reset, then re-run." >&2
    exit 1
fi

echo "robot ${node.id}: in rescue — resolving image + running installimage…" >&2
IMG=$(${ssh} root@${host} 'ls -1 /root/images/${imageGlob} 2>/dev/null | sort | tail -1')
if [ -z "$IMG" ]; then echo "ERROR: no image matching ${imageGlob} on ${host}" >&2; exit 1; fi
echo "robot ${node.id}: using image $IMG" >&2

# Write autosetup (substitute resolved image) and run installimage non-interactively.
${ssh} root@${host} "cat > /autosetup << 'AUTOSETUP'
${autosetup}
AUTOSETUP
sed -i \\"s#__IMAGE__#$IMG#\\" /autosetup"

# installimage: -a automatic, -c config. It partitions, installs, sets bootloader,
# copies rescue authorized_keys, then we reboot into the installed OS.
${ssh} root@${host} '/root/.oldroot/nfs/install/installimage -a -c /autosetup 2>&1 | tail -40' >&2
echo "robot ${node.id}: installimage finished — rebooting into installed OS…" >&2
${ssh} root@${host} 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true

# Wait for the box to return on the INSTALLED OS (hostname != rescue).
echo "robot ${node.id}: waiting for installed OS to come up…" >&2
for i in $(seq 1 120); do
    sleep 10
    HN=$(${ssh} root@${host} 'cat /etc/hostname' 2>/dev/null || echo "")
    if [ -n "$HN" ] && [ "$HN" != "rescue" ]; then
        echo "robot ${node.id}: installed OS up (hostname=$HN) after ~$((i*10))s." >&2
        ${ssh} root@${host} 'touch /etc/ecc-os-installed'
        exit 0
    fi
    echo "  …still waiting ($i/120) [hostname='$HN']" >&2
done
echo "ERROR: robot ${node.id} did not return on the installed OS within ~20 min." >&2
exit 1
`;
    }

    // Resolve the peer control-plane's public IP. Shared logic (branches on the PEER's
    // provider) lives in nodes-k3s-common so a robot or hcloud peer resolves identically
    // regardless of which provisioner is asked.
    discoverPeerCpIpScript(peer: ComputeNodeCloud | undefined): pulumi.Input<string> {
        return peerCpIpScript(peer);
    }

    // Static vSwitch VLAN private-network setup. Exports PRIVATE_IFACE + PRIVATE_IP (the
    // contract the rest of the userData relies on), then reuses the agnostic SNAT/forward
    // gateway tail. The VLAN sub-iface is <base>.<vlanId> with MTU 1400 (Hetzner vSwitch
    // max) and the node's STATIC privateIp.
    privateNetworkSetupScript(n: ComputeNodeCloud): string {
        const node = this.node(n);
        const sub = node.vlanId; // vSwitch VLAN id (4000-4091)
        const ip = node.privateIp;
        // The VLAN iface address uses the vswitch SUBNET prefix (/24), not the umbrella
        // subnetRange (/23) — the robot IP lives in vswitchRange.
        const cidrBits = project_settings.network.vswitchRange.split("/")[1];
        // Next-hop for the private-network route. A robot box sits on the vSwitch subnet
        // (vswitchRange), so it must route into the network via THAT subnet's gateway — the
        // ".1" of vswitchRange (e.g. 10.0.1.1) — NOT network.gateway (10.0.0.1, the cloud
        // "server"-subnet gateway, which is on an L2 segment the robot box can't reach).
        // Using the cloud gateway here black-holes robot↔cloud traffic: the init CP becomes
        // unreachable at <vswitchIp>:6443 and cloud CPs fail to fetch /cacerts on join.
        // Hetzner routes between the two subnets once each side egresses via its OWN gateway.
        const vswitchGateway = project_settings.network.vswitchRange.replace(/\.\d+\/\d+$/, ".1");
        return `
    ufw disable || true
    # Detect the primary physical NIC (the default-route iface).
    BASE_IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
    # Host firewall (inet public_guard): default-drop allow-list on the public NIC. On a
    # robot box this is THE enforcement layer — no hcloud firewall exists in front, and the
    # Robot firewall (network.ts) can't express the allow-list within its 10-rule cap. Its
    # default drop also covers rpcbind/111 (BSI CB-Report 2026-06).
${publicGuardScript()}
    if [ -z "$BASE_IFACE" ]; then
        echo "WARNING: could not detect base NIC for vSwitch VLAN" >&2
        PRIVATE_IFACE=""
        PRIVATE_IP=""
    else
        PRIVATE_IFACE="\${BASE_IFACE}.${sub}"
        PRIVATE_IP="${ip}"
        # Create the VLAN-tagged sub-interface (Hetzner vSwitch). MTU 1400 is the vSwitch max.
        ip link add link "$BASE_IFACE" name "$PRIVATE_IFACE" type vlan id ${sub} 2>/dev/null || true
        ip link set "$PRIVATE_IFACE" mtu 1400 up || true
        ip addr add ${ip}/${cidrBits} dev "$PRIVATE_IFACE" 2>/dev/null || true
        # Persist via systemd-networkd (static, NOT DHCP — robot vSwitch has no DHCP).
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-vswitch-vlan.netdev << NETDEV
[NetDev]
Name=\${PRIVATE_IFACE}
Kind=vlan

[VLAN]
Id=${sub}
NETDEV
        cat > /etc/systemd/network/10-vswitch-vlan.network << ROUTECONF
[Match]
Name=\${PRIVATE_IFACE}

[Network]
Address=${ip}/${cidrBits}

[Link]
MTUBytes=1400

[Route]
Destination=${project_settings.network.privateRange}
Gateway=${vswitchGateway}
ROUTECONF
        # Bind the VLAN netdev to its parent on boot.
        cat > /etc/systemd/network/05-vswitch-parent.network << PARENT
[Match]
Name=\${BASE_IFACE}

[Network]
VLAN=\${PRIVATE_IFACE}
PARENT
        ip route add ${project_settings.network.privateRange} via ${vswitchGateway} dev "$PRIVATE_IFACE" onlink || true
        # Persist IP forwarding for WireGuard.
        cat > /etc/sysctl.d/99-wireguard.conf << SYSCTLWG
net.ipv4.ip_forward = 1
SYSCTLWG
        sysctl --system || true

        # ── Mesh → private-network gateway (mesh API HA) ──────────────────────────
        # Same forwarding leg as cloud nodes (see nodes-k3s-common privateNetworkSetupScript):
        # SNAT mesh→private out the VLAN iface so every CP is a mesh↔private gateway.
        iptables -t nat -C POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$PRIVATE_IFACE" -j MASQUERADE 2>/dev/null \\
          || iptables -t nat -A POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$PRIVATE_IFACE" -j MASQUERADE
        # Persist across reboots. The ExecStart re-derives the VLAN iface at boot from the
        # default-route NIC + the fixed VLAN id (the base NIC name is stable on a dedicated
        # box, but re-deriving avoids hardcoding it). 'SNATSVC' is single-quoted so the
        # heredoc body is written verbatim (resolved at boot, not at script-write time).
        #
        # WARNING: the [Install] WantedBy is what makes 'systemctl enable' below actually do
        # something. Without it, enable has nothing to symlink and prints the "unit files have
        # no installation config" explainer -- which the '|| true' then swallows, so the unit
        # was silently NOT enabled and the SNAT rule only survived until the next reboot (the
        # iptables call above applies it imperatively for the current boot only). On a CP box
        # that is the mesh<->private API HA path, so losing it on reboot is not cosmetic.
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/mesh-private-snat.service << 'SNATSVC'
[Unit]
Description=SNAT tailscale mesh -> Hetzner vSwitch private network (mesh API HA gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'B=$(ip -o -4 route show default | awk "{print \\$5; exit}"); IFACE="$B.${sub}"; iptables -t nat -C POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${project_settings.network.meshRange} -d ${project_settings.network.subnetRange} -o "$IFACE" -j MASQUERADE'

[Install]
WantedBy=multi-user.target
SNATSVC
        systemctl daemon-reload || true
        systemctl enable mesh-private-snat.service || true

        # ── Connectivity gate ─────────────────────────────────────────────────────
        # The Robot vSwitch attach is async and the bridged path to the hcloud private
        # network (via the vSwitch gateway ${vswitchGateway}) can take a minute to come up.
        # Wait for it before k3s starts so cp0 doesn't advertise an apiserver the cloud CPs
        # can't yet reach (and a robot worker doesn't try to join a not-yet-routable server).
        echo "Waiting for vSwitch path to ${vswitchGateway}…" >&2
        for i in $(seq 1 18); do
            ping -c1 -W2 ${vswitchGateway} >/dev/null 2>&1 && { echo "private path up." >&2; break; }
            [ "$i" = "18" ] && echo "WARNING: ${vswitchGateway} not reachable after ~3 min — continuing anyway." >&2
            sleep 10
        done
    fi
`;
    }
}
