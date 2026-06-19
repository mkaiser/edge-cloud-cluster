#!/bin/bash
# 20-connect-vpn.sh — Install Tailscale and join the headscale VPN.
#
# SHARED edge-join logic — single source of truth, consumed by BOTH:
#   - scripts/runtime/generateEdgeJoinScript.sh (manual; fills placeholders via sed)
#   - src/nodes-k3s-on-premise.ts (Pulumi remote.Command; fills placeholders via env-subst)
# DO NOT COMMIT a filled-in copy (contains a pre-auth key).
#
# Placeholders: HEADSCALE_URL_PLACEHOLDER, TS_AUTHKEY_PLACEHOLDER, HEADSCALE_CA_B64_PLACEHOLDER
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 20-connect-vpn.sh failed at line $LINENO" >&2' ERR

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

HEADSCALE_URL="HEADSCALE_URL_PLACEHOLDER"
TS_AUTHKEY="TS_AUTHKEY_PLACEHOLDER"
HEADSCALE_HOST="${HEADSCALE_URL#https://}"
HEADSCALE_CA_FILE="/usr/local/share/ca-certificates/headscale-login-ca.crt"
# headscale mesh prefix — kept in sync with project_settings.ts by
# scripts/environment/updateConfigFromProjectSettings.sh via the anchor comment.
MESH_RANGE="10.0.10.0/23" # project-settings: network.meshRange

# ── Trust headscale CA (handles Let's Encrypt staging certs) ─────────────────
# update-ca-certificates installs ONE cert per .crt file — a multi-cert bundle in a
# single file only registers its first cert, silently dropping the rest. The headscale
# chain is leaf + staging-intermediate + staging-root; tailscaled (Go) needs the ROOT
# in the trust store to verify, so we MUST split the bundle into one file per cert.
install_headscale_ca() {
  local ca_b64="HEADSCALE_CA_B64_PLACEHOLDER"
  [ -n "$ca_b64" ] || return 1
  local dir; dir="$(dirname "$HEADSCALE_CA_FILE")"
  rm -f "$dir"/headscale-login-ca*.crt
  echo "$ca_b64" | base64 -d | awk -v d="$dir" '
    /-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/headscale-login-ca-%d.crt", d, n)}
    n{print > f}
  '
  local count; count=$(ls "$dir"/headscale-login-ca-*.crt 2>/dev/null | wc -l)
  echo "Imported $count headscale CA cert(s) into the trust store."
  update-ca-certificates >/dev/null
}

# ── Install Tailscale (skip if already present) ───────────────────────────────
if ! command -v tailscale &>/dev/null; then
  echo "=== Install Tailscale ==="
  export DEBIAN_FRONTEND=noninteractive
  UBUNTU_CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-focal}" || echo "focal")
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_CODENAME}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  # The provisioner runs under `umask 077`, so tee creates the keyring 0600
  # (root-only). apt's gpgv runs as the `_apt` user and then can't read it →
  # "key(s) ... ignored as the file is not readable" → repo treated as UNSIGNED
  # → `apt-get update` errors out and tailscale never installs. Force world-read.
  chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  apt-get install -y tailscale
else
  echo "=== Tailscale already installed — skipping package install ==="
fi

TS_SERVICE=""
for svc in tailscaled tailscale; do
  systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null \
    | grep -q "^${svc}" && { TS_SERVICE="$svc"; break; }
done
[ -n "$TS_SERVICE" ] || { echo "ERROR: tailscaled unit not found." >&2; exit 1; }

systemctl enable --now "$TS_SERVICE"
systemctl is-active --quiet "$TS_SERVICE" || {
  systemctl status "$TS_SERVICE" --no-pager >&2; exit 1
}

# ── Connect to headscale ──────────────────────────────────────────────────────
echo ""
echo "=== Connect to headscale VPN ==="

# Wipe existing tailscale state to avoid stale machine-key conflicts.
# force-reauth alone regenerates keys but leaves stale peer state in the daemon,
# causing rx=0 / noise-handshake failures against the relay.
wait_tailscaled() {
  local label="$1"
  # Check socket existence — tailscale status exits non-zero in NeedsLogin state
  # even when the daemon is fully operational and ready to accept `tailscale up`.
  for i in $(seq 1 30); do
    [ -S /run/tailscale/tailscaled.sock ] && return 0
    sleep 1
  done
  echo "ERROR: tailscaled socket not ready after 30s ($label)" >&2
  systemctl status "$TS_SERVICE" --no-pager >&2 || true
  journalctl -u "$TS_SERVICE" -n 20 --no-pager >&2 || true
  exit 1
}

systemctl stop "$TS_SERVICE" 2>/dev/null || true
rm -rf /var/lib/tailscale
systemctl start "$TS_SERVICE"
wait_tailscaled "initial start"

# Import the headscale CA up front (staging/private cert) so the system trust store
# has it before connecting; restart the daemon to pick it up.
if install_headscale_ca; then
  systemctl restart "$TS_SERVICE"
  wait_tailscaled "after CA import"
else
  echo "No headscale CA to import (production/publicly-trusted cert)."
fi
# Reachability HEAD is best-effort only — do NOT abort on it. 'tailscale up' below is
# the authoritative connectivity/auth test and fails loudly if headscale is truly
# unreachable. Aborting here (after wiping state) would strand the node offline.
curl -fsI --max-time 10 "$HEADSCALE_URL" >/dev/null 2>&1 \
  || echo "WARNING: HEAD $HEADSCALE_URL failed (cert/network?) — continuing; tailscale up will verify."

# --timeout so a rejected key / unreachable login-server fails loudly instead of
# blocking forever (which strands the Pulumi remote.Command with no progress).
# --accept-dns=true: enable MagicDNS so headscale names (e.g. k3s-api.ts.internal, the
# API endpoint this node's k3s-agent uses — see 30-join-cluster.sh) resolve. Tailscale
# points the host resolver at 100.100.100.100 and falls through to upstream resolvers for
# non-ts.internal names, so local/home DNS keeps working.
timeout 90 tailscale up \
  --login-server "$HEADSCALE_URL" \
  --authkey "$TS_AUTHKEY" \
  --hostname "$(hostname)" \
  --accept-dns=true \
  --accept-routes \
  --timeout 60s \
  || { echo "ERROR: 'tailscale up' failed/timed out against $HEADSCALE_URL." >&2
       echo "  Check: pre-auth key validity, headscale reachability from this host," >&2
       echo "  and that the headscale CA is trusted (staging cert)." >&2
       tailscale status >&2 || true
       exit 1; }

echo "Waiting for VPN IP..."
for i in $(seq 1 20); do
  VPN_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  [ -n "$VPN_IP" ] && break
  sleep 3
done
[ -n "$VPN_IP" ] || {
  echo "ERROR: No tailscale IP after 60s." >&2; tailscale status >&2; exit 1
}

echo ""
echo "=== VPN connected ==="
echo "VPN IP: $VPN_IP"
tailscale status

# ── MagicDNS split-route for ts.internal (resolved drop-in, NOT tailscale's SetLinkDNS) ──
# tailscaled normally points the host resolver at MagicDNS (100.100.100.100) by calling
# systemd-resolved's SetLinkDNS over D-Bus/varlink. On Ubuntu 26.04 (systemd 259) that call
# hangs ("setLinkDNS: context deadline exceeded"), so MagicDNS is enabled tailnet-wide but
# the OS resolver never learns to forward *.ts.internal → 100.100.100.100. Names like
# k3s-api.ts.internal then NXDOMAIN and the k3s-agent can't find the apiserver.
#
# We install the split-route ourselves via a resolved CONFIG DROP-IN (read at resolved
# start — file path, not the hung runtime varlink API). It forwards ONLY the ts.internal
# domain to MagicDNS; every other name keeps using the node's normal/home resolvers
# (Domains=~ts.internal is a routing-only domain, not a search domain). 100.100.100.100 is
# a fixed tailscale-local address, so this never hardcodes a CP IP or the ecc subdomain.
#
# Transient-safe: this file only ROUTES a domain to MagicDNS. If the node later leaves the
# tailnet, 100.100.100.100 simply stops answering (NXDOMAIN) — it can never resolve
# ts.internal names to a stale/wrong IP the way an /etc/hosts pin would. We remove it on
# teardown anyway (see below) so it leaves no trace.
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  echo "Installing systemd-resolved drop-in: route ts.internal → 100.100.100.100 (MagicDNS)"
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/tailscale-magicdns.conf << 'RESOLVED_DROPIN'
# Route the headscale MagicDNS base domain to the tailscale-local resolver.
# Worked around: tailscaled SetLinkDNS hangs on systemd 259 (Ubuntu 26.04).
# Remove this file (and `systemctl restart systemd-resolved`) when leaving the tailnet.
[Resolve]
DNS=100.100.100.100
Domains=~ts.internal
RESOLVED_DROPIN
  systemctl restart systemd-resolved
  # Verify the split-route actually resolves the API name before proceeding to the join.
  for i in $(seq 1 10); do
    getent hosts k3s-api.ts.internal >/dev/null 2>&1 && { echo "  ts.internal resolves via MagicDNS."; break; }
    [ "$i" = 10 ] && echo "  WARNING: k3s-api.ts.internal not resolving yet — 30-join-cluster.sh will retry."
    sleep 2
  done
else
  echo "systemd-resolved not active — relying on tailscale's own DNS handling for ts.internal."
fi

# tailscaled (v1.96.x + headscale) does not install IPv4 peer routes into the
# kernel routing table for custom headscale prefixes.  Without this route,
# traffic to the control-plane VPN IP (10.0.10.1) hits the default gateway
# instead of tailscale0, so k3s-agent can never reach the API server.
# The /23 covers the entire headscale prefix (10.0.10.0–10.0.11.255) and
# is more specific than any RFC-1918 catch-all that might exist on this host.
echo "Installing VPN peer route: $MESH_RANGE dev tailscale0"
ip route replace "$MESH_RANGE" dev tailscale0 || true

# Persist the route across reboots via a systemd drop-in.
# NB: unquoted heredoc so $MESH_RANGE expands now; the runtime shell vars ($i, $(seq…))
# are escaped (\$) so they are evaluated by systemd at boot, not when this file is written.
mkdir -p "/etc/systemd/system/${TS_SERVICE}.service.d"
cat > "/etc/systemd/system/${TS_SERVICE}.service.d/vpn-routes.conf" << DROPIN
[Service]
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 30); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done; ip route replace ${MESH_RANGE} dev tailscale0 2>/dev/null || true'
DROPIN
systemctl daemon-reload
echo "Persistent VPN route drop-in written."

echo ""
echo "Next step: 30-join-cluster.sh"
