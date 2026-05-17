# Deployment Directory

This directory contains all Kubernetes manifests and configurations for applications deployed via [ArgoCD](https://argoproj.github.io/) in a declarative, GitOps-driven manner.

## Directory Structure

```
deployment/
├── apps/                      # ArgoCD Application definitions (app-of-apps root)
├── argocd/                    # ArgoCD control plane configuration (self-managed)
├── gitlab/                    # GitLab deployment (optional, disabled by default)
├── headplane/                 # Headplane (VPN management UI)
├── headscale/                 # Headscale (WireGuard VPN server)
├── hello-argocd/              # Example/smoke-test application
├── kube-prometheus-stack/     # Prometheus + Grafana + Alertmanager
├── opendesk-cmp/              # openDesk Config Management Plugin (CMP) sidecar
├── opendesk-apps/             # openDesk app-of-apps chart (spawns child Applications)
├── renovate/                  # Renovate (dependency update bot, optional)
├── ryax-cmp/                  # Ryax CMP sidecar (optional)
├── secrets/                   # Shared sealed secrets (SMTP, etc.)
├── manageSealedSecrets.sh     # Shared helper for creating SealedSecrets
└── Deployment.md              # Legacy deployment notes
```

## ArgoCD Application Structure

This project uses the **app-of-apps pattern**. A single root Application (`argocd-main-app`) points to `deployment/apps/`, which contains one YAML file per Application. Each file is picked up by ArgoCD automatically.

```
argocd-main-app  (root, defined in deployment/argocd/)
└── deployment/apps/
    ├── wave0-argocd-infra.yaml       → ArgoCD self-upgrade
    ├── wave0-opendesk-cmp.yaml       → openDesk CMP sidecar
    ├── wave0-secrets.yaml            → Shared sealed secrets
    ├── wave1-cmp-readiness.yaml      → Gates openDesk until CMP is ready
    ├── wave1-external-dns.yaml       → ExternalDNS (Hetzner DNS)
    ├── wave2-hello-argocd.yaml       → Smoke-test app
    ├── wave2-opendesk.yaml           → openDesk app-of-apps (spawns child apps below)
    ├── wave3-kube-prometheus-stack.yaml
    ├── wave4-headscale.yaml
    └── wave5-headplane.yaml
```

### openDesk Child Applications (spawned by wave2-opendesk)

`wave2-opendesk` deploys `deployment/opendesk-apps/charts/opendesk`, which in turn creates one ArgoCD Application per openDesk component. These are rendered by the helmfile-opendesk CMP sidecar from the upstream openDesk git repository.

```
opendesk  (wave 2, app-of-apps)
├── wave 0  opendesk-cmp                        (CMP sidecar — pre-exists, not a child)
├── wave 1  opendesk-nubus-nubus                (Nubus/UMS base)
│           opendesk-opendesk-services          (core openDesk services)
│           opendesk-open-xchange-dovecot       (Dovecot IMAP)
│           opendesk-services-external          (external service connectors)
├── wave 2  opendesk-nubus-ums                  (UMS: LDAP, UDM, portal)
│           opendesk-nubus-intercom-service
│           opendesk-open-xchange-open-xchange  (OX App Suite)
│           opendesk-open-xchange-*-bootstrap   (OX bootstrap jobs)
│           opendesk-open-xchange-ox-connector
│           opendesk-open-xchange-postfix-ox    (Postfix for OX)
├── wave 3  opendesk-nubus-opendesk-keycloak-bootstrap
├── wave 4  opendesk-collabora                  (Collabora Online)
│           opendesk-cryptpad
│           opendesk-element                    (Matrix client)
│           opendesk-jitsi
│           opendesk-nextcloud-*-management
│           opendesk-notes
│           opendesk-xwiki
├── wave 5  opendesk-nextcloud-opendesk-nextcloud
└── wave 7  opendesk-opendesk-migrations-post
```

## Sync Wave Reference

| Wave | Application                                            | Depends On           |
| ---- | ------------------------------------------------------ | -------------------- |
| 0    | `argocd-infra` — ArgoCD self-upgrade                   | —                    |
| 0    | `opendesk-cmp` — helmfile CMP sidecar                  | —                    |
| 0    | `secrets` — shared sealed secrets (SMTP, …)            | —                    |
| 1    | `cmp-readiness` — blocks wave 2 until CMP pod is ready | wave 0 CMP           |
| 1    | `external-dns` — Hetzner DNS manager                   | —                    |
| 2    | `opendesk` — spawns all openDesk child apps            | wave 1 CMP readiness |
| 3    | `kube-prometheus-stack` — Prometheus / Grafana         | —                    |
| 4    | `headscale` — WireGuard VPN server                     | —                    |
| 5    | `headplane` — Headscale web UI                         | wave 4 headscale     |

ArgoCD processes waves in ascending order within a sync operation. All resources in wave N must be healthy before wave N+1 starts.

## Required Secrets

Before deploying a fresh cluster, run the `sealSecrets.sh` scripts for each component you want to enable. Sealed secrets are encrypted with the cluster's sealed-secrets controller public key and safe to commit to git.

### Always Required

| Script                              | Secret name        | What to enter                                                                                       |
| ----------------------------------- | ------------------ | --------------------------------------------------------------------------------------------------- |
| `deployment/secrets/sealSecrets.sh` | `smtp-credentials` | SMTP relay host, port, username, password (used by openDesk postfix and Keycloak for outbound mail) |

### openDesk (required for openDesk deployment)

openDesk credentials are configured via `project_settings.ts` (domain, master password, TURN password, S3 credentials) and the `opendesk-cmp` Helm values. The SMTP credentials above are the only sealed secret required specifically for openDesk.

### Optional Components

| Script                                            | Secret name(s)                                                                                         | What to enter                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `deployment/headscale/sealSecrets.sh`             | `headscale-oidc-client-secret`                                                                         | OIDC client secret for Headscale + Headplane authentication via Keycloak |
| `deployment/kube-prometheus-stack/sealSecrets.sh` | `kube-prometheus-stack-grafana`                                                                        | Grafana admin username and password                                      |
| `deployment/renovate/sealSecrets.sh`              | `renovate-token`                                                                                       | GitHub Personal Access Token for the Renovate dependency-update bot      |
| `deployment/gitlab/sealSecrets.sh`                | `gitlab-oidc-client-secret`, `gitlab-s3-connection`, `gitlab-registry-storage`, `gitlab-root-password` | GitLab OIDC integration, S3 object storage, and initial root password    |
| `deployment/gitlab-runner/sealRunnerToken.sh`     | `gitlab-runner-token`, `gitlab-runner-cache-s3`                                                        | GitLab Runner auth token (`glrt-...`) and S3 cache credentials           |

### Rotating / Updating a Secret

```bash
# Re-run the relevant sealSecrets.sh — it will overwrite the sealed file.
# Then commit and push; ArgoCD will apply the updated SealedSecret on next sync.
deployment/secrets/sealSecrets.sh
git add deployment/secrets/smtp-credentials-sealed.yaml
git commit -m "Rotate smtp-credentials"
git push
```

## Management

### Adding a New Application

1. Create directory: `deployment/<app-name>/`
2. Place manifests or a Helm chart there
3. Add `deployment/apps/waveN-<app-name>.yaml` with the appropriate sync wave
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

# Test outbound mail
bash scripts/testMail.sh your@address.com
```

## External References

- [ArgoCD Documentation](https://argoproj.github.io/)
- [Helmfile Docs](https://helmfile.readthedocs.io/)
- [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets)
