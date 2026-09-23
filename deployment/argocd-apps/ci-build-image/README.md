# ci-build-image — buildah **and** skopeo in one CI image

Every image-building pipeline in this repo needs two things: `buildah` to build, and a way
to ask a registry **whether a tag already exists** before spending minutes-to-hours
rebuilding it. `skopeo inspect` is that way. No maintained upstream image ships both
(measured 2026-09-02):

| image | buildah | skopeo | curl |
|---|---|---|---|
| `quay.io/buildah/stable` | 1.43.2 | — | 8.18.0 |
| `quay.io/podman/stable` | — | — | yes |
| **this image** | 1.43.2 | 1.22.2 | 8.18.0 |

`dnf -y install skopeo` on top of the buildah image costs **~38 MB** (673 MB vs 635 MB).

## Who uses it

Seven pipelines, all of which now run their recover-or-rebuild gate with `skopeo inspect`:

`eda/xilinx-2024-1`, `eda/xilinx-2026-1`, `eda/petalinux-2024-1`, `eda/hyperlynx-2604`,
`remote-desktop` (ci-base.yml), `ollama`, `vllm`.

They pin it by tag:

```yaml
image: $CI_REGISTRY/deployments/infrastructure/ci/build-image:<IMAGE_TAG>
```

## Bumping the tag

`IMAGE_TAG` in `.gitlab-ci.yml` is the sole cache key and the pin every consumer carries,
so a bump is a **seven-file change**: this file, the six consumers' `image:` lines, and
each consumer's `build-files-configmap.yaml` (regenerate, do not hand-edit).
`remote-desktop/check-image-invariants.sh` fails the commit if any of them disagree.

Regenerate the ConfigMaps after any edit:

```bash
deployment/argocd-apps/remote-desktop/sync-build-files.sh deployment/argocd-apps/ci-build-image
```

## Three things that will bite you

**1. This pipeline does NOT run on its own output, and its gate is curl.** It builds on the
plain `quay.io/buildah/stable`. An image built with itself cannot be built on a cluster
where it does not exist yet — which is every cluster right after a recreate. Do not
"harmonise" this pipeline's gate with the six it enables.

**2. Consumers must be able to PULL it, and that is a GitLab setting, not a file.** A
consumer's build pod pulls this image with `gitlab-ci-token` + the **consumer project's**
`CI_JOB_TOKEN`. Since GitLab 16 a project refuses job tokens from other projects unless
they are on its **inbound allowlist**. A refusal is not a message: the build pod never
starts, the job fails at image pull, and nothing rebuilds anything.

⚠ **This project cannot open itself.** Measured on ecc193 (2026-09-02):

```
PATCH /projects/:id/job_token_scope  enabled=false
-> 400 "Job token scope cannot be disabled for this project because it is enforced
        for the instance."
```

So each consumer's own build trigger registers itself instead, right after it waits for the
image:

```
POST /projects/<build-image>/job_token_scope/allowlist  target_project_id=<consumer>
# 201 first time, 400 "already in the job token allowlist" afterwards
```

Self-registration rather than a list kept here: a list would need editing the day a seventh
pipeline appears, and a missing entry fails as invisibly as described above.

Check who is allowed:

```bash
curl -sS -H "PRIVATE-TOKEN: $PAT" \
  "$GITLAB_API/projects/deployments%2Finfrastructure%2Fci%2Fbuild-image/job_token_scope/allowlist"
```

If that route is ever closed off too, the fallback is a `read_registry` deploy token on this
project, published to each consumer as a `DOCKER_AUTH_CONFIG` CI variable (the runner uses
it for the job `image:` pull) — six more variables to keep alive, which is why it is the
fallback.

**3. Consumers wait for it; it does not wait for them.** The trigger here mirrors and fires
the pipeline and exits — waiting would park the Job behind whatever the `[eda]` runner is
doing (a Vivado build is hours) until the Job deadline killed it. Each consumer's own
trigger blocks until this tag is in the registry before it fires its pipeline, and fails
if it is not, so ArgoCD retries instead of leaving a pipeline that died at image pull with
nothing to re-trigger it.

## Deliberately NOT archived to image-registry

`remote-desktop`, `ollama` and `vllm` archive their images to the TrueNAS-backed
`image-registry` because rebuilding them costs 10 minutes to several hours. This image is one
`dnf install` on a pulled base — a few minutes — and `image-registry` has **no garbage
collection**, so every tag parked there is permanent. It is rebuilt after a recreate, on
purpose.

## Verify

```bash
# the tag exists
kubectl -n gitlab exec deploy/gitlab-toolbox -c toolbox -- \
  gitlab-rails runner "puts Project.find_by_full_path('deployments/infrastructure/ci/build-image').container_repositories.flat_map(&:tags).map(&:name)"

# the image really carries both tools (from any node with the pull secret)
skopeo inspect --config docker://registry.gitlab.<tld>/deployments/infrastructure/ci/build-image:<tag>
```
