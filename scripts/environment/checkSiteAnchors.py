#!/usr/bin/env python3
"""Fail on site / storage-scope / ecc-label literals that are not derived from project_settings.ts.

WHY THIS EXISTS
---------------
Placement values (which site a pod runs at, which Longhorn scope its volume lives on, which
`ecc/*` label it selects on) are declared once in project_settings.applicationPlacements and
pushed into YAML/shell by scripts/environment/updateConfigFromProjectSettings.sh, which
rewrites the value on every line carrying

    # automatically updated from project-settings:applicationPlacements.<key>

An unanchored literal is invisible to that pass. It keeps working until a site is renamed or an
app moves, then drifts silently: a stale `ecc/site` leaves pods Pending with "untolerated
taint(s)" (the selector, not the taint, being the real cause), and a stale
`storageClass: longhorn-<scope>` binds a PVC to a class that no longer exists.

⚠ MATCHES ON SHAPE, NOT ON A FIXED STRING. A checker keyed to "unibi-hclab" would find nothing
the moment the site is renamed — and the new name would then be unanchored everywhere, which is
exactly when the guard is needed. The legal site / scope / label sets are read out of
project_settings.ts on every run, so a renamed site is still policed.

Usage:  python3 scripts/environment/checkSiteAnchors.py [--warn-only]
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
SETTINGS = REPO / "project_settings.ts"

SCAN = [
    ("deployment", ("*.yaml", "*.yml", "*.sh")),
    ("src/provisioning-scripts", ("*.sh",)),
]

ANCHOR = "automatically updated from project-settings:"

# Same contract as checkHardcodedIps.py: a BEGIN/END pair whose body the update script
# regenerates wholesale, so it cannot drift but also carries no per-line anchor.
BLOCK_BEGIN = re.compile(r"BEGIN\s+(\S+)\s+\(auto-generated from project-settings:")

# StorageClasses minted as literals in src/storage.ts rather than composed from a storageScope,
# so they do not move when a scope is renamed.
ALLOWED_EXACT = {"longhorn", "longhorn-cloud", "longhorn-cloud-db", "longhorn-static"}

# Sites and scopes that name something OTHER than the applicationPlacements defaults, so
# there is no anchor for them to carry. Each is a deliberate choice, not a copy of the
# default that drifted.
#
# ⚠ These are still policed by validatePlacementDefaults only insofar as they exist as
# node properties; nothing checks that a manifest naming one is still correct. Prefer an
# anchor wherever the value IS the default.
ALLOWED_CONTEXT = {
    # The CROSS-LAN scope: unibi-hclab + unibi-recslab. windows deliberately replicates
    # across both LANs rather than staying local, so it is not meshStorageScope.
    "longhorn-unibi",
    # Per-site Ryax worker overrides (ryax/worker-values.<site>.yaml). Each file EXISTS to
    # name a site other than the default, so there is no anchor it could carry: an anchored
    # value would resolve to meshStorageScope and defeat the file. The file name states
    # which site it is for, and manageWorker.sh refuses a non-default site whose file is
    # missing, so a wrong value here cannot pass silently.
    "longhorn-budapest-emdc",
    "longhorn-home-martin",
    # The RYAX-ONLY storage scope. It is deliberately NARROWER than meshStorageScope
    # (`unibi-hclab`): that tag is also carried by unibi-hclab-fs-vm, a 57.7 G disk whose
    # DiskPressure took Guacamole's database down for ~4h on 2026-09-15, so Ryax — the
    # largest tenant of it — gets its own tag that fs-vm is kept out of. An anchored value
    # would resolve to meshStorageScope and re-admit exactly the node this scope exists to
    # exclude. manageWorker.sh reads the tag off the live Longhorn node to decide whether a
    # Ryax pool may be created there, so a wrong value fails closed (no node matches, every
    # registration is refused) rather than silently placing action data on the small disk.
    "unibi-ryax",
}

# Files whose placement literal cannot carry a comment. Each needs a different guarantee
# instead — see the reason.
EXEMPT = {
    # CEL inside a YAML folded block scalar (`expression: >-`). A `#` there is not a comment:
    # it becomes part of the CEL string and the policy fails to compile. Covered by the
    # applicationPlacements drift check at the end of updateConfigFromProjectSettings.sh.
    "deployment/argocd-apps/cape-demo/ryax/admission-policies.yaml",
    # The label lines here are inside a `cat > /etc/rancher/k3s/config.yaml << KCONFIG`
    # heredoc, so a trailing `#` is not a comment on this script — it is written verbatim
    # into the generated k3s config. src/nodes-k3s-mesh.ts labels the same node from
    # applicationPlacements after the join, so the values are reconciled there anyway.
    "src/provisioning-scripts/40-join-cluster.sh",
}


def _settings_text() -> str:
    return SETTINGS.read_text(encoding="utf-8", errors="replace")


def known_sites_and_scopes(text: str) -> tuple[set[str], set[str]]:
    """Every site and storageScope named on any node, enabled or not.

    Disabled nodes count here on purpose: this guard is about whether a literal is DERIVED,
    not about whether it currently schedules. validatePlacementDefaults in
    project_settings_types.ts enforces the latter.
    """
    sites = set(re.findall(r'^\s*site:\s*"([^"]+)"', text, re.M))
    scopes: set[str] = set()
    for block in re.findall(r"storageScope:\s*\[([^\]]*)\]", text):
        scopes.update(re.findall(r'"([^"]+)"', block))
    return sites, scopes


def known_node_ids(text: str) -> set[str]:
    """Node ids, which are NOT site references even though they start with the site name.

    `unibi-hclab-pcie-tb-d` is a kubernetes node name; renaming a site does not rename an
    existing node, because the id is baked into the k3s registration and the Longhorn node
    object. Recognised by exact membership rather than by an `-<suffix>` heuristic, which
    would also swallow `longhorn-unibi-hclab`.
    """
    return set(re.findall(r'^\s*id:\s*"([^"]+)"', text, re.M))


def known_labels(text: str) -> set[str]:
    """The ecc/* keys declared in applicationPlacements.labels.

    Keys NOT in the block (ecc/description, ecc/provision-fingerprint, ecc/hardware) are node
    metadata Pulumi alone reads and writes, and ecc/volume / ecc/seed are deployment-only
    conventions on PVs and Authentik blueprints. None is part of the placement vocabulary, so
    none is policed here.
    """
    block = re.search(r"labels:\s*\{(.*?)\n\s{8}\}", text, re.S)
    return set(re.findall(r'"(ecc/[a-z-]+)"', block.group(1))) if block else set()


def main() -> int:
    warn_only = "--warn-only" in sys.argv
    text = _settings_text()
    sites, scopes = known_sites_and_scopes(text)
    node_ids = known_node_ids(text)
    labels = known_labels(text)

    # A placement literal is a bare site/scope name, or `longhorn-<scope>`. Built from the
    # settings so a rename keeps it accurate.
    values = {v for v in sites | scopes if v} | {f"longhorn-{s}" for s in scopes if s}
    if not values or not labels:
        print("site-anchor check: could not read applicationPlacements from project_settings.ts")
        return 0 if warn_only else 1
    token_re = re.compile(
        r"(?<![\w./-])(" + "|".join(sorted(map(re.escape, values | labels), key=len, reverse=True)) + r")(?![\w-])"
    )

    findings = []
    for rel, globs in SCAN:
        root = REPO / rel
        if not root.is_dir():
            continue
        for pattern in globs:
            for path in sorted(root.rglob(pattern)):
                if str(path.relative_to(REPO)) in EXEMPT:
                    continue
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
                    for m in token_re.finditer(code):
                        token = m.group(1)
                        if token in ALLOWED_EXACT or token in ALLOWED_CONTEXT or token in node_ids:
                            continue
                        findings.append((path.relative_to(REPO), n, token, line.strip()[:90]))

    if not findings:
        print("site-anchor check: OK — every placement literal is anchored or explicitly allowed.")
        return 0

    print(f"site-anchor check: {len(findings)} unanchored placement literal(s) found:\n")
    for path, n, token, text_ in findings:
        print(f"  {path}:{n}: {token}")
        print(f"      {text_}")
    print(
        "\nEach must either:\n"
        "  1. carry '# automatically updated from project-settings:applicationPlacements.<key>'\n"
        "     (meshSite | meshStorageScope | meshStorageClass | cloudSite | labels.<name>), or\n"
        "  2. be added to ALLOWED_EXACT or EXEMPT in this script WITH a justification, if the\n"
        "     literal genuinely cannot be derived or cannot carry a comment.\n"
    )
    return 0 if warn_only else 1


if __name__ == "__main__":
    sys.exit(main())
