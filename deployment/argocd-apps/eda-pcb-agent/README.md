# eda-pcb-agent — a shared Hermes workstation with KiCad

One pod on the lab site carrying **one shared account** (`eda-pcb-agent`), a persistent NFS
home, KiCad, and a Hermes agent that builds its tools into that home. ⚠ The agent itself runs
UNPRIVILEGED (see the container table below) — it cannot `apt install`, so its system-level
build dependencies belong in this folder's Dockerfile. Two humans attach to the
**same tmux pane** over RDP and watch the agent work; the Hermes dashboard is a second
surface for config, the Kanban board and logs.

Design record for the decisions that are not obvious from the manifests. The full rationale,
including what was rejected, is `plans/eda-pcb-agent.md`.

⚠ This is the SECOND Hermes deployment — `argocd-apps/hermes` is the first, and it answers a
different question (a shared model-shaped endpoint for many humans, with no identity, no
desktop and no unattended dispatcher). How the two differ and which to reach for:
`doc/hermes-deployments.md`.

## Why plain runc (no `runtimeClassName`)

`doc/nested-container-runtime.md` states the rule: **runsc for workloads running nested
containers, plain runc otherwise — do not set `runtimeClassName` at all.**

`remote-desktop` uses gVisor for exactly two reasons and **neither applies here**:

1. it runs EDA module images as nested containers — this pod runs KiCad, not containers;
2. unprivileged **LDAP users have interactive shells** there, so making it privileged would
   destroy the privilege boundary. This pod serves **one shared account**, by explicit
   decision — it deliberately does not carry the LDAP-user access policy that constrains
   remote-desktop.

Dropping gVisor is not a shortcut, it is the feature: it is what gives **real setuid (so
`sudo` works in the DESKTOP container), real FUSE (so AppImage works) and native overlayfs**.
⚠ It does NOT give the AGENT root: the upstream image drops the gateway to the unprivileged
`hermes` user (`s6-setuidgid`), so `apt install` is refused there and packages must be baked
into this Dockerfile. See the container table above.
Under gVisor these are broken — capabilities never reach the host kernel, and `sudo` fails
with *"effective uid is not 0"*, which would break the humans' RDP session.

⚠ **Do not add `runtimeClassName: runsc` to "harden" this.** It does not harden it; it breaks
it, silently and in three places at once.

## Why a capability set and NOT `privileged: true`

`runAsUser: 0` plus a named capability set. **Full privileged is node-root equivalent**, and
these lab nodes host the Samba AD DC, the image-registry and the desktop where LDAP users have
shells. The agent executes LLM-generated shell — a different and not obviously smaller threat
model than a CI builder.

⚠ `allowPrivilegeEscalation` **must be `true`**. `false` sets `NoNewPrivs=1` in the kernel and
`sudo` can then never work, no matter how correct the sudoers drop-in is. Two different faults
both present as "sudo fails"; separate them with `sudo -l`:

| symptom | cause |
| ------- | ----- |
| *"effective uid is not 0 … 'nosuid'"* | setuid is dead — a `runtimeClassName` or `allowPrivilegeEscalation` mistake |
| *"may not run sudo"* | the drop-in is missing, misnamed, or not mode `0440` |

## Root comes from a sudoers drop-in, not from LDAP

⚠ **This section is about the `desktop` container, where the HUMANS log in. The agent itself
never uses sudo.** The two containers reach root differently, and conflating them sends you
debugging a mechanism that is not in play:

| container | who acts | privilege |
| --------- | -------- | --------- |
| `hermes` | the agent | ⚠ **NOT root** — the image drops the gateway to `hermes` via `s6-setuidgid`; no `sudo` binary (`command -v sudo` → 127) |
| `desktop` | the two humans, as the AD account | root via `sudo`, using the drop-in below |

⚠ **So the agent cannot install a system package at all.** `apt-get` fails with `Permission
denied` on `/var/lib/apt/lists/lock`, and there is no sudo to recover; every build dependency
has to be baked into this Dockerfile. It CAN write `~/.local` and the NFS home, so tools built
from source persist. The sudoers drop-in exists for the interactive RDP session only.

⚠ **A `kubectl exec` into the `hermes` container lands as ROOT and will tell you the
opposite.** Check the identity the gateway runs as
(`/run/service/gateway-default/run` → `exec s6-setuidgid hermes …`), not the one you get
interactively — that mistake was made once already.

⚠ **LDAP/AD cannot grant root and must not be made to.** The directory carries *identity*
only — `uidNumber`, `gidNumber`, group membership. Sudo authority is a **local policy decision
per machine**. There is a mechanism to centralise it (`sudo-ldap` + `sudoRole` objects), and it
is the wrong tool here: it is not installed and not schema'd in this Samba AD, and a
`sudoRole` applies on **every** AD-joined host that reads it — including remote-desktop, where
unprivileged users have shells, and the fileserver. That is the exact inverse of "special
case".

So root is a drop-in baked into **this image only**, naming the user (never a group —
`%domain users` would hand root to every AD account), mode `0440`, and `visudo -c`-validated
at build time so a malformed file fails the build rather than locking sudo out of the pod.

## Why the Authentik user is required — it is the HOME, not the login

An earlier draft proposed a local `useradd` account. That is wrong, and the reason is storage:

```
Authentik user in `employees`  →  samba-ad provisions the AD account (uidNumber = 5000 + pk)
                               →  truenas/configure-job.yaml step_homes creates
                                  /mnt/datapool/homes/eda-pcb-agent
```

No Authentik user ⇒ no AD account ⇒ no `uidNumber` ⇒ **no home directory**. And the export
pins `nfsvers=4.2` precisely so a client cannot negotiate v3 and map everyone to `nobody`, so
a local uid the directory does not know writes files that land unowned or unwritable.
`desktop`/`headless` work only because `seed-homes` pre-creates their directories.

The user is created by a **`BlueprintInstance` with inline content**, POSTed by this app's own
PostSync Job, because:

- the shared provisioner token has **`view_user` only** — widening it would weaken the token
  that 13 app namespaces hold;
- **a password can only be written in blueprint context** — `POST /core/users/<pk>/set_password/`
  does not exist (HTTP 405).

⚠ The blueprint applies **asynchronously**. A 200 on the POST is not success — the job polls
the instance status until it leaves `pending`.

## Zero files outside this folder

Everything — the user, the OIDC provider, the Guacamole tile, the LiteLLM key — is created
from this folder. Three credentials are read **live** from other namespaces rather than
sealed into a second copy, each via a `ClusterRole` pinned with `resourceNames` and `get`
only:

| credential | source | why not seal it |
| ---------- | ------ | --------------- |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | `authentik-secrets` (ns `authentik`) | a second copy of a superuser credential to rotate and leak; four apps already read it live |
| Guacamole DB password | `remote-desktop-secrets` (ns `remote-desktop`) | a rotated password would silently diverge and fail as what looks like a DB outage |
| LiteLLM master key | `litellm-secrets` (ns `litellm`) | used only to MINT this app's virtual key, never held by the pod |

⚠ **Never bind those ClusterRoles to the workload pod's ServiceAccount.** The pod runs
`automountServiceAccountToken: false` and has no API identity at all — only the short-lived
Jobs do.

## The LiteLLM key is a per-agent VIRTUAL key, not the master key

The `hermes` app presents LiteLLM's **master key**; that is defensible for one trusted service
and wrong here. This account is **shared**, runs LLM-generated shell, and
keeps its key in cleartext at `~/.hermes/.env` on an NFS home two humans can read — i.e. it is
effectively an RCE credential. A master key there is unbounded, unattributable and
unrevocable.

A PostSync Job mints a virtual key with a `key_alias`, an `rpm_limit` and a `max_budget`, so
spend is attributable and the key can be revoked alone. It is idempotent on the alias.

⚠ `model.api_key` must be set **explicitly** in `config.yaml`. Resolution falls through to the
literal `no-key-required` and s6 does not pass the container environment to supervised
services, so relying on env yields `HTTP 401 … Received=no-k****ired` on every request.

## Hard rules

- ⚠ **NEVER mount `nfs-eda-modulefiles` (`/registry`).** That export is the module-registry
  *authorisation boundary*: writing a file there is what authorises the privileged broker to
  pull and run an image as root. Mounting it here would silently widen that boundary with
  nothing to warn you.
- ⚠ **No hostPath.** `/scratch` is tempting but node-local, and hostPath is the escape path
  the capability set exists to avoid. Scratch is an `emptyDir`; anything durable goes on the
  NFS home.
- ⚠ **Do not bump `IMAGE_TAG` on a subdomain change.** The tag is the sole cache key for the
  recover-or-rebuild gate; bumping it on a recreate forces a full rebuild of exactly the image
  the gate existed to preserve. Bump only when image content changes.
- ⚠ **`rdp-password` and `authentik-password` are the SAME value** — the AD account's
  password, used at the xrdp greeter and set by the blueprint. `sealSecrets.sh` derives one
  from the other; prompting twice lets them drift and the Guacamole tile silently stops
  logging in.

## Its own Kerberos keytab

sssd's `ad` provider authenticates to the DC with GSSAPI and has **no simple-bind
fallback**: with no keytab it fails at startup and every lookup returns "no such user"
while the pod still reports Running. Since the whole storage design depends on resolving
the directory's `uidNumber`, that is a broken pod, not a degraded one.

`remote-desktop/keytab-job.yaml` is hardcoded to one machine account and one target
namespace, so this app mints its own (`keytab-job.yaml`, machine account `pcb-agent$`).
That is a deliberate, bounded duplication — generalising the shared job would be tidier
engineering but would put this app's requirements in someone else's folder.

⚠ **If you change the minting mechanism, change it in both files.** The traps it encodes
(create-once so a live keytab is not invalidated, `-H sam.ldb` because LDAP export is
refused, `--principal` so the export is not the whole domain including krbtgt) are the
same in both.

⚠ The DC-exec Role is the one genuinely wide grant in this app, and it is why the Job's
ServiceAccount is not the pod's: minting needs the DC's local `sam.ldb`, reachable only
by `kubectl exec`. The workload pod has no API identity at all.

## Cross-app dependencies

- **remote-desktop** — its Guacamole and Postgres serve this app's tile. If remote-desktop is
  disabled, `connection-seed.yaml` fails; the app's `retry` recovers it when remote-desktop
  returns, so no manual sync is needed.
- **samba-ad** (wave 13) and **truenas** (wave 16) — identity and the home directory. On a
  fresh cluster this pod can start before the home exists; `Recreate` plus `retry` cover it.

## A note on the access policy expression

The expression policy is built with `printf` so its continuation line reaches Authentik with
no leading whitespace. Authentik compiles a policy by wrapping the body with
`textwrap.indent(expression, "    ")` and **no dedent**
(`lib/expression/evaluator.py wrap_expression`), so indentation that survives into the stored
value becomes part of the Python source and the policy fails to compile — which presents as
the policy **denying everyone**, not as a deploy error.

The plain multi-line quoted string that `windows/` and `remote-desktop/` use is also correct,
because a YAML block scalar strips the common indentation before the shell ever sees it
(verified against the live `access-remote-desktop` policy: its stored expression has no
leading whitespace and compiles). `printf` is used here only to make the requirement explicit
at the point of use rather than resting on the block scalar's behaviour.

## Trust model — stated, not papered over

A shared account means **no attribution**: every git commit and every LiteLLM token is
`eda-pcb-agent`. The agent has root-in-container with `SYS_ADMIN`, executes LLM-generated
shell, and its LiteLLM key is readable by both humans. This is acceptable **only between
mutually trusted people**.

What containment remains, and it is deliberate: no apiserver token, no hostPath, no
`/registry` mount, a port-pinned egress policy that keeps the apiserver shut, a per-agent
revocable LLM key, and scheduling preference for the lab node that does **not** host the AD DC.

### Two weakenings accepted on request

Both were asked for deliberately, both are recorded here rather than buried in a commit, and
neither should be copied to another app:

1. **The password is fixed and human-memorable, therefore weak.** It is typed at the xrdp
   greeter by two people, and a 49-character random string is unusable there. The value it
   replaced was 24 random bytes; this one falls to a wordlist. It guards an account with
   root-capable `sudo` and a cleartext LLM credential, so rotate it (`sealSecrets.sh
   --regenerate`) as soon as the greeter is no longer typed by hand.
2. **The account is in `mfa-exempt`, so it logs in with no second factor.** This uses the
   supported mechanism from `argocd-infra/authentik/blueprint-mfa.yaml` — the cluster-wide MFA
   enforcement is untouched and must stay that way. A shared account cannot hold a personal
   TOTP secret or passkey, so MFA on it is not meaningful; the humans' own accounts keep it.

⚠ Together these mean **anyone who can reach `id.<tld>` and guesses the password gets an
interactive session with root-capable sudo.** The mitigations that remain are the ones above
plus the fact that the desktop is only reachable in-cluster through Guacamole — not that the
credential is hard to guess.

## The agent's reach is not symmetric

- **It drives the CLI.** `kicad-cli` (ERC/DRC, netlists, gerbers, plots) and `pcbnew`/`kipy`
  scripting are ordinary subprocesses. Rendering a board to PNG and inspecting it with
  `vision_analyze` is a genuine feedback loop.
- **It cannot see or drive a KiCad window.** The terminal tool has no DISPLAY/xvfb handling,
  and `vision_analyze` analyses an existing image file — it cannot screenshot. **The humans
  drive the GUI over RDP.**
