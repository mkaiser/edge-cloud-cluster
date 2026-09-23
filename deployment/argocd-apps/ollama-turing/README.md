# ollama-turing — Ollama on the discrete-GPU mesh node

Serves GGUF models on **smartmirror1** (2x RTX 2070, Turing sm_75, 8 GiB each).
Fronted by LiteLLM (`turing/*` routes); the only client is that gateway.

Distinct from the `ollama` app, which is **Thor-only** (aarch64, CI-built image,
mutually exclusive with vLLM, hand-switched). Here the cards are discrete and pods hold
real `nvidia.com/gpu` allocations, so **the scheduler** enforces one pod per card — there
is nothing to switch.

## Shape

| | |
|---|---|
| replicas | **2**, one GPU each (`nvidia.com/gpu: 1`) |
| image | upstream `ollama/ollama` (x86_64 — no CI build needed) |
| model store | `hostPath /var/lib/ollama-models`, **shared** by both pods |
| catalogue | `prepull-models.yaml` ConfigMap + PostSync Job |
| routes | one live `turing/*` wildcard in `litellm/config.yaml` (expands from /api/tags) |

Measured on this hardware: `qwen3.5:9b` @ 8192 ctx loads **34/34 layers to GPU**,
5.6 GB resident, `100% GPU`, against ~7.5 GiB usable. KV is only 256 MiB because the
architecture is hybrid/recurrent (8 of 34 layers hold a cache) — do not assume that for a
plain transformer.

## How model selection works

Ollama keeps every pulled model on disk and loads/evicts on demand
(`OLLAMA_MAX_LOADED_MODELS` + `OLLAMA_KEEP_ALIVE` + LRU). **A user picking a model in Open
WebUI is what "deploys" it** — no redeploy, no scaling, no switch script. Verified: loading
the 4b auto-evicted the 9b, both at `100% GPU`.

### Adding a model — just pull it

**There is no per-model configuration.** LiteLLM carries a single `turing/*` route, which it
expands by calling the provider's own `get_models()` → `GET /api/tags` on this server. So
anything present on the node is offered automatically:

```bash
kubectl exec -n ollama-turing deploy/ollama-turing -- ollama pull qwen3.5:2b
```

…and it appears in `/v1/models`, and therefore in Open WebUI's picker, with **no commit and
no LiteLLM restart**. Chat users can do the same through the Model Library tool (below).

Two caveats, neither a fault:

- **Up to ~5 minutes of lag, and a CronJob is what closes it.** The running proxy recomputes
  its model list only at STARTUP — measured, a model pulled at t=0 was still absent at
  **t=635s** and appeared immediately after a restart (so the documented
  `AvailableModelsCache` `ttl_seconds=300` does not refresh the listing in practice).
  `litellm/model-sync-cronjob.yaml` reconciles this every 5 min: it compares `/api/tags`
  against `/v1/models` and restarts LiteLLM **only on drift**, so an idle cluster does
  nothing. To skip the wait: `kubectl rollout restart deploy/litellm -n litellm`.
- **`turing/*` itself shows up in the picker.** Selecting it errors. Hide it per-model in
  Open WebUI's admin UI if it bothers people.

Still add long-lived models to `prepull-models.yaml`: that ConfigMap is what makes a **fresh
or reimaged node** repopulate itself. Pulling without it works, but the model is lost on
reimage.

> **Use the `ollama_chat/*` provider, never `openai/*`.** With `openai/*` LiteLLM expands the wildcard from
> OpenAI's entire built-in STATIC catalogue — measured at **374 phantom models** (`gpt-*`,
> `o1-*`, `dall-e`, `tts-*`), none of which exist here, drowning the real ones in the picker.
> `get_known_models_from_wildcard()` takes the provider from `litellm_params.model`, so the
> prefix is the whole difference: an `ollama/`-provider wildcard resolves to a live
> `/api/tags` call instead. (The ROUTE is named `turing/*`; only `litellm_params.model`
> carries the `ollama/` provider — see the naming note in litellm/config.yaml.)
> Requires `check_provider_endpoint: true` plus the `OLLAMA_API_BASE` env var (the listing
> path has no deployment context and would otherwise probe localhost).

## Letting chat users add models themselves (optional)

`tools/model_pull.py` is an Open WebUI **Tool**. Stock Open WebUI gates `/api/pull` behind
`get_admin_user`, so a normal user cannot add a model; a Tool is installed from git and is
callable by any verified user (`get_verified_user` + per-tool access control).
That avoids standing up a service with its own OIDC, UI and RBAC.

It enforces, in order: an **allowlist** of model-ref prefixes, a **per-model size cap**, and
a **total disk quota** — refusing by default. This matters because Open WebUI's own admin
pull hardcodes `insecure: True` and accepts arbitrary refs, so an unguarded endpoint lets any
user push unbounded data from any registry onto the GPU node's disk. This tool sends no
`insecure` flag.

### Install — automated

`open-webui/postsync-install-tools.yaml` installs this on every sync via
`POST /api/v1/tools/create`, which computes `specs` server-side, so a recreate needs no
human. Sources here are the truth; `open-webui/tools-configmap.yaml` is generated from them
by `open-webui/sync-tools.sh` (run it after editing, `--check` proves sync).

`open-webui/postsync-hide-wildcard-model.yaml` then attaches the tool to every model
(`meta.toolIds`) — without that a model is offered NO tools and answers "I don't have a
tool to do that", however correctly the tool is installed.

Still human decisions:

1. **Access**: share it with the group that should be able to add models (e.g. `ai`).
   Leave it private to admins if you do not want self-service.
2. Optionally tune valves (**Workspace → Tools → Model Library → valves**):
   `allowed_prefixes`, `max_model_gb`, `max_thor_model_gb` (the Thor's ~117 GiB needs its
   own, larger cap), `max_store_gb`, `allow_delete`, `protected_models`, and `enabled` as a
   master off-switch.

**It manages BOTH GPU nodes.** `list_models`, `add_model` and `remove_model` all take a
`node` argument (`turing` or `thor`, default `turing`), resolved from the `backends`
valve — a `<node>=<url>` map. Since both nodes now carry a live LiteLLM wildcard route
(`turing/*` and `thor/*`), a model pulled to either becomes selectable with no git change.
Per-model size caps are **per node**: 7 GB on the Turing cards (7.5 GiB usable each) versus
45 GB on the Thor, whose ~117 GiB of unified memory runs a 38 GB model GPU-resident — one
shared cap would have refused exactly the models the Thor exists to serve. Verified live: a
pull, a catalogue-protection refusal, and a delete, all against Thor.

It also exposes `remove_model`, so a user can reclaim disk space without an admin. Deletion
is `DELETE /api/delete` on Ollama (verified: 200 then gone from `/api/tags`; 404 for an
unknown ref). Guards, in order:

* **`protected_models`** — the git-declared catalogue (`prepull-models.yaml`) is refused.
  Deleting one is not permanently destructive, since the PostSync Job re-pulls it, but it is a
  pointless multi-GB re-download, and dropping `nomic-embed-text` would silently break RAG for
  every user. Matching normalises `:latest`, so `nomic-embed-text` and
  `nomic-embed-text:latest` are both protected.
* **`allow_delete`** — separate from `enabled`, so the library can be made append-only
  (pull yes, delete no) or frozen entirely.
* An unknown ref returns a **typo hint** listing near matches rather than a bare 404, because
  Ollama answers 404 to both "gone" and "never existed".
* A model loaded in VRAM is **warned about, not refused** — Ollama unloads it as part of the
  delete, and refusing would leave a user unable to reclaim their own space.

No LiteLLM route is created, because none is needed: the `turing/*` wildcard expands from
the live `/api/tags`, so a pulled model becomes selectable on its own within ~5 min (the
model-sync CronJob restarts the gateway when it sees the drift). The tool's success message
says so.

## Switching backend / node from the chat UI (optional)

`tools/llm_backend_switch.py` is the second Open WebUI **Tool**. It answers the runtime
"high throughput vs high flexibility" question without a git commit: it reports and scales the
serving Deployments on both GPU nodes.

| It can | It cannot |
|---|---|
| scale Ollama or vLLM up/down, per node | change which model vLLM serves — that is a startup CLI arg (`--model`), so N models needs N Deployments |
| switch smartmirror1 between **2 pods x 1 GPU** and **1 pod x 2 GPUs** (`set_gpu_mode`) | double-book a GPU — both backends request `nvidia.com/gpu`, so the scheduler enforces exclusivity and the worst case is a `Pending` pod |
| report which backend owns each node's GPU(s) | switch without a gap — see below |
| refuse cleanly when a target is not deployed (vLLM is currently disabled) | |

`set_gpu_mode("concurrency"|"large")` was initially thought to be commit-only, on the grounds
that the GPU count is a pod-template field rather than a replica count. That is true, but
`patch` on a Deployment already covers the template, so no extra RBAC was needed — only two
more `ignoreDifferences` pointers. Three things to know:

* Replicas and card count move in **one patch**: 2 replicas x 2 GPUs would need 4 cards on a
  2-card node, so the intermediate state is unschedulable.
* **The switch has a gap, and that is unavoidable.** `maxSurge` stays 0 (a surge pod on a
  fully-booked node has no card and deadlocks the rollout) and `maxUnavailable` rises to the
  replica count, so the old generation is torn down *before* the new one starts. Roughly a
  minute or two with nothing served, plus a cold model load on the first request.
  Leaving `maxUnavailable` at 1 **deadlocks the 1x2 -> 2x1 direction**: the controller keeps
  the old 2-GPU pod (it satisfies availability) and tries to schedule a 1-GPU pod with zero
  free cards — measured Pending for 7+ minutes until the old pod was deleted by hand. On a
  2-card node a GPU-count change cannot be done without an interruption.
* The patch names the container from the **live spec**, never the Deployment name. Strategic
  merge keys containers by name and silently *appends* on a mismatch; getting this wrong once
  created a phantom container that asked for 2+1=3 GPUs and looked exactly like a stale device
  plugin.

Two prerequisites, both already in git:

* `llm-backend-switch-rbac.yaml` in `deployment/argocd-apps/open-webui/` — a namespaced Role
  per GPU namespace granting the Open WebUI pod's `default` ServiceAccount `get`+`patch` on
  the one named Deployment (plus `list` on pods, for the status report). No cluster scope, no
  create, no delete, no exec. The pod's mounted SA token is the only credential; the tool
  adds none.
* `ignoreDifferences` on `/spec/replicas` + `RespectIgnoreDifferences` on both GPU
  Applications. Without it selfHeal reverts a scale within seconds — measured, it evicted a
  test pod mid-download. Suspending the child Application's `syncPolicy` does **not** work
  instead: the app-of-apps re-applies it from git.

### Install — automated, but sharing is not

Installed by the same PostSync Job as the Model Library tool above.

1. **Access**: share it with `authentik-admins` **only**. Unlike adding a model, scaling a
   backend affects every user of that node, so it is not a per-user action.
2. Ask in a chat: *"what LLM backends are running?"*, or
   *"switch the turing node to ollama"*.

Enabling vLLM later needs the matching Role/RoleBinding added to the **vllm app's own**
folder — deliberately not created from the open-webui app, or the two would fight over
ownership of the namespace object.

## Gotchas

- `maxSurge` **must** be 0: 2 replicas on exactly 2 GPUs means a surge pod has no card and
  the rollout deadlocks on `Pending`.
- The two replicas load models **independently**, so a follow-up request may land on the
  replica that has not loaded that model and pay a second cold load. `sessionAffinity` would
  not help (LiteLLM is the only client, so all traffic shares one source IP). If it matters,
  split into two Services + two routes.
- `NVIDIA_VISIBLE_DEVICES=void` inside the pod is **normal and working** — the node runs
  runtime `mode=auto` and the container toolkit auto-generates a CDI spec, so injection goes
  via CDI. Check `nvidia-smi -L` in the pod, not the env var. See

- The model store is node-local and disposable. A node reimage wipes it; the PostSync Job
  re-pulls the catalogue.
