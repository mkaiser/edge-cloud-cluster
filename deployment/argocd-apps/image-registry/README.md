# image-registry — lab-local OCI registry for EDA module images

Plain `registry:3` on a TrueNAS NFS export, pinned to the appliance LAN
(`ecc/fileserver-lan`). It exists for **speed**:

| Path | Throughput |
|---|---|
| GitLab registry → Hetzner S3 (`nbg1`), from the lab | ~5.3 MB/s |
| TrueNAS NFS on the lab LAN | ~92 MB/s write / ~126 MB/s read |

A 31 GB HyperLynx push took **16 min** over S3; a 40 GB Vivado restore never completed.

GitLab's own registry is **untouched** and still serves everything else.

## Using it

In-cluster only, HTTPS, authenticated:

```
https://image-registry.image-registry.svc.cluster.local:5000
```

The certificate comes from a **private in-cluster CA** (`tls-cert.yaml`) — Let's Encrypt
cannot sign a `.svc` name. Clients must trust it. The `ca-distribute` PostSync Job copies
the CA into `gitlab-runner` and `remote-desktop` as the `image-registry-ca` ConfigMap; the CI
also receives it as the `IMAGE_REGISTRY_CA` variable and writes it to
`/etc/containers/certs.d/<host>/ca.crt`, which buildah and skopeo read automatically.

Credentials are sealed by `sealSecrets.sh` (user `eda`) and reach the CI as masked project
variables.

## Three things that will bite you

**1. Retention covers the ARCHIVES ONLY; module images still grow forever.**
`retention-cronjob.yaml` keeps the 2 most recent tags per `image-archives/*` repository and
runs `registry garbage-collect -m` weekly (Sunday 03:00). It touches nothing under
`deployments/**`.

That scope is deliberate, and not just caution: the module repositories are what the
privileged broker pulls and runs **as root**, and what protects a given one is
`<name>/<version>/module.yaml` on `datapool/eda/modulefiles` — a dataset whose *mount points
are themselves the security boundary*. A retention job that read it to decide what is
still referenced would have to mount it, widening that boundary to save work the scope rule
already does. Each module repository carries exactly one tag today, so a keep-2 policy would
never have deleted one anyway.

⚠ **So re-pushing a module tag still orphans the old blobs permanently.** EDA images are
20–40 GB each. Prune those by hand:

```bash
# What is it using?
kubectl -n image-registry exec deploy/image-registry -c registry -- du -sh /var/lib/registry
```

⚠ `REGISTRY_STORAGE_DELETE_ENABLED` stays **false**. Retention removes tag links on the
filesystem and lets `garbage-collect -m` collect the untagged manifests, so no account ever
gains DELETE through the API.

⚠ The weekly GC **skips itself if any upload is in flight**. What GC removes is blobs no
manifest references, which includes a push still staging in `_uploads` — so the risk is a
concurrent push failing and being retried, not stored images being damaged.

**2. Three layers guard it, and all three matter.** What this registry serves is executed
**as root** by the broker, whose `allowed()` gate authorises by `<repo>:<tag>` and never
verifies the *content* at that tag — so publish rights are effectively root-execution
rights.

| Layer | Mechanism | Stops |
|---|---|---|
| Credential | htpasswd, **two accounts** (`sealSecrets.sh`) | anyone without a password reaching it at all |
| Authorisation | nginx front (`authz-configmap.yaml`): `eda-pull` may only GET/HEAD | the broker's credential — mounted in a multi-user desktop — being able to publish |
| Reachability | `CiliumNetworkPolicy` | every pod outside `gitlab-runner` / `remote-desktop` |
| Transport | TLS from a private CA | the basic-auth credential crossing the pod network in the clear |

⚠ Cilium runs `enable-policy=default` — it denies only where a policy *selects* the pod. If
`networkpolicy.yaml` is ever removed, the registry silently becomes reachable cluster-wide
again with no error anywhere.

**No longer ClusterIP-only, since 2026-09-03: it is a NodePort on 30500.** The kubelet
cannot resolve `*.svc.cluster.local` — that is a node resolver, not a cluster one — so lab
workloads had to pull their images from GitLab's S3-backed registry instead, at ~5 MB/s from
the lab against ~126 MB/s here. Every appliance-LAN node now carries containerd's own
`certs.d/127.0.0.1:30500/hosts.toml` + CA (`node-registries-config.yaml`), and remote-desktop
and ollama pull from it.

⚠ **That config is written into containerd's `certs.d` directory, NOT into
`/etc/rancher/k3s/registries.yaml`, and the distinction is load-bearing.** k3s expands
`registries.yaml` into two places with different lifetimes: the auth into `config.toml`
(read only at agent start) and the endpoint/CA into `certs.d/<host>/hosts.toml` (re-read on
every pull). Writing `certs.d` directly therefore takes effect with NO k3s restart — which
is what removed the old manual `activateNodeRegistry.sh` step from every bootstrap and
recreate, and what makes a re-minted CA self-healing.

The credential is the half that cannot live there — `hosts.toml` has no auth field — so it
is an ordinary `imagePullSecret` (`image-registry-cred-node`, sealed by `sealSecrets.sh`
into the ollama and remote-desktop namespaces). ⚠ It is keyed to host `127.0.0.1:30500`:
a pull secret is matched by registry host string, so the FQDN-keyed `image-registry-cred`
does not apply to these image references at all.

⚠ A NodePort binds on ALL interfaces, so the registry is now reachable from the lab LAN too,
and a LAN packet is SNATed to the node address — arriving with the same identity as the
kubelet, which the policy admits. The policy cannot separate them. What does is the
credential split (the node-side account is the read-only `eda-pull`) and digest pinning in
the broker. This would NOT have been acceptable before either existed.

Still no HTTPRoute, and that has not changed: the CA is private, so no external client could
verify it, and publishing a root-execution push endpoint on the public wildcard is a
different thing entirely from a node-local port.

Cheap check that the node path works, on any lab node:

```bash
sudo k3s crictl pull 127.0.0.1:30500/smoke/alpine:3.20
```

`smoke/alpine` is a 5 MB image kept for exactly this. It is outside `image-archives/`, so the
retention CronJob never touches it.

**3. Single replica, and it must stay that way.** The `filesystem` driver on a shared NFS
export does not serialise concurrent writers; only the database-backed registry does, and
`database.enabled` is off here. `strategy: Recreate` enforces this across rollouts.

## What this is NOT

It is **not** the module registry. The `<name>/<version>/module.yaml` store — whose
contents authorise the *privileged* broker to pull and run an image **as root** — lives in
a separate dataset (`datapool/eda/modulefiles`), is claimed by
`remote-desktop/nfs-eda-modulefiles-pv.yaml`, and is mounted **only** in the broker sidecar.

They are deliberately separate datasets. Sharing one would put that authorisation boundary
inside an export this ordinary Deployment mounts read-write. Do not merge them back.

Until 2026-09-02 the two were `datapool/eda/registry` and `datapool/eda/modulefiles`, and
this paragraph had to warn readers to "read the dataset, not the word registry" — one word
naming both an OCI blob store and a module-manifest store. That is why the blob store is now
`datapool/images`: the ambiguity was the name's fault, not the reader's.

## Cluster recreate

The PV is `Retain` + static, and the server-side path is deterministic, so pushed images
survive a recreate — which is the point: rebuilding an EDA image from installer media is
hours of Xvfb batch install.

It also carries the **archives** of images whose primary home is GitLab's registry (which is
S3-backed and dies with the cluster): `image-archives/remote-desktop`,
`image-archives/ollama`, `image-archives/vllm`. Those pipelines restore from here instead of
rebuilding. A separate repository namespace from `deployments/…/eda/modules` is deliberate —
module images under `deployments/` are pulled by the broker and run **as root**, so an
archived app image must never be confusable with a module.

Verify content, not just that the PVC is `Bound`. A fresh PVC pointing at the wrong dataset
presents an **empty** registry, and every CI gate here fails open, so all images are then
rebuilt from scratch with no error anywhere:

```bash
kubectl exec -n image-registry deploy/image-registry -- \
  ls /var/lib/registry/docker/registry/v2/repositories/image-archives
```

Growth is the cost: there is still **no GC** (above), and the archives add a few GB per tag
bump on top of the module images. Prune by hand. The node-local podman/buildah caches on the
desktop and runner nodes are a different problem — the kubelet never sees them, so its image
GC never fires; that is tracked in `ToDo.md`.

## Why this registry has no public ingress (credential model)

`service.yaml` says "NEVER give this an HTTPRoute". The reason is **not** that a public
registry is inherently unsafe — GitLab's is public and fine, because it has accounts, scoped
tokens and audit. It is that this one has none of that:

- ~~One account, no read/write split.~~ **FIXED 2026-09-02.** There are now two accounts:
  `eda-push` for CI and `eda-pull` for the broker. Enforcement is NOT in the registry —
  distribution's htpasswd backend authenticates without authorising, so both accounts would
  otherwise be able to push. An nginx front owns TLS, auth and authorisation and refuses
  anything but GET/HEAD for `eda-pull`; the registry itself binds loopback with no auth.
- ~~That one push-capable credential is mounted into a multi-user LDAP desktop.~~ The
  desktop now holds `eda-pull`. A shell there is no longer equivalent to root on the next
  `module load`.
- **Tag-only authorisation.** `broker.sh allowed()` checks `<repo>:<tag>` and never verifies
  content, so overwriting an existing tag makes the broker pull and run that image **as
  root** on the next `module load`, silently.

Today the CiliumNetworkPolicy is what keeps writers down to two namespaces. Publishing would
remove that fence and leave a single shared password as the only control. So this is a
sequencing point, not a permanent veto — to make external exposure reasonable, first:

1. ~~split credentials~~ — **done**;
2. ~~stop mounting a push-capable credential in the desktop~~ — **done**;
3. ~~pin `allowed()` to a digest, not a tag~~ — **done 2026-09-02.** `broker register`
   resolves the tag to a digest and records it in the stored `module.yaml`; `module_image()`
   then pulls `<repo>@sha256:…` instead of `<repo>:<version>`, so overwriting a tag no
   longer changes what runs as root.
   ⚠ A module registered without a resolvable digest still loads by tag — registration must
   not fail because the registry blinked during a recreate — but the broker then warns on
   **every** load until it is re-registered. If you see that warning, the gap is real.

With those, an HTTPRoute becomes a normal decision. It is also the only way to drop GitLab
from the desktop's pull path: the kubelet resolves image refs through the *node's* resolver,
and nodes do not resolve `*.svc.cluster.local` (tried in `b7224bf7`, reverted in `e6fa551b`).

Switching this registry to Let's Encrypt is not possible as things stand for the same
reason: LE only signs publicly-resolvable names, and
`image-registry.image-registry.svc.cluster.local` is internal, so there is no challenge to pass.
