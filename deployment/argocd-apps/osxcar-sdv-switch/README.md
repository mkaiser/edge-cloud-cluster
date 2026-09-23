# osxcar-sdv-switch — external repo checkout + EDA deploy run

Creates a GitLab project owned by `testuser`, checks an **external** GitLab repository out
into `testuser`'s home, loads the Xilinx and PetaLinux modules and runs `./deploy.sh -hw`.

```
PreSync   ensure GitLab project deployments/eda/osxcar-sdv-switch, testuser = OWNER
          default branch -> main; unprotect it (the mirror force-pushes)
          seed ci/osxcar-sdv-switch.yml into deployments/eda/ci-configs
          point the project at it via ci_config_path
CronJob   every 10 min: clone --mirror external -> force push --prune into the project
Pipeline  tags: [eda-run]  (gVisor runner, module runtime)
            auto on main, manual Run button on every other ref
            broker &  ->  module load xilinx/2024.1 + petalinux/2024.1  ->  ./deploy.sh -hw
            outputs -> /builds-out/<project>/<branch>-<sha>/  (datapool/eda/builds)
```

## Mirroring — hand-rolled, because this GitLab is CE

The in-cluster project is a **pull-only mirror** of the external repository. The external
one stays authoritative and nothing here is meant to be committed to.

⚠ **GitLab's own pull mirror is NOT used, because it does not exist on this instance.**
`/api/v4/version` reports `"enterprise": false`, and pull mirroring is EE/Premium. Measured
on ecc204:

| call | result |
| ---- | ------ |
| `PUT /projects/:id` with `mirror=true` | **HTTP 400** — `mirror` is not an accepted parameter |
| `POST /projects/:id/mirror/pull` | not available |

The instance setting `mirror_available` reads `true`, which is misleading — it is an
instance toggle with no effect without a licence. So `mirror-cronjob.yaml` does the work
itself: `git clone --mirror` of the external repo, then a **forced** `git push --prune` of
`refs/heads/*` and `refs/tags/*` into the in-cluster project, every 10 min.

⚠ **`main` must stay UNPROTECTED here.** The mirror force-pushes, and a protected branch
rejects that with `pre-receive hook declined` — for *every* ref, not just main (measured:
4 branches + 1 tag all rejected until it was unprotected). The PreSync hook re-asserts this
on every sync, because a group's `default_branch_protection` re-protects the default branch
of each project created under it.

⚠ **It refuses to push a zero-ref mirror.** A token that authenticates but can see nothing
clones 0 refs and exits 0; the following `--prune` would then delete every ref in the
target. That turns a permissions problem into data loss, so the run fails instead.

⚠ **A poll, not a webhook** — and not by preference. A webhook needs the external GitLab to
reach *into* this cluster, but `make production` closes 22/6443 and leaves admin WireGuard
as the only way in. There is no inbound path to hook.

⚠ **`--recurse-submodules` is deliberately NOT used by the mirror.** `clone --mirror` copies
refs and objects, so a submodule is just a gitlink and mirrors correctly without it. The
*consuming* pipeline does need it: `deploy.sh` is a **symlink into the `scripts/shared`
submodule** (`fpga-scripts`), so a plain clone leaves it dangling and `./deploy.sh` fails
"not found".

## The pipeline, and where its config lives

⚠ **The pipeline config is NOT in the mirrored repository, and cannot be.** The mirror
force-pushes the external repo over the project's tree, so a `.gitlab-ci.yml` committed
there is wiped on the next run — and the external repo has none. It is seeded into a
separate project instead and selected with GitLab's external CI config:

```
project  ci_config_path = osxcar-sdv-switch.yml@deployments/eda/ci-configs:main
```

Verified against the live API. The source of truth is `ci/osxcar-sdv-switch.yml` in this
repo; `sync-ci-config.sh` embeds it into `ci-config-configmap.yaml`, which the PreSync hook
seeds into GitLab. **Edit the file under `ci/`, never the ConfigMap** — precommit fails on
drift.

⚠ **The build branch is `main`** (it was `sdv-switch-bring-up` until that branch was merged
on 2026-09-08). `main` builds automatically; every other ref offers a manual **Run
pipeline** button. `pcie-bring-up` is a different board's bring-up and is deliberately not
built here. Change it in `BUILD_BRANCH` only — the PreSync hook's `DEFAULT_BRANCH` must
match.

⚠ **`GIT_SUBMODULE_STRATEGY: recursive` is mandatory.** `deploy.sh` at the repo root is a
**symlink into the `scripts/shared` submodule** (`fpga-scripts`), and the branch carries a
second submodule (`meta-rust-bin`) too. A plain clone leaves `deploy.sh` **dangling**: the
clone succeeds and `./deploy.sh` fails "not found", which reads as a missing file rather
than a missing submodule.

## Why it runs on [eda-run] and not [eda]

`module load` needs the gVisor + podman posture. The `[eda]` runner is privileged and
non-gVisor because rootless buildah does not work under k3s/containerd, and the executor's
`runtime_class_name` and `privileged` are **runner-wide** — so one runner cannot serve both.
All six existing `[eda]` jobs build images; none runs a module.

⚠ **The broker runs in the job container, not as a sidecar** — the Kubernetes executor has
no sidecar setting, and `module load` blocks forever on `/modules/.ready/<name>-<ver>` which
only the broker creates. So the job starts it, and `/registry` is mounted **read-only** in
the job pod: writing a `module.yaml` there is root-execution authority.

⚠ **`bash -lc`, not `bash -c`.** `/etc/profile.d` is sourced by login shells only and the
base image's bashrc fallback is guarded to interactive shells, so a CI shell gets neither.

## Where the build outputs go

To the shared NFS export `datapool/eda/builds`, under
`<project>/<branch>-<short-sha>/` — reachable from every interactive machine, and **local by
construction**.

⚠ **Not through GitLab `artifacts:` for the bulk.** `gitlab/check-ci-artifacts.sh` forbids
it and records why: the runner PUTs to Workhorse, which runs in the **cloud**, so a
lab-built output travels lab → cloud → back to an appliance 200 m from the runner (~1h45m
for 30 GB against ~5.5 min direct). `artifacts:` carries the log only.

## Two traps

**`bash -lc`, not `bash -c`.** `/etc/profile.d` is sourced by **login shells only**. The base
image adds a fallback in `/etc/bash.bashrc`, but it is guarded `case $- in *i*)` —
interactive only — so a Job's exec (neither login nor interactive) does not get the `module`
function at all.

**`vivado/2024.1` is not a module.** The module is `xilinx/2024.1`; the image also ships
Vitis, Model Composer and PDM, and `vivado` is one of its `cli_entries`, put on PATH by the
load. `module load vivado/2024.1` fails.

## The license is already handled

The desktop container carries `XILINXD_LICENSE_FILE` / `LM_LICENSE_FILE` /
`MODULE_LICENSE_SERVER` from `remote-desktop-secrets:license-server`, and `module-podmand`
passes the license vars it can see through to the module container. Running inside that pod
inherits all of it — do **not** add a second copy here, it would drift from the sealed one.

## Setup

```bash
source ./scripts/pulumi/initPulumiStack.sh
deployment/argocd-apps/osxcar-sdv-switch/sealSecrets.sh
```

Seals one secret, `osxcar-sdv-switch/external-git`, with two keys — `url` and `token`. The token is
a GitLab **personal access token** on the external instance, scope `read_repository`.

There is deliberately **no username**. A GitLab PAT carries its own identity, so HTTP Basic
only needs the token in the password field; the job sends the fixed literal `oauth2` as the
username (GitLab's documented placeholder). Pairing the PAT with a real account name works
by accident and breaks confusingly the day it is swapped for a project or group token.

The URL must **not** embed credentials; the script rejects one that does, because the token
is supplied through a git askpass helper — an embedded credential would silently win over
the sealed token *and* be written into the checkout's remote URL on the shared NFS home.

## Syncing

There is **no `automated` syncPolicy**, deliberately — the same reasoning as remote-desktop.
A sync runs `./deploy.sh -hw` — a Vivado synthesis build inside the desktop pod, which ties
up that pod's CPU for a long stretch. `selfHeal` would re-run it on any drift and `prune`
could delete a Job mid-build. Build on purpose:

```bash
argocd app sync osxcar-sdv-switch
```

## Notes

- **The checkout is a deploy artefact, not a working copy.** An existing `~/osxcar-sdv-switch` is
  `git reset --hard` to the remote head on every run. Keep personal work elsewhere in `$HOME`.
- **`backoffLimit: 0`.** `deploy.sh` is not known to be idempotent, so a failed deploy is not
  retried blindly — the log stays and a human decides.
- **The token never reaches argv or the checkout.** It is passed on the exec's stdin and
  supplied to git through a single-use `GIT_ASKPASS` helper in a private tmp dir, removed by
  a trap. `/proc/<pid>/cmdline` is readable inside the shared sandbox, and `git credential
  approve` would persist the token onto the shared NFS home.
- **testuser is pre-created in GitLab; no OIDC login is needed.** `gitlab-sync-admins`
  (CronJob, every 5 min) creates the account with its `openid_connect` identity for every
  member of its Authentik group sets, and testuser is in `employees` (that group carries
  `ecc/seed: all`, and `seed-user-group-sync` reconciles the seed users into it every 5 min).
  If the PreSync job runs inside the window before that CronJob has fired it WAITS, up to
  15 min, then fails loudly. It does not warn-and-continue: this app has no `automated`
  syncPolicy, so there would be no next sync to grant ownership on.
