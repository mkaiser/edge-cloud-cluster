#!/bin/bash
# mintUserKey.sh — mint a headscale pre-auth key for an ADMIN's device (laptop/phone).
#
# ORDINARY USERS DO NOT NEED THIS SCRIPT. A person in the Authentik group `vpn-users` runs
#   tailscale up --login-server=https://vpn.<tld> --accept-routes
# logs in through Authentik, and headscale creates their user from the OIDC claim. There is
# no key to mint and no admin step per device — see doc/vpn-user-access.md.
#
# This script exists only for `operator`, which is deliberately NOT self-service: it grants
# full tailnet reach (kubectl on 6443, node SSH, both LAN subnet routes), so it stays a
# named headscale user enrolled by hand rather than something an Authentik group hands out.
#
# The old `human` tier is GONE. Its grants were keyed off the username `human@`, and OIDC
# mints one headscale user PER PERSON — so those grants matched nobody. The policy now
# grants by autogroup:member (any untagged, i.e. personal, device), which covers every
# OIDC-created user automatically.
#
# This enrols PEOPLE only. Machines are enrolled by the provisioning path
# (scripts/provisioning/), which registers them keyless and has them approved in Headplane.
# The distinction is not cosmetic: a laptop joined under a node tier
# (on-premise-resident/-transient) lands inside the wide-open node-fabric grant in
# deployment/argocd-infra/headscale/policy-configmap.yaml and gets unrestricted reach across
# the whole cluster.
#
# Runs on the devcontainer (needs kubectl + kubeconfig).
#
# Usage:
#   ./scripts/runtime/mintUserKey.sh                  # tier `operator`, single-use, 1h TTL
#   ./scripts/runtime/mintUserKey.sh --ttl 30m
#   ./scripts/runtime/mintUserKey.sh --qr             # render a QR (phones)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_SETTINGS_FILE="$ROOT_DIR/project_settings.ts"
NAMESPACE="${HEADSCALE_NAMESPACE:-headscale}"

TIER="operator"
TTL="1h"
QR=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)    TIER="$2"; shift 2 ;;
    --ttl)     TTL="$2"; shift 2 ;;
    --qr)      QR=true; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *)         echo "ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# `operator` is the only tier. A node tier here would silently grant full cluster reach,
# which is the exact mistake this script exists to prevent — so reject it outright rather
# than trusting the caller to know the difference.
case "$TIER" in
  operator) ;;
  human)
    echo "ERROR: the 'human' tier was removed — ordinary users are self-service now." >&2
    echo "       Add the person to the Authentik group 'vpn-users'; they then run:" >&2
    echo "         tailscale up --login-server <headscale-url> --accept-routes" >&2
    echo "       and log in through Authentik. See doc/vpn-user-access.md." >&2
    exit 2 ;;
  *) echo "ERROR: --tier must be 'operator' (got '$TIER'). Machines are enrolled by scripts/provisioning/." >&2; exit 2 ;;
esac

BASE_DOMAIN=$(sed -n 's/^[[:space:]]*domain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
SUBDOMAIN=$(sed -n 's/^[[:space:]]*subdomain:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_SETTINGS_FILE" | head -n1)
[ -n "$BASE_DOMAIN" ] || { echo "ERROR: could not parse general.domain from $PROJECT_SETTINGS_FILE" >&2; exit 1; }
HEADSCALE_URL="https://vpn.${SUBDOMAIN:+${SUBDOMAIN}.}${BASE_DOMAIN}"

kubectl cluster-info &>/dev/null || {
  echo "ERROR: kubectl not connected. Run: ./scripts/runtime/getKubeConfig.sh" >&2; exit 1
}

hs_pod() {
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || kubectl get pods -n "$NAMESPACE" -l app=headscale \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
HS_POD=$(hs_pod)
[ -n "$HS_POD" ] || { echo "ERROR: headscale pod not found in $NAMESPACE" >&2; exit 1; }

TIER_UID=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- headscale users list -o json 2>/dev/null \
  | awk -v n="$TIER" '/"id":/{id=$2} $0 ~ "\"name\": \""n"\""{gsub(/[^0-9]/,"",id); print id; exit}')
[ -n "$TIER_UID" ] || {
  echo "ERROR: headscale user '$TIER' not found. It is created by the headscale post-deploy" >&2
  echo "       job — sync the headscale app, or create it with:" >&2
  echo "         kubectl exec -n $NAMESPACE $HS_POD -- headscale users create $TIER" >&2
  exit 1
}

# Always single-use and short-lived: an operator key needs to enroll exactly one device
# once. There is deliberately no --reusable escape hatch — a leaked reusable key would
# enroll arbitrary devices into the most privileged tier on the tailnet.
TS_AUTHKEY=$(kubectl exec -n "$NAMESPACE" "$HS_POD" -- \
  headscale preauthkeys create --user "$TIER_UID" --expiration "$TTL" 2>/dev/null | tail -n1)
[ -n "$TS_AUTHKEY" ] || { echo "ERROR: failed to mint pre-auth key" >&2; exit 1; }

echo ""
echo "=== One-time user pre-auth key minted ==="
echo "Tier       : $TIER"
echo "Single-use : yes"
echo "Expires in : $TTL"
echo "Headscale  : $HEADSCALE_URL"
echo ""
echo "Key:"
echo "  $TS_AUTHKEY"
echo ""
echo "On the device (Linux/macOS, tailscale already installed):"
echo "  sudo tailscale up --login-server $HEADSCALE_URL --authkey $TS_AUTHKEY"
echo ""
echo "Windows:"
echo "  tailscale up --login-server $HEADSCALE_URL --authkey $TS_AUTHKEY"
echo ""
echo "This tier has FULL tailnet reach (k3s API, node SSH, both LAN subnet routes)."
echo "For an ordinary user, do NOT mint a key: add them to the Authentik group"
echo "'vpn-users' and have them log in through Authentik (doc/vpn-user-access.md)."
echo "Grants are defined in deployment/argocd-infra/headscale/policy-configmap.yaml."

if [ "$QR" = "true" ]; then
  if command -v qrencode &>/dev/null; then
    echo ""
    qrencode -t ANSI256 "$TS_AUTHKEY"
  else
    echo "" >&2
    echo "NOTE: qrencode not installed (apt install qrencode) — QR skipped." >&2
  fi
fi
