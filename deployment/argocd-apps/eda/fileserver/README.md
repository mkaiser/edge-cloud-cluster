# eda-fileserver — EDA storage on the TrueNAS appliance

Owns the TrueNAS datasets, NFS exports and per-module subdirectories the EDA stack uses.
Separate from `argocd-infra/truenas/configure-job.yaml` so that disabling the EDA stack
stops provisioning EDA storage: **a dataset is provisioned by the app that mounts it.** The
names themselves are grouped under `project_settings.storage.fileserver.datasets`, because
they share one appliance — grouping is not central provisioning.

| dataset                    | holds                                                                 | policy                                                            |
| -------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `datapool/eda`             | grouping parent, **not exported**                                     | —                                                                 |
| `datapool/eda/installers`   | installer media (no image archives — see below)                       | regenerable → short retention, excluded from off-site replication |
| `datapool/eda/modulefiles` | `<name>/<version>/module.yaml` — the broker's **authorisation** store | NOT regenerable → long retention, replicate off-site              |
| `datapool/images`    | OCI blob store for the lab-local registry                             | append-only, no GC                                                |

The children are separate datasets **on purpose**: a common parent groups them, it does not
merge them, and their policies differ in opposite directions. Never merge `modulefiles` into
`registry` — that would put root-execution authority inside a volume an ordinary Deployment
mounts rw.

## ⚠ The payloads outlive the cluster — check them before a recreate

Nothing in `datapool/eda/*` is regenerable on any sane timescale, and a recreate that finds
these datasets empty fails **silently**:

- every container module rebuilds from installer media — **hours** of Xvfb batch install
  per module, with no error anywhere to explain it;
- the HyperLynx installer media has **no upstream any more** (the lab SMB share was
  retired), so it cannot simply be re-fetched;
- every module registration is gone, so `module load` fails for all of them.

Note there are **no `image.tar` archives** — that scheme was retired. What carries the built
images across a recreate is `datapool/images`, the blob store itself; the media on
`artifacts` is only the rebuild fallback.

So confirm on the appliance before destroying a cluster:

```sh
ls -la /mnt/datapool/eda/installers/*/*/            # installer media present
ls -la /mnt/datapool/eda/modulefiles/modules/*/*/module.yaml
ls    /mnt/datapool/images/docker/registry/v2/repositories/deployments/infrastructure/eda/modules
```

## ⚠ Pre-recreate: the shared datasets must be reshaped on the appliance

`datapool/shared` became a **grouping parent** with two children, matching the `eda` shape.
The manifests already point at the new paths, so the ZFS rename must happen on the
appliance **while the old cluster is down** (the desktop holds these mounted) and **before**
`make bootstrap`, or the provisioning job creates them empty and `/shared` comes up blank:

```sh
zfs rename datapool/shared      datapool/shared-old
zfs create datapool/shared                       # parent, NOT exported
zfs rename datapool/shared-old  datapool/shared/data
zfs rename datapool/shared_tmp  datapool/shared/tmp
```

Then delete the stale NFS exports for the old `datapool/shared` and `datapool/shared_tmp`
paths. Nothing here deletes an export (forward-only, see below), and `nfs_export()`
converges BY PATH — an export left on the new parent would serve both children through one
path and defeat the split.

A PV's `spec.persistentvolumesource` is **immutable**, so any future change to `share:`,
`server:` or `volumeHandle:` takes effect only on a fresh cluster; until then ArgoCD reports
the PV `OutOfSync` and **that drift is expected and harmless**. Never delete a Bound PV to
force it — that detaches live data.

## Sealed secret

`sealSecrets.sh` seals a **scoped** TrueNAS API key (`eda-fileserver-api`), not the
appliance-admin password: this app needs datasets and exports, not AD or identity. The key
is minted by hand on the appliance (Credentials → Local Users → _user_ → API Keys → Add)
and shown exactly once.

The key buys least privilege — a narrower blast radius than the appliance admin password.
The Job runs on a lab node against the appliance's LAN address over `wss://`, because cloud
pods cannot route to the lab LAN at all.

## Forward-only

Nothing here deletes a dataset, an export or a file — there is no `pool.dataset.delete`, no
`sharing.nfs.delete`, no `filesystem.unlink`. Disabling this app means it **stops
re-asserting**; the data stays. Do not add a teardown path: it would put irreplaceable
installer media, the 115 GB SDI tarballs, the un-GC'd blob store and the broker's authority
store one bad `prune` away from destruction.

## Checks

Both run in `make precommit`:

- `check-tnclient.sh` — the embedded `tnclient.py` must stay byte-identical to
  `argocd-infra/truenas/configure-job.yaml`'s copy (a ConfigMap cannot cross namespaces, so
  the duplicate is unavoidable; silent drift is not). `--fix` re-syncs it.
- `check-subdirs.sh` — the per-module subdir string is derived in two unlinked places
  (each app's `.gitlab-ci.yml` reads its media from it, this app's `SUBDIRS` creates it).
  If they disagree, **the build cannot find its installer media**. Also asserts each EDA PV's `share:` equals
  `/mnt/<dataset>` from `project_settings.ts` — those lines deliberately carry no anchor
  (the substitution regex would eat the `/mnt` prefix), so they are hand-maintained.

The PostSync `verify.py` turns appliance drift into a visible failure: the fileserver is not
a k8s resource, so ArgoCD would otherwise report this app Synced regardless of its state.

## Adding installer media from Windows

The `eda/installers` dataset is also exported over SMB as `\\fs-1.ad.base.internal\eda`, so
a laptop on the VPN can drop new vendor media in from Explorer.

**Access is a four-link chain, and every link is required:**

| # | Thing | Created by |
|---|---|---|
| 1 | Authentik group `eda-developer` | `eda/fileserver/authentik-group.yaml` (PostSync) |
| 2 | the user's **AD account** | `samba-ad/postsync-provision-users.yaml` step 2 — from `employees` |
| 3 | AD group `eda-developer` | same job, step 2a — mirrored from (1) |
| 4 | the SMB share ACL | `provision-job.yaml` `smb_share()` — restricts the share to (3) |

⚠ **Being in `eda-developer` is not enough.** A member must ALSO be in
`employees`, because that is the group whose members get an AD account at all.
Someone in `eda-developer` alone has no AD identity to add, and the mirroring job reports
that rather than failing.

⚠ **Without link 4 the share is writable by EVERY domain user** — a new SMB share defaults
to `everyone@` / FULL. The ACL converges on every provisioning run, so widening it by hand
in the UI is put back.

⚠ **The network path already exists**: the headscale policy grants `autogroup:member`
(any personal device on the tailnet) access to `192.168.1.0/24` on port 445. No new firewall or policy rule is needed for a laptop on the
VPN — but the appliance is *only* reachable from that LAN, so this does not work off-VPN.

Drop new media in a **new** `<tool>/<version>/` directory rather than editing one in place:
the `[eda]` runner reads this same tree during builds.

## "No internet connection" on the appliance while the cluster is down

Expected, not a fault. `argocd-infra/truenas/configure-job.yaml` sets the appliance's
**only** nameserver to the on-prem Samba DC's LAN IP and clears `nameserver2`/`nameserver3`.
That is deliberate: a lab-router fallback breaks the AD join, because TrueNAS fails hard on
the *first* nameserver that cannot answer for the realm rather than moving on
(`Forward lookup of "_kerberos._tcp.<REALM>." failed with nameserver 192.168.1.1`).

So when the cluster is destroyed the DC goes with it, the appliance's sole resolver stops
answering, and everything by name fails. The LAN itself is fine — `192.168.1.237` still
pings, the UI still loads over `fileserver.webUiForward`.

- **Leave it**: `make bootstrap` redeploys the DC and resolution returns by itself.
- **Need it sooner**: set Nameserver 1 to the lab router in Network → Global Configuration,
  and set it back before the AD join runs. configure-job re-asserts the DC address anyway,
  but only once that pod is up.

Same root cause behind `[EBUSY] cannot unmount '/mnt/datapool/eda/...'` when deleting a
dataset by hand: delete its NFS export first (or restart the NFS service), since `nfsd`
holds the mount. Deleting these datasets is optional — `ensure_dataset()` creates whatever
is missing on the next sync, with the correct `acltype=NFSV4`.
