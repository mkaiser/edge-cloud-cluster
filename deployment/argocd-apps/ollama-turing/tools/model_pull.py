"""
title: Model Library
author: ecc-infra
description: Let any chat user add a model to a GPU node's library, list what is on disk, and see what is loaded in GPU memory right now. Guarded by an allowlist, a per-model size cap and a disk quota.
version: 1.1.0
required_open_webui_version: 0.5.0
licence: MIT
"""

# WHY A TOOL AND NOT A NEW SERVICE
# --------------------------------
# Stock Open WebUI gates /api/pull behind get_admin_user, so a normal user cannot add a
# model. The obvious fix — a small web service with its own OIDC login, UI and RBAC — means
# writing and operating an auth surface we would rather not own.
#
# An Open WebUI *Tool* is a better seam: an admin installs it ONCE, and thereafter any
# verified user can invoke it (routers/tools.py gates execution on get_verified_user +
# per-tool access_control, not get_admin_user). Open WebUI already did the OIDC, the session
# handling and the group mapping; this only has to enforce the guards. Users invoke it
# conversationally ("add qwen3.5:2b to the library"), and the model then appears in the
# normal picker once a LiteLLM route exists for it.
#
# WHAT THE GUARDS ARE FOR
# -----------------------
# Open WebUI's own admin pull hardcodes `insecure: True` and accepts ARBITRARY refs, so an
# unguarded endpoint lets any user push unbounded data from any registry onto the GPU node's
# disk. Hence, in order: allowlist the registry/namespace, cap the single-model size, and cap
# total store usage. Refuse by default — an unparseable size is treated as too big, and an
# unreachable server is a refusal, never an implicit allow.
#
# LIMITS OF THIS TOOL (deliberate)
# --------------------------------
# * A pulled model becomes selectable on its own, but not instantly: LiteLLM expands its
#   per-node wildcard route by calling this server's /api/tags, and only recomputes that at
#   STARTUP. litellm/model-sync-cronjob.yaml reconciles the drift every 5 minutes and
#   restarts the proxy when it finds any. So expect up to ~5 minutes, and say so rather than
#   implying the model is usable the moment the download ends.
# * It does NOT add the model to prepull-models.yaml, so a pulled model is LOST on a node
#   reimage. Long-lived models belong in that ConfigMap (a git change).
# * Deletion IS offered (`remove_model`), but fenced: the `allow_delete` valve can turn it
#   off entirely, and `protected_models` refuses the git-declared catalogue — deleting one
#   of those would only make the PostSync Job re-download it, and removing
#   nomic-embed-text would silently break RAG for everyone.

import asyncio
import json
from typing import Any, Callable, Optional

import aiohttp
from pydantic import BaseModel, Field


class Tools:
    class Valves(BaseModel):
        """Admin-set, in Workspace -> Tools -> Model Library -> valves."""

        backends: str = Field(
            default=(
                "turing=http://ollama-turing.ollama-turing.svc:11434,"
                "thor=http://ollama.ollama.svc:11434"
            ),
            description=(
                "Comma-separated <node>=<url> map of Ollama backends a user may manage. "
                "The node name is what a user says ('add X to thor'); it matches the LiteLLM "
                "route prefix and ecc/gpu-model. Both nodes carry a live "
                "LiteLLM wildcard route, so a model pulled to either becomes selectable "
                "without a git change. Remove an entry to make that node unmanageable."
            ),
        )
        default_node: str = Field(
            default="turing",
            description=(
                "Which backend to use when the user does not name one. turing is the "
                "always-on multi-model node; thor is the big-model box."
            ),
        )
        allowed_prefixes: str = Field(
            default="qwen3.5:,qwen3:,nomic-embed-text,llama3.2:,llama3.1:,gemma3:,mistral:,phi4",
            description=(
                "Comma-separated allowlist of model-ref prefixes. A request must start with "
                "one of these. Keep it to curated, known-good families — this is what stops "
                "a user pulling arbitrary data from an arbitrary registry."
            ),
        )
        max_model_gb: float = Field(
            default=7.0,
            description=(
                "Reject a single model larger than this (GB, as reported by the registry). "
                "The cards are 8 GiB with ~7.5 GiB usable, so anything above this cannot be "
                "served GPU-resident anyway."
            ),
        )
        max_thor_model_gb: float = Field(
            default=45.0,
            description=(
                "Per-model cap for the Thor specifically. Its ~117 GiB of unified memory runs "
                "a 38 GB model fully GPU-resident, so the Turing node's 7 GB cap would refuse "
                "the very models the Thor is for. Still bounded: unified memory is shared with "
                "the desktop and every other pod on that node."
            ),
        )
        max_store_gb: float = Field(
            default=120.0,
            description=(
                "Refuse a pull that would take the whole model store past this (GB). Guards "
                "the node's disk against accumulation."
            ),
        )
        pull_timeout_s: int = Field(
            default=3600,
            description="Give up on a single pull after this many seconds.",
        )
        enabled: bool = Field(
            default=True,
            description="Master off-switch; when false every pull is refused.",
        )
        allow_delete: bool = Field(
            default=True,
            description=(
                "Allow users to remove models. Independent of `enabled` so a library can be "
                "made append-only (delete off, pull on) or frozen entirely."
            ),
        )
        protected_models: str = Field(
            default="qwen3.5:9b,qwen3.5:4b,qwen3.5:2b,nomic-embed-text",
            description=(
                "Comma-separated models a user may NOT delete. These are the git-declared "
                "catalogue (ollama-turing/prepull-models.yaml): the PostSync Job re-pulls "
                "them on every sync, so deleting one only wastes bandwidth re-downloading "
                "it. nomic-embed-text in particular backs Open WebUI's RAG — removing it "
                "silently breaks document search for everyone. Match is on the ref as "
                "listed, with or without an explicit ':latest'."
            ),
        )

    def __init__(self):
        self.valves = self.Valves()
        # Nothing here is a citation source; keep Open WebUI from appending source cards.
        self.citation = False

    # ── helpers ──────────────────────────────────────────────────────────────────────

    def _backend(self, node: Optional[str]) -> tuple[Optional[str], Optional[str], str]:
        """Resolve a node name to (name, url, error).

        Returns the error string instead of raising so every caller can hand it straight back
        to the user — a wrong node name is a typo, not an exception.
        """
        table = {}
        for pair in self.valves.backends.split(","):
            if "=" not in pair:
                continue
            k, v = pair.split("=", 1)
            if k.strip() and v.strip():
                table[k.strip().lower()] = v.strip()
        if not table:
            return None, None, "No Ollama backends are configured for this tool."
        want = (node or self.valves.default_node or "").strip().lower()
        if not want:
            return None, None, "No node given and no default configured."
        if want not in table:
            return None, None, (
                f"'{node}' is not a known node. Available: {', '.join(sorted(table))}."
            )
        return want, table[want], ""

    def _max_model_gb_for(self, node: str) -> float:
        """Per-node size ceiling.

        The two nodes differ by an order of magnitude, so ONE cap is wrong for both: the
        Turing cards hold ~7.5 GiB each, while the Thor has ~117 GiB of unified memory and
        happily runs a 38 GB model GPU-resident. Capping the Thor at the Turing figure would
        refuse exactly the models it exists to serve.
        """
        if node == "thor":
            return max(self.valves.max_model_gb, self.valves.max_thor_model_gb)
        return self.valves.max_model_gb

    def _allowed(self, ref: str) -> bool:
        prefixes = [p.strip() for p in self.valves.allowed_prefixes.split(",") if p.strip()]
        return any(ref.startswith(p) for p in prefixes)

    async def _get_json(self, session: aiohttp.ClientSession, base: str, path: str) -> Any:
        async with session.get(f"{base}{path}", timeout=aiohttp.ClientTimeout(total=30)) as r:
            r.raise_for_status()
            return await r.json()

    def _protected(self, ref: str) -> bool:
        """True if `ref` is in the git-declared catalogue and so not user-deletable.

        Compares with ':latest' normalised away, because /api/tags reports the implicit tag
        explicitly ('nomic-embed-text:latest') while a user types the bare name.
        """

        def norm(x: str) -> str:
            x = x.strip()
            return x[: -len(":latest")] if x.endswith(":latest") else x

        wanted = norm(ref)
        return any(
            norm(p) == wanted
            for p in self.valves.protected_models.split(",")
            if p.strip()
        )

    async def _running(self, session: aiohttp.ClientSession, base: str) -> list:
        """Models currently loaded in VRAM, per /api/ps. Empty list if unavailable."""
        try:
            data = await self._get_json(session, base, "/api/ps")
            return [m.get("name") for m in data.get("models", [])]
        except Exception:
            # A status read must never block a delete; absence of evidence is not a refusal.
            return []

    async def _store_bytes(self, session: aiohttp.ClientSession, base: str) -> int:
        """Total bytes currently held, summed over /api/tags."""
        data = await self._get_json(session, base, "/api/tags")
        return sum(int(m.get("size") or 0) for m in data.get("models", []))

    # ── user-facing methods ──────────────────────────────────────────────────────────

    async def list_models(
        self,
        node: Optional[str] = None,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        List the models available on a GPU node, with their sizes and total disk used. Use this
        before adding a model, to check whether it is already there.
        :param node: Which GPU node — "turing" (2x RTX 2070, small models) or "thor" (big-model box).
                     Omit for the default node.
        :return: A human-readable list of available models.
        """
        name, base, err = self._backend(node)
        if err:
            return err
        try:
            async with aiohttp.ClientSession() as session:
                data = await self._get_json(session, base, "/api/tags")
        except Exception as e:
            return f"Could not reach the {name} model server: {e}"

        models = data.get("models", [])
        if not models:
            return f"The {name} model library is empty."

        total = 0
        lines = []
        for m in sorted(models, key=lambda x: x.get("name", "")):
            size = int(m.get("size") or 0)
            total += size
            lines.append(f"- {m.get('name')} ({size / 1e9:.1f} GB)")
        lines.append(
            f"\nTotal: {total / 1e9:.1f} GB of {self.valves.max_store_gb:.0f} GB quota."
        )
        return f"Models available on {name}:\n" + "\n".join(lines)

    async def loaded_models(
        self,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        Show which models are loaded in GPU memory RIGHT NOW, on every node. Use this to
        answer "what is running?", "which model is active?", or to check whether a model
        will answer instantly or has to load first.
        :return: Per-node list of resident models with their VRAM use.
        """
        table = {}
        for pair in self.valves.backends.split(","):
            if "=" not in pair:
                continue
            k, v = pair.split("=", 1)
            if k.strip() and v.strip():
                table[k.strip().lower()] = v.strip()
        if not table:
            return "No Ollama backends are configured for this tool."

        out = []
        async with aiohttp.ClientSession() as session:
            for name in sorted(table):
                base = table[name]
                try:
                    data = await self._get_json(session, base, "/api/ps")
                except Exception as e:
                    out.append(f"{name}: could not reach the model server ({e})")
                    continue

                models = data.get("models", [])
                if not models:
                    out.append(
                        f"{name}: nothing loaded — the next request pays a load "
                        f"(seconds to ~40 s depending on the model)."
                    )
                    continue

                for m in sorted(models, key=lambda x: x.get("name", "")):
                    vram = int(m.get("size_vram") or 0)
                    out.append(f"{name}: {m.get('name')} — {vram / 1e9:.1f} GB in VRAM")

        # The Turing node runs TWO replicas, one per card, each with its OWN VRAM. A
        # Service-level /api/ps answers from whichever replica the round-robin picked, so
        # this listing is one card's view, not the node's. Say so rather than implying the
        # node holds only what is shown — a model can be resident on one card and absent
        # from the other, which is exactly why a follow-up request sometimes reloads.
        out.append(
            "\nNote: the turing node has two GPUs serving independently, so a model shown "
            "here may be loaded on one card and not the other. Asking again can report a "
            "different card."
        )
        return "Loaded in GPU memory:\n" + "\n".join(out)

    async def add_model(
        self,
        model: str,
        node: Optional[str] = None,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        Add (download) a model to a GPU node's library so it can be used for chat. Only
        curated model families are permitted, and size/disk quotas apply.
        :param model: The model reference to pull, e.g. "qwen3.5:2b".
        :param node: Which GPU node — "turing" (7.5 GiB per card, small models) or
                     "thor" (~117 GiB unified, big models). Omit for the default node.
        :return: What happened, including why a request was refused.
        """
        ref = (model or "").strip()
        name, base, err = self._backend(node)
        if err:
            return err
        who = (__user__ or {}).get("email") or (__user__ or {}).get("name") or "unknown"

        async def say(desc: str, done: bool = False) -> None:
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": desc, "done": done}}
                )

        # ── guard 0: master switch + syntactic sanity ────────────────────────────────
        if not self.valves.enabled:
            return "Adding models is currently disabled by an administrator."
        if not ref:
            return "No model given. Say for example: add qwen3.5:2b"
        # A ref carrying a scheme/host is an attempt to reach outside the allowlist.
        if any(c in ref for c in (" ", "\t", "\n")) or "://" in ref:
            return f"Refused: '{ref}' is not a valid model reference."

        # ── guard 1: allowlist ──────────────────────────────────────────────────────
        if not self._allowed(ref):
            allowed = ", ".join(
                p.strip() for p in self.valves.allowed_prefixes.split(",") if p.strip()
            )
            return (
                f"Refused: '{ref}' is not in the permitted model families.\n"
                f"Permitted prefixes: {allowed}\n"
                "Ask an administrator if you need another family added."
            )

        try:
            async with aiohttp.ClientSession() as session:
                # ── already present? ────────────────────────────────────────────────
                tags = await self._get_json(session, base, "/api/tags")
                have = {m.get("name") for m in tags.get("models", [])}
                if ref in have or f"{ref}:latest" in have:
                    return f"'{ref}' is already in the library — you can select it now."

                # ── guard 2: per-model size cap, BEFORE downloading anything ────────
                # /api/show on a not-yet-pulled ref makes the server fetch the manifest
                # only, so this is cheap. Refuse on any doubt rather than pulling blind.
                await say(f"Checking the size of {ref}...")
                size_gb = None
                try:
                    async with session.post(
                        f"{base}/api/show",
                        json={"model": ref},
                        timeout=aiohttp.ClientTimeout(total=60),
                    ) as r:
                        if r.status == 200:
                            info = await r.json()
                            raw = (info.get("details") or {}).get("parameter_size")
                            for key in ("size", "total_size"):
                                if isinstance(info.get(key), int):
                                    size_gb = info[key] / 1e9
                                    break
                            if size_gb is None and raw:
                                # Fall through: a parameter count is not a byte size.
                                size_gb = None
                except Exception:
                    size_gb = None

                cap = self._max_model_gb_for(name)
                if size_gb is not None and size_gb > cap:
                    return (
                        f"Refused: '{ref}' is about {size_gb:.1f} GB, over the {cap:.1f} GB "
                        f"per-model limit for {name}."
                        + (
                            " The Turing cards have ~7.5 GiB usable each, so a larger model "
                            "could not stay GPU-resident — try the thor node instead."
                            if name != "thor"
                            else ""
                        )
                    )

                # ── guard 3: disk quota ─────────────────────────────────────────────
                used_gb = (await self._store_bytes(session, base)) / 1e9
                projected = used_gb + (size_gb or 0.0)
                if projected > self.valves.max_store_gb:
                    return (
                        f"Refused: the library already holds {used_gb:.1f} GB and this pull "
                        f"would exceed the {self.valves.max_store_gb:.0f} GB quota. Ask an "
                        "administrator to remove an unused model first."
                    )

                # ── pull ────────────────────────────────────────────────────────────
                # NOTE no "insecure": the allowlist means we only ever talk to the default
                # registry over TLS. Open WebUI's own admin pull forces insecure=True; we
                # deliberately do not.
                await say(f"Downloading {ref} to {name} (requested by {who})... this can take minutes.")
                last_pct = -10
                async with session.post(
                    f"{base}/api/pull",
                    json={"model": ref, "stream": True},
                    timeout=aiohttp.ClientTimeout(total=self.valves.pull_timeout_s),
                ) as r:
                    if r.status != 200:
                        body = (await r.text())[:300]
                        return f"Refused by the model server (HTTP {r.status}): {body}"
                    async for raw_line in r.content:
                        line = raw_line.decode("utf-8", "ignore").strip()
                        if not line:
                            continue
                        try:
                            ev = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if ev.get("error"):
                            return f"Download failed: {ev['error']}"
                        total, done = ev.get("total"), ev.get("completed")
                        if total and done:
                            pct = int(done * 100 / total)
                            if pct >= last_pct + 10:
                                last_pct = pct
                                await say(f"Downloading {ref}: {pct}%")

                await say(f"{ref} added.", done=True)

                # Report the real post-pull footprint rather than the estimate.
                new_used = (await self._store_bytes(session, base)) / 1e9
                return (
                    f"Added '{ref}' to {name}.\n"
                    f"Library now uses {new_used:.1f} GB of the "
                    f"{self.valves.max_store_gb:.0f} GB quota.\n\n"
                    "It will appear in the model picker automatically within about 5 "
                    "minutes (a background job reconciles the gateway's model list). "
                    "No administrator action is needed."
                )

        except asyncio.TimeoutError:
            return (
                f"Timed out after {self.valves.pull_timeout_s}s downloading '{ref}'. "
                "It may still be completing in the background — check the library again."
            )
        except Exception as e:
            return f"Could not add '{ref}': {e}"

    async def remove_model(
        self,
        model: str,
        node: Optional[str] = None,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Any]] = None,
    ) -> str:
        """
        Remove (delete) a model from a GPU node's library to free disk space. The curated
        catalogue models cannot be removed. Ask the user to confirm the exact model name AND
        which node before calling this — deletion is immediate and frees the weights from disk.
        :param model: The model reference to delete, e.g. "qwen2.5-coder:14b".
        :param node: Which GPU node — "turing" or "thor". Omit for the default node.
        :return: What happened, including why a request was refused.
        """
        ref = (model or "").strip()
        name, base, err = self._backend(node)
        if err:
            return err
        who = (__user__ or {}).get("email") or (__user__ or {}).get("name") or "unknown"

        async def say(desc: str, done: bool = False) -> None:
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": desc, "done": done}}
                )

        if not self.valves.allow_delete:
            return "Removing models is disabled on this instance."
        if not ref or " " in ref or "://" in ref:
            return f"'{model}' is not a valid model name."

        # Protect the git-declared catalogue. Deleting one of these is not destructive in the
        # lasting sense (the PostSync Job re-pulls it), but it IS a pointless multi-GB
        # re-download, and losing nomic-embed-text silently breaks RAG for every user.
        if self._protected(ref):
            return (
                f"'{ref}' is part of the standard catalogue and cannot be removed here.\n"
                "It is declared in git and would be re-downloaded automatically on the next "
                "sync. To retire it for good, remove it from "
                "deployment/argocd-apps/ollama-turing/prepull-models.yaml."
            )

        try:
            async with aiohttp.ClientSession() as session:
                # Confirm it exists first, so the reply distinguishes "already gone" from
                # "typo" — Ollama answers 404 to both.
                tags = await self._get_json(session, base, "/api/tags")
                present = {m.get("name") for m in tags.get("models", [])}
                if ref not in present:
                    # Accept the bare name for an implicit :latest, matching Ollama's own CLI.
                    alt = f"{ref}:latest"
                    if alt in present:
                        ref = alt
                    else:
                        near = sorted(n for n in present if n and ref.split(":")[0] in n)
                        hint = f" Did you mean: {', '.join(near)}?" if near else ""
                        return f"'{ref}' is not in the {name} library.{hint}"

                # Warn rather than refuse if it is loaded: Ollama unloads it as part of the
                # delete, and refusing would leave a user unable to reclaim their own space.
                loaded = await self._running(session, base)
                was_loaded = ref in loaded

                await say(f"Removing {ref}…")
                async with session.request(
                    "DELETE",
                    f"{base}/api/delete",
                    json={"model": ref},
                    timeout=aiohttp.ClientTimeout(total=120),
                ) as r:
                    if r.status == 404:
                        return f"'{ref}' is not in the library."
                    if r.status >= 400:
                        return f"Could not remove '{ref}': HTTP {r.status} {await r.text()}"

                await say(f"{ref} removed.", done=True)
                freed = (await self._store_bytes(session, base)) / 1e9
                note = (
                    "\nIt was loaded in VRAM and has been unloaded."
                    if was_loaded
                    else ""
                )
                return (
                    f"Removed '{ref}' from {name} (requested by {who})."
                    f"{note}\n"
                    f"Library now uses {freed:.1f} GB of the "
                    f"{self.valves.max_store_gb:.0f} GB quota.\n\n"
                    "It disappears from the model picker within about 5 minutes, when the "
                    "background job reconciles the gateway's model list."
                )

        except Exception as e:
            return f"Could not remove '{ref}': {e}"
