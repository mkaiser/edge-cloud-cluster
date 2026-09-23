#!/bin/bash
# Seals the sambacc configuration for the Samba AD domain controllers.
#
# THE WHOLE CONFIG DOCUMENT IS SEALED, not just a password field. sambacc takes a single
# JSON document (`samba-container-config: v0`) and the domain administrator password lives
# INSIDE it (`domain_settings.<name>.admin_password`) — there is no separate password
# input. So the document as a whole is secret and is mounted at the path
# SAMBACC_CONFIG points to (/etc/samba/container/config.json).
#
# One document serves BOTH DCs. `configs` holds one key per DC (cloud, lab); each pod
# picks its key via the SAMBA_CONTAINER_ID env var. They share `domain_settings`, which is
# what makes them the same domain.
#
# DELIBERATELY NOT SEEDING USERS. sambacc can create `domain_users` / `domain_groups` at
# provision time. Do not use it: Authentik is the sole identity write path (Phase 2), and a
# second write path is exactly the divergent-write hazard the two-DC design rules out.
#
# Seals against the PULUMI-held cert (`sealedSecretsTlsCrt`), matching every other
# sealSecrets.sh here. Pulumi is the source of truth for this keypair, not the cluster:
# src/sealedsecrets.ts seeds the controller from it, so sealing works with NO cluster —
# including before `make bootstrap` — and survives cluster recreation.
#
# instance_name IS THE POD HOSTNAME, DELIBERATELY.
#
# sambacc uses instance_name as the DC's netbios name and hence its AD identity
# (dcname -> the `<name>.<realm>` A record and the SRV records that point at it). If that
# differs from the POD hostname, the DC ends up with TWO identities in its own DNS:
#
#   dccloud.<realm>          A 10.42.0.44    written once at provision, NEVER updated
#   ad-cloud-0.<realm> A 10.42.0.231   maintained by samba_dnsupdate on every start
#
# Only the pod-hostname record self-heals — the StatefulSet guarantees that name is stable
# while the pod IP is not, so samba_dnsupdate re-points it after every restart. The
# provisioned name silently rots, and a peer resolving it gets
# NT_STATUS_HOST_UNREACHABLE — which is what blocks a lab DC re-join, while
# `samba_dnsupdate --verbose` says "No DNS updates needed" and is RIGHT: it is
# maintaining the other name.
#
# Making the two the same removes the duplicate identity entirely. Cost: the netbios name
# is now SAMBA-AD-CLOUD-0 (15-char limit — it fits) rather than a tidy DCCLOUD. That shows
# up in `ECC\<dc>` listings and nowhere that matters; users authenticate as ECC\<user>.
#
# ⚠ THE LAB DC'S instance_name IS THE TOKEN `__POD_NAME__`, NOT A LITERAL. There are now
# several on-prem DCs (one per node labelled ecc/ad-dc), and each needs its OWN netbios
# name; a literal would make every replica claim one AD identity. The resolve-node-config
# initContainer in statefulset-onprem.yaml substitutes the pod name from the downward API,
# which is exactly the value this comment argues for. The cloud DC is a single replica and
# keeps its literal.
#
# ⚠ ad-cloud-0 MUST track the cloud StatefulSet's pod name. Renaming that StatefulSet
# without changing it re-introduces the split.
#
# THE LAB DCs BIND EXPLICIT INTERFACES ONLY. They run hostNetwork, so without this Samba
# tries 0.0.0.0:53 and collides with systemd-resolved (which holds 127.0.0.53:53 and
# 127.0.0.54:53) — "Failed to bind to 0.0.0.0:53 TCP - NT_STATUS_ADDRESS_ALREADY_ASSOCIATED"
# and the DC crashloops. An explicit list also stops it registering its tailscale address in
# DNS: dclab.<realm> was resolving to an IPv6 mesh address, which would send Kerberos/LDAP
# over the WAN instead of the LAN and defeat the point of a lab-site DC.
#
# NOTE sambacc's dynamic interface selection (domain_settings.interface_config) is applied
# on PROVISION only — commands/addc.py:87 — and NOT on join, so the lab DCs need these as
# explicit global options. The cloud DC is not hostNetwork and needs none of this.
#
# ⚠ THE LAN NIC IS THE TOKEN `__LAB_NIC__`, NOT A LITERAL, and it is DERIVED rather than
# configured. The name differs on every box — measured 2026-09-01 across the four lab nodes:
# eno2np1, enp129s0, ens3, enP2p1s0 — so a literal is wrong on all but one, and a list of
# all four is one more piece of node-scoped state in an opaque blob. resolve-node-config
# reads the node's DEFAULT-ROUTE interface from /proc/net/route (this pod is hostNetwork, so
# that is the host's table) and substitutes it. Correct on any node the DC lands on, and it
# needs no re-seal when a box is replaced.
#
# The realm is NOT prompted for: it is derived from project_settings.ts
# (activeDirectory.adLabel) so the sealed config cannot drift from the manifests. Only the
# password is entered.
#
# ⚠ THE REALM IS BAKED INTO sam.ldb AT PROVISION TIME. Re-sealing with a different realm
# does NOT migrate an existing domain — it produces DCs that cannot join. Changing the
# realm means deleting both DC PVCs and re-doing Phase 2 (Authentik sync) and Phase 3
# (TrueNAS join).
#
# Usage: ./sealSecrets.sh          # prompt for the admin password
#        ./sealSecrets.sh --show   # show the current realm/config shape, no changes
#
# Non-interactive (CI): set SAMBA_ADMIN_PASSWORD. Prefer the interactive path; a password
# in the environment is visible to other processes on the machine.
set -euo pipefail

NAMESPACE="samba-ad"
SECRET_NAME="samba-ad-config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR"
SEALED_OUT="$MANIFEST_DIR/samba-ad-secrets-sealed.yaml"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETTINGS="$REPO_DIR/project_settings.ts"
SEALED_FILES=()

# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/deployment/manageSealedSecrets.sh"

# --- derive realm/domain from project_settings.ts -----------------------------------
# Mirrors the getters in the activeDirectory block: adLabel -> <adLabel>.internal, realm is
# the uppercase of that, short domain is the NetBIOS name. Regex-scraped, because the
# script cannot execute TypeScript (same approach as updateConfigFromProjectSettings.sh).
ad_label="$(sed -n '/activeDirectory: {/,/^    },/p' "$SETTINGS" \
  | sed -nE 's/^[[:space:]]*adLabel:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
netbios="$(sed -n '/activeDirectory: {/,/^    },/p' "$SETTINGS" \
  | sed -nE 's/^[[:space:]]*netbiosName:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"

if [ -z "$ad_label" ] || [ -z "$netbios" ]; then
  echo "ERROR: could not read activeDirectory.adLabel / .netbiosName from $SETTINGS" >&2
  echo "       (the block must keep the plain 'adLabel: \"...\"' literal form)" >&2
  exit 1
fi

ad_domain="${ad_label}.internal"
realm="$(echo "$ad_domain" | tr '[:lower:]' '[:upper:]')"

echo "Realm      : $realm"
echo "AD domain  : $ad_domain"
echo "NetBIOS    : $netbios"
echo "Secret     : $SECRET_NAME (namespace $NAMESPACE)"
echo

if [ "${1:-}" = "--show" ]; then
  if [ -f "$SEALED_OUT" ]; then
    echo "Sealed file present: $SEALED_OUT"
  else
    echo "No sealed file yet at $SEALED_OUT"
  fi
  exit 0
fi

# --- admin password -----------------------------------------------------------------
# AD enforces its own complexity policy (7+ chars, 3 of 4 character classes by default).
# A password that fails it makes `samba-tool domain provision` fail with an error that
# does not obviously say "your password was rejected", so check it here.
#
# Offers keep / replace / generate via the shared prompt_keg helper, the same three-way
# choice authentik/sealSecrets.sh uses, so re-running for an unrelated reason (adding the
# dns-forwarder token, a rename, a recreate) does not require retyping the password.
#
# ⚠ GENERATE USES AN AD-COMPLEXITY-SAFE ALPHABET, NOT `openssl rand -hex`. AD enforces
# 3-of-4 character classes, and lowercase hex is ONE class: such a value seals fine and is
# then rejected at provision time with
#   0000052D: check_password_restrictions: the password does not meet the complexity criteria
# which does not obviously say "your password was rejected" — a 2-class value like
# `blahblah123` is enough to trip it. base64 gives mixed case + digits; the `Aa1!` suffix
# guarantees all four classes regardless of what the random draw happened to contain.
if [ -n "${SAMBA_ADMIN_PASSWORD:-}" ]; then
  admin_pw="$SAMBA_ADMIN_PASSWORD"
  echo "Using SAMBA_ADMIN_PASSWORD from the environment."
else
  # ⚠ try_recover CANNOT be used directly here. It reads a FLAT `.data[<key>]`, but this
  # secret has exactly one key — `config.json` — with the password NESTED inside it as
  # domain_settings.primary.admin_password. Asking try_recover for ADMIN_PASSWORD returns
  # EMPTY, and "keep" would then silently seal an empty password: the DCs come up, the
  # provision succeeds with a blank Administrator credential, and every later bind fails
  # with NT_STATUS_LOGON_FAILURE. So recover the whole config.json and pull the field out.
  _existing_admin_pw="$(try_recover "$SEALED_OUT" config.json 2>/dev/null \
    | jq -r '.domain_settings.primary.admin_password // empty' 2>/dev/null || true)"
  admin_pw=""
  if [ -n "$_existing_admin_pw" ]; then
    prompt_keg "Domain Administrator password" "true" "true"
  else
    prompt_keg "Domain Administrator password" "false" "true"
  fi
  case "$KEG_CHOICE" in
    keep)
      admin_pw="$_existing_admin_pw"
      echo "  keeping the existing Domain Administrator password."
      ;;
    generate)
      admin_pw="$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 32)Aa1!"
      echo "  generated a new Domain Administrator password (AD-complexity-safe alphabet)."
      echo "  ⚠ It is stored ONLY in the sealed file (and in the live Secret once"
      echo "    ArgoCD syncs). Recover it later with, from this directory:"
      echo "      kubeseal --recovery-unseal --recovery-private-key <(pulumi config get \\"
      echo "        sealedSecretsTlsKey) < samba-ad-secrets-sealed.yaml -o json \\"
      echo "        | jq -r '.data[\"config.json\"]' | base64 -d \\"
      echo "        | jq -r .domain_settings.primary.admin_password"
      ;;
    *)
      read -r -s -p "  Domain Administrator password: " admin_pw; echo
      read -r -s -p "  Repeat: " admin_pw2; echo
      if [ "$admin_pw" != "$admin_pw2" ]; then
        echo "ERROR: passwords do not match." >&2
        exit 1
      fi
      ;;
  esac
fi

if [ ${#admin_pw} -lt 12 ]; then
  echo "ERROR: too short for the AD password policy (min length 12, set by" >&2
  echo "       samba-ad/postsync-provision-users.yaml step 0b)." >&2
  exit 1
fi

# --- build the sambacc config -------------------------------------------------------
# `instance_name` becomes the DC's netbios name (samba-tool --option=netbios name=...), so
# the two DCs MUST differ here. domain_settings is shared: that is what makes them one
# domain rather than two.
#
# cloud_bind.tls* — points LDAPS at the cert-manager-issued pair (tls-cert.yaml) instead of
# Samba's autogenerated self-signed one. Required for Authentik's password write-back:
# `unicodePwd` is refused in the clear, so the write happens over LDAPS, and ldap3 verifies
# the chain. The autogenerated cert fails on BOTH counts — untrusted, and its only SAN is
# the AD FQDN, which does not resolve in-cluster (see tls-cert.yaml's header for why the
# CoreDNS forward never loaded).
#
# ⚠ ABSOLUTE paths. Relative values are resolved against Samba's private dir, and this
# Secret is deliberately mounted at /etc/samba/tls — outside private/tls, so it cannot be
# confused with or overwritten by the autogenerated pair.
#
# ⚠ The key names are the k8s TLS Secret's, not Samba's: tls.crt / tls.key / ca.crt.
#
# These reach smb.conf only because statefulset-cloud.yaml runs an apply-global-options
# initContainer — sambacc merges `globals` ONCE at provision/join and silently ignores
# later edits. Without that container this block is inert.
#
# lab_bind.interfaces — every entry is load-bearing:
#   __LAB_NIC__          the node's LAN NIC -> its LAN address. TrueNAS and the laptops
#                        reach real AD ports there; this is the whole reason for
#                        hostNetwork. Derived per node — see the token note in the header.
#   __MESH_IP__/255.255... the mesh IP. REQUIRED for replication: the CLOUD DC can route to
#                        the mesh but NOT to the lab LAN, so without this it dials the LAN,
#                        times out, and cloud<-lab replication fails with WERR_SEM_TIMEOUT
#                        while lab<-cloud keeps working. That asymmetry is quiet — a user
#                        created on the cloud DC still propagates, so replication looks fine
#                        until something ORIGINATES at the lab (including the lab DC's own
#                        DNS registration).
#   10.42.0.0/255.255.0.0  the POD NETWORK RANGE. REQUIRED for the OTHER direction.
#                        `bind interfaces only` constrains OUTBOUND source selection too, not
#                        just listeners: the cloud DC is an ordinary pod (10.42.x.y), the
#                        kernel routes to it via the CNI, and samba REFUSES a source address
#                        that is not in this list — lab<-cloud replication then fails
#                        WERR_HOST_UNREACHABLE even though a plain TCP connect to the same
#                        address succeeds. Adding the mesh IP without this REGRESSES the
#                        direction that already worked.
#
#                        ⚠ DO NOT NAME A CNI DEVICE HERE. There is none that works:
#                        Cilium's pod-side veths are per-pod (lxc<hash>, so not knowable
#                        here), and `cilium_host` carries the node's cilium-internal router
#                        IP as a /32 — the SAME point-to-point shape documented below for
#                        tailscale0, which samba's IPv4 enumeration silently skips. Naming
#                        either loads cleanly, echoes back in testparm, and binds nothing.
#                        A RANGE with a wide netmask sidesteps the per-node/per-pod address
#                        entirely and matches whatever pod IP this DC actually gets — samba
#                        uses the netmask only for matching (see the interface_ips() note
#                        below). Verify with samba.interface_ips() after any change here,
#                        never by reading testparm.
#   lo                   samba's own local access.
#
# ⚠ WHY THE MESH ADDRESS AND NOT THE INTERFACE NAME. Writing `tailscale0` here does NOT
# work, and fails SILENTLY: samba loads the config, testparm echoes the name back, and the
# AD ports still bind only the LAN address. tailscale0 is POINTOPOINT with a /32, and
# samba's IPv4 enumeration skips a point-to-point /32 — it picks up only the interface's
# IPv6 /128. Measured on ad-onprem-0 (eno2np1, LAN .216, mesh 10.0.10.8 at the time):
#     'lo eno2np1 tailscale0'                -> ['192.168.1.216', 'fd7a:115c:a1e0::8']
#     'lo eno2np1 10.0.10.8'                 -> ['192.168.1.216']            (bare IP: no)
#     'lo eno2np1 10.0.10.8/255.255.255.255' -> ['192.168.1.216']            (/32: no)
#     'lo eno2np1 10.0.10.8/255.255.255.0'   -> ['192.168.1.216', '10.0.10.8']   <- works
# The netmask is only used for matching, so a wider one is correct here; a /32 reads as an
# empty range. Check with interface_ips() after any change, never by reading testparm.
#
# ⚠ AND WHY THE NIC NAME IS SAFE TO DERIVE. An interface that is ABSENT is silently IGNORED,
# so naming the wrong one costs the LAN bind rather than failing loudly. Re-measured on the
# live ad-onprem-0 2026-09-01 (mesh 10.0.10.4):
#     'lo eno2np1 ...'      -> [..., '192.168.1.216', '10.0.10.4', '10.42.3.159']
#     'lo eno2np1 ens3 ...' -> [..., '192.168.1.216', '10.0.10.4', '10.42.3.159']  <- ens3 ignored
#     'lo ens3 ...'         -> [...,                  '10.0.10.4', '10.42.3.159']  <- LAN bind LOST
# That is exactly why the NIC must be the node's REAL one, and why resolve-node-config
# derives it from the default route instead of anyone maintaining a list here.#
# `server services` DROPS "nbt" (the default list otherwise) — required, and directly caused
# by the netmask above. NetBIOS derives a BROADCAST address from the netmask, so /255.255.255.0
# on a /32 point-to-point address makes nbtd compute 10.0.10.255, which is not assigned to the
# node. It then hard-fails the WHOLE server at startup:
#     Failed to bind to 10.0.10.255:137 - NT_STATUS_ADDRESS_NOT_ASSOCIATED
#     task_server_terminate: [nbtd failed to setup interfaces]
# Losing NetBIOS costs nothing here: `server min protocol = SMB2_02`, and SMB2+ does not use
# NetBIOS at all — it is a NT4-era name service. This also closes 137-139, which the design
# notes were never wanted (see the port list in the app README).
#
# ⚠ This parameter ALSO decides what samba_dnsupdate publishes: it derives the A record from
# `samba.interface_ips(lp)`, and dns_update_list's `$IP` placeholder expands to ONE RECORD PER
# INTERFACE IP (samba_dnsupdate lines 814-829 — it is a loop, not a substitution). Left
# unpinned, this DC would publish all three of its addresses.
#
# `dns update command` pins it to the MESH ip, 10.0.10.8. That choice is forced, and the
# reasoning matters because the obvious alternative (publish the LAN IP, which is what lab
# clients actually want) was tried first and does NOT work:
#
#   - The A record is ONE replicated directory object. It cannot differ per DC, so the cloud
#     DC and the lab clients necessarily resolve the same address.
#   - DRS resolves the peer through samba's OWN DNS and IGNORES /etc/hosts. A `hostAliases`
#     entry on the cloud DC pod therefore does NOT redirect replication: `getent` resolves
#     the mesh address while /proc/net/tcp shows DRS dialling the LAN one in SYN_SENT.
#     Do not re-try this approach.
#   - Publishing BOTH addresses does not help either: DRS picks the LAN one and hangs rather
#     than failing over to the second.
#   - The cloud node cannot reach the lab LAN at all — `ip route get <lab-lan>` there
#     resolves via the PUBLIC gateway (178.xxx.xxx.xxx). NOT because the route is missing:
#     pcie-tb-s advertises 192.168.1.0/24 and headscale has it APPROVED and serving. The
#     cloud CPs never INSTALL it, because mesh-gateway/daemonset.yaml runs `tailscale up`
#     WITHOUT --accept-routes — the flag is all-or-nothing and would also install
#     10.0.0.0/23 over tailscale0 and break etcd peer TLS. Policy, not topology, and no
#     samba setting can fix either.
#
# The mesh IP is the only address BOTH sides can reach, so it is what gets published.
#
# ⚠ CONSEQUENCE FOR LAB CLIENTS, ACCEPTED KNOWINGLY: anything resolving a DC by its OWN
# name gets the mesh address and so reaches it over the overlay rather than the LAN. Each DC
# still LISTENS on its LAN address (see `interfaces` above), so a client pointed at that
# address keeps the direct path.
#
# That is what the LAN-only names are for, and TrueNAS is the case that matters: it has only
# a LAN address, so replication-job.yaml publishes one `dc-lan-<n>.<realm>` A record per
# on-prem DC and retargets the SITE-scoped SRV records at those names. A separate NAME, not
# a second A record on the DC's own name — DRS resolves <DSA-GUID>._msdcs.<realm>, a CNAME
# to that same name, so any LAN address added there is inherited by the cloud DC, which
# round-robins onto it and stalls with WERR_SEM_TIMEOUT.
#
# Verify after any change with a DNS query returning exactly ONE A record — never by reading
# the samba_dnsupdate log, which reports success while records are missing.
#
# ⚠ THE MESH IP IS NOT WRITTEN HERE. Both places that need it use the literal token
# `__MESH_IP__`, which the `resolve-node-config` initContainer substitutes at pod start
# from the downward API (`status.podIP`). Under hostNetwork that IS the node's mesh
# address — verified: node InternalIP and pod IP are the same value.
#
# ⚠ DO NOT put a literal address here. Measured with a literal 10.0.10.8: the lab node was
# re-addressed to 10.0.10.11, the sealed secret still said .8, samba could not bind an
# address the node no longer had, and the DC CrashLooped 63 times with
#     Failed to listen on 10.0.10.8:53 - NT_STATUS_ADDRESS_NOT_ASSOCIATED
# taking cloud replication down to 5/10 partitions. A sealed secret is the wrong place for
# cluster-scoped state: it is opaque, it needs the Pulumi stack to regenerate, and nothing
# validates it against reality.
config_json="$(cat <<EOF
{
  "samba-container-config": "v0",
  "configs": {
    "cloud": {
      "instance_features": ["addc"],
      "domain_settings": "primary",
      "instance_name": "ad-cloud-0",
      "globals": ["cloud_bind"]
    },
    "lab": {
      "instance_features": ["addc"],
      "domain_settings": "primary",
      "instance_name": "__POD_NAME__",
      "globals": ["lab_bind"]
    }
  },
  "globals": {
    "cloud_bind": {
      "options": {
        "tls enabled": "yes",
        "tls certfile": "/etc/samba/tls/tls.crt",
        "tls keyfile": "/etc/samba/tls/tls.key",
        "tls cafile": "/etc/samba/tls/ca.crt"
      }
    },
    "lab_bind": {
      "options": {
        "interfaces": "lo __LAB_NIC__ __MESH_IP__/255.255.255.0 __POD_CIDR_NETMASK__",
        "bind interfaces only": "yes",
        "dns update command": "/usr/bin/samba_dnsupdate --current-ip=__MESH_IP__",
        "server services": "s3fs, rpc, wrepl, ldap, cldap, kdc, drepl, ft_scanner, winbindd, ntp_signd, kcc, dnsupdate, dns",
        "dns forwarder": "__DNS_FORWARDER__"
      }
    }
  },
  "domain_settings": {
    "primary": {
      "realm": "$realm",
      "short_domain": "$netbios",
      "admin_password": "$admin_pw"
    }
  }
}
EOF
)"

# --- seal against the Pulumi-held cert (source of truth) --------------------
CERT=$(mktemp); trap 'rm -f "$CERT"' EXIT

echo "Reading sealed-secrets cert from the Pulumi stack..."
if ! (cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt) > "$CERT" 2>/dev/null; then
  echo "ERROR: could not read sealedSecretsTlsCrt from the Pulumi stack." >&2
  echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
  exit 1
fi

# Guard the ecc146 failure mode explicitly: an EMPTY or malformed value would
# otherwise seal against garbage and fail silently at mount time, weeks later.
if [[ ! -s "$CERT" ]]; then
  echo "ERROR: sealedSecretsTlsCrt is EMPTY on this stack." >&2
  echo "  Sealing now would produce data no controller can decrypt." >&2
  echo "  Recover the keypair into Pulumi config before continuing —" >&2
  echo "  see the pulumi-sealed-secrets-key-empty memory." >&2
  exit 1
fi
if ! FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null | cut -d= -f2); then
  echo "ERROR: sealedSecretsTlsCrt is not a parseable X.509 certificate." >&2
  exit 1
fi
echo "  cert: $FINGERPRINT"

# Cross-check against the live cluster, if one is reachable.
#
# `kubeseal --fetch-cert` returns only the controller's NEWEST key, but the controller
# DECRYPTS with any key it holds. It routinely holds more than one: Pulumi seeds
# `sealed-secrets-key` (src/sealedsecrets.ts) and the controller then generates its own on
# first start. So a fetch-cert mismatch is NOT by itself a problem — the real question is
# whether the Pulumi cert is among the controller's keys. Check that directly.
if LIVE=$(kubeseal --controller-name=sealed-secrets-controller \
                   --controller-namespace=kube-system \
                   --fetch-cert 2>/dev/null \
          | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2); then
  if [[ -n "$LIVE" && "$LIVE" == "$FINGERPRINT" ]]; then
    echo "  live controller: newest key matches Pulumi"
  else
    # Look for the Pulumi cert among ALL the controller's keys.
    found=""
    for k in $(kubectl get secrets -n kube-system \
                 -l sealedsecrets.bitnami.com/sealed-secrets-key \
                 -o name 2>/dev/null); do
      fp=$(kubectl get "$k" -n kube-system -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
           | base64 -d 2>/dev/null \
           | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
      [[ "$fp" == "$FINGERPRINT" ]] && { found="$k"; break; }
    done
    if [[ -n "$found" ]]; then
      echo "  live controller: Pulumi's key is present (${found#secret/}); newest is a"
      echo "                   controller-generated key — normal, decryption will work."
    else
      echo "  WARNING: Pulumi's cert is NOT among the controller's keys." >&2
      echo "    newest live: $LIVE" >&2
      echo "  Data sealed here will NOT decrypt until the stack and cluster agree." >&2
    fi
  fi
else
  echo "  (no cluster reachable — fine, the Pulumi cert is authoritative)"
fi

mkdir -p "$MANIFEST_DIR"
# Single key `config.json`: the file sambacc reads via SAMBACC_CONFIG. The admin
# password is inside it, which is why the whole document is sealed.
#
# The realm/short_domain are ALSO stamped as CLEARTEXT annotations, deliberately. Neither
# is a secret — the realm is committed in plaintext in eight manifests already, and the
# only real secret in this blob is admin_password. They are sealed purely because sambacc
# consumes ONE json document and the password has to be inside it.
#
# WHY THE STAMP: netbiosName -> short_domain is the one identity value that NO anchor
# reaches (updateConfigFromProjectSettings.sh rewrites plaintext YAML; this file is
# ciphertext). Without the stamp, editing project_settings.ts and not re-running this
# script is a SILENT no-op: the DCs provision on the OLD identity while every manifest
# claims the new one, surfacing late as a Kerberos/SMB error that reads like a permissions
# problem.
# The annotation makes the sealed identity readable WITHOUT the Pulumi key, which is what
# lets updateConfigFromProjectSettings.sh diff it and fail loudly instead.
#
# ⚠ Keep these two annotation values in step with the config_json above. They are a
# MARKER, not a source — sambacc reads config.json and never looks at them.
kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --from-literal=config.json="$config_json" \
    --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --format yaml \
  | REALM="$realm" SHORT_DOMAIN="$netbios" perl -pe '
      if (/^  template:$/) {
          $_ .= "    metadata:\n";
          $_ .= "      annotations:\n";
          $_ .= "        # Cleartext MARKER of the identity this blob was sealed with, so a\n";
          $_ .= "        # drift check can read it without the Pulumi key. NOT read by sambacc.\n";
          $_ .= "        ecc/sealed-realm: \"$ENV{REALM}\"\n";
          $_ .= "        ecc/sealed-short-domain: \"$ENV{SHORT_DOMAIN}\"\n";
          $skip_tmpl_meta = 1;
      } elsif ($skip_tmpl_meta && /^    metadata:$/) {
          $_ = "";              # kubeseal emits its own template.metadata; drop the dup
          $skip_tmpl_meta = 0;
      }
  ' > "$SEALED_OUT"
unset admin_pw admin_pw2

echo "Written: samba-ad-secrets-sealed.yaml  (sambacc config incl. admin password, sealed)"
echo
echo "NOTE: the realm is baked into sam.ldb at provision time. If you changed it, both DC"
echo "      PVCs must be deleted before the new config has any effect."
SEALED_FILES+=("$SEALED_OUT")

# ── Copies of two Authentik-side secrets, for postsync-provision-users.yaml ────────────
#
# A Secret cannot be read across namespaces, so this namespace seals its OWN copy of the
# same plaintext — the established pattern here (see argocd-apps/jitsi/sealSecrets.sh and
# remote-desktop/sealSecrets.sh, which do the same for AUTHENTIK_PROVISIONER_TOKEN).
#
#   AD_PROVISIONER_TOKEN   — the ad-provisioner service account's API token, used to READ
#                            users from Authentik.
#   SAMBA_AD_BIND_PASSWORD — the password the Job SETS on the authentik-sync AD account and
#                            that authentik-blueprint-ad-source.yaml binds with. Both sides must carry
#                            the same value or write-back fails to bind.
#
# ⚠ Run argocd-infra/authentik/sealSecrets.sh FIRST — these are recovered from its bundle.
AUTHENTIK_BUNDLE="$REPO_DIR/deployment/argocd-infra/authentik/authentik-secrets-sealed.yaml"
AD_PROV_TOKEN=$(try_recover "$AUTHENTIK_BUNDLE" AD_PROVISIONER_TOKEN)
AD_BIND_PW=$(try_recover "$AUTHENTIK_BUNDLE" SAMBA_AD_BIND_PASSWORD)
if [[ -z "$AD_PROV_TOKEN" || -z "$AD_BIND_PW" ]]; then
  echo "ERROR: AD_PROVISIONER_TOKEN / SAMBA_AD_BIND_PASSWORD not found in the authentik" >&2
  echo "       bundle. Run deployment/argocd-infra/authentik/sealSecrets.sh first." >&2
  exit 1
fi
AUTHENTIK_SEALED_OUT="$MANIFEST_DIR/samba-ad-authentik-sealed.yaml"
kubectl create secret generic samba-ad-authentik \
    --namespace "$NAMESPACE" \
    --from-literal=AD_PROVISIONER_TOKEN="$AD_PROV_TOKEN" \
    --from-literal=SAMBA_AD_BIND_PASSWORD="$AD_BIND_PW" \
    --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --format yaml > "$AUTHENTIK_SEALED_OUT"
unset AD_PROV_TOKEN AD_BIND_PW
echo "Written: samba-ad-authentik-sealed.yaml  (copies of the two Authentik-side secrets)"
SEALED_FILES+=("$AUTHENTIK_SEALED_OUT")

if [[ -z "${SKIP_GIT_COMMIT:-}" ]]; then
  ask_and_commit_sealed_files \
    "samba-ad: seal sambacc AD domain configuration" \
    "${SEALED_FILES[@]}"
fi
