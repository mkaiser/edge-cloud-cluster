#!/bin/bash
# adoptProvisionedNodes.sh — interactive post-join menu for a hand-provisioned mesh node.
#
# After a node has joined the cluster manually (10-install-prereqs → 30-connect-vpn →
# 40-join-cluster, run on the node itself — no SSH from here), it appears as a bare k8s node
# with none of the labels/annotations the Pulumi MeshNodesComponent would apply. This menu
# fills that gap from the devcontainer: labels (role/site/kvm/gpu/nested-runtime), Longhorn storageScope disk
# tags, description, and the provision-fingerprint stamp — mirroring
# generateProvisioningScripts.sh's post-steps so a later `make provision-mesh-node` skip-check
# no-ops the node.
#
# Keyless 2nd-factor approval is NOT done here: a node provisioned with the carry-script
# registers as PENDING and prints a one-time registration URL + QR — approve it in the Headplane
# UI (Machines → "Register machine"), which calls `headscale auth register` for you with a user
# picker. This script prints that Headplane link and then does the post-join k8s work.
# Flow:  approve in Headplane → wait ~30-60s for it to join k3s → run this and Apply (labels/scope).
#
# Runs on the devcontainer (needs kubectl + kubeconfig).
#
# Usage:
#   ./scripts/provisioning/adoptProvisionedNodes.sh                # interactive; pick node from the menu
#   ./scripts/provisioning/adoptProvisionedNodes.sh <node-name>    # preselect the k8s node
#   ./scripts/provisioning/adoptProvisionedNodes.sh <node-name> --nested-runtime gvisor
#                                                     # preseed the nested-runtime labels
#
# ⚠ --nested-runtime only LABELS. The handler is installed on the node by
# 50-install-nested-runtime.sh (step 5 on the carry-script path). Pass the SAME value the
# node was provisioned with: labelling a node whose handler is missing hangs pods selecting
# that RuntimeClass in ContainerCreating.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"

# Headplane admin URL (where a keyless PENDING node is approved: Machines → Register machine).
# Same general.{domain,subdomain} parse as generateProvisioningScripts.sh; first match wins.
_BASE_DOMAIN=$(sed -n 's/^[[:space:]]*domain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
_SUBDOMAIN=$(sed -n 's/^[[:space:]]*subdomain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
HEADPLANE_URL="https://headplane.${_SUBDOMAIN:+${_SUBDOMAIN}.}${_BASE_DOMAIN}/admin/"

kubectl cluster-info &>/dev/null || {
  echo "ERROR: kubectl not connected. Run: ./scripts/runtime/getKubeConfig.sh" >&2; exit 1
}

# ── Selected-node state (populated by choose_node / defaults) ─────────────────
NAME="" ; SITE="" ; KVM="false" ; SCOPES="" ; GPU="" ; NESTED="" ; EDA_BUILDER="false" ; DESCRIPTION=""
# CLI preseed. NESTED_CLI is remembered separately: load_defaults_from_settings() overwrites
# NESTED from project_settings.ts, and an explicit flag must win over that.
NESTED_CLI=""
while [ $# -gt 0 ]; do
  case "$1" in
    --nested-runtime) NESTED_CLI="$2"; shift 2 ;;
    -*) echo "ERROR: unknown option '$1'" >&2; exit 2 ;;
    *)  [ -z "$NAME" ] && { NAME="$1"; shift; } || { echo "ERROR: unexpected arg '$1'" >&2; exit 2; } ;;
  esac
done
case "$NESTED_CLI" in
  ""|gvisor) ;;
  *) echo "ERROR: --nested-runtime must be gvisor or empty (got '$NESTED_CLI')." >&2; exit 2 ;;
esac
HOST="" ; PORT="22" ; SSH_USER="root"   # only used to recompute the provision-fingerprint

# ── Parse a node's declared defaults from project_settings.ts (best-effort) ───
# Same depth-aware perl parse as generateProvisioningScripts.sh. Emits the pipe record for the
# node whose id matches $1 so the menu can pre-fill site/scope/kvm/gpu/desc/host/port/user.
load_defaults_from_settings() {
  local want="$1"
  local rec
  rec=$(perl -0777 -ne '
    s{//[^\n]*}{}g;
    if (/mesh:\s*\[(.*?)\]\s*as\s+ComputeNodeMesh/s) {
      my $blk=$1; my $depth=0; my $cur=""; my @objs;
      for my $ch (split //, $blk){ $depth++ if $ch eq "{"; $cur.=$ch if $depth>0;
        if($ch eq "}"){ $depth--; if($depth==0){ push @objs,$cur; $cur=""; } } }
      for my $o (@objs){
        my ($id)=$o=~/id:\s*"([^"]+)"/;
        next unless $id;
        my ($host)=$o=~/endpoint:\s*"([^"]+)"/;
        my ($port)=$o=~/port:\s*(\d+)/;
        my ($user)=$o=~/user:\s*"([^"]+)"/;
        my ($site)=$o=~/site:\s*"([^"]+)"/;
        my ($kvm)=$o=~/kvm:\s*(true|false)/;
        my ($desc)=$o=~/description:\s*"([^"]*)"/;
        my ($sc)=$o=~/storageScope:\s*\[([^\]]*)\]/;
        $sc=~s/"//g; $sc=~s/\s+//g if defined $sc;
        # \b so this does not also swallow the `nestedRuntime:` value parsed next.
        my ($gpu)=$o=~/\bgpu:\s*"([^"]+)"/;
        my ($nested)=$o=~/\bnestedRuntime:\s*"([^"]+)"/;
        my ($eda)=$o=~/\bedaBuilder:\s*(true|false)/;
        $port||=22; $user||="root"; $site||=""; $kvm||="false";
        $desc=defined $desc?$desc:""; $sc=defined $sc?$sc:""; $gpu=defined $gpu?$gpu:"";
        $nested=defined $nested?$nested:""; $eda||="false";
        print "$id|$user\@$host|$port|$site|$kvm|$desc|$sc|$gpu|$nested|$eda\n";
      }
    }' "$PROJECT_SETTINGS_FILE" | awk -F'|' -v w="$want" '$1==w{print; exit}')
  [ -n "$rec" ] || return 1
  local addr
  IFS='|' read -r _ addr PORT SITE KVM DESCRIPTION SCOPES GPU NESTED EDA_BUILDER <<<"$rec"
  HOST="${addr#*@}" ; SSH_USER="${addr%@*}"
  return 0
}

# ── Pick a k8s node ───────────────────────────────────────────────────────────
choose_node() {
  echo ""
  echo "Cluster nodes (mesh nodes lack the ROLE 'mesh' until adopted):"
  kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
  echo ""
  local nodes; mapfile -t nodes < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
  [ "${#nodes[@]}" -gt 0 ] || { echo "ERROR: no nodes found." >&2; exit 1; }
  local i=1
  for n in "${nodes[@]}"; do printf "  %2d) %s\n" "$i" "$n"; i=$((i+1)); done
  echo ""
  # A node that has not been approved yet is absent from this list entirely — it never joined
  # k3s. That, not a missing label, is what "I don't see my node" means, so point at Headplane
  # only here rather than on every menu redraw.
  echo "  (node missing? it is still PENDING approval — approve it first at"
  echo "   ${HEADPLANE_URL} → Machines → Register machine)"
  echo ""
  printf "Select node number: "
  local sel; read -r sel
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#nodes[@]}" ] || {
    echo "ERROR: invalid selection." >&2; exit 1; }
  NAME="${nodes[$((sel-1))]}"
}

# ── Prompt helper: read with a default shown in [brackets] ────────────────────
ask() { # ask <prompt> <default> -> echoes answer (default if empty)
  # Prompt goes to STDERR: callers use $(ask ...), which captures stdout — printing the
  # prompt to stdout would swallow it (never shown) AND fold it into the captured answer.
  #
  # Enter keeps the default, so with a NON-EMPTY default there is otherwise no keystroke that
  # means "make this empty" — `-` is that keystroke. It matters for the optional fields (gpu,
  # nested-runtime, description): a node that had a GPU label and no longer should needs a way
  # to clear it, and on the validated fields the operator would otherwise be stuck (see the
  # retry loops below).
  local p="$1" d="$2" a
  printf "%s [%s]: " "$p" "$d" >&2; read -r a
  case "$a" in
    -) echo "" ;;            # explicit clear
    "") echo "$d" ;;         # Enter keeps the default
    *) echo "$a" ;;
  esac
}
ask_yn() { # ask_yn <prompt> <default true|false>
  local p="$1" d="$2" a def
  def=$([ "$d" = "true" ] && echo Y/n || echo y/N)
  printf "%s (%s): " "$p" "$def" >&2; read -r a  # prompt to stderr (see ask())
  a="${a:-$d}"
  case "$a" in y|Y|yes|true|Y/n) echo true ;; *) echo false ;; esac
}

# ── Actions ───────────────────────────────────────────────────────────────────
# NOTE: approving a keyless PENDING node is NOT done here — do it in the Headplane UI
# (Machines → "Register machine": paste the registration URL/auth-id the node printed, pick the
# user, click). Headplane calls `headscale auth register` for you, with a user dropdown, so a
# terminal step would just be a worse copy of it. This script only does the post-join k8s work.
# CLI fallback if Headplane is unavailable:
#   kubectl exec -n headscale deploy/headscale -- \
#     headscale auth register --user on-premise-resident --auth-id <hskey-authreq-…>

# Print a short indented help block for a field (each extra arg = one line).
guide() { local l; for l in "$@"; do printf "      %s\n" "$l"; done; }

action_edit_metadata() {
  echo ""
  echo "Edit metadata for node: $NAME  (Enter keeps the shown default, - clears it)"
  echo "These mirror what the Pulumi MeshNodesComponent would set for a nodes.mesh entry."

  echo ""
  guide "ecc/site — the node's failure/latency domain. One LAN = one site." \
        "Nodes sharing a site share a failure domain; give boxes on the same" \
        "physical/VPN LAN the SAME string (e.g. 'unibi-hclab', 'home-martin')."
  SITE=$(ask "  ecc/site" "$SITE")

  echo ""
  guide "ecc/kvm — mark the node KVM-capable (flex tier / KVM-anywhere)." \
        "Set true only if it can run KVM VMs (e.g. Windows raw-block workloads)."
  KVM=$(ask_yn "  KVM-capable (ecc/kvm=true)" "$KVM")

  echo ""
  guide "GPU type — Nvidia Jetson model; drives GPU host enablement, the ecc/gpu=true +
        ecc/gpu-model labels, and the ecc/gpu=true:NoSchedule opt-in taint." \
        "Valid: jetson-thor | jetson-orin | nvidia-turing-sm75, or - for no GPU."
  # Validate into a SCRATCH var, never back into GPU: assigning the rejected value would make
  # it the next iteration's default, so Enter would re-submit it and the loop could never be
  # escaped. Keep the last GOOD value as the default instead. `-` clears (see ask()).
  local _gpu
  while :; do
    _gpu=$(ask "  ecc/gpu" "$GPU")
    case "${_gpu// }" in
      ""|jetson-thor|jetson-orin|nvidia-turing-sm75) GPU="$_gpu"; break ;;
      *) echo "      ! must be jetson-thor, jetson-orin, nvidia-turing-sm75, or empty (got '$_gpu')." \
              "Enter keeps '$GPU'; type - to clear." ;;
    esac
  done

  echo ""
  guide "nestedRuntime — lets pods on this node run inner OCI containers WITHOUT being
        privileged, via runtimeClassName. Stamps ecc/nested-runtime=<t> plus the
        per-handler ecc/nested-runtime-gvisor boolean the RuntimeClass selects on." \
        "⚠ THIS ONLY LABELS. The handler itself is installed by" \
        "50-install-nested-runtime.sh (provisioning step 5 on the carry-script path)." \
        "Labelling a node whose handler is NOT installed hangs those pods in" \
        "ContainerCreating — verify with 'which runsc' on the box." \
        "Valid: gvisor, or - for none."
  local _nested
  while :; do
    _nested=$(ask "  ecc/nested-runtime" "$NESTED")
    case "${_nested// }" in
      ""|gvisor) NESTED="$_nested"; break ;;
      *) echo "      ! must be gvisor or empty (got '$_nested')." \
              "Enter keeps '$NESTED'; type - to clear." ;;
    esac
  done

  echo ""
  guide "ecc/eda-builder — mark this node an EDA image-build host. The shared [eda] GitLab
        runner's node_selector matches this label instead of a hostname, so a build can
        land on any enrolled node." \
        "⚠ Also needs the node to be at the fileserver site (it then gets" \
        "ecc/fileserver-lan=true automatically): csi-driver-nfs runs only on" \
        "those nodes, so the installer-media PVC cannot mount elsewhere." \
        "⚠ Only safe while that runner keeps concurrent=1 — /build-scratch is a" \
        "node-local hostPath and its flock does not serialise across nodes."
  EDA_BUILDER=$(ask_yn "  EDA build host (ecc/eda-builder=true)" "$EDA_BUILDER")

  echo ""
  guide "storageScope — shared Longhorn storage with tightly-coupled nodes." \
        "CSV of disk tags (first = primary); nodes sharing a tag hold replicas" \
        "of the same longhorn-<scope> StorageClass. A tag shared across sites =" \
        "cross-LAN redundancy; a single-node tag = replica 1." \
        "REQUIRED (>=1, no empty tags) — matches the Pulumi validator. Without a" \
        "tag the node's Longhorn disk holds no scoped volume and is dead weight." \
        "e.g. 'unibi-hclab,unibi'  (strict-local scope + cross-LAN unibi scope)."
  # Required, >=1 non-empty tag — mirror validateClusterNodes in project_settings_types.ts.
  local _scopes trimmed
  while :; do
    _scopes=$(ask "  Longhorn storageScope CSV" "$SCOPES")
    trimmed="${_scopes// /}"
    if [ -z "$trimmed" ]; then
      echo "      ! storageScope is required (>=1 tag)."
    elif [[ ",$trimmed," == *",,"* ]]; then
      echo "      ! storageScope has an empty tag (no ',,' or leading/trailing ',')."
    else
      SCOPES="$_scopes"; break
    fi
  done

  echo ""
  guide "ecc/description — free-text note annotated on the node (optional)."
  DESCRIPTION=$(ask "  ecc/description" "$DESCRIPTION")

  # SSH host/port/user are NOT prompted here — they are node identity from
  # project_settings.ts nodes.mesh (pre-filled above), used only to compute the
  # ecc/provision-fingerprint in action_apply. Editing them by hand would just
  # break that stamp.

  # Offer to apply immediately (auto-select menu 4) — the common next step after
  # entering metadata. Show the resulting config first so the user confirms it.
  action_show
  if [ "$(ask_yn "Apply this config to the cluster now (menu 4)" "true")" = "true" ]; then
    action_apply
  else
    echo "Not applied. Choose 4) later to apply."
  fi
}

action_show() {
  echo ""
  echo "Pending config for $NAME:"
  echo "  ecc/site        : ${SITE:-<none>}"
  echo "  ecc/kvm         : $KVM"
  echo "  ecc/gpu         : ${GPU:-<none>}"
  echo "  nested-runtime  : ${NESTED:-<none>}"
  echo "  ecc/eda-builder : $EDA_BUILDER"
  echo "  storageScope    : ${SCOPES:-<none>}"
  echo "  ecc/description : ${DESCRIPTION:-<none>}"
  echo "  fingerprint from: host=${HOST:-<none>} port=$PORT user=$SSH_USER"
  echo ""
  echo "Currently on the node:"
  kubectl get node "$NAME" -o jsonpath='  labels: {.metadata.labels}{"\n"}  annotations: {.metadata.annotations}{"\n"}' 2>/dev/null || true
  echo ""
}

action_apply() {
  kubectl get node "$NAME" &>/dev/null || {
    echo "ERROR: node '$NAME' not found in the cluster. Has it joined yet?" >&2; return 1; }

  echo ""
  echo "Applying to $NAME…"
  # Labels — node-role value is EMPTY (k8s reads only the key for the ROLE column), matching
  # MeshNodesComponent so a later `make provision-mesh-node` skip-check agrees.
  local labels=("node-role.kubernetes.io/mesh=" "node.kubernetes.io/mesh-worker=true")
  [ -n "${SITE// }" ] && labels+=("ecc/site=${SITE}")
  [ "$KVM" = "true" ] && labels+=("ecc/kvm=true")
  # Capability + model, and the opt-in taint — must match the Pulumi path
  # (src/nodes-k3s-mesh.ts), or a hand-adopted GPU node silently accepts every
  # non-GPU workload while the Pulumi-provisioned ones repel them.
  [ -n "${GPU// }" ]  && labels+=("ecc/gpu=true" "ecc/gpu-model=${GPU}")
  # EDA image-build host — same label as src/nodes-k3s-mesh.ts.
  [ "$EDA_BUILDER" = "true" ] && labels+=("ecc/eda-builder=true")
  # Nested-container runtime — same label set as src/nodes-k3s-mesh.ts. The per-handler
  # booleans are what the RuntimeClass nodeSelectors match on.
  # ⚠ These LABEL only; 50-install-nested-runtime.sh installs the handler. On the
  # carry-script path that is provision step 5 — run it BEFORE this, or the node advertises
  # a runtime it does not have and those pods hang in ContainerCreating.
  if [ -n "${NESTED// }" ]; then
    labels+=("ecc/nested-runtime=${NESTED}")
    if [ "$NESTED" = "gvisor" ]; then labels+=("ecc/nested-runtime-gvisor=true"); fi
  fi
  kubectl label node "$NAME" "${labels[@]}" --overwrite
  if [ -n "${GPU// }" ]; then
    kubectl taint node "$NAME" ecc/gpu=true:NoSchedule --overwrite
  else
    kubectl taint node "$NAME" ecc/gpu- 2>/dev/null || true
  fi

  # Longhorn per-scope disk tags (first scope = primary), same shape as the Pulumi path.
  if [ -n "${SCOPES// }" ]; then
    local disk_tags disk_cfg
    disk_tags=$(printf '"%s",' ${SCOPES//,/ }); disk_tags="[${disk_tags%,}]"
    disk_cfg="[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"tags\":${disk_tags}}]"
    kubectl label node "$NAME" node.longhorn.io/create-default-disk=config --overwrite
    kubectl annotate node "$NAME" "node.longhorn.io/default-disks-config=${disk_cfg}" --overwrite

    # The annotation ONLY takes effect when Longhorn first creates the disk. On the manual
    # path the node joins minutes before this script runs, so longhorn-manager has already
    # created the disk — tagged with the node's hostname — and never re-reads the annotation.
    # Adoption would then silently leave the node out of every longhorn-<scope> StorageClass
    # it is supposed to back. So patch the live node CR too, which is what actually decides
    # replica placement. No-op when the CR does not exist yet (Longhorn not up); the
    # annotation covers that case.
    if kubectl get nodes.longhorn.io -n longhorn-system "$NAME" >/dev/null 2>&1; then
      local lh_patch
      # ⚠ ONLY the default /var/lib/longhorn disk is retagged here. A node may carry EXTRA
      # Longhorn disks (project_settings extraLonghornDisks), and this script's Perl parser
      # does not read that nested array — `[^\]]*` stops at the first `]`. Blanket-stamping
      # every disk with the node's storageScope would therefore silently flatten per-disk
      # tags that the Pulumi path (src/nodes-k3s-mesh.ts) had set deliberately. Match on
      # PATH and leave every other disk alone; the Pulumi path owns those.
      lh_patch=$(kubectl get nodes.longhorn.io -n longhorn-system "$NAME" -o json \
        | SCOPE_TAGS="${SCOPES// /}" python3 -c "
import json,os,sys
tags = [t for t in os.environ['SCOPE_TAGS'].split(',') if t]
node = json.load(sys.stdin)
disks = node.get('spec',{}).get('disks',{})
for d in disks.values():
    if d.get('path') == '/var/lib/longhorn':
        d['tags'] = tags
print(json.dumps({'spec':{'disks':disks}}))
" 2>/dev/null || true)
      if [ -n "$lh_patch" ]; then
        if kubectl patch nodes.longhorn.io -n longhorn-system "$NAME" \
             --type merge -p "$lh_patch" >/dev/null 2>&1; then
          echo "  Longhorn disk tags set to [${SCOPES// /}]."
        else
          echo "  NOTE: could not patch Longhorn disk tags — set them in the Longhorn UI"
          echo "        (Node → Edit node and disks → Disk Tags): ${SCOPES// /}"
        fi
      fi
    fi
  fi

  [ -n "${DESCRIPTION// }" ] && kubectl annotate node "$NAME" "ecc/description=${DESCRIPTION}" --overwrite

  # Stamp the box fingerprint so `make provision-mesh-node` sees the node as already provisioned.
  # fpBox = sha256(JSON.stringify([id,host,port,user]))[:16] — port is a bare number (no quotes),
  # matching the TS `sha` in nodes-k3s-mesh.ts. Only meaningful if host/port/user match the
  # project_settings.ts entry; harmless otherwise.
  if [ -n "${HOST// }" ]; then
    local fp
    fp=$(printf '["%s","%s",%s,"%s"]' "$NAME" "$HOST" "$PORT" "$SSH_USER" | sha256sum | cut -c1-16)
    kubectl annotate node "$NAME" "ecc/provision-fingerprint=${fp}" --overwrite
  fi

  # Tag the tailnet node tag:k8s-node. The pre-auth-key paths apply this at MINT time via
  # `--tags`, but a KEYLESS join cannot: `headscale auth register` takes no --tags. An
  # untagged node gets a tailnet IP and matches only the ACL policy's permissive raw-user
  # half, staying outside every tag-based grant — so without this a hand-provisioned node is
  # not equivalent to a Pulumi-provisioned one, which is the whole point of this script.
  #
  # Non-fatal: headscale may be unreachable, and the k8s-side adoption above is still valid
  # without it. Idempotent — re-tagging an already-tagged node is a no-op.
  tag_tailnet_node

  kubectl uncordon "$NAME" 2>/dev/null || true
  echo "Applied. Node $NAME adopted."
}

# Match the tailnet node by hostname. 30-connect-vpn.sh sets --hostname to the k8s node name
# (ECC_NODE_NAME), so the two agree; a node re-registered after a wipe appears as <name>-1,
# <name>-2, … and would NOT match here — tag those by id from `headscale nodes list`.
tag_tailnet_node() {
  local hs_pod hs_id
  hs_pod=$(kubectl get pods -n headscale -l app.kubernetes.io/name=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$hs_pod" ] || hs_pod=$(kubectl get pods -n headscale -l app=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$hs_pod" ]; then
    echo "  NOTE: headscale pod not found — skipping tag:k8s-node."
    echo "        Tag it later: headscale nodes tag -i <node-id> -t tag:k8s-node"
    return 0
  fi

  hs_id=$(kubectl exec -n headscale "$hs_pod" -- headscale nodes list -o json 2>/dev/null \
    | python3 -c "
import json,sys
try: nodes = json.load(sys.stdin)
except Exception: sys.exit(0)
want = sys.argv[1]
for n in nodes:
    if n.get('name') == want or n.get('given_name') == want:
        print(n.get('id','')); break
" "$NAME" 2>/dev/null || true)

  if [ -z "$hs_id" ]; then
    echo "  NOTE: no tailnet node named '$NAME' — skipping tag:k8s-node."
    echo "        (a re-registered node appears as ${NAME}-1, -2, …; tag it by id)"
    return 0
  fi

  if kubectl exec -n headscale "$hs_pod" -- \
       headscale nodes tag -i "$hs_id" -t tag:k8s-node >/dev/null 2>&1; then
    echo "  Tagged tailnet node $hs_id ($NAME) with tag:k8s-node."
  else
    echo "  NOTE: could not tag tailnet node $hs_id — do it by hand:"
    echo "        headscale nodes tag -i $hs_id -t tag:k8s-node"
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
[ -n "$NAME" ] || choose_node
if load_defaults_from_settings "$NAME"; then
  echo "Loaded declared defaults for '$NAME' from project_settings.ts."
else
  echo "No matching entry for '$NAME' in project_settings.ts — starting from blanks."
fi
# An explicit --nested-runtime beats project_settings.ts, and must also apply when the node
# is not declared there at all (the carry-script path): the flag records what was ACTUALLY
# installed on the box.
[ -n "$NESTED_CLI" ] && NESTED="$NESTED_CLI"

while true; do
  echo ""
  echo "══════════════════════════════════════════"
  echo "  Adopt mesh node: $NAME"
  echo "══════════════════════════════════════════"
  echo "  1) Edit metadata (site / kvm / gpu / nested-runtime / eda-builder / scope / description)"
  echo "  2) Show pending config + current node state"
  echo "  3) Apply to cluster (labels + Longhorn + fingerprint)"
  echo "  4) Change selected node"
  echo "  q) Quit"
  printf "Choose: "
  read -r choice
  case "$choice" in
    1) action_edit_metadata ;;
    2) action_show ;;
    3) action_apply ;;
    4) NAME=""; choose_node; load_defaults_from_settings "$NAME" >/dev/null 2>&1 || true
       [ -n "$NESTED_CLI" ] && NESTED="$NESTED_CLI" ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) echo "Unknown choice." ;;
  esac
done
