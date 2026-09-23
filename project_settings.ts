/**
 * Project: edgecloudinfra
 * File: project_settings.ts
 * Purpose: Shared project settings and types.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

/*
Single source of truth for all project settings. AFTER CHANGING ANY VALUE HERE, run
scripts/environment/updateConfigFromProjectSettings.sh
src/*.ts import this file, but the YAML in deployment/ cannot, and is kept in sync
by that script's anchor passes.

That script EVALUATES this file (scripts/environment/dumpProjectSettings.mjs emits the
settings as JSON with getters resolved), so getters need no shell counterpart. What is
load-bearing instead: every key an anchor names must resolve in the JSON, and every
resolver must be reached by some anchor — the engine errors on either orphan, so a renamed
path fails loudly rather than silently ceasing to propagate.

Fields marked "derived — do not edit" are computed from their siblings. Per-run flags that
steer an apply live in runtime_flags.ts, not here; field-level type docs live in
project_settings_types.ts.
*/

import * as pulumi from "@pulumi/pulumi";
// Shared domain types live in a dedicated file; only settings belong here.
// Type-only names must be imported with `import type`: the JSON dump
// (scripts/environment/dumpProjectSettings.mjs) evaluates this file with Node's type
// stripping, which erases `import type` but keeps a value import — a type imported as a
// value becomes a runtime import of a name that does not exist. `npx tsc --noEmit`
// (make check) keeps the split honest.
import type {
    LoadBalancerProvider,
    TargetState,
    CertType,
    ComputeNodeCloud,
    LonghornReplicaCount,
    ComputeNodeMesh,
} from "./project_settings_types";
import {
    validateClusterNodes,
    validateAdPlacement,
    validatePlacementDefaults,
} from "./project_settings_types";

// Pulumi config handle for secrets/overrides. Not a setting — just the accessor used below.
const projectConfig = new pulumi.Config();

export const project_settings = {
    general: {
        name: "edgecloudinfra", // pulumi project / resource name prefix + S3 bucket name prefix
        domain: "your-domain.tld", // this needs to match your DNS tone name in Hetzner Console
        subdomain: "subdomain1", //  Adapt to avoid hitting Let's Encrypt rate limits. ("") to leave empty
        timezone: "Europe/Berlin",
        k3sClusterToken: projectConfig.requireSecret("k3sClusterToken"),
        // ⚠ THE CNI BOUNDS THIS, NOT k3s. Cilium 1.20.2 supports Kubernetes 1.33–1.36 only
        // (its own Documentation/network/kubernetes/requirements.rst; main tops out at 1.36
        // too, and 1.21.0 is still -pre). k3s v1.37.0+k3s1 exists and Renovate proposes it,
        // but taking it puts the CNI outside its support matrix — and on a recreate that is
        // wave 0, so everything else waits on it. v1.36.4 is the NEWEST 1.36 patch.
        // Bump past 1.36 only together with a Cilium release that lists the new minor.
        k3sVersion: "v1.36.4+k3s1", // renovate: datasource=github-releases depName=k3s-io/k3s versioning=loose
        targetState: "production" as TargetState, // lifetime variable set by the make scripts
        backupToS3IntervalHour: 3, // etcd + Longhorn backup interval in hours; 0 disables backup
        loadBalancerProvider: "k3s-servicelb" as LoadBalancerProvider,
        // derived — do not edit. updateConfigFromProjectSettings.sh derives the YAML-side tld
        // identically (it cannot see getters); the name matches the `general.tld` anchor.
        get tld(): string {
            return this.subdomain ? `${this.subdomain}.${this.domain}` : this.domain;
        },
    },
    // All Hetzner credentials in one place. Set via scripts/secrets/setHetznerCredentials.sh.
    hetzner: {
        // Hetzner Cloud API token (hcloud provider/CLI + CCM/CSI/external-dns/cert-manager).
        hcloudToken: projectConfig.requireSecret("hcloudToken"),
        // Hetzner Robot webservice credentials (dedicated servers; manual order, adopt by
        // serverId). Used only when the unified node list contains a provider:"robot" node.
        robotUser: projectConfig.getSecret("hetznerRobotUser"),
        robotPassword: projectConfig.getSecret("hetznerRobotPass"),
    },
    tls: {
        // ⚠ Nine anchor keys DERIVE from this one and exist nowhere in this file:
        // tls.{oidcSkipVerify,nodeTlsReject,verifySsl,grafanaSkipVerify,allowUnsecureCert,
        // curlInsecure,registryTlsVerify,oidcCaBundle,ryaxEnvironment}. Each is one app's
        // "trust the staging CA" switch, and each is a pure function of this value — storing
        // them here would be nine fields that must always agree with a tenth. They are
        // resolved in scripts/environment/applyProjectSettings.py (build_resolvers, "TLS
        // pseudo-keys"); grep there when an anchor names a tls.* key you cannot find here.
        // Their anchors name BOTH — `{tls.certIssuerType,tls.registryTlsVerify}` — so a line
        // says where its value comes from and which of the nine spellings it takes (`true`,
        // `1`, `True`, `""` and `letsencrypt-prod` all mean "prod").
        certIssuerType: "letsencrypt-prod" as CertType,
        // ACME account email — same identity as the service from/sender; getter reads the single
        // source of truth in mail.senderEmail (a later sibling, so it can't be referenced directly).
        letsEncrypt: {
            get email(): string {
                return project_settings.mail.senderEmail;
            },
        },
        wildcardTlsCert: projectConfig.getSecret("wildcardTlsCert"),
        wildcardTlsKey: projectConfig.getSecret("wildcardTlsKey"),
        sealedSecretsTlsCrt: projectConfig.requireSecret("sealedSecretsTlsCrt"),
        sealedSecretsTlsKey: projectConfig.requireSecret("sealedSecretsTlsKey"),
    },
    // Every cluster network range and address. Propagated to the YAML that cannot import TS
    // (wave8-headscale, mesh-gateway, kube-vip) via `network.<key>` anchors.
    network: {
        privateRange: "10.0.0.0/16",
        // The UMBRELLA range the mesh plane advertises (mesh-gateway, headscale route-approval,
        // kube-vip, mesh join scripts). It must cover BOTH subnets below — do NOT shrink it, or
        // mesh nodes lose their route to the CP apiservers at 10.0.0.x and 10.0.1.x.
        subnetRange: "10.0.0.0/23",
        // hcloud "server"-type NetworkSubnet (cloud VMs). Must NOT overlap vswitchRange —
        // Hetzner rejects overlapping subnets in one network.
        serverSubnetRange: "10.0.0.0/24",
        // hcloud "vswitch"-type NetworkSubnet — Robot boxes, bridged in via a Robot vSwitch.
        // Their privateIps live here. Only used when nodes.cloud has a provider:"robot" node.
        vswitchRange: "10.0.1.0/24",
        gateway: "10.0.0.1",
        // kube-vip virtual IP for the k3s API. Consumed by kube-vip/daemonset.yaml `address`
        // and the CP tls-san, and routed by a Hetzner network route (src/network.ts).
        //
        // ⚠ MUST be a /32 OUTSIDE both CP subnets: a VIP inside a subnet cannot be given a
        // Hetzner route ("ip range overlaps with existing subnetwork"). It sits in privateRange
        // but outside subnetRange/vpnSubnet/meshRange. The route gateway must be a cloud
        // server-subnet CP (Hetzner will not route onto the robot vSwitch segment), so only
        // cloud CPs hold the VIP — robot and mesh CPs use k3s-api.ts.internal instead.
        // See doc/kube-vip-cross-segment.md.
        vip: "10.0.3.100",
        // Stable k3s API hostname in the admin/provider kubeconfig and the CP tls-san. The
        // devcontainer resolves it via an /etc/hosts entry managed by setKubeApiHost.sh — the
        // init CP's PUBLIC IP during bring-up/teardown/breakglass, the VIP once the admin
        // WireGuard tunnel is up.
        //
        // ⚠ A NAME AND NOT AN IP because the Pulumi k8s provider's kubeconfig input must never
        // change content: a public→private endpoint flip would replace the provider and cascade
        // a replace onto EVERY k8s resource ("already exists" storm). This constant name keeps
        // the provider stable while the reachable IP changes underneath. MUST stay constant
        // across recreates, and is NOT derived from subdomain. Distinct from k3s-api.ts.internal
        // (headscale MagicDNS, the mesh-node join path).
        apiServerHost: "kubeapi.ecc.internal",
        // headscale/tailscale mesh prefix (mesh node VPN IPs). Matches wave8-headscale.yaml
        // `prefixes.v4`. The CP mesh↔private-network gateway SNATs across it so mesh nodes reach
        // the apiserver advertised on the private network, which is what gives the k3s agent
        // load-balancer its failover across control-plane nodes.
        meshRange: "10.0.10.0/23",
        // Tailscale WireGuard direct data port. Opened on the Hetzner firewall AND pinned on
        // tailscaled via --port (mesh-gateway daemonset) — otherwise tailscaled binds a random
        // port, no direct path forms, and mesh↔cloud is DERP-relay-only.
        tailscalePort: 41641,
        // k3s apiserver port — single source of truth for the many 6443 references in src/.
        k3sApiPort: 6443,
        // Admin WireGuard listen port. Single source of truth for the server's ListenPort/
        // hostPort, the client config's Endpoint and the firewall rule below; these must agree
        // or the tunnel silently never connects. Changing it invalidates every distributed
        // client config — re-fetch with scripts/runtime/getAdminWireguardConfig.sh.
        wireguardPort: 51820,
        cni: {
            // Pod CIDR — k3s `cluster-cidr`, and Cilium consumes the per-node PodCIDRs k3s
            // allocates from it. ⚠ Do NOT change: it is an explicit AD site-subnet object
            // (samba-ad/sites-job.yaml) and is in Zulip's trusted-proxy list; both mis-behave
            // silently if it moves.
            podCidr: "10.42.0.0/16",
            // Service CIDR — k3s `service-cidr`, declared explicitly because Cilium needs it.
            // ⚠ Must contain adDnsClusterIp below, which samba-ad pins.
            serviceCidr: "10.43.0.0/16",
            // Pinned ClusterIP of the cloud samba-ad DNS Service. DECLARED, not observed: the
            // on-prem DC consumes it as its DNS forwarder under dnsPolicy:None, so it must be
            // identical on every cluster — a randomly allocated address leaves the on-prem
            // bootstrap stuck in wait-domain with nothing pointing at DNS. On "provided IP is
            // already allocated", pick another free address inside serviceCidr; both consumers
            // are anchored to this value.
            adDnsClusterIp: "10.43.48.96",
            // Pinned ClusterIP of the cluster DNS Service (kube-dns). DECLARED, not observed,
            // and it is NOT free to choose: k3s hands kubelet `--cluster-dns` derived from
            // serviceCidr (the .10 address), and every pod's /etc/resolv.conf is written from
            // that. CoreDNS is ours rather than k3s's (see k3sDisableFlags), so its Service
            // must claim exactly this address or every pod in the cluster resolves against an
            // IP nothing is listening on. Changing it means changing kubelet's flag too.
            clusterDnsIp: "10.43.0.10",
            // VXLAN tunnel port — the IANA default, and what the mesh-gateway SNAT rule for
            // udp/8472 leaving tailscale0 matches on. Changing it means changing that rule too.
            tunnelPort: 8472,
            // The CNI's overlay devices, as nft iifname/oifname match strings. The only consumer
            // is the mesh_antiloop table (doc/network-firewall.md), which drops tailscale's UDP
            // port on them so a peer cannot pick a pod-overlay address as a WireGuard endpoint
            // and tunnel WireGuard inside the tunnel carrying it.
            //
            // ⚠ DELIBERATELY A SUPERSET, and that is load-bearing: nft matches by STRING, so a
            // device that does not exist yet simply never matches and the ruleset still loads —
            // which is what lets the table load before Cilium has created anything. It is
            // equally why a WRONG name here is SILENT: no error, no counter, just the recursion
            // flood back (500+ GB/node in hours). `lxc*` is an nft wildcard for the pod veths.
            //
            // Space-separated so the multi-value anchor pass can rewrite the whole quoted list
            // in one go; consumers turn it into an nft set.
            overlayInterfaces: "cilium_vxlan cilium_host cilium_net lxc*",
            // Cilium's MTU = the DEVICE MTU, not the usable pod MTU; Cilium derives the
            // pod-facing route MTU itself as device MTU - 50B VXLAN, on remote pod CIDRs only.
            //
            // ⚠ 1230 IS THE NUMBER THAT MUST NOT BE LOST. Cilium auto-detects ~1450 from the
            // primary NIC and knows nothing about the tailscale path. The binding constraint is
            // the mesh tier: tailscale0's WireGuard MTU is 1280 and VXLAN adds 50, so the device
            // MTU can be at most 1230. Unpinned, large frames (API watch streams, kubectl logs,
            // SA-token responses, Longhorn gRPC) are silently dropped while small ones pass — a
            // mesh node that is Ready with crash-looping pods.
            //
            // ⚠ DO NOT "correct" this to 1280 to match tailscale0. Pod→pod traffic to a remote
            // CIDR is VXLAN-encapsulated and THEN carried over WireGuard, so the budget is
            // 1280 - 50 - 50 and the real pod route MTU is 1180 on every remote path, cloud↔cloud
            // included. At 1280 the device would emit 1330-byte frames into a 1280-byte tunnel,
            // and Cilium runs with --enable-pmtu-discovery=false, so nothing would catch it.
            mtu: 1230,
        },
        // derived — do not edit. All CP mesh IPs in mesh-join order (init CP/cp1/cp2 = .1/.2/.3
        // in HA; just [init CP] otherwise). Published as the k3s-api.ts.internal A-record SET so
        // the k3s-agent client-LB fails over across live CPs. [0] is the init CP — it joins the
        // mesh first, so it deterministically takes the first host address and is the endpoint
        // mesh nodes and the CP tls-san use. See controlPlaneMeshIps() below.
        get cpMeshIps(): string[] {
            return controlPlaneMeshIps(this.meshRange, project_settings.highAvailability.enabled);
        },
        // What is reachable from the internet, for both enforcement layers: the hcloud Cloud
        // firewall (src/network.ts, hcloud VMs) and the host nftables allow-list
        // (publicGuardScript, src/nodes-k3s-common.ts), which is the ONLY enforcer on robot
        // boxes. Every targetState except "production" gets bringUpRules + alwaysRules.
        //
        // The Robot firewall deliberately does NOT consume these: its input chain caps at 10
        // rules, each needing an explicit ip_version (×2 families), and dst_port holds at most
        // 3 comma ports or one range — the list below needs 12. See robotFirewallEnsureScript.
        //
        // A getter, not a literal, so the rules can reference sibling fields (this.k3sApiPort,
        // this.privateRange) — project_settings is not assigned yet while it is being built.
        get firewall() {
            const anySource = ["0.0.0.0/0", "::/0"];
            return {
                // Ports needed to reach the cluster while it is being brought up, restored,
                // shut down or destroyed — i.e. before the VPN exists, or while it is going
                // away. Dropped in "production", where WireGuard is the only ingress.
                bringUpRules: [
                    {
                        direction: "in",
                        protocol: "tcp",
                        port: "22",
                        description: "SSH login",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "tcp",
                        port: `${this.k3sApiPort}`,
                        description: "Kubernetes API server",
                        sourceIps: anySource,
                    },
                    {
                        // NOT a public rule: private-network source only. The host nft guard
                        // filters the PUBLIC nic exclusively, so this is a no-op there; it
                        // matters for the hcloud firewall, which also sees private traffic.
                        direction: "in",
                        protocol: "tcp",
                        port: "2380",
                        description: "etcd peer (HA control plane, private network only)",
                        sourceIps: [this.privateRange],
                    },
                ],
                // Applied in EVERY targetState: HTTP(S), Jitsi media, and the VPN plane
                // (admin WireGuard + tailscale/headscale).
                alwaysRules: [
                    {
                        direction: "in",
                        protocol: "tcp",
                        port: "80",
                        description: "HTTP (Envoy Gateway, redirects to HTTPS)",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "tcp",
                        port: "443",
                        description: "HTTPS (Envoy Gateway TLS)",
                        sourceIps: anySource,
                    },
                    {
                        // Without this a default-drop blackholes Path-MTU discovery
                        // (fragmentation-needed / packet-too-big). The vSwitch VLAN runs at MTU
                        // 1400 and the pod network at 1230 over WireGuard, so PMTUD is load-bearing:
                        // dropping it yields intermittent stalls, not clean failures. It also
                        // keeps `ping` working, which the robot provisioner's own connectivity
                        // gate relies on. No port (hcloud requires one only for tcp/udp).
                        direction: "in",
                        protocol: "icmp",
                        description: "ICMP echo + PMTUD (fragmentation-needed / packet-too-big)",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "udp",
                        port: "10000",
                        description: "Jitsi Video Bridge ICE port",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "udp",
                        port: "3478",
                        description: "Jitsi Coturn STUN/TURN (media fallback)",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "udp",
                        port: `${this.wireguardPort}`,
                        description: "WireGuard VPN tunnel",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "udp",
                        // In the NodePort range: STUN is served source-IP-preserving by
                        // kube-proxy (headscale-stun NodePort svc, ETP Local) — klipper
                        // would masquerade and break reflexive-address discovery. Must
                        // match wave8-headscale.yaml service.derp.port and
                        // headscale/derp-stun-service.yaml nodePort.
                        port: "30478",
                        description:
                            "Headscale embedded DERP STUN (endpoint discovery for direct WireGuard paths)",
                        sourceIps: anySource,
                    },
                    {
                        direction: "in",
                        protocol: "udp",
                        // Must match the tailscaled --port in mesh-gateway/daemonset.yaml.
                        port: `${this.tailscalePort}`,
                        description:
                            "Tailscale WireGuard direct data port (NAT hole-punch; falls back to DERP if blocked)",
                        sourceIps: anySource,
                    },
                ],
            };
        },
    },
    wireguard: {
        subDomain: "wg",
        vpnSubnet: "10.0.2.0/24",
        serverAddr: "10.0.2.1/24",
        wgServerPrivateKey: projectConfig.requireSecret("wgServerPrivateKey"),
        wgServerPublicKey: projectConfig.requireSecret("wgServerPublicKey"),
        // One [Peer] per admin, each with its OWN keypair and its OWN /32.
        // WireGuard tracks a single endpoint per peer, so two clients sharing one key
        // steal the endpoint from each other: every handshake repoints return traffic at
        // the other client, which drops it. Measured 2026-09-05 with two devcontainers on
        // the shared admin key — rehandshake every 20s instead of 120s, 65-90% loss inside
        // the tunnel while the underlay showed 0%, and `Connection reset by peer` aborted
        // the production preflight. Distinct /32s are what let the server route replies back.
        //
        // ⚠ The private keys below are PLACEHOLDERS generated centrally. Each admin MUST
        // replace their own: run `wg genkey | tee priv | wg pubkey`, keep the private key
        // local, and hand over only the public key to be set here
        // (`pulumi config set --secret wgAdmin<N>PublicKey <key>`). Until then anyone with
        // the stack passphrase can impersonate that admin.
        admins: [
            {
                name: "admin1",
                addr: "10.0.2.2/32",
                privateKey: projectConfig.requireSecret("wgAdminPrivateKey"),
                publicKey: projectConfig.requireSecret("wgAdminPublicKey"),
            },
            {
                name: "admin2",
                addr: "10.0.2.3/32",
                privateKey: projectConfig.requireSecret("wgAdmin2PrivateKey"),
                publicKey: projectConfig.requireSecret("wgAdmin2PublicKey"),
            },
        ],
    },
    nodes: {
        cloud: [
            // Hetzner server types, for sizing a new cloud node:
            //   hcloud server-type list -o columns=name,location,cores,memory | awk '$2 ~ /fsn1/'
            //
            // Cost-Optimized:
            // CX23 (2CPU/4GB/40GB) 4€
            // CX33 (4CPU/8GB/80GB) 6,5€
            // CX43 (8CPU/16GB/160GB) 12€
            // CX53 (16CPU/32GB/320GB) 22,5€

            // regular performance:
            // CPX22 (2CPU/4GB/80GB) 8€
            // CPX32 (4CPU/8GB/160GB) 14€
            // CPX42 (8CPU/16GB/320GB) 25,5€
            // CPX52 (12CPU/24GB/480GB) 35,5€
            // CPX62 (16CPU/32GB/640GB) 50,5€

            // Geneneral Purpose:
            // CCX13 (2CPU/8GB/80GB) 16€
            // CCX23 (4CPU/16GB/160GB) 31,5€
            // CCX33 (8CPU/32GB/240GB) 62,49€

            // Locations: fsn1 (Falkenstein)  nbg1 (Nürnberg)  hel1 (Helsinki)
            // ⚠ SSD volumes must be in the same location as the nodes that use them.
            {
                // The cluster-init CP. A Robot box is ordered MANUALLY and adopted by serverId;
                // it is not in the hcloud API, hence the literal publicIp and the vSwitch fields.
                id: "dedicated0",
                description: "hetzner dedicated i7-7700 64gb 2x512gb",
                enabled: true,
                provider: "robot",
                k8sRole: "controlplane",
                clusterLink: "init",
                site: "hetzner-fsn1",
                os: "debian-13",
                image: "Debian 13", // installimage name, spelled differently from `os`
                location: "fsn1",
                serverId: 3022370,
                vlanId: 4000,
                privateIp: "10.0.1.2",
                publicIp: "203.0.113.10", // Robot boxes are not in the hcloud API
                publicIpv6: "2a01:4f8:120:81c5::2",
                ssh: { key: "sshkey-ecc-dedicated", port: 22, user: "root" },
                swap: 16,
                swapBehavior: "LimitedSwap",
                kvm: true, // bare metal
            },
            {
                id: "hcloud-cp0",
                enabled: false,
                provider: "hcloud",
                k8sRole: "controlplane",
                clusterLink: "direct",
                site: "hetzner-fsn1", // shared L2 for "direct": hcloud private net + Robot vSwitch
                os: "debian-13",
                location: "fsn1",
                serverType: "CPX32",
                privateIp: "10.0.0.2",
                ssh: { key: "sshkey-ecc-cloud", port: 22, user: "root" },
                swap: 16, // GiB
                swapBehavior: "LimitedSwap",
            },
            {
                id: "hcloud-cp1",
                enabled: false,
                provider: "hcloud",
                k8sRole: "controlplane",
                clusterLink: "direct",
                site: "hetzner-fsn1",
                os: "debian-13",
                location: "fsn1",
                serverType: "CPX32",
                privateIp: "10.0.0.3",
                ssh: { key: "sshkey-ecc-cloud", port: 22, user: "root" },
                swap: 16,
                swapBehavior: "LimitedSwap",
            },
            {
                id: "hcloud-cp2",
                enabled: false,
                provider: "hcloud",
                k8sRole: "controlplane",
                clusterLink: "direct",
                site: "hetzner-fsn1",
                os: "debian-13",
                location: "fsn1",
                serverType: "CPX32",
                privateIp: "10.0.0.4",
                ssh: { key: "sshkey-ecc-cloud", port: 22, user: "root" },
                swap: 16,
                swapBehavior: "LimitedSwap",
            },
            {
                id: "hcloud-w0",
                enabled: false,
                provider: "hcloud",
                k8sRole: "worker",
                clusterLink: "direct",
                site: "hetzner-fsn1",
                os: "debian-13",
                location: "fsn1",
                serverType: "CPX32",
                privateIp: "10.0.0.5",
                ssh: { key: "sshkey-ecc-cloud", port: 22, user: "root" },
                swap: 16,
                swapBehavior: "LimitedSwap",
            },
        ] as ComputeNodeCloud[],
        // On-premise machines adopted over SSH, joining over the headscale/tailscale mesh.
        // Pulumi does NOT create them, so enabled:false here is a pure provisioning pause.
        // Provisioned by a second pass (`make provision-mesh-node`), never by `make bootstrap`
        // — the VPN is not up until ~15 min after pulumi finishes.
        mesh: [
            {
                id: "unibi-hclab-pcie-tb-s",
                description:
                    "testbed server in hetComp Lab with PCIe gen6, Xeon Silver 4510 (12C/24T), 32 GB",
                enabled: false,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi", "unibi-ryax"],
                lanIp: "192.168.1.216",
                // Subnet router for the lab LAN: without it the cloud DC cannot replicate from
                // the on-prem DC, and no cluster pod can reach a LAN address. headscale holds
                // each advertised route DISABLED until an operator approves it.
                advertiseRoutes: ["192.168.1.0/24"],
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3001,
                    user: "cape",
                },
                kvm: true,
                nestedRuntime: "gvisor",
                edaBuilder: true,
                // ⚠ adDc REMOVED 2026-09-15: this box reboots every few hours and has been
                // NotReady since 23:00 with its DC pod Pending. A DC pinned to it is a
                // replica the directory cannot count on, and because the StatefulSet is
                // hostNetwork with hostname anti-affinity, that pod can never land
                // elsewhere — it just sits Pending. bender carries the third DC instead.
                // Restore this line once the hardware is fixed; see
                // doc/ad-identity-chain.md for the demote-FIRST procedure if a DC is ever
                // removed while its pod is RUNNING (it is not, here — it never started).
                // adDc: true,
            },
            {
                id: "unibi-hclab-pcie-tb-d",
                description:
                    "testbed desktop in hetComp Lab with PCIe gen6. Intel Core Ultra 7 265K LGA1551, GByte Z890, 2x16 GB RAM",
                // ⚠ DISABLED 2026-09-14: this box never joined — it is in
                // meshNodeProvisionSkip (unreachable at bootstrap) and `kubectl get node`
                // does not know it. Left enabled it still COUNTS toward the on-prem DC
                // replica count, which is anchored to the number of adDc nodes, so the
                // StatefulSet would ask for a DC that can never be scheduled. That is the
                // "one DC Pending" trap in CLAUDE.md. Re-enable when the box is back.
                enabled: false,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi", "unibi-ryax"],
                lanIp: "192.168.1.116",
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3002,
                    user: "cape",
                },
                kvm: true,
                nestedRuntime: "gvisor",
                edaBuilder: true,
                // The second on-prem DC. With only fs-vm carrying one, any maintenance on that
                // box was a site-wide auth outage with nothing left but the cloud DC over the
                // mesh. Here rather than pcie-tb-s (which hosts the desktop and the registry)
                // and not thor (arm64, and the GPU taint the DC pod does not tolerate).
                adDc: true,
            },
            {
                id: "unibi-hclab-bender",
                description: "COM-HPC server Icelake, Xeon D-1732TE (8C/16T), 256 GByte DDR",
                enabled: true,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi", "unibi-ryax"],
                lanIp: "192.168.1.192",
                // Subnet router for the lab LAN: without it the cloud DC cannot replicate from
                // the on-prem DC, and no cluster pod can reach a LAN address. headscale holds
                // each advertised route DISABLED until an operator approves it.
                advertiseRoutes: ["192.168.1.0/24"],
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3007,
                    user: "cape",
                },
                kvm: true,
                nestedRuntime: "gvisor",
                edaBuilder: true,
                // Third on-prem DC. Added 2026-09-14 because unibi-hclab-pcie-tb-s reboots
                // every few hours (host uptime 0.3h against 294h on fs-vm/thor), and with
                // only two ecc/ad-dc nodes ad-onprem-0 had nowhere to reschedule when that
                // node was cordoned — one flaky host was pinning a directory replica.
                // ⚠ pcie-tb-d is still listed adDc above but NO LONGER EXISTS in the
                // cluster, so the label set was really just {pcie-tb-s, fs-vm}.
                adDc: true,
            },
            {
                // VM on truenas
                id: "unibi-hclab-fs-vm",
                description: "AD/fileserver node, VM on the TrueNAS appliance",
                enabled: true,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi"],
                lanIp: "192.168.1.194", // the DHCP reservation keyed to host.mac below
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3004,
                    user: "cape",
                },
                kvm: false,
                adDc: true,
                host: {
                    kind: "truenas",
                    endpoint: "192.168.1.237", // automatically updated from project-settings:storage.fileserver.endpoint
                    pool: "datapool",
                    // ⚠ PIN THE MAC. TrueNAS assigns a fresh random one on every VM create, so a
                    // rebuild would lose the router's DHCP reservation and with it the epi:3004
                    // forward — the VM boots fine and is simply not where anything expects it.
                    mac: "00:a0:98:05:ef:59",
                    // names of the secrets, not the values — resolved from the Pulumi stack.
                    userNameKey: "truenasAdminUser",
                    passwordKey: "truenasAdminPassword",
                },
            },
            {
                id: "unibi-recslab-smartmirror1",
                description:
                    "Smartmirror in RECS lab (2x RTX 2070, Turing sm_75), i9-9900K (8C/16T), 32 GB",
                enabled: true,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-recslab",
                storageScope: ["unibi", "unibi-recslab", "unibi-ryax"],
                // Two spare 916 GiB Samsung 860 SSDs the cluster did not use: Longhorn saw
                // only the 457 GiB OS disk on a ~2.3 TiB machine. Both were already ext4 and
                // EMPTY (2 MiB, lost+found only); their fstab entries named UUIDs of disks
                // that no longer exist and survived only because of `nofail`.
                // Tags are inherited from storageScope above — the only shape guaranteed to
                // have both a StorageClass and a RecurringJob backup group behind it.
                extraLonghornDisks: [
                    { label: "storage1", path: "/mnt/storage1" },
                    { label: "storage2", path: "/mnt/storage2" },
                ],
                ssh: {
                    endpoint: "smartmirror1.ks.techfak.uni-bielefeld.de",
                    key: "sshkey-ecc-mesh",
                    port: 22,
                    user: "cape",
                },
                kvm: true,
                // Two SEPARATE 8 GiB cards, not a pooled 16 GiB: prefer 2 pods x 1 GPU over
                // tensor-parallel — BAR1 is hardware-capped at 256 MB, so P2P/NVLink is
                // impossible. sm_75 has no FP8 and no NVFP4, so the Thor's models do not port.
                gpu: "nvidia-turing-sm75",
                hardware: "nvidia-rtx-2070-x2",
            },
            {
                id: "unibi-recslab-orin-eval",
                description: "Nvidia Jetson Orin 32GB eval SoC in recs Lab",
                enabled: true,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-recslab",
                storageScope: ["unibi-recslab", "unibi"], // real, not decorative: the kernel rebuild provides CONFIG_ISCSI_TCP
                // A 465.8 GiB NVMe (ext4, label "storage") that the cluster would otherwise
                // ignore. It matters more here than on any other node: this box roots on a
                // 54 GiB eMMC that is ALREADY 69% full, so without this entry Longhorn would
                // put /var/lib/longhorn on the small, slow, low-endurance eMMC while 435 GiB
                // of NVMe sat empty.
                // Its fstab entry is correct and the mount is active (mnt-storage.mount), so
                // 06-prepare-longhorn-disks.sh finds a foreign entry for this mountpoint and
                // leaves it alone — it only ensures the mount, it does not take it over.
                // Tags inherit storageScope above.
                extraLonghornDisks: [{ label: "storage", path: "/mnt/storage" }],
                // ⚠ AND /var/lib/rancher goes on that same NVMe — the eMMC cannot host
                // container images. Measured 2026-09-23: the 54 GiB eMMC root sits at 82%
                // full (9.3 GiB free) with only ~1.5 GiB of that being images, so pulling
                // the ~8 GiB vLLM image filled the root to 100%, the kubelet raised
                // DiskPressure and evicted the pod, and a half-unpacked pull left 9.8 GiB of
                // orphaned containerd blobs pinned by a lease. Unlike the netboot node below
                // this box CAN host /var/lib/rancher on its root — it just has nowhere near
                // enough room, which is the same fix for a different reason.
                // Shares the disk with Longhorn above; the two use separate subdirectories,
                // and 05-prepare-data-disk.sh reuses the existing /mnt/storage mount instead
                // of mounting the device twice.
                k3sDataDisk: { label: "storage", subdir: "ecc-k3s" },
                ssh: {
                    endpoint: "smartmirror6.ks.techfak.uni-bielefeld.de",
                    key: "sshkey-ecc-mesh",
                    port: 22,
                    user: "cape",
                },
                kvm: true,
                // jetson-* takes the SoC path: the box must already be FLASHED with L4T (the
                // driver comes from the flash). Also stamps the ecc/gpu=true:NoSchedule taint,
                // so this scarce single-GPU box is opt-in only.
                gpu: "jetson-orin",
                hardware: "nvidia-jetson-orin",
            },
            {
                id: "unibi-hclab-thor-eval",
                description: "Nvidia Jetson Thor T5000 GPU eval SoC in hetComp Lab",
                enabled: true,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi"], // real, not decorative: the kernel rebuild provides CONFIG_ISCSI_TCP
                // No extraLonghornDisks, deliberately: checked 2026-09-22 and this box has no
                // spare drive. It roots on a 953.9 GiB NVMe with 656 GiB free, so
                // /var/lib/longhorn is already on fast, roomy storage — unlike the Orin, whose
                // root is a small eMMC. The sda/sdb devices visible here are Longhorn's own
                // iSCSI volumes (vendor IET, VIRTUAL-DISK), not physical disks.
                lanIp: "192.168.1.114",
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3006,
                    user: "cape",
                },
                kvm: true,
                // jetson-* takes the SoC path: the box must already be FLASHED with L4T (the
                // driver comes from the flash). Also stamps the ecc/gpu=true:NoSchedule taint,
                // so this scarce single-GPU box is opt-in only.
                gpu: "jetson-thor",
                hardware: "nvidia-jetson-thor",
            },
            {
                id: "home-martin-mini0",
                description:
                    "mini PC, Ryzen 5 PRO 5650GE (6C/12T), 24 GB; only accessible when connected via VPN to martin's home network",
                enabled: true, // only reachable on martin's home LAN; VPN down 2026-09-17
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "home-martin",
                storageScope: ["home-martin"], // single-node site → replica 1
                ssh: {
                    endpoint: "192.168.178.150",
                    key: "sshkey-ecc-mesh",
                    port: 22,
                    user: "cape",
                },
                kvm: true,
            },
            {
                id: "unibi-hclab-cape-vm",
                description: "transient testbed VM in hetComp Lab (Uni Bielefeld)",
                enabled: false,
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "unibi-hclab",
                storageScope: ["unibi-hclab", "unibi"],
                ssh: {
                    endpoint: "jump.your-domain.tld",
                    key: "sshkey-ecc-mesh",
                    port: 3003,
                    user: "cape",
                },
                kvm: true,
            },
            {
                id: "budapest-emdc-node7",
                description:
                    "only accessible when connected via VPN to the EMDC network in Budapest",
                enabled: false, // only reachable via budapest VPN
                k8sRole: "worker",
                clusterLink: "vpn",
                site: "budapest-emdc",
                storageScope: ["budapest-emdc"],
                ssh: {
                    endpoint: "192.168.22.104",
                    key: "sshkey-ecc-mesh",
                    port: 22,
                    user: "cape",
                },
                kvm: true,
                // Netboot live system: root is a squashfs+tmpfs overlay, and overlayfs cannot
                // be stacked, so k3s cannot host containerd's snapshotter there. Relocate
                // /var/lib/rancher onto the node-local NVMe. The subdir names us because that
                // partition is SHARED — it also carries another tenant's live-boot
                // persistence volume, which our provisioning never touches.
                k3sDataDisk: { label: "nodestorage-test", subdir: "unibi-testbed" },
            },
        ] as ComputeNodeMesh[],
    },
    // The HA intent flag plus every essential pod's replica count. src/*.ts read these via
    // haReplicas(); YAML/Helm gets the resolved integer through
    // `highAvailability.replicas.<key>` anchors — max when enabled, else min. The
    // `highAvailability.enabled` anchor additionally flips `enablePodAntiAffinity:` (that field
    // name is hardcoded in the script; there is no per-key affinity anchor).
    highAvailability: {
        // THE HA intent flag. Also sizes network.cpMeshIps (derived above). When true:
        // enforces ≥3 control-plane nodes at deploy time (src/storage.ts).
        // updateConfigFromProjectSettings.sh reads this `enabled:` value inside the
        // highAvailability block to resolve replica counts (max when true, else min).
        enabled: false,
        replicas: {
            cnpgOperator: { min: 1, max: 2 }, // CNPG operator (leader-elected); HA so a CP loss doesn't stall DB failover
            headscalePg: { min: 1, max: 3 }, // CNPG quorum (odd)
            authentikPg: { min: 1, max: 3 }, // CNPG quorum (odd)
            gitlabPg: { min: 1, max: 3 }, // CNPG quorum (odd)
            headplane: { min: 1, max: 1 }, // NOT scalable: RWO PVC → 2nd replica Multi-Attach fails. Pinned 1.
            grafana: { min: 1, max: 1 }, // NOT scalable: RWO PVC → 2nd replica Multi-Attach fails. Pinned 1.
            // Loki SimpleScalable. NB two related settings are NOT anchorable (the rewrite pass
            // only touches lines whose key is literally instances/replicas/replicaCount): the
            // chart's `replication_factor` (must rise with lokiWrite) and read/write/backend
            // HARD pod anti-affinity (replicas>1 needs that many schedulable nodes).
            // See doc/logging.md before flipping highAvailability.enabled.
            lokiWrite: { min: 1, max: 3 }, // ingesters — quorum, odd
            lokiRead: { min: 1, max: 3 }, // queriers
            lokiBackend: { min: 1, max: 3 }, // compactor/ruler/index-gateway — quorum, odd
            lokiGateway: { min: 1, max: 2 }, // nginx front for the read+write paths
            authentikRedis: { min: 1, max: 1 }, // TODO no redis HA wired up yet; left at 1
            seaweedfsMaster: { min: 1, max: 1 }, // 3 masters fail liveness (/cluster/status timeout) → CrashLoop. Durability is on Longhorn (see seaweedfs values). Pinned 1.
            seaweedfsVolume: { min: 1, max: 2 },
            seaweedfsFiler: { min: 1, max: 2 },
            argocdServer: { min: 1, max: 2 },
            argocdController: { min: 2, max: 2 }, // already 2; pinned stable
            argocdNotifications: { min: 1, max: 1 }, // singleton controller
            certManager: { min: 1, max: 2 },
            certManagerWebhook: { min: 1, max: 2 }, // admission path — most HA-relevant
            certManagerCainjector: { min: 1, max: 2 },
            sealedSecrets: { min: 1, max: 2 },
            // Cilium operator (leader-elected). Off the datapath — agents keep forwarding
            // without it — but it owns IPAM and CiliumIdentity GC, so while it is down no new
            // pod gets an IP. max 2 needs two schedulable control-plane nodes: the pods
            // declare host ports, so a surplus replica on a single-CP cluster sits Pending and
            // marks the app Degraded, which stalls the wave-1 barrier.
            ciliumOperator: { min: 1, max: 2 },
        } as Record<string, { min: number; max: number }>,
    },
    storage: {
        longhorn: {
            // Longhorn default-StorageClass replica target. "auto": min(3, cloudNodeCount).
            // 1|2|3: explicit override. Effective count derived in src/storage.ts. Pinned to 1
            // because the lean cloud tier (1 small CP + 1 small worker) can't hold a full mirror
            // of the ~270Gi the apps provision — replica=2 over-commits the worker disk
            // (DiskPressure → faulted volumes). Capacity/redundancy come from mesh nodes.
            replicaCount: 1 as LonghornReplicaCount,
        },
        objectStorage: {
            baseEndpoint: "nbg1.your-objectstorage.com",
            // ⚠ Pulumi-owned buckets ONLY — cluster infra that exists BEFORE ArgoCD:
            //   etcd           — k3s etcd-S3 snapshots (src/nodes-k3s-common.ts)
            //   longhornBackup — Longhorn BackupTarget (src/storage.ts)
            // Each ArgoCD-deployed app owns its own bucket(s) via an s3-buckets-job.yaml
            // co-located with its manifests; do NOT add app buckets here. Wipe every live
            // bucket with scripts/environment/deleteS3Buckets.sh.
            //
            // A getter so the names can be prefixed with general.name, which keeps them
            // constant across subdomain bumps. The local is named `clusterName` because that
            // is the token extract_bucket_name substitutes in generated manifests.
            get buckets() {
                const clusterName = project_settings.general.name;
                return [
                    { key: "etcd", name: `${clusterName}-etcd`, location: "nbg1" },
                    {
                        key: "longhornBackup",
                        name: `${clusterName}-longhorn-backup`,
                        location: "nbg1",
                    },
                ];
            },
            accessKey: projectConfig.requireSecret("hetznerS3AccessKey"),
            secretKey: projectConfig.requireSecret("hetznerS3SecretKey"),
        },
        // TrueNAS SCALE file server at the unibi lab. Joined to the Samba AD domain above as a
        // MEMBER server (NOT a DC — TrueNAS middleware exposes "join a domain", not "provision
        // a domain", and merging the DC and the file server would collapse the two failure
        // domains that Gate 4 passed *because* they are separate). Serves /home over NFSv4 to
        // the desktop pods and to users' laptops.
        //
        // Configured by the wave16-truenas ArgoCD app, whose Job MUST run on a node at the same
        // site: cloud pods cannot reach 192.168.1.0/24. Two independent things are needed for
        // cloud->lab traffic, and only ONE is missing:
        //   SERVED   — pcie-tb-s advertises 192.168.1.0/24 and headscale has it APPROVED and
        //              serving. This half works; do not "fix" it.
        //   INSTALLED— the cloud CP would need `--accept-routes` (RouteAll) to put the prefix in
        //              its table 52. It is deliberately OFF, because the flag is all-or-nothing:
        //              it would also install 10.0.0.0/23 (the cluster subnet range) and collapse
        //              etcd quorum once the CP set grows.
        // Symptom of the missing half: `ip route get 192.168.1.237` on the cloud CP resolves via
        // the PUBLIC gateway (178.xxx.xxx.xxx) and the packet dies in Hetzner's backbone — a wrong
        // route, not a firewall drop. So this is POLICY, not topology: reversible in principle,
        // but only by a cluster-wide change that the etcd design rejects. Treat as a hard
        // constraint.
        //
        fileserver: {
            // ⚠ ≤15 chars (NetBIOS limit) and MUST equal the appliance's Network → Global
            // Config hostname AND its Directory Services NetBIOS name. SMB clients strictly
            // validate Kerberos SPNs, so a mismatch does NOT fail at join — it fails later, at
            // mount time, as a Kerberos error that reads like a permissions problem.
            // ⚠ Baked into the machine account (FS-1$) at join, so renaming means leaving and
            // rejoining the domain, invalidating every SPN and exported keytab.
            // Named for the ROLE, not the product: the appliance could stop being TrueNAS
            // without the domain identity becoming a lie. The site is NOT encoded here —
            // `site` below is the only place that records it, so keep that accurate.
            hostname: "fs-1",
            // Matches the ecc/site node label and the AD site name (see sites-job.yaml).
            site: "unibi-hclab",
            // Management + API address — the appliance's `eno1` LAN IP, as a LITERAL. The AD
            // zone publishes the on-prem DC's MESH address, so resolving this by name would
            // route LAN traffic over the overlay.
            endpoint: "192.168.1.237",
            // Inbound port-forward to the appliance's WEB UI — a human's way in from outside
            // the lab LAN. Recorded here because it is in no DNS and derivable from nothing
            // else; no code reads it (every automated path uses `endpoint` over wss://).
            webUiForward: "http://jump.your-domain.tld:3005/",
            // The appliance's own hardware. Recorded because it is LAN-only and in no
            // inventory: the box is not a cluster node, so `kubectl get node` never sees
            // it, and the fs-vm guest reports a masked "QEMU Virtual CPU" that says
            // nothing about the host.
            cpu: "Intel(R) Xeon(R) CPU E3-1230",
            // The lab LAN in CIDR form — the ONLY network allowed to mount the NFS exports.
            // Load-bearing: the exports run maproot_user=root (required, or csi-driver-nfs
            // cannot mkdir a per-PVC subdirectory and every PVC sits Pending), so an export
            // open to the world would be a real exposure.
            labCidr: "192.168.1.0/24",
            // ⚠ NO CREDENTIALS HERE, deliberately. Username and password live ONLY in the
            // sealed secret that consumes them (truenas/truenas-secrets-sealed.yaml; the EDA
            // half uses its own scoped API key in eda/fileserver).
            pool: "datapool",
            // derived — do not edit. updateConfigFromProjectSettings.sh recomputes both with
            // the same rules, because getters are invisible to a regex-scraping script.
            get fqdn(): string {
                return `${this.hostname}.${project_settings.activeDirectory.adDomain}`; // fs-1.ad.base.internal
            },
            // The AD machine account created at join — uppercase + trailing `$`, the shape
            // `samba-tool computer list` prints.
            get machineAccount(): string {
                return `${this.hostname.toUpperCase()}$`; // FS-1$
            },
            // Datasets on `pool` above. Grouped here because they share the appliance, NOT
            // because anything provisions them centrally — each is owned by the app that
            // mounts it, so disabling that app stops re-asserting its storage:
            //   homes, shared         -> argocd-infra   (truenas/configure-job.yaml)
            //   eda, imageRegistry    -> argocd-apps    (eda/fileserver)
            //
            // ⚠ A PV's spec.persistentvolumesource is IMMUTABLE, so renaming a dataset here
            // takes effect only on the NEXT CLUSTER RECREATE; until then ArgoCD reports the
            // affected PVs OutOfSync and that drift is expected. NEVER delete a Bound PV to
            // force it — that detaches live data. And MOVE THE DATA on the appliance before
            // that recreate, or the new datasets start empty.
            datasets: {
                // Every user's /home. Consumed by csi-driver-nfs's `nfs-homes` StorageClass
                // (which templates a per-PVC subdirectory) and remote-desktop/nfs-homes-pv.yaml.
                //
                // ⚠ ONE dataset for ALL homes with per-user SUBDIRECTORIES, not a child dataset
                // per user: TrueNAS has a practical ceiling on dataset count and every child
                // multiplies replication and snapshot bookkeeping. Isolation comes from
                // AD-sourced POSIX ownership instead (uid = uidStartNumber + pk, mode 0700).
                //
                // ⚠ The one genuinely IRREPLACEABLE dataset here — both consumers are Retain for
                // that reason, and the export carries no uid/gid/mode mount options, since
                // flattening them would silently defeat the 0700 isolation.
                homes: {
                    dataset: "datapool/homes",
                },

                // Common area mounted at /shared by the remote desktop, unlike per-user `homes`.
                //
                // ⚠ ONE PARENT, TWO CHILDREN, separate datasets on purpose: a parent groups, it
                // does not merge. Differing policy is the only good reason for a dataset
                // boundary, and these differ — `data` is curated and must survive, `tmp` is
                // scratch that must NOT accumulate snapshots or replicate off-site. A
                // subdirectory could carry neither a separate quota nor a snapshot policy.
                shared: {
                    // Grouping only — deliberately NOT exported, or both children would be
                    // reachable through one path and the per-child boundary would be moot.
                    parent: "datapool/shared",
                    // Curated, root-owned; /shared/tools holds scripts delivered from git. Users
                    // read; only the desktop's PostSync job writes.
                    dataset: "datapool/shared/data",
                    // World-writable scratch at /shared/tmp, mode 1777 (sticky, like /tmp) — a
                    // user may delete their own files but not anyone else's. Sticky rather than
                    // per-user directories because AD accounts are not local uids on the appliance.
                    tmpDataset: "datapool/shared/tmp",
                    // ⚠ MANDATORY, not a nicety: this is the only world-writable dataset on the
                    // pool, so without a cap one runaway job fills `datapool` and takes homes and
                    // every EDA dataset with it. Exceeding it fails the WRITE, not the pool.
                    tmpQuota: "1T",
                },

                // ⚠ ONE PARENT, TWO CHILDREN, same shape and same reasoning as `shared` — the
                // policies differ, which is what earns the boundary:
                //   installers   regenerable      -> short retention, NOT replicated off-site
                //   moduleFiles  NOT regenerable  -> long retention, DO replicate off-site
                eda: {
                    // Grouping only — deliberately NOT exported (see shared.parent).
                    parent: "datapool/eda",
                    // Installer media, one directory per module family+version. This IS the
                    // installer-media store, so do not nest another eda/ inside it.
                    //
                    // ⚠ Named `installers`, NOT `artifacts`: "artifacts" is what GitLab CI calls
                    // the job-output mechanism this repo deliberately never uses (see
                    // gitlab/check-ci-artifacts.sh). The MOUNT PATH in the EDA pods is still
                    // /artifacts — a separate name, renamed separately if ever.
                    installers: "datapool/eda/installers",
                    // The EDA module MANIFEST store: <name>/<version>/module.yaml, nothing else.
                    //
                    // ⚠ THE BROKER'S AUTHORISATION BOUNDARY. Writing a file here is what permits
                    // the privileged remote-desktop broker to pull and run an image AS ROOT
                    // (broker.sh allowed(), fail-closed). Being a separate dataset does NOT make
                    // it a separate ACCESS boundary — NFS scopes by client network, and the
                    // broker and the [eda] runner share a node, so the server sees one source IP.
                    // The real boundary is WHICH PODS MOUNT IT: the broker sidecar only, via
                    // remote-desktop/registry-pv.yaml. Never mount it in the runner or the
                    // desktop container.
                    moduleFiles: "datapool/eda/modulefiles",
                    // BUILD OUTPUTS of the EDA projects — .xsa, bitstreams, BOOT.BIN, the
                    // packaged deployment/ set and build logs. Written by the CI build pod AND
                    // by users running a synthesis by hand on an interactive machine, so it is
                    // ONE SHARED export rather than per-user: a bitstream is a team output, and
                    // a build on one machine must be visible from the others.
                    //
                    // ⚠ NAMED `builds`, NOT `artifacts`. "Artifacts" is GitLab CI's job-output
                    // mechanism, which this repo deliberately does not use for bulk data —
                    // gitlab/check-ci-artifacts.sh enforces that and explains the measured cost
                    // (a lab-built output travels lab -> Workhorse in the CLOUD -> back to the
                    // appliance). Naming the dataset `artifacts` would invite exactly the wiring
                    // that check forbids. Same reasoning as `installers` above.
                    //
                    // ⚠ Its own dataset, not a subdirectory of anything: the policy is the
                    // OPPOSITE of homes/modulefiles. Build outputs are REGENERABLE from git plus
                    // a rebuild, so NO snapshots and NO off-site replication — and it needs its
                    // own quota, because one build is GB-scale (a Xilinx .xsa plus PetaLinux
                    // images). A subdirectory could carry neither.
                    //
                    // ⚠ Concurrent builds share it, so consumers MUST write under
                    // <project>/<branch>-<short-sha>/ and never to a fixed path.
                    builds: "datapool/eda/builds",
                },

                // Blob store for the lab-local OCI registry (argocd-apps/image-registry), which
                // exists because GitLab's S3-backed registry measured ~5.3 MB/s from the lab
                // against ~92/126 MB/s on the LAN. A SIBLING of eda, not a child: it also holds
                // the image archives of ollama, vllm and remote-desktop, none of them EDA tools.
                //
                // ⚠ NO GARBAGE COLLECTION, deliberately: `delete.enabled` is off and there is no
                // GC CronJob, so this store is APPEND-ONLY — overwriting a tag orphans the old
                // blobs and nothing reclaims them. EDA images are 20-40 GB each, so it WILL fill
                // and the failure lands mid-build. Prune by hand; see the app README.
                // ⚠ Never merge it with eda.moduleFiles: that would put root-execution authority
                // inside a volume a non-privileged pod mounts rw.
                imageRegistry: {
                    dataset: "datapool/images",
                },

                // Model weights for the LLM servers (vLLM on the Thor today; any future
                // engine on any GPU node). A SIBLING of imageRegistry, not a child: that one
                // is an OCI blob store written by the registry Deployment, this one holds
                // HuggingFace-format weight trees written by whichever server downloaded
                // them. Same appliance, unrelated lifecycles.
                //
                // ⚠ NAMED FOR WHAT IT HOLDS, not for its first consumer: `ai-models`, never
                // `vllm`. The same weights are usable by a different engine, and a second
                // engine must not have to mount something called after the first one.
                //
                // WHY IT EXISTS: an NVFP4 MoE checkpoint is ~23.4 GiB and the node-local
                // local-path PVC that used to hold it is wiped by a GPU-node reimage, after
                // which vLLM re-downloads the whole tree from HuggingFace over the mesh link.
                // Keeping it on the appliance makes that survivable.
                //
                // ⚠ It is a SEED, not the serve path — consumers copy from here to node-local
                // disk and load from there. vLLM mmaps its weight files, and mmap of a 23 GiB
                // safetensors tree over NFS is not something this project has measured; the
                // copy keeps the load path on local disk where it is known to work.
                //
                // ⚠ Regenerable (re-downloadable from HuggingFace), so NO off-site
                // replication and no long retention — same policy class as eda.builds, the
                // opposite of homes/modulefiles.
                aiModels: {
                    dataset: "datapool/ai-models",
                },
            },
        },
    },
    // Samba AD — the technical directory layer TrueNAS SCALE requires. Authentik stays the
    // source of truth for identity and provisions into this; Samba holds the NT hash and
    // Kerberos keys that SMB/NFS need and Authentik's LDAP outpost cannot provide.
    // Placement vocabulary: the label KEYS Pulumi writes onto nodes and the default
    // VALUES apps select on. THE ONLY DECLARATION of these strings — src/nodes-k3s-*.ts
    // imports `labels` to write them, deployment/** receives them through anchors
    // (# automatically updated from project-settings:applicationPlacements.*).
    //
    // ⚠ A literal "ecc/…" or a bare site name anywhere else is the drift this block exists
    // to prevent; scripts/environment/checkSiteAnchors.py fails the commit on one.
    applicationPlacements: {
        // Keys that appear in BOTH src/ and deployment/. Node metadata Pulumi alone reads
        // and writes (ecc/description, ecc/provision-fingerprint, ecc/hardware) is NOT here —
        // listing it would imply it is configurable. Neither are ecc/volume and ecc/seed,
        // which are deployment-only conventions on PVs and Authentik blueprints, not node
        // labels.
        labels: {
            site: "ecc/site",
            tier: "ecc/tier",
            mesh: "ecc/mesh",
            fileserverLan: "ecc/fileserver-lan",
            gpu: "ecc/gpu",
            gpuModel: "ecc/gpu-model",
            kvm: "ecc/kvm",
            edaBuilder: "ecc/eda-builder",
            adDc: "ecc/ad-dc",
            lanIp: "ecc/lan-ip",
            nestedRuntime: "ecc/nested-runtime",
            nestedRuntimeGvisor: "ecc/nested-runtime-gvisor",
        },

        // ⚠ site and storageScope are SEPARATE axes. unibi-hclab-pcie-tb-s has site
        // "unibi-hclab" and storageScope ["unibi-hclab", "unibi", "unibi-ryax"]. A scope can
        // span sites (cross-LAN redundancy, e.g. "unibi") and can also EXCLUDE nodes within
        // the sites it spans: "unibi-ryax" covers both Bielefeld LANs but only the four
        // machines Ryax may place replicas on. An app may want one axis and not the other.
        // Do not merge them, and do not derive one from the other — which scope serves a
        // site is a policy choice, not a fact.
        //
        // ⚠ NOT the fileserver's site. storage.fileserver.site is where the TrueNAS appliance
        // is, hence the only site where the csi-driver-nfs/-smb node DaemonSets run.
        // remote-desktop and eda-pcb-agent follow THAT and must keep doing so if the two
        // ever diverge.
        meshSite: "unibi-hclab",

        // ⚠ CHANGING THIS IS A DATA MIGRATION, NOT A CONFIG EDIT. It composes the
        // longhorn-<scope> StorageClass name, and storageClassName is immutable on a bound
        // PVC and on a StatefulSet's volumeClaimTemplates. A change makes ArgoCD fail the
        // sync with "field is immutable"; recovering a StatefulSet (rocketchat mongodb,
        // samba-ad) then needs delete --cascade=orphan + recreate. Every volume must be
        // backed up to S3 and restored onto the new class, or drained first.
        meshStorageScope: "unibi-hclab",

        // Ryax's OWN storage scope → StorageClass longhorn-unibi-ryax. Same immutability
        // warning as meshStorageScope above: changing it is a data migration, not a config
        // edit.
        //
        // Separate from meshStorageScope because Ryax is by far the largest tenant of the
        // `unibi-hclab` tag — 705 GiB of replica footprint (176 GiB logical × 3–4 replicas),
        // 400 G of it the action-builder nix-store alone. That tag is also carried by
        // unibi-hclab-fs-vm, a 57.7 G disk sharing it with 0.9–1.8 T peers, so Longhorn
        // treats the small disk as an equal replica candidate and it fills first. On
        // 2026-09-15 that took remote-desktop's Guacamole database down for ~4h: fs-vm hit
        // DiskPressure and refused a 5 G replica while 50% physically free.
        //
        // Carried by pcie-tb-s, pcie-tb-d, bender and smartmirror1. Deliberately NOT:
        //   fs-vm      — 57.7 G, smaller than a single 100 Gi nix-store replica, and the
        //                disk whose DiskPressure caused the incident above;
        //   thor-eval  — arm64, the only non-amd64 node in the fleet;
        //   the cloud/dedicated node — Ryax's engine storage is LAN-local by design
        //                (see ryax/admission-policies.yaml).
        // pcie-tb-d is currently `enabled: false` (never joined), so the live replica count
        // is 3, not 4 — it starts carrying replicas by itself once that box is back.
        //
        // ⚠ The name says `unibi`, not `unibi-hclab`, because smartmirror1 sits at
        // unibi-recslab: the pool spans BOTH Bielefeld LANs and replicates over WireGuard.
        // That is a deliberate trade, not an oversight — Longhorn acks a write only once
        // ALL replicas confirm, so every Ryax write waits on the recslab hop, and no Ryax
        // pod can ever read that replica locally (they are all pinned to
        // ecc/site=unibi-hclab). It buys a third replica in a second failure domain.
        // The rule it respects is that a pool never spans REGIONS: budapest-emdc and
        // home-martin keep their own scopes and never join this one.
        ryaxStorageScope: "unibi-ryax",

        // The cloud failure domain. Not derived from nodes.cloud[0].site: a mixed
        // fsn1/nbg1 fleet has more than one, and manifests want the one the app tier targets.
        cloudSite: "hetzner-fsn1",
    },

    //
    // There is deliberately no `enabled` flag: whether the DCs deploy is decided by the
    // presence of app-of-apps/wave13-samba-ad.yaml (rename to .yaml.disable to remove it).
    // A field that looks like a switch but that nothing reads is worse than no field.
    // DC PLACEMENT is likewise not here — it is a node property (`adDc` + `lanIp` on the mesh
    // nodes). One address in this block could only ever describe ONE DC.
    activeDirectory: {
        // Two-level AD label, typed by hand → zone ad.base.internal, realm AD.BASE.INTERNAL,
        // base DN dc=ad,dc=base,dc=internal.
        //
        // ⚠ SET ONCE AT DOMAIN PROVISION. Baked into sam.ldb, so changing it means wiping both
        // DCs and re-doing the Authentik sync + TrueNAS join. Deliberately NOT derived from
        // general.subdomain, which changes on every recreate.
        //
        // Two levels, not one: a bare "ad.internal" is the known-fragile two-label AD case for
        // some Windows/SMB clients, and .internal is shared. Must also avoid ecc.internal
        // (network.apiServerHost) and ts.internal (headscale MagicDNS) — a DC is authoritative
        // for its whole realm zone and would NXDOMAIN names those systems own.
        //
        // Brand-free on purpose: "base" names the role, so no rebrand can force a rename.
        adLabel: "ad.base",
        // NetBIOS domain (pre-Windows-2000 name), ≤15 chars — the name users type: `AD\alice`.
        // Samba uppercases it at provision time, so the case here is cosmetic. Same string as
        // adLabel's first label, which keeps that name as short as possible.
        //
        // ⚠ SET ONCE AT DOMAIN PROVISION, and NOT ANCHORED. It reaches Samba only via
        // samba-ad/sealSecrets.sh, so editing this line without re-sealing is a silent no-op
        // that surfaces at SMB mount time as a Kerberos error reading like a permissions
        // problem. Changing it for real is a full re-provision: new SIDs, every user, group and
        // machine account recreated.
        netbiosName: "ad",
        // Upstream resolver the on-prem DC forwards NON-AD names to (`dns forwarder` in
        // smb.conf). The lab LAN gateway today, but only its resolver role matters here.
        //
        // ⚠ WITHOUT one, Samba's internal DNS answers NXDOMAIN for every name outside the AD
        // zone — and NXDOMAIN is authoritative, so clients accept it instead of falling back to
        // their second nameserver. Every domain member pointed here (TrueNAS first) then loses
        // ALL external resolution while looking correctly configured. Empty restores that.
        //
        // Declared rather than read off the node: the DC pod has dnsPolicy None and its own
        // mount namespace, so it sees neither the node's resolv.conf nor its routing table.
        labDnsForwarder: "192.168.1.1",
        // uid/gid bases for the RFC2307 attributes written into AD. AD is the SINGLE source:
        // postsync-provision-users.yaml seeds uidNumber from uidStartNumber + the Authentik pk,
        // and every consumer reads that attribute. Never add a second component that COMPUTES a
        // uid from these bases — see doc/ad-identity-chain.md.
        uidStartNumber: 5000,
        gidStartNumber: 6000,
        // Pulumi config KEY NAME for the domain administrator password (never the value).
        adminPasswordKey: "sambaAdDomainAdminPassword",
        // derived — do not edit. updateConfigFromProjectSettings.sh recomputes these with the
        // same rules, because getters are invisible to a regex-scraping script.
        get adDomain(): string {
            return `${this.adLabel}.internal`; // ad.base.internal
        },
        get realm(): string {
            return this.adDomain.toUpperCase(); // AD.BASE.INTERNAL
        },
        get baseDn(): string {
            return this.adDomain
                .split(".")
                .map((label) => `dc=${label}`)
                .join(","); // dc=ad,dc=base,dc=internal
        },
    },
    mail: {
        // SMTP transport settings live in the Pulumi stack (set via scripts/secrets/setMail.sh):
        //   smtpServer, smtpPort, smtpUsername, smtpPassword, smtpNotifyRecipient
        // requireSecret so the hostname stays encrypted in Pulumi.mystack.yaml (public
        // repo). NB it's still published in the public SPF DNS record (see src/dns.ts).
        // smtpUsername/smtpPassword are the SMTP LOGIN credentials (not the from-address).
        smtpRelay: projectConfig.requireSecret("smtpServer"),
        smtpPort: projectConfig.requireSecret("smtpPort"),
        smtpUsername: projectConfig.requireSecret("smtpUsername"),
        smtpPassword: projectConfig.requireSecret("smtpPassword"),
        // Where cluster alert mail goes: the ArgoCD notification subscription and the
        // bootstrap-finished mail. src/argocd.ts turns these five into the argocd-infra
        // Secret `smtp-credentials` and into the `default` AppProject's subscription.
        notifyRecipient: projectConfig.requireSecret("smtpNotifyRecipient"),
        spfInclude: "",
        // Canonical service email — from/sender, admin/support contact, Let's Encrypt ACME
        // account (via tls.letsEncrypt.email getter), alert-recipient default. Plain literal,
        // single source of truth (NOT a Pulumi secret). updateConfigFromProjectSettings.sh bakes
        // it into manifests via the `automatically updated from project-settings:mail.senderEmail` anchor.
        senderEmail: "no-reply@your-domain.tld",
    },
    argocd: {
        git: {
            repoUrl: "git@github.com:YourProject/yourGit.git",
            targetRevision: "main",
            deployKey: projectConfig.requireSecret("argocdGithubDeployKey"),
        },
        serverSecretKey: projectConfig.requireSecret("argocdServerSecretKey"),
        adminPasswordPlain: projectConfig.requireSecret("argocdAdminPasswordPlain"),
        adminPasswordHash: projectConfig.requireSecret("argocdAdminPasswordHash"),
        adminPasswordMtime: projectConfig.requireSecret("argocdAdminPasswordMtime"),
        serverTlsCert: projectConfig.getSecret("argocdServerTlsCert"),
        serverTlsKey: projectConfig.getSecret("argocdServerTlsKey"),
    },
};

// Fail fast on a misconfigured cluster (exactly one clusterLink:"init" CP, unique ids
// across cloud+mesh, ≥1 control-plane, per-provider link legality). Runs at module load,
// before any component is built.
validateClusterNodes(project_settings.nodes.cloud, project_settings.nodes.mesh, {
    subnetRange: project_settings.network.subnetRange,
    serverSubnetRange: project_settings.network.serverSubnetRange,
    vswitchRange: project_settings.network.vswitchRange,
    meshRange: project_settings.network.meshRange,
    vip: project_settings.network.vip,
    gateway: project_settings.network.gateway,
});

// Fail fast on a misplaced on-prem AD DC (≥2 enrolled nodes, all at the fileserver's site,
// each with a unique lanIp inside the site LAN). Separate from validateClusterNodes because
// these are invariants BETWEEN nodes.mesh and fileserver, and because a misplaced DC is
// SILENT — it comes up Healthy and replicates fine while every SMB/NFS login fails.
validateAdPlacement(project_settings.nodes.mesh, {
    site: project_settings.storage.fileserver.site,
    labCidr: project_settings.storage.fileserver.labCidr,
});

// Fail fast on a placement default no enabled node satisfies — an unschedulable nodeSelector
// or a longhorn-<scope> StorageClass that is never created.
validatePlacementDefaults(
    project_settings.nodes.cloud,
    project_settings.nodes.mesh,
    project_settings.applicationPlacements,
);

// ─────────────────────────────────────────────────────────────────────────────
// Machinery — derivations and helpers. Not settings; you don't edit these. They are
// `function` declarations (hoisted) so the getters in the settings object above can call
// them even though they're defined here, at the end of the file.
// ─────────────────────────────────────────────────────────────────────────────

// Effective replica count for an essential pod: max when HA is enabled, else min.
// Pulumi components (src/*.ts) call this directly — they import this file, so there is
// no reason to bake a literal that the update script then has to patch. YAML/Helm
// manifests can't import TS, so those are still kept in sync by the anchor pass in
// scripts/environment/updateConfigFromProjectSettings.sh.
export function haReplicas(key: string): number {
    const { enabled, replicas } = project_settings.highAvailability;
    const r = replicas[key];
    if (!r) {
        throw new Error(`haReplicas: unknown key '${key}' (not in highAvailability.replicas)`);
    }
    return enabled ? r.max : r.min;
}

// nth host address of a CIDR (network address + n). Used to derive the deterministic
// control-plane mesh IPs from network.meshRange.
function nthHostOf(cidr: string, n: number): string {
    const [base] = cidr.split("/");
    const o = base.split(".").map(Number);
    const acc = (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] + n;
    return [(acc >>> 24) & 255, (acc >>> 16) & 255, (acc >>> 8) & 255, acc & 255].join(".");
}

// First usable host of a CIDR (".0" network -> ".1"). The init CP joins the mesh first and
// deterministically gets this address, so it can never drift from the prefix.
function firstHostOf(cidr: string): string {
    return nthHostOf(cidr, 1);
}

// All control-plane mesh IPs, in mesh-join order (init CP → .1, cp1 → .2, cp2 → .3).
// `allocation: sequential` (wave8-headscale.yaml) + the init CP always joining first makes these
// deterministic. HA → 3 CPs (.1/.2/.3); non-HA → only the init CP exists, so just [.1].
function controlPlaneMeshIps(meshRange: string, highAvailability: boolean): string[] {
    return highAvailability
        ? [nthHostOf(meshRange, 1), nthHostOf(meshRange, 2), nthHostOf(meshRange, 3)]
        : [firstHostOf(meshRange)];
}
