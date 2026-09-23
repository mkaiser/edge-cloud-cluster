#!/usr/bin/env python3
"""
Project: edgecloudinfra
File: scripts/environment/applyProjectSettings.py
Purpose: Push project_settings.ts into the YAML/shell that cannot import it.

Author: Martin Kaiser
Copyright (c) 2026 Martin Kaiser
License: MIT
SPDX-License-Identifier: MIT
"""

# THE anchor engine. Reads the settings ONCE (as JSON, from dumpProjectSettings.mjs, with
# getters already resolved) and rewrites every machine-managed literal in ONE pass over the
# corpus, writing only the files whose text actually changed.
#
# A managed literal is marked by a trailing anchor comment:
#
#     key: value   # automatically updated from project-settings:<key>
#     KEY=value    # automatically updated from project-settings:{<key>,<key>}
#
# and nothing else is rewritten. Two rule modes cover every anchor:
#
#   whole     (default) the value is whatever sits between the separator and the anchor
#             comment; it is replaced entirely, quotes and spacing preserved. Separators:
#             `key: value`, `KEY=value`, `- value` (sequence item), `${VAR:-value}` (shell
#             default). Because the whole value is replaced, a value can never eat a prefix
#             of its neighbour — the ordering hazards the old per-shape regexes had
#             (fqdn before hostname, meshStorageClass before meshStorageScope) do not exist.
#   embedded  a substring rewrite inside a larger value, declared per key. Only four keys
#             need it: the cluster hostname inside URLs and mail addresses, the S3 host
#             inside an endpoint URL, the bucket tokens inside a multi-bucket line, and the
#             issuer name inside an issuerRef/annotation.
#
# Both orphan directions are ERRORS, which is what makes a renamed settings path fail loudly:
#   * an anchor naming a key with no resolver,
#   * a resolver no anchor ever reaches (bar the declare-only allowlist),
#   * an anchored line whose value did not end up equal to the resolved value.

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHOR_MARK = "automatically updated from project-settings:"
# The anchor comment itself: `#` (YAML/shell) or `//` (HuJSON, src/*.ts), the marker, then the
# field list — either a bare `group.field` or a `{a,b,c}` list mirroring the TS object syntax.
ANCHOR_RE = re.compile(
    r"(?P<comment>(?:#|//)\s*" + re.escape(ANCHOR_MARK) + r"\s*(?P<list>\{[^}]*\}|[A-Za-z0-9_.\[\]]+))"
)

# Keys that are deliberately DECLARE-ONLY: the anchor records provenance and feeds
# checkSiteAnchors.py, but nothing is rewritten.
#
# applicationPlacements.labels.* — a label KEY is not in value position, so there is no single
# place to anchor a substitution. Renaming one is a grep-replace across the tree, and the
# checker is what proves nothing was missed. Two measured corruptions from trying anyway:
# `"ecc/mesh=true" = "NoSchedule"` (a compound literal whose right-hand side was eaten) and
# `nodes labelled ecc/ad-dc with an ecc/lan-ip` (two keys on one line collapsed into one).
#
# general.name / storage.objectStorage.baseEndpoint(as trigger) — these appear in field lists
# as TRIGGERS alongside the key that actually drives the rewrite.
# applicationPlacements.celLiteral.* — a value that a SECOND parser re-reads after YAML.
# A CEL `expression:` needs its own string quotes INSIDE the YAML scalar, and the rewrite
# owns the whole value region, so it strips exactly those quotes and leaves a bare
# identifier CEL rejects ("undeclared reference to 'unibi'"). A TOKEN_SHAPE cannot fix it
# either: the table is keyed by settings path, so a shape narrow enough for the quoted CEL
# line breaks the seven plain `ecc/site: <value>` anchors that share the key. Declare-only
# keeps the provenance and the checkSiteAnchors.py coverage, and the literal is maintained
# by hand — which is safe here precisely because checkSiteAnchors.py fails on an unanchored
# site literal.
DECLARE_ONLY_PREFIXES = ("applicationPlacements.labels.", "applicationPlacements.celLiteral.")


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ── reading the source of truth ───────────────────────────────────────────────────────────
# project_settings.ts is EVALUATED, not scraped, so its getters (general.tld,
# activeDirectory.{adDomain,realm,baseDn}, storage.fileserver.{fqdn,machineAccount},
# network.cpMeshIps, …) come out resolved and cannot drift from a re-implementation here.
#
# Node runs the program below with --eval, so there is no loader file on disk. Two
# module-resolution hooks are needed to load the settings under type stripping, and
# registerHooks installs both synchronously in the calling thread:
#
#  1. `@pulumi/pulumi` resolves to an in-memory stub. The real module loads, but
#     `Config.requireSecret()` THROWS without a stack ("Missing required configuration
#     variable"), and every value it returns is a secret nothing in the rewrite path reads.
#     The stub hands back a marker serialising as "<secret>" — no stack, passphrase or network.
#  2. The repo's relative imports are EXTENSIONLESS (`./project_settings_types`), which is
#     TypeScript convention but not resolvable by Node. Append `.ts` for those.
#
# ⚠ registerHooks' hooks are SYNCHRONOUS — nextResolve/nextLoad return values, not promises.
DUMP_PROGRAM = r"""
import { registerHooks } from "node:module";

const PULUMI_STUB = "ecc-pulumi-stub:pulumi";
const PULUMI_SOURCE = `
    class SecretMarker { toJSON() { return "<secret>"; } }
    export class Config {
        constructor(_name) {}
        get(_k) { return undefined; }
        require(k) { return "<config:" + k + ">"; }
        getSecret(_k) { return new SecretMarker(); }
        requireSecret(_k) { return new SecretMarker(); }
        getBoolean(_k) { return undefined; }
        getNumber(_k) { return undefined; }
    }
    export default { Config };
`;

registerHooks({
    resolve(specifier, context, nextResolve) {
        if (specifier === "@pulumi/pulumi") {
            return { url: PULUMI_STUB, shortCircuit: true, format: "module" };
        }
        if (specifier.startsWith(".") && !/\.[cm]?[jt]s$/.test(specifier)) {
            try { return nextResolve(specifier + ".ts", context); } catch {}
        }
        return nextResolve(specifier, context);
    },
    load(url, context, nextLoad) {
        if (url === PULUMI_STUB) {
            return { format: "module", source: PULUMI_SOURCE, shortCircuit: true };
        }
        return nextLoad(url, context);
    },
});

// Getters are own enumerable properties, so JSON.stringify invokes them; functions and
// `undefined` values drop out on their own.
const { project_settings } = await import(process.env.ECC_SETTINGS_TS);
process.stdout.write(JSON.stringify(project_settings, null, 2));
"""


def load_settings(settings_ts: Path) -> dict:
    """Evaluate project_settings.ts and return it as a plain dict."""
    out = subprocess.run(
        ["node", "--experimental-strip-types", "--no-warnings", "--eval", DUMP_PROGRAM],
        env={**os.environ, "ECC_SETTINGS_TS": str(settings_ts)},
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        die(f"could not evaluate {settings_ts}:\n{out.stderr.strip()}")
    return json.loads(out.stdout)


# ── settings → resolver map ───────────────────────────────────────────────────────────────
def pod_cidr_netmask(cidr: str) -> str:
    """podCidr in ADDRESS/NETMASK form. Samba's `interfaces` takes a netmask, not a prefix
    length, so the same range has two spellings that must not diverge."""
    n = ipaddress.ip_network(cidr, strict=False)
    return f"{n.network_address}/{n.netmask}"


def build_resolvers(ps: dict) -> dict[str, str]:
    """anchor key -> the exact string that must appear in the file."""
    g, net, tls = ps["general"], ps["network"], ps["tls"]
    ad, stor, ap = ps["activeDirectory"], ps["storage"], ps["applicationPlacements"]
    fs, ds = stor["fileserver"], stor["fileserver"]["datasets"]
    obj = stor["objectStorage"]
    ha = ps["highAvailability"]

    mesh_nodes = [n for n in ps["nodes"]["mesh"] if n.get("enabled", True)]
    # Every on-prem LAN advertised by a mesh node, de-duplicated in first-seen order. Consumed
    # by the samba-ad subnet-to-site mapping, which must name the LANs in the on-prem AD site.
    lab_subnets: list[str] = []
    for n in mesh_nodes:
        for r in n.get("advertiseRoutes") or []:
            if r not in lab_subnets:
                lab_subnets.append(r)
    # DC placement is a property of the NODES, not of the domain.
    dc_lan_ips = [n["lanIp"] for n in mesh_nodes if n.get("adDc") and n.get("lanIp")]

    # Public IPv4 of the first enabled robot node — headscale's embedded-DERP address. It is
    # not in the hcloud API, so project_settings.ts is the only source.
    dedicated_ip = next(
        (n["publicIp"] for n in ps["nodes"]["cloud"]
         if n.get("enabled", True) and n.get("provider") == "robot" and n.get("publicIp")),
        None,
    )

    s3_endpoint = obj["baseEndpoint"]
    s3_region = s3_endpoint.split(".")[0]

    r: dict[str, str] = {
        "general.domain": g["domain"],
        "general.subdomain": g["subdomain"],
        "general.tld": g["tld"],
        "general.name": g["name"],
        "general.k3sVersion": g["k3sVersion"],
        "tls.certIssuerType": tls["certIssuerType"],
        "mail.senderEmail": ps["mail"]["senderEmail"],
        "storage.objectStorage.baseEndpoint": s3_endpoint,
        "storage.objectStorage.buckets": "",  # embedded rule; see BUCKET_SUFFIXES
        "nodes.mesh[].advertiseRoutes": " ".join(lab_subnets),
        # An EMPTY list is legal and is written through: no node carries adDc, so the AD zone
        # has only its ClusterIP server. Guarding on non-empty would leave a stale list behind
        # after the last DC node is un-enrolled — a black-holed resolver rather than none.
        "nodes.mesh[].lanIp": " ".join(dc_lan_ips),
        # The pod anti-affinity is `required`, so replicas > nodes leaves a pod Pending forever
        # and replicas < nodes silently leaves a node without a DC.
        "nodes.mesh[].adDc": str(len(dc_lan_ips)),
        "activeDirectory.adDomain": ad["adDomain"],
        "activeDirectory.realm": ad["realm"],
        "activeDirectory.baseDn": ad["baseDn"],
        "activeDirectory.labDnsForwarder": ad.get("labDnsForwarder", ""),
        "activeDirectory.uidStartNumber": str(ad["uidStartNumber"]),
        "activeDirectory.gidStartNumber": str(ad["gidStartNumber"]),
        "storage.fileserver.hostname": fs["hostname"],
        "storage.fileserver.site": fs["site"],
        "storage.fileserver.endpoint": fs["endpoint"],
        "storage.fileserver.fqdn": fs["fqdn"],
        "storage.fileserver.machineAccount": fs["machineAccount"],
        "storage.fileserver.pool": fs["pool"],
        "storage.fileserver.labCidr": fs["labCidr"],
        "storage.fileserver.datasets.homes.dataset": ds["homes"]["dataset"],
        "storage.fileserver.datasets.shared.parent": ds["shared"]["parent"],
        "storage.fileserver.datasets.shared.dataset": ds["shared"]["dataset"],
        "storage.fileserver.datasets.shared.tmpDataset": ds["shared"]["tmpDataset"],
        "storage.fileserver.datasets.shared.tmpQuota": ds["shared"]["tmpQuota"],
        "storage.fileserver.datasets.eda.parent": ds["eda"]["parent"],
        "storage.fileserver.datasets.eda.installers": ds["eda"]["installers"],
        "storage.fileserver.datasets.eda.moduleFiles": ds["eda"]["moduleFiles"],
        "storage.fileserver.datasets.eda.builds": ds["eda"]["builds"],
        "storage.fileserver.datasets.imageRegistry.dataset": ds["imageRegistry"]["dataset"],
        "storage.fileserver.datasets.aiModels.dataset": ds["aiModels"]["dataset"],
        "applicationPlacements.meshSite": ap["meshSite"],
        "applicationPlacements.meshStorageScope": ap["meshStorageScope"],
        # Composed rather than stored as a fourth setting: two keys that must always satisfy
        # `b == "longhorn-" + a` is a drift surface with no upside.
        "applicationPlacements.meshStorageClass": "longhorn-" + ap["meshStorageScope"],
        # Composed, never stored — same rationale as meshStorageClass above. The scope
        # itself is not exported: nothing references it directly, only the class name.
        "applicationPlacements.ryaxStorageClass": "longhorn-" + ap["ryaxStorageScope"],
        "applicationPlacements.cloudSite": ap["cloudSite"],
        "highAvailability.enabled": str(ha["enabled"]).lower(),
    }

    # network.* — the flat keys plus the derived ones. Names match the anchors, which predate
    # the JSON dump, so a few differ from the TS field names (cniMtu vs cni.mtu).
    cni = net["cni"]
    r.update({
        "network.meshRange": net["meshRange"],
        "network.subnetRange": net["subnetRange"],
        "network.privateRange": net["privateRange"],
        "network.gateway": net["gateway"],
        "network.vip": net["vip"],
        "network.tailscalePort": str(net["tailscalePort"]),
        "network.k3sApiPort": str(net["k3sApiPort"]),
        "network.cniTunnelPort": str(cni["tunnelPort"]),
        "network.cniMtu": str(cni["mtu"]),
        "network.cniOverlayInterfaces": cni["overlayInterfaces"],
        "network.podCidr": cni["podCidr"],
        "network.serviceCidr": cni["serviceCidr"],
        "network.adDnsClusterIp": cni["adDnsClusterIp"],
        "network.clusterDnsIp": cni["clusterDnsIp"],
        # Derived so they cannot drift from the ranges they mirror. cloudSubnets is
        # SPACE-separated (samba-ad CLOUD_SUBNETS); trustedProxyCidrs is COMMA-separated
        # (zulip LOADBALANCER_IPS takes one string).
        "network.cloudSubnets": f'{net["subnetRange"]} {net["meshRange"]} {cni["podCidr"]}',
        "network.trustedProxyCidrs": f'{cni["podCidr"]},{net["privateRange"]}',
        "network.podCidrNetmask": pod_cidr_netmask(cni["podCidr"]),
        "network.labSubnets": " ".join(lab_subnets),
    })
    if dedicated_ip:
        r["nodes.dedicated[0].publicIp"] = dedicated_ip

    # The address Cilium dials for the apiserver before a pod network exists. NOT network.vip:
    # kube-vip is a pod and cannot be up before the CNI it would serve — that deadlocks a fresh
    # create. Mirrors initCpApiHost() in src/cni.ts: the node carrying clusterLink:"init".
    init_cp = next(
        (n["privateIp"] for group in ps["nodes"].values() if isinstance(group, list)
         for n in group if n.get("clusterLink") == "init" and n.get("privateIp")),
        None,
    )
    if init_cp:
        r["network.initCpPrivateIp"] = init_cp

    # highAvailability.replicas.<key> — max when HA is on, min when off.
    for key, span in ha["replicas"].items():
        r[f"highAvailability.replicas.{key}"] = str(span["max"] if ha["enabled"] else span["min"])

    # applicationPlacements.labels.* — declare-only (see DECLARE_ONLY_PREFIXES), registered so
    # an anchor naming one is not an orphan.
    for key, value in ap["labels"].items():
        r[f"applicationPlacements.labels.{key}"] = value

    # Declare-only too: the same site value where it is embedded in a CEL expression that
    # YAML hands to a second parser. See DECLARE_ONLY_PREFIXES.
    r["applicationPlacements.celLiteral.meshSite"] = ap["meshSite"]

    # ── TLS pseudo-keys ───────────────────────────────────────────────────────────────────
    # Every app that talks to Authentik over HTTPS from its own backend needs a "trust the
    # staging CA" switch flipped with certIssuerType. Each lives under a different key in a
    # different file; deriving them as pseudo-keys makes each line SELF-LOCATING, which is what
    # retires the hardcoded file lists. Skipping a file was invisible: the anchor says the line
    # is machine-managed, so review moves on, and nothing reported that it was never rewritten.
    # Measured on ecc208 — eda-pcb-agent sat on the STAGING CA bundle on a letsencrypt-prod
    # cluster and its OIDC discovery died with CERTIFICATE_VERIFY_FAILED for good.
    prod = tls["certIssuerType"] == "letsencrypt-prod"
    r.update({
        "tls.oidcSkipVerify": "false" if prod else "true",
        "tls.nodeTlsReject": "1" if prod else "0",
        "tls.verifySsl": "True" if prod else "False",
        "tls.grafanaSkipVerify": "false" if prod else "true",
        "tls.allowUnsecureCert": "false" if prod else "true",
        "tls.curlInsecure": "" if prod else "-k",
        # On prod the registry cert is publicly trusted; on staging the CA is untrusted in the
        # build pod. BOTH copies must move — .gitlab-ci.yml AND build-files-configmap.yaml,
        # since the ConfigMap copy is what the build-trigger mirrors into GitLab.
        "tls.registryTlsVerify": "true" if prod else "false",
        # NODE_EXTRA_CA_CERTS / SSL_CERT_FILE. SSL_CERT_FILE *replaces* Python's trust store
        # (it is not additive), so it must never point at the staging-only bundle on prod.
        "tls.oidcCaBundle": "/etc/ssl/certs/ca-certificates.crt" if prod
                            else "/etc/ssl/staging-ca/ca-bundle.pem",
        "tls.ryaxEnvironment": "production" if prod else "stg",
    })
    return r


# S3 bucket suffix -> resolved bucket name. The app buckets are not declared in
# project_settings.buckets[]; they follow the `${general.name}-<suffix>` convention. The
# SUFFIX is what FINDS the existing token (`<anyprefix>-<suffix>`), so the value updates from
# any old prefix. Sorted longest-first at use, and the negative lookahead stops `-zulip`
# eating `-zulip-avatars` or `-gitlab` eating `-gitlab-pg`.
APP_BUCKET_SUFFIXES = [
    "gitlab-artifacts", "eda-builds", "gitlab-lfs", "gitlab-uploads", "gitlab-packages",
    "gitlab-external-diffs", "gitlab-terraform-state", "gitlab-ci-secure-files",
    "gitlab-dependency-proxy", "gitlab-pages", "gitlab-backups", "gitlab-tmp",
    "gitlab-registry", "gitlab-runner-cache", "nextcloud-files", "authentik", "headscale",
    "zulip-avatars", "zulip", "loki",
]


def bucket_rewrites(ps: dict) -> list[tuple[str, str]]:
    """(suffix, resolved name) pairs, longest suffix first."""
    cluster = ps["general"]["name"]
    pairs: list[tuple[str, str]] = []
    # Pulumi-owned buckets carry a DECLARED name in project_settings.buckets[]; app buckets do
    # not and are derived. `key` there is the settings-side name, `name` the bucket itself.
    declared = {b["key"]: b["name"] for b in ps["storage"]["objectStorage"].get("buckets", [])}
    for key, suffix in (("etcd", "etcd"), ("longhornBackup", "longhorn-backup")):
        pairs.append((suffix, declared.get(key) or f"{cluster}-{suffix}"))
    for suffix in APP_BUCKET_SUFFIXES:
        pairs.append((suffix, f"{cluster}-{suffix}"))
    return sorted(pairs, key=lambda p: -len(p[0]))


# ── line rewriting ────────────────────────────────────────────────────────────────────────
# An anchored line is split into BODY (everything left of the anchor comment) and TAIL (the
# comment onward). Inside the BODY, the managed value is found by VALUE POSITION: the last
# separator, then the token after it.
#
#   ${VAR:-value}   shell default (ryax manageWorker.sh) — the default only, not the var name
#   - value         YAML sequence item (matchExpressions), which has no key to its left
#   key: value      YAML mapping, `key = value` / `KEY=value` shell or TOML assignment
#   directive x;    nginx config line (gitlab-s3-proxy's upstream `server <fqdn>:<port>;`)
#
# The value region is then narrowed to the managed TOKEN. Most anchors own the whole region,
# but a handful embed their value inside a larger one, and each is a real line in the tree:
#
#   server fs-1.ad.base.internal:30304;   an fqdn with a :PORT and a statement terminator
#   share: /mnt/datapool/shared/data      a dataset path under an unmanaged /mnt prefix
#   internal_host: https://fs-1...        an fqdn behind an unmanaged URL scheme
#   bind_cn: CN=authentik-sync,CN=Users,dc=ad,…   a baseDn as the SUFFIX of a longer DN
#   "data_center_name": "unibi-hclab", …  a value inside a JSON/Python dict literal
#
# So each key declares the SHAPE of its own token (TOKEN_SHAPES below) and the rewrite
# replaces the last match of that shape inside the value region. Shape-matching is what the
# old per-key perl passes did; what changes here is that the shape is a property of the KEY
# (one table) rather than of the pass (seventeen hand-tuned regexes), and that the match is
# confined to a value position, so a key containing digits or dots can never be rewritten —
# `k8sServicePort: 6443` became `k6443sServicePort: 6443` when it was not.
VALUE_SHAPES = [
    re.compile(r"(?P<pre>:-)(?P<val>[^}]*)(?P<post>\})"),
    re.compile(r"(?P<pre>^\s*-\s+)(?P<val>.*?)\s*$"),
    # `directive value;` — an nginx config line (gitlab-s3-proxy `server <fqdn>:<port>;`),
    # whose separator is the space after the directive name and whose terminator is the `;`.
    # Ahead of the bare `[:=]` shape: that one would otherwise take the `:<port>` inside the
    # value for the separator and hand back only the port.
    re.compile(r"(?P<pre>^\s*[a-z_]+\s+)(?P<val>[^;]*);\s*$"),
    # ⚠ `.*?` after the separator, matched from the LEFTMOST separator: a value can itself
    # contain `:` or `=` (a dict literal, a `host:port`), and binding to the last one would
    # hand back a fragment of the value instead of the value.
    # ⚠ A trailing `,` is a SEPARATOR, not part of the value — River/HCL and JSON-ish literals
    # write `cluster = "x",`. Swallowing it re-emits the value unquoted and comma-less, which
    # is a syntax error rather than a wrong value, so it is not caught by a value comparison.
    re.compile(r"(?P<pre>[:=]\s*)(?P<val>.*?),?\s*$"),
]

QUOTED_RE = re.compile(r"^(?P<q>[\"'])(?P<inner>.*)(?P=q)$")
# Start of the anchor's own comment introducer, immediately before the marker.
COMMENT_START_RE = re.compile(r"(?:#|//)\s*$")

# Per-key token shapes. A key absent here owns its whole value region, which is the common
# case; listing a shape is how a key says "my value is embedded in a larger one".
#
# ⚠ A shape must match the token EXACTLY, never a prefix of it: `[\w.-]+` on an fqdn line
# would stop at the first component and leave a corrupted name behind. That is why each shape
# below is written to consume its whole token (a full dotted name, a full DN, a full path).
HOSTNAME_SHAPE = r"[*A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+"
# ZFS dataset paths appear bare (the truenas job env) AND under a /mnt prefix (the PV
# `share:`), so the shape is the pool-rooted path without any leading slash.
# A dataset path is the tail of whatever it sits in, bare (the truenas job env) or behind the
# `/mnt/` mountpoint prefix an NFS PV `share:` carries. The prefix is NOT managed — it names
# where the appliance mounts the pool, not the dataset — so the shape refuses to start at a
# leading `/`, which is what keeps a rewrite from eating it.
ZFS_PATH_SHAPE = r"(?:(?<=^)|(?<=/mnt/)|(?<=[\s\"']))[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+$"
# ⚠ QUOTED, and the quotes are outside the capture: inside a dict literal the line carries
# several bare tokens (`"rack_name": FS_HOST`), and an unquoted shape would take the last of
# them rather than the managed value. Every placement value in the tree is quoted or is the
# whole value region, so requiring the quotes costs nothing and removes the ambiguity.
TOKEN_SHAPES = {
    "storage.fileserver.fqdn": HOSTNAME_SHAPE,
    "activeDirectory.adDomain": HOSTNAME_SHAPE,
    "activeDirectory.realm": r"[A-Z0-9_-]+(?:\.[A-Z0-9_-]+)+",
    # A baseDn can be the SUFFIX of a longer DN (bind_cn: CN=…,CN=…,dc=ad,dc=base,dc=internal),
    # so the shape is the dc= chain alone.
    "activeDirectory.baseDn": r"dc=[A-Za-z0-9_-]+(?:,dc=[A-Za-z0-9_-]+)*",
    "storage.fileserver.datasets.homes.dataset": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.shared.parent": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.shared.dataset": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.shared.tmpDataset": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.eda.parent": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.eda.installers": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.eda.moduleFiles": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.eda.builds": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.imageRegistry.dataset": ZFS_PATH_SHAPE,
    "storage.fileserver.datasets.aiModels.dataset": ZFS_PATH_SHAPE,
}


def split_anchor_line(line: str) -> tuple[str, str] | None:
    """(body, tail) — everything left of the anchor comment, and the comment onward."""
    head, sep, _ = line.partition(ANCHOR_MARK)
    if not sep:
        return None
    m = COMMENT_START_RE.search(head)
    if not m:
        return None
    return head[: m.start()], line[m.start():]


# A value region holding a `{` or a `[` is a structure literal, not a scalar.
COMPOSITE_VALUE_RE = re.compile(r"[\{\[]")


def locate_value(line: str, key: str, current: str = "") -> tuple[str, str, int, int] | None:
    """(body, tail, start, end) — the span of the managed token inside the line.

    Returns None when no value position could be found. The caller reports that as an error:
    an anchor that locates nothing is exactly the silent no-op anchors exist to prevent.
    """
    split = split_anchor_line(line)
    if split is None:
        return None
    body, tail = split
    # An anchored line may carry a SECOND, human comment between the value and the anchor
    # (ryax values.yaml: `storageClass: x  # subchart ignores global…  # anchor`). The value
    # region ends at the first comment introducer, not at the anchor.
    region = body
    m_note = re.search(r"\s(?:#|//)\s", body)
    if m_note:
        region = body[: m_note.start()]

    for shape in VALUE_SHAPES:
        m = shape.search(region)
        if not m:
            continue
        start, end = m.start("val"), m.end("val")
        val = m.group("val")
        quoted = QUOTED_RE.match(val)
        if quoted:
            # Operate inside the quotes so they survive.
            start, end = start + 1, end - 1
            val = quoted.group("inner")
        token = TOKEN_SHAPES.get(key)
        if token is None and COMPOSITE_VALUE_RE.search(val):
            # The value region is a STRUCTURE, not a scalar: a dict or list literal whose
            # first separator handed back the whole thing (truenas s3-app-job's
            # `"seaweedfs": {"data_center_name": "unibi-hclab", "rack_name": FS_HOST, …}`).
            # The managed value is then the QUOTED member equal to what is there now — the
            # only unambiguous way to pick it out of several bare tokens on the line.
            token = r"(?<=[\"'])" + re.escape(current) + r"(?=[\"'])"
        if token:
            # Last match, so a `server <fqdn>:<port>;` line takes the name and not the port,
            # and a DN takes its dc= suffix rather than its leading CN=.
            matches = list(re.finditer(token, val))
            if not matches:
                # This separator found a region the key's token is not in; a later, less
                # specific shape may still locate it.
                continue
            last = matches[-1]
            start, end = start + last.start(), start + last.end()
        return body, tail, start, end
    return None


def replace_whole_value(line: str, new: str, key: str) -> str | None:
    """Replace the managed token on an anchored line, preserving quoting and layout.

    `new` doubles as the needle for a composite value region: inside a dict literal the
    managed member is the one already equal to the resolved value, which also makes the
    rewrite a no-op exactly when nothing changed.
    """
    found = locate_value(line, key, new)
    if found is None:
        return None
    body, tail, start, end = found
    return body[:start] + new + body[end:] + tail


def read_whole_value(line: str, key: str, current: str = "") -> str | None:
    """The current managed token — for the post-condition check."""
    found = locate_value(line, key, current)
    if found is None:
        return None
    body, _, start, end = found
    return body[start:end]


# ── embedded rules ────────────────────────────────────────────────────────────────────────
# Four keys rewrite a SUBSTRING of a larger value rather than the value as a whole.

def embed_cluster_hostname(line: str, subdomain: str, base_domain: str) -> str:
    """`{general.subdomain,general.domain}` — the cluster label inside a hostname.

    Rewrites only the `[<old>.]<domain>` portion, so service prefixes and URL paths survive
    (https://gitlab.<tld>/users/auth/…). Works in BOTH directions, which is what makes
    bare-apex mode reversible:
      * the cluster label is OPTIONAL, so an apex hostname gets the label INSERTED, not just
        an `eccNNN` one collapsed;
      * the prefix chain refuses a digit-suffixed label (negative lookahead), so it cannot
        swallow the cluster label and produce `gitlab.ecc196.ecc197.<domain>`;
      * at least ONE service label is required, which leaves the legitimate bare-apex uses
        alone (no-reply@<domain>, external-dns domainFilters, Nextcloud mail_domain, the
        Authentik enrollment whitelist). A hostname that IS the bare TLD therefore does not
        match here — those lines carry general.tld and take the whole-value rule.
      * the lookbehind replaces `\\b` so a leading `*.` can start the match, which `\\b` cannot.
    """
    bd = re.escape(base_domain)
    tail = base_domain if subdomain == "" else f"{subdomain}.{base_domain}"
    line = re.sub(
        r"(?<![A-Za-z0-9.-])((?:(?![A-Za-z-]+[0-9]+\.)[*A-Za-z0-9-]+\.)+)(?:[A-Za-z-]+[0-9]+\.)?" + bd,
        lambda m: m.group(1) + tail,
        line,
    )
    # Mail addresses whose host IS the bare TLD have no service label, so the chain above can
    # never match them. The `@` is the missing prefix: as strong a discriminator as a service
    # label, and it cannot appear inside a hostname. Bidirectional for the same reason.
    return re.sub(r"@(?:[A-Za-z-]+[0-9]+\.)?" + bd, "@" + tail, line)


def embed_s3(line: str, endpoint: str, region: str) -> str:
    """`storage.objectStorage.baseEndpoint` — the S3 host inside an endpoint URL, or the bare
    region token when the line carries no host (the two share one anchor key)."""
    if ".your-objectstorage.com" in line:
        return re.sub(r"[A-Za-z0-9-]+\.your-objectstorage\.com", endpoint, line)
    replaced = replace_whole_value(line, region, "storage.objectStorage.baseEndpoint")
    return replaced if replaced is not None else line


def embed_buckets(line: str, pairs: list[tuple[str, str]]) -> str:
    """`storage.objectStorage.buckets` — several bucket tokens can share one line (the
    `for BUCKET in …` loop). Longest suffix first, with a negative lookahead so a short suffix
    never matches inside a longer one."""
    for suffix, name in pairs:
        line = re.sub(r"[A-Za-z0-9._]+-" + re.escape(suffix) + r"(?![A-Za-z0-9-])", name, line)
    return line


def embed_issuer(line: str, issuer: str) -> str:
    """`tls.certIssuerType` — the letsencrypt-(prod|staging) name inside a cert-manager
    annotation or an issuerRef.name, leaving any surrounding quote untouched."""
    return re.sub(r"letsencrypt-(?:prod|staging)", issuer, line)


# Keys whose rewrite is a substring operation rather than a whole-value replace. The value is
# the handler; `general.subdomain`/`general.domain` share one, since they always co-occur.
EMBEDDED_KEYS = {
    "general.subdomain",
    "general.domain",
    "storage.objectStorage.baseEndpoint",
    "storage.objectStorage.buckets",
    "tls.certIssuerType",
}


# ── corpus ────────────────────────────────────────────────────────────────────────────────
# Candidates come from a handful of fixed-string tree walks (~0.07 s each) rather than a
# 600-entry path list: only the files that carry a marker are opened at all.
#
# scripts/windows carries the end-user helper scripts, which run on a machine with no repo
# checkout and so cannot read project_settings.ts at runtime the way scripts/runtime does.
# Their control-server default is an anchored literal instead. Only the .ps1 can hold it:
# ANCHOR_RE accepts `#` and `//`, not batch `REM`, so the .bat wrappers carry no hostname.
SEARCH_ROOTS = ["deployment", "src/provisioning-scripts", "README.md", "scripts/windows"]


def grep_files(marker: str) -> set[Path]:
    roots = [str(REPO_ROOT / r) for r in SEARCH_ROOTS if (REPO_ROOT / r).exists()]
    out = subprocess.run(
        ["grep", "-rlIF", "--", marker, *roots],
        capture_output=True, text=True,
    )
    # grep exits 1 on "no match", which is not an error here.
    if out.returncode not in (0, 1):
        die(f"grep for {marker!r} failed: {out.stderr.strip()}")
    return {Path(p) for p in out.stdout.split("\n") if p}


class Engine:
    def __init__(self, ps: dict, check_only: bool, verbose: bool):
        self.ps = ps
        self.check_only = check_only
        self.verbose = verbose
        self.resolvers = build_resolvers(ps)
        self.buckets = bucket_rewrites(ps)
        self.seen_keys: set[str] = set()
        self.errors: list[str] = []
        self.changed: list[Path] = []
        # file -> line numbers that would change; --check reports these so the drifted value
        # is pointed at directly rather than leaving a whole file to be searched.
        self.changed_lines: dict[Path, list[int]] = {}
        self.s3_region = self.resolvers["storage.objectStorage.baseEndpoint"].split(".")[0]

    def detail(self, msg: str) -> None:
        if self.verbose:
            print(msg)

    # ── one anchored line ────────────────────────────────────────────────────────────────
    def rewrite_line(self, line: str, where: str) -> str:
        m = ANCHOR_RE.search(line)
        if not m:
            return line
        raw = m.group("list")
        # A field LIST is `{a,b,c}` (braces, mirroring the TS object syntax) — always
        # multi-element, so it contains a comma. A bare single key never uses list braces but
        # MAY carry an index bracket, so strip the braces only when a comma is present.
        if "," in raw:
            raw = raw.strip("{}")
        keys = [k.strip().rstrip(".") for k in raw.split(",")]
        keys = [k for k in keys if k]

        for key in keys:
            if key not in self.resolvers:
                self.errors.append(f"{where}: anchor names unknown project-settings key '{key}'")
                return line
        self.seen_keys.update(keys)

        # Declare-only keys carry provenance for checkSiteAnchors.py; nothing is rewritten.
        declare = [k for k in keys if k.startswith(DECLARE_ONLY_PREFIXES)]
        actionable = [k for k in keys if k not in declare]
        if not actionable:
            return line

        embedded = [k for k in actionable if k in EMBEDDED_KEYS]
        whole = [k for k in actionable if k not in EMBEDDED_KEYS]

        # TRIGGER keys name WHY a line is managed but never drive its value; the key beside
        # them does. Dropping them here is what lets a field list stay descriptive without
        # every extra name competing for the line's single value position.
        #   general.name                  BESIDE a buckets key: the cluster prefix inside a
        #                                 bucket name, which embed_buckets writes. ALONE it is
        #                                 a real target (external-dns txtOwnerId, the Alloy
        #                                 `cluster` label), so it is only dropped when another
        #                                 key on the line can drive the value.
        #   highAvailability.enabled      beside a replicas.<key> it only says the count is
        #                                 HA-driven; ALONE it drives enablePodAntiAffinity
        #   network.subnetRange /
        #   nodes.mesh[].advertiseRoutes  on a policy-cidrs line: block-generated, not patched
        #   tls.certIssuerType            beside a derived tls.* key it names the INPUT those
        #                                 nine switches are computed from, so the line says
        #                                 both where the value comes from and which spelling
        #                                 it takes. ALONE it is the issuer NAME rewrite
        #                                 (issuerRef / cert-manager annotation).
        if len(keys) > 1:
            whole = [k for k in whole if k != "general.name"]
        if len(whole) > 1 and "highAvailability.enabled" in whole:
            whole = [k for k in whole if k != "highAvailability.enabled"]
        if len(whole) > 1 and {"network.subnetRange", "nodes.mesh[].advertiseRoutes"} <= set(whole):
            whole = []
        if len(keys) > 1 and any(k.startswith("tls.") and k != "tls.certIssuerType" for k in keys):
            embedded = [k for k in embedded if k != "tls.certIssuerType"]
        # general.tld carries {general.subdomain,general.domain,general.tld}: the tld token is
        # the discriminator that selects the whole-value rule over the embedded hostname one.
        if "general.tld" in whole:
            embedded = [k for k in embedded if k not in ("general.subdomain", "general.domain")]

        for key in embedded:
            if key in ("general.subdomain", "general.domain"):
                line = embed_cluster_hostname(
                    line, self.resolvers["general.subdomain"], self.resolvers["general.domain"]
                )
            elif key == "storage.objectStorage.baseEndpoint":
                line = embed_s3(line, self.resolvers[key], self.s3_region)
            elif key == "storage.objectStorage.buckets":
                line = embed_buckets(line, self.buckets)
            elif key == "tls.certIssuerType":
                line = embed_issuer(line, self.resolvers[key])

        if len(whole) > 1:
            self.errors.append(
                f"{where}: anchor names {len(whole)} whole-value keys ({', '.join(whole)}); "
                "a line has one value position, so at most one may drive a rewrite"
            )
            return line
        if whole:
            key = whole[0]
            new = replace_whole_value(line, self.resolvers[key], key)
            if new is None:
                self.errors.append(
                    f"{where}: anchor '{key}' found no value position "
                    "(expected `key: value`, `KEY=value`, `- value` or `${VAR:-value}`)"
                )
                return line
            line = new
            # Post-condition: the value on the line must now BE the resolved value. This is
            # what replaces the old deferred tls_rewrite_problems gate.
            got = read_whole_value(line, key, self.resolvers[key])
            if got is not None and got != self.resolvers[key]:
                self.errors.append(
                    f"{where}: anchor '{key}' still reads {got!r}, expected "
                    f"{self.resolvers[key]!r}"
                )
        return line

    # ── one file ─────────────────────────────────────────────────────────────────────────
    def process_file(self, path: Path, extra: list = ()) -> None:
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            return
        original = text

        rel = path.relative_to(REPO_ROOT)
        if ANCHOR_MARK in text:
            lines = text.split("\n")
            for i, line in enumerate(lines):
                if ANCHOR_MARK in line:
                    lines[i] = self.rewrite_line(line, f"{rel}:{i + 1}")
                    if lines[i] != line:
                        self.changed_lines.setdefault(path, []).append(i + 1)
            text = "\n".join(lines)

        for transform in extra:
            text = transform(text, path)

        if text != original:
            self.changed.append(rel)
            if not self.check_only:
                path.write_text(text)


# ── non-anchor rewrites ───────────────────────────────────────────────────────────────────
# A handful of values have no anchor comment because their line shape carries the signal
# itself (a git URL, a `targetRevision:` field). Each is found by its own fixed-string tree
# walk, so these too open only the files that can match.

GIT_URL_RE = re.compile(r"git@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git")
RENOVATE_RE = re.compile(r"(-\s*name:\s*RENOVATE_REPOSITORIES\s*\n\s*value:\s*\")[^\"]+(\")")
# A targetRevision that is a VERSION (v1.2.3 / 1.2), a 40-char commit sha, or HEAD pins an
# upstream chart and must not be touched; anything else is a branch ref for THIS repo.
PINNED_REVISION_RE = re.compile(r"^(?:v?\d+\.\d|[0-9a-f]{40}$|HEAD$)")
TARGET_REVISION_RE = re.compile(r"^(?P<pre>\s*targetRevision:\s*)(?P<q>\"?)(?P<val>[^\s#\"]+)(?P=q)(?P<post>\s*(?:#.*)?)$")


def make_github_transform(repo_url: str, repo_slug: str):
    def transform(text: str, path: Path) -> str:
        if path.name == "README.md":
            # The README stays generic so the repo reads sensibly when reused.
            return GIT_URL_RE.sub("git@github.com:owner/repo.git", text)
        text = GIT_URL_RE.sub(repo_url, text)
        return RENOVATE_RE.sub(lambda m: m.group(1) + repo_slug + m.group(2), text)
    return transform


def make_target_revision_transform(branch: str):
    def transform(text: str, path: Path) -> str:
        out = []
        for line in text.split("\n"):
            m = TARGET_REVISION_RE.match(line)
            if m and not PINNED_REVISION_RE.match(m.group("val")):
                q = m.group("q")
                line = f'{m.group("pre")}{q}{branch}{q}{m.group("post")}'
            out.append(line)
        return "\n".join(out)
    return transform


def make_readme_transform(subdomain: str, base_domain: str):
    """README.md carries no anchors (it is meant to read generically), so its cluster
    hostnames are rewritten by shape. Only digit-suffixed cluster subdomains — a broader
    `word.<base>` pass clobbered generic links like www.<base> and the bare grant-agreement
    URL."""
    tail = base_domain if subdomain == "" else f"{subdomain}.{base_domain}"
    pattern = re.compile(r"\b((?:[*A-Za-z0-9-]+\.)*)[A-Za-z-]+[0-9]+\." + re.escape(base_domain))

    def transform(text: str, path: Path) -> str:
        return pattern.sub(lambda m: m.group(1) + tail, text)
    return transform


def make_authentik_transform(base_domain: str):
    """Self-service enrollment email-domain whitelist = the company email domain."""
    def transform(text: str, path: Path) -> str:
        return re.sub(r'(\.lower\(\) != ")[^"]*(")', lambda m: m.group(1) + base_domain + m.group(2), text)
    return transform


# ── BEGIN/END block generators ────────────────────────────────────────────────────────────
# Two values need whole BLOCKS regenerated rather than per-line patching, because their entry
# COUNT varies and a per-line rewrite can only change values, not add or remove lines.

def make_cpmesh_transform(cp_ips: list[str]):
    """The k3s-api.ts.internal A-record SET in wave8-headscale.yaml — one record per LIVE
    control plane, so the k3s-agent client-LB fails over across them. Count is HA-driven
    (non-HA 1, HA 3)."""
    block = "".join(
        '                  - name: "k3s-api.ts.internal"\n'
        '                    type: "A"\n'
        f'                    value: "{ip}"\n'
        for ip in cp_ips
    )
    pattern = re.compile(
        r"(^[ \t]*\# BEGIN cpMeshIps-records[^\n]*\n).*?(^[ \t]*\# END cpMeshIps-records[^\n]*$)",
        re.S | re.M,
    )

    def transform(text: str, path: Path) -> str:
        return pattern.sub(lambda m: m.group(1) + block + m.group(2), text)
    return transform


def make_storage_scopes_transform(scopes: list[str]):
    """The per-scope RecurringJob group lists in recurring-jobs.yaml — one group entry per
    distinct nodes.mesh[].storageScope.

    Generated rather than hand-kept because a MISSING entry is silent data loss, not an
    error: src/storage.ts sets a recurringJobSelector on every longhorn-<scope> class, and
    Longhorn applies the `default` group ONLY to volumes with no selector. So a scope absent
    from these lists gets zero snapshots and zero backups with nothing to show for it. Three
    scopes had already drifted out this way (unibi-recslab, budapest-emdc, and the ryax pool
    — the last one with live volumes on it).

    Covers scopes from ALL mesh nodes, including `enabled: false` ones. src/storage.ts only
    mints a class for scopes carried by an ENABLED node, so the superset can name a group no
    class references — which is harmless. The converse loses backups."""
    block = "".join(f"    - {scope}\n" for scope in scopes)
    pattern = re.compile(
        r"(^[ \t]*\# BEGIN storage-scopes[^\n]*\n).*?(^[ \t]*\# END storage-scopes[^\n]*$)",
        re.S | re.M,
    )

    def transform(text: str, path: Path) -> str:
        return pattern.sub(lambda m: m.group(1) + block + m.group(2), text)
    return transform


def make_policy_transform(subnet_range: str, lab_subnets: list[str]):
    """The headscale ACL policy CIDRs. The node-fabric and operator grants must name the cloud
    private plane plus EVERY on-prem LAN advertised by a mesh node.

    Getting this wrong PARTITIONS THE CLUSTER — Cilium's VXLAN pod network runs over tailscale,
    so a missing CIDR is not a blocked service but a broken datapath."""
    cidrs = "".join(f', "{c}"' for c in [subnet_range, *lab_subnets])
    smb_dst = ", ".join(f'"{c}"' for c in lab_subnets)
    node_users = '"k3s-cloud@", "on-premise-resident@", "on-premise-transient@"'
    # HuJSON allows `//` line comments, so the anchors are legal inside the policy itself —
    # which is what lets checkHardcodedIps.py tell a derived literal from a hand-typed one.
    anchor = ("// automatically updated from project-settings:"
              "{network.subnetRange,nodes.mesh[].advertiseRoutes}")
    block = f"""        {{
          "src": ["tag:k8s-node", {node_users}],
          "dst": ["tag:k8s-node", {node_users}{cidrs}], {anchor}
          "ip":  ["*"],
        }},

        // ---- Operators: full reach (kubectl on 6443, node SSH, everything). ----
        {{
          "src": ["operator@"],
          "dst": ["tag:k8s-node", "tag:desktop"{cidrs}], {anchor}
          "ip":  ["*"],
        }},

        // ---- Humans: the lab SMB fileserver, reachable only via a mesh subnet route. ----
        // autogroup:member = every untagged (personal) device, NOT a named user: OIDC
        // self-service creates one headscale user PER PERSON, so a "human@" grant would
        // match nobody — silently, since headscale no-ops undefined users in grants.
        {{ "src": ["autogroup:member"], "dst": [{smb_dst}], "ip": ["445"] }}, {anchor}

"""
    pattern = re.compile(
        r"(^[ \t]*// BEGIN policy-cidrs[^\n]*\n).*?(^[ \t]*// END policy-cidrs[^\n]*$)",
        re.S | re.M,
    )

    def transform(text: str, path: Path) -> str:
        return pattern.sub(lambda m: m.group(1) + block + m.group(2), text)
    return transform


# ── base-domain migration ─────────────────────────────────────────────────────────────────
# EVERY rewrite keys on the NEW general.domain, so when the domain itself changes the old one
# has to be swapped out FIRST — otherwise the passes match nothing and the manifests silently
# keep the old domain while Pulumi moves to the new one.
#
# The old value comes from --old-domain, else from the `general.tld` anchor in the tree: that
# line carries the whole previous TLD, and stripping a leading digit-suffixed cluster label
# leaves the previous domain.
TLD_ANCHOR_VALUE_RE = re.compile(
    r"([*A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\s*[\"']?\s*(?:#|//)\s*" + re.escape(ANCHOR_MARK)
)
CLUSTER_LABEL_RE = re.compile(r"^[A-Za-z-]+[0-9]+\.")


def detect_old_domain(files: set[Path]) -> str:
    for path in sorted(files):
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for line in text.split("\n"):
            if "general.tld" not in line or ANCHOR_MARK not in line:
                continue
            m = TLD_ANCHOR_VALUE_RE.search(line)
            if m:
                # Strip a leading cluster label (`ecc196.`); bare-apex mode has none.
                return CLUSTER_LABEL_RE.sub("", m.group(1))
    return ""


def migrate_base_domain(files: set[Path], old: str, new: str) -> None:
    """Only lines whose anchor names general.domain are rewritten — the anchor is what marks a
    domain occurrence as machine-managed. README.md is migrated wholesale: it carries no
    anchors and is meant to read generically."""
    for path in sorted(files):
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        if path.name == "README.md":
            updated = text.replace(old, new)
        else:
            out = []
            for line in text.split("\n"):
                if ANCHOR_MARK in line and re.search(
                    re.escape(ANCHOR_MARK) + r"\S*\bgeneral\.domain\b", line
                ):
                    line = line.replace(old, new)
                out.append(line)
            updated = "\n".join(out)
        if updated != text:
            path.write_text(updated)


# ── AD identity drift ─────────────────────────────────────────────────────────────────────
# activeDirectory.adLabel propagates through three derived anchors (adDomain / realm / baseDn)
# into plaintext manifests, so it cannot drift. netbiosName CANNOT: it reaches Samba only
# through samba-ad/sealSecrets.sh -> domain_settings.primary.short_domain, and that file is
# CIPHERTEXT — there is no plaintext value for an anchor to rewrite.
#
# So editing project_settings.ts without re-running sealSecrets.sh is a SILENT no-op: the DCs
# provision on the OLD identity while every manifest claims the new one, ArgoCD is green, and
# it surfaces much later as a Kerberos/SMB failure that reads like a permissions problem.
#
# Compared against the CLEARTEXT `ecc/sealed-*` annotations sealSecrets.sh stamps onto the
# SealedSecret, so this needs neither the Pulumi stack nor a cluster.
AD_SEALED_FILE = "deployment/argocd-infra/samba-ad/samba-ad-secrets-sealed.yaml"


def check_ad_identity(ps: dict) -> bool:
    """True on drift. Prints the remedy; the caller aborts."""
    path = REPO_ROOT / AD_SEALED_FILE
    ad = ps["activeDirectory"]
    if not path.exists():
        return False

    def annotation(name: str) -> str:
        m = re.search(rf'^\s*ecc/{name}:\s*"?([^"\n]*)"?\s*$', path.read_text(), re.M)
        return m.group(1).strip() if m else ""

    sealed_realm, sealed_short = annotation("sealed-realm"), annotation("sealed-short-domain")
    if not sealed_realm and not sealed_short:
        # A sealed file predating the stamp simply has no annotation — "cannot verify", not
        # drift, so this never fails on an old-but-correct seal.
        print("NOTE: the sealed samba-ad config carries no ecc/sealed-* marker, so its AD",
              file=sys.stderr)
        print("      identity cannot be verified. Re-run deployment/argocd-infra/samba-ad/",
              file=sys.stderr)
        print("      sealSecrets.sh to stamp it (keep the existing password with [k]).",
              file=sys.stderr)
        return False
    if sealed_realm == ad["realm"] and sealed_short == ad["netbiosName"]:
        return False

    for line in (
        "ERROR: the sealed samba-ad config does NOT match project_settings.ts.",
        f'  project_settings.ts : realm={ad["realm"]} short_domain={ad["netbiosName"]}',
        f"  sealed file         : realm={sealed_realm} short_domain={sealed_short}",
        "",
        "  netbiosName is NOT anchored — it reaches Samba only via the sealed config,",
        "  so this WILL NOT fix itself on the next sync. The DCs would provision on the",
        "  sealed identity while every manifest claims the one above, surfacing later as",
        "  a Kerberos/SMB error that looks like a permissions problem.",
        "",
        "  Fix: bash deployment/argocd-infra/samba-ad/sealSecrets.sh   (answer [k] to",
        "  keep the current admin password), then commit the re-sealed file.",
        "  ⚠ The realm is baked into sam.ldb: on an EXISTING domain both DC PVCs must",
        "  be deleted for a realm change to take effect.",
    ):
        print(line, file=sys.stderr)
    return True


# ── main ──────────────────────────────────────────────────────────────────────────────────
# Resolvers that legitimately have no anchor. Each is consumed by something other than a
# manifest literal, so "unreached" is correct rather than a stale rename.
UNANCHORED_OK = {
    # Read by src/*.ts directly (Pulumi components import the settings), never patched into YAML.
    "network.gateway",
    "network.privateRange",
    "network.serviceCidr",
    # Consumed by deployment/argocd-infra/samba-ad/sealSecrets.sh, which produces CIPHERTEXT —
    # there is no plaintext line for an anchor to sit on.
    "network.podCidrNetmask",
    # Trigger-only: named in a field list beside the key that drives the rewrite.
    "storage.objectStorage.buckets",
    # Read by src/*.ts (cert-manager, sealed-secrets components import the settings and call
    # haReplicas()), so these counts never reach a YAML literal.
    "highAvailability.replicas.certManager",
    "highAvailability.replicas.certManagerCainjector",
    "highAvailability.replicas.certManagerWebhook",
    "highAvailability.replicas.sealedSecrets",
    # Label KEYS declared for checkSiteAnchors.py; these two are applied by Pulumi from the
    # settings rather than written into any manifest.
    "applicationPlacements.labels.tier",
    "applicationPlacements.labels.nestedRuntime",
    # Consumed by deployment/argocd-infra/samba-ad/sealSecrets.sh (CIPHERTEXT — no plaintext
    # line to anchor) and by the TrueNAS configure job's own derivation.
    "storage.fileserver.machineAccount",
    "storage.fileserver.pool",
    "storage.fileserver.site",
    # Consumed as the COMPOSED applicationPlacements.meshStorageClass / .ryaxStorageClass,
    # which carry the anchors. The bare scope names reached one literal each — the
    # recurring-jobs.yaml group lists — and those are now generated as a BEGIN/END block
    # from the full storageScope set instead (make_storage_scopes_transform).
    "applicationPlacements.meshStorageScope",
    "applicationPlacements.ryaxStorageScope",
}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Rewrite machine-managed literals in deployment manifests from project_settings.ts."
    )
    ap.add_argument("--settings-json", type=Path,
                    help="pre-made JSON dump of project_settings (default: evaluate "
                         "project_settings.ts directly)")
    ap.add_argument("--old-domain", default="",
                    help="the base domain the FILES currently carry, when general.domain itself "
                         "has just changed (auto-detected from the general.tld anchor otherwise)")
    ap.add_argument("--check", action="store_true",
                    help="write nothing; exit non-zero if any file would change")
    ap.add_argument("--verbose", action="store_true",
                    help="print every resolved value (the PHASE_VERBOSE detail level)")
    args = ap.parse_args()

    ps = (json.loads(args.settings_json.read_text()) if args.settings_json
          else load_settings(REPO_ROOT / "project_settings.ts"))

    g, tls = ps["general"], ps["tls"]
    if tls["certIssuerType"] not in ("letsencrypt-prod", "letsencrypt-staging"):
        die(f'Unsupported certIssuerType {tls["certIssuerType"]!r} in project settings.')

    repo_url = ps["argocd"]["git"]["repoUrl"]
    m = re.fullmatch(r"git@github\.com:([^/\s]+/\S+)\.git", repo_url)
    if not m:
        die(f"Unsupported github.repoUrl {repo_url!r} (expected git@github.com:owner/repo.git).")
    repo_slug = m.group(1)

    # Bare-apex mode reuses ONE SAN set for every cluster: Let's Encrypt allows 5 issuances of
    # an identical SAN set per 7 days, and a per-cluster subdomain is what normally gives each
    # recreate a fresh one.
    if not g["subdomain"] and tls["certIssuerType"] == "letsencrypt-prod":
        for line in (
            "",
            "WARNING: bare-apex mode (empty general.subdomain) with letsencrypt-prod.",
            f'         Every recreate re-requests the SAME SAN set (*.{g["domain"]}), so only 5',
            "         issuances per 7 days are possible — a recreate cadence above that gets NO",
            "         production certificates. Use a per-cluster subdomain while recreating, or",
            "         letsencrypt-staging for tests.",
            "",
        ):
            print(line, file=sys.stderr)

    engine = Engine(ps, check_only=args.check, verbose=args.verbose)
    print(f'Deriving config: targetState={g["targetState"]} tld={g["tld"]} '
          f'issuer={tls["certIssuerType"]}')
    engine.detail(f"  GitHub repo URL: {repo_url}")
    engine.detail(f"  Renovate repo slug: {repo_slug}")
    for key in sorted(engine.resolvers):
        engine.detail(f"  {key} = {engine.resolvers[key]!r}")

    anchored = grep_files(ANCHOR_MARK)

    # Base-domain migration runs BEFORE everything else and writes directly: every rewrite
    # below keys on the NEW domain, so the old one must already be gone.
    old_domain = args.old_domain or detect_old_domain(anchored)
    migrated = ""
    if old_domain and old_domain != g["domain"]:
        source = "--old-domain" if args.old_domain else "general.tld anchor"
        print(f'Base domain change: {old_domain!r} -> {g["domain"]!r} (old value from {source})')
        if not args.check:
            migrate_base_domain(anchored, old_domain, g["domain"])
        migrated = old_domain

    # Per-file extra transforms, keyed by the file they apply to. A file not named here is
    # still processed for its anchors.
    branch = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip()

    github_files = grep_files("git@github.com") | grep_files("RENOVATE_REPOSITORIES")
    revision_files = grep_files("targetRevision:")
    github_transform = make_github_transform(repo_url, repo_slug)
    revision_transform = make_target_revision_transform(branch) if branch and branch != "HEAD" else None
    if revision_transform is None:
        print("Could not determine current branch; skipping targetRevision update.")

    mesh_nodes = [n for n in ps["nodes"]["mesh"] if n.get("enabled", True)]
    # Deliberately NOT mesh_nodes: a disabled node's scope still needs a backup group, so the
    # group list survives that node being re-enabled. See make_storage_scopes_transform.
    storage_scopes: list[str] = []
    for n in ps["nodes"]["mesh"]:
        for scope in n.get("storageScope") or []:
            if scope not in storage_scopes:
                storage_scopes.append(scope)

    lab_subnets: list[str] = []
    for n in mesh_nodes:
        for route in n.get("advertiseRoutes") or []:
            if route not in lab_subnets:
                lab_subnets.append(route)

    special = {
        REPO_ROOT / "README.md": [make_readme_transform(g["subdomain"], g["domain"])],
        REPO_ROOT / "deployment/argocd-infra/authentik/blueprint-enrollment.yaml":
            [make_authentik_transform(g["domain"])],
        REPO_ROOT / "deployment/argocd-infra/app-of-apps/wave8-headscale.yaml":
            [make_cpmesh_transform(ps["network"]["cpMeshIps"])],
        REPO_ROOT / "deployment/argocd-infra/headscale/policy-configmap.yaml":
            [make_policy_transform(ps["network"]["subnetRange"], lab_subnets)],
        REPO_ROOT / "deployment/argocd-infra/longhorn-system/recurring-jobs.yaml":
            [make_storage_scopes_transform(storage_scopes)],
    }

    candidates = anchored | github_files | revision_files | set(special)
    for path in sorted(candidates):
        if not path.exists():
            continue
        extra = list(special.get(path, []))
        if path in github_files:
            extra.append(github_transform)
        if revision_transform and path in revision_files:
            extra.append(revision_transform)
        engine.process_file(path, extra)

    # ── orphan guards, both directions ───────────────────────────────────────────────────
    # An anchor naming an unknown key is already collected in engine.errors by rewrite_line.
    unreached = sorted(set(engine.resolvers) - engine.seen_keys - UNANCHORED_OK)
    for key in unreached:
        engine.errors.append(
            f"resolver '{key}' is reached by no anchor — it was renamed, or its last anchor "
            "was deleted (add it to UNANCHORED_OK if that is deliberate)"
        )

    if engine.errors:
        print("ERROR: anchor problems:", file=sys.stderr)
        for problem in engine.errors:
            print(f"  {problem}", file=sys.stderr)
        return 1

    if args.check:
        if engine.changed:
            print("ERROR: these files have drifted from project_settings.ts:", file=sys.stderr)
            for path in engine.changed:
                lines = engine.changed_lines.get(REPO_ROOT / path)
                where = f" (line {', '.join(map(str, lines))})" if lines else ""
                print(f"  {path}{where}", file=sys.stderr)
            print("Run scripts/environment/updateConfigFromProjectSettings.sh.", file=sys.stderr)
            return 1
        print("Check mode: every managed value matches project_settings.ts.")
        return 0

    if check_ad_identity(ps):
        # NON-RECOVERABLE-BY-SYNC, so fail rather than print and exit 0. Everything above has
        # already been written — the manifests are correct; what is missing is the re-seal, and
        # a warning buried in a long log is exactly how this gets missed.
        print("", file=sys.stderr)
        print("ABORTING: AD identity drift (see the ERROR above). Manifests were updated;",
              file=sys.stderr)
        print("re-seal the samba-ad config, then re-run this script.", file=sys.stderr)
        return 1

    # After every pass, anything still on the old domain is NOT machine-managed — no anchor
    # names it — and needs a human. Reported, not fatal: a comment or a doc line mentioning the
    # old domain is legitimate.
    if migrated:
        found = subprocess.run(
            ["grep", "-rIlF", "--", migrated, "deployment", "src", "README.md"],
            cwd=REPO_ROOT, capture_output=True, text=True,
        ).stdout.split()
        if found:
            print(f"NOTE: {migrated!r} still appears in these files:", file=sys.stderr)
            for path in found:
                print(f"  {path}", file=sys.stderr)
            if ps["mail"]["senderEmail"].endswith("@" + migrated):
                print(f'      mail.senderEmail is still {ps["mail"]["senderEmail"]!r} — it is a '
                      "setting of its own,", file=sys.stderr)
                print("      so the domain change did not move it. Edit it in "
                      "project_settings.ts and", file=sys.stderr)
                print("      re-run if the address moved with the domain.", file=sys.stderr)
        else:
            print(f"Base domain migration complete: no occurrence of {migrated!r} left in "
                  "deployment/, src/ or README.md.")

    print(f'Applied cert issuer {tls["certIssuerType"]!r}, TLD {g["tld"]!r}, '
          f"GitHub repo URL {repo_url!r}")
    print(f"Changed files: {len(engine.changed)}")
    for path in engine.changed:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
