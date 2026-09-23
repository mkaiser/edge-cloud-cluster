# Generic EDA desktop — runtime-loadable applications (`module load`)

An Ubuntu/Xfce desktop where EDA applications (Vivado, HyperLynx, …) are loaded
**at runtime**, HPC `module load` style — instead of baking one tool into the
image (`xilinx-2026-1`) or installing one into a PVC (`hyperlynx`).

## The tile

Guacamole shows **one** tile, `EDA Workstation` —
[`desktop-gvisor.yaml`](desktop-gvisor.yaml), RDP on 3389, serving the container
modules. It gives you a private Xfce session authenticated with your own
Authentik/LDAP credentials; sessions are never shared. (A local `desktop` account
remains as a break-glass login for when Authentik or the mesh is down; it is not the
normal path.)

**Sessions are per login.** Log out and the session ends, so a long-running GUI job
dies with it. Run those through the module/batch path instead (see below).

### Why does the desktop ask for a password again?

Logging into Guacamole with Authentik SSO does **not** log you into the desktop. You
land on xrdp's own greeter and type your Authentik/LDAP username and password there.
That is expected, and it is not a missing configuration — there is nothing to fill in:

- Guacamole authenticates you by **OIDC**. It receives an ID token, never a password,
  so it has no credential to replay into the RDP connection.
- RDP itself has no OIDC path. The seeded connection could carry static `username` /
  `password` parameters, but those are one shared account for every user, which
  defeats the per-user LDAP session the whole design rests on. So they are
  deliberately absent (see [`connection-seed.yaml`](connection-seed.yaml)).

If it should become true SSO, the change is real work, not a setting: Guacamole would
need a credential-bearing auth extension (its LDAP or header extension, or the
`vault`/KSM extension holding per-user secrets) so that `${GUAC_USERNAME}` /
`${GUAC_PASSWORD}` tokens resolve to something, or the desktop would need Kerberos
against the Samba AD DC so xrdp could accept a forwarded ticket.

## How it works (target design)

- Each application is published as an OCI image. EDA module images live in the **lab-local**
  `image-registry` (`image-registry.image-registry.svc.cluster.local:5000/deployments/infrastructure/eda/modules/<name>:<version>`),
  not GitLab's — that is also what makes them survive a cluster recreate.
- Every module declares **`runtime: container`** (`xilinx/2024.1`, `xilinx/2026.1`,
  `hyperlynx/2604`): the desktop's `podman` runs the image directly inside the
  gVisor-sandboxed pod.
  - An unprivileged LDAP user cannot pull into the shared root podman store themselves (no
    `/etc/subuid` entry, no `newuidmap`, and gVisor refuses the mapping), so both the pull
    and the run are delegated to **`module-podmand`**, a root helper in the desktop
    container, through a 0733 request dir. It re-validates every request and passes the
    caller's uid/HOME/cwd/DISPLAY through, running the container as `--user <caller>`.
- The broker only acts on modules **registered in the module registry**
  (`/registry/modules/<name>/<version>/module.yaml`, its own TrueNAS NFS export) — see
  [`register-module.sh`](register-module.sh) and the trust model in
  [`doc/nested-container-runtime.md`](../../../doc/nested-container-runtime.md).

## Batch / scripted use of a container module

A container module puts nothing on `PATH` by way of Lmod — there is no modulefile. To make
one usable from a script, list its command-line tools under `cli_entries` in its
`module.yaml` (alongside `desktop_entries`, which stay GUI-only):

```yaml
cli_entries:
    - name: vivado # the wrapper's name == the tool's name
      command: /opt/Xilinx/2024.1/Vivado/bin/vivado # full path INSIDE the container
    - name: hw_server
      command: /opt/Xilinx/2024.1/Vivado/bin/hw_server
```

`module load` then generates one wrapper per entry into
`$HOME/.local/module-bin/<name>/<version>/` and prepends that directory to `PATH`, so an
existing script runs unchanged:

```bash
source /etc/profile.d/z10-module.sh     # REQUIRED in a non-interactive shell — see below
module load xilinx/2024.1

vivado -mode batch -source build.tcl    # each invocation = one podman run
hw_server &
```

Each call starts its own short-lived container. `$HOME` is bind-mounted **at the same path**
inside and out and is the working directory, so tools read your project files and write
results straight back — which is also how two container modules exchange artifacts (one
writes into `$HOME`, the next reads it). Nothing else from the desktop is visible: `/tmp` is
not shared (only the X11 socket) and `/smb` is deliberately unreachable.

Verify entry paths against the **built image**, not the Dockerfile — optional components may
be switched off in `install_config.txt` (Vivado 2024.1 ships `xsdb` but has no `xsct`,
because Vitis is not installed):

```bash
podman run --rm --entrypoint /bin/sh <image> -c 'ls /opt/<tool>/bin'
```

Two behaviours that matter for scripting, both new in `base-r27`:

- **Exit codes propagate.** The wrapper exits with the container's status, so `set -e` and
  `if ! vivado ...` work. Before r27 it exited 0 on completion regardless, and a failed
  synthesis looked like success.
- **Output is streamed** to the wrapper's stderr (the helper also keeps a per-run log at
  `/var/log/module-run.<uid>.<reqid>.log`). Redirecting stdout does not swallow progress
  text.

**`source /etc/profile.d/z10-module.sh` explicitly** in any non-login shell. Lmod's own
`lmod.sh` exports `BASH_ENV`, which bash sources for every _non-interactive_ shell and
silently restores the raw `module` function — so a script can otherwise behave differently
from your terminal, which is a miserable failure to debug.

`module unload <name>/<version>` removes the shims from `PATH` again.

## Storage

| PVC                    | Class         | Mode | Purpose                                          |
| ---------------------- | ------------- | ---- | ------------------------------------------------ |
| `nfs-eda-modulefiles`  | static NFS PV | RWX  | module REGISTRY — **broker sidecar only**        |
| `nfs-homes`            | static NFS PV | RWX  | per-user `/home`                                 |
| `nfs-shared-data`      | static NFS PV | RWX  | curated common area, `/shared`                   |
| `nfs-shared-tmp`       | static NFS PV | RWX  | world-writable scratch, `/shared/tmp` (1777, 1T) |

Each claim is named for the TrueNAS dataset behind it (`nfs-<path>`), and the PV, the PVC
and the manifest filename all carry that same name — `check-subdirs.sh` enforces it.

⚠ **`nfs-eda-modulefiles` is mounted ONLY in a broker sidecar, and the set of pods that
mount it IS the security boundary.** Write access to the registry authorises the broker to
pull and run an image as root, and no export rule can narrow that — the server cannot
distinguish the broker from the [eda] runner, which share a node.

Two pods hold that grant today, each through its OWN claim over the same export
(`remote-desktop`'s `nfs-eda-modulefiles`, and `remote-desktop-bender`'s
`nfs-eda-modulefiles-bender` — see `deployment/argocd-apps/remote-desktop-bender/`). Adding a
third widens the boundary again, and nothing warns you: register any new consumer in
`module-runtime/check-module-runtime.sh` so the grant is at least visible in one place.

Module images are held by the lab-local `image-registry` on `datapool/images`, outside
the cluster, so they survive a recreate — see `doc/storage-architecture.md`.

## SSH access (RDP is not the only way in)

The desktop runs sshd from image `base-r29` onward, in addition to xrdp. Same LDAP
identity, same PAM/SSSD stack — no separate credential store.

```bash
ssh <ldap-user>@remote-desktop-gvisor-vnc.remote-desktop.svc.cluster.local
```

Useful for SFTP and for `ssh -X` to run one GUI tool without taking a whole Xfce session
over RDP. The container listens on **2222**; the Service publishes **22**, so no `-p` is
needed. That split is deliberate: it keeps a tailnet grant for the desktop from being
confused with a grant to a NODE's sshd (which stays operator-only).

⚠ These are ClusterIP names and a VPN client cannot reach them — the k3s service CIDR
(`10.43.0.0/16`) is deliberately not advertised into the tailnet, because advertising it
would make every ClusterIP in the cluster routable from the tailnet.

From a laptop, use the tailnet name instead: **`remote-desktop.ts.internal`** on 3389 (RDP)
or 22 (SSH), served by the tailscale sidecar in `desktop-gvisor.yaml`. Any personal device
on the tailnet already has the grant (`autogroup:member` -> `tag:desktop` on 22/3389).

⚠ **That name can point at a DEAD registration.** The sidecar's state is an `emptyDir` (a
deliberate choice, see `desktop-gvisor.yaml`), so every pod roll re-registers and headscale
de-duplicates the name with a `-N` suffix — leaving the clean name held by the offline
predecessor while the live pod answers as `remote-desktop-1`. Measured 2026-09-13; it was the
only drifted name in the tailnet. Confirm the live one with
`kubectl -n remote-desktop exec deploy/remote-desktop-gvisor -c tailscale -- tailscale status
--self --peers=false`, and clear the stale entries with `make prune-orphaned-mesh-nodes`.
VSCode Remote-SSH setup: `doc/vscode-remote-ssh-desktop.md`.

Two constraints on that sidecar, both worth knowing before editing it:

- **It must run userspace.** This pod is `runtimeClassName: runsc`, so it cannot have the
  `privileged: true` + `/dev/net/tun` hostPath that the mesh-gateway DaemonSet's tailscaled
  uses. Do not copy that recipe here.
- **Hence `TS_SERVE_CONFIG`, not `TS_DEST_IP`.** containerboot hard-errors
  `"TS_DEST_IP is not supported with TS_USERSPACE"` (and likewise for
  `TS_EXPERIMENTAL_DEST_DNS_NAME` / `TS_TAILNET_TARGET_*`). The forwarding lives in
  `tailscale-serve-configmap.yaml`, which points 3389 at `localhost:3389` and 22 at
  `localhost:2222` — **2222**, because the container listens there and only the Service
  maps 22.

### Public-key auth comes from LDAP, not `~/.ssh/authorized_keys`

Set a `sshPublicKey` attribute on the Authentik user (User → Attributes, or a blueprint):

```yaml
attributes:
    sshPublicKey: "ssh-ed25519 AAAA... user@laptop" # a list works too, for several keys
```

sshd reads it via `AuthorizedKeysCommand=sss_ssh_authorizedkeys`, so the key works on a
brand-new account at first contact and nothing about key auth touches the home filesystem.
Two reasons it is done this way rather than with a key file in `$HOME`:

- `/home` is moving to TrueNAS. On a network filesystem OpenSSH `StrictModes` cannot trust
  the ownership/mode of `~/.ssh/authorized_keys`, and it refuses the key rather than
  warning — which looks to the user like an unexplained password prompt.
- A key in `$HOME` can only be installed _after_ a first password login, so keys could
  never be the primary factor.

`~/.ssh/authorized_keys` is still honoured (`AuthorizedKeysFile` is left at its default),
so anyone who already placed a key there keeps working. Password auth also remains on.

## Privilege note

The broker runs `privileged: true`. It holds the registry credential and mounts the module
registry — writing to that registry is what authorises a module to be pulled and run. This
is a stronger grant than `xilinx`/`hyperlynx` request and is contained to the broker
sidecar; unprivileged LDAP users cannot enter it.

**The broker publishes metadata only** — `<name>/<ver>.module.yaml` and `.ready/<n>-<v>`,
plain files in the shared emptyDir. It never pulls or runs the module image. That happens
in the DESKTOP container, where `module-podmand` (a root helper reached through its own
0733 request dir) pulls into the shared root store and runs the container as the calling
user. Users cannot invoke podman against that store themselves.

> When changing any of this, **run the tool** — do not just confirm the mount exists. The
> original bug reported READY, had a real mount, and printed no error.

## Build files (KEEP IN SYNC BY HAND)

The base image is built in-cluster on the shared `[eda]` GitLab runner. Its build
inputs live here as `Dockerfile.base` + `ci-base.yml` and are MIRRORED into the
GitLab project `deployments/infrastructure/eda/remote-desktop` by
`presync-build-desktop.yaml` — via `build-files-configmap.yaml`, which embeds a
copy under the canonical names `Dockerfile` / `.gitlab-ci.yml`. **If you edit
`Dockerfile.base` or `ci-base.yml`, regenerate `build-files-configmap.yaml`** (the
trigger reads the ConfigMap, not the raw files). Bump `IMAGE_TAG` in `ci-base.yml`
to force a rebuild.

## What is in this directory

|                                                                                               |                                                                |
| --------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `desktop-gvisor.yaml`                                                                         | the desktop Deployment (+ broker sidecar)                      |
| `startup-configmap.yaml`                                                                      | the startup script the pod runs                                |
| `vnc-services.yaml`                                                                           | the RDP/SSH ClusterIP Service                                  |
| `values.yaml`, `httproute.yaml`, `postgres.yaml`                                              | Guacamole (chart values, routing, CNPG database)               |
| `connection-seed.yaml`                                                                        | seeds the Guacamole tile + permissions                         |
| `authentik-provider.yaml`, `sealSecrets.sh`                                                   | OIDC provider, sealed secrets                                  |
| `Dockerfile.base`, `ci-base.yml`, `presync-build-desktop.yaml`, `build-files-configmap.yaml` | base-image build (see above)                                   |
| `broker.sh`, `module-cli.sh`, `module-podman.sh`, `register-module.sh`                        | the module machinery                                           |

## Before first deploy

```
deployment/argocd-apps/remote-desktop/sealSecrets.sh   # generate *-sealed.yaml
```

## Self-contained

The registry pull credential uses the shared `deployments`-group `registry-pull`
deploy token. This app's own build-trigger (`presync-build-desktop.yaml`, PreSync
wave 0) **creates the `deployments/infrastructure/eda` group** before the
credential job (wave 1) runs — so `remote-desktop` does not depend on `xilinx`/`vllm`
being deployed. The build runs on the shared `[eda]` runner
(`app-of-apps/gitlab-runner-eda.yaml`), which mints its own token.
