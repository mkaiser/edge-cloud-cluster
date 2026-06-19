Longhorn replication between resident nodes = direct LAN, never crosses the internet.

### PVC Storage Inventory

| Application        | Component            | Size        |
| ------------------ | -------------------- | ----------- |
| ArgoCD             | helm-cache           | 2 Gi        |
| Authentik          | postgres             | 8 Gi        |
| Authentik          | redis                | 2 Gi        |
| Headscale          | postgres             | 1 Gi        |
| Headplane          | data                 | 2 Gi        |
| GitLab             | postgres             | 20 Gi       |
| GitLab             | redis                | 5 Gi        |
| GitLab             | minio                | 50 Gi       |
| Nextcloud          | postgres             | 8 Gi        |
| Nextcloud          | redis                | 2 Gi        |
| Nextcloud          | app-data             | 10 Gi       |
| RocketChat         | mongodb              | 16 Gi       |
| Zulip              | postgres             | 16 Gi       |
| Zulip              | redis                | 2 Gi        |
| Zulip              | rabbitmq             | 4 Gi        |
| Rallly             | postgres             | 4 Gi        |
| XWiki              | postgres             | 8 Gi        |
| XWiki              | app-data             | 5 Gi        |
| Windows            | postgres (guacamole) | 5 Gi        |
| Windows            | vm-storage           | 40 Gi       |
| **Total raw data** |                      | **~210 Gi** |

### Disk Requirements by Redundancy Mode

| Mode          | CP nodes | `highAvailability` | `replicaCount` | Total disk | Per-node           |
| ------------- | -------- | ------------------ | -------------- | ---------- | ------------------ |
| Single-node   | 1× CPX52 | false              | auto → 1       | ~210 Gi    | 210 Gi (44%)       |
| 2-replica     | 2× CX33  | false              | auto → 2       | ~420 Gi    | ~210 Gi/node (52%) |
| Full HA       | 3× CX33  | true               | auto → 3       | ~630 Gi    | ~210 Gi/node (35%) |
| Full HA large | 3× CPX52 | true               | auto → 3       | ~630 Gi    | ~210 Gi/node (44%) |

---
