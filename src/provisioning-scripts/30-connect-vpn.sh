#!/bin/bash
# 30-connect-vpn.sh — Install Tailscale and join the headscale VPN.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual; fills placeholders via sed)
#   - src/nodes-k3s-mesh.ts (Pulumi remote.Command; fills placeholders via env-subst)
# DO NOT COMMIT a filled-in copy (contains a pre-auth key).
#
# Placeholders: HEADSCALE_URL_PLACEHOLDER, TS_AUTHKEY_PLACEHOLDER, HEADSCALE_CA_B64_PLACEHOLDER
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 30-connect-vpn.sh failed at line $LINENO" >&2' ERR

# Re-exec with sudo if not root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

HEADSCALE_URL="HEADSCALE_URL_PLACEHOLDER"
TS_AUTHKEY="TS_AUTHKEY_PLACEHOLDER"
# Site LAN subnets this node advertises into the mesh, comma-separated, or empty.
# From project_settings.ts nodes.mesh[].advertiseRoutes (see the long note there).
# Empty for every node that is not a subnet router — the normal case.
TS_ADVERTISE_ROUTES="TS_ADVERTISE_ROUTES_PLACEHOLDER"
# Node-local AD-zone resolver (installed on EVERY mesh node — see the block near the end of
# this script for why it is unconditional and why the zone carries two servers).
AD_DOMAIN="ad.base.internal" # automatically updated from project-settings:activeDirectory.adDomain
AD_DNS_CLUSTER_IP="10.43.48.96" # automatically updated from project-settings:network.adDnsClusterIp
# The on-prem DCs' LAN addresses, space-separated — one per node carrying `adDc: true`
# (project_settings nodes.mesh[].lanIp). Fallback servers for the AD zone; see the block
# near the end of this script. Empty is legal (no on-prem DC): the zone then has only the
# ClusterIP server.
AD_DC_IPS="192.168.1.192 192.168.1.194" # automatically updated from project-settings:nodes.mesh[].lanIp
# Keyless 2nd-factor mode: the manual generator leaves the ONDEMAND sentinel here (the string
# ONDEMAND followed by _PLACEHOLDER) instead of a pre-auth key. In that mode this script runs
# `tailscale up` WITHOUT --authkey, so headscale holds the node PENDING and prints a one-time
# registration URL; it is admitted only after an operator approves it in the Headplane UI. A
# leaked carry-script therefore cannot join on its own.
#
# CRITICAL: the trigger token must NOT be one the Pulumi remote.Command path rewrites. Pulumi
# does a GLOBAL replace of the authkey placeholder (the TS_AUTHKEY token above) over this whole
# file. If the keyless comparison referenced that same token, the replace would rewrite it to the
# REAL key and the comparison would then match it — sending every Pulumi node into keyless mode
# (the "Waiting for approval" hang). We instead assemble the ONDEMAND sentinel from two halves at
# runtime, so no matching literal exists in the file for any replace to clobber.
KEYLESS_MODE=false
_ONDEMAND="ONDEMAND""_PLACEHOLDER"
if [ "$TS_AUTHKEY" = "$_ONDEMAND" ]; then
  KEYLESS_MODE=true
  TS_AUTHKEY=""   # explicit: no key is used in keyless mode
fi
HEADSCALE_HOST="${HEADSCALE_URL#https://}"
HEADSCALE_CA_FILE="/usr/local/share/ca-certificates/headscale-login-ca.crt"
# headscale mesh prefix — kept in sync with project_settings.ts by
# scripts/environment/updateConfigFromProjectSettings.sh via the anchor comment.
MESH_RANGE="10.0.10.0/23" # automatically updated from project-settings:network.meshRange

# ── Subnet-router flag ───────────────────────────────────────────────────────
# Built as a variable rather than inlined, because an EMPTY --advertise-routes= is not the
# same as omitting the flag: passing it empty on a node that already advertises routes
# WITHDRAWS them. Most nodes have no routes, so the flag must vanish entirely for them.
#
# Note `tailscale up` is declarative — every invocation replaces the node's full advertised
# set — so this is also what re-asserts the routes on a re-provision.
TS_ROUTE_FLAG=""
if [ -n "$TS_ADVERTISE_ROUTES" ] && [ "$TS_ADVERTISE_ROUTES" != "TS_ADVERTISE_ROUTES""_PLACEHOLDER" ]; then
  TS_ROUTE_FLAG="--advertise-routes=$TS_ADVERTISE_ROUTES"
  echo "Advertising site subnet(s) into the mesh: $TS_ADVERTISE_ROUTES"
  echo "  NOTE: headscale holds new routes DISABLED until approved:"
  echo "    headscale nodes list-routes"
  echo "    headscale nodes approve-routes --identifier <id> --routes $TS_ADVERTISE_ROUTES"
  # IP forwarding is REQUIRED for a subnet router: without it the kernel silently drops
  # every packet destined for the LAN behind this node, and the symptom is a timeout with a
  # perfectly healthy-looking tailscale status.
  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
    echo "Enabling IPv4 forwarding (required to route the advertised subnet)"
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale-subnet-router.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale-subnet-router.conf
    sysctl -p /etc/sysctl.d/99-tailscale-subnet-router.conf >/dev/null 2>&1 || true
  fi
fi

# ── Trust headscale CA (handles Let's Encrypt staging certs) ─────────────────
# update-ca-certificates installs ONE cert per .crt file — a multi-cert bundle in a
# single file only registers its first cert, silently dropping the rest. The headscale
# chain is leaf + staging-intermediate + staging-root; tailscaled (Go) needs the ROOT
# in the trust store to verify, so we MUST split the bundle into one file per cert.
install_headscale_ca() {
  local ca_b64="HEADSCALE_CA_B64_PLACEHOLDER"
  # Compare against the split token for the same reason the authkey sentinel does (see the
  # CRITICAL note above): written as one literal it would be rewritten by the generator's own
  # global replace. An UNSUBSTITUTED placeholder is non-empty, so a bare `[ -n ]` accepts it,
  # base64-decodes garbage to zero certs, and still returns 0 — the caller then logs
  # "Imported 0 headscale CA cert(s)" and proceeds as though the CA were installed.
  if [ "$ca_b64" = "HEADSCALE_CA_B64""_PLACEHOLDER" ]; then
    echo "ERROR: headscale CA placeholder was never substituted — refusing to continue." >&2
    return 1
  fi
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
  # Tolerate a broken third-party repo (e.g. a stray Helm apt list) so `set -e` doesn't abort
  # before tailscale installs; the install below is the real gate. See 10-install-prereqs.sh.
  apt-get update -qq || echo "WARNING: apt-get update reported errors (a repo may be unreachable) — continuing." >&2
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

# --accept-dns=true: enable MagicDNS so headscale names (e.g. k3s-api.ts.internal, the
# API endpoint this node's k3s-agent uses — see 40-join-cluster.sh) resolve. Tailscale
# points the host resolver at 100.100.100.100 and falls through to upstream resolvers for
# non-ts.internal names, so local/home DNS keeps working.
# Tailnet name. Defaults to the box's own hostname, but ECC_NODE_NAME (set by the callers
# that already know the k8s node name) overrides it so the two identities MATCH.
#
# Why it matters: headscale de-duplicates by name. A box whose hostname differs from its k8s
# node name registers under the hostname, and a re-provision of the SAME node then collides
# with the leftover entry and is renamed <name>-1, -2, … — the operator sees an unfamiliar
# name in `headscale nodes list` and cannot tell which tailnet entry belongs to which k8s
# node. (Observed: k8s node home-martin-mini0 on a box named minipc-martin registered as
# minipc-martin-1.)
TS_HOSTNAME="${ECC_NODE_NAME:-$(hostname)}"

if [ "$KEYLESS_MODE" = "true" ]; then
  # ── Keyless web-registration (2nd factor = operator approval) ───────────────
  # Run `tailscale up` WITHOUT --authkey. headscale replies with a one-time registration
  # URL (.../register/hskey-authreq-<24 chars>) and holds the node PENDING until an operator
  # approves it from the devcontainer. `tailscale up` blocks until then, so we run it in the
  # background, scrape the URL it prints, show it big + as a QR (scan with a phone → paste the
  # auth-id into adoptProvisionedNodes.sh on the devcontainer), then wait for the node to come up.
  echo "Keyless mode: requesting a one-time registration URL from headscale…"
  UP_LOG="$(mktemp)"
  tailscale up \
    --login-server "$HEADSCALE_URL" \
    --hostname "$TS_HOSTNAME" \
    --accept-dns=true \
    --accept-routes \
    ${TS_ROUTE_FLAG:+"$TS_ROUTE_FLAG"} \
    >"$UP_LOG" 2>&1 &
  UP_PID=$!

  REG_URL=""
  for i in $(seq 1 30); do
    REG_URL=$(grep -oE "${HEADSCALE_URL}/register/[A-Za-z0-9._-]+" "$UP_LOG" 2>/dev/null | head -n1 || true)
    [ -z "$REG_URL" ] && REG_URL=$(grep -oE 'https?://[^ ]+/register/[A-Za-z0-9._-]+' "$UP_LOG" 2>/dev/null | head -n1 || true)
    [ -n "$REG_URL" ] && break
    kill -0 "$UP_PID" 2>/dev/null || break   # tailscale up exited (already registered / error)
    sleep 1
  done

  if [ -z "$REG_URL" ]; then
    # Either already registered from a prior run, or a real failure. If we now have an IP, treat
    # as success; otherwise surface the log.
    if tailscale ip -4 >/dev/null 2>&1; then
      echo "Already registered (no new URL needed)."
    else
      echo "ERROR: keyless 'tailscale up' produced no registration URL." >&2
      cat "$UP_LOG" >&2 || true
      rm -f "$UP_LOG"; exit 1
    fi
  else
    AUTH_ID="${REG_URL##*/register/}"
    # Colour only when stdout is a terminal that has colours. Piped to a log, run under a dumb
    # TERM, or with NO_COLOR set, every variable below is empty and the text prints unchanged —
    # this block must stay readable in a provisioning transcript.
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] \
       && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
      C_RST=$(tput sgr0); C_BOLD=$(tput bold)
      C_YEL=$(tput setaf 3); C_CYA=$(tput setaf 6); C_GRN=$(tput setaf 2)
    else
      C_RST=""; C_BOLD=""; C_YEL=""; C_CYA=""; C_GRN=""
    fi
    echo ""
    echo "${C_YEL}${C_BOLD}════════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo "${C_YEL}${C_BOLD}  APPROVAL REQUIRED — this node is PENDING until approved. Don't close this terminal.${C_RST}"
    echo "${C_YEL}${C_BOLD}════════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo ""
    echo "  ${C_BOLD}Open this URL to approve (or scan the QR below):${C_RST}"
    echo ""
    echo "      ${C_CYA}${C_BOLD}${REG_URL}${C_RST}"
    echo ""
    echo "  auth-id: ${C_GRN}${AUTH_ID}${C_RST}"
    echo ""
    # Headplane admin UI = headscale host with the vpn.→headplane. prefix swapped.
    HEADPLANE_URL="https://headplane.${HEADSCALE_HOST#vpn.}/admin/"
    echo "  Approve it in the Headplane UI:"
    echo "    $HEADPLANE_URL   →   Machines → \"Register machine\""
    echo "    (paste this URL/auth-id or scan the QR, pick the user, click Register)"
    echo "  CLI fallback (if Headplane is down):"
    echo "    kubectl exec -n headscale deploy/headscale -- \\"
    echo "      headscale auth register --user on-premise-resident --auth-id $AUTH_ID"
    echo ""
    # Keyless registration cannot carry a tag: `headscale auth register` takes no --tags,
    # and the tag-at-mint trick used on the pre-auth-key path does not apply here. So a
    # keyless node joins UNTAGGED and matches only the ACL policy's permissive raw-user
    # half. Tag it explicitly after approval or it stays outside the tag-based grants.
    echo "  AFTER approving, tag the node (keyless joins cannot carry a tag):"
    echo "    kubectl exec -n headscale deploy/headscale -- \\"
    echo "      headscale nodes tag -i <node-id> -t tag:k8s-node"
    echo ""
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSI256 "$REG_URL"
    else
      echo "  (install qrencode on this node to show a scannable QR: apt-get install -y qrencode)"
    fi
    echo ""
    echo "Waiting for approval (Ctrl-C to abort)…"
    # `tailscale up` (UP_PID) blocks and exits 0 once approved. Bound the wait: a watchdog kills
    # `tailscale up` after ~1h so a forgotten approval can't hang the console forever. It must kill
    # UP_PID (not merely exit itself) or `wait` below would never return.
    ( for _ in $(seq 1 3600); do kill -0 "$UP_PID" 2>/dev/null || exit 0; sleep 1; done
      kill "$UP_PID" 2>/dev/null || true ) &
    WATCHDOG_PID=$!
    if wait "$UP_PID"; then
      kill "$WATCHDOG_PID" 2>/dev/null || true
      echo "Approved — node registered."
    else
      kill "$WATCHDOG_PID" 2>/dev/null || true
      echo "ERROR: registration did not complete — not approved within the wait window," >&2
      echo "       or rejected. Re-run this script on the node to get a fresh URL, then approve" >&2
      echo "       promptly via adoptProvisionedNodes.sh on the devcontainer." >&2
      cat "$UP_LOG" >&2 || true
      rm -f "$UP_LOG"; exit 1
    fi
  fi
  rm -f "$UP_LOG"
else
  # ── Pre-auth-key path (Pulumi/auto bring-up; or non-keyless manual generation) ──
  # --timeout so a rejected key / unreachable login-server fails loudly instead of blocking
  # forever (which strands the Pulumi remote.Command with no progress).
  timeout 90 tailscale up \
    --login-server "$HEADSCALE_URL" \
    --authkey "$TS_AUTHKEY" \
    --hostname "$TS_HOSTNAME" \
    --accept-dns=true \
    --accept-routes \
    ${TS_ROUTE_FLAG:+"$TS_ROUTE_FLAG"} \
    --timeout 60s \
    || { echo "ERROR: 'tailscale up' failed/timed out against $HEADSCALE_URL." >&2
         echo "  Check: pre-auth key validity, headscale reachability from this host," >&2
         echo "  and that the headscale CA is trusted (staging cert)." >&2
         tailscale status >&2 || true
         exit 1; }
fi

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

# ── ts.internal (MagicDNS) needs nothing from us ────────────────────────────────
# tailscaled programs systemd-resolved itself (SetLinkDNS over D-Bus): the tailscale0 link
# carries `DNS Servers: 100.100.100.100` + `DNS Domain: ts.internal`, and tailscaled re-syncs
# on every `systemd-resolved restarted`. Verified across tailscaled 1.98-1.102 on systemd
# 255/257/259 — no hand-written resolved drop-in is needed, and adding one back conflicts
# with the AD-zone dnsmasq below.
#
# ⚠ If ts.internal ever NXDOMAINs on a new node, check for a real SetLinkDNS failure first:
# `journalctl -u tailscaled | grep -i setlinkdns` (an exact match — a loose grep for
# "context deadline exceeded" hits thousands of unrelated bootstrapDNS/logtail timeouts and
# will convince you SetLinkDNS is broken when it is not).

# ── AD-zone resolver (every mesh node, unconditional) ───────────────────────────
# WHY: NFS mounts are performed by the KUBELET in the HOST netns, so they resolve through the
# NODE's resolver — NOT cluster DNS. The TrueNAS PVs address the appliance BY NAME
# (server: fs-1.$AD_DOMAIN), so a node whose resolver does not know that zone cannot mount them.
#
# ⚠ UNCONDITIONAL ON PURPOSE — do NOT make this a per-node opt-in:
#   a. There is no rule to apply correctly. Site membership does not imply zone resolution:
#      lab nodes do NOT get the zone from the lab router, they NXDOMAIN.
#   b. Its absence is INVISIBLE. A mount resolves the server name ONCE, at mount time, and the
#      kernel never re-resolves — so a node with no AD DNS looks perfectly healthy, with live
#      working mounts, right up until a pod restarts and cannot mount.
#   c. A per-node DC address goes stale: it would be baked in at provision time.
# A node that does not mount NFS simply never queries the zone, so installing this everywhere
# costs one idle dnsmasq and removes an entire class of misconfiguration.
#
# WHY dnsmasq AND NOT a systemd-resolved drop-in (do not "simplify" this back):
#   1. resolved's GLOBAL DNS=/Domains= are silently ignored here; `Global` never shows a
#      server, so a drop-in relying on that mechanism is inert.
#   2. Pointing resolved at a ClusterIP does not work either — for reasons 1/3/4, NOT
#      unreachability: Cilium's socket-LB intercepts a ClusterIP at connect() in the host netns,
#      so a plain `dig @<clusterIP>` from the node succeeds even though `ip route get` shows the
#      site gateway.
#   3. Putting the DC on the tailscale0 link ALONGSIDE MagicDNS breaks ts.internal — resolved
#      load-balances across a link's servers and the DC answers authoritatively NXDOMAIN for
#      tailnet names. Two zones cannot share one link.
#   4. A dummy link does not isolate them: resolved reports `Current Scopes: none` and ignores it.
#
# TWO TARGETS FOR THE ZONE, ClusterIP FIRST. dnsmasq tries them in order and fails over: with
# the first server black-holed the query still resolves from the second.
#   * $AD_DNS_CLUSTER_IP (network.adDnsClusterIp) is the ad-cloud-dns Service's PINNED ClusterIP.
#     It is a settings CONSTANT, identical on every cluster and every site, and its selector
#     follows the DC pod wherever it lands — so it cannot go stale the way a pod or node address
#     does. Reachable from the host netns on every node tested, across three sites.
#   * $AD_DC_IPS (nodes.mesh[].lanIp for every adDc node) are the fallbacks for the window
#     before Cilium has programmed socket-LB. Being AFTER the ClusterIP means a stale value
#     costs one failed query, not an outage — and there is one entry per on-prem DC, so a
#     single DC being down does not empty the fallback either.
# Deliberately NOT the DC's MESH ip (assigned by headscale in join order, unknowable here) and
# not a tailnet NAME (peers register under the BOX hostname, and the lab peer has no tailnet IPv4).
#
# BOOTSTRAP SAFETY: the only name needed before the cluster exists is k3s-api.ts.internal
# (K3S_URL), served by MagicDNS via the ts.internal line below. The AD zone is not consulted
# until a pod mounts, long after Cilium is up — so a ClusterIP target cannot wedge the join.
# And dnsmasq FAILS SOFT per zone: with the AD servers unreachable, ts.internal and public names
# kept resolving (measured). A dead DC therefore cannot cost this node the apiserver.
echo "Installing node-local AD-zone resolver (dnsmasq: $AD_DOMAIN)"
# dnsmasq-base ships the binary with no service unit; that is all we need (we run our own
# unit). Install only if absent so a re-provision is a no-op.
if ! command -v dnsmasq >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq-base || {
    echo "ERROR: could not install dnsmasq-base — the AD zone will not resolve on this node." >&2
  }
fi

# Upstream for everything that is NOT a special zone. Read from the CURRENT resolver rather
# than hardcoded: every site differs (home 192.168.178.1, uni <uni-gw>, lab 192.168.1.1,
# cloud <cloud-gw>) and one node already had MagicDNS as its primary, so there is no sane
# default. resolved's own upstream list lives in /run/systemd/resolve/resolv.conf (the REAL
# one, not the 127.0.0.53 stub).
UPSTREAM=""
for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
  [ -r "$f" ] || continue
  UPSTREAM=$(grep -E "^nameserver[[:space:]]+[0-9]" "$f" 2>/dev/null \
             | grep -v "127\.0\.0\." | awk '{print $2}' | head -1)
  [ -n "$UPSTREAM" ] && break
done

if [ -z "$UPSTREAM" ]; then
  # Refuse to take over resolution with nowhere to forward ordinary names — that would break
  # apt, the container registry and the node's own updates. Leaving resolved in place is the
  # safe failure: only the AD zone is missing, and that surfaces as a mount error.
  echo "WARNING: no usable upstream nameserver found; leaving /etc/resolv.conf alone." >&2
  echo "         NFS mounts by name will fail on this node until DNS is configured." >&2
else
  echo "  upstream=$UPSTREAM  ad-zone -> $AD_DNS_CLUSTER_IP,$(echo $AD_DC_IPS | tr ' ' ',')  ts.internal -> MagicDNS"
  mkdir -p /etc/dnsmasq.d
  cat > /etc/dnsmasq.d/ecc-ad-zone.conf << DNSMASQ_CONF
# Managed by 30-connect-vpn.sh. Do not edit by hand — a re-provision overwrites this.
port=53
# ⚠ 127.0.0.2, NOT 127.0.0.1 — the loopback is SHARED with the hostNetwork Samba DC.
# Samba's internal DNS binds 127.0.0.1:53 unconditionally (its \`interfaces\` setting does
# not move it), so a dnsmasq on 127.0.0.1 makes the DC die at startup with
# "Failed to listen on 127.0.0.1:53 - NT_STATUS_ADDRESS_ALREADY_ASSOCIATED". This resolver
# is installed on EVERY mesh node, so that collision took out the DC on whichever node it
# landed — not just one. lo carries 127.0.0.1/8, so .2 needs no extra address or route.
# Keep in step with deployment/argocd-infra/samba-ad/statefulset-onprem.yaml.
listen-address=127.0.0.2
bind-interfaces
no-resolv
no-hosts
# Samba AD zone. SEVERAL servers, tried in order with automatic failover: the pinned
# ad-cloud-dns Service ClusterIP first (a settings constant that follows the DC pod and
# survives recreates), then one entry per on-prem DC LAN address (covering the window before
# Cilium programs socket-LB, and each other's downtime).
server=/$AD_DOMAIN/$AD_DNS_CLUSTER_IP
$(for _ip in $AD_DC_IPS; do echo "server=/$AD_DOMAIN/$_ip"; done)
# Tailnet names -> MagicDNS, so this resolver is a superset of what the node had before.
server=/ts.internal/100.100.100.100
# Everything else -> the node's own upstream, captured at provision time.
server=$UPSTREAM
DNSMASQ_CONF

  # Our own unit: dnsmasq-base has none. Two other resolvers share this loopback and we
  # must collide with neither: systemd-resolved on 127.0.0.53/127.0.0.54, and the Samba DC
  # on 127.0.0.1 (see the listen-address note above). We take 127.0.0.2.
  cat > /etc/systemd/system/ecc-ad-dns.service << 'DNSMASQ_UNIT'
[Unit]
Description=ECC node-local AD-zone resolver (dnsmasq)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq.d/ecc-ad-zone.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
DNSMASQ_UNIT
  systemctl daemon-reload
  systemctl enable --now ecc-ad-dns.service 2>/dev/null || systemctl restart ecc-ad-dns.service

  # ⚠ TAKE DNS OWNERSHIP AWAY FROM tailscaled FIRST, or the pointer below is temporary.
  # With accept-dns on (`tailscale debug prefs` -> "CorpDNS": true) tailscaled does not merely
  # program a link via SetLinkDNS — it REWRITES /etc/resolv.conf wholesale, replacing
  # `nameserver 127.0.0.2` with MagicDNS (100.100.100.100). It does so on its own schedule:
  # a daemon restart, a netmap update, a reboot. This is the same lifetime trap documented for
  # table 52 further down — correct content, wrong owner.
  #
  # That is not hypothetical. Measured 2026-09-14 on unibi-hclab-pcie-tb-d: resolv.conf
  # rewritten by tailscale at 09:35, and because MagicDNS on this tailnet has NO upstream
  # resolvers of its own ("Resolvers (in preference order): (no resolvers configured, system
  # default will be used)"), it fell back to the "system default" it had just overwritten with
  # its own address. A resolution loop: every public name returned `Try again`, `getent hosts
  # registry-1.docker.io` failed, and containerd could not pull — 8 pods in ImagePullBackOff on
  # that node alone, which wedged an ArgoCD sync for hours on hook Jobs that could never start.
  #
  # NOTHING IS LOST by turning it off: the dnsmasq config above forwards /ts.internal/ to
  # 100.100.100.100, so MagicDNS still answers tailnet names — it is consulted THROUGH this
  # resolver instead of replacing it. Verified: a peer name resolved via @127.0.0.2.
  tailscale set --accept-dns=false >/dev/null 2>&1 || true

  # Point the node at it. resolv.conf is normally a symlink to resolved's stub; replace it
  # with a regular file. 00-cleanup-node.sh restores the symlink on teardown.
  #
  # ⚠ Gate on a name the resolver can actually answer WITHOUT the cluster or the tailnet.
  # This used to probe k3s-api.ts.internal, which is not a MagicDNS name on every tailnet
  # (it NXDOMAINs on ours), so the loop always ran its full 10 iterations and proved nothing.
  # A SERVFAIL/REFUSED-free answer for the AD zone's SOA is the cheap liveness signal: it only
  # asks whether dnsmasq is listening and routing a zone, not whether the DCs are up yet.
  for i in $(seq 1 10); do
    dig +time=2 +tries=1 @127.0.0.2 "$AD_DOMAIN" SOA >/dev/null 2>&1 && break
    sleep 1
  done
  rm -f /etc/resolv.conf
  {
    echo "# Managed by 30-connect-vpn.sh. Node-local dnsmasq splits DNS per zone;"
    echo "# see /etc/dnsmasq.d/ecc-ad-zone.conf."
    echo "nameserver 127.0.0.2"
    echo "options edns0 trust-ad"
    echo "search ts.internal"
  } > /etc/resolv.conf
  # ⚠ EXPLICIT 0644 — the provisioner runs under `umask 077` (nodes-k3s-mesh.ts) to protect
  # the token-bearing scripts it stages in /tmp, and without this every file it writes here
  # inherits 0600. resolv.conf holds no secret and is world-readable on every normal system;
  # at 0600 any non-root resolver path cannot read it and silently falls back to whatever
  # else NSS offers (systemd-resolved via mdns4_minimal/dns), which does NOT know the AD
  # zone — so root and non-root get DIFFERENT answers for the same name, invisibly.
  chmod 0644 /etc/resolv.conf

  # ── Self-healing guard for the resolver pointer ──────────────────────────────
  # ⚠ THE SWITCH ABOVE IS NOT ENOUGH ON ITS OWN, and the reason is the lesson already
  # learned twice in this file (table 52, and the ExecStartPost drop-in): a one-shot write at
  # provision time loses to a daemon that rewrites state on later events. `--accept-dns=false`
  # is a PREFERENCE held by tailscaled, and anything that restores it puts us straight back in
  # the outage — `tailscale up` re-run by hand without the flag, a re-login, a headscale policy
  # push, a daemon downgrade/upgrade that resets prefs. The provisioning run cannot defend
  # against any of those because it is long finished by then.
  #
  # WHY A GUARD RATHER THAN TRUSTING THE FLAG: the failure is INVISIBLE and DELAYED, which is
  # what makes it expensive. The node stays Ready, existing NFS mounts keep working (the kernel
  # resolves a mount's server name ONCE, at mount time, and never re-resolves), and cluster DNS
  # for pods is unaffected because that is CoreDNS, not the node resolver. It surfaces only
  # when something new must resolve a PUBLIC name in the host netns — an image pull, apt, a pod
  # restart needing a fresh mount — and it surfaces as ImagePullBackOff on one node, which
  # reads as a registry or capacity problem, not a DNS one. On 2026-09-14 that cost hours of a
  # wedged ArgoCD sync before anyone looked at the node's resolv.conf.
  #
  # The guard re-asserts BOTH halves (the pref and the file) whenever they drift. It is
  # deliberately idempotent and silent in the healthy case: it exits after two local reads when
  # nothing is wrong, so it is free to run often.
  #
  # ⚠ IT MUST NOT WRITE THE POINTER BLINDLY. Pointing resolv.conf at a dnsmasq that is not
  # listening would take out ALL name resolution on the node — a far worse outage than the one
  # being fixed (that is why the provisioning path above gates on a live query too). So the
  # guard PROBES 127.0.0.2 first and repairs only when the resolver actually answers; if
  # dnsmasq is down it tries to start it, and otherwise leaves whatever resolv.conf is there
  # alone and logs. Losing the AD zone is recoverable; losing DNS entirely is not.
  cat > /usr/local/bin/ecc-dns-pointer-guard <<'DNSGUARD'
#!/bin/sh
# Managed by provisioning (30-connect-vpn.sh) — do not edit.
# Keep this node pointed at its node-local split-DNS resolver (127.0.0.2), which tailscaled
# overwrites whenever accept-dns is on. See 30-connect-vpn.sh for the full rationale.
set -u

RESOLVER=127.0.0.2
PROBE_NAME="__AD_DOMAIN__"

# 1. The preference. Cheap to re-assert, and the root cause when it has flipped back.
if tailscale debug prefs 2>/dev/null | grep -q '"CorpDNS": true'; then
  logger -t ecc-dns-pointer-guard "tailscale accept-dns is back on — disabling (it clobbers /etc/resolv.conf)"
  tailscale set --accept-dns=false >/dev/null 2>&1 || true
fi

# 2. The pointer. Nothing to do in the healthy case — this is the usual exit.
grep -qE "^nameserver[[:space:]]+${RESOLVER}\b" /etc/resolv.conf 2>/dev/null && exit 0

# 3. Drifted. Do NOT repair against a dead resolver — that would cost the node ALL DNS.
if ! dig +short +time=2 +tries=1 "@${RESOLVER}" "$PROBE_NAME" SOA >/dev/null 2>&1; then
  systemctl is-active --quiet ecc-ad-dns.service || systemctl start ecc-ad-dns.service 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    dig +short +time=2 +tries=1 "@${RESOLVER}" "$PROBE_NAME" SOA >/dev/null 2>&1 && break
    sleep 1
  done
  if ! dig +short +time=2 +tries=1 "@${RESOLVER}" "$PROBE_NAME" SOA >/dev/null 2>&1; then
    logger -t ecc-dns-pointer-guard "resolv.conf drifted but ${RESOLVER} does not answer — leaving it alone"
    exit 1
  fi
fi

logger -t ecc-dns-pointer-guard "restoring nameserver ${RESOLVER} in /etc/resolv.conf (was: $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | tr '\n' ' '))"
rm -f /etc/resolv.conf
{
  echo "# Managed by 30-connect-vpn.sh. Node-local dnsmasq splits DNS per zone;"
  echo "# see /etc/dnsmasq.d/ecc-ad-zone.conf. Re-asserted by ecc-dns-pointer-guard."
  echo "nameserver ${RESOLVER}"
  echo "options edns0 trust-ad"
  echo "search ts.internal"
} > /etc/resolv.conf
chmod 0644 /etc/resolv.conf
DNSGUARD
  sed -i "s/__AD_DOMAIN__/${AD_DOMAIN}/g" /usr/local/bin/ecc-dns-pointer-guard
  chmod 755 /usr/local/bin/ecc-dns-pointer-guard

  cat > /etc/systemd/system/ecc-dns-pointer-guard.service <<'DNSGUARDUNIT'
[Unit]
Description=Keep /etc/resolv.conf pointed at the node-local split-DNS resolver
After=network-online.target ecc-ad-dns.service
Wants=network-online.target
DNSGUARDUNIT
  cat >> /etc/systemd/system/ecc-dns-pointer-guard.service <<DNSGUARDUNIT2
After=${TS_SERVICE}.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ecc-dns-pointer-guard
DNSGUARDUNIT2

  # Every 5 min, matching mesh-endpoint-watchdog: the healthy path is two local reads, and a
  # clobber costs at most one interval of broken public DNS on that node. OnBootSec is late
  # enough that tailscaled has settled and done its rewrite if it is going to — repairing
  # before that would just be undone.
  cat > /etc/systemd/system/ecc-dns-pointer-guard.timer <<'DNSGUARDTIMER'
[Unit]
Description=Periodic check that this node still uses its split-DNS resolver
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
DNSGUARDTIMER

  # tailscaled rewrites resolv.conf on netmap/link events, not on a schedule, so a dispatcher
  # hook closes most of the window the timer would otherwise leave open. Best-effort and
  # silent, exactly like 50-ecc-lan-local-rule above.
  install -d /etc/NetworkManager/dispatcher.d
  cat > /etc/NetworkManager/dispatcher.d/51-ecc-dns-pointer-guard <<'DNSDISP'
#!/bin/sh
# Re-assert the node-local resolver pointer when an interface comes up or changes
# address. See 30-connect-vpn.sh. Best-effort by design.
case "$2" in
  up|dhcp4-change|dhcp6-change) ;;
  *) exit 0 ;;
esac
[ -x /usr/local/bin/ecc-dns-pointer-guard ] || exit 0
/usr/local/bin/ecc-dns-pointer-guard >/dev/null 2>&1 || true
DNSDISP
  chmod 755 /etc/NetworkManager/dispatcher.d/51-ecc-dns-pointer-guard

  systemctl daemon-reload
  systemctl enable --now ecc-dns-pointer-guard.timer >/dev/null 2>&1 || true
  echo "  DNS pointer guard installed (timer: every 5 min)."

  # Report, do NOT fail: the AD zone is legitimately unresolvable on a FRESH cluster, where
  # this script runs long before the DCs exist. The node only needs it when a pod mounts.
  if getent hosts "fs-1.$AD_DOMAIN" >/dev/null 2>&1; then
    echo "  AD zone resolves via the node resolver."
  else
    echo "  ($AD_DOMAIN not resolving yet — expected on a fresh cluster; the DCs come up later.)"
  fi
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

# ── Keep THIS node's own LAN local, even when a peer advertises it ────────────
# ⚠ A subnet router poisons its own site. One lab node advertises the site LAN into the
# mesh (project_settings nodes.mesh[].advertiseRoutes), and every OTHER node at that site
# runs with `--accept-routes`, so tailscale installs that prefix into ITS OWN table 52:
#
#     ip rule:  5270: from all lookup 52      <- ABOVE 32766: main
#     table 52: 192.168.1.0/24 dev tailscale0
#
# The node then sends traffic to its OWN directly-connected LAN over the overlay, with a
# mesh source address. Outbound still works (the far side answers over the mesh), so the
# node looks healthy — but anything that dials the node BY ITS LAN ADDRESS gets no reply:
# the SYN/echo arrives on the physical NIC and the answer leaves via tailscale0 from
# 10.0.10.x, which the sender never accepts.
#
# It matters beyond cosmetics: a hostNetwork workload that must be reachable on the site
# LAN (the on-prem AD DCs, which serve 88/389/445/464/636 to TrueNAS and laptops) simply
# cannot work on such a node. It also hairpins ordinary pod traffic to the LAN out to the
# advertising router and back.
#
# ⚠ DO NOT FIGHT FOR TABLE 52 — that was tried and it loses. Writing the connected prefix
# into table 52 (`ip route replace <lan> dev <nic> table 52`) is correct in CONTENT and
# wrong in LIFETIME: `RouteAll` is set, so tailscaled re-installs
# `192.168.1.0/24 dev tailscale0` on the next netmap update and the entry is gone.
# Measured 2026-09-01 on the live cluster: three of four lab nodes back in the broken state
# ~1.5 h after provisioning, while unibi-lab-pcie-tb-s still carried the table-52 entry —
# but only because it is the ADVERTISER, which never accepts the prefix back and so is the
# one node that never needed the fix.
#
# ⚠ AN ExecStartPost DROP-IN IS ALSO INSUFFICIENT, for two independent reasons: writing it
# and calling `systemctl daemon-reload` does NOT restart the service, so it never fires on
# the provisioning run (measured: drop-in mtime 23-26s AFTER ActiveEnterTimestamp on three
# nodes); and it fires once per start, while the clobber happens on netmap events later.
#
# THE FIX IS A ROUTING RULE, which sidesteps ownership of table 52 entirely. Live rule table
# on a mesh node:
#
#     9:      from all fwmark 0x200/0xf00 lookup 2004      <- Cilium
#     100:    from all lookup local
#     5210:   from all fwmark 0x80000/0xff0000 lookup main  \
#     5230:   from all fwmark 0x80000/0xff0000 lookup default > tailscaled
#     5250:   from all fwmark 0x80000/0xff0000 unreachable  /
#     5270:   from all lookup 52                           <- the poisoned table
#     32766:  from all lookup main
#
# Priority 5000 sits BELOW Cilium's marked-traffic rule and `local` (so it cannot shadow
# either) and ABOVE everything tailscaled installs, and it names `main`, where the kernel's
# own connected route already lives. tailscaled rewrites table 52; it never touches this
# rule. On a node whose LAN nobody advertises the rule is a pure no-op — `main` is where
# that traffic was going anyway — so this is applied unconditionally on every mesh node.
LAN_RULE_PRIO=5000
LAN_NIC=$(ip -4 -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
# ⚠ The DEFAULT ROUTE's interface, never "the first global-scope address". docker0 carries a
# global 172.17.0.1/16 and would win that scan on any node running docker (measured on
# unibi-lab-fs-vm).
if [ -n "$LAN_NIC" ]; then
  # The connected prefix, not the host address: 192.168.1.194/24 -> 192.168.1.0/24
  LAN_NET=$(ip -4 -o route show dev "$LAN_NIC" scope link 2>/dev/null \
              | awk '$1 ~ /\// {print $1; exit}')
  if [ -n "$LAN_NET" ]; then
    echo "Pinning own LAN local: rule 'to $LAN_NET lookup main' at priority $LAN_RULE_PRIO"
    # Delete-then-add rather than `replace` — `ip rule` has no replace, and adding twice
    # stacks duplicates that survive reboots.
    while ip rule del priority "$LAN_RULE_PRIO" 2>/dev/null; do :; done
    ip rule add to "$LAN_NET" lookup main priority "$LAN_RULE_PRIO" 2>/dev/null || true
  else
    echo "  (no connected LAN prefix on $LAN_NIC — skipping LAN-local pin.)"
  fi
else
  echo "  (no default-route NIC found — skipping LAN-local pin.)"
fi

# Persist as a STANDALONE oneshot rather than a tailscaled drop-in. The rule does not live
# in a table tailscaled owns, so it needs no ordering against tailscaled at all — which is
# precisely what made the drop-in approach fail. Recomputed at boot rather than baked in,
# because the address is a DHCP reservation and the NIC name differs per node.
# A stale drop-in from the previous (table-52) approach is removed so the two cannot fight.
#
# ⚠ NEEDING NO ORDERING AGAINST tailscaled IS NOT THE SAME AS NEEDING NO ORDERING AT ALL.
# The unit still races the LAN NIC itself — `network-online.target` does not wait for it —
# which is a different failure from the table-52 one this design was built to avoid, and it
# bit on 2026-09-11. Verified the same day that a full tailscaled router reconfig (toggling
# --accept-routes, which tears down and re-adds 192.168.1.0/24 in table 52) leaves the rule
# untouched: the ownership argument above holds. The script's own wait loop and the
# dispatcher hook below are what handle the NIC race; do not "simplify" either away.
rm -f "/etc/systemd/system/${TS_SERVICE}.service.d/lan-local-route.conf"
cat > /usr/local/bin/ecc-lan-local-rule <<'LANRULE'
#!/bin/sh
# Keep this node's own connected LAN in `main`, above tailscaled's table 52.
# See the long note in 30-connect-vpn.sh. Idempotent; safe to re-run.
#
# ⚠ WAIT FOR THE NIC, AND FAIL IF IT NEVER COMES. `network-online.target` does NOT
# mean this node's LAN NIC has an address: Ubuntu gates that target on
# `nm-online -s`, which waits for NetworkManager to report STARTUP COMPLETE and not
# for any particular interface. On a slow-carrier NIC (igc takes ~9s to link up) the
# target therefore fires BEFORE DHCP, and an earlier version of this script — which
# did `[ -n "$nic" ] || exit 0` — silently added no rule at all.
#
# That failure is invisible in every place an operator looks: the unit reports
# `active (exited)` with status 0, RemainAfterExit keeps it that way, and nothing
# ever re-runs it. Measured 2026-09-11 on pcie-tb-d: unit finished 12:39:23.200,
# carrier at 12:39:26.140, DHCP at 12:39:26.294 — the rule was three seconds too
# early and never existed. The node routed its own LAN over tailscale0 for the rest
# of the boot, which took the on-prem AD DC it hosts off the LAN (inbound SYNs
# arrived on the NIC, replies left via the overlay) and failed the TrueNAS domain
# join hours later with a DNS error naming that DC.
#
# So: poll, and exit NON-ZERO on timeout. A failed unit is visible; a no-op is not.
set -eu
PRIO="${LAN_RULE_PRIO:-5000}"
WAIT="${LAN_RULE_WAIT:-60}"

nic=""; net=""
i=0
while [ "$i" -lt "$WAIT" ]; do
  nic=$(ip -4 -o route show to default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$nic" ]; then
    net=$(ip -4 -o route show dev "$nic" scope link | awk '$1 ~ /\// {print $1; exit}')
    [ -n "$net" ] && break
  fi
  i=$((i + 1))
  sleep 1
done

if [ -z "$net" ]; then
  echo "ecc-lan-local-rule: no connected IPv4 LAN prefix after ${WAIT}s" >&2
  echo "  (default-route NIC: '${nic:-none}') — refusing to exit 0 on a no-op." >&2
  exit 1
fi

echo "ecc-lan-local-rule: pinning $net to table main at priority $PRIO (via $nic)"
while ip rule del priority "$PRIO" 2>/dev/null; do :; done
ip rule add to "$net" lookup main priority "$PRIO"
LANRULE
chmod 755 /usr/local/bin/ecc-lan-local-rule
cat > /etc/systemd/system/ecc-lan-local-rule.service <<LANUNIT
[Unit]
Description=Keep this node's own LAN in the main routing table (above tailscale table 52)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=LAN_RULE_PRIO=${LAN_RULE_PRIO}
Environment=LAN_RULE_WAIT=60
ExecStart=/usr/local/bin/ecc-lan-local-rule
# ⚠ RETRY. network-online.target can fire before this node's LAN NIC has carrier
# (see the header of the script), so the first attempt may legitimately find no
# default route. The script now waits and then FAILS rather than exiting 0, which
# only helps if something acts on the failure — hence Restart. Without this pair a
# lost race is permanent until the next reboot, because RemainAfterExit means
# systemd never reconsiders a unit it believes succeeded.
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
LANUNIT

# ⚠ BOOT IS NOT THE ONLY TIME THE RULE CAN GO MISSING. The unit fires once; a DHCP
# renewal that changes the prefix, or a NIC that re-activates later, would leave the
# rule naming a stale network with nothing to re-run it. A dispatcher hook costs
# nothing and closes that gap — NetworkManager runs it on every interface up/change.
# It is deliberately silent and best-effort: the unit above is what must be visible
# when the rule genuinely cannot be installed.
install -d /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/50-ecc-lan-local-rule <<'LANDISP'
#!/bin/sh
# Re-assert this node's LAN-local routing rule when an interface comes up or
# changes address. See 30-connect-vpn.sh. Best-effort by design.
case "$2" in
  up|dhcp4-change|dhcp6-change) ;;
  *) exit 0 ;;
esac
[ -x /usr/local/bin/ecc-lan-local-rule ] || exit 0
LAN_RULE_WAIT=5 /usr/local/bin/ecc-lan-local-rule >/dev/null 2>&1 || true
LANDISP
chmod 755 /etc/NetworkManager/dispatcher.d/50-ecc-lan-local-rule

systemctl daemon-reload
systemctl enable ecc-lan-local-rule.service >/dev/null 2>&1 || true
echo "Persistent LAN-local rule unit installed (ecc-lan-local-rule.service)."

# ── Endpoint-refresh watchdog (dynamic WAN IP recovery) ───────────────────────
# Sites on a residential line get a new public IP every few days. When that
# happens tailscaled can end up in a SPLIT state that nothing recovers from:
#
#   * the WireGuard data path keeps working (it re-pins to whatever address
#     still answers — often the IPv6 one), so `tailscale ping` succeeds and the
#     handshake timestamp stays fresh, but
#   * the node stops reporting its endpoint list to headscale, which then holds
#     `endpoints: None`, marks the node `online: false`, and the k3s agent
#     tunnel (the thing behind `kubectl logs`/`exec`) is never rebuilt.
#
# It presents as last_seen stuck days back while `tailscale ping` answers in
# ~20 ms and the kubelet serves /healthz fine. Everything that does NOT use the
# agent tunnel (node Ready, heartbeats, kubectl top, metrics-server) keeps
# working, which makes it easy to misdiagnose as a dead box.
#
# The daemon will not fix this itself, so probe for the split state and force a
# re-announce. `tailscale set --advertise-exit-node=false` is a no-op config
# write whose side effect is a fresh map request to the control plane — cheaper
# and far less disruptive than restarting tailscaled. Only if that fails to
# clear the state do we escalate to a daemon restart, and only then bounce
# k3s-agent, whose tunnel does not always recover on its own.
cat > /usr/local/bin/mesh-endpoint-watchdog <<'WATCHDOG'
#!/bin/sh
# Managed by provisioning (30-connect-vpn.sh) — do not edit.
# Detect "WireGuard fine, control plane stale" and force a re-announce.
set -u

# Peer we always have: the control plane holds the headscale server itself.
# If we cannot even resolve our own status, tailscaled is down — leave that to
# systemd's own Restart= handling rather than fighting it here.
tailscale status >/dev/null 2>&1 || exit 0

# Self must have a stable backend state. "Running" means the daemon believes it
# is connected; the failure mode we target reports Running while the control
# plane disagrees, so this is a precondition, not the test.
STATE=$(tailscale status --json 2>/dev/null | tr -d " \n" | grep -oE '"BackendState":"[A-Za-z]+"' | head -n1 | sed 's/.*:"//;s/"//')
[ "$STATE" = "Running" ] || exit 0

# The test: can we still reach the control plane's HTTP endpoint? A node whose
# endpoints went stale keeps its data path but stops being seen by headscale.
# Self.Online is what headscale thinks of US, reflected back in our own status.
ONLINE=$(tailscale status --json 2>/dev/null | tr -d " \n" | sed 's/.*"Self":{//; s/"Peer":.*//' | grep -oE '"Online":(true|false)' | head -n1 | sed 's/.*://')

if [ "$ONLINE" = "true" ]; then
  exit 0
fi

logger -t mesh-endpoint-watchdog "control plane reports this node offline while tailscaled is Running — forcing re-announce"

# Step 1: cheap re-announce. A config write triggers a fresh map request.
tailscale set --advertise-exit-node=false >/dev/null 2>&1 || true
sleep 15
ONLINE=$(tailscale status --json 2>/dev/null | tr -d " \n" | sed 's/.*"Self":{//; s/"Peer":.*//' | grep -oE '"Online":(true|false)' | head -n1 | sed 's/.*://')
if [ "$ONLINE" = "true" ]; then
  logger -t mesh-endpoint-watchdog "recovered after re-announce"
  exit 0
fi

# Step 2: restart the daemon so it rediscovers endpoints from scratch.
logger -t mesh-endpoint-watchdog "re-announce insufficient — restarting __TS_SERVICE__"
systemctl restart __TS_SERVICE__ || exit 1
for _ in $(seq 1 30); do
  [ -S /run/tailscale/tailscaled.sock ] && break
  sleep 1
done
sleep 20
ONLINE=$(tailscale status --json 2>/dev/null | tr -d " \n" | sed 's/.*"Self":{//; s/"Peer":.*//' | grep -oE '"Online":(true|false)' | head -n1 | sed 's/.*://')
[ "$ONLINE" = "true" ] || { logger -t mesh-endpoint-watchdog "still offline after daemon restart — giving up this cycle"; exit 1; }

# Step 3: the mesh is back, but the k3s agent tunnel was pinned to the dead
# path. Without this, `kubectl logs`/`exec` keep returning 502 even though the
# node looks healthy — and Longhorn will not manage volumes on a node whose
# manager it cannot reach.
if systemctl is-active --quiet k3s-agent.service; then
  logger -t mesh-endpoint-watchdog "mesh recovered — restarting k3s-agent to rebuild the tunnel"
  systemctl restart k3s-agent.service || true
fi
WATCHDOG
sed -i "s/__TS_SERVICE__/${TS_SERVICE}/g" /usr/local/bin/mesh-endpoint-watchdog
chmod +x /usr/local/bin/mesh-endpoint-watchdog

cat > /etc/systemd/system/mesh-endpoint-watchdog.service <<'UNIT'
[Unit]
Description=Recover tailscale endpoint reporting after a WAN IP change
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mesh-endpoint-watchdog
UNIT

# Every 5 min: fast enough that a dynamic-IP change costs minutes of tunnel
# downtime rather than days, slow enough that the probe itself is free (it is a
# local socket read that exits immediately in the healthy case).
cat > /etc/systemd/system/mesh-endpoint-watchdog.timer <<'UNIT'
[Unit]
Description=Periodic tailscale endpoint-staleness check
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now mesh-endpoint-watchdog.timer
echo "Endpoint-refresh watchdog installed (timer: every 5 min)."

echo ""
echo "Next step: 40-join-cluster.sh"
