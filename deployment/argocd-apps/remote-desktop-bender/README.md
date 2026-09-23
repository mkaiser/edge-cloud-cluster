# EDA desktop on `bender` — the same desktop, a second node, a wider audience

The second instance of the `module load` EDA desktop
([`../remote-desktop/`](../remote-desktop/)), pinned to the mesh node
**`unibi-hclab-bender`** and open to the Authentik **`employees`** group.

Everything about *using* it is documented in the other desktop's
[README](../remote-desktop/README.md) — `module load`, the batch/scripted path, SSH
access, public-key auth from LDAP. This file covers only what is **different**, and
the two things that will surprise you.

## The tile

Guacamole shows this desktop as **`EDA Workstation (lab: bender)`**. There is no separate
web address: the tile is seeded into remote-desktop's Guacamole by
[`connection-seed.yaml`](connection-seed.yaml), the same way `eda-pcb-agent` and
`windows` do it. You log in at the usual `remote-desktop.<tld>`.

Sessions are per login and authenticated with your own AD credentials — the desktop is
xrdp → SSSD → Samba AD, exactly as the other one. Guacamole's SSO does not log you into
the desktop; see the other README for why that is deliberate and not a missing setting.

## ⚠ Two things that will surprise you

**1. `/scratch` does NOT follow you between the two desktops.** It is a node-local
hostPath (`/var/lib/desktop-scratch`) — that is what makes it the fast tier. bender's is
a different disk from the other desktop's, so files you leave in `/scratch` on one are
simply not there on the other. `/home`, `/shared` and `/shared/tmp` ARE shared: they are
NFS exports from the same appliance, and the same file is the same file on both.

That is why the tile names the node. If you care where your files are, use `$HOME`.

**2. This desktop is pinned; the other one is not.** bender's `/scratch` is therefore
stable across pod restarts, which the other desktop's is not (it is placed by labels and
can move between runsc lab nodes). Do not rely on that for anything you cannot lose:
`/scratch` is still not backed up, not replicated, not snapshotted, and nobody cleans it.

## What this app does NOT contain, and why

| Not here | Where it lives |
| -------- | -------------- |
| Guacamole, its CNPG database, the public HTTPRoute | `remote-desktop/` — one shared front door for three apps |
| the base image build (`Dockerfile.base`, `ci-base.yml`, the build trigger) | `remote-desktop/` — this app consumes the archived image |
| the Authentik OIDC provider | `remote-desktop/authentik-provider.yaml` — one provider |
| `/shared/tools` publishing | `remote-desktop/postsync-shared-tools.yaml` — one writer for one dataset |
| the licence values (`eda-secrets`) | `eda/secrets/` — sealed into this namespace from one value |

## Two cross-app dependencies, both deliberate

1. **The tile needs remote-desktop's Postgres.** If that app is disabled or down,
   `connection-seed` fails and this desktop has no tile. The pod keeps running and stays
   reachable over SSH and the tailnet; `retry` recovers the tile when remote-desktop
   returns.
2. **The pod needs remote-desktop's pipeline to have archived the base image.** Both
   desktops pull `image-archives/remote-desktop:<IMAGE_TAG>`. ⚠ **Never bump the tag in
   this app alone** — `remote-desktop/check-image-invariants.sh` compares every consumer
   (both desktops and the `[eda-run]` runner) and a partial bump means one of them pulls
   a tag nothing archived.

## ⚠ Security boundary

The broker sidecar mounts the module registry
([`nfs-eda-modulefiles-bender-pv.yaml`](nfs-eda-modulefiles-bender-pv.yaml)). Writing a
`module.yaml` there is what authorises the privileged broker to pull an image and **run
it as root**, and the set of pods that mount that export is the only thing bounding it —
no export rule can narrow it.

This desktop's audience is `employees`, i.e. **every AD account**. That is a deliberate
decision and a wider grant than the other desktop's (`remote-desktop-users`), taken
knowingly. The full reasoning, and what to change if the audience should be narrowed
again, is in the banner at the top of that PV file. Read it before changing either half.

Narrowing is two strings: the group in [`connection-seed.yaml`](connection-seed.yaml)
and the `access-remote-desktop` policy in `../remote-desktop/authentik-provider.yaml`.

## Access wiring — it takes BOTH halves

An `employees` member needs two separate grants, in two different apps:

1. **the portal** — `access-remote-desktop` in `../remote-desktop/authentik-provider.yaml`
   must admit `employees`, or Authentik denies the Guacamole application outright and the
   user never sees a login, let alone a tile;
2. **the tile** — the `READ` grant in [`connection-seed.yaml`](connection-seed.yaml).

Granting one without the other is a silent failure in both directions. No new Authentik
object is needed: `employees` is created centrally and the shared provider's `groups`
scope already emits it.

## The keytab is minted HERE, in PreSync

Unlike remote-desktop — whose keytab comes from a **PostSync** hook in the `samba-ad` app —
this desktop mints its own `rdesk-bender$` machine account in a **PreSync** hook
([`keytab-job.yaml`](keytab-job.yaml)). The desktop refuses to start without
`/etc/krb5.keytab`, so a PostSync minter deadlocks: the Deployment never goes healthy, the
Sync phase fails, and the PostSync phase that would create the Secret never runs
(measured on `eda-pcb-agent`/ecc208). A prerequisite of the workload belongs before it.

⚠ That logic now exists in **three** places (`remote-desktop/keytab-job.yaml`,
`eda-pcb-agent/keytab-job.yaml`, and here), all carrying the same `TODO(rotation)`. If a
fourth is ever needed, extract a single KVNO-triggered CronJob instead of copying again.

## The startup script is duplicated, and guarded

A ConfigMap cannot cross namespaces, so `desktop-startup.sh` exists twice. It must stay
byte-identical — per-desktop values reach it through the pod env, never through the script.
[`check-startup-drift.sh`](check-startup-drift.sh) (run by precommit) fails the commit if
the two copies diverge, and names the first differing line. If you find yourself wanting to
branch on the desktop inside the script, add an env var to the Deployment instead.

## Sync policy

**No automated sync**, for the same reason as remote-desktop: applying a change restarts a
single-replica `Recreate` Deployment and ends every logged-in session, so it is a human's
call. The `desktop-rollout` CronJob syncs it unattended only while it has **zero** ready
replicas — first boot and crash-loops, i.e. exactly when there is no session to lose.

(`eda-pcb-agent` *can* have `selfHeal` because syncing it ends only its own single shared
session. This one ends other people's.)

## Before first deploy

```
deployment/argocd-apps/remote-desktop-bender/sealSecrets.sh   # generate *-sealed.yaml
```

Then check `tests/remoteDesktopBenderChecks.sh`.
