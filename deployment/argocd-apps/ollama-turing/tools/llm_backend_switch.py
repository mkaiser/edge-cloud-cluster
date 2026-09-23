"""
title: LLM Backend Switch
author: ecc-infra
description: Show and switch which LLM backend serves each GPU node — high-flexibility (Ollama, many models loaded on demand) vs high-throughput (vLLM, one pinned model), and on the 2-GPU node, two small models vs one large one.
version: 1.0.0
required_open_webui_version: 0.5.0
licence: MIT
"""

# WHY A TOOL RATHER THAN A NEW WEB APP
# -----------------------------------
# The ask was "a web interface, behind Authentik, to switch backend and node at runtime
# without git". A bespoke service would mean its own OIDC client, HTTPRoute, session
# handling and RBAC. An Open WebUI Tool gets all of that for free: Open WebUI is already
# Authentik-OIDC-gated, already on the shared Gateway, and its pod already has a Kubernetes
# ServiceAccount token mounted. So this is ~200 lines instead of a new app, and there is one
# less auth surface to own.
#
# Access control is Open WebUI's per-tool sharing. Share it with `authentik-admins` only —
# scaling a GPU backend affects EVERY user of that node, so it is not a per-user action.
#
# WHAT IT CAN AND CANNOT DO — read this before extending it
# --------------------------------------------------------
# CAN: scale the serving Deployments (Ollama / vLLM, per node) and report their state.
#      That is `patch` on a Deployment, exactly what `kubectl scale` does.
#
# CAN: on the 2-GPU Turing node, trade concurrency for capacity, because the choice is
#      literally a replica count:
#        2 replicas x 1 GPU  -> two models up to ~7.5 GiB each, 2x concurrency
#        1 replica  x 2 GPU  -> ONE model up to ~15 GiB (llama.cpp layer-splitting; measured:
#                               qwen2.5-coder:14b runs 49/49 layers on GPU, 100% GPU)
#      The 2-GPU form needs `nvidia.com/gpu: 2` in the pod spec as well as a replica change,
#      so `set_gpu_mode` patches BOTH in one call (see _set_gpu_mode). ArgoCD does not fight
#      it: the Application ignores /spec/replicas and the GPU limit.
#
# CANNOT: change which model vLLM serves. That is a startup CLI arg (--model /
#      --served-model-name) and vLLM's OpenAIServingModels.base_model_paths is set in
#      __init__ and never mutated — there is no API to add a base model. `/v1/load_lora_adapter`
#      only attaches adapters to the SAME base model, and `/sleep`+`/wake_up` (dev-mode-gated)
#      just free VRAM for the same model. To offer N vLLM models you need N Deployments, all
#      at replicas 0, and this tool scales the chosen one. Until those exist, vLLM is
#      one-model-per-node.
#
# CANNOT: create a double booking. Each node advertises a fixed nvidia.com/gpu count and both
#      backends now request it, so the scheduler enforces exclusivity — the worst this tool can
#      do is leave something Pending. That is why Thor's ollama was moved off the legacy
#      env-injection path.
#
# A SCALE ONLY STICKS because the Applications carry ignoreDifferences on /spec/replicas plus
# RespectIgnoreDifferences. Without it ArgoCD selfHeal reverts within seconds — measured, it
# evicted a test pod mid-download. Suspending the Application's syncPolicy does NOT help
# either: the app-of-apps re-applies it from git.

import json
import os
from typing import Any, Callable, Optional

import aiohttp
from pydantic import BaseModel, Field

K8S = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

# node -> the backends that can serve it, with their Deployment coordinates.
# Keep in sync with deployment/argocd-apps/{ollama,ollama-turing,vllm}/.
TARGETS: dict[str, dict[str, dict[str, Any]]] = {
    "thor": {
        "ollama": {"ns": "ollama", "deploy": "ollama", "gpus": 1},
        "vllm": {"ns": "vllm", "deploy": "vllm", "gpus": 1},
    },
    "turing": {
        "ollama": {"ns": "ollama-turing", "deploy": "ollama-turing", "gpus": 2},
        # No vLLM app for this node yet — the only vllm app is Thor-pinned (sm_110 image).
        # Listed so the tool can say so instead of silently omitting the option.
        "vllm": {"ns": "vllm-turing", "deploy": "vllm-turing", "gpus": 2},
    },
}

NODE_BLURB = {
    "thor": "Jetson Thor — one big GPU (~123 GiB unified), best for one large pinned model",
    "turing": "smartmirror1 — 2x RTX 2070 sm_75 (7.5 GiB each), best for several small models",
}


class Tools:
    class Valves(BaseModel):
        """Admin-set, in Workspace -> Tools -> LLM Backend Switch -> valves."""

        enabled: bool = Field(
            default=True,
            description="Master off-switch; when false the tool only reports status.",
        )
        allow_switch: bool = Field(
            default=True,
            description=(
                "When false, scaling is refused and the tool is read-only. Useful if you want "
                "the status view shared widely but the switch kept to a smaller group."
            ),
        )

    def __init__(self):
        self.valves = self.Valves()
        self.citation = False

    # ── k8s plumbing ────────────────────────────────────────────────────────────────

    def _token(self) -> Optional[str]:
        try:
            with open(f"{SA}/token") as fh:
                return fh.read().strip()
        except OSError:
            return None

    def _headers(self, patch: bool = False) -> dict[str, str]:
        h = {"Authorization": f"Bearer {self._token()}"}
        if patch:
            # Strategic-merge is enough for spec.replicas and is what kubectl scale uses.
            h["Content-Type"] = "application/strategic-merge-patch+json"
        return h

    async def _get_deploy(
        self, session: aiohttp.ClientSession, ns: str, name: str
    ) -> Optional[dict]:
        url = f"{K8S}/apis/apps/v1/namespaces/{ns}/deployments/{name}"
        async with session.get(
            url, headers=self._headers(), ssl=self._ssl(), timeout=aiohttp.ClientTimeout(total=20)
        ) as r:
            if r.status == 200:
                return await r.json()
            return None

    def _ssl(self):
        # Verify the API server against the SA CA bundle rather than disabling TLS checks.
        ca = f"{SA}/ca.crt"
        if os.path.exists(ca):
            import ssl as _ssl

            return _ssl.create_default_context(cafile=ca)
        return None

    async def _scale(
        self, session: aiohttp.ClientSession, ns: str, name: str, replicas: int
    ) -> tuple[bool, str]:
        url = f"{K8S}/apis/apps/v1/namespaces/{ns}/deployments/{name}"
        body = json.dumps({"spec": {"replicas": replicas}})
        async with session.patch(
            url,
            data=body,
            headers=self._headers(patch=True),
            ssl=self._ssl(),
            timeout=aiohttp.ClientTimeout(total=30),
        ) as r:
            if r.status == 200:
                return True, "ok"
            return False, f"HTTP {r.status}: {(await r.text())[:200]}"

    async def _set_gpu_mode(
        self,
        session: aiohttp.ClientSession,
        ns: str,
        name: str,
        gpus: int,
        replicas: int,
        container: str,
        image: str,
    ) -> tuple[bool, str]:
        """Set pods-per-node AND cards-per-pod in ONE patch.

        They must move together: 2 replicas x 2 GPUs would need 4 cards on a 2-card node, so
        the intermediate state is unschedulable. A single patch means the ReplicaSet is created
        once, with a consistent shape.

        maxSurge is 0 in both modes (a surge pod on a fully-booked 2-GPU node has no card and
        would deadlock), and maxUnavailable is pinned to the FULL replica count so the rolling
        update tears the old generation down before standing the new one up.

        maxUnavailable matters more than it looks. Measured going 1x2 -> 2x1 with
        maxUnavailable 1: the controller kept the old 2-GPU pod alive because it satisfied
        availability, then tried to add a 1-GPU pod with ZERO free cards. Deadlock — the new
        pod sat Pending indefinitely (7+ minutes, not a transient) and only cleared when the
        old pod was deleted by hand. Allowing every replica to go unavailable is what frees the
        cards, and it is the honest shape here: on a 2-card node a GPU-count change CANNOT be
        done without an interruption, so make it explicit rather than deadlock politely.
        """
        url = f"{K8S}/apis/apps/v1/namespaces/{ns}/deployments/{name}"
        body = json.dumps(
            {
                "spec": {
                    "replicas": replicas,
                    "strategy": {
                        "rollingUpdate": {
                            "maxSurge": 0,
                            # == replicas: let the whole old generation go, freeing the cards.
                            "maxUnavailable": replicas,
                        }
                    },
                    "template": {
                        "spec": {
                            "containers": [
                                {
                                    # `container` MUST be the container's real name, read from
                                    # the live spec — NOT the Deployment name. Strategic merge
                                    # keys this list by name and SILENTLY APPENDS a new entry
                                    # when the name does not match. Passing the Deployment name
                                    # here created a phantom second container, so the pod asked
                                    # for 2+1=3 GPUs on a 2-card node and sat Pending on
                                    # "Insufficient nvidia.com/gpu" — with no pod holding a card,
                                    # which reads like a stale device plugin and is not.
                                    #
                                    # `image` is carried along because the API validates the
                                    # MERGED pod spec and rejects a container without one
                                    # ("image: Required value") — server-side dry-run confirmed.
                                    "name": container,
                                    "image": image,
                                    "resources": {"limits": {"nvidia.com/gpu": str(gpus)}},
                                }
                            ]
                        }
                    },
                }
            }
        )
        async with session.patch(
            url,
            data=body,
            headers=self._headers(patch=True),
            ssl=self._ssl(),
            timeout=aiohttp.ClientTimeout(total=30),
        ) as r:
            if r.status == 200:
                return True, "ok"
            return False, f"HTTP {r.status}: {(await r.text())[:300]}"

    @staticmethod
    def _state(dep: Optional[dict]) -> str:
        if dep is None:
            return "not deployed"
        spec = (dep.get("spec") or {}).get("replicas", 0) or 0
        ready = (dep.get("status") or {}).get("readyReplicas", 0) or 0
        if spec == 0:
            return "down"
        if ready >= spec:
            return f"UP ({ready}/{spec} ready)"
        return f"starting ({ready}/{spec} ready)"

    @staticmethod
    def _gpus_per_pod(dep: Optional[dict]) -> Optional[int]:
        if dep is None:
            return None
        try:
            c = dep["spec"]["template"]["spec"]["containers"][0]
            v = (c.get("resources", {}).get("limits", {}) or {}).get("nvidia.com/gpu")
            return int(v) if v is not None else None
        except (KeyError, IndexError, TypeError, ValueError):
            return None

    # ── user-facing methods ─────────────────────────────────────────────────────────

    async def llm_status(
        self, __event_emitter__: Optional[Callable[[dict], Any]] = None
    ) -> str:
        """
        Show which LLM backend is currently serving each GPU node, and how each node's GPUs
        are allocated. Use this before switching anything.
        :return: A per-node summary of backend state.
        """
        if self._token() is None:
            return "No Kubernetes credential available in this pod — cannot read backend state."

        lines: list[str] = []
        async with aiohttp.ClientSession() as session:
            for node, backends in TARGETS.items():
                lines.append(f"\n**{node}** — {NODE_BLURB.get(node, '')}")
                for backend, t in backends.items():
                    dep = await self._get_deploy(session, t["ns"], t["deploy"])
                    state = self._state(dep)
                    per_pod = self._gpus_per_pod(dep)
                    extra = ""
                    if per_pod is not None:
                        spec = (dep.get("spec") or {}).get("replicas", 0) or 0
                        extra = f", {per_pod} GPU/pod x {spec} replica(s)"
                    lines.append(f"  - {backend}: {state}{extra}")

        lines.append(
            "\nOllama = many models, loaded on demand (high flexibility). "
            "vLLM = one pinned model, higher throughput under load."
        )
        return "Current LLM backends:\n" + "\n".join(lines)

    async def switch_llm_backend(
        self,
        node: str,
        backend: str,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        Switch which LLM backend serves a GPU node. Scales the chosen backend up and the
        other one down, so the node's GPU is handed over cleanly.
        :param node: Which GPU node — "thor" or "turing".
        :param backend: Which backend to run — "ollama" (many models, flexible) or "vllm" (one pinned model, faster).
        :return: What changed, or why the request was refused.
        """
        node = (node or "").strip().lower()
        backend = (backend or "").strip().lower()
        who = (__user__ or {}).get("email") or (__user__ or {}).get("name") or "unknown"

        async def say(desc: str, done: bool = False) -> None:
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": desc, "done": done}}
                )

        if not self.valves.enabled or not self.valves.allow_switch:
            return "Switching backends is disabled by an administrator (read-only mode)."
        if node not in TARGETS:
            return f"Unknown node '{node}'. Choose one of: {', '.join(TARGETS)}."
        if backend not in TARGETS[node]:
            return f"Unknown backend '{backend}'. Choose one of: {', '.join(TARGETS[node])}."
        if self._token() is None:
            return "No Kubernetes credential available in this pod — cannot switch."

        want = TARGETS[node][backend]
        others = {b: t for b, t in TARGETS[node].items() if b != backend}

        async with aiohttp.ClientSession() as session:
            # Refuse early if the target does not exist, rather than scaling the incumbent
            # down and leaving the node with NOTHING serving.
            target = await self._get_deploy(session, want["ns"], want["deploy"])
            if target is None:
                return (
                    f"'{backend}' is not deployed for {node} "
                    f"(no Deployment {want['deploy']} in namespace {want['ns']}).\n"
                    "Nothing was changed. An administrator has to enable that app first — "
                    "for vLLM on the turing node there is no app yet at all."
                )

            # Scale the incumbent(s) DOWN first: both backends request the node's only GPU,
            # so the new pod cannot schedule until the old one has released it.
            for b, t in others.items():
                dep = await self._get_deploy(session, t["ns"], t["deploy"])
                if dep is None:
                    continue
                if ((dep.get("spec") or {}).get("replicas") or 0) > 0:
                    await say(f"Stopping {b} on {node} to free the GPU...")
                    ok, msg = await self._scale(session, t["ns"], t["deploy"], 0)
                    if not ok:
                        return f"Could not stop {b} on {node}: {msg}\nNothing else was changed."

            # Default replica count: the Turing node runs one pod per card.
            replicas = 2 if (node == "turing" and backend == "ollama") else 1
            await say(f"Starting {backend} on {node} (requested by {who})...")
            ok, msg = await self._scale(session, want["ns"], want["deploy"], replicas)
            if not ok:
                return f"Could not start {backend} on {node}: {msg}"

            await say(f"{backend} on {node} is starting.", done=True)

        note = ""
        if backend == "vllm":
            note = (
                "\n\nvLLM serves ONE pinned model, fixed at startup — it cannot be changed "
                "from here. Model startup can take minutes (a cold load much longer)."
            )
        elif node == "turing":
            note = (
                "\n\nTwo replicas, one GPU each: two models up to ~7.5 GiB can be resident. "
                "To serve ONE model up to ~15 GiB across both cards instead, the pod spec "
                "needs nvidia.com/gpu: 2 — that is a git change, not a switch."
            )
        return (
            f"Switched {node} to **{backend}** ({replicas} replica(s)).\n"
            "It takes a moment to become ready; run the status check to confirm." + note
        )

    async def set_gpu_mode(
        self,
        mode: str,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        Switch the 2-GPU node ("turing", the host smartmirror1) between two models on one card each, and
        running ONE larger model across both cards. Use "concurrency" for two small models with
        double throughput, or "large" for a single model up to about 14 GiB.
        :param mode: Either "concurrency" (2 pods x 1 GPU) or "large" (1 pod x 2 GPUs).
        :return: What happened, including why a request was refused.
        """
        who = (__user__ or {}).get("email") or (__user__ or {}).get("name") or "unknown"

        async def say(desc: str, done: bool = False) -> None:
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": desc, "done": done}}
                )

        if not self.valves.enabled or not self.valves.allow_switch:
            return "Switching is disabled on this instance; this tool is read-only."

        want = (mode or "").strip().lower()
        aliases = {
            "concurrency": (2, 1),
            "concurrent": (2, 1),
            "2x1": (2, 1),
            "two": (2, 1),
            "small": (2, 1),
            "large": (1, 2),
            "big": (1, 2),
            "1x2": (1, 2),
            "one": (1, 2),
            "both": (1, 2),
        }
        if want not in aliases:
            return (
                f"'{mode}' is not a mode. Use 'concurrency' (2 models, one card each) or "
                "'large' (one model across both cards)."
            )
        replicas, gpus = aliases[want]

        t = TARGETS["turing"]["ollama"]
        ns, name = t["ns"], t["deploy"]

        if self._token() is None:
            return "No Kubernetes credential available in this pod — cannot switch."

        try:
            async with aiohttp.ClientSession() as session:
                dep = await self._get_deploy(session, ns, name)
                if dep is None:
                    return f"{name} is not deployed in namespace {ns}; nothing to switch."

                cur_gpus = self._gpus_per_pod(dep)
                cur_reps = (dep.get("spec") or {}).get("replicas", 0) or 0
                if cur_gpus == gpus and cur_reps == replicas:
                    return (
                        f"Already in {want} mode ({replicas} pod(s) x {gpus} GPU). "
                        "Nothing to do."
                    )

                # Read the container's real NAME and image from the live spec. Anything
                # else risks the silent-append trap documented in _set_gpu_mode.
                try:
                    c0 = dep["spec"]["template"]["spec"]["containers"][0]
                    container, image = c0["name"], c0["image"]
                except (KeyError, IndexError, TypeError):
                    return "Could not read the current container spec; refusing to patch."

                # If the live spec ever grows a second container, a single-container patch is
                # no longer a safe description of intent — refuse rather than guess which one
                # should own the cards.
                if len(dep["spec"]["template"]["spec"]["containers"]) != 1:
                    return (
                        "This Deployment has more than one container; refusing to guess which "
                        "one should hold the GPUs. Fix it in git."
                    )

                await say(f"Switching to {want}: {replicas} pod(s) x {gpus} GPU…")
                ok, detail = await self._set_gpu_mode(
                    session,
                    ns,
                    name,
                    gpus=gpus,
                    replicas=replicas,
                    container=container,
                    image=image,
                )
                if not ok:
                    return f"Switch failed: {detail}"

                await say("Patched; pods are rolling.", done=True)

        except Exception as e:
            return f"Could not switch mode: {e}"

        note = (
            "Two models can now be resident, one per card, each up to ~7.5 GiB."
            if replicas > 1
            else (
                "One model can now use both cards (~14 GiB via llama.cpp layer splitting). "
                "Models above ~7.5 GiB only work in THIS mode — e.g. "
                "qwen2.5-coder:14b-instruct-q5_K_M."
            )
        )
        return (
            f"Switched the turing node to **{want}** mode: {replicas} pod(s) x {gpus} GPU "
            f"(requested by {who}).\n{note}\n\n"
            "The old pods are stopped BEFORE the new ones start — on a 2-card node a GPU-count "
            "change cannot be done without an interruption. Expect a minute or two with nothing "
            "served, plus a cold model load on the first request. Run llm_status to confirm."
        )
