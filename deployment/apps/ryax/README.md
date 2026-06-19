# Ryax on ArgoCD

Ryax is deployed as a normal wave-20 ArgoCD `Application`
([../../argocd-sync-waves/wave20-ryax.yaml](../../argocd-sync-waves/wave20-ryax.yaml)), like the
other user apps. The chart is **not** ArgoCD-friendly out of the box, so a few wrappers are needed.
This document explains *why*, what we do about it, and — importantly — **how the Ryax chart could be
changed upstream so none of this is necessary**. (We can send these as suggestions to the Ryax
maintainers.)

Chart: `oci://registry.ryax.org/release-charts/ryax-engine:26.4.0`
Source for reference: `external/git_ryax-engine` (read-only).

## Files here

| File | Purpose |
|---|---|
| `values.yaml` | Helm values (HAProxy-terminated TLS, `local-path` storage, admin user from sealed secret, kube-prometheus-stack tuned for ArgoCD). |
| `haproxy-ingress.yaml` | 3 HAProxy Ingresses (front `/app`, services, grafana `/grafana`) + the `registry.ryax.*` Certificate. |
| `authentik-blueprint.yaml` | Authentik portal **bookmark** tile (Ryax has no OIDC). Applied cross-namespace into `authentik`. |
| `ryax-admin-credentials-sealed.yaml` | SealedSecret with the Ryax admin user/password. |
| `sealSecrets.sh` | (Re)seals the admin credentials. Run with the Pulumi stack loaded. |

The bootstrap Job lives next to the app at
[../../argocd-sync-waves/wave20-ryax-bootstrap.yaml](../../argocd-sync-waves/wave20-ryax-bootstrap.yaml).
A manual fallback installer is kept at [../../manual/ryax/](../../manual/ryax/) for debugging outside
ArgoCD — do not run it alongside the ArgoCD app on the same cluster.

---

## Problem 1 — fresh-install deadlock (the `pre-upgrade` hooks)

### What happens

The chart ships its database-migration and runner/studio scale-down jobs as Helm **`pre-upgrade`
hooks** (no value to disable them):

- `charts/ryax/subcharts/datastore/templates/jobs.yaml:11` — `ryax-datastore-db-migration`
  (`helm.sh/hook: pre-upgrade`, weight 2). It `psql`s into the datastore and reads
  `ryax-datastore-secret`.
- `charts/ryax/subcharts/runner/templates/upgrade-jobs.yaml:7` / `:100` — scale-down + `db-migration`.
- `charts/ryax/subcharts/studio/templates/jobs.yaml:7` / `:92` — scale-down + `db-migration`.

With plain Helm this is fine: `helm install` runs **only** `pre-install` hooks, so on a fresh install
these `pre-upgrade` jobs are skipped; the DB initialises from the normal Sync-phase resources, and the
migration runs later on `helm upgrade`.

**ArgoCD has no install/upgrade distinction.** It maps every `pre-*` hook to the **PreSync** phase and
runs it on *every* sync, including the first. On a fresh install the migration job runs *before*
postgres (a normal Sync-phase resource) exists → the job fails → PreSync aborts → the Sync phase that
would have created postgres never runs → **deadlock**.

### Our mitigation

[wave20-ryax-bootstrap.yaml](../../argocd-sync-waves/wave20-ryax-bootstrap.yaml) — an idempotent Job
(marker ConfigMap `ryax-bootstrap-done`) in the **same** wave as the app. It:

1. `argocd app sync ryax --skip-hooks` → applies postgres + all main resources **without** the
   failing `pre-upgrade` hooks. The DB initialises.
2. `argocd app wait ryax --health`.
3. `argocd app sync ryax` (normal) → the migration/scale-down hooks now run against a live DB.

From then on, automated `selfHeal` keeps Ryax in sync; the hooks only re-run on a genuine
change/upgrade (which is correct, and idempotent per the comment at `datastore/jobs.yaml:1-3`).

To force a re-bootstrap (e.g. cluster recreate): `kubectl delete configmap ryax-bootstrap-done -n argocd`.

### Upstream fix (suggest to Ryax maintainers)

Any **one** of these removes the need for the bootstrap Job:

- **Gate the migration/scale-down jobs behind a value** (e.g. `datastore.migration.enabled`,
  default `true`) so a GitOps deployment can render the chart with `--set` for the initial apply and
  flip it on afterwards. Minimal change.
- **Don't make migrations Helm hooks.** Run schema migrations as a normal Sync-phase `Job` (or an
  init container on the app Deployment) that waits for postgres to be reachable. Migrations that wait
  for their own DB work identically under `helm install`, `helm upgrade`, and ArgoCD — no hook phase
  needed.
- **If they must stay hooks, make them tolerate a not-yet-initialised DB**: detect "DB empty / not
  reachable yet" and exit 0 (the normal init path will create the schema). That makes the first
  PreSync a no-op instead of a hard failure.
- Document an officially supported ArgoCD install path (the
  [ArgoCD + Helm hooks](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#helm-hooks) caveat
  is well known).

---

## Problem 2 — secret churn on every sync (`lookup()` in the repo-server)

### What happens

Several chart secrets are rendered as `lookup() ... | default (randAlphaNum 12)` to "generate once,
then preserve":

- `charts/ryax/subcharts/datastore/templates/secrets.yaml:1-2` (`ryax-datastore-secret`).
- `charts/worker/templates/secrets.yaml:16-18` (`ryax-db-pass` — `{{ .Release.Name }}-db-pass`).
- plus `ryax-broker-secret`, `ryax-broker-cookie`, `api-jwt-secret-key`, `grafana-credentials`,
  `repository-password-encryption-key`, `runner-encryption-key`, `ryax-minio-secret`.

`lookup()` only works when Helm has a live cluster connection. **ArgoCD's repo-server renders with
`helm template`, which has no cluster access**, so `lookup()` returns empty and the
`| default (randAlphaNum 12)` branch mints a **new random value on every render**. With
`selfHeal: true` ArgoCD would push that new value each reconcile and rotate passwords out from under
running pods.

### Our mitigation

A **name-less** `ignoreDifferences` on `.data` for **all** Secrets (see
[wave20-ryax.yaml](../../argocd-sync-waves/wave20-ryax.yaml)) — robust to the chart's
release-name-derived secret names, which differ across versions (e.g. the worker DB secret is
`{{ .Release.Name }}-db-pass`, not a fixed name). The only non-chart Secret in this app is the
SealedSecret CR (a different kind), so nothing managed out-of-band is affected. ArgoCD treats the
secrets as Synced after first apply and never rewrites them. (Same idea applied name-less to the
immutable PVC fields, and per-name to the Prometheus CRDs the cluster's main kube-prometheus-stack
owns.)

### Upstream fix (suggest to Ryax maintainers)

- **Stop regenerating secrets in templates.** Generate credentials **once** in a `pre-install`-only
  hook (or a small operator/Job), or support `existingSecret:` for every credential so the value
  lives outside the chart. `lookup()`-based preservation is fundamentally incompatible with GitOps
  renderers (ArgoCD, Flux) because they template without cluster access.
- Where `existingSecret` already exists (e.g. the worker DB), allow **all** credentials to be supplied
  that way, so operators can manage them as sealed/external secrets.

---

## Problem 3 — in-place upgrade rotates the worker DB password

### What happens

`ryax-db-pass` (the worker DB secret, `{{ .Release.Name }}-db-pass`) is generated by a
**`pre-install,pre-upgrade` hook** (`charts/worker/templates/secrets.yaml:26`). Because it is a hook,
ArgoCD applies it verbatim whenever the hook phase runs, so `ignoreDifferences` does **not**
protect it. Combined with Problem 2
(empty `lookup()` in the repo-server), a genuine in-place chart **version bump** re-applies this secret
with a **fresh random password** → the worker can no longer authenticate to its existing postgres.

### Our mitigation (and the trade-off)

We do **not** pin the password, because a real pin requires a **plaintext** value in `values.yaml`
(Helm reads `worker.postgresql.auth.password` at *template* time, where a sealed/k8s secret cannot be
read). That would violate this repo's sealed-secret discipline.

So today:

- **Fresh installs and steady state are safe** — the secret is created once and frozen
  (no drift → no hook re-runs).
- **In-place chart version bumps are not supported** without manual care. The project's normal flow is
  **cluster recreation** (`ecc84 → ecc85 …`), where the worker DB is fresh anyway. For a true in-place
  upgrade, either recreate the worker postgres PVC or reset the password manually
  (`ALTER USER worker WITH PASSWORD …` to match the regenerated secret) before/after the sync.

Opt-in alternatives if in-place upgrades become a requirement:

- Put a literal password in `values.yaml` (`worker.postgresql.auth.password` +
  `.postgresPassword`) — feeds `worker/templates/secrets.yaml:17-18`, rendering deterministically.
  Plaintext-in-git trade-off.
- Add a PostSync Job that resets the worker DB password to a stable sealed value after each sync.

### Upstream fix (suggest to Ryax maintainers)

- Same as Problem 2: support `existingSecret` for the worker DB password (it half-does already via
  `auth.existingSecret`, but the chart still *generates* the secret in a hook). Let operators provide
  the secret and skip generation entirely (e.g. `postgresql.auth.generateSecret: false`).

---

## Other ArgoCD-specific tuning already in `values.yaml`

- `kube-prometheus-stack.prometheusOperator.admissionWebhooks.enabled: false` — ArgoCD does not run the
  certgen Helm hook of an **OCI subchart**, so the operator would hang on a missing admission-TLS
  secret. (A good upstream issue too: subchart hooks silently don't run under ArgoCD.)
- `nodeExporter.enabled: false` — avoids hostPort clashes with the cluster-wide node-exporter.
- `prometheusOperator.namespaces.releaseNamespace: true` — keeps the bundled operator scoped to
  `ryaxns` so it doesn't fight the cluster's main kube-prometheus-stack.
- `traefik.ingressClass.isDefaultClass: false`, `certManager.enabled: false`, `global.tls.enabled:
  false` — HAProxy terminates TLS; the chart's own ingress/cert-manager paths are off.

---

## Verification (after a fresh cluster bring-up)

```sh
# bootstrap ran
kubectl get cm ryax-bootstrap-done -n argocd
kubectl get job ryax-bootstrap -n argocd

# app converged with no perpetual drift (validates the ignoreDifferences list)
argocd app get ryax
argocd app diff ryax        # expect empty

# workloads
kubectl get pods -n ryaxns                 # all Ready, incl. ryax-authorization + *-db-migration Completed
kubectl get pvc  -n ryaxns                 # Bound on local-path
kubectl get ingress,certificate -n ryaxns

# external access
curl -kIL https://ryax.<tld>/app/          # 200
curl -kI  https://ryax.<tld>/grafana/login # 200 (no redirect loop)

# secrets are stable across re-sync (selfHeal must NOT rotate them)
argocd app sync ryax ; argocd app sync ryax
kubectl get pods -n ryaxns                 # no restarts

# portal tile
kubectl get cm authentik-blueprint-ryax -n authentik
```
