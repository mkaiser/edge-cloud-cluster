# Ryax — first steps as a user

How to log in and get from a fresh `ryax-engine` install to a workflow that
actually runs. For *why* the deployment looks the way it does (the chart's
ArgoCD-hostile bits, the admission policies, the worker's placement), see
[README.md](README.md).

## TL;DR

```bash
# 1+2. Site, Node Pools and the worker release — fully automated.
# Node names are exactly as `kubectl get nodes` prints them.
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh unibi-hclab-pcie-tb-s unibi-hclab-pcie-tb-d

# credentials for the UI
kubectl get secret -n ryaxns ryax-admin-credentials \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret -n ryaxns ryax-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d; echo
```


## Log in

`https://ryax.<tld>/app/` — the TLD from `project_settings.ts` (`general.tld`).

| | |
|---|---|
| user | `admin` |
| password | read it from the cluster (below) |

```bash
kubectl get secret -n ryaxns ryax-admin-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

This is a **local Ryax account**, provisioned on first boot from
`ryax-admin-credentials-sealed.yaml` via `authorization.extraEnv` in
[values.yaml](values.yaml). It is **not** Authentik SSO: Ryax has no OIDC support,
so the Authentik portal tile is only a bookmark that lands on this same login
form. The `ryax` group and `access-ryax` policy created by
[authentik-provider.yaml](authentik-provider.yaml) gate who *sees the tile*, not
who can log in.

## Step 1+2 — Site, Node Pools, worker release

**Nothing works before this.** Ryax cannot run an action until a **Site** exists,
and the `ryax-engine` chart contains no worker at all (ten subcharts, none of them
one). Until a worker release is installed, `GET /runner/sites` returns an empty
list, the **Deploy** tab offers nothing, and no action can be deployed anywhere.
So do not start by building a workflow — it would have nowhere to go.

[manageWorker.sh](scripts/manageWorker.sh) takes the node names, exactly as
`kubectl get nodes` prints them:

```bash
# add nodes (repeatable — existing ones are kept)
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh unibi-hclab-pcie-tb-s unibi-hclab-pcie-tb-d

# just provisioned one more? hand Ryax its name
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh unibi-hclab-pcie-tb-x

bash deployment/argocd-apps/ryax/scripts/manageWorker.sh --list              # what is registered
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh --remove <node>     # stop using one

# a node at another site — the Site defaults to unibi-hclab, so say so explicitly
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh --site budapest-emdc budapest-emdc-node7
```

⚠ **A Ryax "Site" is not the `ecc/site` label.** It is a Ryax scheduling target with its own
id in the Runner's database; `ecc/site` is this cluster's failure/latency domain. They happen
to share the name `unibi-hclab` and nothing keeps them in step.

⚠ **`--site` chooses a Site at CREATE time; it does not MOVE a node.** An existing Site is
looked up by name, so re-running a registered node under a different `--site` creates a
SECOND Site and a second pool for it. The Sites API has no pool delete. To move a node,
`--remove` it under its current Site's name first, then add it under the new one.

What it does, idempotently:

1. port-forwards to `ryax-runner` and `ryax-authorization` (so it works before
   the HTTPRoute/TLS is up, and keeps the admin JWT off the network),
2. logs in as the admin from the sealed secret,
3. creates the Site `unibi-hclab` — or adopts it if it already exists, or falls
   back to a timestamped name if the name is spent (see the caveat below),
4. creates **one Node Pool per node named**, reading `cpu`/`memory` straight
   from that node's `.status.allocatable` and scaling by `RYAX_POOL_SHARE`
   (default `0.6`, because these nodes are shared with Longhorn, the EDA runners
   and the gVisor desktops),
5. generates the `config.site` block and passes it to Helm as a second `-f`
   layer on top of [worker-values.yaml](worker-values.yaml),
6. `helm upgrade --install ryax-worker … --wait`.

**Adding a node never disturbs the others.** The current pool set is read back
from the live worker ConfigMap and merged with the arguments, so a node already
registered keeps its existing NodePool id (no duplicate pool), and a node not
named on this run is kept rather than dropped. `--remove` takes one out of the
worker's config; it deliberately does **not** delete the Ryax Node Pool object,
because there is no delete-pool API and the pool carries run history.

It refuses two things up front, before changing anything:

- a name that is not a node in `kubectl get nodes`;
- a **GPU node with no free card.** GPU nodes themselves are allowed —
  `ryax-placement` patch 3 tolerates `ecc/gpu=true:NoSchedule`, and the pool is
  registered with its free-card count so Ryax can schedule GPU actions onto it. But a
  node whose cards are all requested (e.g. by ollama-turing) would only ever produce
  `Pending` pods on "Insufficient nvidia.com/gpu", which looks like a Ryax fault. Free
  one with the `1x1-GPU` mode in `app-of-apps/ollama-turing.yaml` first. The Jetson Thor
  is refused unconditionally (aarch64; Ryax builds x86_64 images).

It also refuses a `--remove` that would leave the worker with no pools at all.

Overrides: `RYAX_SITE_NAME`, `RYAX_POOL_SHARE`.

⚠ **Site names are permanently spent.** They carry a unique constraint
(`sites_name_key`) and **archiving does not free the name**: an archived site
disappears from `GET /sites`, so nothing can see or adopt it, yet re-using its name
fails with a bare-text **500 "Server got itself in trouble"** whose real cause
(`psycopg2 UniqueViolation`) only shows up in the runner log. There is no API to
list or purge archived sites. The script therefore retries with a `-<timestamp>`
suffix instead of failing — harmless, since the worker binds to the site *id* and
the name is cosmetic. If you see a suffixed name in the UI, that is why.

Verify:

```bash
kubectl get pods -n ryaxns | grep ryax-worker    # Running, on a unibi-hclab node
```

The Site then appears in the UI at **Infrastructure**
(`/app/infrastructure`) and in each action's **Deploy** tab.

### Doing it by hand instead

The upstream docs present this as a UI walkthrough, and you can still follow it —
[worker-values.yaml](worker-values.yaml) keeps its `REPLACE-WITH-…` placeholders
for exactly that. Infrastructure → new Site (type **Kubernetes**) → two Node
Pools, then paste the three IDs and run the `helm upgrade` from
[README.md](README.md#the-one-manual-step-site-and-node-pool-ids).

Per-node figures for the form (allocatable; enter less, see below):

| Pool | cpu | memory | arch |
|---|---|---|---|
| `unibi-hclab-pcie-tb-s` | 24 | 30.5 GiB | amd64 |
| `unibi-hclab-pcie-tb-d` | 20 | 30.0 GiB | amd64 |

**One pool per node, and not `ecc/site: unibi-hclab`.** Ryax stores the figures you
register and schedules against them, so a pool spanning differently-sized nodes
makes every placement decision wrong — and these three differ by 5-6x.
`unibi-hclab-fs-vm` is left out of the recommended set because it is the fileserver
VM, not because the script rejects it: pass its name if you do want actions there
and it gets its own pool with its own figures. Register **less** than allocatable;
that is what `RYAX_POOL_SHARE` is for.

## Step 3 — get an action in

Ryax imports actions by **scanning a git repository** — there is no "upload a
directory" path. You do **not** need to publish anything: Ryax maintains a public
repo of ready-made actions and triggers, clonable anonymously.

UI → **Library → Repositories → Add**:

| | |
|---|---|
| URL | `https://gitlab.com/ryax-tech/workflows/default-actions.git` |
| credentials | none needed (public; the quickstart's `anonymous`/`anonymous` also works) |

Then **New Scan**. It finds 33 actions and 13 triggers, including the two used
below. **Build** the ones you want — the action-builder packages each with nix and
pushes it to `ryax-registry:5000`. The first build pulls nixpkgs, so allow a few
minutes.

Recommended for a first run:

- **`echo`** (*Echo inputs into outputs*) — purpose-built for this: it declares one
  input and one output of every Ryax type and echoes them straight through, so it
  exercises IO wiring and type handling with nothing to configure. Its own
  description says "For testing purpose!".
- **`print_env`** (*Print Environment*) — dumps every environment variable and the
  working directory of the action pod. Useful precisely once: it tells you which
  downward-API variables the worker actually injects (see the `node_name` note
  below). It declares no inputs/outputs and returns nothing, so it only prints to
  the run log — do not wire it into a chain.
- **`http_api_json`** (*HTTP API JSON*, a trigger) — starts a run from an HTTP POST.

### The local example, if you want a placement probe

[example-action/](example-action/) (`mesh-hello`) is ours rather than upstream's,
and it exists for one thing the stock actions do not do: it returns `node_name`,
`pod_name` and `architecture` as **outputs**, so which node ran the action is
visible in the run result instead of buried in a log. Using it does require
pushing it to a repo Ryax can reach (the in-cluster GitLab works; read-only deploy
token if private). Skip it unless you want that probe — `echo` plus
`kubectl get pods -n ryaxns-execs -o wide` gets you the same confidence.

#### Using `mesh-hello` (UI)

1. **Push it somewhere Ryax can reach it.** Ryax imports actions by *scanning a
   git repository* — there is no "upload a directory" path, so
   [example-action/](example-action/) must live in a repo first:

   ```bash
   # in-cluster GitLab works; make a project there first, then:
   cd deployment/argocd-apps/ryax/example-action
   git init -b main
   git add ryax_handler.py ryax_metadata.yaml
   git commit -m "mesh-hello"
   git remote add origin https://gitlab.<tld>/<group>/mesh-hello.git
   git push -u origin main   # read-only deploy token if the project is private
   ```

2. UI → **Library → Repositories → Add** — name + the clone URL above (+
   credentials if private) → **New Scan**. `Mesh Hello` appears in the results.
3. **Build** it. Standard-library-only + no `dependencies:` in
   `ryax_metadata.yaml` keeps the first nix build to a couple of minutes instead
   of the tens a real dependency set costs.
4. New workflow → add the **HTTP API JSON** trigger → add **Mesh Hello** → link
   the trigger's output to the `message` input (see Step 4 below for the exact
   link direction and required trigger fields — the same wiring `echo` needs).
5. **Deploy** tab → pick the Site / Node Pool that includes your worker → Deploy
   → trigger it.
6. Check the run's `node_name` output. It must be one of the mesh nodes you
   registered with `manageWorker.sh` — if it isn't, the pool selector and the
   `ryax-placement` policy disagree, see
   [README.md](README.md#which-nodes-belong-in-a-pool--and-why-not-eccsite).
   `node_name: unknown` is not itself a failure — see
   [Reading the results correctly](#reading-the-results-correctly) below.

#### Using `mesh-hello` (API, no UI)

Once it is pushed and reachable, swap `echo`/`httpapijson` for `mesh-hello` in
the [API-scripted workflow test](#testing-a-workflow-end-to-end-via-the-api-no-ui)
below — the flow is identical, only the module differs:

```bash
SRC=$(curl -ks -X POST "$B/repository/sources" -H "Authorization: $T" \
  -H 'Content-Type: application/json' \
  -d '{"name":"mesh-hello","url":"https://gitlab.<tld>/<group>/mesh-hello.git"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -ks -X POST "$B/repository/v2/sources/$SRC/scan" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d '{}' > /dev/null

MESH_HELLO=$(curl -ks "$B/repository/v2/sources/$SRC" -H "Authorization: $T" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(m["id"] for m in d["last_scan"]["not_built_actions"] if m["technical_name"]=="mesh-hello"))')
curl -ks -X POST "$B/repository/modules/$MESH_HELLO/build" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d '{}'
# poll GET "$B/repository/v2/sources/$SRC" until status is "Built", then wire it
# into a workflow exactly like echo, but map the RESULT to node_name instead of
# test_str — that is the one field this smoke test is actually checking.
```

## Step 4 — run it

1. New workflow → add the **HTTP API JSON** trigger.
2. Add the **Echo inputs into outputs** action, and set one of its inputs to type
   **link**, pointing at a trigger output.
3. **Deploy** tab → pick the Site / Node Pool → **Deploy**.
4. Trigger the workflow.

A completed run whose echoed output matches what you sent proves the whole chain:
worker, Site, pool selector, placement policy, registry, filestore and broker. To
see *where* it ran, watch `kubectl get pods -n ryaxns-execs -o wide` while the run
is live (or use `mesh-hello`, which reports it as an output).

## Reading the results correctly

- **`node_name: unknown` is not a failure** (only relevant if you used
  `mesh-hello`). The worker builds the action pod spec itself, so which
  downward-API variables it injects is not part of the documented contract; the
  handler degrades instead of raising. Run the upstream `print_env` action once to
  see the real variable list, or just confirm placement directly while a run is
  live: `kubectl get pods -n ryaxns-execs -o wide`.
- **An action rejected at admission rather than queued** asked for more than the
  `ryaxns-execs` quota allows (`userNamespaceResources` in
  [worker-values.yaml](worker-values.yaml): 4 cpu / 8Gi of requests). Raise the
  quota or lower the action's `resources`.
- **A pod stuck `Pending`** means pool membership and the placement policy
  disagree. The pool selector decides which nodes Ryax *considers*; the
  `ryax-placement` policy (hardcoding `ecc/site: unibi-hclab`) decides whether the
  pod can *tolerate* landing there. Both must agree — see
  [README.md](README.md#which-nodes-belong-in-a-pool--and-why-not-eccsite).

## Talking to the API directly

⚠ **The Authorization header takes the bare JWT — not `Bearer <jwt>`.** The
Runner returns **401 with an empty `{}` body** for the `Bearer` form,
which is indistinguishable from "authenticated fine, no sites yet". That is a
genuine trap; it is how this was first misdiagnosed as a read-only API.

```bash
B=https://ryax.<tld>   # your cluster's actual TLD
PASS=$(kubectl get secret -n ryaxns ryax-admin-credentials -o jsonpath='{.data.password}' | base64 -d)
T=$(curl -ks -X POST "$B/authorization/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"admin\",\"password\":\"$PASS\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["jwt"])')

curl -ks -H "Authorization: $T" "$B/runner/sites" | python3 -m json.tool
```

Useful Runner routes (all relative to `/runner`): `GET /sites`,
`POST /sites`, `GET|PUT /sites/{id}`, `POST /sites/{id}/archive`,
`GET|POST /sites/{id}/node-pools`, `GET /workflows`, `GET /workflow_runs/{id}`.

Mind the response shapes — they are inconsistent, and guessing wrong fails
silently: `GET /sites` returns `{"sites": [...]}` (pools nested per site), while
`GET /sites/{id}/node-pools` returns a **bare JSON array**. Node pool payloads take
`cpu` in **millicores** and `memory` in **bytes**.

**Do not use the chart's bundled CLI** (`python -m ryax.cli`, "ryaxctl", inside
the runner pod). Its `CliConfig.auth_headers()` hardcodes `f"Bearer {token}"`, so
every verb 401s against this build. `manageWorker.sh` exists partly to replace it.

## Which node runs a workflow (UI)

Placement is per-**module**, not per-workflow: every action/trigger you drop on
the workflow canvas gets its own Site/Node Pool choice, so a single workflow can
span pools deliberately (e.g. a trigger on `k3s-cloud` calling a processor pinned
to a GPU pool).

In the workflow editor, click a module, then the module's **side panel** (not the
canvas) has two relevant tabs:

- **Constraints** — pick the **Site**, then the **Node Pool(s)** within it (and
  optionally restrict `arch`). Leaving Node Pool empty lets Ryax schedule onto
  *any* pool in the chosen Site — for a Site with one pool (the common case here)
  this is equivalent to picking it explicitly.
- **Objectives** — three sliders (energy/cost/performance), only meaningful with
  more than one eligible pool; harmless defaults (e.g. `10/10/10`) otherwise.

A pod that stays `Pending` after deploy means Constraints and the cluster's
`ryax-placement` admission policy disagree — see
[README.md](README.md#which-nodes-belong-in-a-pool--and-why-not-eccsite). The
Deploy tab mentioned in Step 4 above is really just the button that pushes these
already-configured per-module constraints live; there is no separate placement
step at deploy time.

## Running an action ON THE GPU

Two separate things are needed, and the second is easy to miss because the first one
alone gets you a pod that looks correctly placed.

**1. Ask for a GPU** — in the action's `ryax_metadata.yaml`:

```yaml
  resources:
    cpu: 0.5
    memory: 256M
    gpu: 1        # schema: number, minimum 1
    time: 5m
```

Ryax then schedules only onto a pool whose registered GPU count covers it, and adds the
`ecc/gpu` toleration to the execution pod itself. `manageWorker.sh` registers each pool
with the node's FREE card count (`created node pool … / 1 gpu`), and sets
`filter_no_gpu_action: false` on a pool that has cards — leaving that true would make Ryax
refuse to place GPU actions on the one pool built for them.

**2. Set the Runtime Class — WITHOUT IT THE CONTAINER HAS NO DRIVER.**

In the module's side panel, **Add-ons → Kubernetes → Runtime Class**, set it to `nvidia`.

This is NOT automatic. `k8s_action_deployment_service.py` leaves `runtime_class_name` as
`None` unless the `kubernetes` addon's `runtime_class` parameter is set — the GPU
*toleration* is added from the resource request, the runtime class is not. The failure is
confusing rather than obvious: the pod schedules onto the GPU node, the device is
allocated, and the process then dies on `nvidia-smi: not found` (or a CUDA init error),
which reads like a broken image rather than a missing runtime.

Measured 2026-09-17 on `unibi-recslab-smartmirror1`, same pod spec twice:

| runtimeClassName | result |
| ---------------- | ------ |
| *(unset)* | scheduled, GPU allocated, `sh: 1: nvidia-smi: not found` |
| `nvidia` | `0, NVIDIA GeForce RTX 2070, 8192 MiB, 580.178.04` |

`kubectl get runtimeclass` lists what is available (`nvidia`, `nvidia-experimental`,
`crun`, `lunatic`). ollama-turing sets the same `runtimeClassName: nvidia` — that is the
reference for what a working GPU pod looks like here.

⚠ **Both RTX 2070s are one node, and ollama-turing holds one by default.** So there is
normally exactly ONE free card for Ryax. `manageWorker.sh` refuses to register the pool
when none is free, rather than letting its actions sit `Pending` on "Insufficient
nvidia.com/gpu". Free a second with the `1x1-GPU` mode in
`app-of-apps/ollama-turing.yaml`.

⚠ The Jetson Thor is excluded by `ryax-placement` patch 4 and refused by
`manageWorker.sh`: it is aarch64/sm_110 and the action-builder produces x86_64 images.

## Testing a workflow end-to-end via the API (no UI)

Everything in Steps 3-4 is scriptable. This mirrors what `manageWorker.sh` does
for Site/Node Pool setup, extended through building actions and deploying a
workflow. Useful for smoke-testing a fresh install without a browser, and this is
how the `minipc-martin` worker was verified.

Three more services carry their own OpenAPI docs beyond the Runner one already
shown above — `/studio/openapi.json`, `/repository/docs/swagger.json` (note:
different doc mount than studio's), and they need the same bare-JWT `T` from
the login call above.

```bash
B=https://ryax.<tld>   # your cluster's actual TLD
T=$(...)  # bare JWT, see above

# 1. Add + scan the public actions repo (same one Step 3 uses)
SRC=$(curl -ks -X POST "$B/repository/sources" -H "Authorization: $T" \
  -H 'Content-Type: application/json' \
  -d '{"name":"default-actions","url":"https://gitlab.com/ryax-tech/workflows/default-actions.git"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -ks -X POST "$B/repository/v2/sources/$SRC/scan" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d '{}' > /dev/null

# 2. Find and build `echo` + `httpapijson` (module ids from the scan result)
MODS=$(curl -ks "$B/repository/v2/sources/$SRC" -H "Authorization: $T")
ECHO=$(echo "$MODS" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(m["id"] for m in d["last_scan"]["not_built_actions"] if m["technical_name"]=="echo"))')
TRIG=$(echo "$MODS" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(m["id"] for m in d["last_scan"]["not_built_actions"] if m["technical_name"]=="httpapijson"))')
curl -ks -X POST "$B/repository/modules/$ECHO/build" -H "Authorization: $T" -H 'Content-Type: application/json' -d '{}'
curl -ks -X POST "$B/repository/modules/$TRIG/build" -H "Authorization: $T" -H 'Content-Type: application/json' -d '{}'
# poll GET "$B/repository/v2/sources/$SRC" until both show status "Built" (a
# fresh nixpkgs pull takes several minutes; a cached rebuild is seconds)

# 3. Create the workflow and add both modules
WF=$(curl -ks -X POST "$B/studio/workflows" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d '{"name":"smoketest"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["workflow_id"])')
ECHO_MOD=$(curl -ks -X POST "$B/studio/workflows/$WF/modules" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d "{\"module_id\":\"$ECHO\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
TRIG_MOD=$(curl -ks -X POST "$B/studio/workflows/$WF/modules" -H "Authorization: $T" \
  -H 'Content-Type: application/json' -d "{\"module_id\":\"$TRIG\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

# 4. Link them — ⚠ direction is the OPPOSITE of what the field names suggest.
# output_module_id is the one that STREAMS OUT to input_module_id's module, so
# for "trigger feeds echo" it's output=trigger, input=echo:
curl -ks -X POST "$B/studio/workflows/$WF/modules-links" -H "Authorization: $T" \
  -H 'Content-Type: application/json' \
  -d "{\"output_module_id\":\"$TRIG_MOD\",\"input_module_id\":\"$ECHO_MOD\"}"
# Getting this backwards does not error — it silently produces two workflow
# validation errors (studio error codes 101 and 102) with no message text, and
# they do not go away no matter what else you fix. Confirm the direction by
# exporting the workflow (GET .../export, a zip containing workflow.yaml) and
# checking which module's `streams_to:` lists the other's id.

# 5. Fill the trigger's 3 required OpenAPI fields + the HTTP path (see the
# workflow_module/inputs listing to get each field's id), then wire echo's
# chosen input to the trigger's output via reference_value, then set the
# workflow's one required "result" (echo's output -> a JSON key), via
# PUT /studio/v2/workflows/$WF/results. GET /studio/workflows/$WF/errors
# should return [] once all of this is done.

# 6. Constrain both modules to the Site/Node Pool, then deploy:
curl -ks -X PUT "$B/studio/v2/workflows/$WF/modules/$ECHO_MOD/constraints" -H "Authorization: $T" \
  -H 'Content-Type: application/json' \
  -d '{"site_list":["<site-id>"],"site_type_list":[],"node_pool_list":["<pool-id>"],"arch_list":[]}'
curl -ks -X POST "$B/studio/workflows/$WF/deploy" -H "Authorization: $T"
```

Two more traps specific to the `httpapijson` trigger, found only by reading the
Runner pod's logs after a failed deploy (`kubectl logs -n ryaxns -l
app.kubernetes.io/name=runner`, filtered for `ERROR`) — the studio API returns no
error text for either:

- The dynamic output you add for the trigger (`POST
  .../modules/$TRIG_MOD/outputs`) defaults to **`origin: PATH`** with no API field
  to change it to `body` (the [http_api_json tutorial's](../../../../external/git_ryax-engine/docs/docs/tutorials/http_api_json.md)
  UI has an Origin dropdown; the studio OpenAPI schema does not expose it). So the
  endpoint `path` addon input must reference it as a path parameter:
  `/mesh-hello-smoketest/{Message}` — **not** `{message}`. The curly-brace name
  must match the output's **`display_name`** (title case, as the UI shows it), not
  its `technical_name`; get this wrong and the Runner logs
  `APIEndpointTemplateError: The parameter '<Name>' is missing in the endpoint path`.
- Even with all of the above correct, the route was never actually
  exposed the route: the Runner logs a clean `WorkflowDeployedSuccessfully` with no
  error, but `GET /user-api/openapi.json` (both through the gateway and via a
  direct port-forward to the `ryax-runner` Service's `user-api` port `10080`)
  keeps returning `"paths": {}`, and the endpoint 404s. This looks like a bug
  inside the closed-source `ryax_http_api` addon (the route is registered on some
  router object that never reaches the ASGI app actually serving that port), not
  anything wrong with the workflow config — the orchestration layer (workflow
  validated, deployed, execution scheduled onto the right Node Pool) all worked.
  Chained non-HTTP triggers (e.g. a cron/schedule trigger instead of
  `httpapijson`) were not tested and may not hit this.

## Teardown

Ryax is deployed by ArgoCD (`../../app-of-apps/cape-demo-ryax.yaml`), so removing it means deleting the
Application — prune takes the resources and the PreDelete hook removes the Authentik tile.
