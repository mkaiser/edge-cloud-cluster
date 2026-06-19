# Workflow

This project is shared among others, Windows dev platform, VSCode devcontainer.

Use open source software only

Pulumi TypeScript project deploying a Kubernetes cluster on Hetzner Cloud with ArgoCD, cert-manager Hetzner Storage.

Read README.md for project overview, bootstrapping process, and app details.

Currently this git repository is shared by pulumi code and ArgoCD deployment code

There is no need to keep backwards compatibily.

Don't append Co-Authored-By: lines to commit messages.

If you change anything in the cluster via kubectl be aware that ArgoCD might override these changes.
Keep in mind that between a git push and Argocd reconsile it can take5-10 minutes.

# Debug

## Pulumi stack

If you need access to the Pulumi stack, run `source ./scripts/pulumi/initPulumiStack.sh` in an interactive terminal. The user will insert the credentials and store them in the env

Passphrase is stored at `/tmp/passphrase` (saved there by initPulumiStack.sh). To load non-interactively:

```bash
export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
pulumi login "file://$(pwd)/.pulumi-state" >/dev/null 2>&1
pulumi stack select mystack >/dev/null 2>&1
```

Pulumi entrypoint: main.ts

## make shutdown

Requires two interactive `yes` confirmations (cluster shutdown + DNS record deletion). Run non-interactively with:

```bash
export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
pulumi login "file://$(pwd)/.pulumi-state" >/dev/null 2>&1
pulumi stack select mystack >/dev/null 2>&1
printf 'yes\nyes\n' | bash scripts/pulumi/shutdownCluster.sh
```

## Kubernetes

Kubeconfig is stored at `~/.kube/config` (default path). If this does not work, run `./scripts/runtime/getKubeConfig.sh` to fetch it.

## Hetzner HCLOUD API / CLI

With Pulumi stack loaded, use:

```bash
export HCLOUD_TOKEN=$(pulumi config get hcloudToken)
hcloud server list
hcloud dns rrset list cape-project.eu
```

## ArgoCD CLI

you can use the argocd CLI. After 'make up' the CLI should be logged it. If this does not work, run `./scripts/runtime/argocdLoginCLI.sh` to fetch it.

### workaround using kubectl

kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=127.0.0.1 &>/tmp/argocd-pf.log &
PF_PID=$!
sleep 3
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d 2>/dev/null)
argocd login localhost:8080 --username admin --password "$ARGOCD_PASS" --insecure 2>&1
echo "PF_PID=$PF_PID"

## external repositories

in /external there are sources for external projects (Ryax, the upstream Helm charts for xwiki/zulip/authentik/jitsi/rocketchat, etc. — see scripts/environment/checkoutExternalGits.sh for the full list). You can use them to search for documentations. NEVER edit them, or refer to them in your code.

if the repositories in external do not exist, ask the user to run scripts/environment/checkoutExternalGits.sh

# Cluster Recreation (ecc84, ecc85, …)

To recreate the cluster with a new subdomain:

0. Prepare pulumi stack

- export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
- pulumi login "file://$(pwd)/.pulumi-state" >/dev/null 2>&1
- pulumi stack select mystack >/dev/null 2>&1
- echo "stack: $(pulumi stack --show-name 2>/dev/null)"

1. Destroy old cluster: `export PULUMI_CONFIG_PASSPHRASE=<passphrase> && make destroy ARGS="--yes"` (requires pulumi passphrase)
2. Commit the destroyed Pulumi stack state (`.pulumi-state/` is tracked in git)
3. Increment `subdomain` in `project_settings.ts` (e.g. ecc83 → ecc84)
4. Run `bash scripts/environment/updateConfigFromProjectSettings.sh` — updates all domain refs, cert issuer, GitHub URL across all deployment manifests
5. Commit changes (`git add deployment/ scripts/runtime/ryax/ project_settings.ts && git commit`)
   cd /workspaces/git_infra

6. Create new cluster: `make create` (requires passphrase)

Sealed secrets do NOT need re-sealing on subdomain change — they contain passwords only, no domain refs. Re-seal only when actual secret values change (run `deployment/authentik/sealSecrets.sh` and `deployment/gitlab/sealSecrets.sh` with Pulumi stack loaded).

ArgoCD OIDC note: after cluster creation, ArgoCD login via OIDC requires the Authentik `argocd` provider redirect URI to match the new subdomain. This is configured in `deployment/authentik/blueprint-apps.yaml` and applied automatically by ArgoCD on first sync.

Barriers: each barrier writes a ConfigMap `waveN-barrier-done` in the argocd namespace on first successful pass. On re-syncs, barriers exit immediately if the marker exists. To force a barrier to re-run, delete its ConfigMap: `kubectl delete configmap waveN-barrier-done -n argocd`.

# Switching from Staging to Production TLS Certificates

Change `certIssuerType` in `project_settings.ts` from `"letsencrypt-staging"` to `"letsencrypt-production"`, then run the update script:

```
bash scripts/environment/updateConfigFromProjectSettings.sh
```

The script updates ALL manifests automatically:

- All `cert-manager.io/cluster-issuer:` annotations in deployment manifests
- ArgoCD OIDC TLS verify (`oidc.tls.insecure.skip.verify`)
- Headplane Node TLS (`NODE_TLS_REJECT_UNAUTHORIZED`)
- GitLab/GitLab-runner presync curl insecure flag

Nextcloud `oidc_login_tls_verify` is set automatically by the postsync job based on the ingress cert-issuer annotation — no manual step needed.

Note: letsencrypt-prod has rate limits (5 certs/domain/week). Use staging for testing.

# Cloud↔Edge placement tiers

See `docs/cloud-edge-architecture.md` (+ `docs/redundancy-ha.md`, `docs/gitlab-migration.md`).

- Apps carry `placement.ecc/tier: cloud|flex|edge` on their ArgoCD Application; default `cloud` (`project_settings.ts` `placement.defaultTier`).
- Edge nodes are tainted `ecc/edge=true:NoSchedule` (in the k3s join); only workloads with a matching toleration (e.g. windows) run there — keeps cloud/system pods off edge.
- StorageClasses: `longhorn-cloud` (default, cloud disks), `longhorn-edge` (edge disks, only when `nodes.edge` non-empty), `seaweedfs` (S3-backed file PVCs, CSI at wave 14; cluster at wave 13).
- Pod placement ≠ volume placement: moving an app to edge means moving its state backends (file→SeaweedFS, DB→CNPG), not just rescheduling. Raw block (windows) stays `longhorn-edge`, edge-only (KVM).
- PriorityClasses (`deployment/infrastructure/priorityclasses/`): platform>essential>high>standard>low for graceful degradation under resource pressure.
- Deferred until edge nodes exist: SeaweedFS edge filer + active-active, CNPG mobility conversions + replica clusters, CNPG recovery-on-restore + edge auto-reconnect.

# Token opt

- Use short 3-6 word sentences
- no filler, preamble or pleasantries
- run tools first, show results then stop, don't narrate
- drop articles ("Me fix code" not "I will fix the code")

# External git repositories

script/environment/checkoutExternalGits.sh checks out external git repositories for used software. Use them to search for documentations and check if arguments exist there before guessing. NEVER edit them, or refer to them in your code.
If a repo does not exist, add it.
