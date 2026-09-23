# open-webui

Web chat UI, Authentik-OIDC only, talking to models exclusively through the LiteLLM gateway
(`ENABLE_OLLAMA_API=false`) so budgets, model ACLs and spend attribution all hold.

## Tools are installed from git, not pasted by hand

`postsync-install-tools.yaml` installs the Open WebUI **Tools** on every sync, so a cluster
recreate needs no human in the loop. Sources live in `../ollama-turing/tools/*.py`; the
mirror `tools-configmap.yaml` is GENERATED — run `./sync-tools.sh` after editing a source and
`./sync-tools.sh --check` to prove it is in sync.

### Why the REST API rather than a DB insert

The `tool` table's `specs` column is computed AT WRITE TIME and never recomputed on read. Its
shape comes from LangChain's `convert_to_openai_function` at a pinned version plus two Open
WebUI cleanup passes, so hand-computing it in psql rots on any image bump — and it fails
QUIETLY: `ToolModel.specs` is a required `list[dict]`, so one bad row makes `get_tools()` fail
validation and return `[]`, hiding EVERY tool. Same class of bug as the NULL `user_id` already
documented in `postsync-hide-wildcard-model.yaml`.

`POST /api/v1/tools/create` computes `specs` server-side and validates the module **by
executing it**, so the row is always correct for the running image. Verified: 4 functions
registered for model_library and 3 for llm_backend_switch, and a re-run updates instead of erroring.

### Rejected alternatives

| approach | why not |
|---|---|
| ConfigMap of `.py` files read at boot | **Does not exist.** No `TOOLS_DIR` anywhere in the backend; `load_tool_module_by_id` reads only from the DB. |
| `TOOL_SERVER_CONNECTIONS` (OpenAPI tool servers) | Declarative only on a VIRGIN DB — `Config.seed_defaults` skips existing keys, so later git edits are silently ignored unless `ENABLE_PERSISTENT_CONFIG=false` cluster-wide. Also means rewriting both tools as an HTTP service, losing `Valves` and `__user__`/`__event_emitter__`. |
| An Open WebUI API key | `ENABLE_API_KEYS` defaults **false**; enabling it widens the auth surface cluster-wide to bootstrap two rows. |
| Direct `tool` INSERT | The `specs` problem above. Note `JSONField` is TEXT-backed, so it also needs a JSON *string*, not jsonb. |

### Auth, and the one case where it no-ops

A short-lived JWT signed with `WEBUI_SECRET_KEY` — the same sealed secret the app uses. The
Job runs in the app's own image, so `create_token` is the app's own code rather than a
reimplementation of its token format.

A tool row must be owned by a **real** admin user (see the `specs` note), and on an OIDC-only
instance nobody exists until someone logs in. The Job detects that, prints why, and **exits
0** — the next sync after the first admin login installs the tools. It is not a failure.

## The welcome banner and prompt suggestions are also installed from git

`postsync-welcome-config.yaml` publishes the top-of-chat banner and the clickable
suggestions on the empty chat screen. They are the ONLY place the UI tells a user that the
Model Library tool exists — the tools are invoked conversationally, so nothing else
advertises them.

⚠ `WEBUI_BANNERS` / `DEFAULT_PROMPT_SUGGESTIONS` as env vars would be silently ignored
here: both are PersistentConfig keys, and `Config.seed_defaults` only writes keys that are
absent, so on this long-established DB a git edit never lands. The Job POSTs to
`/api/v1/configs/{banners,suggestions}` instead. Edit the text in that file — an admin's
hand-edit in the UI is overwritten on the next sync.

## The default model is set declaratively

`postsync-welcome-config.yaml` also sets `ui.default_models` to `thor/qwen3-coder:30b` —
the fastest coder in the cluster and always resident. Without it Open WebUI starts a new
chat on whatever sorts first, which was `coder-ollama`: a `qwen35moe` MoE that llama.cpp
cannot batch, so concurrent requests serialise on one slot and a one-word prompt can take
57 s while the model's own decode takes 6 s. Same PersistentConfig caveat as the banner —
it is a DB key, so an env var would be ignored.

## Installing a tool does NOT make a model use it

This bit us: both tools were installed and registered, and the model still answered *"I
don't have a tool to list available models"*. Installation and **attachment** are separate.

`utils/middleware.py` gates the entire tool path on `if tool_ids:`, and the frontend fills
`tool_ids` only from `model.info.meta.toolIds` (`Chat.svelte`, "Set Default Tools"). With no
such row a model is handed no tools at all. A user can also tick a tool per chat in the UI,
but that is per user, per chat, and does not survive a recreate.

`postsync-hide-wildcard-model.yaml` writes those rows, for every model the gateway
advertises (discovered at run time — a hardcoded list would go stale on the next
`ollama pull`). The row shape matters, and it differs from the hide by ONE field:

| base_model_id | is_active | effect (`utils/models.py`) |
|---|---|---|
| NULL | false | model is REMOVED from the picker — the hide |
| NULL | true | `model['info']` = the override, which is what carries `meta.toolIds` |
| set | true | a SEPARATE, ADDITIONAL picker entry — duplicates the model |

⚠ So an attach row is `base_model_id NULL` + `is_active true`. Setting `base_model_id`
duplicates every model in the picker instead of decorating it.

### After install: sharing is still a human decision

Installing does not share. Set access per tool in the UI:

| tool | share with | why |
|---|---|---|
| Model Library | the `ai` group, or all users | guarded by allowlist + size cap + disk quota |
| LLM Backend Switch | `authentik-admins` **only** | scaling a backend affects every user of that node |
