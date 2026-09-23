# module-runtime — the reusable `module load` contract

`module load xilinx/2024.1` is not a portable command. It is a **pod-spec fragment**: a
privileged-adjacent broker sidecar, three volumes, a profile.d drop-in and podman in the
main container. Today remote-desktop is the only pod that carries it; the coming
user-facing machines (SSH + remote desktop) and the EDA CI build pod need the same thing.

This directory is the **canonical definition of that fragment**. It deploys nothing.
`check-module-runtime.sh` (precommit) asserts every consumer carries it consistently, so
the copies cannot silently drift.

## Why a documented fragment and not a Helm chart

A chart renders whole resources. This is a *fragment injected into someone else's pod
spec*, and Helm cannot inject a fragment into a Deployment rendered by a different source —
sharing it would mean every consumer becomes a template of one chart, which is a far larger
change than packaging the runtime.

It would also break the repo's anchoring system: `updateConfigFromProjectSettings.sh`
rewrites literals matched by `# automatically updated from project-settings:<key>` comments.
Inside a template those become `{{ .Values.x }}` — no literal to rewrite — so the anchors,
`checkDomainAnchors.py` and the dataset checks would stop covering them. That machinery is
what keeps a cluster recreate correct.

Precedent for this shape: `check-image-invariants.sh` (one IMAGE_TAG across 3 sites),
`check-subdirs.sh` (CI media paths vs provisioned subdirs), `sync-build-files.sh --check`.

## The four pieces

| piece | what provides it | already shared? |
| ----- | ---------------- | --------------- |
| the `module` shell function | `remote-desktop/module-cli.sh` → `/etc/profile.d/z10-module.sh` | **yes** — one file, baked into the base image |
| the privileged work (pull + run) | `remote-desktop/module-podman.sh` → `module-podmand`, podman in the MAIN container | **yes** — same base image |
| `/modules` + `/run/module-requests` | the broker sidecar publishes metadata here | no — pod-spec fragment |
| `/registry` (the module manifests) | `nfs-eda-modulefiles` export | no — one PV/PVC per namespace |
| the image cache | `hostPath: /var/lib/eda-module-podman` | **yes, per node** — see below |

So only the **pod-spec fragment** is duplicated. The two scripts are single-source already.

## The image cache is shared per node

Every consumer on a node names the SAME graphroot, `/var/lib/eda-module-podman`. That is
deliberate and load-bearing: the `xilinx/2024.1` image is two layers and the second is a
single **42.8 GB blob**, which at the ~32 MB/s this registry sustains is ~23 minutes. One
pull per node then serves the desktop, CI, and any future user-facing machine.

The kubelet's own image cache cannot do this job — podman *inside* the pod does the pull, so
containerd never sees the layers (measured: 43 cached images on pcie-tb-s, none of them EDA).

Two writers into one store is safe on two locks, and **both live in the store, not in a
pod**:

| lock | serialises |
| ---- | ---------- |
| podman's `storage.lock` (in the graphroot) | the store's own metadata writes |
| `<graphroot>/.module-pull-locks/.lock.<img>` | one pull per image, node-wide |

⚠ The pull lock used to sit in the pod-local `/run/module-requests`-style emptyDir, where it
serialised only the users of ONE pod. Two pods sharing a store would each have taken their
own copy and both started the same 42.8 GB fetch. `module-podman.sh` now derives the lock
directory from `podman info .Store.GraphRoot`. **Do not move it back into a pod.**

⚠ An `emptyDir` store is not an option: it dies with the pod and re-pulls the 42.8 GB blob
every time. `check-module-runtime.sh` asserts the hostPath, the shared literal path, and
that the runner's TOML names the same one.

⚠ Sharing couples the writers. The `[eda-run]` runner is safe at `concurrent = 1`; raising
it needs a hard one-build-per-node anti-affinity first. And **never leave a foreign storage
driver in the store** — a `--storage-driver vfs` probe left `vfs*` dirs behind once and
podman then refused every overlay pull instantly ("FAILED to pull" in under a second). Wipe
the store on *both* builder nodes if that happens; a single-node exec is not enough.

## The contract every consumer must satisfy

```yaml
spec:
  # ⚠ gVisor is NOT optional — see "the sandbox is the boundary" below.
  runtimeClassName: runsc
  containers:
    - name: <main>                       # runs module-podmand + the user's shell
      volumeMounts:
        - { name: modules,         mountPath: /modules }
        - { name: module-requests, mountPath: /run/module-requests }
        - { name: registry-cred,   mountPath: /var/run/registry-cred, readOnly: true }
        - { name: podman-store,    mountPath: /var/lib/containers/storage }  # shared node cache
    - name: broker
      command: ["/usr/local/bin/broker"]
      # ⚠ NO `privileged: true`. See below — it breaks the whole pod on pcie-tb-d.
      env:
        - { name: REGISTRY_HOST, value: "image-registry.image-registry.svc.cluster.local:5000" }
        - { name: IMAGE_BASE,    value: "deployments/infrastructure/eda/modules" }
      volumeMounts:
        - { name: registry,       mountPath: /registry }          # rw ONLY here
        - { name: modules,        mountPath: /modules }
        - { name: module-requests, mountPath: /run/module-requests }
        - { name: registry-cred,  mountPath: /run/registry-cred, readOnly: true }
  volumes:
    - { name: modules,         emptyDir: {} }
    - { name: module-requests, emptyDir: {} }
    # ⚠ The SHARED per-node image cache — same literal path in every consumer, hostPath
    # never emptyDir. See "The image cache is shared per node" above.
    - name: podman-store
      hostPath: { path: /var/lib/eda-module-podman, type: DirectoryOrCreate }
    - name: registry
      persistentVolumeClaim: { claimName: <per-namespace claim on nfs-eda-modulefiles> }
```

## Three traps, each already paid for once

**1. The sandbox IS the security boundary.** `module-podmand` runs podman **as root inside
the pod** to pull and run module images. What makes that acceptable is `runtimeClassName:
runsc`, not any capability grant. A consumer without gVisor is a materially different
security posture — which is why the `[eda]` CI runner (`privileged = true`, no gVisor)
**cannot** simply adopt this; it gets a separate gVisor build pod instead.

**2. The broker MUST NOT be privileged.** runsc cannot start a privileged *subcontainer* on
unibi-hclab-pcie-tb-d, and a sidecar is always a subcontainer. The sandbox dies mid-`/sys`
mount and **all containers fail together**, which reads as a pod-wide fault rather than one
container's securityContext. Do not add it "because skopeo needs it" — the broker mounts
nothing.

**3. `/registry` rw is root-execution authority.** Writing `<name>/<version>/module.yaml`
there is what permits the broker to pull and run an image as root (`broker.sh allowed()`,
fail-closed). Being a separate dataset does NOT make it a separate ACCESS boundary — NFS
scopes by client network and these pods share a node, so the server sees one source IP.
**The real boundary is which containers mount it.** Mount it in the broker sidecar ONLY —
never in the main container, never in the CI runner.

⚠ A consumer that only *consumes* modules still needs `/registry` in its broker sidecar
(the broker reads the manifests). It must never appear in the container where users have
shells.

## Adding a consumer

1. Its own PV/PVC pair against the `nfs-eda-modulefiles` export — a PV binds to exactly ONE
   PVC, so a second namespace cannot reuse remote-desktop's. Give the PV a **unique
   `volumeHandle`**: the driver treats it as the volume's identity and changing one orphans
   the binding.
2. Copy the fragment above verbatim.
3. Register the file in `check-module-runtime.sh` so drift is caught.
4. Use the desktop base image (it carries `broker`, `module-podmand` and the profile.d
   drop-in), or install those three yourself.

⚠ `bash -lc`, not `bash -c`, in any automated consumer: `/etc/profile.d` is sourced by
**login** shells only, and the base image's bashrc fallback is guarded to *interactive*
shells. A Job's exec is neither, so `module` does not exist without `-l`.
