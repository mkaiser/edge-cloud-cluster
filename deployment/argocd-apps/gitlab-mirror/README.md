# gitlab-mirror — every repository as a bare repo on the appliance

GitLab is cloud-pinned so it survives a mesh outage. The cost is that lab users lose git
when the tunnel drops, and the repositories have no on-prem copy at all. This is that copy.

```
GitLab API + git (cloud, public)   ──▶  CronJob (lab LAN)  ──▶  NFS  ──▶
                                                       fs-1:/mnt/datapool/gitlab/mirror
```

Hourly, `git clone --mirror` then `git remote update --prune`, one bare repo per project
plus its wiki.

## What it is and is not

**It is** a copy you can use with nothing else running: mount the export, `git clone` a
directory, done. No GitLab, no matching version, no restore tooling.

**It is not** a GitLab backup. Issues, merge requests, wiki *metadata*, CI configuration,
users, settings and tokens live in Postgres and are covered only by the toolbox backup
(`gitlab-toolbox-backup`). Both exist because they answer different questions. Do not delete
one on the strength of the other.

## Three things that will bite you

**1. The token is minted per cluster, not sealed — and that is deliberate.** A PAT lives in
GitLab's database, so a sealed copy would name a token that does not exist after a recreate:
the secret would still apply, the mirror would still start, and every run would 401 in a way
that reads as a permissions problem. `postsync-mirror-token.yaml` mints it in the running
GitLab on every sync instead, which also makes the 365-day expiry self-healing — it re-mints
whenever the stored token is missing or no longer accepted. `GitLabMirrorStale` remains the
backstop for when syncs themselves have stopped.

**2. A non-admin token yields a silently partial mirror.** `/api/v4/projects` returns only
what the caller can see and exits 0 either way. That is why the bootstrap uses the admin
user. Check `projects discovered: N` in the logs against the admin area's project count.

**3. It must run at the lab.** It needs the public GitLab API and the appliance's LAN
address in one process, and only a mesh node reaches both — cloud pods have no route to
192.168.1.0/24. `gitaly-backup create --path <dir>` is the tool that *should* do this, but
it runs inside the gitaly container, which is cloud-side and cannot see the export.

## Deliberate choices

- **Keyset pagination**, not `page=N`: offset pagination skips rows when the project list
  changes between pages, so a repository could be missed with no error.
- **Archived projects are kept.** That is exactly the state where the last copy matters.
- **`--prune`**, so branches deleted upstream disappear here too; without it the mirror
  drifts into a union of every branch ever pushed.
- **A wiki that 404s is treated as empty, not failed.** Wiki repos are created lazily on
  the first page, so most projects have none — failing on that would fail every run.
- **Any repository failure fails the Job.** A partial mirror that exits 0 is the failure
  this exists to prevent, and the alert keys off the last *successful* run.
- **The token is stripped from `origin` after each fetch**, so it is never left in a repo's
  config on the export.

## Setup

None. `postsync-mirror-token.yaml` mints the API token (scopes `read_api`,
`read_repository`) after every GitLab sync and writes it to `gitlab-mirror/gitlab-mirror-token`.

The dataset and its NFS export come from `deployment/argocd-infra/truenas/configure-job.yaml`
(`DS_GITLAB_MIRROR`). ⚠ Exactly one controller may manage an export path, so do not declare
this export anywhere else.

## Restoring from it

```bash
# from any host that can mount the export
git clone /mnt/datapool/gitlab/mirror/<group>/<project>.git
```

⚠ Snapshot policy on `datapool/gitlab/mirror` is what protects this from a bad mirror run
(a force-push upstream propagates here on the next `--prune`). The mirror is a copy, not a
history of copies.
