#!/usr/bin/env python3
"""Fail on a NetworkPolicy whose DNS egress allows kube-dns but not node-local-dns.

WHY THIS IS A CHECK AND NOT A CODE REVIEW ITEM
----------------------------------------------
The broken rule is the one every upstream example and every other cluster writes:

    to:
      - namespaceSelector: { kubernetes.io/metadata.name: kube-system }
        podSelector:       { k8s-app: kube-dns }
    ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]

That is correct almost everywhere and WRONG HERE, so review catches it only if the
reviewer happens to know this cluster's DNS data path. Nothing else warns: the API
accepts it, ArgoCD syncs it, the policy reports no error, and Cilium logs no drop
that names DNS.

THE DATA PATH, AND WHY THE SELECTOR HAS TO NAME node-local-dns
---------------------------------------------------------------
A pod resolves via the kube-dns ClusterIP, but Cilium's LocalRedirectPolicy
(deployment/argocd-infra/node-local-dns/local-redirect-policy.yaml) rewrites that
address to the node-local-dns pod on the SAME node BEFORE NetworkPolicy is
evaluated. So the peer that must be allowed is the cache, not CoreDNS.

Upstream's node-local-dns runs hostNetwork, and NetworkPolicy does not filter
host-network sources — there a podSelector is irrelevant and a kube-dns-only rule
is harmless. This cluster MUST run it as an ordinary pod (hostNetwork: false):
`kubeProxyReplacement: true` removes the kube-proxy chain upstream's iptables
interception depends on, and Cilium's documented answer is the LRP, which requires
an ordinary pod. An ordinary pod has a pod IP and a Cilium identity carrying
`k8s:k8s-app=node-local-dns`, so policy IS enforced against it.

Cilium's own LRP documentation says nothing about this consequence, which is why
the trap is easy to walk into from any upstream example.

WHAT IT COSTS, MEASURED ON ecc214 2026-09-17
---------------------------------------------
THE SYMPTOM NEVER MENTIONS DNS, which is the whole reason this is mechanised.
eda-pcb-agent and hermes both had the kube-dns-only rule. Neither could resolve
anything at all — not even kubernetes.default. It surfaced as:

  * the desktop container exiting `FATAL: 'eda-pcb-agent' does not resolve after
    60s`, because sssd could not find a domain controller — an IDENTITY fault
  * tailscale reporting `no DNS fallback candidates remain` — a VPN fault

with the hermes container itself Ready and healthy beside them, and the pod in
CrashLoopBackOff. Hours went into the AD and VPN paths before the policy.

It was also LATENT for two clusters: while the LRP was inert (its port names did
not bind — see that file's header, fixed on ecc212 2026-09-16) traffic really did
reach CoreDNS and the kube-dns-only rule really was correct. So the rule looks
right, has history on its side, and breaks on an unrelated fix elsewhere.

Proven causally rather than inferred from a recovery: one probe pod spec, one node,
only the policy peer varied. With `kube-dns` alone the pod failed to resolve; with
`node-local-dns` added it resolved immediately.

SCOPE / LIMITS
--------------
Scans deployment/**.yaml for NetworkPolicy documents and inspects every egress rule
that opens port 53.

  * A rule with NO podSelector (namespaceSelector on kube-system alone) is NOT
    flagged: it already covers every pod in kube-system, node-local-dns included.
    That is how searxng is immune, and it is a legitimate shape.
  * A rule naming node-local-dns is fine whether or not it also names kube-dns —
    naming both is what the two fixed policies do, and is the recommended shape:
    it keeps working if the LRP is ever removed.
  * Only `k8s-app` is read, because that is the label the DaemonSet and the coredns
    chart actually set and the only one a policy here selects on.
  * CiliumNetworkPolicy is not scanned: its DNS rules are expressed with toEntities
    / toFQDNs rather than a podSelector, so this shape does not arise there.
"""

import os
import sys

try:
    import yaml
except ImportError:
    print("checkDnsEgressPeers: PyYAML not installed — skipping", file=sys.stderr)
    sys.exit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_DIR = os.path.join(ROOT, "deployment")

CACHE = "node-local-dns"

# (namespace, policy) pairs deliberately exempt, each with the reason. Empty: a
# policy that genuinely must not reach the cache would not be able to resolve at
# all, so there is no legitimate case yet.
ALLOW: dict[tuple[str, str], str] = {}


def docs(path):
    """Yield the YAML documents in path, tolerating templated / non-YAML files."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        return
    # Helm/ArgoCD templating is not valid YAML; skip such files wholesale rather
    # than half-parsing them.
    if "{{" in text:
        return
    try:
        for doc in yaml.safe_load_all(text):
            if isinstance(doc, dict):
                yield doc
    except yaml.YAMLError:
        return


def opens_dns(rule):
    """True if this egress rule opens port 53 (either protocol)."""
    ports = rule.get("ports")
    # ⚠ An egress rule with NO `ports` key opens EVERY port, so it opens 53 too.
    # Treating a missing key as "no DNS" would skip the most permissive rule there
    # is — the one most likely to be the app's only DNS path.
    if ports is None:
        return True
    if not isinstance(ports, list):
        return False
    return any(isinstance(p, dict) and p.get("port") == 53 for p in ports)


def peers(rule):
    """(names, saw_selectorless) for the pod-selected peers of an egress rule.

    saw_selectorless marks a peer that selects a whole namespace (or anything
    other than a podSelector, e.g. an ipBlock) — such a peer already includes
    node-local-dns, so the rule is safe regardless of the named ones.
    """
    names = set()
    selectorless = False
    for peer in rule.get("to") or []:
        if not isinstance(peer, dict):
            continue
        sel = peer.get("podSelector")
        if not isinstance(sel, dict) or not sel.get("matchLabels"):
            # namespaceSelector alone, an ipBlock, or an empty podSelector ({}),
            # which selects every pod in the namespace.
            selectorless = True
            continue
        names.add(sel["matchLabels"].get("k8s-app"))
    return names, selectorless


def main():
    offenders = []
    checked = 0

    for dirpath, _dirnames, filenames in os.walk(SCAN_DIR):
        for name in sorted(filenames):
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            for doc in docs(path):
                if doc.get("kind") != "NetworkPolicy":
                    continue
                meta = doc.get("metadata") or {}
                pol = meta.get("name", "<unnamed>")
                ns = meta.get("namespace", "<no-namespace>")
                spec = doc.get("spec") or {}
                egress = spec.get("egress")
                if not isinstance(egress, list):
                    continue
                for rule in egress:
                    if not isinstance(rule, dict) or not opens_dns(rule):
                        continue
                    checked += 1
                    names, selectorless = peers(rule)
                    if selectorless or CACHE in names:
                        continue
                    if (ns, pol) in ALLOW:
                        continue
                    offenders.append((rel, ns, pol, sorted(n for n in names if n)))

    if offenders:
        print("DNS egress check: FAILED\n", file=sys.stderr)
        for rel, ns, pol, names in offenders:
            got = ", ".join(names) if names else "<none>"
            print(
                f"  {rel}\n"
                f"    NetworkPolicy {ns}/{pol} opens port 53 to pods labelled: {got}\n"
                f"    but not to k8s-app={CACHE}.",
                file=sys.stderr,
            )
        print(
            "\n  Pods resolve via the kube-dns ClusterIP, but Cilium's LocalRedirectPolicy\n"
            "  rewrites that to the node-local-dns pod on the same node BEFORE\n"
            "  NetworkPolicy is evaluated — so a kube-dns-only rule drops EVERY query.\n\n"
            "  ⚠ The symptom never mentions DNS. It surfaces as sssd being unable to find\n"
            "  a domain controller (`does not resolve after 60s`) and tailscale reporting\n"
            "  `no DNS fallback candidates remain`, i.e. as identity and VPN faults, with\n"
            "  the pod in CrashLoopBackOff. Measured on ecc214 2026-09-17.\n\n"
            "  Fix — add the cache as a second peer of the SAME rule:\n\n"
            "    - to:\n"
            "        - namespaceSelector:\n"
            "            matchLabels:\n"
            "              kubernetes.io/metadata.name: kube-system\n"
            "          podSelector:\n"
            "            matchLabels:\n"
            "              k8s-app: kube-dns\n"
            "        - namespaceSelector:\n"
            "            matchLabels:\n"
            "              kubernetes.io/metadata.name: kube-system\n"
            "          podSelector:\n"
            "            matchLabels:\n"
            "              k8s-app: node-local-dns\n"
            "      ports:\n"
            "        - protocol: UDP\n"
            "          port: 53\n"
            "        - protocol: TCP\n"
            "          port: 53\n\n"
            "  Keeping kube-dns alongside it is deliberate: the rule then still works if\n"
            "  the LocalRedirectPolicy is ever removed. Allowing port 53 to the whole\n"
            "  kube-system namespace (no podSelector) is also accepted — that covers the\n"
            "  cache by construction, and is how searxng is immune.\n",
            file=sys.stderr,
        )
        return 1

    print(
        f"DNS egress check: OK — {checked} port-53 egress rule(s), "
        "every one reaches node-local-dns."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
