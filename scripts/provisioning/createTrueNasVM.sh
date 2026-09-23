#!/bin/bash
# createTrueNasVM.sh — create the k8s-node VM on the TrueNAS appliance (phase A).
#
# Builds a QEMU/KVM VM on the appliance from an Ubuntu autoinstall ISO, entirely over the
# JSON-RPC API: upload the ISO, create the VM, attach DISK/CDROM/NIC/DISPLAY, start it, and
# wait for the guest to come up on the LAN. The guest configures ITSELF from the ISO's baked-in
# autoinstall config (cape user + sshkey-ecc-mesh), so nothing has to be injected afterwards.
#
# ⚠ A VM, NOT A CONTAINER, and that is not a preference. The container path cannot
# self-provision: TrueNAS's registry carries only `ubuntu:*:default` images, which ship no
# cloud-init, and container.create's init/initenv/inituser fields are accepted, stored and read
# back — then SILENTLY IGNORED at boot (measured twice: at create time and via update; the
# container DHCP'd, proving /sbin/init ran instead). createTrueNasContainer.sh still implements
# that path and is fine for throwaway probes — it is NOT the node path. See doc/truenas-vm.md.
#
# This is phase A only. Phase B (mesh join) is `make provision-mesh-node ARGS=<node-id>` once
# the VM is SSH-reachable at the node's ssh: endpoint in project_settings.ts.
#
# ── Four facts this script encodes, none of them guessable from the schema ───────────────────
#
# 1. DEVICE `order` BECOMES QEMU `bootindex`, under `-boot strict=on`. The DISK must sit at a
#    LOWER order than the CDROM: an empty disk falls through to the installer, a finished system
#    boots itself, and the ISO can stay attached the whole time. CDROM-first is an install LOOP
#    whose symptom is badly misleading — SSH answers and rejects the correct key, because you are
#    talking to the installer's live environment, not the installed system.
#    ⛔ Never break that loop by ejecting the CDROM mid-install: that leaves no EFI boot entry,
#    and the VM then sits in the UEFI shell reporting RUNNING while writing nothing and emitting
#    no packets. Eject only AFTER the install has finished (--eject-cdrom, or `vm.device.delete`).
#
# 2. DISPLAY `password` IS REQUIRED, though the schema marks it optional — the validator says
#    "Password is required for display devices". Same class of defect as the FILESYSTEM `source`
#    docstring in the container API, which states the opposite of what the validator enforces.
#    A DISPLAY is not optional in practice: qemu's serial goes to a pty nobody reads and
#    vm.get_display_devices is [], so without one an install is a blind ~20-minute wait.
#
# 3. `filesystem.put` IS NOT CALLABLE OVER JSON-RPC ("Pipe 'input' is not open"). Uploading needs
#    a multipart POST to https://<host>/_upload with HTTP BASIC auth. (Downloading is the mirror
#    image: `core.download` hands back a one-shot URL.) Measured at 2.9 GB in ~31 s.
#
# 4. `create_zvol:true` THICK-PROVISIONS, so `used == volsize` the moment it exists. Zvol usage is
#    therefore USELESS as an install-progress signal — it reads "full" whether or not a single
#    byte was written. Watch the guest's port instead (see WAITING, below).
#
# ── Networking ──────────────────────────────────────────────────────────────────────────────
# nic_attach takes a BARE INTERFACE NAME and the mode FOLLOWS FROM WHICH NAME: a physical iface
# macvlan-attaches, a bridge bridge-attaches. There is no mode flag.
#
# The appliance has no bridge (nic_attach_choices → BRIDGE: []), so the guest is a MACVLAN child.
# The textbook rule says such a child cannot reach its own parent interface's host address —
# which would stop it mounting the appliance's own NFS exports, the whole point of this node.
# MEASURED, that rule does not apply here: from the guest on eno2, both .237 (eno1) AND .238
# (eno2 — its own parent) answer, 2049/443 are open, and a real `mount -t nfs` succeeds. The
# switch hairpins the frames. So no bridge is needed and the port choice does not affect
# reachability; eno2 is the default only to keep guest traffic off the management port.
# ⚠ That depends on SWITCH behaviour, not on anything TrueNAS or the kernel guarantees. Re-run
# the check after any change of switch, cabling or appliance NIC — and treat a failure as the
# expected default rather than a new fault. Fallback is a real bridge (interface.create,
# type BRIDGE, bridge_members=[eno2] — never eno1, which carries management/API/NFS; network
# changes are transactional via has_pending_changes/checkin_waiting/rollback).
#
# ── The MAC is pinned, and it has to be ────────────────────────────────────────────────────
# TrueNAS mints a FRESH RANDOM MAC on every vm.device.create for a NIC. So deleting and
# rebuilding a VM (--force) gives the guest a new L2 identity: the router's DHCP reservation
# still points at the OLD MAC, the guest takes an arbitrary pool address, and every inbound
# port-forward aimed at the reserved IP — the node's own ssh.port included — goes dead. Nothing
# errors. The VM boots, installs, and is simply not where anything expects it, which reads as
# "the install hung" rather than "the address moved".
# --force moved fsnode0 off 192.168.1.194 and left epi.techfak:3004
# refusing, ~40 min into a wait for an SSH login that could never arrive.
# The MAC therefore comes from project_settings host.mac (override with --mac) and is passed
# explicitly, so one VM keeps one identity across any number of rebuilds.
#
# ── Waiting, and why not ARP ────────────────────────────────────────────────────────────────
# The guest's MAC may NEVER appear in a given neighbour's ARP table even while it is up and
# answering on :22, so "absent from ARP" is not evidence of "no network". This script polls the
# SSH PORT from the lab side instead. The installer's live environment ALSO answers :22 but has
# no `cape` user, so the real completion test is a successful `cape` login, not an open port.
# The banners differ too (installer Ubuntu-2ubuntu3 vs installed Ubuntu-2ubuntu3.5).
#
# ⚠ The probe deliberately does NOT verify the host key. A reinstalled guest presents a NEW
# one by definition, and the normal wrapper's StrictHostKeyChecking=accept-new refuses a
# CHANGED key — which reads as "cape is not there yet" and burns the whole wait budget on a
# guest that is already up. Only this liveness probe skips the check; every other access path
# keeps it.
#
# ── Hostname ────────────────────────────────────────────────────────────────────────────────
# The ISO names the box ubuntu-autoinstall-<mac>, then enables dhcp-hostname-refresh.service,
# which applies DHCP option 12 from the systemd-networkd lease. It is enabled from the
# autoinstall's LATE-COMMANDS, i.e. after the system is already up, so it does NOT run on the
# install boot — the guest keeps ubuntu-autoinstall-<mac> until its FIRST REBOOT. Give it its
# intended name with a DHCP reservation on the router; nothing changes inside the guest.
# None of this affects the k8s node name: 40-join-cluster.sh takes that from --node-name=.
#
# ── Transports (same contract as createTrueNasContainer.sh) ──────────────────────────────────
# The devcontainer cannot route to the lab LAN, so the API calls must execute ON it:
#   pod — a Job pinned to ecc/fileserver-lan=true. Needs a cluster with a lab node joined.
#   ssh — the same python on a lab box over the epi.techfak forward. Needs ONLY the Pulumi
#         stack (relay key + appliance credential both live there), so it works during a
#         recreate when there is no cluster at all — which matters, because this IS a
#         bootstrap step and requiring a healthy cluster would contradict its own premise.
# Picked automatically; force with --via-cluster / --via-ssh.
#
# Usage:
#   ./scripts/provisioning/createTrueNasVM.sh                      # create (idempotent)
#   ./scripts/provisioning/createTrueNasVM.sh --show               # report state, change nothing
#   ./scripts/provisioning/createTrueNasVM.sh --iso <path>         # local ISO to upload
#   ./scripts/provisioning/createTrueNasVM.sh --eject-cdrom        # post-install: stop, detach, start
#   ./scripts/provisioning/createTrueNasVM.sh --force              # DELETE and rebuild (destructive)
#   ./scripts/provisioning/createTrueNasVM.sh --mac 00:a0:98:05:ef:59   # override host.mac
#   ./scripts/provisioning/createTrueNasVM.sh --name fsnode0 --memory 8 --cpu 4 --disk 60
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
CONFIGURE_JOB="$ROOT_DIR/deployment/argocd-infra/truenas/configure-job.yaml"
NAMESPACE="truenas"

# ── Defaults ─────────────────────────────────────────────────────────────────
NAME="fsnode0"
MEMORY_GB=8
CPU=4
DISK_GB=60
NIC_ATTACH="eno2"          # see the Networking note above for why eno2 and not eno1
NIC_MODEL="VIRTIO"
NIC_MAC=""                 # default: project_settings host.mac (pinned so DHCP survives a rebuild)
ISO_LOCAL=""
ISO_REMOTE_DIR="/mnt/datapool/shared/data/iso"
ISO_REMOTE_NAME="ubuntu-autoinstall.iso"
POOL=""                    # default: read from project_settings host.pool
MODE="create"              # create | recreate | show | eject
TRANSPORT="${FS_VM_TRANSPORT:-auto}"
ASSUME_YES="false"
WAIT_SECS=2400             # autoinstall is ~13 min on this hardware; allow generous headroom
SKIP_WAIT="false"

usage() {
    # Print the header block only — everything from line 2 up to the line before `set -euo`.
    sed -n "2,109p" "${BASH_SOURCE[0]}" | sed 's/^# \\{0,1\\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2 ;;
    --memory)       MEMORY_GB="$2"; shift 2 ;;
    --cpu)          CPU="$2"; shift 2 ;;
    --disk)         DISK_GB="$2"; shift 2 ;;
    --nic)          NIC_ATTACH="$2"; shift 2 ;;
    --nic-model)    NIC_MODEL="$2"; shift 2 ;;
    --mac)          NIC_MAC="$2"; shift 2 ;;
    --iso)          ISO_LOCAL="$2"; shift 2 ;;
    --pool)         POOL="$2"; shift 2 ;;
    --show)         MODE="show"; shift ;;
    --eject-cdrom)  MODE="eject"; shift ;;
    --force|--recreate) MODE="recreate"; shift ;;
    --yes|-y)       ASSUME_YES="true"; shift ;;
    --no-wait)      SKIP_WAIT="true"; shift ;;
    --wait-secs)    WAIT_SECS="$2"; shift 2 ;;
    --via-cluster)  TRANSPORT="pod"; shift ;;
    --via-ssh)      TRANSPORT="ssh"; shift ;;
    -h|--help)      usage ;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# ── The appliance address, from project_settings ─────────────────────────────
# ⚠ THE LITERAL IP, deliberately — same value and reasoning as fileserver.endpoint: the AD
# zone publishes the on-prem DC's MESH address, so resolving the appliance by name would
# route LAN traffic over the overlay.
TN_ENDPOINT=$(perl -ne '
    if (/^\s*fileserver:\s*\{/) { $in = 1; next }
    if ($in && /^\s{4}\},/) { exit }
    if ($in && /^\s*endpoint:\s*"([^"]+)"/) { print "$1"; exit }
' "$PROJECT_SETTINGS_FILE")
[[ -z "$TN_ENDPOINT" ]] && { echo "ERROR: could not read fileserver.endpoint from project_settings.ts" >&2; exit 1; }

# ⚠ The guest MAC, pinned in project_settings host.mac. Without it TrueNAS mints a FRESH
# RANDOM MAC on every create, so a rebuilt VM loses its DHCP reservation, lands on some other
# address, and every port-forward aimed at the reserved IP (the node's own ssh.port included)
# goes dead — silently, because the VM itself boots fine.
if [[ -z "$NIC_MAC" ]]; then
  NIC_MAC=$(perl -ne '
      if (/^\s*host:\s*\{/) { $in = 1; next }
      if ($in && /^\s*\},/) { exit }
      if ($in && /^\s*mac:\s*"([^"]+)"/) { print "$1"; exit }
  ' "$PROJECT_SETTINGS_FILE")
fi

# Pool from the node's host.pool block unless overridden.
if [[ -z "$POOL" ]]; then
  POOL=$(perl -ne 'if (/^\s*pool:\s*"([^"]+)"/) { print "$1"; exit }' "$PROJECT_SETTINGS_FILE")
  POOL="${POOL:-datapool}"
fi

# The API client is NOT duplicated here. It is lifted from the ConfigMap in configure-job.yaml,
# which check-tnclient.sh already guards against drift — a third copy would need a third entry
# in that check.
[[ -f "$CONFIGURE_JOB" ]] || { echo "ERROR: $CONFIGURE_JOB not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$CONFIGURE_JOB" "$WORK/tnclient.py" <<'PYEXTRACT'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
for doc in yaml.safe_load_all(open(src)):
    if doc and doc.get("kind") == "ConfigMap":
        body = (doc.get("data") or {}).get("tnclient.py")
        if body:
            open(dst, "w").write(body)
            sys.exit(0)
sys.exit("ERROR: tnclient.py not found in the configure-job ConfigMap")
PYEXTRACT

echo "appliance : $TN_ENDPOINT"
echo "vm        : $NAME  (${CPU} cores, ${MEMORY_GB} GiB, ${DISK_GB} GiB on $POOL)"
echo "nic       : $NIC_ATTACH ($NIC_MODEL)${NIC_MAC:+ mac=$NIC_MAC}"
[[ -z "$NIC_MAC" ]] && echo "  ⚠ no host.mac pinned — TrueNAS will assign a RANDOM MAC, so any DHCP" \
                    && echo "    reservation (and the port-forward that depends on it) will NOT apply."

# ⚠ RETRY BEFORE CONCLUDING "no lab node", then prefer ssh over failing.
# The overwhelmingly common way to reach this script is deprovision-then-rebuild, and the
# deprovision has just deleted a node. For a few seconds afterwards the API can answer with a
# view in which NO node carries ecc/fileserver-lan=true even though several do — so a single probe
# picks `ssh` (or, at the guard below, aborts) for a condition that clears in one poll.
# `--force` run 67s after a decommission hit exactly this and bailed
# before touching the VM.
#
# Falling through to `ssh` is the right answer when it IS genuinely empty: that path needs
# only the Pulumi stack, which is the whole reason it exists. This is a bootstrap step —
# refusing to build the VM because the cluster looks unhealthy inverts the dependency.
lab_node_present() {
  local tries="${1:-1}" i
  for (( i = 1; i <= tries; i++ )); do
    kubectl get nodes -l ecc/fileserver-lan=true -o name 2>/dev/null | grep -q node && return 0
    (( i < tries )) && { echo "  no ecc/fileserver-lan=true node yet (try $i/$tries) — retrying in 5s…" >&2; sleep 5; }
  done
  return 1
}

pick_transport() {
  if [[ "$TRANSPORT" != "auto" ]]; then echo "$TRANSPORT"; return; fi
  if command -v kubectl >/dev/null && kubectl cluster-info &>/dev/null \
     && lab_node_present 5; then
    echo pod
  else
    echo ssh
  fi
}

# ── The payload ──────────────────────────────────────────────────────────────
cat > "$WORK/vm.py" <<'PYVM'
import os, sys, json, time, ssl, base64, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tnclient import TrueNAS

HOST = os.environ["TN_HOST"]; USER = os.environ["TN_USER"]; PASS = os.environ["TN_PASS"]
NAME = os.environ["V_NAME"]; MODE = os.environ["V_MODE"]
MEM  = int(os.environ["V_MEMORY_GB"]) * 1024
CPU  = int(os.environ["V_CPU"]); DISK = int(os.environ["V_DISK_GB"])
POOL = os.environ["V_POOL"]
NIC_ATTACH = os.environ["V_NIC"]; NIC_MODEL = os.environ["V_NIC_MODEL"]
NIC_MAC = os.environ.get("V_NIC_MAC", "").strip()
ISO_PATH = os.environ["V_ISO_REMOTE"]
ISO_STAGED = os.environ.get("V_ISO_STAGED", "")   # local path on THIS host, if uploading
DPW = os.environ.get("V_DISPLAY_PW", "")

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
BASIC = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()


def upload(tn, local, remote_dir, remote_name):
    """filesystem.put via multipart POST to /_upload.

    ⚠ NOT callable over JSON-RPC: params alone give "Pipe 'input' is not open". HTTP BASIC,
    not Bearer — a form token is also rejected. Measured 2.9 GB in ~31 s.
    """
    size = os.path.getsize(local)
    payload = json.dumps({"method": "filesystem.put",
                          "params": [f"{remote_dir}/{remote_name}", {"mode": 0o644}]})
    boundary = "----tnvm" + base64.b16encode(os.urandom(8)).decode()
    pre = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"data\"\r\n\r\n"
           f"{payload}\r\n--{boundary}\r\n"
           f"Content-Disposition: form-data; name=\"file\"; filename=\"{remote_name}\"\r\n"
           f"Content-Type: application/octet-stream\r\n\r\n").encode()
    post = f"\r\n--{boundary}--\r\n".encode()

    class Body:
        """Stream the file rather than buffering it — these ISOs are multi-GB."""
        def __init__(self):
            self.parts = [pre, open(local, "rb"), post]; self.i = 0
        def read(self, n=-1):
            while self.i < len(self.parts):
                p = self.parts[self.i]
                chunk = p.read(n) if hasattr(p, "read") else p
                if hasattr(p, "read"):
                    if chunk:
                        return chunk
                    p.close(); self.i += 1; continue
                self.i += 1
                if chunk:
                    return chunk
            return b""

    req = urllib.request.Request(f"https://{HOST}/_upload", data=Body(), method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Content-Length", str(len(pre) + size + len(post)))
    req.add_header("Authorization", BASIC)
    r = json.loads(urllib.request.urlopen(req, context=CTX, timeout=3600).read() or b"{}")
    jid = r.get("job_id")
    print(f"  upload job {jid} ({size} bytes)", flush=True)
    for _ in range(1800):
        j = tn.call("core.get_jobs", [[["id", "=", jid]]])
        if j and j[0]["state"] in ("SUCCESS", "FAILED", "ABORTED"):
            if j[0]["state"] != "SUCCESS":
                raise RuntimeError(f"upload failed: {j[0].get('error')}")
            return
        time.sleep(2)
    raise RuntimeError("upload did not finish")


with TrueNAS(HOST, USER, PASS) as tn:
    def call(method, params=None):
        r = tn.call(method, params)
        if isinstance(r, dict) and "error" in r:
            raise RuntimeError(f"{method}: {json.dumps(r['error'])[:400]}")
        return r.get("result") if isinstance(r, dict) and "result" in r else r

    def find():
        for v in call("vm.query") or []:
            if isinstance(v, dict) and v.get("name") == NAME:
                return v
        return None

    def devices(vid):
        return sorted(call("vm.device.query", [[["vm", "=", vid]]]) or [],
                      key=lambda d: d.get("order") or 0)

    def show(vm):
        print(f"  vm {vm['id']} {vm['name']}: {vm.get('status')}")
        for d in devices(vm["id"]):
            a = d.get("attributes", {})
            tgt = a.get("path") or a.get("nic_attach") or a.get("port") or ""
            print(f"    order={d.get('order')} {a.get('dtype'):8s} id={d.get('id')} {tgt}")

    def stop(vid):
        if call("vm.status", [vid]).get("state") != "RUNNING":
            return
        call("vm.stop", [vid, {"force": True, "force_after_timeout": True}])
        for _ in range(40):
            time.sleep(3)
            if call("vm.status", [vid]).get("state") != "RUNNING":
                return
        raise RuntimeError("VM did not stop")

    print("version:", call("system.info").get("version"), flush=True)
    vm = find()

    # ── --show ────────────────────────────────────────────────────────────────
    if MODE == "show":
        if not vm:
            print(f"  no VM named {NAME}")
        else:
            show(vm)
        print("nic_attach_choices:", call("vm.device.nic_attach_choices"))
        sys.exit(0)

    # ── --eject-cdrom ─────────────────────────────────────────────────────────
    # Device deletion REQUIRES a stopped VM ("Please stop/resume associated VM before deleting
    # VM device"), so this is stop → delete → start, not a live eject.
    if MODE == "eject":
        if not vm:
            sys.exit(f"ERROR: no VM named {NAME}")
        cds = [d for d in devices(vm["id"]) if d["attributes"].get("dtype") == "CDROM"]
        if not cds:
            print("  no CDROM attached — nothing to do"); sys.exit(0)
        was_running = call("vm.status", [vm["id"]]).get("state") == "RUNNING"
        stop(vm["id"])
        for d in cds:
            print("  deleting CDROM id", d["id"], d["attributes"].get("path"))
            call("vm.device.delete", [d["id"]])
        show(find())
        if was_running:
            call("vm.start", [vm["id"]]); time.sleep(4)
            print("  state:", call("vm.status", [vm["id"]]).get("state"))
        sys.exit(0)

    # ── --force: delete and rebuild ───────────────────────────────────────────
    if vm and MODE == "recreate":
        print(f"  deleting VM {vm['id']} ({NAME}) and its zvol")
        stop(vm["id"])
        call("vm.delete", [vm["id"], {"zvols": True, "force": True}])
        vm = None

    if vm:
        print(f"  VM {NAME} already exists (id {vm['id']}) — nothing to do (use --force to rebuild)")
        show(vm)
        sys.exit(0)

    # ── Stage the ISO ─────────────────────────────────────────────────────────
    iso_dir, iso_name = ISO_PATH.rsplit("/", 1)
    have = False
    try:
        st = call("filesystem.stat", [ISO_PATH])
        have = st.get("type") == "FILE" and st.get("size", 0) > 0
    except Exception:
        have = False
    if have:
        print(f"  ISO present on the appliance: {ISO_PATH} ({st['size']} bytes)")
    elif ISO_STAGED:
        print(f"  uploading ISO -> {ISO_PATH}", flush=True)
        upload(tn, ISO_STAGED, iso_dir, iso_name)
    else:
        sys.exit(f"ERROR: {ISO_PATH} is not on the appliance and no --iso was given")

    # ── Create ────────────────────────────────────────────────────────────────
    vid = call("vm.create", [{"name": NAME, "bootloader": "UEFI", "vcpus": 1,
                              "cores": CPU, "threads": 1, "memory": MEM,
                              "autostart": True,
                              "description": "k8s node VM (createTrueNasVM.sh)"}])["id"]
    print(f"  created VM id {vid}")

    # ⚠ ORDER IS THE WHOLE GAME — see the header. DISK below CDROM.
    call("vm.device.create", [{"vm": vid, "order": 1001, "attributes": {
        "dtype": "DISK", "create_zvol": True,
        "zvol_name": f"{POOL}/vms/{NAME}", "zvol_volsize": DISK * 1024**3,
        "type": "AHCI"}}])
    print(f"    DISK  order=1001  {POOL}/vms/{NAME} ({DISK} GiB)")

    call("vm.device.create", [{"vm": vid, "order": 1002, "attributes": {
        "dtype": "CDROM", "path": ISO_PATH}}])
    print(f"    CDROM order=1002  {ISO_PATH}")

    choices = call("vm.device.nic_attach_choices") or {}
    flat = {n for v in choices.values() for n in v} if isinstance(choices, dict) else set()
    if flat and NIC_ATTACH not in flat:
        sys.exit(f"ERROR: nic '{NIC_ATTACH}' not attachable; choices={choices}")
    nic_attrs = {"dtype": "NIC", "nic_attach": NIC_ATTACH, "type": NIC_MODEL}
    # Pinning the MAC is what makes the router's DHCP reservation survive a rebuild.
    if NIC_MAC:
        nic_attrs["mac"] = NIC_MAC
    call("vm.device.create", [{"vm": vid, "order": 1003, "attributes": nic_attrs}])
    mode = "bridge" if any(NIC_ATTACH in v for k, v in choices.items() if k == "BRIDGE") else "macvlan"
    print(f"    NIC   order=1003  {NIC_ATTACH} ({NIC_MODEL}, attaches as {mode})"
          + (f" mac={NIC_MAC} (pinned)" if NIC_MAC else " mac=<random>"))

    # ⚠ `password` is REQUIRED despite the schema marking it optional.
    ports = call("vm.port_wizard") or {}
    call("vm.device.create", [{"vm": vid, "order": 1004, "attributes": {
        "dtype": "DISPLAY", "type": "SPICE",
        "port": ports.get("port", 5900), "web_port": ports.get("web", 5901),
        "bind": "0.0.0.0", "resolution": "1024x768", "web": True,
        "password": DPW}}])
    print(f"    DISPLAY order=1004  SPICE {ports.get('port', 5900)}/{ports.get('web', 5901)}")

    call("vm.start", [vid]); time.sleep(4)
    vm = find()
    show(vm)
    mac = next((d["attributes"].get("mac") for d in devices(vid)
                if d["attributes"].get("dtype") == "NIC"), None)
    print("MAC=" + (mac or ""))
PYVM

python3 -c "import ast,sys; ast.parse(open('$WORK/vm.py').read())" \
  || { echo "ERROR: generated vm.py does not parse" >&2; exit 1; }

TRANSPORT="$(pick_transport)"
echo "transport : $TRANSPORT"

# ── Destructive-path confirmation ────────────────────────────────────────────
# ⚠ Asked HERE, before anything is applied, and asked about the LIVE CLUSTER rather than only
# the appliance: once this VM has been through phase B it is a k8s node, and the expensive part
# of deleting it is the node state, not the VM. Naming the node makes that concrete.
if [[ "$MODE" == "recreate" && "$ASSUME_YES" != "true" ]]; then
  echo "⚠ --force will DELETE VM '$NAME' on $TN_ENDPOINT, INCLUDING its zvol."
  echo "  Everything on its disk is lost."
  NODE_ID=$(perl -ne 'print "$1" if /^\s*id:\s*"([^"]*fs-vm[^"]*)"/' "$PROJECT_SETTINGS_FILE" | head -1)
  if [[ -n "$NODE_ID" ]] && command -v kubectl >/dev/null && kubectl get node "$NODE_ID" &>/dev/null; then
    echo
    echo "  ⚠ '$NODE_ID' IS CURRENTLY A NODE IN THIS CLUSTER:"
    kubectl get node "$NODE_ID" -o wide 2>/dev/null | sed 's/^/      /'
    echo "      Deleting the VM strands this node and its headscale machine. This script does"
    echo "      NOT clean either up — scripts/provisioning/decomissionNode.sh does."
  fi
  echo
  read -rp "  type the VM name to confirm: " _confirm
  [[ "$_confirm" == "$NAME" ]] || { echo "aborted (got '$_confirm')"; exit 1; }
  echo
fi

# The SPICE console password lives in the Pulumi stack, generated once. A DISPLAY cannot be
# created without one, and reusing a stack-held secret beats minting a throwaway nobody records.
DISPLAY_PW=""
if command -v pulumi >/dev/null; then
  DISPLAY_PW="$(pulumi -C "$ROOT_DIR" config get truenasVmDisplayPassword 2>/dev/null || true)"
fi
if [[ -z "$DISPLAY_PW" ]]; then
  DISPLAY_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  if command -v pulumi >/dev/null; then
    pulumi -C "$ROOT_DIR" config set --secret truenasVmDisplayPassword "$DISPLAY_PW" >/dev/null 2>&1 \
      && echo "generated truenasVmDisplayPassword into the Pulumi stack"
  fi
fi

ISO_REMOTE="$ISO_REMOTE_DIR/$ISO_REMOTE_NAME"
[[ -n "$ISO_LOCAL" && ! -f "$ISO_LOCAL" ]] && { echo "ERROR: --iso '$ISO_LOCAL' not found" >&2; exit 1; }

# ── Execute ──────────────────────────────────────────────────────────────────
OUT="$WORK/out.txt"
if [[ "$TRANSPORT" == "ssh" ]]; then
  # Cluster-free path — everything it needs is in the Pulumi stack.
  RELAY_HOST="${FS_VM_RELAY_HOST:-jump.your-domain.tld}"
  RELAY_PORT="${FS_VM_RELAY_PORT:-3002}"
  RELAY_USER="${FS_VM_RELAY_USER:-cape}"
  command -v pulumi >/dev/null || { echo "ERROR: pulumi not found (needed for transport=ssh)" >&2; exit 1; }
  KEYF="$WORK/relay.key"
  pulumi -C "$ROOT_DIR" config get sshkey-ecc-mesh > "$KEYF" 2>/dev/null || {
    echo "ERROR: could not read sshkey-ecc-mesh from the Pulumi stack." >&2
    echo "       Load it first: source ./scripts/pulumi/initPulumiStack.sh" >&2; exit 1; }
  chmod 600 "$KEYF"
  [[ -s "$KEYF" ]] || { echo "ERROR: sshkey-ecc-mesh is empty" >&2; exit 1; }
  TN_USER_V="$(pulumi -C "$ROOT_DIR" config get truenasAdminUser 2>/dev/null || true)"
  TN_PASS_V="$(pulumi -C "$ROOT_DIR" config get truenasAdminPassword 2>/dev/null || true)"
  if [[ -z "$TN_USER_V" || -z "$TN_PASS_V" ]]; then
    echo "ERROR: truenasAdminUser/truenasAdminPassword not in the Pulumi stack." >&2
    echo "       Seed them by running deployment/argocd-infra/truenas/sealSecrets.sh" >&2
    exit 1
  fi
  SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=15 -o LogLevel=ERROR -i "$KEYF")
  REMOTE_DIR="/tmp/fs-vm-$$"
  echo "running via ssh relay $RELAY_USER@$RELAY_HOST:$RELAY_PORT ..."
  ssh "${SSH_OPTS[@]}" -p "$RELAY_PORT" "$RELAY_USER@$RELAY_HOST" "mkdir -p $REMOTE_DIR" \
    || { echo "ERROR: cannot reach the relay host over SSH" >&2; exit 1; }
  scp -q "${SSH_OPTS[@]}" -P "$RELAY_PORT" "$WORK/tnclient.py" "$WORK/vm.py" \
      "$RELAY_USER@$RELAY_HOST:$REMOTE_DIR/"
  STAGED=""
  if [[ -n "$ISO_LOCAL" ]]; then
    echo "staging ISO to the relay (this is the slow part) ..."
    scp -q "${SSH_OPTS[@]}" -P "$RELAY_PORT" "$ISO_LOCAL" "$RELAY_USER@$RELAY_HOST:$REMOTE_DIR/iso.img"
    STAGED="$REMOTE_DIR/iso.img"
  fi
  # ⚠ THE CREDENTIAL GOES OVER STDIN, NEVER IN argv. Interpolating it into the ssh command
  # string makes it a process ARGUMENT on a shared lab box, readable via `ps` by any other
  # user — and this is the appliance ADMIN password, the one that can mint API keys.
  set +e
  {
    printf 'export TN_HOST=%s TN_USER=%s TN_PASS=%s\n' \
      "$(printf %q "$TN_ENDPOINT")" "$(printf %q "$TN_USER_V")" "$(printf %q "$TN_PASS_V")"
    printf 'export V_NAME=%s V_MODE=%s V_MEMORY_GB=%s V_CPU=%s V_DISK_GB=%s V_POOL=%s\n' \
      "$(printf %q "$NAME")" "$(printf %q "$MODE")" "$(printf %q "$MEMORY_GB")" \
      "$(printf %q "$CPU")" "$(printf %q "$DISK_GB")" "$(printf %q "$POOL")"
    printf 'export V_NIC=%s V_NIC_MODEL=%s V_NIC_MAC=%s V_ISO_REMOTE=%s V_ISO_STAGED=%s V_DISPLAY_PW=%s\n' \
      "$(printf %q "$NIC_ATTACH")" "$(printf %q "$NIC_MODEL")" "$(printf %q "$NIC_MAC")" \
      "$(printf %q "$ISO_REMOTE")" "$(printf %q "$STAGED")" "$(printf %q "$DISPLAY_PW")"
    printf 'python3 %s/vm.py; rc=$?; rm -rf %s; exit $rc\n' "$REMOTE_DIR" "$REMOTE_DIR"
  } | ssh "${SSH_OPTS[@]}" -p "$RELAY_PORT" "$RELAY_USER@$RELAY_HOST" "sh -s" 2>&1 | tee "$OUT"
  RC=${PIPESTATUS[1]}
  set -e
else
  # Only reachable with an EXPLICIT --via-cluster (auto-selection already retried and would
  # have chosen ssh), so honour the operator's choice and fail rather than silently switching.
  if ! lab_node_present 5; then
    echo "ERROR: --via-cluster was requested but no node carries ecc/fileserver-lan=true." >&2
    echo "       Node labels lag project_settings after a recreate; check:" >&2
    echo "         kubectl get nodes -L ecc/fileserver-lan,ecc/site" >&2
    echo "       Or use the cluster-free path: --via-ssh" >&2
    exit 1
  fi
  if [[ -n "$ISO_LOCAL" ]]; then
    echo "ERROR: --iso is only supported on the ssh transport (a Job has no local file to send)." >&2
    echo "       Upload it once by hand, or re-run with --via-ssh." >&2
    exit 1
  fi
  TN_USER_V="$(kubectl -n "$NAMESPACE" get secret truenas-admin -o jsonpath='{.data.TRUENAS_ADMIN_USER}' 2>/dev/null | base64 -d)"
  TN_PASS_V="$(kubectl -n "$NAMESPACE" get secret truenas-admin -o jsonpath='{.data.TRUENAS_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)"
  if [[ -z "$TN_USER_V" || -z "$TN_PASS_V" ]]; then
    echo "ERROR: secret truenas-admin not found/complete in namespace $NAMESPACE." >&2
    echo "       It is sealed by deployment/argocd-infra/truenas/sealSecrets.sh and applied" >&2
    echo "       by the wave16-truenas app — sync that app first, or use --via-ssh." >&2
    exit 1
  fi
  B1=$(base64 -w0 "$WORK/tnclient.py"); B2=$(base64 -w0 "$WORK/vm.py")
  set +e
  kubectl run "createvm-$RANDOM" --rm -i --restart=Never --image=python:3.12-alpine \
    --overrides='{"spec":{"nodeSelector":{"ecc/fileserver-lan":"true"},"tolerations":[{"key":"ecc/mesh","operator":"Exists","effect":"NoSchedule"}]}}' \
    --env="TN_HOST=$TN_ENDPOINT" --env="TN_USER=$TN_USER_V" --env="TN_PASS=$TN_PASS_V" \
    --env="V_NAME=$NAME" --env="V_MODE=$MODE" --env="V_MEMORY_GB=$MEMORY_GB" \
    --env="V_CPU=$CPU" --env="V_DISK_GB=$DISK_GB" --env="V_POOL=$POOL" \
    --env="V_NIC=$NIC_ATTACH" --env="V_NIC_MODEL=$NIC_MODEL" --env="V_NIC_MAC=$NIC_MAC" \
    --env="V_ISO_REMOTE=$ISO_REMOTE" --env="V_DISPLAY_PW=$DISPLAY_PW" \
    --env="B1=$B1" --env="B2=$B2" \
    --command -- sh -c 'mkdir -p /w; echo "$B1"|base64 -d>/w/tnclient.py; echo "$B2"|base64 -d>/w/vm.py; python /w/vm.py' 2>&1 | tee "$OUT"
  RC=${PIPESTATUS[0]}
  set -e
fi

[[ "${RC:-0}" -eq 0 ]] || { echo "ERROR: the appliance step failed (rc=$RC)" >&2; exit "$RC"; }
[[ "$MODE" == "show" || "$MODE" == "eject" ]] && exit 0

# ── Wait for the guest ───────────────────────────────────────────────────────
# ⚠ NOT via ARP: the guest's MAC may never appear in a lab node's neighbour table even while it
# is up and answering. Poll the SSH port, then require a `cape` login — the installer's live
# environment also answers :22 but has no such user, so an open port alone means "installing".
if [[ "$SKIP_WAIT" == "true" ]]; then
  echo
  echo "--no-wait: skipping the install watch. The autoinstall takes ~13 min, then the VM"
  echo "reboots itself into the installed system."
  exit 0
fi

NODE_SSH_PORT=$(perl -ne '
    if (/^\s*id:\s*"[^"]*fs-vm[^"]*"/) { $in = 1 }
    if ($in && /^\s*port:\s*(\d+)/) { print "$1"; exit }
' "$PROJECT_SETTINGS_FILE")
NODE_SSH_HOST=$(perl -ne '
    if (/^\s*id:\s*"[^"]*fs-vm[^"]*"/) { $in = 1 }
    if ($in && /^\s*endpoint:\s*"([^"]+)"/) { print "$1"; exit }
' "$PROJECT_SETTINGS_FILE")

echo
if [[ -z "$NODE_SSH_PORT" || -z "$NODE_SSH_HOST" ]]; then
  echo "No fs-vm ssh: block in project_settings — cannot watch the install from here."
  echo "The autoinstall takes ~13 min; then the VM reboots into the installed system."
  exit 0
fi

echo "waiting for the autoinstall to finish (up to ${WAIT_SECS}s) ..."
echo "  watching $NODE_SSH_HOST:$NODE_SSH_PORT for a working 'cape' login"
# ⚠ THE PROBE MUST NOT VERIFY THE HOST KEY. This VM has just been REINSTALLED, so it
# presents a NEW host key by definition — and the wrapper (sshConnectNode.sh) uses
# StrictHostKeyChecking=accept-new, which accepts an UNKNOWN host but still REFUSES a CHANGED
# one. Every probe then dies with "Host key verification failed", which with stderr discarded
# is indistinguishable from "cape does not exist yet", so the loop waits out its whole budget
# on a guest that is up and fine.
# a 40-minute TIMEOUT on a VM that had been installed and reachable for
# 28 of those minutes.
#
# So the probe talks to the guest DIRECTLY with checking disabled and known_hosts pointed at
# /dev/null, rather than going through the wrapper. That is safe HERE and only here: this is
# a liveness probe on a box we just built ourselves, on a port we just created, and it runs
# no commands beyond `hostname`. Everything afterwards — provisioning, adoption, day-to-day
# access — goes back through sshConnectNode.sh with its normal checking.
#
# The key selection trick is kept: -o IdentitiesOnly=yes -i <PUBLIC key> offers exactly the
# one matching agent identity, so the guest's MaxAuthTries is not burned by the agent walking
# through every key it holds. The PRIVATE key never touches disk.
NODE_ID_FOR_SSH=$(perl -ne 'print "$1" if /^\s*id:\s*"([^"]*fs-vm[^"]*)"/' "$PROJECT_SETTINGS_FILE" | head -1)
NODE_SSH_USER=$(perl -ne '
    if (/^\s*id:\s*"[^"]*fs-vm[^"]*"/) { $in = 1 }
    if ($in && /^\s*user:\s*"([^"]+)"/) { print "$1"; exit }
' "$PROJECT_SETTINGS_FILE")
NODE_SSH_USER="${NODE_SSH_USER:-cape}"

# Load the mesh key into the agent and derive its public half (same helper the wrapper uses).
PROBE_PUB=""
if [[ -f "$ROOT_DIR/scripts/pulumi/sshAgentHelpers.sh" ]]; then
  _prev_pwd="$PWD"; cd "$ROOT_DIR"
  # shellcheck source=../pulumi/sshAgentHelpers.sh
  source "$ROOT_DIR/scripts/pulumi/sshAgentHelpers.sh" >/dev/null 2>&1 || true
  ensure_node_ssh_keys_in_agent >/dev/null 2>&1 || true
  cd "$_prev_pwd"
  [[ -f "$ROOT_DIR/tmp/ssh-public-keys/sshkey-ecc-mesh.pub" ]] \
    && PROBE_PUB="$ROOT_DIR/tmp/ssh-public-keys/sshkey-ecc-mesh.pub"
fi

probe_guest() {
  local opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o GlobalKnownHostsFile=/dev/null
              -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=0
              -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
  [[ -n "$PROBE_PUB" ]] && opts+=(-o IdentitiesOnly=yes -i "$PROBE_PUB")
  timeout 45 ssh "${opts[@]}" -p "$NODE_SSH_PORT" \
      "${NODE_SSH_USER}@${NODE_SSH_HOST}" \
      'hostname; . /etc/os-release && echo "$PRETTY_NAME"' 2>/dev/null | tail -2
}

DEADLINE=$(( $(date +%s) + WAIT_SECS ))
LAST=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  if out=$(probe_guest); then
    if [[ -n "$out" ]]; then
      echo
      echo "=== install complete — guest is up ==="
      echo "$out" | sed 's/^/  /'
      echo
      echo "Next:"
      echo "  1. make provision-mesh-node ARGS='<node-id>'   # phase B: mesh + k3s join"
      echo "  2. $0 --eject-cdrom                            # after the install, never during"
      echo "  3. reboot once so dhcp-hostname-refresh applies the DHCP name"
      exit 0
    fi
  fi
  now=$(date +%s); left=$(( DEADLINE - now ))
  msg="  $(date '+%H:%M:%S')  still installing (${left}s left)"
  [[ "$msg" != "$LAST" ]] && { echo "$msg"; LAST="$msg"; }
  sleep 30
done
echo "TIMEOUT after ${WAIT_SECS}s — the guest never accepted a 'cape' login." >&2
echo "  The probe ignores host keys, so this is a real failure to log in, not a stale key." >&2
echo "  Check the SPICE console (port from --show) — a stuck install is invisible otherwise." >&2
echo "  NOTE your own later logins go through sshConnectNode.sh, which DOES check the host key," >&2
echo "  and a reinstalled guest presents a new one. If that refuses, clear it with:" >&2
echo "    ssh-keygen -f ~/.ssh/known_hosts -R '[$NODE_SSH_HOST]:$NODE_SSH_PORT'" >&2
echo "  Also check the qemu log mtime: a RUNNING VM whose log stopped minutes ago is stuck," >&2
echo "  not slow. See doc/truenas-vm.md." >&2
exit 1
