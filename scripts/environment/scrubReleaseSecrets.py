#!/usr/bin/env python3
"""
Project: edgecloudinfra
File: scripts/environment/scrubReleaseSecrets.py
Purpose: Empty every secret VALUE in a release build, keeping the files' shape.

Author: Martin Kaiser
Copyright (c) 2026 Martin Kaiser
License: MIT
SPDX-License-Identifier: MIT
"""

# Called by prepareRelease.sh against the shadow tree ONLY — it rewrites files in place and
# must never be pointed at the source repo (it refuses; see main()).
#
# Values are emptied rather than the files deleted: a SealedSecret and a Pulumi stack config
# are both instructive as SHAPES, and a reader of a public infra repo needs to see what they
# look like. What must not survive is the material.
#
# ⚠ Every scrub here COUNTS what it changed and the caller's gate re-checks the result. A
# scrub that silently matches nothing is the exact defect this release path was rewritten
# around (removeAllSealedSecrets.sh reported success having removed nothing for 14 apps).

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# SealedSecret ciphertext: `  <key>: AgA…` under encryptedData. The value is base64 and always
# starts "AgA" (the sealed-secrets envelope marker).
SEALED_VALUE_RE = re.compile(r'^(\s+[A-Za-z0-9._-]+:\s*)(AgA[A-Za-z0-9+/=]+)\s*$', re.M)
# Pulumi stack secret: `    secure: v1:…`
PULUMI_SECURE_RE = re.compile(r'^(\s*secure:\s*)(v1:\S+)\s*$', re.M)
# The salt is not a secret by itself, but it is stack-specific noise with no meaning to a
# reader and it pairs with the ciphertext above.
PULUMI_SALT_RE = re.compile(r'^(encryptionsalt:\s*)(\S+)\s*$', re.M)


def scrub_sealed(root: Path) -> tuple[int, int]:
    """Empty every encryptedData value. Returns (files, values)."""
    files = values = 0
    for path in sorted(root.rglob("*-sealed.yaml")):
        text = path.read_text()
        new, n = SEALED_VALUE_RE.subn(lambda m: m.group(1) + '""', text)
        if n:
            path.write_text(new)
            files += 1
            values += n
    return files, values


def scrub_pulumi(root: Path) -> int:
    """Empty every `secure:` value in the stack config. Returns values changed."""
    path = root / "Pulumi.mystack.yaml"
    if not path.exists():
        return 0
    text = path.read_text()
    text, n = PULUMI_SECURE_RE.subn(lambda m: m.group(1) + '""', text)
    text = PULUMI_SALT_RE.sub(lambda m: m.group(1) + '""', text)
    path.write_text(text)
    return n


def main() -> int:
    ap = argparse.ArgumentParser(description="Empty secret values in a release build.")
    ap.add_argument("--root", type=Path, required=True, help="the release build directory")
    args = ap.parse_args()

    root = args.root.resolve()
    if not root.is_dir():
        sys.exit(f"ERROR: not a directory: {root}")
    # Refuse to run against a real checkout: this rewrites files in place, and pointed at the
    # source repo it would destroy every sealed secret and the Pulumi stack.
    if (root / ".git").is_dir() and (root / ".git" / "refs" / "remotes").is_dir():
        sys.exit(f"ERROR: {root} looks like a real checkout (it has remotes). "
                 "This scrubs files IN PLACE and is only for a release build.")

    sealed_files, sealed_values = scrub_sealed(root)
    pulumi_values = scrub_pulumi(root)

    # Report counts, never a bare "done": the caller's gate re-checks, but a zero here when
    # files exist is worth seeing immediately.
    print(f"scrubbed {sealed_values} sealed value(s) across {sealed_files} file(s); "
          f"{pulumi_values} Pulumi stack secret(s)")

    remaining = sum(1 for p in root.rglob("*-sealed.yaml")
                    if SEALED_VALUE_RE.search(p.read_text()))
    if remaining:
        sys.exit(f"ERROR: {remaining} sealed file(s) still carry ciphertext after the scrub.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
