---
name: argocd-debug
description: Diagnose an ArgoCD Application that will not apply a change — a sync that reports Synced/Healthy or Succeeded while the live cluster keeps the old state, a wedged or endlessly retrying operation, a hook Job that never fires, or a PreSync namespace deadlock. Use whenever a pushed fix does not land, an expected Job or Secret is absent, or you are about to patch an Application's operation/operationState. Covers both instances (argocd-infra, argocd-apps) and app-of-apps generated children.
---

# ArgoCD: why a change did not land

Almost every incident here is the same shape: **ArgoCD reports success and the cluster
keeps the old state.** Green status is not evidence. Diagnose before patching — the
recovery for each cause is different, and the wrong patch re-wedges the app.

## Two instances

| instance | namespace | manages |
|---|---|---|
| infra | `argocd-infra` | waves 0–19 |
| apps  | `argocd-apps`  | `deployment/argocd-apps/app-of-apps/` |

Same admin password hash. CLI login: `./scripts/runtime/argocdLoginCLI.sh [infra|apps]`
(default `infra`); run twice for both contexts, `argocd context <host>` switches.

## Step 1 — always run this first

Do not patch anything until you have read these five fields. They separate all five
causes below, and three of the causes look identical without them.

```bash
NS=argocd-apps   # or argocd-infra
APP=<name>
kubectl -n $NS get app $APP -o jsonpath='
sync={.status.sync.revision}
used={.status.operationState.syncResult.revision}
phase={.status.operationState.phase}
inflight={.operation}
scoped={.status.operationState.operation.sync.resources}
'; echo
```

Read it as:

- **`inflight` non-empty** → a sync IS in flight. Never judge this by `phase`: `phase`
  can read `Running` for hours after `.operation` is gone.
- **`used` older than `sync`** → the retry loop is pinned to an old revision (cause B).
  `sync` advancing is the misleading part — it names the revision ArgoCD *resolved*, not
  the one it *applied*.
- **`scoped` non-empty** → that sync ran NO hooks (cause D).

## The five causes

### A. Wedged operation — `phase: Running`, `.operation` gone

New sync requests are accepted and silently ignored; the app keeps reporting the old
operation's `startedAt`. Measured 2026-09-03 on remote-desktop: a rejected sync
(`--force cannot be used with --server-side`) wedged it, and three later syncs did nothing.

```bash
kubectl -n $NS patch app $APP --type json -p '[{"op":"remove","path":"/status/operationState"}]'
```

Then request the sync again.

⚠ Never pass `syncStrategy.apply.force` on an app that syncs with ServerSideApply — they
are mutually exclusive and the apply fails before touching anything. That is what caused
this wedge in the first place.

### B. Failed sync retries pinned to the ORIGINAL revision

`retry.limit: -1` means forever, and every retry re-applies the OLD manifests, so a fix
pushed afterwards can never apply. Signature: `phase: Running`, `message: Retrying
attempt #N`, `used=` older than `sync=`.

Measured twice — 2026-09-10 (eda-pcb-agent, ~25 min of stale ConfigMap re-applies) and
2026-09-16 (image-registry, a bad `nginx:1.31.6-alpine` held the sync at `4287b83c` for
~20 min while the fix `a9f8620e` sat unapplied).

**Clear BOTH fields, then sync at an explicit SHA.** Clearing only `operationState` leaves
the old revision in `.operation` and the retry loop immediately re-wedges. `revision: HEAD`
is swallowed by the retry and re-pinned — pass the real sha:

```bash
kubectl -n $NS patch app $APP --type json -p '[{"op":"remove","path":"/operation"}]'
kubectl -n $NS patch app $APP --type json -p '[{"op":"remove","path":"/status/operationState"}]'
kubectl -n $NS patch app $APP --type merge \
  -p "{\"operation\":{\"sync\":{\"revision\":\"$(git rev-parse HEAD)\"}}}"
```

⚠ Do NOT work around this with a hand `kubectl apply`. Hook resources carry
`hook-delete-policy: BeforeHookCreation`, so ArgoCD deletes and recreates them on its next
pass and silently reverts the manual copy — which reads as the fix not working.

### C. Hook-body change — nothing to apply, so no hooks run

A change that edits only the BODY of a hook Job (the SQL in a connection-seed, the JSON in
an authentik-provider) never applies on its own, and the app reports `Synced`/`Healthy`
throughout. Hook Jobs are not part of the desired-state comparison, so there is no drift:
`selfHeal` cannot fire and `automated` makes no difference. A plain sync short-circuits in
~15s with nothing to do and runs no hooks.

```bash
kubectl -n $NS patch app $APP --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncStrategy":{"hook":{}}}}}'
```

⚠ **`syncStrategy.hook` runs the HOOKS ONLY.** Use it to unstick a failed or unrun hook,
never as a general "sync this app": it reports `Succeeded … (all tasks run)` while ordinary
Sync-phase resources are never applied, so a manifest change appears to deploy and does
not. Measured 2026-09-14 on eda-pcb-agent — the hook-only sync left the pod in
`Init:CreateContainerConfigError` with `secret "eda-pcb-agent-secrets" not found`, because
that app's SealedSecret is itself a PreSync hook with no delete policy: the hook-only run
replaced it without applying the Sync phase around it. For a normal sync omit
`syncStrategy` entirely.

⚠ Deleting the Job first is NOT the trigger (it looked like one once because that sync had
other real work queued). `syncStrategy.hook` is.

**Same cause, second shape: a hook-annotated ConfigMap.** In the EDA module apps the build
inputs (Dockerfile, `.gitlab-ci.yml`, `module.yaml`) reach GitLab through a ConfigMap
annotated `argocd.argoproj.io/hook: PreSync`. Pushing a change to it deploys nothing, for
the same reason. Measured 2026-09-21 on `eda-kicad-10`: the app reported `Synced/Healthy`
at the correct HEAD for ~7 hours while the live ConfigMap held the previous day's content
(`grep -c librsvg2-common` returned 0 on the live object against 5 in git).

⚠ **A hard refresh does NOT help here** — that is the tell separating this from cause E.
`refresh=hard` makes ArgoCD re-read git, and it correctly concludes the app is Synced,
which it is by its own definition. Refresh fixes a stale *cache*; this is not a caching
problem. Request a sync at a real SHA (and see the digest-pin caveat: after the image
rebuilds, users still run the OLD one until the PostSync register hook re-pins — confirm
with `broker digest <name> <version>`, not with "the pipeline succeeded").

⚠ **A Sync-phase Job still Running blocks the PostSync phase**, and the operation still
reports `Succeeded … (all tasks run)` having run zero PostSync hooks. Measured on zammad:
`zammad-init-1` (~2–3 min) was in flight, so three successive hook syncs each returned
immediately and created no provider Job. Wait for Sync-phase Jobs to finish, then sync.

Related but distinct: a failed **PostSync** hook does not re-run either. `retry`
re-attempts a sync that FAILS; it does not START one. An app sits `Synced/Healthy` while
`operationState` stays frozen at `phase: Failed` forever.

### D. Scoped sync — runs no hooks at all

A sync whose `operation.sync.resources` is non-empty applies only the listed resources and
runs **no hooks**. The app reports `Synced/Healthy`, `phase: Succeeded`, duration ~1s, and
every PostSync Job in that app is simply *absent* — not Failed, not pending, absent.
`kubectl get job` returns NotFound and Loki has no logs, so there is nothing to find by
looking at the job.

ArgoCD's own selfHeal produces these: `initiatedBy.automated: true` with
`autoHealAttemptsCount` set and a resource list naming only the drifted objects.

Measured 2026-09-17 on ecc214 — `ryax`'s Authentik portal tile was missing while 19 other
apps had theirs, at the right SHA, with the `ServiceAccount`/`Role` from the same
`authentik-provider.yaml` present. `syncResult.resources` length is the other giveaway: 1
instead of 200+.

Fix with a full sync (omit `syncStrategy`):

```bash
kubectl -n $NS patch app $APP --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

### E. Stale render — the parent, or the repo-server cache

Two variants, same remedy (`refresh=hard`), different tell:

**Generated child (app-of-apps).** Editing a value inside a child Application's inline
`helm.valuesObject` needs the PARENT (`apps-root`) to re-render. Syncing the child does
nothing — its spec is generated, so it faithfully applies the values the parent last gave
it. The child's `status.sync.revision` is EMPTY (a generated app has no git revision of its
own), so **no revision on the child can ever confirm your change landed.**

Measured 2026-09-22 changing the `[eda]` runner's `cpu_request`: `apps-root` read `Synced`,
`Succeeded`, `successfully synced (all tasks run)` — at the commit BEFORE the change.
Syncing at an explicit SHA did not move it.

**OCI chart cache.** For a multi-source app with `valueFiles: $values/...` (ryax), ArgoCD
can report `Synced` **at the new revision** while the repo-server serves a cached render.
`syncResult.revisions` named the right SHA for both git sources while the target ConfigMap
kept its original `creationTimestamp`.

```bash
kubectl -n $NS annotate app <parent-or-app> argocd.argoproj.io/refresh=hard --overwrite
```

It flips to OutOfSync if the cache was stale. Two checks before reaching for it:

1. Confirm your change is on the REMOTE branch ArgoCD tracks (`git show origin/main:<file>`)
   — a precommit hook that amends leaves HEAD ahead of origin.
2. Render locally with that exact file (`helm template <rel> <chart> -f <values>`) to
   separate a chart-override problem from a cache problem.

If a sync then keeps aborting on an unrelated resource's health wait, scope it — pass
`operation.sync.resources` with just the kind/name/namespace you need, so one unhealthy
Deployment cannot block the apply. Mind that this makes it a scoped sync (cause D): it will
run no hooks.

## Verifying — the part that gets skipped

**Never conclude from the app's sync status.** Verify on the object the change produces:
the Job's `creationTimestamp`, the row in the database, a `GET` against Authentik, a
command whose output differs between old and new.

- Re-read before concluding an apply failed. A `kubectl get` moments after a sync can show
  the old spec; compare `metadata.generation` against `status.observedGeneration` rather
  than trusting one snapshot. Measured 2026-09-17: a scoped sync HAD applied the change
  while a stale read sent the diagnosis down a false path.
- For app-of-apps, verify through **three layers**: parent `status.sync.revision` == your
  SHA → the child Application's live spec → the object the child writes. For a
  gitlab-runner the third layer is two steps, because the runner reads its config at
  STARTUP: the ConfigMap can be correct while a days-old pod still schedules builds with
  the old numbers. `rollout restart` it and read `config.toml` out of the running pod.

## PreSync namespace deadlock

`CreateNamespace=true` creates the namespace in the **Sync** phase, so a namespaced
**PreSync** hook runs before it exists, fails `namespaces "<ns>" not found`, and aborts the
phase — so the Sync phase that would have created the namespace never runs. Unconditional
on a fresh cluster, not a race. Cluster-scoped hook resources (ClusterRole/Binding) succeed
throughout, which makes it read as an RBAC problem rather than an ordering one.

⚠ A negative `sync-wave` does NOT fix this. Waves order resources WITHIN a phase; they do
not move one between phases. The namespace must itself be a **PreSync hook** ordered ahead
of the others (`sync-wave: -10` against their `-1`), and must NOT carry
`hook-delete-policy: HookSucceeded` — that would delete the namespace and everything in it.

Precedent: `deployment/argocd-apps/remote-desktop/namespace.yaml`. A plain `kind: Namespace`
manifest suffices only when the app has no namespaced PreSync hooks
(`deployment/argocd-infra/loki/namespace.yaml`).

⚠ Check whether OTHER apps write into that namespace — `CreateNamespace=true` only ever
creates an app's OWN destination namespace. One missing namespace failed FOUR apps on ecc196.

⚠ Ordering within a phase is `argocd.argoproj.io/sync-wave` and only that.
`argocd.argoproj.io/hook-weight` is NOT an ArgoCD annotation and is silently ignored —
gitops-engine's `syncwaves.Wave()` reads `sync-wave`, else `helm.sh/hook-weight`, else 0.
Verified against the deployed v3.5.2.

## Barriers

Each infra barrier writes a ConfigMap `waveN-barrier-done` in `argocd-infra` on first
successful pass, and exits immediately on re-syncs if the marker exists. Force a re-run:

```bash
kubectl delete configmap waveN-barrier-done -n argocd-infra
```

The apps instance has no barriers.

## kubectl fallback when the CLI is not logged in

The admin password comes from the Pulumi stack, NOT from a k8s secret — there is no
`argocd-initial-admin-secret` in this cluster (the chart is deployed with a pre-set hash).
Load the stack first:

```bash
ARGOCD_PASS=$(pulumi config get argocdAdminPasswordPlain)

# infra
kubectl port-forward svc/argocd-server -n argocd-infra 8080:443 --address=127.0.0.1 &>/tmp/argocd-pf-infra.log &
sleep 3 && argocd login localhost:8080 --username admin --password "$ARGOCD_PASS" --insecure

# apps (different local port, same password)
kubectl port-forward svc/argocd-apps-server -n argocd-apps 8081:443 --address=127.0.0.1 &>/tmp/argocd-pf-apps.log &
sleep 3 && argocd login localhost:8081 --username admin --password "$ARGOCD_PASS" --insecure
```

⚠ Never `pkill -f "port-forward..."` — it matches your own agent shell and kills the tool call.

## Also remember

- ArgoCD may override any change you make with `kubectl`. Between a git push and reconcile
  is 5–10 minutes.
- `remote-desktop` has no `automated` syncPolicy on purpose — a sync kills every logged-in
  session. Do not diagnose that as a fault. The `desktop-rollout` CronJob syncs it
  automatically when it is OutOfSync AND has zero ready replicas.
