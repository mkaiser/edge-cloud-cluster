# Deployment via ArgoCD

## Apps of Apps

- argocd infra. self updating

## Sync Waves

All waves are managed by `argocd-main-app` (source: `deployment/apps/`).

| Wave  | Resources                                    | What happens                                                                                                                                                                                                                            | Est. time |
| ----- | -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| **0** | `argocd-infra` + `opendesk-cmp`              | ArgoCD self-upgrade via `argocd-self` (Helm chart); CMP ConfigMaps and SealedSecrets applied; repo-server pods roll out with `helmfile-opendesk` sidecar. On a fresh cluster: image pull of `travisghansen/argo-cd-helmfile` dominates. | 5–15 min  |
| **1** | `cmp-readiness` (Sync hook) + `external-dns` | Gate job polls until all `helmfile-*` containers are `ready=true` on every repo-server replica. Exits immediately if CMP is already up; waits up to 15 min on cold clusters. `external-dns` deploys in parallel.                        | 0–15 min  |
| **2** | `opendesk` (app-of-apps)                     | openDesk parent chart creates ~23 child Applications. Each child uses the `helmfile-opendesk` CMP to render its helmfile. CMP is guaranteed ready at this point.                                                                        | 10–30 min |
| **3** | `kube-prometheus-stack`                      | Prometheus + Grafana + Alertmanager Helm chart. Waits for openDesk CRDs to exist first.                                                                                                                                                 | 2–5 min   |
