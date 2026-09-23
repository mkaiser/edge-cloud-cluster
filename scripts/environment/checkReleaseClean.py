#!/usr/bin/env python3
"""Fail on anything in a release build that must not be published.

WHY THIS EXISTS

`prepareRelease.sh` produces a public copy of this repo: secret values scrubbed, the cluster's
identity swapped for placeholders. Every one of those steps is a substitution, and a
substitution that matches nothing does not fail — it silently leaves the real value in place.
That is not hypothetical: the release path's own sealed-secret strip reported "All sealed
secrets removed" while removing NOTHING for 14 apps, because it delegated to per-app remover
scripts that did not exist (measured 2026-09-14).

So the release does not get to CLAIM it is clean. This scanner is the gate that proves it, and
a pass prints what it actually checked rather than a reassuring sentence.

Two rule kinds, both from scripts/environment/release-denylist.txt:
  content  a regex matched against every line of every text file
  path     a regex matched against the path, so a file that must never ship fails even if a
           scrub emptied its contents

Usage:
  python3 scripts/environment/checkReleaseClean.py --root release/build
  python3 scripts/environment/checkReleaseClean.py --self-test    # see below
  python3 scripts/environment/checkReleaseClean.py --root X --warn-only

⚠ --self-test is not optional in practice. It runs the denylist against the UN-anonymized
source repo and asserts every rule matches something. A rule with a typo matches nothing,
passes the gate, and leaks — the same silent-no-op this file exists to prevent, one level up.
Run it whenever the denylist changes.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DENYLIST = REPO_ROOT / "scripts/environment/release-denylist.txt"

# Per-rule cap on reported hits: one over-broad rule should not bury the other findings.
MAX_HITS_PER_RULE = 20

# Rules marked `#self-test-exempt` in the denylist: they cannot match the source tree by
# construction (e.g. `.git/`, which git never tracks) but still guard a release build.
SELF_TEST_EXEMPT: set[str] = set()


def parse_denylist(path: Path) -> tuple[list[re.Pattern], list[re.Pattern], list[tuple[str, re.Pattern]]]:
    """(content rules, path rules, allow pairs) from the denylist file."""
    content, paths, allows = [], [], []
    section = "content"
    exempt_next = False
    for lineno, raw in enumerate(path.read_text().split("\n"), 1):
        line = raw.strip()
        if line == "#self-test-exempt":
            # The NEXT rule cannot fire against the source tree but is still wanted against a
            # build. Marked here so --self-test does not report it as dead.
            exempt_next = True
            continue
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        try:
            if section == "allow":
                rule, _, where = line.partition("\t")
                allows.append((rule.strip(), re.compile(where.strip())))
            elif section == "path":
                rule = re.compile(line)
                if exempt_next:
                    SELF_TEST_EXEMPT.add(rule.pattern)
                paths.append(rule)
            else:
                # MULTILINE: several rules anchor with ^ to pin a VALUE position (`  key: AgA…`)
                # rather than match the token anywhere. The scan applies them per line, the
                # self-test against whole-file text — ^ must mean "line start" in both.
                rule = re.compile(line, re.M)
                if exempt_next:
                    SELF_TEST_EXEMPT.add(rule.pattern)
                content.append(rule)
        except re.error as exc:
            sys.exit(f"ERROR: {path}:{lineno}: bad regex {line!r}: {exc}")
        exempt_next = False
    return content, paths, allows


def is_text(path: Path) -> bool:
    """Null-byte sniff — the cheap, conventional binary test."""
    try:
        return b"\0" not in path.open("rb").read(8192)
    except OSError:
        return False


def walk(root: Path):
    """Every file under root. Dotfiles and dot-dirs INCLUDED: a stray .git or a
    .claude/settings.local.json is itself a finding, so they must not be skipped."""
    for p in sorted(root.rglob("*")):
        if p.is_file() and not p.is_symlink():
            yield p


def scan(root: Path, content_rules, path_rules, allows) -> tuple[list[str], int]:
    findings: list[str] = []
    per_rule: dict[str, int] = {}
    scanned = 0

    for path in walk(root):
        rel = path.relative_to(root).as_posix()

        for rule in path_rules:
            if rule.search(rel):
                findings.append(f"  {rel}: path matches /{rule.pattern}/")

        if not is_text(path):
            continue
        scanned += 1
        exempt = {r for r, where in allows if where.search(rel)}
        try:
            lines = path.read_text(errors="replace").split("\n")
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            for rule in content_rules:
                if rule.pattern in exempt:
                    continue
                m = rule.search(line)
                if not m:
                    continue
                seen = per_rule.get(rule.pattern, 0)
                if seen < MAX_HITS_PER_RULE:
                    findings.append(f"  {rel}:{n}: {m.group(0)[:80]}  [/{rule.pattern}/]")
                elif seen == MAX_HITS_PER_RULE:
                    findings.append(f"  … more hits for /{rule.pattern}/ not listed")
                per_rule[rule.pattern] = seen + 1

    return findings, scanned


def self_test(content_rules, path_rules) -> int:
    """Assert every rule matches something in the SOURCE tree.

    A rule that can never fire is worse than no rule: it reads as coverage and provides none.

    ⚠ Scans the TRACKED files only (`git ls-files`), not a filesystem walk: the working
    directory carries install/ and external/ (tens of GB of vendor media and upstream chart
    clones), which a walk would read in full for no benefit. Tracked files are also exactly
    what a release is built from, so it is the right set anyway.
    """
    print("self-test: checking every denylist rule fires against the source repo")
    dead: list[str] = []

    tracked = subprocess.run(["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
                             capture_output=True, text=True).stdout.split("\0")
    rels = [r for r in tracked if r]

    for rule in path_rules:
        if rule.pattern in SELF_TEST_EXEMPT:
            continue
        if not any(rule.search(r) for r in rels):
            dead.append(f"[path] /{rule.pattern}/")

    remaining = {r.pattern: r for r in content_rules if r.pattern not in SELF_TEST_EXEMPT}
    for rel in rels:
        if not remaining:
            break
        path = REPO_ROOT / rel
        if not path.is_file() or not is_text(path):
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for pattern, rule in list(remaining.items()):
            if rule.search(text):
                del remaining[pattern]
    dead += [f"[content] /{p}/" for p in remaining]

    if dead:
        print(f"ERROR: {len(dead)} denylist rule(s) match NOTHING in the source repo.",
              file=sys.stderr)
        print("       A rule that cannot fire reads as coverage and gives none — it would",
              file=sys.stderr)
        print("       pass the release gate while the value it names leaks. Fix the regex,",
              file=sys.stderr)
        print("       or delete the rule if what it guarded is genuinely gone:", file=sys.stderr)
        for d in dead:
            print(f"  {d}", file=sys.stderr)
        return 1

    print(f"self-test OK — all {len(content_rules)} content + {len(path_rules)} path rule(s) fire.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, help="release build directory to scan")
    ap.add_argument("--denylist", type=Path, default=DEFAULT_DENYLIST)
    ap.add_argument("--self-test", action="store_true",
                    help="assert every rule fires against the source repo, then exit")
    ap.add_argument("--warn-only", action="store_true", help="report findings but exit 0")
    args = ap.parse_args()

    if not args.denylist.exists():
        sys.exit(f"ERROR: denylist not found: {args.denylist}")
    content_rules, path_rules, allows = parse_denylist(args.denylist)

    if args.self_test:
        return self_test(content_rules, path_rules)

    if not args.root:
        sys.exit("ERROR: --root is required (or pass --self-test)")
    if not args.root.is_dir():
        sys.exit(f"ERROR: not a directory: {args.root}")

    findings, scanned = scan(args.root, content_rules, path_rules, allows)

    if findings:
        print(f"release-clean check: {len(findings)} FINDING(S) in {args.root}", file=sys.stderr)
        for f in findings:
            print(f, file=sys.stderr)
        print("", file=sys.stderr)
        print("Each is something the denylist says must not be published. Fix it in the", file=sys.stderr)
        print("SOURCE repo (preferred — then every future release is clean), or add a", file=sys.stderr)
        print("substitution to prepareRelease.sh. Adding a rule to [allow] only silences", file=sys.stderr)
        print("the check; it does not make the value safe.", file=sys.stderr)
        return 0 if args.warn_only else 1

    # A pass says what it CHECKED. "All clean" with nothing behind it is the failure mode
    # this whole gate was written to replace.
    print(f"release-clean check: OK — scanned {scanned} text file(s) against "
          f"{len(content_rules)} content + {len(path_rules)} path rule(s), 0 findings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
