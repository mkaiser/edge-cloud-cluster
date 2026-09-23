#!/usr/bin/env python3
"""Fail on a Deployment that mounts a ReadWriteOnce PVC without strategy Recreate.

WHY THIS IS A CHECK AND NOT A CODE REVIEW ITEM
----------------------------------------------
`strategy` is OPTIONAL in the Deployment API and defaults to RollingUpdate, so the
broken shape is the one you get by writing nothing at all. Nothing in Kubernetes,
Helm or ArgoCD warns about it.

RollingUpdate starts the replacement pod BEFORE terminating the old one. A
ReadWriteOnce volume can be attached to exactly one node at a time, so the moment
the scheduler places the new pod on a different node than the old one, the new pod
blocks forever on

    FailedAttachVolume: Volume is already used by pod(s) <old pod>

while the old pod waits for the new one to go Ready. Neither side yields; no
timeout breaks it. The app sits Degraded until a human deletes a pod.

It is a LATENT bug: while both pods keep landing on the same node the rollout
works, so the Deployment can ship green for months. It detonates on an ordinary
image bump — measured 2026-09-04, open-webui v0.11.1 -> v0.11.3 deadlocked for
10 minutes because the new pod was scheduled to unibi-hclab-pcie-tb-d while the
volume was attached on unibi-hclab-pcie-tb-s. Unpinned pods (flex placement, any
`tolerations` for the mesh taint) hit it soonest, but a node drain moves a pinned
one too.

`Recreate` is the correct shape whenever the pod owns a RWO volume: with one
replica there is nothing to roll anyway, and the brief downtime is REAL either way
(the volume cannot be shared, so no overlap is possible even in principle).

SCOPE / LIMITS
--------------
Scans deployment/**.yaml for Deployment + PersistentVolumeClaim documents in the
repo. It matches a PVC by claimName within the same namespace, so:

  * A PVC declared in a chart's values (not as a manifest here) is invisible to
    this check — those must be fixed via the chart's own strategy value. Known
    upstream cases are listed in ALLOW below with the reason.
  * volumeClaimTemplates (StatefulSet) are NOT affected: a StatefulSet replaces
    pods one ordinal at a time and each ordinal keeps its own volume.
  * A PVC listing ReadWriteMany ALONGSIDE ReadWriteOnce is not flagged: it can be
    multi-attached, so a rolling update is safe. Read the whole accessModes list —
    `kubectl get pvc` prints them joined ("RWO,RWX") and a check that looks only at
    the first element reports a false positive.
  * ReadWriteOncePod is not flagged either: the API already forbids the overlap.
"""

import os
import sys

try:
    import yaml
except ImportError:
    print("checkRwoRolloutStrategy: PyYAML not installed — skipping", file=sys.stderr)
    sys.exit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_DIR = os.path.join(ROOT, "deployment")

# (namespace, deployment) pairs whose PVC comes from an upstream chart we do not
# template here. Each needs its fix in that chart's values, not in a manifest.
ALLOW: dict[tuple[str, str], str] = {}


def docs(path):
    """Yield the YAML documents in path, tolerating templated / non-YAML files."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        return
    # Helm/ArgoCD templating and Go templates are not valid YAML; skip such files
    # wholesale rather than half-parsing them.
    try:
        for d in yaml.safe_load_all(text):
            if isinstance(d, dict):
                yield d
    except yaml.YAMLError:
        return


def main() -> int:
    rwo: set[tuple[str, str]] = set()  # (namespace, pvc name)
    deployments = []  # (namespace, name, strategy, [claimNames], path)

    for dirpath, _dirnames, filenames in os.walk(SCAN_DIR):
        for fn in filenames:
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, fn)
            for d in docs(path):
                kind = d.get("kind")
                meta = d.get("metadata") or {}
                if not isinstance(meta, dict):
                    continue
                ns = meta.get("namespace") or ""
                name = meta.get("name") or ""
                spec = d.get("spec") or {}
                if not isinstance(spec, dict):
                    continue

                if kind == "PersistentVolumeClaim":
                    modes = spec.get("accessModes") or []
                    # RWO only counts when it is the ONLY mode. A PVC that also
                    # requests ReadWriteMany can be multi-attached, so a rolling
                    # update is safe — jitsi's jibri recordings volume is exactly
                    # that (RWO,RWX). Reading only modes[0] reports it as a false
                    # positive, which is how it first got "fixed" needlessly.
                    if isinstance(modes, list) and "ReadWriteOnce" in modes \
                            and "ReadWriteMany" not in modes:
                        rwo.add((ns, name))

                elif kind == "Deployment":
                    strategy = (spec.get("strategy") or {})
                    stype = strategy.get("type", "RollingUpdate") if isinstance(strategy, dict) else "RollingUpdate"
                    tmpl = ((spec.get("template") or {}).get("spec") or {})
                    if not isinstance(tmpl, dict):
                        continue
                    claims = [
                        v["persistentVolumeClaim"]["claimName"]
                        for v in (tmpl.get("volumes") or [])
                        if isinstance(v, dict)
                        and isinstance(v.get("persistentVolumeClaim"), dict)
                        and v["persistentVolumeClaim"].get("claimName")
                    ]
                    if claims:
                        deployments.append((ns, name, stype, claims, path))

    failures = []
    for ns, name, stype, claims, path in deployments:
        if stype == "Recreate":
            continue
        if (ns, name) in ALLOW:
            continue
        bad = [c for c in claims if (ns, c) in rwo]
        if bad:
            failures.append((ns, name, stype, bad, os.path.relpath(path, ROOT)))

    if failures:
        print("RWO rollout-strategy check: FAILED\n", file=sys.stderr)
        for ns, name, stype, bad, rel in sorted(failures):
            print(f"  {rel}", file=sys.stderr)
            print(
                f"    Deployment {ns}/{name} has strategy {stype} but mounts "
                f"ReadWriteOnce PVC(s): {', '.join(bad)}",
                file=sys.stderr,
            )
        print(
            "\n  RollingUpdate starts the new pod before stopping the old one. A RWO volume\n"
            "  attaches to ONE node, so a replacement scheduled elsewhere deadlocks on\n"
            "  FailedAttachVolume while the old pod waits for it to go Ready. Nothing\n"
            "  times this out.\n\n"
            "  Fix — add to the Deployment spec (a 1-replica RWO app loses nothing):\n\n"
            "    spec:\n"
            "      strategy:\n"
            "        type: Recreate\n\n"
            "  ⚠ On an ALREADY-RUNNING Deployment that also needs\n"
            "    metadata.annotations:\n"
            "      argocd.argoproj.io/sync-options: Replace=true\n\n"
            "  kube-controller-manager defaults spec.strategy.rollingUpdate into every\n"
            "  RollingUpdate Deployment and OWNS that field. ServerSideApply merges\n"
            "  per-field, so it leaves the stale block in place and the API rejects the\n"
            "  result — 'rollingUpdate: Forbidden: may not be specified when strategy\n"
            "  type is Recreate' — which ArgoCD then retries forever. Replace=true\n"
            "  delete+creates, dropping the field. Not needed for a NEW Deployment, nor\n"
            "  for a Helm-templated one (Helm replaces rather than field-merges).\n",
            file=sys.stderr,
        )
        return 1

    print(
        f"RWO rollout-strategy check: OK — {len(deployments)} PVC-mounting Deployment(s), "
        "every ReadWriteOnce one uses Recreate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
