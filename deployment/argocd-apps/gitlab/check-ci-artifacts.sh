#!/bin/bash
# Assert that no pipeline in this repo hands bulk data to GitLab's `artifacts:` keyword.
#
# WHY THIS EXISTS: `artifacts:` looks like the obvious way to move a build output between
# jobs, and here it is the expensive one. The bytes do not go where the bucket setting
# suggests: the runner PUTs to `/api/v4/jobs/:id/artifacts` and **Workhorse** performs the
# object-storage write ("GitLab Workhorse can offload all storage related uploads",
# the GitLab chart docs, charts/globals.md). Workhorse runs in the cloud and the artifacts
# bucket is on the appliance in the lab. So a lab-built artifact travels:
#
#     lab runner --(4.9 MB/s, measured)--> Workhorse (cloud) --(20 MB/s)--> appliance (lab)
#
# For a 30 GB EDA output that is ~1 h 45 m up plus ~25 m back down, to land on a disk that
# was 200 m from the runner. Pushed straight to the endpoint over the LAN it is ~5.5 min.
#
# ⚠ THE FIX IS NOT A BIGGER BUCKET OR A CLOSER ONE. It is not using `artifacts:` for bulk:
# push the object yourself and let `artifacts:` carry the small things — logs, reports,
# manifests, the URL of the big object. That IS selectable per job, because it is just
# script; the storage backend is not (GitLab's object storage is per-CATEGORY and
# instance-wide, so there is no per-job or per-project override to reach for).
#
# ⚠ NOTHING IN THIS REPO USES `artifacts:` TODAY — every build publishes to a registry
# instead. This check exists so that stays true by decision rather than by luck, and so the
# next person who reaches for `artifacts:` reads the reason first.
#
# Small use is fine and is what the keyword is for; the check fires on `artifacts:` with a
# `paths:` block, which is the shape that moves files. If you genuinely need it, the
# exemption is a comment on the line saying why — see ALLOW below.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_DIR"

# CI definitions live in two shapes here: standalone .gitlab-ci.yml files, and the same
# content mirrored into GitLab through build-files ConfigMaps.
# ⚠ THE NAME LIST IS THE WHOLE COVERAGE. A pipeline file named anything else escapes this
# check SILENTLY — it still passes, just without having looked. `ci/*.yml` catches the
# configs that cannot live in their own repository: a MIRRORED project's tree is
# force-pushed over by the mirror, so its pipeline is seeded into a separate project and
# selected with ci_config_path (see osxcar-sdv-switch/ci/). Add new shapes here.
mapfile -t FILES < <(find deployment/argocd-apps \
    \( -name '.gitlab-ci.yml' -o -name 'ci-base.yml' -o -name 'build-files-configmap.yaml' \
       -o -path '*/ci/*.yml' \) \
    -type f 2>/dev/null | sort)

ALLOW='ci-artifacts-ok'   # put this in a comment on the artifacts: line to exempt it
fail=0

for f in "${FILES[@]}"; do
    # Find `artifacts:` lines, then look ahead a few lines for a `paths:` block. A bare
    # `artifacts:` with only `reports:` or `expire_in:` is not what this is about.
    while IFS=: read -r line _; do
        [ -n "$line" ] || continue
        window=$(sed -n "${line},$((line + 6))p" "$f")
        printf '%s' "$window" | grep -qE '^\s*paths:' || continue
        printf '%s' "$window" | grep -q "$ALLOW" && continue
        echo "ERROR: $f:$line — 'artifacts:' with paths:" >&2
        sed -n "${line},$((line + 6))p" "$f" | sed 's/^/    /' >&2
        fail=1
    # ⚠ THE TRAILING-COMMENT CASE MATTERS — keep `(#.*)?` in the anchor below. Anchoring on
    # `artifacts:\s*$` alone does not match `artifacts:  # anything`, so a violation written
    # that way slips through silently while the exemption above appears to work.
    done < <(grep -nE '^[[:space:]]*artifacts:[[:space:]]*(#.*)?$' "$f" 2>/dev/null | cut -d: -f1 | sed 's/$/:/')
done

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

Bulk output must not travel through `artifacts:` — it goes via Workhorse in the cloud even
when both the runner and the bucket are in the lab (see this script's header for the
measured cost).

Instead, from the job script, push straight to the on-prem endpoint:

    aws --endpoint-url "$ONPREM_S3_ENDPOINT" s3 cp build/out.tar \
        "s3://$ONPREM_S3_BUCKET/$CI_PROJECT_PATH/$CI_JOB_ID/out.tar"

and keep `artifacts:` for the small things — logs, reports, and the URL you just wrote.

If a small `paths:` really is right here, add a comment containing `ci-artifacts-ok` on the
`artifacts:` line saying why.
EOF
    exit 1
fi

echo "OK: no pipeline hands bulk data to artifacts: (${#FILES[@]} CI file(s) checked)"
