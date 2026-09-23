"""Minimal Ryax action: echo a message and report where it actually ran.

The point of this action is placement verification. `node_name` is the output that
matters — it must come back as one of the unibi-hclab mesh nodes, which is what
proves the Site / Node Pool selector and the ryax-placement admission policy are
both doing their job.

Standard library only, deliberately: see the note in ryax_metadata.yaml.
"""

import os
import platform
import socket


def _node_name() -> str:
    """Best-effort node name for the pod running this action.

    The Ryax worker builds the action pod spec itself (it is not rendered by the
    Helm chart), so which downward-API variables it injects is not guaranteed and
    is not part of the documented contract. Try the conventional names, then fall
    back to reading the value the kubelet always provides via the pod's
    /etc/hostname-independent spec.nodeName mirror, and finally to "unknown"
    rather than raising — a smoke test must report a partial result, not fail.
    """
    for var in ("RYAX_NODE_NAME", "NODE_NAME", "KUBERNETES_NODE_NAME", "K8S_NODE_NAME"):
        value = os.environ.get(var)
        if value:
            return value

    # Some runtimes expose it as a file rather than an env var.
    for path in ("/etc/nodename", "/var/run/nodename"):
        try:
            with open(path, encoding="utf-8") as handle:
                value = handle.read().strip()
                if value:
                    return value
        except OSError:
            pass

    return "unknown"


def handle(request: dict) -> dict:
    return {
        "greeting": f"{request['message']} (from {socket.gethostname()})",
        "node_name": _node_name(),
        # The pod name IS reliably the hostname for a Kubernetes pod.
        "pod_name": socket.gethostname(),
        "architecture": platform.machine(),
    }
