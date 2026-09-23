#!/bin/bash
# generateProvisioningScripts.sh — generate self-contained node scripts for manual provisioning.
#
# Runs on the devcontainer (needs kubectl + kubeconfig).
#
# Produces, in tmp/provisioning/ - the node-side steps, run in NUMBER order:
#   00-cleanup-node.sh            wipe stale state from a previously-destroyed cluster
#   05-prepare-data-disk.sh       OPTIONAL (--data-disk), for a node whose ROOT cannot host
#                                 /var/lib/rancher (netboot/live: overlayfs cannot stack)
#   10-install-prereqs.sh         Longhorn/iSCSI/NFS prereqs
#   20-install-gpu.sh             OPTIONAL (--gpu), before the join so containerd picks it up
#   30-connect-vpn.sh             headscale/tailscale registration
#   40-join-cluster.sh            k3s agent
#   50-install-nested-runtime.sh  OPTIONAL (--nested-runtime), after the join
# plus the two drivers that chain them:
#   provision-mesh-node-ssh.sh      (drive over SSH from the devcontainer)
#   provision-mesh-node-local.sh   (run ON the node, no SSH needed)
# and four unnumbered files, which are not steps in that sequence:
#   20a-install-gpu-soc.sh, 20b-install-gpu-pcie.sh   SOURCED by 20-install-gpu.sh, never run
#     on their own - hence its number plus a letter rather than numbers of their own.
#   rebuild-kernel-tegra.sh, verify-kernel-tegra.sh   Jetson only, and they straddle a REBOOT:
#     rebuild, reboot, verify, then re-run provisioning. The Pulumi path runs the rebuild
#     automatically and then stops on purpose; the reboot-and-verify half is always manual.
#
# NOT copied here - these run on the DEVCONTAINER, not on a node, and are prefixed `_local-`
# so they sort apart from the numbered node steps:
#   _local-fetch-cluster-inputs.sh    reads the live cluster for the join inputs (used below)
#   _local-cleanup-node-over-ssh.sh   pipes 00-cleanup-node.sh to a box over SSH
#
# Two ways to provision:
#   A) SSH-reachable node, drive from the devcontainer (scp's + runs the steps over SSH):
#        bash tmp/provisioning/provision-mesh-node-ssh.sh --name <id>      # see --help
#   B) No inbound SSH — copy tmp/provisioning/ to the node and run there:
#        sudo bash provision-mesh-node-local.sh --name <id>              # see --help / menu
#      then finish on the devcontainer: ./scripts/provisioning/adoptProvisionedNodes.sh (labels/scope)
#      (scripts/provisioning/copyProvisioningScripts.sh regenerates and delivers the folder over SSH)
#   Or run the steps by hand on the node, in the numbered order above.
#
# KEYLESS, ALWAYS. No pre-auth key is ever baked into the generated 30-connect-vpn.sh: the
# generator writes the ONDEMAND sentinel instead, so the node registers keyless, prints a
# one-time registration URL + QR, and stays PENDING until an operator approves it. Baking a
# reusable key into a script that travels to a node is deliberately not offered. (Pulumi's own
# provisioning substitutes a real key straight into src/provisioning-scripts/30-connect-vpn.sh
# via remote.Command; it does not use this generator, so that path is unaffected.)
#
# ⚠ THAT DOES NOT MAKE THE OUTPUT INERT — 40-join-cluster.sh still gets the REAL k3s
# node-token substituted below. What saves it is a second, independent layer:
# K3S_URL=https://k3s-api.ts.internal:6443 is a MagicDNS name resolvable only from INSIDE the
# tailnet, so the token is unusable until its holder has been approved into the tailnet by a
# human. Treat the output as a cluster-join credential regardless: mode 0600, hand over
# out-of-band, delete from the node after the join. Making the token opt-in (leave the
# placeholder, have the local driver acquire it at run time) is tracked in ToDo.md.
#
# Usage:
#   ./scripts/provisioning/generateProvisioningScripts.sh            # generate the keyless carry-scripts
#   ./scripts/provisioning/generateProvisioningScripts.sh --bundle   # + a single .tar.gz to carry away
#   ./scripts/provisioning/generateProvisioningScripts.sh --token    # print tailscale auth key only (debug)
#   ./scripts/provisioning/generateProvisioningScripts.sh --list-nodes  # + ready-to-run SSH lines
#   ./scripts/provisioning/generateProvisioningScripts.sh --qr       # display QR code (debug)
#
# --bundle additionally packs OUTPUT_DIR into tmp/provisioning-<subdomain>-<ts>.tar.gz with a
# SHA256SUMS beside it — one file to hand over (USB, another operator) instead of an scp -r of
# a directory. tar, NOT zip: every script in the bundle must stay executable and zip does not
# carry the mode portably, which would land the recipient on
# "bash: ./provision-mesh-node-local.sh: Permission denied".
#
# ⚠ A bundle is only valid for the cluster it was generated against — the k3s token and the
# headscale CA both change on a recreate. Regenerate after one.

set -euo pipefail

# Reject unknown FLAGS. A bare positional is ignored rather than rejected — only $1 is read,
# by the --token/--qr case below.
SHOW_INVOCATIONS=false
MAKE_BUNDLE=false
for a in "$@"; do
  case "$a" in
    --token|--qr)  : ;;   # CLI modes, handled below on $1
    --list-nodes)  SHOW_INVOCATIONS=true ;;
    --bundle)      MAKE_BUNDLE=true ;;
    --*)           echo "ERROR: unknown flag '$a' (valid: --token, --qr, --list-nodes, --bundle)." >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE_PROVISIONING_DIR="$ROOT_DIR/src/provisioning-scripts"
OUTPUT_DIR="$ROOT_DIR/tmp/provisioning"
# Declared in execution order; the file numbers encode the same order, so a new step slots
# in by number alone. Names are IDENTICAL to src/provisioning-scripts/ and to what the Pulumi
# path uploads — one name per file across the whole pipeline.
CLEANUP_SCRIPT="$OUTPUT_DIR/00-cleanup-node.sh"
DATADISK_SCRIPT="$OUTPUT_DIR/05-prepare-data-disk.sh"
PREREQ_SCRIPT="$OUTPUT_DIR/10-install-prereqs.sh"
GPU_SCRIPT="$OUTPUT_DIR/20-install-gpu.sh"
VPN_SCRIPT="$OUTPUT_DIR/30-connect-vpn.sh"
JOIN_SCRIPT="$OUTPUT_DIR/40-join-cluster.sh"
NESTED_SCRIPT="$OUTPUT_DIR/50-install-nested-runtime.sh"
SSH_DRIVER_SCRIPT="$OUTPUT_DIR/provision-mesh-node-ssh.sh"          # drive over SSH from the devcontainer
LOCAL_DRIVER_SCRIPT="$OUTPUT_DIR/provision-mesh-node-local.sh"    # run ON the node (no SSH)
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
NAMESPACE="${HEADSCALE_NAMESPACE:-headscale}"

# ── Resolve HEADSCALE_URL from project_settings.ts ───────────────────────────
# Read the `general.{domain,subdomain}` properties (not top-level consts — those
# don't exist). First match wins (general block precedes any other subdomain:).
BASE_DOMAIN=$(sed -n 's/^[[:space:]]*domain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
SUBDOMAIN=$(sed -n 's/^[[:space:]]*subdomain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
[ -n "$BASE_DOMAIN" ] || { echo "ERROR: could not parse general.domain from $PROJECT_SETTINGS_FILE" >&2; exit 1; }
HEADSCALE_URL="https://vpn.${SUBDOMAIN:+${SUBDOMAIN}.}${BASE_DOMAIN}"
export HEADSCALE_URL

# ── Verify kubectl ────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl not connected. Run: ./scripts/runtime/getKubeConfig.sh" >&2
  exit 1
fi

# ── Fetch cluster inputs via shared script ────────────────────────────────────
# _local-fetch-cluster-inputs.sh is the single source of truth for:
#   - minting the pre-auth key
#   - approving the subnet route
#   - reading k3s token + version
#   - building the CA cert bundle (incl. LE staging root)
# CP0_SSH_HOST is the CP0 public SSH address (for reading the k3s token).
# An empty jsonpath match still exits 0, so `||` never falls through — test the
# value instead. Dedicated/robot control-plane nodes have no ExternalIP (only
# InternalIP), so fall back to InternalIP when ExternalIP is absent.
CP0_PUBLIC_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
if [ -z "$CP0_PUBLIC_IP" ]; then
  CP0_PUBLIC_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
fi
[ -n "$CP0_PUBLIC_IP" ] || { echo "ERROR: could not resolve CP0 public IP" >&2; exit 1; }

export CP0_SSH_HOST="$CP0_PUBLIC_IP"
export MESH_TIER="${MESH_TIER:-on-premise-resident}"
export NAMESPACE

echo "Fetching cluster inputs (pre-auth key, token, CA cert)..."
bash "$NODE_PROVISIONING_DIR/_local-fetch-cluster-inputs.sh" >/tmp/_mesh_fetch_kv.txt || {
  echo "ERROR: _local-fetch-cluster-inputs.sh failed" >&2
  rm -f /tmp/_mesh_fetch_kv.txt
  exit 1
}

TS_AUTHKEY=$(grep '^MESH_TS_AUTHKEY=' /tmp/_mesh_fetch_kv.txt | cut -d= -f2-)
K3S_TOKEN=$(grep '^MESH_K3S_TOKEN=' /tmp/_mesh_fetch_kv.txt | cut -d= -f2-)
K3S_VERSION=$(grep '^MESH_K3S_VERSION=' /tmp/_mesh_fetch_kv.txt | cut -d= -f2-)
HEADSCALE_CA_B64=$(grep '^MESH_HEADSCALE_CA_B64=' /tmp/_mesh_fetch_kv.txt | cut -d= -f2-)
rm -f /tmp/_mesh_fetch_kv.txt

[ -n "$TS_AUTHKEY" ]  || { echo "ERROR: no MESH_TS_AUTHKEY in fetch output" >&2; exit 1; }
[ -n "$K3S_TOKEN" ]   || { echo "ERROR: no MESH_K3S_TOKEN in fetch output" >&2; exit 1; }

echo "k3s version: ${K3S_VERSION:-latest}"

# ── CLI modes ─────────────────────────────────────────────────────────────────
case "${1:-}" in
  --token)
    echo "$TS_AUTHKEY"
    exit 0
    ;;
  --qr)
    command -v qrencode &>/dev/null || {
      echo "qrencode not installed: apt install qrencode" >&2
      echo "Token: $TS_AUTHKEY"; exit 1
    }
    qrencode -t ANSI256 "${HEADSCALE_URL}?authkey=${TS_AUTHKEY}"
    echo ""
    echo "tailscale up --login-server $HEADSCALE_URL --authkey $TS_AUTHKEY"
    exit 0
    ;;
esac

# ── Parse nodes.mesh from project_settings.ts (for copy-paste hints only) ──────
# The generated provision script is fully CLI-driven and bakes in NOTHING; this parse is
# used ONLY to print ready-to-run invocation hints in the closing summary. Same one-pass
# perl parse as cleanupMeshNodes.sh, extended with site/kvm/description/storageScope.
# Emits one pipe-delimited record per node:
#   NAME|USER@HOST|PORT|SITE|KVM|DESCRIPTION|STORAGESCOPE_CSV|GPU
MESH_NODE_RECORDS=$(perl -0777 -ne '
    s{//[^\n]*}{}g;  # strip //-to-EOL comments so commented-out node blocks do not leak in
    if (/mesh:\s*\[(.*?)\]\s*as\s+ComputeNodeMesh/s) {
        my $blk = $1;
        # Depth-aware split into top-level { ... } node objects (each nests an ssh: { ... }).
        my @objs; my $depth = 0; my $cur = "";
        for my $ch (split //, $blk) {
            $depth++ if $ch eq "{";
            $cur .= $ch if $depth > 0;
            if ($ch eq "}") { $depth--; if ($depth == 0) { push @objs, $cur; $cur = ""; } }
        }
        for my $o (@objs) {
            my ($id)   = $o =~ /id:\s*"([^"]+)"/;
            my ($host) = $o =~ /endpoint:\s*"([^"]+)"/;  # ssh endpoint (hostname or IP)
            my ($port) = $o =~ /port:\s*(\d+)/;
            my ($user) = $o =~ /user:\s*"([^"]+)"/;
            my ($site) = $o =~ /site:\s*"([^"]+)"/;
            my ($kvm)  = $o =~ /kvm:\s*(true|false)/;
            my ($desc) = $o =~ /description:\s*"([^"]*)"/;
            my ($scopes) = $o =~ /storageScope:\s*\[([^\]]*)\]/;
            $scopes =~ s/"//g; $scopes =~ s/\s+//g if defined $scopes;  # -> csv
            my ($gpu)  = $o =~ /gpu:\s*"([^"]+)"/;
            # k3sDataDisk { label, subdir } -> "<label>:<subdir>" for --data-disk. Emitted
            # because a node that declares it CANNOT JOIN without the flag (overlayfs cannot
            # stack, so containerd never initialises) — a ready-to-run line that omitted it
            # would fail ~300s into the join.
            my ($ddl) = $o =~ /k3sDataDisk:\s*\{[^}]*label:\s*"([^"]+)"/;
            my ($dds) = $o =~ /k3sDataDisk:\s*\{[^}]*subdir:\s*"([^"]+)"/;
            my $datadisk = ($ddl && $dds) ? "$ddl:$dds" : "";
            next unless $id && $host;
            $port ||= 22; $user ||= "root"; $site ||= ""; $kvm ||= "false";
            $desc = defined $desc ? $desc : ""; $scopes = defined $scopes ? $scopes : "";
            $gpu = defined $gpu ? $gpu : "";
            print "$id|$user\@$host|$port|$site|$kvm|$desc|$scopes|$gpu|$datadisk\n";
        }
    }' "$PROJECT_SETTINGS_FILE")

[ -n "$MESH_NODE_RECORDS" ] || echo "NOTE: no mesh nodes parsed from project_settings.ts (invocation hints will be skipped)." >&2

# ── Generate scripts ──────────────────────────────────────────────────────────
# Wiped, not just re-populated: the folder is gitignored and survives across runs, so a
# script that is renamed or dropped stays behind and copyProvisioningScripts.sh happily ships
# the obsolete copy to a node alongside the current one.
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

cp "$NODE_PROVISIONING_DIR/00-cleanup-node.sh" "$CLEANUP_SCRIPT"
chmod +x "$CLEANUP_SCRIPT"

# Conditional step (like 20-install-gpu.sh): the driver runs it only when --data-disk is
# given. It always TRAVELS, because the generator emits one carry-script set for any node.
cp "$NODE_PROVISIONING_DIR/05-prepare-data-disk.sh" "$DATADISK_SCRIPT"
chmod +x "$DATADISK_SCRIPT"

cp "$NODE_PROVISIONING_DIR/10-install-prereqs.sh" "$PREREQ_SCRIPT"
chmod +x "$PREREQ_SCRIPT"

cp "$NODE_PROVISIONING_DIR/30-connect-vpn.sh" "$VPN_SCRIPT"
sed -i "s|HEADSCALE_URL_PLACEHOLDER|${HEADSCALE_URL}|g"      "$VPN_SCRIPT"
# Keyless-only: leave the ONDEMAND sentinel — never bake a key. The on-node script then
# registers keyless (PENDING) and is approved in the Headplane UI (2nd factor).
sed -i "s|TS_AUTHKEY_PLACEHOLDER|ONDEMAND_PLACEHOLDER|g"     "$VPN_SCRIPT"
sed -i "s|HEADSCALE_CA_B64_PLACEHOLDER|${HEADSCALE_CA_B64}|g" "$VPN_SCRIPT"
# Subnet routes are left EMPTY on this manual path. The generator emits ONE carry-script for
# any node (it takes no node argument), while advertiseRoutes is per-node in
# project_settings.nodes.mesh — so there is nothing to substitute here without guessing.
# A node that must act as a subnet router is normally provisioned by Pulumi, which fills this
# in from its own config. To do it by hand, set TS_ADVERTISE_ROUTES near the top of the
# generated 30-connect-vpn.sh before running it on the box (and remember the routes still need
# `headscale nodes approve-routes` afterwards).
sed -i "s|TS_ADVERTISE_ROUTES_PLACEHOLDER||g"                "$VPN_SCRIPT"
chmod +x "$VPN_SCRIPT"

# GPU host-enable step (no placeholders) — run only for --gpu nodes by the provision wrapper.
# The dispatcher SOURCES a per-hardware sibling (jetson-* => SoC, else discrete PCIe), so both
# siblings must travel with it under their repo names.
cp "$NODE_PROVISIONING_DIR/20-install-gpu.sh" "$GPU_SCRIPT"
cp "$NODE_PROVISIONING_DIR/20a-install-gpu-soc.sh" "$OUTPUT_DIR/20a-install-gpu-soc.sh"
cp "$NODE_PROVISIONING_DIR/20b-install-gpu-pcie.sh" "$OUTPUT_DIR/20b-install-gpu-pcie.sh"
chmod +x "$GPU_SCRIPT" "$OUTPUT_DIR/20a-install-gpu-soc.sh" "$OUTPUT_DIR/20b-install-gpu-pcie.sh"

# Jetson kernel rebuild + its post-reboot verifier. Copied for BOTH provisioning paths so the
# manual/carry-script route is not silently missing the fix that makes Cilium work on a
# Jetson (the stock L4T kernel lacks XFRM/xt_CT/TPROXY/CGROUP_NET_CLASSID, so the node joins
# Ready but no pod gets a network). Not chained automatically: a rebuild needs a REBOOT, and
# recovering from a bad Jetson kernel needs physical console access — so it is run
# deliberately, then verified, then provisioning is re-run.
#   sudo bash rebuild-kernel-tegra.sh --check-only  # is a rebuild needed at all?
#   sudo bash rebuild-kernel-tegra.sh               # rebuild (~10 min), then REBOOT
#   sudo bash verify-kernel-tegra.sh                # after the reboot; non-zero = do not join
# Roll back by swapping the files back (primary route — it works regardless of how the
# bootloader finds the kernel, which the extlinux menu has been observed not to):
#   sudo cp -a /boot/Image.backup /boot/Image && sudo cp -a /boot/initrd.backup /boot/initrd
#   sudo reboot
cp "$NODE_PROVISIONING_DIR/rebuild-kernel-tegra.sh" "$OUTPUT_DIR/rebuild-kernel-tegra.sh"
cp "$NODE_PROVISIONING_DIR/verify-kernel-tegra.sh" "$OUTPUT_DIR/verify-kernel-tegra.sh"
chmod +x "$OUTPUT_DIR/rebuild-kernel-tegra.sh" "$OUTPUT_DIR/verify-kernel-tegra.sh"

# Ship the README with the bundle so the folder that travels to the node (USB, scp) carries
# its own instructions — the operator on the node has no repo to read them from.
cp "$SCRIPT_DIR/README.md" "$OUTPUT_DIR/README.md"

# Nested-container runtime (gVisor) — run only for --nested-runtime nodes by the
# provision wrappers. Copied for BOTH provisioning paths: 50-install-nested-runtime.sh is
# the single source of truth for the handler install. Both paths must ship it, or a node
# reaches adoptProvisionedNodes.sh with NO nested runtime installed while still being labelled
# ecc/nested-runtime-*, and pods selecting that RuntimeClass hang in ContainerCreating.
# Idempotent, and it restarts the k3s-agent itself.
cp "$NODE_PROVISIONING_DIR/50-install-nested-runtime.sh" "$NESTED_SCRIPT"
chmod +x "$NESTED_SCRIPT"

cp "$NODE_PROVISIONING_DIR/40-join-cluster.sh" "$JOIN_SCRIPT"
sed -i "s|K3S_TOKEN_PLACEHOLDER|${K3S_TOKEN}|g"    "$JOIN_SCRIPT"
sed -i "s|K3S_VERSION_PLACEHOLDER|${K3S_VERSION}|g" "$JOIN_SCRIPT"
chmod +x "$JOIN_SCRIPT"

# Emit the fully parameter-driven provision script from a single quoted heredoc.
cat << 'SCRIPT_EOF' > "$SSH_DRIVER_SCRIPT"
#!/bin/bash
# provision-mesh-node-ssh.sh — provision ONE mesh node (SSH-join to the cluster).
# Generated by: scripts/provisioning/generateProvisioningScripts.sh
#
# All node identity/parameters are passed on the CLI (--name, --host, ...); nothing is baked
# in. Labels/annotations mirror the Pulumi MeshNodesComponent (incl. the ecc/provision-fingerprint
# stamp so a later `make provision-mesh-node` skip-check no-ops the node).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

usage() {
  cat <<USAGE
Provision one mesh node (SSH-adopt it into the cluster over the headscale VPN).

Usage:
  provision-mesh-node-ssh.sh --name <id> --host <addr> [options]
  provision-mesh-node-ssh.sh -h | --help

Required:
  --name <id>          Node name (becomes the k8s node name).
  --host <addr>        SSH host / IP of the node.

Connection:
  --port <n>           SSH port                          (default: 22).
  --user <name>        SSH user                          (default: root).
  --password <pw>      Authenticate with a PASSWORD instead of an ssh-agent key (needs
                       sshpass). Default without this flag is unchanged: agent keys.
                       ⚠ visible in your shell history — prefer --ask-password.
  --ask-password       Same, but prompt for the password (no echo, not in history).

  Either way the user still needs PASSWORDLESS sudo on the node (or use --user root):
  the password authenticates the SSH login only, never sudo. Checked upfront.

Metadata (become node labels/annotations; mirror the Pulumi path):
  --site <name>        ecc/site label (failure/latency domain).
  --kvm                Mark node KVM-capable (ecc/kvm=true).
  --no-kvm             Force KVM off (the default).
  --description <s>    ecc/description annotation.
  --scope <csv>        Longhorn storageScope tags, comma-separated (first = primary).
  --gpu <type>         GPU type (jetson-thor|jetson-orin|nvidia-turing-sm75). Runs the GPU host
                       install (nvidia-container-toolkit + k3s nvidia runtime) and sets
                       ecc/gpu=true + ecc/gpu-model=<type>, plus the
                       ecc/gpu=true:NoSchedule taint (GPU box is opt-in only).
                       Assumes JetPack (L4T) is pre-flashed.
  --data-disk <label>:<subdir>
                       ONLY for a node whose ROOT FILESYSTEM CANNOT HOST /var/lib/rancher —
                       a netboot/live box, where root is an overlay and overlayfs cannot be
                       stacked, so containerd's snapshotter never initialises and the k3s
                       join dies looping on "overlayfs snapshotter cannot be enabled".
                       Symlinks /var/lib/rancher into <subdir> on the filesystem labelled
                       <label> (blkid -L; a LABEL, since nvme enumeration is not stable).
                       <subdir> must name the owner — these disks are often shared, and
                       nothing outside it is touched. e.g. nodestorage-test:unibi-testbed
  --eda-builder        Mark this node an EDA image-build host (ecc/eda-builder=true) — what
                       the shared [eda] GitLab runner's node_selector matches. The node
                       must also be at the fileserver site, which is what grants
                       ecc/fileserver-lan=true (csi-driver-nfs runs only there).
  --nested-runtime <t> Nested-container runtime (gvisor). Installs the handler AND stamps
                       ecc/nested-runtime=<t> plus ecc/nested-runtime-gvisor=true.
                       ⚠ Install and label go together on purpose: a node labelled
                       without the handler installed hangs runsc pods in
                       ContainerCreating.

Behavior:
  --force              Re-provision even if the node is already registered/Ready
                       (drain + k3s-agent reinstall + Tailscale re-auth).

Examples:
  provision-mesh-node-ssh.sh --name unibi-hclab-vm0 --host jump.your-domain.tld \\
       --port 1717 --user cape --site unibi-hclab --scope unibi-hclab,unibi
  provision-mesh-node-ssh.sh --name unibi-hclab-vm0 --host 10.1.2.3 --force
USAGE
}

# ── Parse args ────────────────────────────────────────────────────────────────
NAME="" ; HOST="" ; PORT="" ; USER="" ; SITE="" ; DESCRIPTION="" ; SCOPES="" ; GPU=""
PASSWORD="" ; ASK_PASSWORD=false
NESTED="" ; EDA_BUILDER=false ; KVM="" ; FORCE=false ; DATA_DISK=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --name)        NAME="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --user)        USER="$2"; shift 2 ;;
    --site)        SITE="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --scope)       SCOPES="$2"; shift 2 ;;
    --gpu)         GPU="$2"; shift 2 ;;
    --data-disk)   DATA_DISK="$2"; shift 2 ;;
    --nested-runtime) NESTED="$2"; shift 2 ;;
    --eda-builder) EDA_BUILDER=true; shift ;;
    --kvm)         KVM="true"; shift ;;
    --no-kvm)      KVM="false"; shift ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --ask-password)  ASK_PASSWORD=true; shift ;;
    --force)       FORCE=true; shift ;;
    -*)            echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *)             [ -z "$NAME" ] && { NAME="$1"; shift; } || { echo "ERROR: unexpected arg '$1'" >&2; exit 2; } ;;
  esac
done

[ -n "$NAME" ] || { echo "ERROR: --name <id> is required." >&2; usage >&2; exit 2; }
[ -n "$HOST" ] || { echo "ERROR: --host <addr> is required." >&2; usage >&2; exit 2; }
PORT="${PORT:-22}" ; USER="${USER:-root}" ; KVM="${KVM:-false}"
case "$NESTED" in
  ""|gvisor) ;;
  *) echo "ERROR: --nested-runtime must be gvisor or empty (got '$NESTED')." >&2; exit 2 ;;
esac
# Validated here as well as in the local wrapper: an unvalidated typo runs 20-install-gpu.sh
# with a bad type AND lands on the node as ecc/gpu-model=<typo>, which then silently matches
# no GPU workload selector.
case "$GPU" in
  ""|jetson-thor|jetson-orin|nvidia-turing-sm75) ;;
  *) echo "ERROR: --gpu must be jetson-thor, jetson-orin, nvidia-turing-sm75, or empty (got '$GPU')." >&2; exit 2 ;;
esac
ADDR="${USER}@${HOST}"

# ── Auth mode: ssh-agent key (default) or password ───────────────────────────
# Default path is UNCHANGED: bare ssh/scp using whatever the agent holds (the Pulumi node
# keys loaded by scripts/pulumi/sshAgentHelpers.sh). --password/--ask-password wrap every
# hop in sshpass instead, for a box whose key is not (yet) deployed.
#
# PubkeyAuthentication=no + PreferredAuthentications=password are REQUIRED, not belt-and-
# braces: with an agent holding several keys, ssh offers them first and a box with
# MaxAuthTries=6 (the default) disconnects with "Too many authentication failures" before it
# ever reaches the password prompt — which reads as a wrong password rather than an
# exhausted key list.
#
# The password reaches sshpass through the environment (-e), never argv, so it does not
# appear in `ps`. It is NOT exported: the assignment is scoped to each sshpass invocation.
SSH_CMD=(ssh) ; SCP_CMD=(scp)
if [ "$ASK_PASSWORD" = "true" ] && [ -z "$PASSWORD" ]; then
  # -s: no echo. </dev/tty so this still works when the script's stdin is a pipe.
  printf 'SSH password for %s: ' "$ADDR" >&2
  read -r -s PASSWORD < /dev/tty ; printf '\n' >&2
  [ -n "$PASSWORD" ] || { echo "ERROR: empty password." >&2; exit 2; }
fi
if [ -n "$PASSWORD" ]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "ERROR: --password needs sshpass (apt-get install -y sshpass)." >&2; exit 2; }
  SSH_OPTS="$SSH_OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password"
  SSH_CMD=(env "SSHPASS=$PASSWORD" sshpass -e ssh)
  SCP_CMD=(env "SSHPASS=$PASSWORD" sshpass -e scp)
fi

# sudo on the node.
#
# We deliberately do NOT try to feed the password to sudo. The obvious route (SendEnv) is a
# trap: sshd only forwards variables its AcceptEnv lists, and the stock Debian/Ubuntu policy
# is `AcceptEnv LANG LC_* COLORTERM NO_COLOR` — so the variable is silently dropped and sudo
# then blocks on a prompt nothing answers, which reads as a hung provision rather than a
# config problem. Piping it on stdin instead collides with the steps that read stdin, and
# passing it in argv would expose it in the node's `ps`.
#
# So: NOPASSWD sudo (or --user root) is a REQUIREMENT of the SSH path, independent of how
# the SSH login itself authenticates. It is checked explicitly below rather than left to
# surface as a mid-run hang.
SUDO="sudo -n"
[ "$USER" = "root" ] && SUDO=""

echo ""
echo "══════════════════════════════════════════════════"
echo "  Node: $NAME  ($ADDR:$PORT)  site=${SITE:-<none>} kvm=$KVM scope=${SCOPES:-<none>} gpu=${GPU:-<none>} nested=${NESTED:-<none>} force=$FORCE"
echo "  Auth: $([ -n "$PASSWORD" ] && echo 'password (sshpass)' || echo 'ssh-agent key')"
echo "══════════════════════════════════════════════════"

# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" 'echo "SSH OK"'

# Preflight the sudo requirement (see the SUDO comment above). Every step below runs under
# sudo, so a box without NOPASSWD would otherwise fail several minutes in, at a prompt.
if [ -n "$SUDO" ]; then
  # shellcheck disable=SC2086
  "${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" 'sudo -n true' 2>/dev/null || {
    echo "ERROR: '$USER' has no passwordless sudo on $HOST." >&2
    echo "       Every provisioning step runs under sudo. Fix one of:" >&2
    echo "         - grant NOPASSWD:  echo '$USER ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/$USER" >&2
    echo "         - or connect as root:  --user root" >&2
    echo "         - or run ON the node:  provision-mesh-node-local.sh (sudo prompts work there)" >&2
    exit 2; }
fi

JOIN_FLAGS=""
[ "$FORCE" = "true" ] && JOIN_FLAGS="--force"
if kubectl get node "$NAME" &>/dev/null; then
  echo "Node $NAME already registered — cordoning and draining..."
  kubectl cordon "$NAME"
  kubectl drain "$NAME" --ignore-daemonsets --delete-emptydir-data \
    --grace-period=60 --timeout=120s || true
  JOIN_FLAGS="--force"
fi

# Delete any existing headscale machine entry named $NAME BEFORE the box re-registers.
# The re-join wipes tailscale state and re-registers with --hostname; headscale would otherwise
# keep the old record and de-dup the given name to $NAME-1, -2, … (orphan buildup). Deleting it
# first lets the fresh registration reuse the base name. VPN identity only — no k8s/box change.
# Same by-name delete as scripts/provisioning/decomissionNode.sh.
HS_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/name=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl get pods -n headscale -l app=headscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$HS_POD" ]; then
  HS_IDS=$(kubectl exec -n headscale "$HS_POD" -- headscale nodes list --output json 2>/dev/null \
    | NODE_ID="$NAME" python3 -c "
import sys, json, os
want = os.environ['NODE_ID']
data = json.load(sys.stdin)
nodes = data if isinstance(data, list) else data.get('nodes', [])
print(' '.join(str(n['id']) for n in nodes
      if (n.get('given_name') or n.get('givenName') or n.get('name')) == want))" 2>/dev/null || true)
  for HID in $HS_IDS; do
    echo "Deleting stale headscale entry id=$HID (name $NAME) before re-join…"
    kubectl exec -n headscale "$HS_POD" -- headscale nodes delete --identifier "$HID" --force >/dev/null 2>&1 || true
  done
fi

# Everything is copied UNCONDITIONALLY, not gated on $GPU/$NESTED: the optional steps are
# small, and an unconditional set keeps a later re-run with --gpu/--nested-runtime working
# without a re-copy.
#
# 20a/20b MUST travel with 20-install-gpu.sh. It does not run them, it SOURCES one of them
# (`. "$(source_path 20a-install-gpu-soc.sh node-15a.sh)"`), and it looks for them under
# their REPO names — which is why those two keep repo names in tmp/provisioning/ instead of
# being renumbered like the others. Omitting them made --gpu fail on the node with
# "cannot find 20a-install-gpu-soc.sh", after the VPN and cleanup steps had already run.
# shellcheck disable=SC2086
"${SCP_CMD[@]}" $SSH_OPTS -P "$PORT" \
  "$SCRIPT_DIR/00-cleanup-node.sh" \
  "$SCRIPT_DIR/05-prepare-data-disk.sh" \
  "$SCRIPT_DIR/10-install-prereqs.sh" \
  "$SCRIPT_DIR/20-install-gpu.sh" \
  "$SCRIPT_DIR/20a-install-gpu-soc.sh" \
  "$SCRIPT_DIR/20b-install-gpu-pcie.sh" \
  "$SCRIPT_DIR/30-connect-vpn.sh" \
  "$SCRIPT_DIR/40-join-cluster.sh" \
  "$SCRIPT_DIR/50-install-nested-runtime.sh" \
  "$ADDR":/tmp/

# Clean any stale state from a previously-destroyed cluster before joining.
# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} bash /tmp/00-cleanup-node.sh"
# Node whose ROOT cannot host /var/lib/rancher (netboot/live: overlayfs cannot stack, so
# containerd's snapshotter never initialises). AFTER the cleanup — which deletes
# /var/lib/rancher/k3s and would otherwise delete through a symlink just created — and
# BEFORE the join, so the path is already redirected when the agent installs.
if [ -n "${DATA_DISK// }" ]; then
  # shellcheck disable=SC2086
  "${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" \
    "${SUDO} env ECC_DATA_DISK_LABEL=${DATA_DISK%%:*} ECC_DATA_DISK_SUBDIR=${DATA_DISK#*:} bash /tmp/05-prepare-data-disk.sh"
fi
# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} bash /tmp/10-install-prereqs.sh"
# GPU host enablement (nvidia-container-toolkit + k3s nvidia runtime) BEFORE the k3s join,
# so the agent generates a containerd config that already has the nvidia runtime handler.
# No VPN dependency (it only reaches public NVIDIA apt repos), so it runs in file-number
# order, before connectVPN — same sequence on all three provisioning paths.
if [ -n "${GPU// }" ]; then
  # shellcheck disable=SC2086
  "${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} bash /tmp/20-install-gpu.sh"
fi
# ECC_NODE_NAME makes the tailnet name match the k8s node name (see 30-connect-vpn.sh).
# Passed inline rather than via SendEnv: sshd's stock AcceptEnv does not list it, so a
# forwarded variable would be silently dropped. The node name is not a secret.
# shellcheck disable=SC2029,SC2086
"${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} env ECC_NODE_NAME=${NAME} bash /tmp/30-connect-vpn.sh"
GPU_FLAG=""
[ -n "${GPU// }" ] && GPU_FLAG="--gpu=${GPU}"
# shellcheck disable=SC2029,SC2086
"${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} bash /tmp/40-join-cluster.sh --node-name=${NAME} ${GPU_FLAG} ${JOIN_FLAGS}"
# Nested-container runtime AFTER the join: the step writes a k3s containerd
# config-v3.toml.d drop-in and restarts k3s-agent, so the agent must already exist.
# Runs BEFORE the labels below — the handler must be on the box before the node advertises
# it, or pods selecting that RuntimeClass hang in ContainerCreating.
if [ -n "${NESTED// }" ]; then
  # shellcheck disable=SC2029,SC2086
  "${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "${SUDO} bash /tmp/50-install-nested-runtime.sh --runtime=${NESTED}"
fi

echo "Waiting for node $NAME to register..."
for i in $(seq 1 60); do
  kubectl get node "$NAME" &>/dev/null && break
  sleep 5
done
kubectl get node "$NAME" &>/dev/null || {
  echo "ERROR: node $NAME did not appear after 300s" >&2; exit 1
}

echo "Applying labels + Longhorn disk config to $NAME (mirrors the Pulumi path)..."
# node-role value is EMPTY (k8s reads only the key for the ROLE column) — matches
# MeshNodesComponent, so a subsequent `make provision-mesh-node` skip-check agrees.
LABELS=("node-role.kubernetes.io/mesh=" "node.kubernetes.io/mesh-worker=true")
[ -n "${SITE// }" ] && LABELS+=("ecc/site=${SITE}")
[ "${KVM}" = "true" ] && LABELS+=("ecc/kvm=true")
# Capability + model, and the opt-in taint — keep in step with the Pulumi path
# (src/nodes-k3s-mesh.ts) and adoptProvisionedNodes.sh.
[ -n "${GPU// }" ] && LABELS+=("ecc/gpu=true" "ecc/gpu-model=${GPU}")
# EDA image-build host — keep in step with src/nodes-k3s-mesh.ts and adoptProvisionedNodes.sh.
[ "$EDA_BUILDER" = "true" ] && LABELS+=("ecc/eda-builder=true")
# Nested-container runtime labels — keep in step with src/nodes-k3s-mesh.ts. The per-handler
# booleans are what the RuntimeClass nodeSelectors match on; ecc/nested-runtime is the
# human-readable summary.
if [ -n "${NESTED// }" ]; then
  LABELS+=("ecc/nested-runtime=${NESTED}")
  if [ "$NESTED" = "gvisor" ]; then LABELS+=("ecc/nested-runtime-gvisor=true"); fi
fi
kubectl label node "$NAME" "${LABELS[@]}" --overwrite
if [ -n "${GPU// }" ]; then
  kubectl taint node "$NAME" ecc/gpu=true:NoSchedule --overwrite
else
  kubectl taint node "$NAME" ecc/gpu- 2>/dev/null || true
fi

# Longhorn per-scope disk tags (first scope = primary), same shape as the Pulumi path.
DISK_TAGS=$(printf '"%s",' ${SCOPES//,/ }); DISK_TAGS="[${DISK_TAGS%,}]"
DISK_CFG="[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"tags\":${DISK_TAGS}}]"
kubectl label node "$NAME" node.longhorn.io/create-default-disk=config --overwrite
kubectl annotate node "$NAME" "node.longhorn.io/default-disks-config=${DISK_CFG}" --overwrite
[ -n "${DESCRIPTION// }" ] && kubectl annotate node "$NAME" "ecc/description=${DESCRIPTION}" --overwrite

# Stamp the box fingerprint so `make provision-mesh-node` sees the node as already
# provisioned. fpBox = sha256(JSON.stringify([id,host,port,user]))[:16] — port is a bare
# number (no quotes), matching the TS `sha` in nodes-k3s-mesh.ts.
FP=$(printf '["%s","%s",%s,"%s"]' "$NAME" "$HOST" "$PORT" "$USER" \
      | sha256sum | cut -c1-16)
kubectl annotate node "$NAME" "ecc/provision-fingerprint=${FP}" --overwrite
kubectl uncordon "$NAME" 2>/dev/null || true
echo "Node $NAME provisioned."
SCRIPT_EOF
chmod +x "$SSH_DRIVER_SCRIPT"

# ── Emit the LOCAL (on-node) provisioner ──────────────────────────────────────
# Self-contained: runs ON the node (no SSH). Chains the local numbered steps
# (cleanup -> prereqs -> vpn -> [gpu] -> join). Node identity/GPU come from CLI flags or an
# interactive menu. kubectl-side work (approval + labels/Longhorn/fingerprint) is NOT done here
# — the node has no kubectl — so it prints the exact devcontainer follow-up (adoptProvisionedNodes.sh).
cat << 'LOCAL_EOF' > "$LOCAL_DRIVER_SCRIPT"
#!/bin/bash
# provision-mesh-node-local.sh — provision THIS machine as a mesh node, run locally (no SSH).
# Generated by: scripts/provisioning/generateProvisioningScripts.sh
#
# Copy the whole tmp/provisioning/ folder to the node (e.g. USB), then run this here as root.
# It chains: 00-cleanup-node -> 10-install-prereqs -> [20-install-gpu] -> 30-connect-vpn
#            -> 40-join-cluster -> [50-install-nested-runtime].
# Settings come from CLI flags; anything missing is asked interactively (menu).
#
# After it finishes, complete adoption:
#   - if the scripts are keyless: approve this node's PENDING registration in the Headplane UI
#     (Machines → "Register machine": paste the URL/auth-id 30-connect-vpn.sh printed, pick user)
#   - then on the DEVCONTAINER (needs kubectl): ./scripts/provisioning/adoptProvisionedNodes.sh
#     → Apply labels / Longhorn storageScope / fingerprint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Root is required: every step script installs packages, writes /etc and restarts services.
# The re-exec happens AFTER argument parsing so --help never asks for a password.
#
# Deliberately NOT `sudo -E`: sudoers ships env_reset, so without an explicit SETENV tag
# `-E` is refused and prints "preserving the entire environment is not supported, '-E' is
# ignored" on every run. It also buys nothing here — the only variable the steps read
# (ECC_NODE_NAME) is set inline on the run_step call below, not inherited.
require_root() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: this script must run as root and sudo is not installed." >&2
    echo "       Re-run it as root:  su -c 'bash $0 <args>'" >&2
    exit 1
  fi
  # Probe first so the failure is a clear message rather than three password retries.
  if ! sudo -v; then
    echo "ERROR: cannot obtain root via sudo (wrong password, or this user is not a sudoer)." >&2
    exit 1
  fi
  echo "Re-executing as root via sudo..."
  exec sudo bash "$0" "$@"
}

usage() {
  cat <<USAGE
Provision THIS machine as a mesh node (run locally on the node — no SSH).

Usage:
  provision-mesh-node-local.sh [--name <id>] [--gpu <type>] [--nested-runtime <t>]
                               [--data-disk <label>:<subdir>]
  provision-mesh-node-local.sh -h | --help

Options:
  --name <id>    k8s node name (defaults to this host's hostname if omitted).
  --gpu <type>   GPU type (jetson-thor|jetson-orin|nvidia-turing-sm75): runs the GPU host install
                 (nvidia-container-toolkit + k3s nvidia runtime) BEFORE the k3s join.
                 Assumes JetPack (L4T) is pre-flashed.
  --data-disk <label>:<subdir>
                 ONLY for a node whose ROOT FILESYSTEM CANNOT HOST /var/lib/rancher — a
                 netboot/live box, where root is an overlay and overlayfs cannot be stacked,
                 so containerd's snapshotter never initialises and the k3s join dies looping
                 on "overlayfs snapshotter cannot be enabled". Symlinks /var/lib/rancher into
                 <subdir> on the filesystem labelled <label> (blkid -L; a LABEL, because
                 nvme enumeration is not stable). <subdir> must name the owner: these disks
                 are often shared, and nothing outside it is ever touched.
                 e.g. --data-disk nodestorage-test:unibi-testbed
  --nested-runtime <t>
                 Nested-container runtime (gvisor): installs the handler AFTER
                 the k3s join (it writes a k3s containerd drop-in and restarts the agent).
                 ⚠ The matching ecc/nested-runtime* LABELS are applied later by
                 adoptProvisionedNodes.sh — pass it the SAME value, or the node either advertises a
                 runtime it does not have (pods hang in ContainerCreating) or has one it
                 never advertises.
  --yes          Skip the final confirm prompt (non-interactive).

Anything not passed as a flag is prompted for: the node name, then yes/no for GPU support
(both default to no) and for the gVisor nested-container runtime. Answer those here — they
install software on this box around the k3s join and cannot be added later by
adoptProvisionedNodes.sh, which only applies labels.

The remaining node metadata (site / kvm / storageScope / description) IS applied later from
the devcontainer via adoptProvisionedNodes.sh — it needs kubectl, which this node does not have.
Until it runs, the node is tainted and unlabelled and nothing schedules on it.
USAGE
}

NAME="" ; GPU="" ; NESTED="" ; DATA_DISK="" ; ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --name)    NAME="$2"; shift 2 ;;
    --gpu)     GPU="$2"; shift 2 ;;
    --data-disk) DATA_DISK="$2"; shift 2 ;;
    --nested-runtime) NESTED="$2"; shift 2 ;;
    --yes)     ASSUME_YES=true; shift ;;
    *)         echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# Validate flag VALUES before anything interactive: a typo should fail immediately, not
# after the operator has answered the menu.
if [ -n "$DATA_DISK" ]; then
  case "$DATA_DISK" in
    *:*/*|*/*:*|:*|*:) echo "ERROR: --data-disk must be <label>:<subdir>, and <subdir> a single directory name (got '$DATA_DISK')." >&2; exit 2 ;;
    *:*) : ;;
    *)   echo "ERROR: --data-disk must be <label>:<subdir> (got '$DATA_DISK')." >&2; exit 2 ;;
  esac
fi

require_root "$@"

# ── Interactive prompts ───────────────────────────────────────────────────────
# Asked as yes/no with a NO default rather than as open value prompts: both features are
# opt-in and off on most nodes, so "GPU type [none]:" made an answer look mandatory. The
# GPU type is only asked once the operator has said yes.
#
# These MUST be answered here and cannot be deferred to adoptProvisionedNodes.sh, even though the
# matching LABELS come from that script. Both do real on-node work bracketing the k3s join:
# the GPU step installs nvidia-container-toolkit BEFORE the join so the agent generates a
# containerd config carrying the nvidia handler, and the nested-runtime step writes a
# containerd drop-in AFTER it and restarts the agent. adoptProvisionedNodes.sh only labels. Getting
# this wrong means re-running this script on the node.
#
# The name default is usually WRONG: it falls back to the box hostname, while the k8s node
# name comes from project_settings.ts (nodes.mesh[].id). A mismatch does not update the
# existing node — it creates a SECOND node object for the same machine (observed: one box
# joined as both home-martin-mini0 and minipc-martin).
_menu_shown=false
_menu_header() {
  [ "$_menu_shown" = "true" ] && return 0
  echo "── Mesh node settings (Enter accepts the [default]) ──"
  _menu_shown=true
}
if [ -z "$NAME" ]; then
  DEF_NAME="$(hostname)"
  _menu_header
  echo "   ⚠ Use the id from project_settings.ts nodes.mesh[].id, NOT the hostname,"
  echo "     unless they are the same. A mismatch does NOT update the existing node —"
  echo "     it creates a SECOND node object for this same box."
  printf "Node name [%s]: " "$DEF_NAME"; read -r NAME; NAME="${NAME:-$DEF_NAME}"
fi
# GPU: ask yes/no first, then the type. Only reached when --gpu was not given.
if [ -z "$GPU" ]; then
  _menu_header
  printf "Install GPU support (nvidia-container-toolkit + k3s nvidia runtime)? (y/N): "
  read -r _ans
  case "$_ans" in
    y|Y|yes|YES)
      # Loop until a valid type: a typo here would otherwise abort at the validator below,
      # after the operator has already answered everything else.
      while :; do
        printf "  GPU type (jetson-thor / jetson-orin / nvidia-turing-sm75): "
        read -r GPU
        case "$GPU" in
          jetson-thor|jetson-orin|nvidia-turing-sm75) break ;;
          *) echo "  ! not one of: jetson-thor, jetson-orin, nvidia-turing-sm75" ;;
        esac
      done ;;
    *) GPU="" ;;
  esac
fi
# Nested-container runtime. gvisor is the only supported handler, so a yes/no is the whole
# question — no follow-up type prompt.
if [ -z "$NESTED" ]; then
  _menu_header
  printf "Install nested-container runtime (gVisor/runsc, for running containers in pods)? (y/N): "
  read -r _ans
  case "$_ans" in y|Y|yes|YES) NESTED="gvisor" ;; *) NESTED="" ;; esac
fi
if [ "$GPU" = "none" ]; then GPU=""; fi   # `&&` form would abort under set -e when GPU != none
if [ "$NESTED" = "none" ]; then NESTED=""; fi

# Validate GPU value early (mirror the SSH wrapper's accepted set).
case "${GPU:-}" in
  ""|jetson-thor|jetson-orin|nvidia-turing-sm75) : ;;
  *) echo "ERROR: --gpu must be jetson-thor, jetson-orin, nvidia-turing-sm75, or empty (got '$GPU')." >&2; exit 2 ;;
esac
case "${NESTED:-}" in
  ""|gvisor) : ;;
  *) echo "ERROR: --nested-runtime must be gvisor or empty (got '$NESTED')." >&2; exit 2 ;;
esac

# Verify the step scripts sit next to this one.
for f in 00-cleanup-node.sh 10-install-prereqs.sh 30-connect-vpn.sh 40-join-cluster.sh; do
  [ -f "$SCRIPT_DIR/$f" ] || { echo "ERROR: missing $SCRIPT_DIR/$f (copy the whole tmp/provisioning/ folder)." >&2; exit 1; }
done
[ -z "$GPU" ] || [ -f "$SCRIPT_DIR/20-install-gpu.sh" ] || {
  echo "ERROR: --gpu given but $SCRIPT_DIR/20-install-gpu.sh is missing." >&2; exit 1; }
[ -z "$NESTED" ] || [ -f "$SCRIPT_DIR/50-install-nested-runtime.sh" ] || {
  echo "ERROR: --nested-runtime given but $SCRIPT_DIR/50-install-nested-runtime.sh is missing." >&2; exit 1; }
[ -z "$DATA_DISK" ] || [ -f "$SCRIPT_DIR/05-prepare-data-disk.sh" ] || {
  echo "ERROR: --data-disk given but $SCRIPT_DIR/05-prepare-data-disk.sh is missing." >&2; exit 1; }
# 20-install-gpu.sh sources one of these by repo name depending on the --gpu value.
if [ -n "$GPU" ]; then
  case "$GPU" in
    jetson-*) _gpu_sib="20a-install-gpu-soc.sh" ;;
    *)        _gpu_sib="20b-install-gpu-pcie.sh" ;;
  esac
  [ -f "$SCRIPT_DIR/$_gpu_sib" ] || {
    echo "ERROR: --gpu=$GPU needs $SCRIPT_DIR/$_gpu_sib (copy the whole tmp/provisioning/ folder)." >&2; exit 1; }
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Provision THIS node: $NAME   gpu=${GPU:-<none>}   nested-runtime=${NESTED:-<none>}"
echo "  data-disk: ${DATA_DISK:-<none, /var/lib/rancher stays on the root filesystem>}"
echo "  Steps: cleanup -> ${DATA_DISK:+data-disk -> }prereqs -> ${GPU:+gpu -> }vpn -> join${NESTED:+ -> nested-runtime}"
echo "══════════════════════════════════════════════════"
if [ "$ASSUME_YES" != "true" ]; then
  printf "Proceed? (y/N): "; read -r ok
  case "$ok" in y|Y|yes) : ;; *) echo "Aborted."; exit 0 ;; esac
fi

run_step() { echo ""; echo "=== $2 ==="; bash "$SCRIPT_DIR/$1"; }

run_step 00-cleanup-node.sh     "Clean stale cluster state"
# AFTER the cleanup (which deletes /var/lib/rancher/k3s and would otherwise be deleting
# through a symlink this step had just created) and BEFORE the join.
if [ -n "$DATA_DISK" ]; then
  ECC_DATA_DISK_LABEL="${DATA_DISK%%:*}" ECC_DATA_DISK_SUBDIR="${DATA_DISK#*:}" \
    run_step 05-prepare-data-disk.sh "Relocate /var/lib/rancher onto ${DATA_DISK%%:*}"
fi
run_step 10-install-prereqs.sh  "Install prerequisites"
# Guard the optional GPU step in an `if` (NOT `[ ... ] && run_step`): under `set -e` a
# short-circuited `&&` returns non-zero and would abort the whole script when GPU is empty.
if [ -n "$GPU" ]; then run_step 20-install-gpu.sh "GPU host enablement ($GPU)"; fi
# ECC_NODE_NAME keeps the tailnet name equal to the k8s node name (see 30-connect-vpn.sh);
# without it a box whose hostname differs registers under the hostname and collides on
# re-provision as <name>-1, -2, …
ECC_NODE_NAME="$NAME" run_step 30-connect-vpn.sh "Connect to the headscale VPN"

echo ""
echo "=== Join the cluster ==="
GPU_FLAG=""; [ -n "$GPU" ] && GPU_FLAG="--gpu=${GPU}"
# shellcheck disable=SC2086
bash "$SCRIPT_DIR/40-join-cluster.sh" --node-name="$NAME" $GPU_FLAG

# AFTER the join: the step writes a k3s containerd config-v3.toml.d drop-in and restarts
# k3s-agent, so the agent must already be installed.
if [ -n "$NESTED" ]; then
  echo ""; echo "=== Nested-container runtime ($NESTED) ==="
  bash "$SCRIPT_DIR/50-install-nested-runtime.sh" --runtime="$NESTED"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  On-node steps done for: $NAME"
echo "══════════════════════════════════════════════════════════════════"
echo "  ⚠ THE NODE $NAME IS NOT USABLE YET. It carries the ecc/mesh:NoSchedule taint with NO"
echo "  ecc/* labels and no Longhorn disk config, so nothing will schedule on it."
echo ""
echo "  This script cannot fix that: applying labels needs kubectl and a kubeconfig, which"
echo "  this node does not have. An admin must finish the adoption from the DEVCONTAINER:"
echo ""
echo "      ./scripts/provisioning/adoptProvisionedNodes.sh $NAME${NESTED:+ --nested-runtime $NESTED}"
echo ""
LOCAL_EOF
chmod +x "$LOCAL_DRIVER_SCRIPT"

# ── --bundle: one archive to carry away ─────────────────────────────────────────────────
# tar.gz, deliberately not zip: zip does not portably preserve the executable bit and every
# script here needs it — the recipient would unpack and hit "Permission denied" on the driver.
# `tar -C tmp` stores paths as provisioning/<file> so an unpack lands in its own directory
# rather than spraying the CWD.
BUNDLE_FILE=""
if [ "$MAKE_BUNDLE" = "true" ]; then
  _bundle_tag="${SUBDOMAIN:-$BASE_DOMAIN}"
  BUNDLE_FILE="$ROOT_DIR/tmp/provisioning-${_bundle_tag}-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar czf "$BUNDLE_FILE" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
  # ⚠ SENSITIVE: 40-join-cluster.sh carries the real k3s node-token (the tailscale side is
  # keyless, the k3s side is not). Anyone holding this archive AND an approved tailnet
  # membership can join a node to the cluster, so it is a credential, not just a script set.
  chmod 600 "$BUNDLE_FILE"
  ( cd "$(dirname "$BUNDLE_FILE")" && sha256sum "$(basename "$BUNDLE_FILE")" > SHA256SUMS )
  chmod 600 "$(dirname "$BUNDLE_FILE")/SHA256SUMS"
fi

echo ""
echo "Generated $(ls -1 "$OUTPUT_DIR" | wc -l) files in $OUTPUT_DIR"
echo "  headscale $HEADSCALE_URL   k3s ${K3S_VERSION:-latest}   keyless (approval required)"
if [ -n "$BUNDLE_FILE" ]; then
  echo ""
  echo "Bundle: $BUNDLE_FILE ($(du -h "$BUNDLE_FILE" | cut -f1))"
  echo "  ⚠ SENSITIVE — 40-join-cluster.sh embeds the k3s join token. Mode 0600; hand it over"
  echo "    out-of-band and delete it from the node once the join is done."
  echo "  ⚠ Valid ONLY for this cluster: the token and the headscale CA change on a recreate."
  echo ""
  echo "  On the node:"
  echo "      sha256sum -c SHA256SUMS      # copy it alongside the archive"
  echo "      tar xzf $(basename "$BUNDLE_FILE")"
  echo "      cd provisioning && sudo ./provision-mesh-node-local.sh --name <id>"
fi
echo ""
echo "Next:"
echo "  SSH-reachable   bash $SSH_DRIVER_SCRIPT --name <id> --host <addr>"
echo "  no inbound SSH  copy $OUTPUT_DIR/ to the node, run ./provision-mesh-node-local.sh there"
if [ "$MAKE_BUNDLE" != "true" ]; then
  echo "  --bundle                              pack it all into one .tar.gz to carry away"
fi
echo ""
echo "  $OUTPUT_DIR/README.md   full steps, incl. approval + adoption"
# The ready-to-run per-node lines are behind a flag: they are one long line per declared mesh
# node, which buried the two lines above under ~10 lines of near-identical text on every run.
if [ "$SHOW_INVOCATIONS" = "true" ]; then
  if [ -n "$MESH_NODE_RECORDS" ]; then
    echo ""
    echo "Ready-to-run, from project_settings.nodes.mesh:"
    while IFS='|' read -r name addr port site kvm desc scopes gpu datadisk; do
      [ -n "$name" ] || continue
      line="  bash $SSH_DRIVER_SCRIPT --name $name --host ${addr#*@} --port $port --user ${addr%@*}"
      [ -n "$site" ]   && line="$line --site $site"
      [ "$kvm" = "true" ] && line="$line --kvm"
      [ -n "$scopes" ] && line="$line --scope $scopes"
      [ -n "$gpu" ]    && line="$line --gpu $gpu"
      [ -n "$datadisk" ] && line="$line --data-disk $datadisk"
      echo "$line"
    done <<< "$MESH_NODE_RECORDS"
  else
    echo ""
    echo "  (no mesh nodes parsed from project_settings.ts)"
  fi
else
  echo "  --list-nodes                          ready-to-run SSH lines per declared mesh node"
fi
