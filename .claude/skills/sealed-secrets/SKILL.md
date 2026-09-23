---
name: sealed-secrets
description: Create, edit, re-seal or audit SealedSecrets in this cluster — any work touching a sealSecrets.sh, manageSealedSecrets.sh, kubeseal, a *-sealed.yaml file, or a pod failing with "secret not found" / Init:CreateContainerConfigError. Use before adding a secret to an app, editing a seal script, rotating a credential, or concluding that a Secret reference is wired correctly.
---

# Sealed secrets

Every failure mode here is silent. A wrong seal applies cleanly, produces no Secret, and
surfaces as a credential-less pod — usually on the NEXT RECREATE, far from the cause.

## The one non-negotiable rule

**Always seal against the Pulumi stack cert. Never let `kubeseal` default to fetching the
cert from the live controller.**

```bash
kubeseal --cert <(pulumi config get sealedSecretsTlsCrt) ...
```

`src/sealedsecrets.ts` seeds each new cluster's controller from the Pulumi
`sealedSecretsTlsCrt`/`Key`. A file sealed against a LIVE controller is openable only by
the cluster that happened to be up when the script ran. On the next cluster it applies
cleanly, produces NO Secret, and the app comes up credential-less. This bug shipped once in
`ryax/generateSecrets.sh` (fixed in `f594bc8b`) and was caught only by `make destroy`'s
sealed-key preflight refusing the teardown because the two certs had diverged.

Copy the `--cert` invocation from `deployment/manageSealedSecrets.sh`. Pass **no**
`--controller-namespace` / `--controller-name` — with `--cert` they are inert, but they
imply a live controller is consulted, which is the misconception behind the bug. Fetch the
cert once up front and die if unreadable, rather than part-writing the output file.

A correct seal script needs a loaded Pulumi stack and **no cluster at all**. If your script
requires a running cluster, it is wrong.

## Editing a seal script does not seal anything

The `*-sealed.yaml` artifact appears only when the script is RUN. Adding a namespace to a
`sealSecrets.sh` loop produces nothing on its own.

Measured 2026-09-14: six sealed secrets were wired for `remote-desktop-bender` and
`hermes`, three seal scripts edited, none run. Every guard passed —
`check-seal-coverage.sh` only checks that a script is *invoked by* `sealAllSecrets.sh`, not
that its output exists. `remote-desktop-bender` then failed with `MountVolume.SetUp failed
... secret "image-registry-cred" not found`, and the manifest looked wrong when it was
correct.

**After editing any `sealSecrets.sh`:** run it with `--skip-git-commit` and confirm the
expected `*-sealed.yaml` files exist before committing.

Re-running is safe — values are recovered from existing files and live passwords are not
rotated. But re-sealing rewrites ciphertext even when the plaintext is unchanged
(randomised encryption), so `git checkout` the no-op files to keep the diff honest.

## Verify before committing

Split the sealed file and check every doc opens:

```bash
kubeseal --recovery-unseal --recovery-private-key <(pulumi config get sealedSecretsTlsKey)
```

## Auditing a Secret reference

A pod-wiring audit that asks "does this Secret name exist somewhere in the repo?" misses
the real failure. Ask both:

1. Does it exist **in that namespace**?
2. Is the `*-sealed.yaml` file backing it actually **on disk**?

## Seal order is load-bearing

`sealAllSecrets.sh` drives the order with an explicit `run <app>` list, and the order
matters: **authentik first** (it generates the OIDC bundle the others recover from), then
`vllm` → `litellm` → `open-webui`/`hermes`, each recovering the previous one's key. A
`find`-driven loop would run them in directory order and silently break the chain — which
is why the explicit list stays and `deployment/check-seal-coverage.sh` guards it.

Two failure directions, both silent or destructive:

- An app **missing from the list** is not visibly skipped: `sealAllSecrets.sh` prints "All
  secrets sealed" and exits 0, the running cluster keeps working from sealed values already
  in git, and the gap surfaces on the next recreate as
  `Init:CreateContainerConfigError`. That is how `hermes-secrets` went missing for two days.
- A `run <app>` naming a directory with **no** `sealSecrets.sh` aborts the whole area run
  with "No such file or directory", so every app AFTER it never seals at all.

So when adding an app: add its `sealSecrets.sh`, add it to the right area's
`sealAllSecrets.sh` in a position consistent with the recovery chain, run it, and run
`check-seal-coverage.sh`.

## KEG vs. auto — which helper to use

Two management styles in `deployment/manageSealedSecrets.sh`, deliberately split:

| kind | helper | behaviour |
|---|---|---|
| Human-login passwords (admin / superadmin / bootstrap / gitlab-root) | `recover_keg_or_enter` | **KEG** — fresh run: enter or generate; re-run: keep / replace / generate (`prompt_keg`) |
| Machine secrets (DB users, OIDC client secrets, API tokens, S3 keys) | `recover_or_generate` / `try_recover` | **auto** — recovered or randomly generated, never prompted |

**Do not make machine secrets KEG.** They must byte-match a consumer (a DB role, an OIDC
provider, an S3 credential); a human-entered value is a breakage vector, and rotating one
is a coordinated operation, not a re-seal. This split is policy, not an accident.

⚠ `prompt_keg` is `read -rp` inside `while true` with no timeout, default or tty check —
under non-interactive stdin it **loops forever** rather than failing. So
`authentik/sealSecrets.sh --regenerate` cannot run unattended (it reaches the
CLUSTER_ADMIN/TEST_USER prompts). `samba-ad/sealSecrets.sh` can, via
`SAMBA_ADMIN_PASSWORD`.

## A SealedSecret can be a PreSync hook

Some apps (eda-pcb-agent) ship their SealedSecret as a **PreSync hook with no delete
policy**. Consequence: a hook-only sync (`syncStrategy.hook`) replaces the SealedSecret
without applying the Sync phase around it, leaving the pod in
`Init:CreateContainerConfigError`. See the `argocd-debug` skill.

## Recreates and rotation

**A subdomain change needs NO re-sealing.** Sealed secrets contain passwords only, no
domain refs. Re-seal only when actual secret values change.

Rotation is a coordinated operation, not a re-seal. Two traps worth knowing before touching
any credential (full detail in `doc/secrets.md`):

- **`AUTHENTIK_BOOTSTRAP_PASSWORD`: re-sealing rotates nothing.** Authentik reads it only on
  first boot to seed `akadmin`; afterwards the DB hash is authoritative. Re-sealing leaves
  the sealed value describing a password that is not in effect — worse than not rotating,
  because it looks done.
- **`SAMBA_AD_BIND_PASSWORD`: rotation opens a lockout window.** The value lives in four
  places, and the AD-side re-sync runs as a PostSync hook in a *different* Application from
  the blueprint updating Authentik's side, with no cross-app ordering. In that window every
  `authentik-sync` bind increments `badPwdCount` and can lock out the account that gates
  password changes cluster-wide — silently, at INFO. Re-seal both bundles, sync `authentik`
  and `samba-ad` close together, then confirm a real bind and `badPwdCount: 0`.

## Reference

- `deployment/manageSealedSecrets.sh` — helper reference, and the canonical `--cert` call.
- `deployment/check-seal-coverage.sh` — coverage guard; read its header.
- `doc/backup-restore.md#sealed-secrets-policy-keg-vs-auto` — the KEG/auto policy.
- `doc/secrets.md` — rotation intervals and reconciliation status per credential.
