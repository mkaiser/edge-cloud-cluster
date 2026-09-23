#!/bin/bash
# _local-fetch-cluster-inputs.sh — gather the dynamic inputs an mesh node needs to join,
# from the LIVE cluster. SHARED by src/nodes-k3s-mesh.ts (Pulumi local.Command)
# and (optionally) scripts/provisioning/generateProvisioningScripts.sh.
#
# Side effects: mints an on-premise pre-auth key and approves the CP 10.0.0.0/23 subnet
# route in headscale. Both are safe to repeat: the key is single-use and short-lived, the
# route approve is idempotent. (No TLS-SAN patch — see the note further down; it was
# removed along with its disruptive `systemctl restart k3s`.)
#
# This command's Pulumi triggers include a hash of the kubeconfig's cluster CA, so it
# re-runs when the CLUSTER is recreated and never replays a previous cluster's join token.
# See the clusterCaFp comment in src/nodes-k3s-mesh.ts for why that is load-bearing.
#
# Inputs (env):
#   KUBECONFIG       must point at a working kubeconfig (caller exports it)
#   CP0_SSH_HOST     PREFERRED ssh target for reading the k3s node-token. Not
#                    authoritative: if it is unreachable the script falls back to
#                    the other Ready CPs (the token is identical on every server
#                    node). Likewise the CP whose VPN IP is reported is whichever
#                    Ready CP answers first — not necessarily the init one.
#   HEADSCALE_URL    e.g. https://vpn.<tld>
#   MESH_TIER        on-premise-resident (default) | on-premise-transient
#   NAMESPACE        headscale (default)
#
# Output (stdout): shell-evalable KEY=VALUE lines (secrets included) —
#   MESH_TS_AUTHKEY, MESH_K3S_TOKEN, MESH_K3S_VERSION,
#   MESH_HEADSCALE_CA_B64. All progress/errors go to stderr.
set -euo pipefail

NAMESPACE="${NAMESPACE:-headscale}"
MESH_TIER="${MESH_TIER:-on-premise-resident}"
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
  | awk -v n="$MESH_TIER" '/"id":/{id=$2} $0 ~ "\"name\": \""n"\""{gsub(/[^0-9]/,"",id); print id; exit}')
[ -n "$TIER_UID" ] || { log "ERROR: headscale user '$MESH_TIER' not found (re-sync headscale app)."; exit 1; }
# --tags tag:k8s-node makes the headscale ACL policy's tag-based grants match this node
# (deployment/argocd-infra/headscale/policy-configmap.yaml). Tagging at MINT time, not
# afterwards with `headscale nodes tag`, is what makes it survive: a pre-auth-key tag is
# re-asserted on every re-registration, and 30-connect-vpn.sh wipes /var/lib/tailscale and
# re-registers on every provision. Without it the node matches only the grant's permissive
# raw-user half. Ownership moves to the special user `tagged-devices`; the fabric grant
# names both tag:k8s-node AND the raw tier users so that transfer never partitions.
TS_AUTHKEY=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
  headscale preauthkeys create --user "$TIER_UID" --reusable --expiration 720h \
  --tags tag:k8s-node 2>/dev/null | tail -n1)
[ -n "$TS_AUTHKEY" ] || { log "ERROR: failed to mint pre-auth key"; exit 1; }
log "Minted pre-auth key for $MESH_TIER."

# ── Resolve ANY healthy CP + its VPN IP (mesh-gateway pod) ───────────────────
# Deliberately NOT "cp0": every cloud CP runs mesh-gateway and advertises the CP
# subnet, so any Ready one will do. Filter on Ready and never on NAME: taking
# `{.items[0]}` unconditionally ignores Ready status, so adopting a mesh node while
# the init CP is down would fail outright or hand back a dead node's data. Matching
# a cp0-ish name reintroduces a name assumption the mesh design does not make —
# mesh nodes join via the k3s-api.ts.internal MagicDNS name, which already fails
# over across CPs.
#
# Candidates are filtered to Ready=True, then probed in order: the first one with
# a mesh-gateway pod that reports a tailscale IP wins. Probing (rather than
# trusting node status) matters because the tailscale sidecar can be running
# while logged out — the pod stays 2/2 Ready and only `tailscale ip` reveals it.
# NB: the Ready check is done per node, NOT with a single jsonpath filter. A
# nested filter like
#   {range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}
# silently returns EMPTY on the kubectl in this devcontainer (filter-inside-filter
# is not supported) — which would look like "no Ready CP" on a perfectly healthy
# cluster. Verified against the live cluster before relying on it.
CP_CANDIDATES=$(for n in $(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [ "$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
    && echo "$n"
done)
[ -n "$CP_CANDIDATES" ] || { log "ERROR: no Ready control-plane node found"; exit 1; }


# ── Approve the CP subnet route for EVERY node advertising it (mesh API HA) ───
# Every cloud CP runs mesh-gateway advertising 10.0.0.0/23 (= network.subnetRange)
# into the mesh. headscale serves it from ONE approved subnet-router at a time and
# fails over to another *approved* router when that node dies — but ONLY among the
# nodes we have APPROVED. So we must approve the route on ALL advertising CPs, not
# just cp0; otherwise cp0's death leaves no failover candidate and every mesh node
# is isolated from the private network (where the apiserver lives). The CPs SNAT
# mesh→private (src/nodes-k3s-base.ts), so the k3s agent LB's built-in failover
# across apiserver endpoints then works.
#
# Select nodes by what they ADVERTISE (available_routes from `nodes list-routes`), never
# by tag/user: k3s-cloud is a headscale USER, not a node tag, so a `tag:k3s-cloud` filter
# matches nothing and silently degrades to cp0-only. Idempotent: re-approving an
# already-approved route is a no-op.
SUBNET_RANGE="10.0.0.0/23" # automatically updated from project-settings:network.subnetRange
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

# ── Site subnets (nodes.mesh[].advertiseRoutes) ──────────────────────────────
# A mesh node that subnet-routes its own LAN (e.g. pcie-tb-s -> 192.168.1.0/24) comes up
# Available but NOT Approved: headscale holds every advertised route disabled until someone
# approves it, and the block above only ever approves SUBNET_RANGE. Nothing else in the
# provisioning path approved these, so on EVERY fresh cluster the lab LAN silently stayed
# unrouted — `tailscale status` looks perfectly healthy while `ip route get <lab host>` on a
# cloud node leaves via the PUBLIC gateway. Verified missing again on ecc173 (2026-08-19).
#
# Approve whatever a node actually advertises rather than a hardcoded list, so adding a site
# in project_settings.nodes.mesh[].advertiseRoutes needs no change here. SUBNET_RANGE is
# skipped (handled above, CP-only by design). Idempotent: re-approving is a no-op.
#
# NB: approving makes the route SERVED, which is necessary but not sufficient for cloud->lab
# traffic — the cloud CP additionally needs RouteAll (--accept-routes) to install it, which is
# deliberately off.
SITE_ROUTES=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- headscale nodes list-routes --output json 2>/dev/null \
  | SUBNET="$SUBNET_RANGE" python3 -c "
import sys,json,os
sub=os.environ['SUBNET']
nodes=json.load(sys.stdin); nodes=nodes if isinstance(nodes,list) else nodes.get('nodes',[])
out=[]
for n in nodes:
    avail=n.get('available_routes') or n.get('availableRoutes') or []
    appr=n.get('approved_routes') or n.get('approvedRoutes') or []
    for r in avail:
        if r != sub and r not in appr:
            out.append(f\"{n['id']}={r}\")
print(' '.join(out))" 2>/dev/null || true)
if [ -n "$SITE_ROUTES" ]; then
  for PAIR in $SITE_ROUTES; do
    ID="${PAIR%%=*}"; ROUTE="${PAIR#*=}"
    kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
      headscale nodes approve-routes --identifier "$ID" --routes "$ROUTE" >/dev/null 2>&1 \
      && log "Approved site route $ROUTE for node $ID." \
      || log "WARNING: could not approve site route $ROUTE for node $ID — approve manually."
  done
else
  log "No unapproved site subnets advertised (nothing to approve)."
fi

# ── k3s token + version (ssh a CP) ───────────────────────────────────────────
# The node-token is IDENTICAL on every k3s server node, so any reachable CP can
# supply it. CP0_SSH_HOST stays the preferred target (it is also a Pulumi trigger
# / cluster-identity token — do not change how it is passed), but if that host is
# down we fall through to the other Ready CPs' private IPs rather than failing
# the whole adoption. Without this, losing the init CP blocks mesh-node adoption
# even though the cluster itself is perfectly healthy.
SSH_TARGETS="$CP0_SSH_HOST"
for n in $CP_CANDIDATES; do
  ip=$(kubectl get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  [ -n "$ip" ] && [ "$ip" != "$CP0_SSH_HOST" ] && SSH_TARGETS="$SSH_TARGETS $ip"
done

K3S_TOKEN=""; SSH_HOST_USED=""
for h in $SSH_TARGETS; do
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "root@${h}" true 2>/dev/null || { log "  cannot SSH root@${h}, trying next CP."; continue; }
  # shellcheck disable=SC2086
  tok=$(ssh $SSH_OPTS "root@${h}" 'cat /var/lib/rancher/k3s/server/node-token' 2>/dev/null || true)
  [ -n "$tok" ] || { log "  root@${h}: no node-token readable, trying next CP."; continue; }
  K3S_TOKEN="$tok"; SSH_HOST_USED="$h"; break
done
[ -n "$K3S_TOKEN" ] || {
  log "ERROR: could not read the k3s node-token from any CP (tried: $SSH_TARGETS)"
  exit 1
}
[ "$SSH_HOST_USED" = "$CP0_SSH_HOST" ] || log "NOTE: read node-token from $SSH_HOST_USED (CP0_SSH_HOST $CP0_SSH_HOST unreachable)."
K3S_VERSION=$(kubectl version 2>/dev/null | grep "Server Version" \
  | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' | head -n1 || true)

# NOTE: no TLS-SAN patch needed. The mesh k3s-agent connects to https://<cp0-tailscale-ip>:6443
# (see 40-join-cluster.sh K3S_URL), and cp0's tailscale IP is ALREADY in the cp k3s tls-san
# (src/nodes-k3s-base.ts adds the VPN/tailscale IP). We deliberately do NOT use the kube-vip
# private VIP 10.0.0.100 here: cp0 does not forward 10.0.0.0/23 off tailscale0, so that VIP is
# unreachable from the mesh.

# ── cluster ingress CA (so the mesh trusts a staging/private cert) ───────────
# cert-manager only puts leaf+intermediates in tls.crt; the staging root
# "(STAGING) Pretend Pear X1" is NOT served in the TLS handshake and not in the
# k8s secret. Go's x509 needs the self-signed root to anchor the chain, so we
# read the chain from the k8s secret and append the LE staging root if the topmost
# cert is not self-signed. For production certs this whole block is a no-op.
# Source: the wildcard-tls cert (argocd-infra — the shared Gateway's wildcard
# listener, which serves vpn.<tld>),
# same LE issuer/chain that headscale used to have its own per-host cert for.
# ⚠ WAIT for it rather than reading once. The abort below is correct and must stay, but on a
# FRESH bootstrap this step can run while cert-manager is still issuing the wildcard — a
# Let's Encrypt order takes a minute or two — and a one-shot read then fails the whole mesh
# provision for a cert that was seconds away. Measured on the ecc213 bring-up 2026-09-17:
# unibi-hclab-fs-vm aborted here at 21s, the certificate went Ready shortly after, and the
# node simply never joined — leaving one samba-ad DC Pending because its ecc/ad-dc label was
# never applied. Poll for up to 5 min, then fall through to the existing hard failure.
TLS_CHAIN=""
for _i in $(seq 1 60); do
  TLS_CHAIN=$(kubectl get secret wildcard-tls -n argocd-infra \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)
  [ -n "$TLS_CHAIN" ] && break
  [ "$_i" = "1" ] && log "waiting for the wildcard-tls certificate to be issued (up to 5 min)…"
  sleep 5
done
# Fail HARD if the wildcard cert is not ready yet. Emitting an empty CA here is
# the bug that silently breaks the mesh join: the mesh can't trust the staging
# cert, `tailscale up` fails on TLS, and (worse) Pulumi caches this empty fetch
# output and never re-runs it — so every later provision injects the same empty
# CA. Exiting non-zero makes Pulumi error out and retry on the next `up` instead
# of persisting a poisoned result. (For production certs TLS_CHAIN is still
# populated — this only guards the not-yet-issued case.)
if [ -z "$TLS_CHAIN" ]; then
  log "ERROR: wildcard-tls secret has no tls.crt yet (cert not issued?). Aborting"
  log "       so Pulumi does NOT cache an empty ingress CA. Re-run once the"
  log "       wildcard Certificate is Ready."
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
printf 'MESH_TS_AUTHKEY=%s\n'      "$TS_AUTHKEY"
printf 'MESH_K3S_TOKEN=%s\n'       "$K3S_TOKEN"
printf 'MESH_K3S_VERSION=%s\n'     "${K3S_VERSION:-}"
printf 'MESH_HEADSCALE_CA_B64=%s\n' "${HEADSCALE_CA_B64:-}"
