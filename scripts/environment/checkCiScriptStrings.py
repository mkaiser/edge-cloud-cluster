#!/usr/bin/env python3
"""Fail if any GitLab CI `script:` entry is not a string.

WHY THIS EXISTS. An unquoted YAML scalar containing ": " parses as a MAPPING, not a string:

    - echo "buildah bud (apt: xfce + KiCad)"      # -> {'echo "buildah bud (apt': 'xfce...'}

GitLab then rejects the whole pipeline at CONFIG time with

    jobs:<job>:script config should be a string or a nested array of strings

which is the worst shape of failure available here: the pipeline fails BEFORE any job runs,
so there is no build log to read, no trace, and no job listing — only a `config_error` on
the pipeline object that nothing surfaces unless you go looking in the Rails console.
Measured on ecc205 (eda-pcb-agent pipeline 4).

The same hazard applies to a bare `*` (alias), `{`/`[` (flow collections) and `%` at the
start of a scalar, all of which change the parsed type. Checking the TYPE catches every one
without having to enumerate the syntax.

⚠ Checks BOTH the source file and any build-files-configmap.yaml copy, because the ConfigMap
copy is what the build-trigger actually mirrors into GitLab — a clean source with a stale or
differently-parsed ConfigMap still ships the broken pipeline.
"""
import glob
import os
import sys

import yaml

SECTIONS = ("script", "before_script", "after_script")


def check_ci(doc, origin, problems):
    if not isinstance(doc, dict):
        return
    for job, body in doc.items():
        if not isinstance(body, dict):
            continue
        for sect in SECTIONS:
            entries = body.get(sect)
            if not isinstance(entries, list):
                continue
            for i, entry in enumerate(entries):
                if isinstance(entry, str):
                    continue
                problems.append(
                    f"{origin}: {job}.{sect}[{i}] parsed as {type(entry).__name__}, not a string\n"
                    f"    -> {str(entry)[:120]}\n"
                    f"    Quote the whole entry, or remove the ': ' from it."
                )


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    targets = sorted(
        glob.glob(os.path.join(root, "deployment/argocd-apps/**/.gitlab-ci.yml"), recursive=True)
        + glob.glob(os.path.join(root, "deployment/argocd-apps/**/ci-*.yml"), recursive=True)
    )
    configmaps = sorted(
        glob.glob(
            os.path.join(root, "deployment/argocd-apps/**/build-files-configmap.yaml"),
            recursive=True,
        )
    )

    problems = []
    checked = 0

    for path in targets:
        rel = os.path.relpath(path, root)
        try:
            doc = yaml.safe_load(open(path))
        except yaml.YAMLError as exc:
            problems.append(f"{rel}: not valid YAML: {exc}")
            continue
        check_ci(doc, rel, problems)
        checked += 1

    # The embedded copy is what actually reaches GitLab.
    for path in configmaps:
        rel = os.path.relpath(path, root)
        try:
            cm = yaml.safe_load(open(path))
        except yaml.YAMLError as exc:
            problems.append(f"{rel}: not valid YAML: {exc}")
            continue
        for key, body in (cm.get("data") or {}).items():
            if not key.endswith((".yml", ".yaml")) or "ci" not in key:
                continue
            try:
                doc = yaml.safe_load(body)
            except yaml.YAMLError as exc:
                problems.append(f"{rel} [{key}]: not valid YAML: {exc}")
                continue
            check_ci(doc, f"{rel} [{key}]", problems)
            checked += 1

    if problems:
        print("ERROR: GitLab CI script entries must be strings:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "\nA non-string entry fails the pipeline at CONFIG time — before any job runs,\n"
            "so there is NO build log to diagnose it from.",
            file=sys.stderr,
        )
        return 1

    print(f"CI script-string check: OK — {checked} CI document(s), every script entry is a string.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
