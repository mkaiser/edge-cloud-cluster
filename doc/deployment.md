# Deployment Directory

This directory contains all Kubernetes manifests and configurations for applications deployed via [ArgoCD](https://argoproj.github.io/) in a declarative, GitOps-driven manner.

## Directory Structure

```
deployment/
├── argocd-sync-waves/     # ArgoCD Application definitions (app-of-apps root)
├── infra/                 # Cluster infrastructure & platform components
├── apps/                  # End-user applications
├── manual/                # Components installed out-of-band (not auto-synced)
├── manageSealedSecrets.sh # Shared helper functions for creating SealedSecrets
├── sealAllSecrets.sh      # Seals every component's secrets in dependency order
└── Deployment.md          # Short app-of-apps / sync-wave notes
```

### `infra/` — infrastructure & platform

| Component                              | Purpose                                                                             |
| -------------------------------------- | ----------------------------------------------------------------------------------- |
| `argocd-infra`                         | Self-managed ArgoCD (ArgoCD reconciles itself)                                      |
| `external-dns`                         | Creates Hetzner DNS records from Ingress hostnames                                  |
| `kube-vip`                             | Stable VIP for the k3s API server                                                   |
| `sealed-secrets-guard`                 | Self-heals the sealed-secrets controller after API flaps                            |
| `haproxy-ingress-guard`                | Restarts haproxy-ingress if an Ingress lacks LB status                              |
| `longhorn`                             | Longhorn operational config (RecurringJobs, BackupTarget)                           |
| `seaweedfs`                            | S3-backed file layer for cloud↔edge apps (master/volume/filer + S3 gateway); wave 0 |
| `seaweedfs-csi-driver`                 | CSI driver providing the `seaweedfs` StorageClass; wave 2                           |
| `kube-prometheus-stack`                | Prometheus + Grafana + Alertmanager                                                 |
| `renovate`                             | Dependency-update bot                                                               |
| `system-upgrade-controller`            | k3s node upgrades                                                                   |
| `k3s-upgrade-plans`                    | Upgrade plans for the controller above                                              |
| `k3s-upgrade-plan-save-cordoned-nodes` | Preserves cordon state across k3s upgrades                                          |
| `hello-argocd`                         | Smoke-test application                                                              |
| `authentik`                            | OIDC identity provider + initial users                                              |
| `headscale`                            | Headscale WireGuard/Tailscale VPN server                                            |
| `headplane`                            | Headscale admin web UI                                                              |
| `mesh-gateway`                         | Tailscale VPN agent DaemonSet on control-plane nodes                                |
| `notify`                               | Sends staged bootstrap-progress emails                                              |

### `apps/` — end-user applications

| Component       | Purpose                                    |
| --------------- | ------------------------------------------ |
| `nextcloud`     | Nextcloud file storage + Collabora editing |
| `xwiki`         | XWiki wiki                                 |
| `gitlab`        | Self-hosted GitLab CE                      |
| `gitlab-runner` | In-cluster GitLab CI runner                |
| `zulip`         | Zulip team messaging                       |

All apps authenticate against Authentik via OIDC.

### `manual/`

| Component | Purpose                                                     |
| --------- | ----------------------------------------------------------- |
| `ryax`    | Ryax engine — installed manually, not part of the auto-sync |

## ArgoCD Application Structure

This project uses the **app-of-apps pattern**. A single root Application
(`argocd-main-app`, defined in `src/argocd.ts`) watches
`deployment/argocd-sync-waves/`. Each YAML file there is one ArgoCD Application
that points at a component directory under `infra/`, `apps/`, or `manual/`.

```
argocd-main-app  (root)
└── deployment/argocd-sync-waves/
    ├── wave0-argocd-infra.yaml          → infra/argocd-infra
    ├── wave0-external-dns.yaml          → infra/external-dns
    ├── wave0-kube-vip.yaml              → infra/kube-vip
    ├── wave0-sealed-secrets-guard.yaml  → infra/sealed-secrets-guard
    ├── wave0-haproxy-ingress-guard.yaml → infra/haproxy-ingress-guard

    ├── wave1-barrier.yaml               → blocks wave 2 until wave 0 is healthy
    ├── wave2-longhorn-config.yaml       → infra/longhorn
    ├── wave2-kube-prometheus-stack.yaml → infra/kube-prometheus-stack
    ├── wave2-renovate.yaml              → infra/renovate
    ├── wave2-system-upgrade-controller.yaml
    ├── wave2-hello-argocd.yaml          → infra/hello-argocd
    ├── wave3-barrier.yaml
    ├── wave3-k3s-upgrade-plan-save-cordoned-nodes.yaml → infra/k3s-upgrade-plan-save-cordoned-nodes
    ├── wave4-k3s-upgrade-plans.yaml     → infra/k3s-upgrade-plans
    ├── wave5-barrier.yaml
    ├── wave6-authentik.yaml             → infra/authentik
    ├── wave7-barrier.yaml
    ├── wave8-headscale.yaml             → infra/headscale
    ├── wave8-headplane.yaml             → infra/headplane
    ├── wave9-barrier.yaml
    ├── wave10-mesh-gateway.yaml         → infra/mesh-gateway
    ├── wave18-barrier.yaml              (gates wave 19/20 on all infra Synced+Healthy)
    ├── wave19-notify.yaml               → infra/notify (bootstrap email, once)
    ├── wave20-nextcloud.yaml            → apps/nextcloud
    ├── wave20-xwiki.yaml                → apps/xwiki
    ├── wave20-gitlab.yaml               → apps/gitlab
    ├── wave20-gitlab-runner.yaml        → apps/gitlab-runner
    ├── wave20-jitsi.yaml                → apps/jitsi
    ├── wave20-rocketchat.yaml           → apps/rocketchat
    └── wave20-zulip.yaml                → apps/zulip
```

## Sync Wave Reference

| Wave | Application(s)                                                                                      |
| ---- | --------------------------------------------------------------------------------------------------- |
| 0    | `argocd-infra`, `external-dns`, `kube-vip`, `sealed-secrets-guard`, `haproxy-ingress-guard`         |
| 1    | barrier                                                                                             |
| 2    | `longhorn-config`, `kube-prometheus-stack`, `renovate`, `system-upgrade-controller`, `hello-argocd` |
| 3    | barrier, `k3s-upgrade-plan-save-cordoned-nodes`                                                     |
| 4    | `k3s-upgrade-plans`                                                                                 |
| 5    | barrier                                                                                             |
| 6    | `authentik` (OIDC provider + initial users)                                                         |
| 7    | barrier                                                                                             |
| 8    | `headscale`, `headplane`                                                                            |
| 9    | barrier                                                                                             |
| 10   | `mesh-gateway`                                                                                      |
| 18   | barrier (gates wave 19/20 on all infra Synced+Healthy)                                              |
| 19   | `notify` (core-platform-ready email, sent once)                                                     |
| 20   | `nextcloud`, `xwiki`, `gitlab`, `gitlab-runner`, `jitsi`, `rocketchat`, `zulip`                     |

ArgoCD processes waves in ascending order. **Barriers** are sync-guard apps that
block the next wave until all apps in the current wave are healthy. Each barrier
writes a `waveN-barrier-done` ConfigMap in the `argocd` namespace on first
success and exits immediately on re-syncs. To force a barrier to re-run, delete
its ConfigMap:

```bash
kubectl delete configmap waveN-barrier-done -n argocd
```

Longhorn and the sealed-secrets controller are installed by Pulumi (not ArgoCD)
before wave 0 runs.

## Secrets

All deployment secrets are stored as **SealedSecrets** — encrypted with the
sealed-secrets controller's public key (created by Pulumi) and safe to commit to
git. The Authentik bundle is the canonical source for every OIDC client secret;
other components recover their client secret from it.

### Seal everything at once

From a loaded Pulumi stack (`source ./scripts/pulumi/initPulumiStack.sh`):

```bash
bash deployment/sealAllSecrets.sh                  # first deploy
bash deployment/sealAllSecrets.sh --regenerate     # rotate auto-generated secrets
```

`sealAllSecrets.sh` runs each component's seal script in dependency order
(Authentik first, since it produces the OIDC client secrets the others recover).
This is invoked automatically by `scripts/secrets/setAllSecrets.sh` during the
full bootstrap — see the top-level [README](../README.md#step-2--set-up-secrets).

### Per-component seal scripts

| Script                                       | Seals                                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------------------ |
| `infra/authentik/sealSecrets.sh`             | Authentik core + **all OIDC client secrets** + `clusteradmin`/`testuser` credentials |
| `infra/argocd-infra/sealSecrets.sh`          | ArgoCD SMTP credentials (notifications + bootstrap-finished mail)                    |
| `infra/headscale/sealSecrets.sh`             | Headscale secrets (OIDC client secret recovered from Authentik bundle)               |
| `infra/kube-prometheus-stack/sealSecrets.sh` | Grafana admin password + Alertmanager SMTP credentials                               |
| `infra/longhorn/sealSecrets.sh`              | SMTP credentials for the weekly backup-report CronJob                                |
| `infra/renovate/sealSecrets.sh`              | GitHub PAT for Renovate                                                              |
| `apps/nextcloud/sealSecrets.sh`              | Nextcloud admin + DB password                                                        |
| `apps/xwiki/sealSecrets.sh`                  | XWiki DB + superadmin password                                                       |
| `apps/gitlab/sealSecrets.sh`                 | GitLab root password + DB + rails secrets + S3                                       |
| `apps/gitlab-runner/sealRunnerToken.sh`      | GitLab Runner auth token + S3 cache credentials                                      |
| `apps/zulip/sealSecrets.sh`                  | Zulip Django secret key + DB + S3                                                    |
| `apps/ryax/sealSecrets.sh`                   | Ryax admin credentials                                                               |

> The GitLab OIDC client secret is **not** sealed by Authentik —
> `apps/gitlab/presync-oidc-secrets.yaml` creates it dynamically at sync time.

### Rotating a single secret

```bash
# Re-run the relevant seal script — it overwrites the sealed file.
# Then commit and push; ArgoCD applies the updated SealedSecret on next sync.
bash deployment/apps/nextcloud/sealSecrets.sh
git add deployment/apps/nextcloud/*-sealed.yaml
git commit -m "Rotate nextcloud secrets"
git push
```

## Management

### Adding a new application

1. Create a directory: `deployment/apps/<app-name>/` (or `infra/<app-name>/`)
2. Place manifests or a Helm chart there
3. Add `deployment/argocd-sync-waves/waveN-<app-name>.yaml` with the right sync wave
4. Commit and push — ArgoCD auto-syncs

### Debugging

```bash
# Application status
argocd app list
argocd app get <app-name>

# Sync an app manually
argocd app sync <app-name>

# Check why an app is OutOfSync
argocd app diff <app-name>
```
