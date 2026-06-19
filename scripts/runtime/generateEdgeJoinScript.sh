#!/bin/bash
# generateEdgeJoinScript: Generate self-contained edge-node scripts for manual provisioning.
#
# Runs on the devcontainer (needs kubectl + kubeconfig).
# Produces:
#   tmp/provisioning/0_install_prerequisites.sh
#   tmp/provisioning/1_connectVPN.sh
#   tmp/provisioning/2_joinCluster.sh
#   tmp/provisioning/provision-edge-server.sh
#
# Run them in order on the edge node (or use provision-edge-server.sh):
#   sudo bash 1_connectVPN.sh
#   sudo bash 2_joinCluster.sh
#
# Usage:
#   ./scripts/runtime/generateEdgeJoinScript.sh           # generate all scripts
#   ./scripts/runtime/generateEdgeJoinScript.sh --token   # print tailscale auth key only
#   ./scripts/runtime/generateEdgeJoinScript.sh --qr      # display QR code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EDGE_SHARED_DIR="$SCRIPT_DIR/../edge-provisioning"
OUTPUT_DIR="$ROOT_DIR/tmp/provisioning"
CLEANUP_SCRIPT="$OUTPUT_DIR/00_cleanup.sh"
PREREQ_SCRIPT="$OUTPUT_DIR/0_install_prerequisites.sh"
VPN_SCRIPT="$OUTPUT_DIR/1_connectVPN.sh"
K3S_SCRIPT="$OUTPUT_DIR/2_joinCluster.sh"
PROVISION_SCRIPT="$OUTPUT_DIR/provision-edge-server.sh"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
NAMESPACE="${HEADSCALE_NAMESPACE:-headscale}"

# ── Resolve HEADSCALE_URL from project_settings.ts ───────────────────────────
BASE_DOMAIN=$(sed -n 's/^const baseDomain = "\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
SUBDOMAIN=$(sed -n 's/^const subdomain = "\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
HEADSCALE_URL="https://vpn.${SUBDOMAIN:+${SUBDOMAIN}.}${BASE_DOMAIN}"
export HEADSCALE_URL

# ── Verify kubectl ────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl not connected. Run: ./scripts/runtime/getKubeConfig.sh" >&2
  exit 1
fi

# ── Fetch cluster inputs via shared script ────────────────────────────────────
# 00-fetch-cluster-inputs.sh is the single source of truth for:
#   - minting the pre-auth key
#   - resolving CP0 VPN IP
#   - approving the subnet route
#   - reading k3s token + version
#   - building the CA cert bundle (incl. LE staging root)
# CP0_SSH_HOST is the CP0 public SSH address (for reading the k3s token).
CP0_PUBLIC_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null \
  || kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
  || true)
[ -n "$CP0_PUBLIC_IP" ] || { echo "ERROR: could not resolve CP0 public IP" >&2; exit 1; }

export CP0_SSH_HOST="$CP0_PUBLIC_IP"
export EDGE_TIER="${EDGE_TIER:-on-premise-resident}"
export NAMESPACE

echo "Fetching cluster inputs (pre-auth key, token, CA cert)..."
bash "$EDGE_SHARED_DIR/00-fetch-cluster-inputs.sh" >/tmp/_edge_fetch_kv.txt || {
  echo "ERROR: 00-fetch-cluster-inputs.sh failed" >&2
  rm -f /tmp/_edge_fetch_kv.txt
  exit 1
}

TS_AUTHKEY=$(grep '^EDGE_TS_AUTHKEY=' /tmp/_edge_fetch_kv.txt | cut -d= -f2-)
CP0_VPN_IP=$(grep '^EDGE_CP0_VPN_IP=' /tmp/_edge_fetch_kv.txt | cut -d= -f2-)
K3S_TOKEN=$(grep '^EDGE_K3S_TOKEN=' /tmp/_edge_fetch_kv.txt | cut -d= -f2-)
K3S_VERSION=$(grep '^EDGE_K3S_VERSION=' /tmp/_edge_fetch_kv.txt | cut -d= -f2-)
HEADSCALE_CA_B64=$(grep '^EDGE_HEADSCALE_CA_B64=' /tmp/_edge_fetch_kv.txt | cut -d= -f2-)
rm -f /tmp/_edge_fetch_kv.txt

[ -n "$TS_AUTHKEY" ]  || { echo "ERROR: no EDGE_TS_AUTHKEY in fetch output" >&2; exit 1; }
[ -n "$CP0_VPN_IP" ]  || { echo "ERROR: no EDGE_CP0_VPN_IP in fetch output" >&2; exit 1; }
[ -n "$K3S_TOKEN" ]   || { echo "ERROR: no EDGE_K3S_TOKEN in fetch output" >&2; exit 1; }

echo "CP0 VPN IP:  $CP0_VPN_IP"
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

# ── Generate scripts ──────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

cp "$EDGE_SHARED_DIR/cleanupNode.sh" "$CLEANUP_SCRIPT"
chmod +x "$CLEANUP_SCRIPT"

cp "$EDGE_SHARED_DIR/10-install-prereqs.sh" "$PREREQ_SCRIPT"
chmod +x "$PREREQ_SCRIPT"

cp "$EDGE_SHARED_DIR/20-connect-vpn.sh" "$VPN_SCRIPT"
sed -i "s|HEADSCALE_URL_PLACEHOLDER|${HEADSCALE_URL}|g"      "$VPN_SCRIPT"
sed -i "s|TS_AUTHKEY_PLACEHOLDER|${TS_AUTHKEY}|g"            "$VPN_SCRIPT"
sed -i "s|HEADSCALE_CA_B64_PLACEHOLDER|${HEADSCALE_CA_B64}|g" "$VPN_SCRIPT"
chmod +x "$VPN_SCRIPT"

cp "$EDGE_SHARED_DIR/30-join-cluster.sh" "$K3S_SCRIPT"
sed -i "s|CP0_VPN_IP_PLACEHOLDER|${CP0_VPN_IP}|g"  "$K3S_SCRIPT"
sed -i "s|K3S_TOKEN_PLACEHOLDER|${K3S_TOKEN}|g"    "$K3S_SCRIPT"
sed -i "s|K3S_VERSION_PLACEHOLDER|${K3S_VERSION}|g" "$K3S_SCRIPT"
chmod +x "$K3S_SCRIPT"

cat > "$PROVISION_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# provision-edge-server.sh — provision one or more edge nodes.
# Generated by: scripts/runtime/generateEdgeJoinScript.sh
#
# Edit the NODES list, then run:
#   bash provision-edge-server.sh [node-name]   # single node
#   bash provision-edge-server.sh               # all nodes

set -euo pipefail

# Format: "NAME|USER@HOST|PORT|LOCATION|HARDWARE|KVM"
NODES=(
  "ubuntu-vm|cape@epi.techfak.uni-bielefeld.de|1717|unibi-lab||true"
  "pcie6-server|cape@epi.techfak.uni-bielefeld.de|3001|unibi-lab||true"
  "minipc|cape@192.168.178.150|22|martinHome||true"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

provision() {
  local NAME ADDR PORT LOCATION HARDWARE KVM
  IFS='|' read -r NAME ADDR PORT LOCATION HARDWARE KVM <<< "$1"

  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  Node: $NAME  ($ADDR:$PORT)"
  echo "══════════════════════════════════════════════════"

  # shellcheck disable=SC2086
  ssh $SSH_OPTS -p "$PORT" "$ADDR" 'echo "SSH OK"'

  JOIN_FLAGS=""
  if kubectl get node "$NAME" &>/dev/null; then
    echo "Node $NAME already registered — cordoning and draining..."
    kubectl cordon "$NAME"
    kubectl drain "$NAME" --ignore-daemonsets --delete-emptydir-data \
      --grace-period=60 --timeout=120s || true
    JOIN_FLAGS="--force"
  fi

  # shellcheck disable=SC2086
  scp $SSH_OPTS -P "$PORT" \
    "$SCRIPT_DIR/00_cleanup.sh" \
    "$SCRIPT_DIR/0_install_prerequisites.sh" \
    "$SCRIPT_DIR/1_connectVPN.sh" \
    "$SCRIPT_DIR/2_joinCluster.sh" \
    "$ADDR":/tmp/

  # Clean any stale state from a previously-destroyed cluster before joining.
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -t -p "$PORT" "$ADDR" 'sudo bash /tmp/00_cleanup.sh'
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -t -p "$PORT" "$ADDR" 'sudo bash /tmp/0_install_prerequisites.sh'
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -t -p "$PORT" "$ADDR" 'sudo bash /tmp/1_connectVPN.sh'
  # shellcheck disable=SC2029,SC2086
  ssh $SSH_OPTS -t -p "$PORT" "$ADDR" "sudo bash /tmp/2_joinCluster.sh --node-name=${NAME} ${JOIN_FLAGS}"

  echo "Waiting for node $NAME to register..."
  for i in $(seq 1 60); do
    kubectl get node "$NAME" &>/dev/null && break
    sleep 5
  done
  kubectl get node "$NAME" &>/dev/null || {
    echo "ERROR: node $NAME did not appear after 300s" >&2; exit 1
  }

  echo "Applying labels to $NAME..."
  LABELS=("node-role.kubernetes.io/edge=edge" "node.kubernetes.io/edge-worker=true")
  [ -n "${LOCATION// }" ] && LABELS+=("ecc/location=${LOCATION}")
  [ -n "${HARDWARE// }" ] && LABELS+=("ecc/hardware=${HARDWARE}")
  [ -n "${KVM// }"      ] && LABELS+=("ecc/kvm=${KVM}")
  kubectl label node "$NAME" "${LABELS[@]}" --overwrite
  kubectl uncordon "$NAME" 2>/dev/null || true
  echo "Node $NAME provisioned."
}

TARGET="${1:-}"
MATCHED=false
for NODE in "${NODES[@]}"; do
  NODE_NAME="${NODE%%|*}"
  if [ -z "$TARGET" ] || [ "$TARGET" = "$NODE_NAME" ]; then
    MATCHED=true
    provision "$NODE"
  fi
done
[ "$MATCHED" = "true" ] || {
  echo "ERROR: no node named '$TARGET' in NODES list." >&2
  printf '  %s\n' "${NODES[@]%%|*}" >&2
  exit 1
}
SCRIPT_EOF
chmod +x "$PROVISION_SCRIPT"

echo ""
echo "=== Generated edge node scripts ==="
echo "Headscale URL : $HEADSCALE_URL"
echo "CP0 VPN IP    : $CP0_VPN_IP"
echo "k3s version   : ${K3S_VERSION:-latest}"
echo ""
echo "  $PREREQ_SCRIPT"
echo "  $VPN_SCRIPT"
echo "  $K3S_SCRIPT"
echo "  $PROVISION_SCRIPT"
echo ""
echo "Edit NODES in provision-edge-server.sh, then run:"
echo "  bash $PROVISION_SCRIPT [node-name]"
