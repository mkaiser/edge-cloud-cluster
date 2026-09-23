#!/usr/bin/env python3
"""Fail on cluster hostnames that carry no project-settings anchor.

WHY THIS EXISTS
---------------
The cluster's TLD comes from project_settings.ts and is pushed into YAML/shell by
scripts/environment/updateConfigFromProjectSettings.sh, which rewrites the hostname on every
line carrying

    # automatically updated from project-settings:{general.subdomain,general.domain}

That anchor is not decoration: it is the only thing that says "this hostname belongs to the
cluster". Both TLD shapes are supported -- `<subdomain>.<domain>` and, with an empty
general.subdomain, the bare apex `<domain>` -- and from the apex a regex can no longer tell a
cluster hostname (gitlab.<domain>) from a foreign one (www.<domain>) or from a mail address
(no-reply@<domain>). Only the anchor can. An unanchored cluster hostname is therefore a
one-way door: it collapses to the apex on the way down and never comes back.

Anything matching `<label>.[<cluster-label>.]<general.domain>` must carry the anchor. The
answer to a new hostname is "anchor it", not "add it here" -- see EXEMPT for the single
justified exception.

Usage:  python3 scripts/environment/checkDomainAnchors.py [--warn-only]
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]

# The files updateConfigFromProjectSettings.sh rewrites (deployment_files + the shell half of
# anchor_files). Markdown is deliberately absent: doc prose uses illustrative TLDs.
# .ps1 only under scripts/windows: a .bat cannot carry an anchor the engine understands
# (ANCHOR_RE takes `#` and `//`, not `REM`), so scanning .bat would demand an anchor that
# cannot work. The .bat wrappers therefore hold no hostname at all.
SCAN = [
    ("deployment", ("*.yaml", "*.yml", "*.yaml.template", "*.yml.template", "*.disable", "*.sh")),
    ("src/provisioning-scripts", ("*.sh",)),
    ("scripts/windows", ("*.ps1",)),
]

ANCHOR = "automatically updated from project-settings:"

# Paths whose <domain> occurrences are PATTERNS, not configuration. Empty today: the one
# former entry (remote-desktop/check-image-invariants.sh) now reads general.domain from
# project_settings.ts instead of carrying a literal.
EXEMPT: set[str] = set()


def base_domain() -> str:
    """general.domain from project_settings.ts (the `general` block's first `domain:`)."""
    text = (REPO / "project_settings.ts").read_text()
    general = text.split("general:", 1)[1]
    m = re.search(r'^\s*domain:\s*"([^"]+)"', general, re.M)
    if not m:
        sys.exit("checkDomainAnchors: could not read general.domain from project_settings.ts")
    return m.group(1)


def main() -> int:
    warn_only = "--warn-only" in sys.argv[1:]
    domain = base_domain()
    # One or more service labels, then an OPTIONAL digit-suffixed cluster label, then the base
    # domain. Requiring a service label is what leaves the legitimate bare-apex uses alone:
    # no-reply@<domain>, external-dns domainFilters, Nextcloud mail_domain, the Authentik
    # enrollment whitelist. The lookbehind (rather than \b) lets a leading `*.` start a match.
    host = re.compile(
        r"(?<![A-Za-z0-9.-])(?:[*A-Za-z0-9-]+\.)+(?:[A-Za-z-]+[0-9]+\.)?" + re.escape(domain)
    )

    findings = []
    for base, globs in SCAN:
        for pattern in globs:
            for path in sorted((REPO / base).rglob(pattern)):
                rel = path.relative_to(REPO).as_posix()
                if rel in EXEMPT:
                    continue
                for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                    if ANCHOR in line:
                        continue
                    m = host.search(line)
                    if m:
                        findings.append((rel, lineno, m.group(0), line.strip()))

    if not findings:
        print(f"domain anchor check: OK — every cluster hostname under {domain} is anchored.")
        return 0

    print(f"Unanchored cluster hostnames under {domain}:\n")
    for rel, lineno, hostname, line in findings:
        print(f"  {rel}:{lineno}  {hostname}")
        print(f"      {line[:140]}")
    print(
        "\nAppend to each line:\n"
        "  # automatically updated from project-settings:{general.subdomain,general.domain}\n"
        "A hostname that IS the bare TLD (no service prefix) uses\n"
        "  # automatically updated from project-settings:{general.subdomain,general.domain,general.tld}\n"
        "and a bare base domain with no cluster label at all uses the single-key form\n"
        "  # automatically updated from project-settings:general.domain\n"
        "Where the line cannot carry a comment (prose, a template body, mid-f-string), hoist the\n"
        "TLD into one anchored variable and interpolate it."
    )
    return 0 if warn_only else 1


if __name__ == "__main__":
    sys.exit(main())
