#!/bin/bash
# 00-fetch-cluster-inputs.sh — gather the dynamic inputs an edge node needs to join,
# from the LIVE cluster. SHARED by src/nodes-k3s-on-premise.ts (Pulumi local.Command)
# and (optionally) scripts/runtime/generateEdgeJoinScript.sh.
#
# Side effects: mints an on-premise pre-auth key, approves the CP 10.0.0.0/23 subnet
# route in headscale, and patches the CP k3s TLS SANs with the CP VPN IP.
#
# Inputs (env):
#   KUBECONFIG       must point at a working kubeconfig (caller exports it)
#   CP0_SSH_HOST     ssh target for the primary control plane (for token + TLS-SAN)
#   HEADSCALE_URL    e.g. https://vpn.<tld>
#   EDGE_TIER        on-premise-resident (default) | on-premise-transient
#   NAMESPACE        headscale (default)
#
# Output (stdout): shell-evalable KEY=VALUE lines (secrets included) —
#   EDGE_TS_AUTHKEY, EDGE_CP0_VPN_IP, EDGE_K3S_TOKEN, EDGE_K3S_VERSION,
#   EDGE_HEADSCALE_CA_B64. All progress/errors go to stderr.
set -euo pipefail

NAMESPACE="${NAMESPACE:-headscale}"
EDGE_TIER="${EDGE_TIER:-on-premise-resident}"
: "${CP0_SSH_HOST:?CP0_SSH_HOST required}"
: "${HEADSCALE_URL:?HEADSCALE_URL required}"
HEADSCALE_HOST="${HEADSCALE_URL#https://}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

log() { echo "$@" >&2; }

# Retry: the single-node apiserver can briefly blip (k3s restart), which would
# otherwise abort the whole provision on a transient hiccup.
for i in $(seq 1 30); do
  kubectl cluster-info >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { log "ERROR: kubectl not connected after retries."; exit 1; }
  log "  apiserver not reachable yet (attempt $i/30)..."; sleep 4
done

hs_pod() {
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || kubectl get pods -n "$NAMESPACE" -l app=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ── Mint a reusable pre-auth key for the tier user ───────────────────────────
HS_POD=$(hs_pod)
[ -n "$HS_POD" ] || { log "ERROR: headscale pod not found in $NAMESPACE"; exit 1; }
TIER_UID=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- headscale users list -o json 2>/dev/null \
  | awk -v n="$EDGE_TIER" '/"id":/{id=$2} $0 ~ "\"name\": \""n"\""{gsub(/[^0-9]/,"",id); print id; exit}')
[ -n "$TIER_UID" ] || { log "ERROR: headscale user '$EDGE_TIER' not found (re-sync headscale app)."; exit 1; }
TS_AUTHKEY=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
  headscale preauthkeys create --user "$TIER_UID" --reusable --expiration 720h 2>/dev/null | tail -n1)
[ -n "$TS_AUTHKEY" ] || { log "ERROR: failed to mint pre-auth key"; exit 1; }
log "Minted pre-auth key for $EDGE_TIER."

# ── Resolve CP0 + its VPN IP (mesh-gateway pod) ──────────────────────────────
CP0_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -m1 cp0 || true)
[ -n "$CP0_NODE" ] || { log "ERROR: could not resolve a control-plane node"; exit 1; }
CP0_TS_POD=$(kubectl get pods -n "$NAMESPACE" -l app=mesh-gateway \
  --field-selector "spec.nodeName=${CP0_NODE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$CP0_TS_POD" ] || { log "ERROR: no mesh-gateway pod on $CP0_NODE (is the mesh up?)"; exit 1; }
CP0_VPN_IP=$(kubectl exec -n "$NAMESPACE" "$CP0_TS_POD" -c tailscale -- tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$CP0_VPN_IP" ] || { log "ERROR: CP0 has no tailscale VPN IP (mesh not ready?)"; exit 1; }
log "CP0 node=$CP0_NODE VPN IP=$CP0_VPN_IP"

# ── Approve the CP subnet route for EVERY node advertising it (edge API HA) ───
# Every cloud CP runs mesh-gateway advertising 10.0.0.0/23 (= network.subnetRange)
# into the mesh. headscale serves it from ONE approved subnet-router at a time and
# fails over to another *approved* router when that node dies — but ONLY among the
# nodes we have APPROVED. So we must approve the route on ALL advertising CPs, not
# just cp0; otherwise cp0's death leaves no failover candidate and every edge node
# is isolated from the private network (where the apiserver lives). The CPs SNAT
# mesh→private (src/nodes-k3s-cloud.ts), so the k3s agent LB's built-in failover
# across apiserver endpoints then works.
#
# We select nodes by what they ADVERTISE (available_routes from `nodes list-routes`),
# NOT by tag/user — the prior tag:k3s-cloud filter matched nothing (k3s-cloud is the
# headscale USER, not a node tag) and silently fell back to cp0-only. Idempotent:
# re-approving an already-approved route is a no-op.
SUBNET_RANGE="10.0.0.0/23" # project-settings: network.subnetRange
CP_NODE_IDS=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- headscale nodes list-routes --output json 2>/dev/null \
  | SUBNET="$SUBNET_RANGE" python3 -c "
import sys,json,os
sub=os.environ['SUBNET']
nodes=json.load(sys.stdin); nodes=nodes if isinstance(nodes,list) else nodes.get('nodes',[])
ids=[str(n['id']) for n in nodes if sub in (n.get('available_routes') or n.get('availableRoutes') or [])]
print(' '.join(ids))" 2>/dev/null || true)
if [ -n "$CP_NODE_IDS" ]; then
  for ID in $CP_NODE_IDS; do
    kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
      headscale nodes approve-routes --identifier "$ID" --routes "$SUBNET_RANGE" >/dev/null 2>&1 \
      && log "Approved route $SUBNET_RANGE for CP node $ID." \
      || log "WARNING: could not approve route for node $ID — approve manually via headplane."
  done
else
  log "WARNING: no nodes advertising $SUBNET_RANGE found in headscale — route approval skipped."
fi

# ── k3s token + version (ssh CP0) ────────────────────────────────────────────
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@${CP0_SSH_HOST}" true 2>/dev/null \
  || { log "ERROR: cannot SSH root@${CP0_SSH_HOST}"; exit 1; }
# shellcheck disable=SC2086
K3S_TOKEN=$(ssh $SSH_OPTS "root@${CP0_SSH_HOST}" 'cat /var/lib/rancher/k3s/server/node-token' || true)
[ -n "$K3S_TOKEN" ] || { log "ERROR: could not read k3s node-token from CP0"; exit 1; }
K3S_VERSION=$(kubectl version 2>/dev/null | grep "Server Version" \
  | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' | head -n1 || true)

# NOTE: no TLS-SAN patch needed. The edge k3s-agent connects to https://<cp0-tailscale-ip>:6443
# (see 30-join-cluster.sh K3S_URL), and cp0's tailscale IP is ALREADY in the cp k3s tls-san
# (src/nodes-k3s-cloud.ts adds the VPN/tailscale IP). We deliberately do NOT use the kube-vip
# private VIP 10.0.0.100 here: cp0 does not forward 10.0.0.0/23 off tailscale0, so that VIP is
# unreachable from the edge. The old patch also did a disruptive `systemctl restart k3s`. Removed.

# ── headscale CA (so the edge trusts a staging/private cert) ─────────────────
# cert-manager only puts leaf+intermediates in tls.crt; the staging root
# "(STAGING) Pretend Pear X1" is NOT served in the TLS handshake and not in the
# k8s secret. Go's x509 needs the self-signed root to anchor the chain, so we
# read the chain from the k8s secret and append the LE staging root if the topmost
# cert is not self-signed. For production certs this whole block is a no-op.
TLS_CHAIN=$(kubectl get secret headscale-tls -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)
# Fail HARD if the headscale cert is not ready yet. Emitting an empty CA here is
# the bug that silently breaks the edge join: the edge can't trust the staging
# cert, `tailscale up` fails on TLS, and (worse) Pulumi caches this empty fetch
# output and never re-runs it — so every later provision injects the same empty
# CA. Exiting non-zero makes Pulumi error out and retry on the next `up` instead
# of persisting a poisoned result. (For production certs TLS_CHAIN is still
# populated — this only guards the not-yet-issued case.)
if [ -z "$TLS_CHAIN" ]; then
  log "ERROR: headscale-tls secret has no tls.crt yet (cert not issued?). Aborting"
  log "       so Pulumi does NOT cache an empty headscale CA. Re-run once the"
  log "       headscale Certificate is Ready."
  exit 1
fi
STAGING_ROOT=""
if [ -n "$TLS_CHAIN" ]; then
  LAST_CERT=$(echo "$TLS_CHAIN" \
    | awk '/-----BEGIN CERTIFICATE-----/{p=1;buf=""} p{buf=buf $0 "\n"} /-----END CERTIFICATE-----/{last=buf;p=0} END{printf "%s",last}')
  LAST_ISSUER=$(echo "$LAST_CERT" | openssl x509 -noout -issuer 2>/dev/null || true)
  LAST_SUBJECT=$(echo "$LAST_CERT" | openssl x509 -noout -subject 2>/dev/null || true)
  if [ -n "$LAST_ISSUER" ] && [ "$LAST_ISSUER" != "$LAST_SUBJECT" ]; then
    log "Chain root not self-signed — fetching LE staging root CA (Pretend Pear X1)."
    STAGING_ROOT=$(curl -sf --max-time 10 \
      "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem" 2>/dev/null || true)
    [ -n "$STAGING_ROOT" ] \
      && log "LE staging root CA fetched." \
      || log "WARNING: could not fetch LE staging root; chain may be incomplete."
  fi
fi
HEADSCALE_CA_B64=$(printf '%s\n%s\n' "$TLS_CHAIN" "$STAGING_ROOT" \
  | grep -v '^[[:space:]]*$' | base64 -w0 2>/dev/null || true)

# ── Emit (stdout only) ───────────────────────────────────────────────────────
printf 'EDGE_TS_AUTHKEY=%s\n'      "$TS_AUTHKEY"
printf 'EDGE_CP0_VPN_IP=%s\n'      "$CP0_VPN_IP"
printf 'EDGE_K3S_TOKEN=%s\n'       "$K3S_TOKEN"
printf 'EDGE_K3S_VERSION=%s\n'     "${K3S_VERSION:-}"
printf 'EDGE_HEADSCALE_CA_B64=%s\n' "${HEADSCALE_CA_B64:-}"
