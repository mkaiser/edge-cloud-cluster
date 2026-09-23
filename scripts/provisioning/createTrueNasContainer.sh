#!/bin/bash
# createTrueNasContainer.sh — create the Incus container on the TrueNAS appliance that
# will become a mesh k8s node (phase A of three).
#
# WHY A SCRIPT AND NOT AN ArgoCD JOB. This container is itself a Kubernetes node. A wave-16
# Job cannot create it, because on a cold start there is no cluster to run that Job — and
# wave 16 is documented as running strictly AFTER wave13-samba-ad, which would then be
# running INSIDE the thing wave 16 had not created yet. That circularity is not a detail to
# work around; it is why this is a bootstrap step, run by a human against an appliance that
# outlives any single cluster generation.
# It is also why it is not Pulumi: a failed `remote.Command` REJECTS ITS OUTPUTS and aborts
# the whole program ([[pulumi-failed-command-rejects-outputs]]), so an appliance hiccup
# would break `make destroy`/`up` for the entire cluster. The appliance is deliberately not
# coupled to cluster lifecycle.
#
# THE THREE PHASES, and this script is only the first:
#   A. THIS SCRIPT           create + start the container on the appliance
#   B. provisioning          scripts/provisioning/generateProvisioningScripts.sh, path B
#                            (no inbound SSH: copy tmp/provisioning/ into the container and
#                            run provision-mesh-node-local.sh there). Installs tailscale +
#                            k3s, registers KEYLESS -> approve in the Headplane UI.
#   C. adoption              scripts/provisioning/adoptProvisionedNodes.sh — labels, storageScope disk
#                            tags, provision fingerprint.
# B and C already exist and are unmodified by this work. Do not reimplement them here.
#
# ⚠ THE API CALL RUNS ON THE LAB LAN, NOT IN THE DEVCONTAINER.
# The appliance is on 192.168.1.0/24 and the devcontainer cannot route there. The headscale
# subnet route IS approved and serving; what is missing is `--accept-routes` (RouteAll) on
# the receiving side, deliberately off because it is all-or-nothing and would also install
# 10.0.0.0/23, collapsing etcd quorum. TWO transports satisfy that, picked automatically:
#   pod  — a Job pinned to ecc/fileserver-lan=true, exactly like truenas/configure-job.yaml.
#          Preferred when a cluster WITH a joined lab node is available.
#   ssh  — the same create.py, delivered over the epi.techfak relay to a lab box.
#          Needs ONLY the Pulumi stack (mesh SSH key + truenasAdmin{User,Password}).
# Override with FS_CONTAINER_TRANSPORT=pod|ssh.
#
# ⚠ THE SSH PATH IS NOT A FALLBACK OF CONVENIENCE — IT IS THE BOOTSTRAP PATH. This script
# exists because on a cold start there is no cluster to run an ArgoCD Job (see above), so
# requiring a healthy cluster to run it would contradict its own premise. A recreate is
# exactly when phase A is needed and exactly when no lab node has joined yet.
#
# ⚠ API NAMESPACE DEPENDS ON THE APPLIANCE VERSION, and this is the whole reason the script
# probes before it writes:
#     25.10 (Goldeye)   virt.instance.create   instance_type enum ["CONTAINER"] only;
#                                              devices INLINE; privileged_mode; image is a
#                                              string "ubuntu/noble/default"
#     26.0+             container.create       image is an OBJECT {name, version} named
#                                              "ubuntu:noble:amd64:default"; devices attach
#                                              AFTERWARDS via container.device.create;
#                                              capabilities_policy replaces privileged_mode
# `virt.*` is REMOVED in 26, not deprecated. Both are implemented below and the live method
# list decides which one runs — never the version string, and never the published docs
# (api.truenas.com's 25.10 index omits `virt.*` entirely while the appliance has 33 such
# methods, verified on the live appliance).
#
# ⚠ THE 26 BRANCH IS VERIFIED AGAINST 26.0.0-BETA.3 ON THE LIVE APPLIANCE, by
# creating a throwaway container and exercising each call. Four things cost attempts and are
# NOT guessable from the schema — change them only against a re-probe, not against docs:
#   1. `idmap` enum is DEFAULT | ISOLATED. There is NO "NONE", so privileged does NOT map to
#      an idmap value: `capabilities_policy: "ALLOW"` is the whole privilege lever.
#   2. container.device.create takes `container`, not `container_id`.
#   3. FILESYSTEM `source` MUST be an absolute /mnt/... path. The schema description says the
#      opposite ("must not start with /mnt/") and is simply wrong.
#   4. filesystem.put is NOT callable over JSON-RPC ("Pipe 'input' is not open") — it needs a
#      multipart POST to https://<host>/_upload with HTTP BASIC auth (Bearer and a form
#      auth_token field both 401), and `mode` must be an INT (0o755), not a string.
# Also: `status` changed shape (bare string -> {state,pid,domain_state}); see state_of().
#
# Usage:
#   ./scripts/provisioning/createTrueNasContainer.sh                 # create (idempotent)
#   ./scripts/provisioning/createTrueNasContainer.sh --show          # report state, change nothing
#   ./scripts/provisioning/createTrueNasContainer.sh --print-only    # emit the API payload, do not call
#   ./scripts/provisioning/createTrueNasContainer.sh --name fs-k8s-0 --memory 8 --cpu 4 --disk 60
#   ./scripts/provisioning/createTrueNasContainer.sh --image ubuntu:noble:amd64:default
#   FS_CONTAINER_TRANSPORT=ssh ./scripts/provisioning/createTrueNasContainer.sh   # no cluster needed
#   ./scripts/provisioning/createTrueNasContainer.sh --force         # DESTROYS and rebuilds it
#   ./scripts/provisioning/createTrueNasContainer.sh --force --yes   # ... without the prompt
#
# ⚠ --force (alias --recreate) DELETES THE CONTAINER AND EVERYTHING IN IT. Once phase B has
# run, that container IS a Kubernetes node: deleting it destroys its k3s identity, any
# Longhorn replicas it holds and any workload state on its root disk. It also leaves a
# STALE NODE in the cluster and a stale machine in headscale, neither of which this script
# cleans up — use scripts/provisioning/decomissionNode.sh for a real retirement.
# It prompts for confirmation unless --yes is given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
CONFIGURE_JOB="$ROOT_DIR/deployment/argocd-infra/truenas/configure-job.yaml"

# ── Defaults ─────────────────────────────────────────────────────────────────
# The k8s node name this container will carry. `<site>-<role><n>` per the mesh idiom in
# doc/mesh-node-management.md. It is NOT derived from fileserver.hostname: that is the
# APPLIANCE's AD identity (fs-1 / FS-1$) and must not be confused with a node running on it.
NAME="${FS_CONTAINER_NAME:-unibi-hclab-fs-container}"
# Ubuntu LTS to match the other mesh nodes (the provisioning scripts assume apt + systemd).
# `noble` rather than `resolute`: 50-install-nested-runtime.sh and the k3s install are
# exercised on LTS, and this box is meant to be boring.
# ⚠ THE IMAGE NAME DIFFERS BETWEEN THE TWO APIs and cannot be one string:
#     25.10  virt.instance.image_choices  -> "ubuntu/noble/default"        (os/release/variant)
#     26.0+  container.image.query_registry -> "ubuntu:noble:amd64:default" (colon + arch)
# Left EMPTY here and defaulted per detected flavour, so neither form is hardcoded into a
# run against the wrong appliance version. --image still overrides both.
IMAGE="${FS_CONTAINER_IMAGE:-}"
# Where the bootstrap payload lives ON THE APPLIANCE and where it appears INSIDE the
# container. Empty BOOTSTRAP_DIR = no bind-mount attached (the default; phase B is then a
# console step).
# ⚠ THIS ONLY ATTACHES THE MOUNT — IT DOES NOT UPLOAD ANYTHING. Populating the directory is
# a separate step (multipart POST to https://<appliance>/_upload calling filesystem.put; see
# the header note). Pointing this at an empty directory silently mounts an empty directory.
# ⚠ SOURCE MUST BE AN ABSOLUTE /mnt/... PATH. The schema's own description claims it "must
# not start with /mnt/", and that description is WRONG — the validator rejects a bare
# dataset path with "Source must be an absolute path" and accepts only /mnt/<pool>/...
# (verified against 26.0.0-BETA.3). Trust the validator, not the docstring.
BOOTSTRAP_DIR="${FS_CONTAINER_BOOTSTRAP_DIR:-}"
BOOTSTRAP_TARGET="${FS_CONTAINER_BOOTSTRAP_TARGET:-/opt/bootstrap}"
MEMORY_GB="${FS_CONTAINER_MEMORY_GB:-8}"
CPU_COUNT="${FS_CONTAINER_CPU:-4}"
DISK_GB="${FS_CONTAINER_DISK_GB:-60}"
NIC_PARENT="${FS_CONTAINER_NIC_PARENT:-eno2}"
# ⚠ THE ATTACH MODE IS NOT A SETTING — IT FOLLOWS FROM WHICH INTERFACE YOU NAME.
# `nic_attach` takes a bare interface name; a PHYSICAL iface (eno1/eno2) is macvlan-attached
# and a BRIDGE (truenasbr0) is bridge-attached. `container.device.nic_attach_choices()`
# reports the two lists. So point NIC_PARENT at a bridge when you want bridging — there is
# no separate mode flag to set.
# Why a physical iface by default: the container gets its OWN DHCP lease on the lab LAN
# (measured 192.168.1.183), where the built-in NAT network would put a k8s node behind NAT
# and break the mesh join.
# NIC_MODEL is the emulated CARD (the API's `type`), unrelated to the attach mode.
NIC_MODEL="${FS_CONTAINER_NIC_MODEL:-VIRTIO}"
POOL="${FS_CONTAINER_POOL:-datapool}"
MODE="create"
NAMESPACE="truenas"
ASSUME_YES="${FS_CONTAINER_ASSUME_YES:-false}"

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0; }

TRANSPORT="${FS_CONTAINER_TRANSPORT:-auto}"   # auto|pod|ssh; --via-cluster/--via-ssh override
while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)       MODE="show" ;;
    --print-only) MODE="print" ;;
    # --force is the documented spelling; --recreate is kept as an alias because it reads
    # better at a call site that means "rebuild this box". They are the SAME operation —
    # there is deliberately no weaker "force" that skips the idempotence check but keeps
    # the container, because the check is the only thing standing between a re-run and a
    # destroyed k8s node.
    --force|--recreate) MODE="recreate" ;;
    --yes|-y)     ASSUME_YES=true ;;
    # Force the k8s Job transport instead of letting pick_transport() choose. Kept because
    # it reads clearly at a call site that must NOT touch the ssh relay; --ssh is its twin.
    --via-cluster) TRANSPORT="pod" ;;
    --via-ssh)     TRANSPORT="ssh" ;;
    --name)   NAME="$2"; shift ;;
    --image)  IMAGE="$2"; shift ;;
    --memory) MEMORY_GB="$2"; shift ;;
    --cpu)    CPU_COUNT="$2"; shift ;;
    --disk)   DISK_GB="$2"; shift ;;
    --nic-parent) NIC_PARENT="$2"; shift ;;
    --bootstrap-dir)    BOOTSTRAP_DIR="$2"; shift ;;
    --bootstrap-target) BOOTSTRAP_TARGET="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }

# ── Transport selection ──────────────────────────────────────────────────────
# ⚠ THIS SCRIPT MUST WORK WITH NO CLUSTER. It is a BOOTSTRAP step — the whole argument in
# the header for why it is not an ArgoCD Job is that on a cold start there is nothing to run
# a Job. An implementation that then requires a healthy cluster contradicts its own premise,
# and a recreate is exactly when phase A gets run.
#
# So there are two transports to the appliance, and the k8s one is merely PREFERRED:
#   pod  — a Job pinned to ecc/fileserver-lan=true (what configure-job.yaml does). Needs a
#          cluster WITH a lab node joined.
#   ssh  — run the same python on a lab box over the epi.techfak forward. Needs only the
#          Pulumi stack: the SSH key and the appliance credential both live there
#          (truenasAdminUser / truenasAdminPassword).
# Either way the code executes ON THE LAB LAN, which is the actual requirement — the
# devcontainer cannot route to 192.168.1.0/24.
# (TRANSPORT is declared before the arg loop — see above — so --via-cluster/--via-ssh stick.)

pick_transport() {
  if [[ "$TRANSPORT" != "auto" ]]; then echo "$TRANSPORT"; return; fi
  if command -v kubectl >/dev/null && kubectl cluster-info &>/dev/null \
     && kubectl get nodes -l ecc/fileserver-lan=true -o name 2>/dev/null | grep -q node; then
    echo pod
  else
    echo ssh
  fi
}

# ── The appliance address, from project_settings ─────────────────────────────
# ⚠ THE LITERAL IP, deliberately — same value and reasoning as fileserver.endpoint: the AD
# zone publishes the on-prem DC's MESH address, so resolving the appliance by name would
# route LAN traffic over the overlay. Region-gated to the fileserver block because
# `endpoint:` is generic enough to collide with the mesh nodes' ssh blocks above it.
TN_ENDPOINT=$(perl -ne '
    if (/^\s*fileserver:\s*\{/) { $in = 1; next }
    if ($in && /^\s{4}\},/) { exit }
    if ($in && /^\s*endpoint:\s*"([^"]+)"/) { print "$1"; exit }
' "$PROJECT_SETTINGS_FILE")
[[ -z "$TN_ENDPOINT" ]] && { echo "ERROR: could not read fileserver.endpoint from project_settings.ts" >&2; exit 1; }

# The API client is NOT duplicated here. It is lifted from the ConfigMap in
# configure-job.yaml, which check-tnclient.sh already guards against drift — a third copy
# would need a third entry in that check.
[[ -f "$CONFIGURE_JOB" ]] || { echo "ERROR: $CONFIGURE_JOB not found" >&2; exit 1; }

echo "appliance : $TN_ENDPOINT"
# IMAGE may be empty here: it is defaulted per API flavour once the appliance has been
# probed (the two versions spell the same image differently), so say so rather than
# printing a blank.
echo "container : $NAME  (image ${IMAGE:-<per-version default>}, nic parent $NIC_PARENT)"
echo "sizing    : ${CPU_COUNT} cpu, ${MEMORY_GB}GiB, ${DISK_GB}GiB  (25.10 only — 26 sizes via cpuset)"
[[ -n "$BOOTSTRAP_DIR" ]] && echo "bootstrap : $BOOTSTRAP_DIR -> $BOOTSTRAP_TARGET"
echo "mode      : $MODE"
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$CONFIGURE_JOB" "$WORK/tnclient.py" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(src)):
    if d and d.get("kind") == "ConfigMap" and "tnclient.py" in (d.get("data") or {}):
        open(dst, "w").write(d["data"]["tnclient.py"])
        sys.exit(0)
sys.exit("ERROR: no tnclient.py ConfigMap in " + src)
PY

cat > "$WORK/create.py" <<'PYEOF'
"""Create the fileserver mesh-node container on the appliance.

Read before write, three outcomes (absent / drifted / correct), like configure.py — so a
second run is provably a no-op. NEVER create-and-ignore-the-error: that hides real
failures.
"""
import json, os, sys, time

sys.path.insert(0, "/src")
from tnclient import TrueNAS

HOST     = os.environ["TN_HOST"]
USER     = os.environ["TN_USER"]
PASSWORD = os.environ["TN_PASS"]
NAME     = os.environ["C_NAME"]
IMAGE    = os.environ["C_IMAGE"]           # may be "" -> defaulted per flavour
BOOTSTRAP_SRC    = os.environ.get("C_BOOTSTRAP_DIR", "")
BOOTSTRAP_TARGET = os.environ.get("C_BOOTSTRAP_TARGET", "/opt/bootstrap")
# Resolved at preflight from the registry (26) — the newest published build date.
IMAGE_VERSION = None
MEMORY   = int(os.environ["C_MEMORY_GB"]) * 1024**3
CPU      = os.environ["C_CPU"]
DISK     = int(os.environ["C_DISK_GB"])
NIC      = os.environ["C_NIC_PARENT"]
NIC_MODEL = os.environ.get("C_NIC_MODEL", "VIRTIO")
POOL     = os.environ["C_POOL"]
MODE     = os.environ["C_MODE"]


def api_flavour(tn):
    """Which virtualization namespace does THIS appliance actually have?

    ⚠ DECIDED FROM THE LIVE METHOD LIST, NEVER FROM THE VERSION STRING OR THE DOCS.
    `virt.*` is removed in 26 and replaced by `container.*` with a DIFFERENT schema, and
    the published 25.10 index omits `virt.*` even though the appliance has 33 such methods.
    A version-string check would be wrong in both directions.
    """
    methods = set((tn.rpc("core.get_methods") or {}).keys())
    if "container.create" in methods:
        return "container"
    if "virt.instance.create" in methods:
        return "virt"
    raise RuntimeError(
        "appliance exposes neither container.create nor virt.instance.create — "
        "cannot create a container on this version")


def query(tn, flavour):
    if flavour == "container":
        rows = tn.rpc("container.query", [[["name", "=", NAME]]])
    else:
        rows = tn.rpc("virt.instance.query", [[["name", "=", NAME]]])
    return rows[0] if rows else None


def build_payload(flavour):
    """The create payload for whichever API this appliance has.

    ⚠ NETWORKING: MACVLAN on a spare physical NIC, not the default bridge.
    The default virt network is 10.203.214.0/24 and it is NAT'd — a k8s node behind NAT
    cannot be reached by the cluster and the mesh join would not work. MACVLAN puts the
    container directly on the lab LAN with its own address.
    ⚠ OPEN QUESTION, NOT YET MEASURED: whether a macvlan-attached container can reach the
    APPLIANCE ITSELF (192.168.1.237). The macvlan driver isolates a child from its parent
    interface, which would stop it mounting the appliance's own NFS exports. But this
    appliance has TWO NICs on the same subnet (eno1 .237 / eno2 .238) and the container is
    attached to eno2, so the traffic may leave to the switch and come back to eno1 as a
    genuinely separate port. Nobody has tested it: every attempt so far needed a shell
    inside the container, which TrueNAS 26 does not expose (no exec API).
    TEST IT BEFORE RELYING ON EITHER ANSWER. If it turns out isolated, attach to a BRIDGE
    instead — set NIC_PARENT to truenasbr0 (it already exists on this box); there is no
    mode flag to flip.

    ⚠ PRIVILEGED: kubelet needs it. cgroup writes, /dev/kmsg and module visibility all fail
    in an unprivileged Incus container. On 26 the equivalent spelling is
    idmap=NONE + capabilities_policy=ALLOW.
    """
    if flavour == "virt":
        return {
            "name": NAME,
            "instance_type": "CONTAINER",   # 25.10 enum is ["CONTAINER"] only; VMs are vm.*
            "source_type": "IMAGE",
            "image": IMAGE,
            "remote": "LINUX_CONTAINERS",
            "cpu": str(CPU),
            "memory": MEMORY,
            "root_disk_size": DISK,
            "storage_pool": POOL,
            "autostart": True,
            "privileged_mode": True,
            "devices": [{
                "dev_type": "NIC",
                "name": "eth0",
                "nic_type": "MACVLAN",
                "parent": NIC,
            }],
        }
    # 26+ container.create. VERIFIED against 26.0.0-BETA.3 by creating a throwaway
    # container on the live appliance — not from docs, which are wrong about
    # this API in at least one load-bearing place (see the FILESYSTEM note in attach_devices).
    #
    # ⚠ NO `idmap: NONE`. The enum is DEFAULT | ISOLATED and NOTHING ELSE — there is no
    # NONE, so the 25.10 `privileged_mode: True` does NOT map onto an idmap setting.
    # `capabilities_policy: "ALLOW"` is the ENTIRE privilege lever on 26, and it is what
    # kubelet needs (cgroup writes, /dev/kmsg, module visibility). Confirmed accepted at
    # create and readable back from container.query afterwards.
    #
    # ⚠ NO `devices` KEY AND NO cpu/memory/root_disk_size. container.create takes
    # name/image/pool/autostart/description/uuid/time/init*/idmap/capabilities_*/cpuset/
    # shutdown_timeout — devices are attached AFTERWARDS via container.device.create, and
    # sizing is cpuset (pinning) rather than a cpu count. Passing the 25.10 keys here is
    # rejected outright, so they are deliberately absent rather than "harmlessly ignored".
    #
    # image is an OBJECT: the registry names images `<os>:<release>:<arch>:<variant>` and
    # versions them by build date. IMAGE_VERSION resolves to the newest at preflight.
    return {
        "name": NAME,
        "image": {"name": IMAGE, "version": IMAGE_VERSION},
        "autostart": True,
        "pool": POOL,
        "capabilities_policy": "ALLOW",
    }


def default_image(flavour):
    """The same Ubuntu LTS, spelled the way each API names it. See the IMAGE note in the
    manifest header — the two registries use different separators AND 26 includes the
    architecture, so one literal cannot serve both."""
    return ("ubuntu:noble:amd64:default" if flavour == "container"
            else "ubuntu/noble/default")


def state_of(row):
    """⚠ `status` CHANGED SHAPE between the two APIs: 25.10 returned a bare string
    ("RUNNING"), 26 returns {"state": "RUNNING", "pid": ..., "domain_state": ...}.
    Calling .upper() on the 26 form raises AttributeError, so every state comparison goes
    through here rather than touching row["status"] directly."""
    st = (row or {}).get("status")
    if isinstance(st, dict):
        st = st.get("state")
    return str(st or "").upper()


def attach_devices(tn, cid):
    """Attach the NIC, and the bootstrap bind-mount if one was staged.

    ⚠ THE PARAMETER IS `container`, NOT `container_id`. Passing container_id fails with
    "Field required / Extra inputs are not permitted", which reads like a schema mismatch
    rather than a typo. Verified on 26.0.0-BETA.3.
    """
    # -- NIC. Same MACVLAN reasoning as the 25.10 branch: the default network is NAT'd and
    # a k8s node behind NAT cannot be reached by the cluster. MACVLAN gives the container
    # its own DHCP lease on the lab LAN (measured: 192.168.1.213 alongside the appliance's
    # .237). The parent-isolation caveat in build_payload still applies.
    # ⚠ THE 26 NIC SCHEMA IS NOT THE 25.10 ONE, and the difference is not cosmetic:
    #     25.10  {dtype:NIC, nic_type:"MACVLAN", parent:"eno2"}
    #     26.0+  {dtype:NIC, nic_attach:"eno2", type:"E1000"|"VIRTIO", mac,
    #             trust_guest_rx_filters}
    # `nic_type` and `parent` are REJECTED on 26 ("Extra inputs are not permitted"), and
    # `type` there means the emulated CARD, not the attach mode. Note there is no
    # MACVLAN-vs-BRIDGE field at all: `nic_attach` takes a bare interface name and the mode
    # follows from WHICH name — a physical iface (eno1/eno2) is macvlan-attached, a bridge
    # (truenasbr0) is bridge-attached. nic_attach_choices() reports both lists.
    # Verified on 26.0.0-BETA.3 — an earlier build of this script used the
    # 25.10 names, only WARNED on rejection, and produced a container with devices: [] and
    # no network at all. Hence: fatal, not a warning.
    try:
        tn.rpc("container.device.create", [{
            "container": cid,
            "attributes": {"dtype": "NIC", "nic_attach": NIC, "type": NIC_MODEL},
        }])
        print(f"  device NIC: {NIC} ({NIC_MODEL})")
    except Exception as exc:
        raise RuntimeError(
            f"could not attach NIC on {NIC}: {str(exc)[:200]}\n"
            "  Without a NIC the container has NO network and phase B cannot run, so this "
            "is fatal rather than a warning.") from exc

    # -- Bootstrap bind-mount, only when something was staged for it.
    if not BOOTSTRAP_SRC:
        return
    try:
        tn.rpc("container.device.create", [{
            "container": cid,
            "attributes": {"dtype": "FILESYSTEM",
                           "source": BOOTSTRAP_SRC, "target": BOOTSTRAP_TARGET},
        }])
        print(f"  device FILESYSTEM: {BOOTSTRAP_SRC} -> {BOOTSTRAP_TARGET}")
    except Exception as exc:
        print(f"  WARNING: could not attach the bootstrap mount: {str(exc)[:200]}")


def preflight(tn, flavour):
    """Fail with a USEFUL message rather than a schema error from the middleware."""
    ok = True

    # Virtualization must be initialized and have a pool, or create fails obscurely.
    if flavour == "virt":
        g = tn.rpc("virt.global.config")
        if g.get("state") != "INITIALIZED":
            print(f"  FAIL: virtualization state is {g.get('state')!r}, expected INITIALIZED")
            ok = False
        pools = g.get("storage_pools") or []
        if POOL not in pools:
            print(f"  FAIL: pool {POOL!r} not in virt storage_pools {pools}")
            ok = False
        else:
            print(f"  ok: virtualization INITIALIZED on pool {POOL}")

    # The MACVLAN parent must exist and be offered for MACVLAN specifically. Asking
    # nic_choices is what distinguishes "no such interface" from "bridged is unavailable".
    # The method moved namespaces in 26 and takes no argument there.
    # ⚠ THE TWO APIs RETURN DIFFERENT SHAPES, and reading 26's as 25.10's fails a VALID nic:
    #     25.10  virt.device.nic_choices("MACVLAN") -> {"eno1": "eno1", "eno2": "eno2"}
    #            i.e. already filtered to the type, parents are the KEYS.
    #     26.0+  container.device.nic_attach_choices() -> {"BRIDGE": ["truenasbr0"],
    #                                                     "MACVLAN": ["eno1", "eno2"]}
    #            i.e. keyed BY TYPE, parents in the value list; it takes NO argument
    #            (passing one is "Too many arguments (expected 0, found 1)").
    # Verified on 26.0.0-BETA.3.
    parents, mode = [], None
    try:
        if flavour == "container":
            # {"BRIDGE": ["truenasbr0"], "MACVLAN": ["eno1", "eno2"]} — keyed by attach MODE,
            # and the mode is IMPLIED by which list the interface appears in. Takes NO
            # argument (passing one errors "Too many arguments (expected 0, found 1)").
            bymode = tn.rpc("container.device.nic_attach_choices") or {}
            for m, ifaces in bymode.items():
                parents.extend(ifaces or [])
                if NIC in (ifaces or []):
                    mode = m
        else:
            parents = sorted((tn.rpc("virt.device.nic_choices", ["MACVLAN"]) or {}).keys())
            mode = "MACVLAN"
    except Exception as exc:
        print(f"  NOTE: could not list NIC parents ({str(exc)[:90]}) — not checking")
    if parents and NIC not in parents:
        print(f"  FAIL: {NIC!r} is not attachable; have {sorted(set(parents))}")
        ok = False
    elif parents:
        print(f"  ok: NIC {NIC} available (attaches as {mode})")

    # Image resolution is a REAL EGRESS TEST. The appliance resolves through the on-prem DC
    # (single nameserver, no fallback — deliberate, see configure-job step 2), so when the
    # DC is down this is the call that fails, with a name-resolution error that looks
    # nothing like a DNS problem at first glance.
    if flavour == "virt":
        try:
            imgs = tn.rpc("virt.instance.image_choices", [{"remote": "LINUX_CONTAINERS"}]) or {}
            if IMAGE not in imgs:
                print(f"  FAIL: image {IMAGE!r} not offered by the image server "
                      f"({len(imgs)} images available)")
                ok = False
            else:
                print(f"  ok: image {IMAGE} available ({len(imgs)} total)")
        except Exception as exc:
            print(f"  FAIL: cannot list images — {exc}")
            print("        The appliance resolves DNS through the on-prem DC and has NO "
                  "fallback resolver.\n        If that DC is down, this is the symptom. "
                  "Bring it up rather than adding a resolver:\n        a router fallback "
                  "breaks the AD join (measured).")
            ok = False

    # 26: the registry is a LIST of {name, versions:[{version}]}, not the flat
    # `os/release/variant` map 25.10 returned. Names are `<os>:<release>:<arch>:<variant>`,
    # e.g. ubuntu:noble:amd64:default. Resolving the version here rather than hardcoding a
    # build date is what keeps a recreate from pinning an image that has aged out of the
    # registry — the versions are dated builds and only the last few are kept.
    if flavour == "container":
        global IMAGE_VERSION
        try:
            reg = tn.rpc("container.image.query_registry") or []
            entry = next((e for e in reg if e.get("name") == IMAGE), None)
            if entry is None:
                print(f"  FAIL: image {IMAGE!r} not in the registry ({len(reg)} entries). "
                      f"Names look like 'ubuntu:noble:amd64:default'.")
                ubu = [e.get("name") for e in reg if str(e.get("name", "")).startswith("ubuntu")]
                if ubu:
                    print(f"        ubuntu available: {ubu}")
                ok = False
            else:
                vers = [v.get("version") for v in (entry.get("versions") or []) if v.get("version")]
                if not vers:
                    print(f"  FAIL: image {IMAGE!r} has no published versions")
                    ok = False
                else:
                    IMAGE_VERSION = sorted(vers)[-1]   # dated builds sort chronologically
                    print(f"  ok: image {IMAGE} version {IMAGE_VERSION} "
                          f"({len(vers)} builds offered)")
        except Exception as exc:
            print(f"  FAIL: cannot query the image registry — {exc}")
            print("        Same DNS caveat as above: the appliance resolves through the "
                  "on-prem DC\n        with no fallback, so a DC outage surfaces here as a "
                  "name-resolution error.")
            ok = False
    return ok


def main():
    with TrueNAS(HOST, USER, PASSWORD) as tn:
        info = tn.rpc("system.info")
        flavour = api_flavour(tn)
        global IMAGE
        if not IMAGE:
            IMAGE = default_image(flavour)
        print(f"appliance {info.get('hostname')} running {info.get('version')}")
        print(f"api flavour: {flavour}.* "
              f"({'container.create' if flavour == 'container' else 'virt.instance.create'})")
        print()

        existing = query(tn, flavour)

        if MODE == "show":
            if existing is None:
                print(f"container {NAME!r}: ABSENT")
            else:
                print(f"container {NAME!r}: present")
                print(json.dumps({k: existing.get(k) for k in
                                  ("name", "type", "status", "autostart", "cpu", "memory")},
                                 indent=2, default=str))
            return

        if MODE == "print":
            # ⚠ RESOLVE THE IMAGE VERSION FIRST. IMAGE_VERSION is assigned inside
            # preflight(), which the create path calls further down — so printing without it
            # emitted {"version": null}, i.e. NOT the payload that would actually be sent,
            # which defeats the whole point of --print-only. Run the checks, then print.
            # Their pass/fail is irrelevant here (nothing is created either way); what
            # matters is the version lookup they perform.
            preflight(tn, flavour)
            print()
            print(json.dumps(build_payload(flavour), indent=2))
            return

        if existing is not None and MODE != "recreate":
            # ⚠ DELIBERATELY DOES NOT CONVERGE cpu/memory/disk ON AN EXISTING CONTAINER.
            # Once phase B has run, this container holds a k8s node's identity and state.
            # Silently resizing it — or worse, replacing it — would destroy a live node
            # while its Longhorn replicas and AD workloads are on it. Resizing is a
            # deliberate act: use --force, or change it in the UI.
            print(f"container {NAME!r}: already exists (state "
                  f"{state_of(existing)}) — nothing to do")
            print("  to change its shape, re-run with --force (DESTRUCTIVE), or edit it "
                  "in the appliance UI")
            drift = []
            if existing.get("autostart") is False:
                drift.append("autostart is False")
            for d in drift:
                print(f"  NOTE: {d}")
            return

        if existing is not None and MODE == "recreate":
            print(f"--force: deleting existing container {NAME!r}")
            if state_of(existing) == "RUNNING":
                tn.job("container.stop" if flavour == "container" else "virt.instance.stop",
                       [NAME, {"force": True}] if flavour == "virt" else [existing["id"]])
                time.sleep(3)
            tn.job("container.delete" if flavour == "container" else "virt.instance.delete",
                   [existing["id"] if flavour == "container" else NAME])
            print("  deleted")

        print("preflight:")
        if not preflight(tn, flavour):
            raise SystemExit("preflight FAILED — nothing was created (see messages above)")
        print()

        payload = build_payload(flavour)
        print(f"creating {NAME!r} ...")
        tn.job("container.create" if flavour == "container" else "virt.instance.create",
               [payload], timeout=1800)
        print("  created")

        row = query(tn, flavour)
        if row is None:
            raise RuntimeError("create reported success but the container is not queryable")

        # 26 attaches devices AFTER create; 25.10 took them inline in the payload.
        if flavour == "container":
            attach_devices(tn, row["id"])

        if state_of(row) != "RUNNING":
            print("starting ...")
            tn.job("container.start" if flavour == "container" else "virt.instance.start",
                   [row["id"] if flavour == "container" else NAME])
        print()
        print(f"CONTAINER {NAME} IS UP.")


if __name__ == "__main__":
    main()
PYEOF

python3 -c "import ast,sys; ast.parse(open('$WORK/create.py').read())" || {
  echo "ERROR: generated create.py does not parse" >&2; exit 1; }

TRANSPORT="$(pick_transport)"
echo "transport : $TRANSPORT"

if [[ "$TRANSPORT" == "pod" ]]; then
  # Same placement contract as truenas/configure-job.yaml: ecc/fileserver-lan=true plus the
  # ecc/mesh toleration. Without the toleration the pod stays Pending FOREVER rather than
  # failing — the worst diagnostic outcome, so it is asserted rather than assumed.
  if ! kubectl get nodes -l ecc/fileserver-lan=true -o name 2>/dev/null | grep -q node; then
    echo "ERROR: transport=pod but no node carries ecc/fileserver-lan=true." >&2
    echo "       Node labels lag project_settings after a recreate; check:" >&2
    echo "         kubectl get nodes -L ecc/fileserver-lan,ecc/site" >&2
    echo "       Or force the cluster-free path: FS_CONTAINER_TRANSPORT=ssh" >&2
    exit 1
  fi
  if ! kubectl -n "$NAMESPACE" get secret truenas-admin &>/dev/null; then
    echo "ERROR: secret truenas-admin not found in namespace $NAMESPACE." >&2
    echo "       It is sealed by deployment/argocd-infra/truenas/sealSecrets.sh and applied" >&2
    echo "       by the wave16-truenas app — sync that app first." >&2
    exit 1
  fi
fi

# ── Destructive-path confirmation ────────────────────────────────────────────
# ⚠ Asked HERE, before anything is applied, and asked about the LIVE cluster rather than
# only the appliance: if this container has already been through phase B it is a k8s node,
# and the most expensive part of deleting it is not the container but the node state that
# goes with it. Naming the node in the prompt is what makes that concrete for the operator.
if [[ "$MODE" == "recreate" && "$ASSUME_YES" != "true" ]]; then
  echo "⚠ --force will DELETE and rebuild container '$NAME' on $TN_ENDPOINT."
  echo "  Everything on its root disk is lost."
  if command -v kubectl >/dev/null && kubectl get node "$NAME" &>/dev/null; then
    echo
    echo "  ⚠ '$NAME' IS CURRENTLY A NODE IN THIS CLUSTER:"
    kubectl get node "$NAME" -o wide 2>/dev/null | sed 's/^/      /'
    echo "      Deleting it strands this node and its headscale machine. This script does"
    echo "      NOT clean either up — scripts/provisioning/decomissionNode.sh does."
  fi
  echo
  read -rp "  type the container name to confirm: " _confirm
  [[ "$_confirm" == "$NAME" ]] || { echo "aborted (got '$_confirm')"; exit 1; }
  echo
fi

# ── Execute ──────────────────────────────────────────────────────────────────
if [[ "$TRANSPORT" == "ssh" ]]; then
  # Cluster-free path. Everything it needs is in the Pulumi stack: the mesh SSH key and the
  # appliance credential. Runs the SAME create.py, just delivered over scp instead of a
  # ConfigMap — the code that talks to the appliance is identical either way.
  command -v pulumi >/dev/null || { echo "ERROR: pulumi not found (needed for transport=ssh)" >&2; exit 1; }
  # ⚠ THE PASSPHRASE IS REQUIRED EVEN FOR --show/--print-only ON THIS TRANSPORT, because the
  # relay key and the appliance credential both live in the stack. That is unavoidable for a
  # call that must actually reach the appliance — but say so plainly rather than dying in a
  # `pulumi config get` several lines later with an empty-value error.
  : "${PULUMI_CONFIG_PASSPHRASE:=$(cat /tmp/passphrase 2>/dev/null || true)}"
  if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    echo "ERROR: transport=ssh needs the Pulumi stack (relay key + appliance credential)," >&2
    echo "       but PULUMI_CONFIG_PASSPHRASE is unset and /tmp/passphrase is absent." >&2
    echo "       Load it:  source ./scripts/pulumi/initPulumiStack.sh" >&2
    echo "       Or use the cluster transport:  --via-cluster" >&2
    exit 1
  fi
  export PULUMI_CONFIG_PASSPHRASE
  pulumi -C "$ROOT_DIR" stack select mystack >/dev/null 2>&1 || true

  # The lab box to hop through. Any mesh node at the site works — it is only a relay onto
  # 192.168.1.0/24. Read from project_settings so it is not a second hardcoded endpoint.
  RELAY_HOST="${FS_CONTAINER_RELAY_HOST:-jump.your-domain.tld}"
  RELAY_PORT="${FS_CONTAINER_RELAY_PORT:-3001}"
  RELAY_USER="${FS_CONTAINER_RELAY_USER:-cape}"

  KEYF="$WORK/relay.key"
  pulumi -C "$ROOT_DIR" config get sshkey-ecc-mesh > "$KEYF" 2>/dev/null || {
    echo "ERROR: could not read sshkey-ecc-mesh from the Pulumi stack." >&2
    echo "       Load it first: source ./scripts/pulumi/initPulumiStack.sh" >&2; exit 1; }
  chmod 600 "$KEYF"
  [[ -s "$KEYF" ]] || { echo "ERROR: sshkey-ecc-mesh is empty" >&2; exit 1; }

  # ⚠ CREDENTIALS FROM PULUMI, NOT FROM THE CLUSTER. This is the whole point of the
  # truenasAdminUser/truenasAdminPassword are the source of truth and
  # readable with only the stack passphrase, so this path works with no cluster at all.
  TN_USER_V="$(pulumi -C "$ROOT_DIR" config get truenasAdminUser 2>/dev/null || true)"
  TN_PASS_V="$(pulumi -C "$ROOT_DIR" config get truenasAdminPassword 2>/dev/null || true)"
  if [[ -z "$TN_USER_V" || -z "$TN_PASS_V" ]]; then
    echo "ERROR: truenasAdminUser/truenasAdminPassword not in the Pulumi stack." >&2
    echo "       Seed them by running deployment/argocd-infra/truenas/sealSecrets.sh" >&2
    exit 1
  fi

  SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=15 -o LogLevel=ERROR -i "$KEYF")
  REMOTE_DIR="/tmp/fs-container-$$"
  echo "running via ssh relay $RELAY_USER@$RELAY_HOST:$RELAY_PORT ..."
  ssh "${SSH_OPTS[@]}" -p "$RELAY_PORT" "$RELAY_USER@$RELAY_HOST" "mkdir -p $REMOTE_DIR" \
    || { echo "ERROR: cannot reach the relay host over SSH" >&2; exit 1; }
  scp -q "${SSH_OPTS[@]}" -P "$RELAY_PORT" "$WORK/tnclient.py" "$WORK/create.py" \
      "$RELAY_USER@$RELAY_HOST:$REMOTE_DIR/"

  # ⚠ THE CREDENTIAL GOES OVER STDIN, NEVER IN argv. Interpolating TN_PASS into the ssh
  # command string makes it a process ARGUMENT on the relay, readable via `ps` by any other
  # user on what is a shared lab box — the appliance ADMIN password, the one that can mint
  # API keys. Single-quoting it there was also unescaped, so a password containing `'` would
  # break the command or inject shell.
  # Instead: `sh -s` reads the script from stdin, and the values are fed as a leading
  # `export` block on that same pipe. argv is then just "sh -s"; /proc/<pid>/environ is
  # readable only by the same user and root, which is the same exposure the pod transport
  # already has via the Secret-backed env.
  set +e
  {
    printf 'export TN_HOST=%s TN_USER=%s TN_PASS=%s\n' \
      "$(printf %q "$TN_ENDPOINT")" "$(printf %q "$TN_USER_V")" "$(printf %q "$TN_PASS_V")"
    printf 'export C_NAME=%s C_IMAGE=%s C_MEMORY_GB=%s C_CPU=%s C_DISK_GB=%s\n' \
      "$(printf %q "$NAME")" "$(printf %q "$IMAGE")" "$(printf %q "$MEMORY_GB")" \
      "$(printf %q "$CPU_COUNT")" "$(printf %q "$DISK_GB")"
    printf 'export C_NIC_PARENT=%s C_NIC_MODEL=%s C_POOL=%s C_MODE=%s C_BOOTSTRAP_DIR=%s C_BOOTSTRAP_TARGET=%s\n' \
      "$(printf %q "$NIC_PARENT")" "$(printf %q "$NIC_MODEL")" "$(printf %q "$POOL")" "$(printf %q "$MODE")" \
      "$(printf %q "$BOOTSTRAP_DIR")" "$(printf %q "$BOOTSTRAP_TARGET")"
    printf 'exec python3 %s/create.py\n' "$(printf %q "$REMOTE_DIR")"
  } | ssh "${SSH_OPTS[@]}" -p "$RELAY_PORT" "$RELAY_USER@$RELAY_HOST" "sh -s"
  RC=$?
  set -e
  # The credential was passed through the remote environment; remove the staging dir even
  # on failure so nothing is left behind on a shared lab box.
  ssh "${SSH_OPTS[@]}" -p "$RELAY_PORT" "$RELAY_USER@$RELAY_HOST" "rm -rf $REMOTE_DIR" || true
  unset TN_PASS_V
  [[ $RC -eq 0 ]] || { echo "FAILED — see the log above." >&2; exit 1; }
else
  JOB="fs-container-create-$(date +%s)"
  kubectl -n "$NAMESPACE" delete configmap "$JOB-code" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" create configmap "$JOB-code" \
    --from-file=tnclient.py="$WORK/tnclient.py" \
    --from-file=create.py="$WORK/create.py" >/dev/null

  cleanup_job() {
    kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete configmap "$JOB-code" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap 'cleanup_job; rm -rf "$WORK"' EXIT

  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        ecc/fileserver-lan: "true"
      tolerations:
        - key: ecc/mesh
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: create
          image: docker.io/library/python:3.13-slim
          command: ["python3", "/src/create.py"]
          env:
            - { name: TN_HOST,       value: "$TN_ENDPOINT" }
            - { name: C_NAME,        value: "$NAME" }
            - { name: C_IMAGE,           value: "$IMAGE" }
            - { name: C_BOOTSTRAP_DIR,    value: "$BOOTSTRAP_DIR" }
            - { name: C_BOOTSTRAP_TARGET, value: "$BOOTSTRAP_TARGET" }
            - { name: C_MEMORY_GB,   value: "$MEMORY_GB" }
            - { name: C_CPU,         value: "$CPU_COUNT" }
            - { name: C_DISK_GB,     value: "$DISK_GB" }
            - { name: C_NIC_PARENT,  value: "$NIC_PARENT" }
            - { name: C_NIC_MODEL,   value: "$NIC_MODEL" }
            - { name: C_POOL,        value: "$POOL" }
            - { name: C_MODE,        value: "$MODE" }
            - name: TN_USER
              valueFrom: { secretKeyRef: { name: truenas-admin, key: TRUENAS_ADMIN_USER } }
            - name: TN_PASS
              valueFrom: { secretKeyRef: { name: truenas-admin, key: TRUENAS_ADMIN_PASSWORD } }
          volumeMounts:
            - { name: src, mountPath: /src }
      volumes:
        - name: src
          configMap: { name: $JOB-code }
EOF

  echo "running on a unibi-hclab node (job/$JOB) ..."
  # Creating a container pulls an image over a filtered lab uplink; give it real time.
  kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$JOB" --timeout=1800s >/dev/null 2>&1 &
  WAIT_PID=$!
  while kill -0 "$WAIT_PID" 2>/dev/null; do
    if [[ "$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)" == "1" ]]; then
      break
    fi
    sleep 5
  done
  wait "$WAIT_PID" 2>/dev/null || true

  echo
  kubectl -n "$NAMESPACE" logs "job/$JOB" 2>&1 || true
  echo

  SUCCEEDED=$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [[ "$SUCCEEDED" != "1" ]]; then
    echo "FAILED — see the log above. Nothing was left running." >&2
    exit 1
  fi
fi

if [[ "$MODE" == "create" || "$MODE" == "recreate" ]]; then
cat <<EOF

── NEXT: phase B (provision k8s) ─────────────────────────────────────────────
This container is NOT yet a cluster node. It has no tailscale and no k3s.

  1. Generate the carry-scripts (on the devcontainer):
       ./scripts/provisioning/generateProvisioningScripts.sh

  2. Copy tmp/provisioning/ INTO the container and run it there. There is no
     inbound SSH to a fresh container, so this is path B:
       sudo bash provision-mesh-node-local.sh --name $NAME

  3. It registers KEYLESS and prints a one-time URL + QR. Approve it in Headplane
     (Machines -> "Register machine"), then wait ~30-60s for it to join k3s.

  4. Adopt it (labels, storageScope disk tags, fingerprint):
       ./scripts/provisioning/adoptProvisionedNodes.sh $NAME

Then add it to nodes.mesh[] in project_settings.ts so it is tracked. Note it has
NO inbound SSH, so leave it out of Pulumi's SSH provisioning or give it an
ssh.endpoint that actually resolves.
EOF
fi
