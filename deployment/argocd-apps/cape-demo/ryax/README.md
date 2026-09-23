# Ryax on ArgoCD

Ryax is a normal ArgoCD `Application` ([../../app-of-apps/cape-demo-ryax.yaml](../../app-of-apps/cape-demo-ryax.yaml)).
Chart: `oci://registry.ryax.org/release-charts/ryax-engine:26.9.0`. Upstream source for
reference: `external/git_ryax-engine` (read-only).

The deployment follows upstream's own GitOps how-to,
`docs/howto/install_ryax_argocd.md` in that repo. Read it before changing values here — it is
the authority on why each of the four non-obvious settings exists.

## Files here

| File | Purpose |
|---|---|
| `values.yaml` | Helm values. The four load-bearing ones: `global.secrets.create: false`, every `ingress.enabled: false`, `registryCertSetup.enabled: false`, `traefik.deployment.enabled: false`. |
| `httproute.yaml` | Gateway API HTTPRoute for `ryax.<tld>` (front `/app`, the API services, grafana `/grafana`). |
| `admission-policies.yaml` | Two `MutatingAdmissionPolicy` objects: placement for execution pods in `ryaxns-execs`, and action-builder probe timing. |
| `authentik-provider.yaml` | PostSync/PreDelete Jobs creating the `ryax` group, `access-ryax` policy and the portal bookmark tile (Ryax has no OIDC). |
| `ryax-secrets-sealed.yaml` | The 13 credentials the chart would otherwise generate. Produced by `generateSecrets.sh`. |
| `generateSecrets.sh` | Generates and seals those 13. The datastore/broker URLs embed the passwords stored beside them, so they cannot be created independently. |
| `ryax-admin-credentials-sealed.yaml` | Ryax admin user/password. |
| `authentik-provisioner-token-sealed.yaml` | Scoped Authentik API token for `authentik-provider.yaml`. |
| `sealSecrets.sh` | (Re)seals the two secrets above. Needs the Pulumi stack. |
| `worker-values.yaml` | Values for the separate `ryax-worker-k8s` release. Without a worker Ryax can run no actions at all. |
| `example-action/` | Minimal buildable action (`mesh-hello`) reporting the node it ran on. |
| `snapshot-policy.yaml` | PostSync hook taking EVERY ryaxns volume out of Longhorn's snapshot and S3 backup jobs, and dropping the nix store to one replica. Read its header before re-enabling anything. |
| `registry-garbage-collect.yaml` | CronJob replacing the chart's broken registry GC (it read the wrong config path and masked its own errors). |
| `nix-store-garbage-collect.yaml` | Weekly `nix-collect-garbage` in the action-builder. The first run freed 58 GiB. |
| `kubelet-volume-servicemonitor.yaml` | Scrapes `kubelet_volume_stats_*` for the ryax namespaces — Longhorn's own exporter is unscrapeable here (its NetworkPolicy admits only Longhorn pods). |
| `postsync-ryax-user.yaml` | PostSync Job creating the non-admin Ryax GUI user from `ryax-user-credentials-sealed.yaml`. |
| `ryax-user-credentials-sealed.yaml` | The non-admin Ryax GUI account. Grafana's admin mirrors it. |
| `worker-values.budapest-emdc.yaml`, `worker-values.home-martin.yaml` | Per-site overrides for the worker release; without one, a non-default site would install with the default site's nodeSelector and storage class. |
| `usage.md` | Start here as a user: login, Site/Node Pool, importing and running an action. |

Operator scripts in `scripts/` act on a **running** Ryax over its API and are not part of the
deployment:

| File | Purpose |
|---|---|
| `scripts/manageWorker.sh` | Site + Node Pools + the `ryax-worker-k8s` release. `<node>…`, `--list`, `--remove <node>`, `--site <name>`. |
| `scripts/smoketest.sh` | End to end: builds two actions, wires a workflow, deploys it to one Node Pool, reports whether the execution pod scheduled **and** pulled its image. |
| `scripts/getcredentials.sh` | Prints the admin login. |

---

## Four settings that must not be changed casually

Upstream's how-to documents all four.

### `global.secrets.create: false`

The chart generates credentials with `lookup(...) | default (randAlphaNum 12)`. `lookup()`
returns nothing when ArgoCD's repo server renders without a cluster, so leaving this true means
every reconcile mints new passwords and pushes them to running pods.

⚠ `ignoreDifferences` on Secret `.data` does not contain that — it suppresses drift detection,
not a sync applying the rendered manifest.

Rotating means re-running `generateSecrets.sh` **and** wiping the datastore/broker/minio PVCs,
which still hold the old passwords.

### Every `ingress.enabled: false` — all six, registry included

This cluster runs no Ingress controller (routing is Gateway API). Nothing fills in
`.status.loadBalancer`, so ArgoCD health-checks such an Ingress as Progressing forever and the
sync operation never completes. One is enough to park it.

⚠ Injecting `argocd.argoproj.io/sync-options: Skip health check` with a MutatingAdmissionPolicy
does not work: the annotation lands on the live object, while ArgoCD decides what to wait for
from the manifest it renders from git.

### `registry.registryCertSetup.enabled: false`

Must accompany `registry.ingress.enabled: false`, or the cert-setup DaemonSet nsenters into
PID 1 on every node it lands on, rewrites `/etc/containerd/config.toml` and restarts containerd.

Consequence: the registry serves plain HTTP with htpasswd auth, reachable on port 30012 of
every node — including across the mesh subnet. Fence it with a CiliumNetworkPolicy if that
becomes a concern.

### `traefik.deployment.enabled: false`

Nothing routes through it once the Ingresses are off. If re-enabled, its Service defaults to
LoadBalancer and MetalLB/kube-vip hands it the cluster ingress IP — the chart's Ingresses match
host `*`, so it then answers for every host in the cluster.

---

## Placement

`global.tolerations` / `global.nodeSelector` cover the Ryax-own workloads. The upstream
subcharts (kube-prometheus-stack, minio, rabbitmq, loki, tempo, alloy) ignore those globals and
each need their own keys — all set in `values.yaml`.

⚠ Neither reaches `ryaxns-execs`: the Runner creates execution pods at run time, so they are in
no chart manifest. That is what `ryax-placement` in `admission-policies.yaml` is for, and why
it cannot be replaced by values.

After a chart bump, re-render and check that every Deployment, StatefulSet and DaemonSet carries
both the toleration and the selector.

---

## Sealing

`generateSecrets.sh` and `sealSecrets.sh` both seal with the **stack** certificate
(`pulumi config get sealedSecretsTlsCrt`), never the live controller's.

⚠ Any new sealing script must do the same. `src/sealedsecrets.ts` seeds each cluster's
controller from that stack cert, so a file sealed against a running controller is openable only
by the cluster that was up at the time: on the next cluster it applies cleanly, produces no
Secret, and the app comes up credential-less. Prefer `seal_secret()` from
`deployment/manageSealedSecrets.sh`, which gets this right.

---

## Trying a newer chart

Release-candidate tags are published to `release-charts` alongside releases and are
anonymously pullable the same way:

```sh
tok() { curl -sS -G https://registry.ryax.org/service/token \
  --data-urlencode service=harbor-registry --data-urlencode "scope=$1" | jq -r .token; }
T=$(tok "repository:release-charts/ryax-engine:pull")
curl -sS -H "Authorization: Bearer $T" \
  "https://registry.ryax.org/v2/release-charts/ryax-engine/tags/list?n=500" | jq -r '.tags[]'
```

Bump `targetRevision` in [../../app-of-apps/cape-demo-ryax.yaml](../../app-of-apps/cape-demo-ryax.yaml) and
`CHART_VERSION` in `scripts/manageWorker.sh` together. Upstream ships
`charts/gitops-checks.sh`, which asserts the properties a GitOps engine needs — run it against
a candidate before adopting one.

---

## Adding a cluster node as a Ryax worker (Sites and Node Pools)

Ryax cannot run an action until a **Site** exists. A Site is a compute target;
within it, a **Node Pool** is a set of *homogeneous* nodes.

The thing that surprises people: **the `ryax-engine` chart contains no worker at
all.** `charts/ryax/Chart.yaml` declares ten subcharts
(`common-resources`, `action-builder`, `authorization`, `front`, `intelliscale`,
`repository`, `runner`, `studio`, `registry`, `datastore`) and not one of them is
a worker. So even to run actions on **this same cluster** you must install a
second Helm release, `ryax-worker-k8s`. Skip it and Ryax comes up with an empty
Site list, the Deploy tab offers nothing, and no action can run anywhere.

Files here: [worker-values.yaml](worker-values.yaml) (fully commented) and
[example-action/](example-action/).

### No Skupper for a same-cluster worker

The upstream [worker-install howto](https://docs.ryax.tech/howto/worker-install/)
spends most of its length installing Skupper, a RouterAccess, a Traefik
`IngressRouteTCP` and link certificates. **All of that is only for a worker on a
DIFFERENT cluster.** Skupper exists solely to give a remote worker a network path
to three main-site services: the broker (5672), the filestore/minio (9000) and the
registry.

A worker in `ryaxns` on this cluster reaches all three directly, by reading the
Secrets the main chart already created in that same namespace:

| Secret | Provides |
|---|---|
| `ryax-broker-secret` | `RYAX_BROKER` |
| `ryax-minio-secret` | `RYAX_FILESTORE` + access/secret keys |
| `ryax-registry-creds-secret` | action image pulls (the `registry` subchart injects it into the release namespace and `userNamespace` by default) |

So: no Skupper, no `LoadBalancer`, no second public IP, no link certificates, no
`k8s-ryax-config.py`. Install Skupper only when adding a genuinely separate
cluster.

### Placement

`worker-values.yaml` sets `global.tolerations` / `global.nodeSelector` for the worker's own
pods, plus `postgresql.primary.*` for the bundled bitnami postgres, which ignores those
globals. The user action pods in `ryaxns-execs` are created by the Runner at run time and get
theirs from the `ryax-placement` policy instead.

⚠ The MIG labeler stays disabled (`config.MIG.enabled: false`). It is a DaemonSet carrying
`tolerations: [{effect: NoSchedule, operator: Exists}]`, so it spreads to every node in the
cluster — the placement policy only *adds* tolerations, it cannot remove a blanket one — and it
holds a ClusterRole with `nodes: patch`. It rewrites `nvidia.com/mig.config` for the NVIDIA GPU
Operator's MIG Manager, which this cluster does not run, and neither GPU node here supports MIG.

### Registering a node

```sh
bash deployment/argocd-apps/ryax/scripts/manageWorker.sh --site <site> <node>...
```

The script creates the Ryax Site and one Node Pool per node over the Runner's API, sized from
each node's live `.status.allocatable` scaled by `RYAX_POOL_SHARE` (default 0.6), then installs
or upgrades the `ryax-worker-k8s` release with the generated `config.site` block as a second
`-f` layer. `--list` shows what is registered, `--remove <node>` stops sending work to one.

⚠ It is additive: the pool set is read back from the live worker ConfigMap, so adding one node
never disturbs the others. Re-running it is also how the worker release gets a chart bump.

⚠ The Site name is chosen at CREATE time. An existing Site is looked up by name, so re-running
a registered node under a different `--site` creates a second Site and a second pool rather
than moving it — the API has no pool delete. To move a node, `--remove` it under its current
Site first.

⚠ A Ryax "Site" is a scheduling target with its own id in the Runner's database. It is not the
`ecc/site` node label, which is this cluster's failure/latency domain.

⚠ The Site and pool ids live in the Runner's postgres, so they die with that PVC. After a
cluster recreate, re-run the script.

### Which nodes belong in a pool — and why not `ecc/site`

A Node Pool must be **homogeneous**: Ryax stores the per-node CPU/memory figures
you type into the UI and schedules against them, so a pool spanning different node
sizes makes every placement decision it takes wrong — it sizes against the typed
figures, not against the node it actually picked.

That rules out the obvious selector. `ecc/site: unibi-hclab` is what the placement
policy pins Ryax to, but it covers three nodes that are **not** comparable
(measured allocatable):

| node | cpu | memory | role |
|---|---|---|---|
| `unibi-hclab-pcie-tb-s` | 24 | 30.5 GiB | compute |
| `unibi-hclab-pcie-tb-d` | 20 | 30.0 GiB | compute |
| `unibi-hclab-fs-vm` | 4 | 7.2 GiB | fileserver VM |

So `worker-values.yaml` defines **one pool per compute node**, selected by
`kubernetes.io/hostname` (which matches exactly one node in any case), each
carrying that node's own figures. `unibi-hclab-fs-vm` is deliberately left out, and
**STORAGE is the binding reason, not its role**: it is a 57.7 G disk that shares the
general `unibi`/`unibi-hclab` Longhorn tags with 0.9-1.8 T peers, so it is kept out of
the `unibi-ryax` tag on purpose. Ryax is the largest tenant of that tag (705 GiB of
replica footprint, 400 G of it the action-builder nix-store) and its engine storage is
node-local, so an action landing there fills the smallest disk in the pool first. On
2026-09-15 exactly that took remote-desktop's Guacamole database down for ~4h — fs-vm hit
DiskPressure and refused a 5 G replica while 50% physically free.

⚠ Do NOT "add it as its own pool" — an earlier version of this paragraph suggested that,
and it is wrong for the storage reason above. `manageWorker.sh` now REFUSES any node
without the `unibi-ryax` disk tag, because this prose did not prevent fs-vm being
registered by hand on 2026-09-18 (its `ecc/site` label is shared with the compute nodes,
so it looks eligible). Make a node eligible by adding `unibi-ryax` to its `storageScope`
in `project_settings.ts`, never by bypassing the check.

If you would prefer a single pool, add a genuine shared label to both compute
nodes and select on that. **Do not reuse `ecc/eda-builder=true`** — it matches
exactly those two nodes today, but it means "EDA image-build host", and
overloading it would silently couple Ryax placement to an unrelated concern.

**Adding a further node** is one command —
`manageWorker.sh <node-name>`, using the name from `kubectl get nodes`. It creates
that node's pool from its live allocatable and leaves the existing pools alone.
Two caveats still apply:

- A node in a **different** `ecc/site` needs its own Node Pool, and — if it is at a
  different Ryax **Site** — its own worker RELEASE (see "A second site" below). The
  `ryax-placement` policy injects `ecc/site` in `ryaxns` ONLY, so execution pods in
  `ryaxns-execs` are unaffected — Ryax pins those to one exact node via
  `kubernetes.io/hostname` from the pool, and that pin is authoritative.
  `unibi-recslab-smartmirror1` is registered this way: a different `ecc/site`, but the
  same Ryax Site, so it needs no separate release. The worker release's own pods still
  follow `global.nodeSelector` in `worker-values.yaml`.
- A **GPU node** is accepted only while a card is actually free. `ryax-placement`
  tolerates `ecc/gpu=true:NoSchedule` (patch 3), so a GPU pool schedules — but with every
  card already requested (ollama-turing takes both by default) its actions sit Pending on
  "Insufficient nvidia.com/gpu". `manageWorker.sh` checks this and refuses. Free a card
  with the `1x1-GPU` mode in `app-of-apps/ollama-turing.yaml` first.
- The **Jetson Thor** is always excluded — `ryax-placement` patch 4 keeps pods off it and
  `manageWorker.sh` refuses it. Ryax's action-builder produces x86_64 images; the Thor is
  aarch64/sm_110.
- Upstream recommends tainting pool nodes `ryax.tech/ryaxns-execs` so they are
  dedicated to Ryax actions (every action tolerates it by default) and can scale
  to zero. **Do not do that on these nodes** — they are shared with samba-ad,
  Longhorn and the EDA runners, and a dedicating taint would evict them.

### A second site (budapest-emdc, home-martin)

Ryax is multi-site by design here, and the pieces were already in place: the
`ryax-placement` policy deliberately does NOT pin execution pods to a site (the Node
Pool's hostname selector is authoritative), so an action can run anywhere its pool
points. What a second site adds is its own worker RELEASE.

One helm release per Ryax Site, because the worker's OWN pods carry that site's
`nodeSelector` and bind that site's storage class — a shared release would move them
every time another site was updated:

| site | release | overrides |
| ---- | ------- | --------- |
| `unibi-hclab` (default) | `ryax-worker` | none — uses `worker-values.yaml` |
| `budapest-emdc` | `ryax-worker-budapest-emdc` | `worker-values.budapest-emdc.yaml` |
| `home-martin` | `ryax-worker-home-martin` | `worker-values.home-martin.yaml` |

```bash
scripts/manageWorker.sh --site budapest-emdc <node>      # add
scripts/manageWorker.sh --site budapest-emdc --list      # inspect that site only
```

`--list` and `--remove` act on the release for the site you name, so pass `--site` for
anything other than the default.

Adding a further site means adding its `worker-values.<site>.yaml` with at least
`global.nodeSelector.ecc/site` and `global.defaultStorageClass`. `manageWorker.sh`
**refuses** a non-default site whose file is missing rather than installing with the
default site's placement.

Two things to check before registering an off-site node:

- **The x86-64-v2 label.** The worker's own pods require
  `feature.node.kubernetes.io/cpu-cpuid.X86_64_V2=true` (see `global.affinity` in
  `worker-values.yaml` for the measured failure behind it). Confirm
  node-feature-discovery has actually labelled the node —
  `kubectl get node <n> -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep X86_64_V2`
  — rather than assuming it from the CPU model.
- **Reachability.** Both of these sites are VPN-dependent and may simply be absent.
  `manageWorker.sh` registers pools from live node allocatable, so it cannot register a
  node that has not joined.

Storage: each site uses its OWN site scope (`longhorn-budapest-emdc`,
`longhorn-home-martin`), not a ryax-specific one. The worker's only persistent claim is a
2 Gi postgres and user action pods bind no volume at all, so a dedicated scope would mean a
new anchor, StorageClass and backup group for 2 Gi. Those site scopes keep their snapshots
and backups — the RecurringJob group list is generated from the full `storageScope` set.

⚠ The volumes in `ryaxns` itself are the exception: every one of them is deliberately
excluded from all snapshot and backup jobs by [snapshot-policy.yaml](snapshot-policy.yaml).
See that file's header for what is given up and why.

## Minimal example: the `mesh-hello` action

[example-action/](example-action/) is a complete, buildable Ryax action:
`ryax_metadata.yaml` + `ryax_handler.py`, standard library only (no
`requirements.txt`, no `dependencies:` — every dependency is a nix build in the
action-builder, so an empty dep set keeps the first build to minutes instead of
tens of minutes).

It echoes a message and returns `node_name`, `pod_name` and `architecture`.
`node_name` is the output that matters: it is the proof that the Site selector and
the placement policy agree, and it must come back as a unibi-hclab mesh node.

Ryax imports actions by **scanning a git repository**, so pre-configuring the
example means pointing Ryax at a repo that contains it:

1. Push `example-action/` to a repository Ryax can reach — the in-cluster GitLab
   (`https://gitlab.<tld>/…`) works; use a read-only deploy token for credentials.
2. In the UI: **Library → Repositories → Add**, give it a name and the clone URL
   (plus credentials if private), then **New Scan**. `mesh-hello` appears in the
   scan results.
3. **Build** it. The action-builder packages it with nix and pushes it to
   `ryax-registry:5000`.
4. Create a workflow, add an **HTTP POST** trigger and then the **Mesh Hello**
   action, linking the trigger's field to the `message` input.
5. In the action's **Deploy** tab select the Site/Node Pool from above, deploy,
   and trigger it.

Check `node_name` in the run output. If it is a unibi-hclab node, the whole path —
worker, Site, Node Pool, placement policy, registry, filestore, broker — is
working. `node_name: unknown` is not a failure: the worker builds the action pod
spec itself, so which downward-API variables it injects is not part of the
documented contract and the handler degrades rather than raising. Confirm
placement with `kubectl get pods -n ryaxns-execs -o wide` while the run is live.

## Verification (after a fresh cluster bring-up)

```sh
# the release marker exists, so later syncs run the migration hooks for real
kubectl get cm ryax-release-marker -n ryaxns

argocd app get ryax          # Synced / Healthy
argocd app diff ryax         # empty

# workloads
kubectl get pods -n ryaxns                 # all Ready, incl. ryax-authorization + *-db-migration Completed
kubectl get pvc  -n ryaxns                 # Bound on longhorn-unibi-ryax
kubectl get httproute -n ryaxns            # Accepted=True, ResolvedRefs=True

# external access
curl -kIL https://ryax.<tld>/app/          # 200
curl -kI  https://ryax.<tld>/grafana/login # 200 (no redirect loop)

# secrets are stable across re-sync (selfHeal must NOT rotate them)
argocd app sync ryax ; argocd app sync ryax
kubectl get pods -n ryaxns                 # no restarts

# portal tile + group/policy (created by the PostSync job via the Authentik API)
kubectl get job ryax-authentik-provider -n ryaxns   # Completed
```
