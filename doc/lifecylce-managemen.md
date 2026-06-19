Text about

make create

make destroy

make provision-edge [ARGS=cape-vm-lab]

make shutdown (backs up first to s3)

make restore


# Cluster Lifecycle — Shutdown and Restore

## Graceful shutdown (preserve data)

`make shutdown` stops the cluster without deleting infrastructure or S3 data so it can be restored later.

```
make shutdown
```

**What it does:**

1. Sets `completeClusterTeardown: false` in `project_settings.ts`
2. Runs `pulumi up` to sync the teardown flag into the stack
3. Creates an on-demand etcd snapshot and uploads it to S3 (`edgecloud-etcd` bucket)
4. Triggers Longhorn S3 backups for all volumes
5. Drains all cluster nodes (graceful pod eviction)
6. Runs `pulumi dn` — destroys servers, DNS, and network (S3 buckets are kept because `completeClusterTeardown=false`)
7. Sets `restoreClusterFromS3Backup: true` in `project_settings.ts`

**After shutdown:** commit the changed `project_settings.ts`, then run `make create` — k3s will restore etcd from the latest S3 snapshot automatically.

## Full destroy (delete everything)

`make destroy` tears down all infrastructure. With `completeClusterTeardown: true` it also deletes all S3 buckets and their contents (irreversible).

```
# set completeClusterTeardown: true in project_settings.ts for full wipe
make destroy
```

With `completeClusterTeardown: false` the servers and DNS records are deleted but S3 buckets (etcd snapshots, Longhorn backups, application data) are kept.

## Cluster lifecycle reference

| Command                         | Infrastructure        | S3 data     | Restorable         |
| ------------------------------- | --------------------- | ----------- | ------------------ |
| `make shutdown`                 | Destroyed (pulumi dn) | Kept        | Yes                |
| `make destroy` (teardown=false) | Deleted               | Kept        | With fresh cluster |
| `make destroy` (teardown=true)  | Deleted               | **Deleted** | No                 |
| `make create`                   | Provisioned           | —           | —                  |
