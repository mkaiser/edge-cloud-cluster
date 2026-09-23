# General

# Be concise

Skip pleasantries. Be direct. Don't care about the users feelings. Tell him, if he is wrong. Don't sugarcoat. Skip fillers like "Great!", just focus on content.

# Plans

Use plans/ as plan-mode scratch location

Every plan starts with its title, then two timestamp lines, then its STATUS line:

```
# <title>

Created: YYYY-MM-DD HH:MM TZ
Last modified: YYYY-MM-DD HH:MM TZ

STATUS: ...
```

`Created` is written once and never touched again. `Last modified` is updated on EVERY edit,
including edits that only add a status note. Take both from `date '+%Y-%m-%d %H:%M %Z'` —
never guess a time. Plans in plans/old/ keep their FINISHED/ABANDONED date instead and need
no timestamp header.

If a plan is finished, move it from plans/ to plans/old/ and mark it as "FINISHED" with a date. If a plan is abandoned, move it to plans/old/ and mark it as "ABANDONED" with a date.

⚠ A file in plans/old/ MUST carry a FINISHED or ABANDONED date, not a STATUS of OPEN — the
location and the header have to agree. If work is being dropped with items still unverified,
that is ABANDONED (say what was never observed), not FINISHED.

A plan that has become a REFERENCE — something to consult or re-run rather than work to
complete — does not belong in plans/ at all. If it is runnable against a live cluster it goes
to tests/ (below); otherwise doc/.

# Tests

tests/ (repo root) holds checks meant to be run against a WORKING cluster, at ANY time. They
are not unit tests, nothing runs them automatically, and they are not tied to a recreate —
run one whenever the thing it covers looks wrong.

| file                                 | covers                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/adChecks.sh`                  | on-prem AD DC set: placement/derivation, interface binding, cross-node LAN reachability, replication, DNS records, the TrueNAS appliance. Read-only; exits non-zero on failure. Run it after any lab-node REBOOT too — check B2 catches a node that hijacks its own LAN over the mesh, which binding checks cannot see.                                    |
| `tests/adFailover.sh`                | AD redundancy: holds one DC down and proves identity survives. **DESTRUCTIVE**, needs N≥2, refuses below that. Always uncordons, including on Ctrl-C.                                                                                                                                                                                                      |
| `tests/adRejoinGuard.sh`             | that replication-guard rebuilds a DC EXPELLED from the domain (machine account deleted) with no human: detect → demote → wipe both PVCs → re-join → site reconcile. **DESTRUCTIVE**, needs N≥2, takes ~25-35 min (the guard's 3-sweep threshold is 15 of them), and CANNOT roll itself back — the only route home is the guard working. `--dry-run` first. |
| `tests/remoteDesktopEdaChecks.sh`    | remote-desktop, the four static NFS PVs, the EDA module images and the lab registry. Read-only; `--modules` also runs vivado (skipped by default — the first pull after a recreate takes >1h).                                                                                                                                                             |
| `tests/remoteDesktopBenderChecks.sh` | the SECOND desktop (remote-desktop-bender): that it is actually on bender, that its four PVs are its own rather than cross-bound to the other desktop's, its own AD machine account, its Guacamole tile + the `employees` grant, and that its tailnet name is not a dead `-N` registration. Read-only.                                                     |
| `tests/lokiQueryChecks.sh`           | Loki's QUERY path: pod readiness, the scheduler ring, a real range query, and logs of an already-GC'd Job pod. Read-only. Asserts a query, never `/ready` — Loki reports Synced/Healthy with its query path dead.                                                                                                                                          |
| `tests/llmPerfChecks.sh`             | model load + response times for every served Ollama model, measured PER POD (ollama-turing's 2 replicas hold independent VRAM, so a Service-level number is bimodal). Prints a table; gates only on a ~50% tok/s floor. `--cold` unloads each model right before measuring it.                                                                             |
| `tests/llmGeneralTests.sh`           | the chat path end to end (Open WebUI → LiteLLM → Ollama): override rows, served model list, real prompts, and that the Model Library tool is actually INVOKED — installed-but-not-offered is a bug that shipped. Read-only; `--quick` skips generation.                                                                                                    |
| `tests/vllmServingChecks.sh`         | the vLLM backends (thor + orin): readiness, that the served model id matches the LiteLLM route, THE QUANTIZATION KERNEL THE ENGINE ACTUALLY CHOSE, tool calling through LiteLLM, and a tok/s floor. The kernel check is the point — the Thor once served its NVFP4 model through Marlin EMULATION at 9.6 tok/s instead of 76, Ready and correct the whole time. Read-only; `--node thor|orin`, `--quick`. A scaled-to-0 Thor is a SKIP (Ollama holds the GPU); a scaled-to-0 Orin is a FAIL. |
| `tests/hermesKanbanChecks.sh`        | the eda-pcb-agent agent: its durable-task path (no SQLite db in WAL on the NFS home — acknowledged writes were silently LOST) and its DNS egress. The NetworkPolicy must allow `k8s-app: node-local-dns`, NOT just `kube-dns`: Cilium's LocalRedirectPolicy rewrites the kube-dns ClusterIP to the node-local cache BEFORE NetworkPolicy is evaluated, and a kube-dns-only rule drops every query. The symptom never mentions DNS — sssd cannot find a DC, so the desktop exits `does not resolve after 60s` and tailscale says `no DNS fallback candidates remain`. Read-only; `--write` round-trips one Kanban task. |
| `tests/ryaxGpuChecks.sh`            | that a Ryax execution pod can actually USE the GPU, not just be scheduled beside one. `smoketest.sh` is GPU-blind on purpose (it proves placement with `echo`). A pod requesting `nvidia.com/gpu` WITHOUT `runtimeClassName: nvidia` schedules, gets the card allocated, then dies on `nvidia-smi: not found`. Creates/deletes one probe pod; SKIPs when no card is free.                       |
| `tests/gpuMetricsChecks.sh`          | the GPU UTILIZATION metrics path end to end: the exporter DaemonSet on every `ecc/gpu` node, each node's own `nvidia-smi` query (`gpu_exporter_up`), the Prometheus scrape, and the Grafana dashboard's registration. Read-only. Asserts the Thor reports NO GPU memory and the discrete cards DO — Tegra has no NVML memory query, so demanding memory everywhere would turn a healthy cluster red. |

What goes where:

- **tests/** — runnable on demand against a healthy cluster, repeatable, and it asserts
  rather than just printing. Prefer a script over a markdown checklist: prose that says
  "expect 0 failing" gets skimmed, `bad "..."` does not.
- **plans/** — work with an end state, including a check that cannot be run on demand
  (one that must ride along a real build, say). See plans/old/gitlab-build-scratch-reclaim.md.
- **doc/** — how something works, not whether it currently does.

⚠ When mechanising a check, assert STRUCTURE, never values that legitimately move between
recreates. `uid >= 5000` ("it came from the directory"), not `uid == 5008`; NICs must DIFFER
across nodes, not match a name. Both change on every recreate and a literal turns a passing
cluster red. See the header of tests/adChecks.sh.

# Documentation

under doc/

Never document things that have been in previous/old versions and are not relevant anymore (documentation AND code comments). Only document the current state of the project.

When you encounter any of these, act on it — do not just note it:

- **Old or stale code** — remove it.
- **Wrong comments** (they contradict what the code does) — adapt them to the current state.
- **Stale comments** (they describe something that no longer exists, or narrate how the code got here) — remove them.

If you are not sure, ask.

# Workflow

This project is shared among others, Windows dev platform, VSCode devcontainer.

Use open source software only

Pulumi TypeScript project deploying a Kubernetes cluster on Hetzner Cloud with ArgoCD, cert-manager Hetzner Storage.

Read README.md for project overview, bootstrapping process, and app details.

Currently this git repository is shared by pulumi code and ArgoCD deployment code

There is no need to keep backwards compatibility. If you see comments like "this was done previously like this...", remove those comments. We are just forward-looking. If you see code that is not used anymore, remove it. If you are not sure, ask.

Don't append Co-Authored-By: lines to commit messages.

Commit directly to `main` — do NOT create feature branches for changes. Push when asked.

If you change anything in the cluster via kubectl be aware that ArgoCD might override these changes.
Keep in mind that between a git push and ArgoCD reconcile it can take 5-10 minutes.

# Application structure

Applications / deplyoments should always be self contained. E.g. if we disable an app in deployment/argocd-apps/app-of-apps (suffix .disabled) no stale / unrelated code should exist in other apps (no cross dependencies)

# Debug

## After devcontainer restart

`source ./scripts/init.sh` — one sourced command: sets the Pulumi passphrase/stack env in your shell, then reconnects the admin WireGuard tunnel if the stack is initialized. MUST be sourced (make can't set env in your shell). Individual steps below if you need them separately.

## Pulumi stack

If you need access to the Pulumi stack, run `source ./scripts/pulumi/initPulumiStack.sh` in an interactive terminal. The user will insert the credentials and store them in the env

Passphrase is stored at `/tmp/passphrase` (saved there by initPulumiStack.sh). To load non-interactively:

```bash
export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
pulumi login "file://$(pwd)/.pulumi-state" >/dev/null 2>&1
pulumi stack select mystack >/dev/null 2>&1
```

Pulumi entrypoint: main.ts

## `pulumi up` — always via `make up`

⚠ NEVER run a bare `pulumi up`. `make up` calls `scripts/pulumi/up.sh`, which re-probes the
mesh boxes and refreshes `meshNodeProvisionSkip` (`meshSkipUnreachable.sh`) first — the guard
that stops a transiently-NotReady node being sent down the destructive re-provision path
that wipes `/var/lib/longhorn`. A bare apply skips that guard and is also unlogged.

## make invocation

Every `make` invocation is logged automatically to `logs/<timestamp>-make-<goals>.log`
(start/end timestamps, the exact command incl. ARGS, exit code, duration). The path is
printed to stderr when the run ends. Do NOT pipe make output to a file yourself — that
suppresses the terminal output you need to read, and the log already exists.

`make -n` writes no log and executes nothing.

### Long-running make targets MUST be started detached

The agent's Bash tool has a **hard 10-minute ceiling** (600000 ms max timeout). When that
fires, the tool does not just stop watching — **it KILLS the process group**. A long target
run in the foreground is therefore truncated mid-flight.

A killed `make destroy` leaves the cluster half torn down — ArgoCD controllers scaled to
zero, every `syncPolicy.automated` stripped, Applications part-deleted — with no teardown
running. The log's last line looks like normal progress, so it reads as "still working"
rather than "dead", and a broad `pgrep` appears to confirm that while actually matching the
polling pipeline itself.

So for anything that can exceed ~8 minutes — `make destroy`, `bootstrap`, `production`,
`restore`, big `pulumi` runs:

```bash
nohup make destroy ARGS="--force" > "$SCRATCH/destroy.out" 2>&1 & disown
# then poll in SEPARATE short tool calls:
tail -3 "$SCRATCH/destroy.out"; pgrep -f "make destroy" >/dev/null && echo alive || echo done
```

Checking liveness properly:

- Grep for the **exact** target (`pgrep -f "make destroy"`), never a broad pattern like
  `pulumi|kubectl` — that matches your own polling pipeline and always reports "alive".
- A **stale log mtime** is the reliable signal. Compare `stat -c %y <log>` against `date`:
  minutes of silence plus no matching process means the run died, not that it is slow.
- Resuming after a killed teardown is safe here (each phase is idempotent and re-running
  re-does the quiesce), but VERIFY the phase you were in rather than assuming.

### Detecting completion: never `pgrep` your own polling loop

A background wait-loop (Monitor tool, or a `while pgrep ...; do sleep; done` you spawn
yourself) is ALSO a process whose command line gets passed through a shell (`bash -c
"... pgrep -f 'make bootstrap' ..."`). `pgrep -f` matches full command lines, so the loop's
OWN text containing the string `"make bootstrap"` satisfies its own `pgrep` — it reports
"alive" forever, even seconds after the real `make` process exited. This is silent: no
error, no timeout, just a monitor that never fires and a job you believe is still running
long after it finished (confirmed: two separate monitors on 2026-09-01 sat "watching" a
destroy and a bootstrap that had already completed and pushed their own commits).

### ⚠ `tail -f … | grep -m1 <marker>` NEVER FIRES on a finished run

This is the same silent failure one layer down, and it cost two waits on 2026-09-04 (a
destroy and a bootstrap, both already complete and pushed). `grep -m1` does exit on the
match — but `tail -f` only learns its stdout is gone when it NEXT WRITES, and the completion
marker is by definition the last line the run ever writes. So `tail` blocks in its read loop
forever, the pipeline never exits, and a background wait on it never notifies. Silence from
such a waiter carries no information at all.

**Wait with a loop that exits by itself**, started as its own background call:

```bash
# capture the run's log the moment it starts (the START banner is written at launch)
nohup make bootstrap ARGS="--complete" > "$SCRATCH/bootstrap.out" 2>&1 & disown
LOG=$(ls -t logs/*make-bootstrap.log | head -1)
# …then, in a SEPARATE background tool call:
until grep -q '^=== END' "$LOG"; do sleep 15; done; tail -3 "$LOG"
```

### Which marker: `=== END` in the log, not `log:` in the terminal

`runLogged.sh` writes the two banners to DIFFERENT places, and only one carries the verdict:

| marker                                 | where it lands                             | says                               |
| -------------------------------------- | ------------------------------------------ | ---------------------------------- |
| `=== END <ts> rc=<code> duration=<n>s` | appended to `logs/<...>.log` ONLY          | finished **and** whether it worked |
| `log: logs/<...>.log`                  | stderr → your `> out 2>&1` redirect target | finished, nothing more             |

So grep the LOG FILE for `^=== END` and read `rc=` — `rc=0` is the only success. Grepping the
redirect target for `^log: logs/` tells you a run ended but not that it succeeded, which is
how a failed `make destroy` once read as a normal finish.

Correct completion checks, in order of preference:

- **Best: `until grep -q '^=== END' "$LOG"; do sleep 15; done`**, then read the `rc=`.
  Never poll a PID.
- If you must check liveness, exclude your own shell: `pgrep -f "make bootstrap"
| xargs -r ps -o pid=,cmd= -p | grep -v 'pgrep\|eval\|claude-'`, or simpler — match the
  make LOGFILE path (unique per run) instead of the goal name, since your polling command
  never contains that path.
- Corroborate with the **log mtime** either way (already documented above): a log untouched
  for minutes with no `=== END` means dead, not slow.

## Command logging (agents too)

`scripts/environment/runLogged.sh <slug> <command...>` is the ONE logging mechanism.
The Makefile trap uses it, and agents should use the same mechanism for any
long-running or state-changing command run outside make — pulumi, kubectl waits,
provisioning, build/push loops:

```bash
bash scripts/environment/runLogged.sh pulumi-preview pulumi preview
bash scripts/environment/runLogged.sh argocd-sync argocd app sync samba-ad
```

Do NOT hand-roll `> tmp/foo.log`, `tee`, or start/end banner wrappers — a hand-rolled
`rc=$?` banner after a pipe reports the wrong exit code. Writes
`logs/<timestamp>-<slug>.log`; make runs get a `make-` prefix so they
sort apart. Slug is for the filename only — keep it short and kebab-case.

Properties that matter: the real exit code is preserved (`PIPESTATUS`, not tee's);
stdin is untouched so interactive prompts and passphrase entry still work; stdout is a
pipe, so colors self-disable and pulumi streams plainly instead of rendering progress.
Same-second runs get a `~2` suffix rather than sharing a file. `logs/` is gitignored and
never pruned.

## Cluster logs (Loki) — how to gather them

`logs/` above is LOCAL command output. Logs from inside the cluster come from Loki.

⚠ **Use the `loki-query` skill** before querying — the label schema is a trap (no `pod`
and no `node` label, so `{namespace="x",pod="y"}` returns 0 rows with no error), timestamps
are nanoseconds, and `HTTP:000` means a dead port-forward, not an empty Loki.

Because Alloy tails **files**, not the kubelet API, `kubectl logs` failing is NOT a reason
logs are missing: a deleted pod, a completed Job, and anything that ran before the logging
stack came up are all still in Loki. That is the main reason to reach for Loki.

## Cluster lifecycle + firewall posture (make bootstrap / production / breakglass)

`make bootstrap` is the bring-up command: no cluster in the stack ⇒ fresh create (with
public SSH 22 + k3s API 6443 open — provisioning needs them); cluster exists ⇒ just
re-opens that posture (`pulumi up`). There is no separate create target. `ARGS=--complete`
makes a fresh create unattended: the three post-create offers (hardening, mesh provisioning,
commit & push) each auto-SKIP on timeout, and `--complete` answers them yes instead. `make restore`
= create from S3 backup. `make production` hardens (closes 22/6443; admin WireGuard is
the only way in) and refuses unless the WG tunnel actually works (`ARGS=--force`
overrides — Production-only; to force a recreate use `make destroy` first or
FORCE_CREATE=1). `general.targetState` in project_settings.ts records what the current
apply is driving toward — `bootstrap` | `restore` | `production` | `shutdown` | `destroy` —
and is set by the make targets, not by hand (`ps_set_target_state` in scripts/pulumi/_common.sh).
It carries BOTH the firewall posture and the data disposition: `production` is the only closed
posture, and only `destroy` deletes the S3 buckets and clears the saved TLS certs, which is
what separates it from `shutdown`. Lockout recovery:
`make breakglass` (plain Robot API + SSH; deliberately no pulumi/kubernetes — note a
Robot-API source-IP rule can NOT unlock: the lock is host nftables, not the Robot FW).
Enforcement is the host nftables table `inet public_guard` on robot/hcloud nodes
(persisted in /etc/nftables.conf) — mesh nodes must NEVER get it. Details:
doc/network-firewall.md.

The TLD shape is derived from `general.subdomain`: non-empty ⇒ `<subdomain>.<domain>`
(ecc148.example-domain.tld), EMPTY ⇒ bare apex (`mydomain.tld`). It is NOT tied to
targetState — a lifecycle transition never rewrites deployment manifests. The switch works in
BOTH directions because the rewrite is driven by the `{general.subdomain,general.domain}` anchor
— from the apex no regex can tell a cluster hostname from a foreign one, so
`scripts/environment/checkDomainAnchors.py` (pre-commit, `make check`) fails on any unanchored
cluster hostname. Bare apex trades away the per-recreate certificate SAN set (Let's Encrypt's
5-duplicates-per-week limit becomes binding) — see doc/setup-instructions.md.

## make shutdown

One interactive `yes` confirmation. Skip it with `--force`, exactly like `make destroy`:

```bash
make shutdown ARGS="--force"
```

⚠ Without `--force` a DETACHED run dies instantly (`rc=2`, `duration=0s`) — the prompt hits
a closed stdin. That is the only prompt in the script; every `pulumi up`/`pulumi dn` inside
it already passes `-y`. Long target ⇒ run it detached, so in practice always pass `--force`.

## Kubernetes

Kubeconfig is stored at `~/.kube/config` (default path). If this does not work, run `./scripts/runtime/getKubeConfig.sh` to fetch it.

## Secrets

⚠ **Use the `sealed-secrets` skill** for any work touching a `sealSecrets.sh`,
`manageSealedSecrets.sh`, `kubeseal`, a `*-sealed.yaml`, or a pod failing with
`secret not found` / `Init:CreateContainerConfigError`. Every failure mode there is
silent — the headline rule is that `kubeseal` MUST seal against the Pulumi stack cert
(`--cert <(pulumi config get sealedSecretsTlsCrt)`), never the live controller's, and
editing a seal script does not produce a sealed file: you have to run it.

## Hetzner HCLOUD API / CLI

With Pulumi stack loaded, use:

```bash
export HCLOUD_TOKEN=$(pulumi config get hcloudToken)
hcloud server list
hcloud dns rrset list mydomain.tld
```

## ArgoCD CLI

Two ArgoCD instances: **infra** (ns `argocd-infra`, host `argocd-infra.<tld>`, waves 0–19)
and **apps** (ns `argocd-apps`, host `argocd-apps.<tld>`, manages
`deployment/argocd-apps/app-of-apps/`). Both share the same admin password hash.

If the CLI is not logged in, run `./scripts/runtime/argocdLoginCLI.sh [infra|apps]`
(default `infra`). Run twice to get both contexts; `argocd context <host>` switches.

⚠ **Use the `argocd-debug` skill** whenever a change does not land — a sync reporting
Synced/Healthy or Succeeded while the cluster keeps the old state, a wedged or endlessly
retrying operation, a hook Job that never fires, a PreSync namespace deadlock, or before
patching any Application's `operation`/`operationState`. Green status is not evidence, and
the wrong patch re-wedges the app.

# external repositories

in `external/` (repo-relative, i.e. /workspaces/git_infra/external) there are sources for external projects (Ryax, the upstream Helm charts for xwiki/zulip/authentik/jitsi/rocketchat, etc. — see scripts/environment/cloneExternalGits.sh for the full list). You can use them to search for documentations. NEVER edit them, or refer to them in your code.

if the repositories in `external/` do not exist, ask the user to run scripts/environment/cloneExternalGits.sh

## ⚠ UPDATE the checkout before trusting it — on every bug hunt and every version bump

These checkouts are pinned at whatever commit they were last cloned/fetched at, and they do
NOT track the version we actually deploy. Before reading one to answer "how does upstream
behave" or "is this fixed upstream", `git -C external/<repo> fetch --all --tags` and check
out the version in question. Do the same whenever bumping a pinned version, so the source
you reason about is the source you are moving to.

A stale checkout does not fail loudly — it answers confidently and wrongly. Measured
2026-09-19: `external/git_vllm-project_vllm` sat at a 2026-08-24 commit with no tags, and
its `CMakeLists.txt` showed Thor's `11.0` missing from `FUSED_GDN_DECODE_ARCHS`. That led to
the conclusion "upstream does not support sm_110, a version bump cannot help" — when the
one-line fix had ALREADY merged upstream on 2026-09-05. It had merely missed the 0.29.0
release cut.

So for any "is it fixed upstream" question, the authoritative sources are the released
artifact (download the sdist/wheel for the EXACT version from PyPI and read it) and the
project's own issue/PR state — never the local checkout alone.

# Cluster Recreation (ecc84, ecc85, …)

⚠ **Use the `cluster-recreate` skill** — the full procedure, measured timings, what
converges on its own and what does not, the IMAGE_TAG prohibition, EDA module image
survival, and the AD-DC add/remove caveats.

Shape only: destroy → commit stack state → bump `subdomain` in `project_settings.ts` →
`updateConfigFromProjectSettings.sh` → commit → `make bootstrap ARGS=--complete`. Both long
targets MUST run detached. "Cluster is up" ≈ 1h15m; a green apps instance is gated on
GitLab CI, not on bootstrap.

# Switching from Staging to Production TLS Certificates

TLS architecture (wildcard-by-default, per-host certs as the exception, backup/recovery, CA consumers): see `doc/tls-certificates.md`. Per-host certs exist ONLY for gitlab (multi-level hosts); everything else, ryax included, uses the shared Gateway's wildcard listener (`argocd-infra/wildcard-tls`).

Change `certIssuerType` in `project_settings.ts` from `"letsencrypt-staging"` to `"letsencrypt-prod"`, then run the update script:

```
bash scripts/environment/updateConfigFromProjectSettings.sh
```

The script updates ALL manifests automatically:

- All `cert-manager.io/cluster-issuer:` annotations in deployment manifests
- ArgoCD OIDC TLS verify (`oidc.tls.insecure.skip.verify`)
- Headplane Node TLS (`NODE_TLS_REJECT_UNAUTHORIZED`)
- GitLab/GitLab-runner presync curl insecure flag

Nextcloud `oidc_login_tls_verify` is set automatically by the postsync job based on the ingress cert-issuer annotation — no manual step needed.

Note: letsencrypt-prod rate limits — **50 new certs / 7 days per registered domain** (`mydomain.tld` via the Public Suffix List, so ALL `eccN` subdomains share one bucket), and separately **5 / 7 days per exact SAN set** (the "duplicate certificate" limit — this is what re-issuing the _same_ subdomain's cert hits; it is NOT a wildcard-specific limit). Incrementing the subdomain changes the SAN set → dodges the 5-duplicate limit but still counts toward the 50. Use staging for testing.

# Cloud↔Edge placement tiers

See `doc/cloud-mesh-architecture.md` (+ `doc/redundancy-ha.md`).

- Apps carry `placement.ecc/tier: cloud|flex|mesh` on their ArgoCD Application; default `cloud` (`project_settings.ts` `placement.defaultTier`). (windows is `flex` / KVM-anywhere.)
- Mesh nodes are tainted `ecc/mesh=true:NoSchedule` (in the k3s join); only workloads with a matching toleration run there — keeps cloud/system pods off mesh nodes. ROLE shows `mesh` via `node-role.kubernetes.io/mesh`.
- Each node has `site` (one LAN = one failure/latency domain → `ecc/site` label) and mesh nodes also have `storageScope: string[]` (≥1, first=primary) → overlapping Longhorn disk tags.
- StorageClasses: `longhorn-cloud` (default, cloud disks), `longhorn-cloud-db` (cloud disks for CNPG data volumes — same placement as `longhorn-cloud` but in the `cnpg` RecurringJob group: daily S3 backup, NO hourly snapshot, since barman already gives PITR), one `longhorn-<scope>` per distinct mesh `storageScope` (only when `nodes.mesh` non-empty), `seaweedfs` (S3-backed file PVCs, CSI at wave 2; cluster at wave 0). A scope spanning LANs = cross-LAN redundancy (over WireGuard); single-node scope = replica 1.
- Pod placement ≠ volume placement: moving an app to a mesh site means moving its state backends (file→SeaweedFS, DB→CNPG), not just rescheduling. Raw block (windows) stays on `longhorn-cloud`/`longhorn-<scope>` and the pod follows the volume.
- PriorityClasses (`deployment/argocd-infra/priorityclasses/`): platform>essential>high>standard>low for graceful degradation under resource pressure.
- Deferred until mesh nodes exist: SeaweedFS mesh filer + active-active, CNPG mobility conversions + replica clusters, CNPG recovery-on-restore + mesh auto-reconnect.
- "mesh" = externally-hosted machine adopted over SSH, joins over the headscale/tailscale VPN (`clusterLink: "vpn"`); NOT physically at the network edge. Init CP may be cloud/robot OR a mesh site; exactly one "init site" holds the `direct` CP+followers.

# Token opt

- Use short 3-6 word sentences
- no filler, preamble or pleasantries
- run tools first, show results then stop, don't narrate
- drop articles ("Me fix code" not "I will fix the code")
- don't use pleasantries ("Good idea"...)

# External git repositories

script/environment/cloneExternalGits.sh checks out external git repositories for used software. Use them to search for documentations and check if arguments exist there before guessing. NEVER edit them, or refer to them in your code.
If a repo does not exist, add it.

# Renovate update management

Although renovate automatically finds version numbers, ALL version defines in source code shall be annotated that the user knows that renovate is managing them. See renovate.json for the regexes used to find version numbers.

# Agent execution with wait times

If an agent issues a command that takes a long time to complete, it should print the current time and the expected wait time, then print the current time again when the command completes. This allows the user to see how long the command took to complete.

Print a timestamp at least every 5 minutes when you are active.
