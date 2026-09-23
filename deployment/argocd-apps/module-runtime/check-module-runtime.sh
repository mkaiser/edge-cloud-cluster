#!/usr/bin/env bash
# Assert every module-runtime consumer carries the `module load` pod-spec fragment.
#
# ⚠ BASH WRAPPER AROUND PYTHON, DELIBERATELY. precommit's run_contract_check() invokes
# every check as `bash "$script"`, so a file with a `#!/usr/bin/env python3` shebang is
# executed BY BASH — the docstring runs as shell commands ("module: command not found")
# and the check silently passes without asserting anything. Keep this wrapper.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT
exec python3 - "$@" <<'PYEOF'
"""Assert every module-runtime consumer carries the fragment consistently.

The `module load` mechanism is a POD-SPEC FRAGMENT (broker sidecar + three volumes + the
mounts), not a resource, so it cannot be shared by a chart — see this directory's README.
It is therefore duplicated per consumer, and this check is what stops the copies drifting.

⚠ It asserts STRUCTURE, never values that legitimately move between recreates: mount PATHS
and volume WIRING, not image tags, node names or claim names (a second consumer needs its
OWN claim — a PV binds to exactly one PVC). See the header of tests/adChecks.sh for why.

What it enforces, and why each one has already bitten:
  1. gVisor        — the sandbox is what makes podman-as-root acceptable. A consumer
                     without it is a different security posture, not a config nit.
  2. broker NOT privileged — runsc cannot start a privileged SUBCONTAINER on pcie-tb-d and
                     ALL containers then fail together, reading as a pod-wide fault.
  3. /registry in the BROKER ONLY — writing a module.yaml there is root-execution
                     authority. Which containers mount it IS the boundary.
  4. the mount set — a missing /modules or /run/module-requests makes `module load` hang
                     rather than fail, because the CLI polls for a status file forever.
  5. ONE shared podman graphroot per node — the desktop and the [eda-run] runner must name
                     the SAME hostPath. The xilinx image's second layer is a single 42.8 GB
                     blob (~23 min); two paths means every consumer on the node pays it
                     again, which is what this cache exists to stop. Silent when it drifts:
                     the build still works, just slowly.
Run by precommit; exits non-zero on drift.
"""
import os
import sys

import yaml

# ⚠ NOT derived from __file__: the wrapper feeds this script to python on STDIN, so
# __file__ does not exist. The repo root comes from the environment the wrapper sets.
ROOT = os.environ["REPO_ROOT"]

# file -> (pod-spec-carrying kind, main container name)
# Register a new consumer HERE; an unregistered one is invisible to this check.
CONSUMERS = {
    "deployment/argocd-apps/remote-desktop/desktop-gvisor.yaml": ("Deployment", "desktop"),
    "deployment/argocd-apps/remote-desktop-bender/desktop-bender.yaml": ("Deployment", "desktop"),
}

REQUIRED_SHARED = {"/modules", "/run/module-requests"}
BROKER_ONLY = "/registry"

# The per-node module image cache. Shared by every consumer on the node ON PURPOSE, so the
# path is an invariant across two files in two different formats (a pod spec and the
# runner's TOML) — which is exactly the kind of pair that drifts unnoticed.
SHARED_GRAPHROOT = "/var/lib/eda-module-podman"
GRAPHROOT_TOML = "deployment/argocd-apps/app-of-apps/gitlab-runner-eda-run.yaml"

fail = []


def podspecs(doc):
    """Yield every pod spec in a manifest doc, whatever wraps it."""
    if not isinstance(doc, dict):
        return
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind == "Pod":
        yield spec
    elif kind in ("Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"):
        yield (spec.get("template") or {}).get("spec") or {}
    elif kind == "CronJob":
        jt = (spec.get("jobTemplate") or {}).get("spec") or {}
        yield (jt.get("template") or {}).get("spec") or {}


def mounts(container):
    return {m.get("mountPath") for m in (container.get("volumeMounts") or [])}


for rel, (want_kind, main_name) in sorted(CONSUMERS.items()):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        fail.append(f"{rel}: registered consumer file is missing")
        continue

    found = False
    with open(path) as fh:
        for doc in yaml.safe_load_all(fh):
            if not isinstance(doc, dict) or doc.get("kind") != want_kind:
                continue
            for pod in podspecs(doc):
                names = [c.get("name") for c in (pod.get("containers") or [])]
                if main_name not in names or "broker" not in names:
                    continue
                found = True
                by_name = {c.get("name"): c for c in pod["containers"]}
                broker = by_name["broker"]
                main = by_name[main_name]

                # 1. the sandbox
                if pod.get("runtimeClassName") != "runsc":
                    fail.append(
                        f"{rel}: runtimeClassName is {pod.get('runtimeClassName')!r}, not 'runsc' — "
                        "the gVisor sandbox is what makes podman-as-root acceptable")

                # 2. the broker must not be privileged
                if ((broker.get("securityContext") or {}).get("privileged")) is True:
                    fail.append(
                        f"{rel}: broker has privileged: true — runsc cannot start a privileged "
                        "subcontainer on pcie-tb-d and ALL containers fail together")

                # 3. /registry is broker-only: it is root-execution authority
                if BROKER_ONLY not in mounts(broker):
                    fail.append(f"{rel}: broker does not mount {BROKER_ONLY} — it reads the module manifests there")
                if BROKER_ONLY in mounts(main):
                    fail.append(
                        f"{rel}: container {main_name!r} mounts {BROKER_ONLY} — that is "
                        "root-execution authority and belongs to the broker ONLY")

                # 4. the shared IPC/metadata mounts, on BOTH containers
                for cname, c in ((main_name, main), ("broker", broker)):
                    missing = REQUIRED_SHARED - mounts(c)
                    if missing:
                        fail.append(
                            f"{rel}: container {cname!r} is missing {sorted(missing)} — "
                            "`module load` then HANGS (the CLI polls for a status file) rather than failing")

                # ...and they must be the pod-local emptyDirs the broker/CLI protocol needs,
                # not a shared network volume (the status files are per-pod).
                vols = {v.get("name"): v for v in (pod.get("volumes") or [])}
                for want in ("modules", "module-requests"):
                    v = vols.get(want)
                    if v is None:
                        fail.append(f"{rel}: no volume named {want!r}")
                    elif "emptyDir" not in v:
                        fail.append(
                            f"{rel}: volume {want!r} is not an emptyDir — the request/status "
                            "protocol is pod-local and must not be shared between pods")

                # 5. the podman store is the SHARED per-node cache, and a hostPath: an
                # emptyDir would die with the pod and re-pull 42.8 GB every time.
                store = vols.get("podman-store")
                if store is None:
                    fail.append(f"{rel}: no volume named 'podman-store'")
                elif "hostPath" not in store:
                    fail.append(
                        f"{rel}: volume 'podman-store' is not a hostPath — the module image "
                        "layer is a single 42.8 GB blob and an emptyDir re-pulls it per pod")
                elif store["hostPath"].get("path") != SHARED_GRAPHROOT:
                    fail.append(
                        f"{rel}: podman-store hostPath is {store['hostPath'].get('path')!r}, "
                        f"not the shared per-node cache {SHARED_GRAPHROOT!r} — a private store "
                        "makes this consumer re-pull 42.8 GB that the node already has")

    if not found:
        fail.append(
            f"{rel}: no {want_kind} carrying containers {main_name!r} + 'broker' was found — "
            "registered as a module-runtime consumer but does not look like one")

# The [eda-run] runner declares its store in the runner's TOML config, not in a pod spec,
# so it is checked as text. It is the SECOND writer into the shared graphroot and the reason
# module-podman.sh takes its pull lock inside the store rather than in a pod-local emptyDir.
toml_path = os.path.join(ROOT, GRAPHROOT_TOML)
if not os.path.exists(toml_path):
    fail.append(f"{GRAPHROOT_TOML}: missing — it declares the second writer into the shared store")
else:
    with open(toml_path) as fh:
        toml_text = fh.read()
    if f'host_path = "{SHARED_GRAPHROOT}"' not in toml_text:
        fail.append(
            f"{GRAPHROOT_TOML}: no podman-store host_path = \"{SHARED_GRAPHROOT}\" — the "
            "runner must share the desktop's graphroot so one pull per node serves both")

if fail:
    print("module-runtime drift:", file=sys.stderr)
    for f in fail:
        print(f"  - {f}", file=sys.stderr)
    print("\nThe canonical fragment is deployment/argocd-apps/module-runtime/README.md",
          file=sys.stderr)
    sys.exit(1)

print(f"ok: {len(CONSUMERS)} module-runtime consumer(s) carry the fragment "
      "(gVisor, unprivileged broker, /registry broker-only, pod-local IPC) "
      f"and share the per-node store {SHARED_GRAPHROOT}")
PYEOF
