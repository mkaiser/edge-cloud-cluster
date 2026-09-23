#!/usr/bin/env python3
"""Fail on IP addresses that are neither derived from project_settings.ts nor deliberately fixed.

WHY THIS EXISTS
---------------
Network values (pod/service CIDRs, the mesh range, the kube-vip VIP, ...) are declared once
in project_settings.ts and pushed into YAML/shell by
scripts/environment/updateConfigFromProjectSettings.sh, which rewrites the value on every
line carrying

    # automatically updated from project-settings:network.<key>

An unanchored literal is invisible to that pass: it keeps working until a range changes, then
drifts silently. Two concrete instances this guard would have caught -- CLOUD_SUBNETS in
samba-ad (three ranges in one string; a wrong subnet-to-site mapping degrades AD replication
without erroring) and POD_CIDR in 30-join-cluster.sh (the pod->apiserver SNAT).

Literals that are genuinely constant (RFC1918 supernets in a deny-list, loopback, MagicDNS)
are allowed via ALLOWED below. Anything else must be anchored, so the default answer to a new
hardcoded address is "add it to project_settings.ts", not "add it here".

Usage:  python3 scripts/environment/checkHardcodedIps.py [--warn-only]
"""

import ipaddress
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]

SCAN = [
    ("deployment", ("*.yaml", "*.yml", "*.sh")),
    ("src/provisioning-scripts", ("*.sh",)),
]

ANCHOR = "automatically updated from project-settings:"

# The other half of updateConfigFromProjectSettings.sh's contract: a BEGIN/END marker pair
# whose body it regenerates WHOLESALE (record counts vary with the settings, so there is no
# stable line to hang a per-line anchor on). The body is generated, hence never drift — but
# it also carries no ANCHOR, so it has to be recognised by its markers instead.
BLOCK_BEGIN = re.compile(r"BEGIN\s+(\S+)\s+\(auto-generated from project-settings:")

# Literals that are fixed by an external standard or protocol, not by our topology, so they
# cannot drift with project_settings.ts. Keep this list short and justified.
ALLOWED_EXACT = {
    "0.0.0.0",  # bind-all
    "127.0.0.1",  # loopback
    "127.0.0.2",  # loopback, second address: the node-local dnsmasq (127.0.0.1:53 is Samba's)
    "127.0.1.1",  # Debian/Ubuntu convention for a machine's OWN hostname in /etc/hosts
    "127.0.0.53",  # systemd-resolved stub
    "127.0.0.54",  # systemd-resolved stub (delegate)
    "100.100.100.100",  # tailscale MagicDNS
    "1.1.1.1",  # public resolver
    "8.8.8.8",  # public resolver
    "9.9.9.9",  # public resolver
}
ALLOWED_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),  # RFC1918 supernet (deny-lists, not our ranges)
    ipaddress.ip_network("172.16.0.0/12"),  # RFC1918 supernet
    ipaddress.ip_network("192.168.0.0/16"),  # RFC1918 supernet
    ipaddress.ip_network("169.254.0.0/16"),  # link-local / cloud metadata
    ipaddress.ip_network("100.64.0.0/10"),  # CGNAT (tailscale overlay)
    ipaddress.ip_network("224.0.0.0/4"),  # multicast
]

IP_RE = re.compile(r"\b(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(/\d{1,2})?(?![\w.])")


def is_netmask(addr: str) -> bool:
    """True for a contiguous netmask literal (255.255.255.0), which is not an address.

    Samba's `interfaces` takes ADDRESS/NETMASK rather than a prefix length, so a bare mask
    appears alongside a placeholder (__MESH_IP__/255.255.255.0). The mask follows from the
    prefix length, not from our topology, so it cannot drift on its own.
    """
    try:
        packed = int(ipaddress.ip_address(addr))
    except ValueError:
        return False
    inverted = packed ^ 0xFFFFFFFF
    return ((inverted + 1) & inverted) == 0  # contiguous high bits


def allowed(token: str) -> bool:
    """True if this literal is a fixed constant rather than one of our topology values."""
    addr, _, prefix = token.partition("/")
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return True  # not an IP (version string like 26.04.2.1.1)
    if addr in ALLOWED_EXACT:
        return True
    if not prefix and is_netmask(addr):
        return True
    # A bare supernet (10.0.0.0/8) is a deny-list entry; a subnet of it (10.42.0.0/16) is ours.
    if prefix:
        try:
            net = ipaddress.ip_network(token, strict=False)
        except ValueError:
            return True
        return any(net == a for a in ALLOWED_NETS)
    # Bare (prefixless) form: only the NETWORK address of an allow-listed supernet is a
    # constant — "10.0.0.0" names the RFC1918 block, "10.0.10.1" is a host in OUR mesh range
    # and drifts with it. Membership alone would have exempted every 10./172.16./192.168.
    # host literal in the repo, i.e. most of the topology this guard exists to anchor.
    return any(ip == a.network_address for a in ALLOWED_NETS)


def main() -> int:
    warn_only = "--warn-only" in sys.argv
    findings = []

    for rel, globs in SCAN:
        root = REPO / rel
        if not root.is_dir():
            continue
        for pattern in globs:
            for path in sorted(root.rglob(pattern)):
                try:
                    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
                except OSError:
                    continue
                in_docstring = False
                in_block: str | None = None
                for n, line in enumerate(lines, 1):
                    stripped = line.lstrip()
                    if in_block is not None:
                        if f"END {in_block}" in line:
                            in_block = None
                        continue  # generated wholesale — cannot drift
                    begin = BLOCK_BEGIN.search(line)
                    if begin:
                        in_block = begin.group(1)
                        continue
                    # A Python docstring is prose exactly like a `#` comment, but its body
                    # lines carry no comment marker. Both the embedded python in these YAML
                    # Jobs and the python heredocs in the shell scripts document real
                    # addresses in theirs, so without this every such mention is a finding.
                    was_in_docstring = in_docstring
                    if stripped.count('"""') % 2 or stripped.count("'''") % 2:
                        in_docstring = not in_docstring
                    if in_docstring or was_in_docstring:
                        continue
                    if stripped.startswith("#") or stripped.startswith("//"):
                        continue  # prose, not config
                    if ANCHOR in line:
                        continue  # managed by updateConfigFromProjectSettings.sh
                    code = line.split("#", 1)[0]
                    for m in IP_RE.finditer(code):
                        token = m.group(1) + (m.group(2) or "")
                        if allowed(token):
                            continue
                        findings.append((path.relative_to(REPO), n, token, line.strip()[:90]))

    if not findings:
        print("hardcoded-ip check: OK — every topology IP is anchored or explicitly allowed.")
        return 0

    print(f"hardcoded-ip check: {len(findings)} unanchored literal(s) found:\n")
    for path, n, token, text in findings:
        print(f"  {path}:{n}: {token}")
        print(f"      {text}")
    print(
        "\nEach must either:\n"
        "  1. carry '# automatically updated from project-settings:network.<key>' and have that\n"
        "     key exported in scripts/environment/updateConfigFromProjectSettings.sh, or\n"
        "  2. be added to ALLOWED_* in this script WITH a justification, if it is a fixed\n"
        "     external constant rather than part of our topology.\n"
    )
    return 0 if warn_only else 1


if __name__ == "__main__":
    sys.exit(main())
