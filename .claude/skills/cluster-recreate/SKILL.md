---
name: cluster-recreate
description: Recreate the cluster under a new subdomain (ecc84 → ecc85 …) — the destroy/bump/bootstrap procedure, expected timings, what converges on its own and what does not, and the traps that cost hours (IMAGE_TAG bumps, AD DC removal, EDA module image survival). Use when running or planning a recreate, when judging whether a post-bootstrap cluster is healthy, or before bumping any image tag.
---

# Cluster recreation (ecc84, ecc85, …)

## Procedure

**0. Prepare the Pulumi stack**

```bash
export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
pulumi login "file://$(pwd)/.pulumi-state" >/dev/null 2>&1
pulumi stack select mystack >/dev/null 2>&1
echo "stack: $(pulumi stack --show-name 2>/dev/null)"
```

**1.** Destroy the old cluster: `make destroy ARGS="--force"`
**2.** Commit the destroyed Pulumi stack state (`.pulumi-state/` is tracked in git)
**3.** Increment `subdomain` in `project_settings.ts` (ecc83 → ecc84)
**4.** `bash scripts/environment/updateConfigFromProjectSettings.sh` — updates all domain
refs, cert issuer and GitHub URL across every deployment manifest
**5.** Commit: `git add deployment/ project_settings.ts && git commit`
**6.** Create: `make bootstrap`. Add `ARGS=--complete` to auto-answer the three post-create
offers (hardening, mesh provisioning, commit & push) with yes — otherwise each auto-SKIPs
on its timeout and the recreate needs a human.

⚠ Both long targets MUST be started detached — the Bash tool's 10-minute ceiling KILLS the
process group, and a killed `make destroy` leaves the cluster half torn down with no
teardown running. Wait with an until-loop on `^=== END` in the make log and read `rc=`;
never `pgrep` your own poller. (See CLAUDE.md, "Long-running make targets".)

## Timings

Measured 2026-08-29/30 (ecc186 → ecc187), re-measured 2026-08-31 (ecc188 → ecc189).
Hetzner provisioning and image-pull speed vary — order of magnitude, not a budget.

| phase | ecc187 | ecc189 |
|---|---|---|
| `make destroy ARGS=--force` | **31m45s** | 19m34s |
| `make bootstrap ARGS=--complete` | **40m58s** | 35m39s |

Inside `make bootstrap`:

| step | duration |
|---|---|
| start → first `pulumi up` | 2m23s |
| `pulumi up` → robot install begins | 7m31s |
| robot install → k3s init | 6m31s |
| k3s init → argocd-infra deployed | 1m00s |
| argocd-infra deployed → pulumi pass 1 done | 4m11s |
| pulumi pass 1 done → mesh provisioning | 16m21s |
| mesh provisioning → bootstrap returns | 3m01s |

The three `pulumi` passes reported 14m56s / 4m32s / 2m27s.

**"Cluster is up" ≈ 1h15m from starting the destroy.** A fully green apps instance is
gated on CI, not on bootstrap.

## What converges, and what does not

- **argocd-infra: all 42 Synced/Healthy 3m56s after bootstrap returns.** This is the real
  health signal.
- **argocd-apps reaches ~24/28 about 10 min later and then STALLS.** It does not converge
  on its own timescale. The remaining apps wait on GitLab CI rebuilding the self-built
  images (`ollama`, `vllm`, `remote-desktop`, `gitlab-runner-eda`) — hours, not minutes,
  because those images live in the IN-CLUSTER GitLab registry and die with the cluster.
  **Do not read `ErrImagePull` on them as a fault** — the build-trigger Jobs have already
  fired the pipelines.
- **remote-desktop has no `automated` syncPolicy** (a sync kills every logged-in session),
  but you do not have to babysit it: the `desktop-rollout` CronJob (argocd-apps, every
  5 min) syncs it whenever it is OutOfSync AND has ZERO ready replicas — first boot and
  crash-loops included. A desktop that is UP keeps its pending change until a human
  applies it.
- **Lab images come from the LAN registry and it activates itself — no manual step.**
  remote-desktop and ollama pull from `127.0.0.1:30500` (~126 MB/s vs GitLab S3's ~5 MB/s).
  Both halves are dynamic: `image-registry/node-registries-config.yaml` writes containerd's
  own `certs.d/127.0.0.1:30500/hosts.toml`, re-read on EVERY pull; the credential is an
  ordinary `imagePullSecret` (`image-registry-cred-node`). Neither needs a k3s restart.
  `scripts/runtime/activateNodeRegistry.sh` is only the hammer for a node carrying stale
  k3s-generated registry state; it is not part of bootstrap.

  ⚠ Do NOT reintroduce `/etc/rancher/k3s/registries.yaml` for this host. k3s reads it only
  at agent start, and `cleanContainerdHosts()` `RemoveAll()`s the `certs.d` directory of
  every host it names before regenerating — deleting the config above on the next restart.
  The two mechanisms must stay apart.

  ⚠ A pull secret is matched by REGISTRY HOST STRING. The FQDN-keyed `image-registry-cred`
  does NOT apply to a `127.0.0.1:30500/...` image; that pull fails with `no basic auth
  credentials`. Both secrets are listed on those pods on purpose.

## ⚠ Do NOT bump any IMAGE_TAG during a recreate

A recreate is precisely when the archived image must still match: **the tag is the SOLE
cache key** for the recover-or-rebuild gates, so bumping it invalidates the archive and
forces a full rebuild of exactly the thing the archive existed to preserve.

`updateConfigFromProjectSettings.sh` has no `IMAGE_TAG` handling, so any bump in a recreate
commit was bundled in by hand (`5485150c` did this: `base-r35` → `base-r36` with no
`Dockerfile.base` change at all). Beyond the wall-clock, `image-registry` has **no GC** by
design and is at ~135 GB, so every needless bump orphans a few GB permanently.

Bump a tag when the image CONTENT changes — never on a subdomain change.
`deployment/argocd-apps/remote-desktop/check-image-invariants.sh` (precommit) enforces the
converse: a build-input change without a bump fails.

## Sealed secrets

**No re-sealing needed on a subdomain change** — they contain passwords only, no domain
refs. Re-seal only when actual secret values change. See the `sealed-secrets` skill.

## EDA module images survive a recreate

The lab-local registry's blob store is its own TrueNAS dataset (`datapool/images`),
OUTSIDE the cluster. Every module is `runtime: container` (`xilinx/2024.1`,
`xilinx/2026.1`, `petalinux/2024.1`, `hyperlynx/2604`) and is restored from it.

There are deliberately **NO `image.tar` archives** — a docker-archive tar per module would
be a second copy of the same layers (~190 GB) with no survival benefit, and the broker
sidecar holds a PULL-ONLY deploy token so it could never push one back. `broker archive`,
`archive-async` and `restore` are RETIRED (they exit 2).

**Before destroying**, verify the images are in the blob store — this is what survives:

```bash
kubectl exec -n image-registry deploy/image-registry -- sh -c \
  'ls /var/lib/registry/docker/registry/v2/repositories/deployments/infrastructure/eda/modules'
```

**After the recreate**, confirm the registry PVC rebound to `datapool/images`. A fresh PVC
pointing elsewhere presents an EMPTY registry, and the CI gate then rebuilds all three
modules from installer media (hours) with no error — it fails open by design.

Each app's `.gitlab-ci.yml` gates its build on the REGISTRY: a v2 `GET
/v2/<repo>/manifests/<tag>` returning 200 means "already built, skip". Expected output:

```
xilinx-2024-1:2024.1 already exists — skipping build.
```

⚠ The gate is **FAIL-OPEN**, so when it breaks it does not error — it silently rebuilds all
three from installer media with the images present the whole time. If you ever see a module
rebuild, read the `registry gate: HTTP <code>` line: that number is the diagnosis (401
credential, 404 absent, 000 TLS/DNS). A past regression was `${IMAGE#*/}` leaving the
`:TAG` inside the repository name, giving a permanent 404. `FORCE_REBUILD=1` overrides the
gate for a one-shot rebuild.

Module **registration** is automatic and survives: each EDA app carries a PostSync Job
(`postsync-register-module.yaml`) that re-registers its module from its build-files
ConfigMap. A recreate starts the `datapool/eda/modulefiles` dataset empty and the apps
refill it — no manual step, no central list to drift.

## On-prem AD DCs — automatic, with caveats

Everything re-derives from `project_settings.ts`, so a recreate needs **no manual AD step**:
the `ecc/ad-dc` / `ecc/lan-ip` node labels, the StatefulSet's `replicas` (anchored to the
COUNT of `adDc: true` nodes), the `__POD_NAME__` / `__LAB_NIC__` tokens in the sealed
config, `AD_DC_IPS` for each node's dnsmasq, and the `ecc-lan-local-rule.service` unit that
`30-connect-vpn.sh` installs on every mesh provision. No consumer carries a DC address
literal.

⚠ **Two different discovery sources, deliberately.** `configure-job.yaml`'s
`read-onprem-dcs` initContainer reads the live `dc=onprem` PODS (it needs DCs actually
serving, and gates on Ready). `dc-set-watch` reads the `ecc/ad-dc` NODE LABELS instead,
because it must not mistake a DC that is merely down for one that was removed. Do not
"unify" these — the difference is the fix for a measured outage. Any new consumer should
use the labels unless it specifically needs "serving right now".

⚠ **A lab box unreachable at bootstrap leaves one DC Pending.** It lands in
`meshNodeProvisioning.skip`, never joins, so never gets labelled — while `replicas` still
counts it from settings. It does NOT stall bootstrap (the wave-18 barrier awaits only
`sync-wave=10` apps; samba-ad is 13). Fix by setting that node `enabled: false` and
re-running `updateConfigFromProjectSettings.sh`, which drops the label and the replica
count together.

⚠ **A drifted DHCP lease is a WARNING, not a failure.** `ecc/lan-ip` is a declaration; a DC
binds whatever its NIC actually has. Surfaces as `⚠ WARNING: nothing answers tcp/389 at
<ip>` from the TrueNAS configure job.

⚠ **`truenas-configure` waits for DCs to be READY, not merely scheduled.** A tcp/389
connect is NOT proof a DC can service a join — these DCs are hostNetwork, so samba binds
the LAN listener long before the directory is up. Measured 2026-09-04: the job started 31s
before the second DC was Ready, reported `2/2 DC(s) answering tcp/389`, and the join died
with `[EFAULT] Failed to properly join domain and start up services`. The gate lives in the
initContainer ON PURPOSE: `backoffLimit` MUST stay 1 (the appliance locks out for ten
minutes after 20 auth attempts per 60s), so waiting BEFORE the websocket is opened costs no
auth attempt. **Never "fix" a startup race by raising `backoffLimit`.**

### ⚠ REMOVING a DC is a PROCEDURE, not a settings edit

Adding one is self-healing; removing one is not. Measured 2026-09-02 scaling 3 DCs to 1 —
each of these bit, and none is caught by any check.

1. **Demote FIRST, while the pod still runs:** `samba-tool domain demote -U
   "Administrator%<pw>"` inside the pod. It also removes that DC's SRV/`_msdcs` records.
   Deleting the pod first leaves an orphaned DC object needing `--remove-other-dead-server`.
2. **Then edit `project_settings.ts`** (drop `adDc`) and re-run
   `updateConfigFromProjectSettings.sh`.
3. **Remove the node label BY HAND:** `kubectl label node <n> ecc/ad-dc-`. `pulumi up` will
   NOT do it — `kubectl label --overwrite` only adds, so an un-set flag leaves the label
   and the DC keeps scheduling there. (Same gap for `gpu`/`edaBuilder`/`kvm`/
   `nestedRuntime`.)
4. **Move the survivor if needed.** The StatefulSet keeps the LOWEST ordinals, which may
   sit on a node you just unlabelled. A running pod is not evicted by a label change —
   delete it so it reschedules.
5. **Re-run the TrueNAS configure job — not optional.** Nothing in the `truenas` app
   changed, so ArgoCD never re-syncs it and the appliance keeps resolvers pointing at nodes
   that no longer run a DC. TrueNAS fails hard on the first resolver that cannot answer for
   the realm, so the appliance goes FAULTED and stops authenticating:

   ```bash
   kubectl delete job -n samba-ad truenas-configure --ignore-not-found
   kubectl apply -f deployment/argocd-infra/truenas/configure-job.yaml
   ```

⚠ Left FAULTED long enough, winbind wedges into a state where `AD\Domain Users` still
resolves but EVERY user returns "does not exist". That survives `cache_refresh`, a cifs
restart and a reboot; the only recovery is leave+rejoin. Doing step 5 promptly avoids it.

⚠ **That recovery is AUTOMATED — do not reach for it by hand first.**
`configure-job.yaml`'s repair path detects the wedge (`_identity_works()` must fail
`REPAIR_PROBE_ATTEMPTS` consecutive sweeps) and does the leave+rejoin unattended. Measured
2026-09-04: a wedged appliance recovered ~10 min later with no human action. Check that a
configure run has had its chance before doing anything destructive manually.

⚠ **`_identity_works()`'s `if not probes: return True` is DELIBERATE.** It looks like a bug
that would skip the repair on a fresh cluster, but the probe list is populated in practice
(configmap `truenas-home-users` is published at wave 13, before truenas at wave 16).
Returning `True` on a genuinely empty list is what stops a first bring-up firing a
DESTRUCTIVE repair on a healthy join. Read the docstring before touching it.

⚠ **Losing ONE of two DCs is survivable.** What is not survivable is being RECONFIGURED
down to one DC while the other is merely down — that strips the survivor's resolver entries
and wedges winbind.

## Post-recreate checks

| script | covers |
|---|---|
| `tests/adChecks.sh` | AD DC set, placement, replication, DNS, TrueNAS appliance (read-only) |
| `tests/remoteDesktopEdaChecks.sh` | remote-desktop, the four static NFS PVs, EDA modules, lab registry |
| `tests/lokiQueryChecks.sh` | Loki's query path |
| `tests/hermesKanbanChecks.sh` | eda-pcb-agent: Kanban durability + the DNS egress its NetworkPolicy must allow |

`tests/adFailover.sh` is separate and **DESTRUCTIVE** — needs N≥2, refuses below that.
Read its header first.

**Open `recreate-check-*` plans in `plans/` are checks that can ONLY be made during a
recreate** — read them BEFORE starting one, because the evidence they need is destroyed by
carrying on. Currently:

| plan | what the recreate must show |
|---|---|
| `recreate-check-loki-read-hangs-after-recreate.md` | ⚠ CAPTURE THE GOROUTINE DUMP BEFORE RESTARTING loki-read — two occurrences were already lost to a restart |
| `recreate-check-argocd-mcp-token-regeneration.md` | `source ./scripts/init.sh` must print `minted and stored` for BOTH ArgoCD MCP tokens with no human action (a recreate invalidates them; `token OK` would mean the detection is broken) |

## Other recreate notes

- **ArgoCD OIDC:** login requires the Authentik `argocd-infra` / `argocd-apps` provider
  redirect URIs to match the new subdomain. Configured in
  `deployment/argocd-infra/authentik/blueprint-apps.yaml` and applied automatically by
  ArgoCD on first sync.
- **Barriers:** each infra barrier writes ConfigMap `waveN-barrier-done` in `argocd-infra`
  on first successful pass and exits immediately on re-syncs. Force a re-run with
  `kubectl delete configmap waveN-barrier-done -n argocd-infra`. The apps instance has none.
- **letsencrypt-prod rate limits:** 50 new certs / 7 days per registered domain (ALL
  `eccN` subdomains share one bucket via the PSL), and 5 / 7 days per exact SAN set.
  Incrementing the subdomain changes the SAN set → dodges the 5-duplicate limit but still
  counts toward the 50. Use staging for testing.
