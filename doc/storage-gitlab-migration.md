# GitLab: keeping Gitaly small with Git LFS → S3

GitLab's git repositories live on a POSIX filesystem (Gitaly), which is why GitLab
stays cloud-pinned ([cloud-edge-architecture.md](cloud-edge-architecture.md)): Gitaly
needs strong consistency, file locking, and low-latency small-file IO that an
object-backed FS can't provide. Large incompressible blobs committed to git bloat
Gitaly and slow its backups. **Git LFS** offloads those blobs to S3 (already
configured: GitLab `object_store` → bucket `edgecloudinfra-gitlab`, prefix
`gitlab-lfs`), leaving only small pointer files in the repo.

## Size-based vs pattern-based — the key limitation

Git LFS tracking is driven by **patterns** in a repo's `.gitattributes`; there is **no
built-in size threshold**. So:

- **Existing repos (size-based, one-off).** Rewrite history, moving every blob above a
  size into LFS:
  ```bash
  git lfs migrate import --above=500KB --everything
  ```
  This updates `.gitattributes` for the file *types* it moved. ⚠️ It **rewrites
  history** → force-push and all clones must re-clone. Coordinate with users.

- **New commits (ongoing).** Add a baseline `.gitattributes` per repo, e.g.:
  ```gitattributes
  *.bin   filter=lfs diff=lfs merge=lfs -text
  *.zip   filter=lfs diff=lfs merge=lfs -text
  *.tar   filter=lfs diff=lfs merge=lfs -text
  *.mp4   filter=lfs diff=lfs merge=lfs -text
  # ... extensions relevant to your large-binary projects
  ```

## GitLab-wide enforcement (free tier)

Instance/group **project templates** (auto-applying a baseline `.gitattributes` to new
projects) are GitLab **Premium** — not available on the free tier. The free,
instance-wide lever is a **global `pre-receive` server hook** (GitLab CE) that
**rejects** any push adding a non-LFS blob over the threshold. It enforces the policy
(it does **not** auto-convert — the developer must LFS-track and re-push).

Install as a global server hook (runs for every repo). On the Gitaly/GitLab side, place
an executable hook at the configured global hooks dir (e.g.
`/etc/gitlab/gitlab-rails/shared/custom_hooks/pre-receive.d/` or the Gitaly
`custom_hooks_dir`), for example:

```bash
#!/usr/bin/env bash
# Reject pushes that add a non-LFS blob larger than MAX_BYTES.
set -euo pipefail
MAX_BYTES=$((500 * 1024))
status=0
while read -r _old new _ref; do
  [ "$new" = "0000000000000000000000000000000000000000" ] && continue
  while read -r _mode type sha _path; do
    [ "$type" = "blob" ] || continue
    size=$(git cat-file -s "$sha" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_BYTES" ]; then
      # LFS pointer files are tiny text blobs; anything large is a raw binary.
      echo "REJECTED: $_path is $size bytes (> $MAX_BYTES). Use Git LFS." >&2
      status=1
    fi
  done < <(git rev-list --objects "$new" --not --all | \
           git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
           | awk '{print "", $1, $2, "", $4}')
done
exit $status
```

(Tune `MAX_BYTES` and the object-walk to your GitLab version; test on a scratch repo
first.)

## Already on S3 (no LFS needed)

GitLab CI **artifacts**, **packages**, and the container **registry** are separate
object types already stored in Hetzner S3 via `object_store` in
`deployment/apps/gitlab/values.yaml`.

## Verify

```bash
git lfs ls-files                 # blobs now tracked by LFS
du -sh .git                      # repo size before/after migrate
# + watch object growth in the gitlab-lfs prefix of edgecloudinfra-gitlab
```
