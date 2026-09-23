#!/bin/bash
# Assert the four invariants that keep an image ARCHIVE usable across a cluster recreate.
#
# WHY THIS EXISTS: every one of these has already shipped, and none of them fails loudly.
# The shared failure mode is that CI still succeeds — it just rebuilds from installer media
# for HOURS, or worse, serves a DIFFERENT image under a tag believed good. Nothing in the
# cluster reports an error, so the cost only surfaces on the next recreate.
#
#   1. CA-before-gate  — every recover-or-rebuild gate reads the image-registry CA from
#      /etc/containers/certs.d/<host>/ca.crt, and that file is materialised from the
#      $IMAGE_REGISTRY_CA job variable by a separate step. All three EDA pipelines had the
#      write ~70 lines AFTER the gate, so on a fresh runner pod the gate failed on the
#      missing CA. The gates are deliberately FAIL-OPEN, so the gate could never
#      short-circuit and every module rebuilt from media every time, with no error
#      anywhere.
#      ⚠ The gates now call `skopeo`, which reads certs.d IMPLICITLY — there is no
#      --cacert flag to spot any more, so the ordering is even easier to break by
#      accident. Both forms count as a use here.
#
#   2. IMAGE_TAG agrees everywhere — the tag is the SOLE cache key for the archive, and it
#      appears in ci-base.yml, in the mirrored build-files ConfigMap, and on every
#      container image: ref in EVERY CONSUMER of the base image (IMAGE_CONSUMERS below:
#      both desktops and the [eda-run] runner). A partial bump means the pipeline archives
#      one tag while a consumer pulls another.
#      ⚠ The consumer list was desktop-gvisor.yaml ALONE until 2026-09-14, so the runner's
#      pin was never compared and a bump could report "consistent" while leaving it stale.
#
#   3. build inputs changed => IMAGE_TAG changed — commit 55029d99 changed Dockerfile.base
#      and the BUILD_SCRIPTS but left IMAGE_TAG at base-r36, so ONE tag named two different
#      images. That is the dangerous direction: not an ImagePullBackOff, but a wrong image
#      under a believed-good tag, restored from the archive on every future recreate.
#      (The inverse slip is commit 5485150c: a tag bumped during a recreate with no build
#      change at all, which merely invalidated a good archive — see the "do not bump image
#      tags during a recreate" note in CLAUDE.md.)
#
#   4. the CI build image pin agrees everywhere — six pipelines run on
#      deployments/infrastructure/ci/build-image:<tag>, built by the ci-build-image app.
#      A consumer pinned to a tag that app never built does not fail with a message: its
#      build POD never starts. So the pin is compared against that app's IMAGE_TAG, in the
#      CI files and in the mirrored ConfigMaps alike, and a change to that app's Dockerfile
#      must come with a bump for the same reason invariant 3 exists.
#
# All four are pure-local text checks: no cluster, no registry, no network.
#
#   ./check-image-invariants.sh    exit 1 on the first violation, naming the file
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import glob, os, re, subprocess, sys

root = sys.argv[1]
fail = []

# general.domain from project_settings.ts — the same single source of truth the rewrite uses.
# Hardcoding it here would make this guard fire on a domain change (and stop normalising the
# hostname it exists to normalise).
_settings = open(os.path.join(root, "project_settings.ts")).read()
BASE_DOMAIN = re.search(r'^\s*domain:\s*"([^"]+)"', _settings.split("general:", 1)[1], re.M).group(1)


def rel(p):
    return os.path.relpath(p, root)


# ─── 1. CA-write must precede any --cacert use, in every CI file ────────────────────
# Checked on the SOURCE files and on the mirrored ConfigMap copies alike: the ConfigMap is
# what actually reaches the build (the sources are `exclude`d from the ArgoCD Application),
# so a correct source with a stale ConfigMap is still broken in CI.
ci_files = sorted(
    glob.glob(os.path.join(root, "deployment/argocd-apps/eda/*/.gitlab-ci.yml"))
    + glob.glob(os.path.join(root, "deployment/argocd-apps/*/.gitlab-ci.yml"))
    + glob.glob(os.path.join(root, "deployment/argocd-apps/remote-desktop/ci-base.yml"))
    + glob.glob(os.path.join(root, "deployment/argocd-apps/*/build-files-configmap.yaml"))
    + glob.glob(os.path.join(root, "deployment/argocd-apps/eda/*/build-files-configmap.yaml"))
)
checked_ca = 0
def is_comment(ln):
    # A `#` line inside a YAML block scalar is a SHELL comment; either way it does not
    # execute. Matching it produced a false positive on a comment that merely NAMED
    # --cacert while explaining the ordering rule.
    return ln.lstrip().startswith("#")


for f in ci_files:
    text = open(f).read().split("\n")
    # First line that WRITES the CA file, and first line that USES it. Comments excluded:
    # only executable lines can be mis-ordered.
    write = next((i for i, ln in enumerate(text)
                  if not is_comment(ln) and "certs.d" in ln
                  and ("mkdir -p" in ln or ">" in ln and "ca.crt" in ln)), None)
    # A "use" is anything that VERIFIES TLS against that CA: curl's explicit --cacert, or
    # a skopeo call naming the private-CA registry (skopeo reads certs.d implicitly, so
    # there is no flag to look for — the dependency is invisible in the line itself).
    #
    # ⚠ MATCHED ON LOGICAL LINES, not physical ones. `skopeo inspect` and the ref it
    # inspects sit on either side of a `\` continuation, so a per-physical-line match saw
    # neither and silently found no use at all in all three EDA pipelines — a check that
    # passes by not checking, which is the failure mode this whole script exists to stop.
    def uses_ca(ln):
        if "--cacert" in ln:
            return True
        return "skopeo" in ln and ("$IMAGE_REGISTRY" in ln or "SURVIVING_IMAGE" in ln
                                   or "INTERNAL_REGISTRY" in ln)

    use, joined, first = None, "", None
    for i, ln in enumerate(text):
        if is_comment(ln):
            continue
        if first is None:
            first = i
        joined += " " + ln.rstrip("\\")
        if ln.rstrip().endswith("\\"):
            continue                      # continued — keep accumulating
        if uses_ca(joined):
            use = first
            break
        joined, first = "", None
    if use is None:
        continue
    checked_ca += 1
    if write is None:
        fail.append(f"{rel(f)}:{use+1} verifies TLS against the image-registry CA but never writes the CA file")
    elif write > use:
        fail.append(
            f"{rel(f)}: the image-registry CA is used at line {use+1} but not written until line "
            f"{write+1} — the gate runs before the file exists, fails open, and NEVER skips a build")

# ─── 1b. A /v2/…/manifests/… URL must not be built from ${VAR#*/} ───────────────────
# `${IMAGE#*/}` strips the registry HOST but leaves the ":TAG", so the URL asks for a
# repository literally named "<path>/<name>:<tag>". That repo cannot exist, so the gate
# gets a permanent 404 — and because it is fail-open, that reads as "not in the registry"
# and rebuilds from installer media every single run, silently. Measured on ecc188: the
# buggy form returned 404 and the tag-free form 200 against the same tag.
#
# A `docker://` destination is the OPPOSITE case — the tag belongs there — so this only
# inspects /v2/ URLs.
for f in ci_files:
    for i, ln in enumerate(open(f).read().split("\n")):
        if is_comment(ln) or "/v2/" not in ln:
            continue
        seg = ln.split("/v2/", 1)[1]
        if "#*/" in seg:
            fail.append(
                f"{rel(f)}:{i+1} builds a /v2/ URL from ${{...#*/}}, which leaves the ':TAG' "
                f"suffix in the REPOSITORY name — a permanent 404, and the gate fails open "
                f"into a full rebuild. Use a host-free AND tag-free var (IMAGE_REPO).")

# ─── 2. IMAGE_TAG must agree across every site ──────────────────────────────────────
rd = os.path.join(root, "deployment/argocd-apps/remote-desktop")
tags = {}

m = re.search(r"^\s*IMAGE_TAG:\s*(\S+)", open(os.path.join(rd, "ci-base.yml")).read(), re.M)
if m:
    tags["ci-base.yml"] = m.group(1)

cm = open(os.path.join(rd, "build-files-configmap.yaml")).read()
m = re.search(r"^\s*IMAGE_TAG:\s*(\S+)", cm, re.M)
if m:
    tags["build-files-configmap.yaml"] = m.group(1)

# Every CONSUMER of the desktop base image, not just the one that builds it.
#
# ⚠ THIS LIST IS THE WHOLE POINT OF THE INVARIANT, and it was wrong until 2026-09-14:
# only desktop-gvisor.yaml was scanned, so gitlab-runner-eda-run.yaml — which pins the same
# image for the [eda-run] runner's build pods — was invisible here. A bump therefore reported
# "consistent" while that runner stayed pinned to a tag the archive gate no longer refreshes.
# Anything that names `remote-desktop:base-r*` belongs in this list; a consumer left out is
# not merely unchecked, it is silently asserted to be correct.
IMAGE_CONSUMERS = [
    "deployment/argocd-apps/remote-desktop/desktop-gvisor.yaml",
    "deployment/argocd-apps/remote-desktop-bender/desktop-bender.yaml",
    "deployment/argocd-apps/app-of-apps/gitlab-runner-eda-run.yaml",
    "deployment/argocd-apps/hermes/statefulset.yaml",
]
for relpath in IMAGE_CONSUMERS:
    path = os.path.join(root, relpath)
    if not os.path.exists(path):
        continue
    name = os.path.basename(relpath)
    # ⚠ Keyed by FILE, and every tag a file names is recorded — not setdefault'd away.
    # The old code collapsed a file's several tags into one key, so the cross-file
    # comparison below could not see a within-file disagreement at all.
    # ⚠ The terminator must include the QUOTE. Consumers are not all YAML: the [eda-run]
    # runner's tag sits inside an HCL string (image = "...:base-r67"), so a \S+ bounded only
    # by whitespace swallows the closing quote and the tag never compares equal to the
    # YAML consumers' — a false failure that looks exactly like real drift.
    found = sorted(set(re.findall(r"remote-desktop:(base-r[^\s\"']+)", open(path).read())))
    for t in found:
        tags[f"{name}[{t}]" if len(found) > 1 else name] = t

# One global check rather than one per file: two consumers each self-consistent but pinned to
# DIFFERENT tags is exactly the drift this exists to catch, and a per-file check cannot see it.
distinct = set(tags.values())
if len(distinct) > 1:
    detail = ", ".join(f"{k}={v}" for k, v in sorted(tags.items()))
    fail.append(f"IMAGE_TAG disagrees across sites ({detail}) — a partial bump archives one "
                f"tag while the Deployment pulls another")

# ─── 4. The CI build image pin must equal ci-build-image's own IMAGE_TAG ────────────
# The six pipelines run IN that image. A pin naming a tag that was never built does not
# produce an error message — the build pod never starts, so the job fails at image pull and
# nothing rebuilds anything.
cbi_dir = os.path.join(root, "deployment/argocd-apps/ci-build-image")
cbi_ci = os.path.join(cbi_dir, ".gitlab-ci.yml")
cbi_tag = None
if os.path.exists(cbi_ci):
    m = re.search(r"^\s*IMAGE_TAG:\s*(\S+)", open(cbi_ci).read(), re.M)
    cbi_tag = m.group(1) if m else None
pins = {}
for f in ci_files:
    for i, ln in enumerate(open(f).read().split("\n")):
        if is_comment(ln):
            continue
        m = re.search(r"ci/build-image:(\S+)", ln)
        if m:
            pins.setdefault(m.group(1), []).append(f"{rel(f)}:{i+1}")
# The [thor] consumers (ollama, vllm) run on arm64 and pin `<tag>-arm64`, built by the
# second job in the same pipeline. Both are legitimate; anything else is drift.
if cbi_tag and pins:
    allowed = {cbi_tag, cbi_tag + "-arm64"}
    wrong = {t: w for t, w in pins.items() if t not in allowed}
    if wrong:
        detail = "; ".join(f"{t} at {', '.join(w)}" for t, w in sorted(wrong.items()))
        fail.append(f"CI build image pinned to a tag ci-build-image does not build "
                    f"(it builds {cbi_tag} and {cbi_tag}-arm64): {detail}")
elif pins and not cbi_tag:
    fail.append("pipelines pin ci/build-image:<tag> but ci-build-image/.gitlab-ci.yml has no IMAGE_TAG")

# ─── 3. A staged build-input change must come with an IMAGE_TAG bump ────────────────
# Only meaningful for a commit; skipped when nothing is staged (e.g. a manual run).
staged = subprocess.run(["git", "-C", root, "diff", "--cached", "--name-only",
                         "--diff-filter=ACMR"],
                        capture_output=True, text=True).stdout.split()
BUILD_SCRIPTS = ["broker.sh", "module-cli.sh", "module-podman.sh"]
inputs = ["deployment/argocd-apps/remote-desktop/Dockerfile.base"] + [
    f"deployment/argocd-apps/remote-desktop/{s}" for s in BUILD_SCRIPTS]
def strip_noise(text):
    """Build-significant content only: no comments, no blank lines, no trailing space.

    A comment-only edit cannot change the built image, so demanding a tag bump for one is
    actively harmful: image-registry has NO GC, so every needless bump orphans several GB
    PERMANENTLY (and CLAUDE.md's recreate rule exists precisely to stop gratuitous bumps).
    A guard that cries wolf on documentation edits also trains people to bypass it, which
    is how the real case — a changed Dockerfile under an unchanged tag — gets waved through.

    The cluster TLD is normalised away for the same reason, and it matters more: a recreate
    rewrites `registry.gitlab.<tld>` across every build input via
    updateConfigFromProjectSettings.sh. That is a hostname, not image content — the built
    image is byte-identical — and CLAUDE.md's recreate rule says explicitly NOT to bump
    IMAGE_TAG then, because that is exactly when the archive must still match. Without this
    normalisation the guard fires on every single recreate and demands the one bump the
    rule forbids.

    Both TLD shapes fold to the same token: the cluster label is optional (an empty
    general.subdomain puts the host at `registry.gitlab.<domain>`), and the domain itself is
    read from project_settings.ts, so changing either reads as no change.
    """
    text = re.sub(r"(?:[A-Za-z-]+\d+\.)?" + re.escape(BASE_DOMAIN), "CLUSTER-TLD", text)
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        out.append(s)
    return "\n".join(out)


def content_changed(path):
    """True if the staged version differs from HEAD in build-significant content."""
    head = subprocess.run(["git", "-C", root, "show", f"HEAD:{path}"],
                          capture_output=True, text=True)
    if head.returncode:          # new file — always significant
        return True
    staged_blob = subprocess.run(["git", "-C", root, "show", f":{path}"],
                                 capture_output=True, text=True)
    if staged_blob.returncode:
        return True
    return strip_noise(head.stdout) != strip_noise(staged_blob.stdout)


# The CI build image is the same shape of problem in its own app: its Dockerfile is the
# only build input, and its IMAGE_TAG is both the archive-free cache key AND the pin six
# consumers carry. A renovate bump of the FROM line without a tag bump would leave one tag
# naming two different images, exactly as commit 55029d99 did for the desktop base.
cbi_input = "deployment/argocd-apps/ci-build-image/Dockerfile"
if cbi_input in staged and content_changed(cbi_input):
    diff = subprocess.run(
        ["git", "-C", root, "diff", "--cached", "--unified=0", "--",
         "deployment/argocd-apps/ci-build-image/.gitlab-ci.yml"],
        capture_output=True, text=True).stdout
    if re.search(r"^\+\s*IMAGE_TAG:", diff, re.M) is None:
        fail.append(
            "deployment/argocd-apps/ci-build-image/Dockerfile is staged but IMAGE_TAG in "
            "ci-build-image/.gitlab-ci.yml is unchanged — the same tag would name two "
            "different CI build images, and every consumer pins it")

# eda-pcb-agent is the same shape again, and was UNGUARDED until 2026-09-14 — found while
# bumping its base to 26.04 and adding the KiCad PPA, i.e. exactly the change that would have
# shipped silently. It builds its OWN image (FROM ubuntu, not the shared desktop base), so
# nothing above covers it.
#
# ⚠ IT HAS TWO PLACES TO KEEP IN STEP, not one: the tag in its .gitlab-ci.yml AND the pin its
# Deployment carries. Bumping only the CI tag builds an image nothing runs; bumping only the
# Deployment pulls a tag CI never built. Both are checked.
pcb_input = "deployment/argocd-apps/eda-pcb-agent/Dockerfile"
if pcb_input in staged and content_changed(pcb_input):
    ci_diff = subprocess.run(
        ["git", "-C", root, "diff", "--cached", "--unified=0", "--",
         "deployment/argocd-apps/eda-pcb-agent/.gitlab-ci.yml"],
        capture_output=True, text=True).stdout
    if re.search(r"^\+\s*IMAGE_TAG:", ci_diff, re.M) is None:
        fail.append(
            "deployment/argocd-apps/eda-pcb-agent/Dockerfile is staged but IMAGE_TAG in "
            "eda-pcb-agent/.gitlab-ci.yml is unchanged — the recover-or-rebuild gate would "
            "restore the OLD image and the Dockerfile change would silently do nothing")
    dep_diff = subprocess.run(
        ["git", "-C", root, "diff", "--cached", "--unified=0", "--",
         "deployment/argocd-apps/eda-pcb-agent/deployment.yaml"],
        capture_output=True, text=True).stdout
    if re.search(r"^\+.*eda-pcb-agent:", dep_diff, re.M) is None:
        fail.append(
            "deployment/argocd-apps/eda-pcb-agent/Dockerfile is staged but the image pin in "
            "eda-pcb-agent/deployment.yaml is unchanged — the pod would keep pulling the "
            "previous tag, so a rebuilt image would never reach it")

touched = [p for p in staged if p in inputs and content_changed(p)]
if touched:
    # Did IMAGE_TAG itself change in the staged diff?
    diff = subprocess.run(
        ["git", "-C", root, "diff", "--cached", "--unified=0", "--",
         "deployment/argocd-apps/remote-desktop/ci-base.yml"],
        capture_output=True, text=True).stdout
    bumped = re.search(r"^\+\s*IMAGE_TAG:", diff, re.M) is not None
    if not bumped:
        fail.append(
            "build inputs are staged (" + ", ".join(sorted(touched)) + ") but IMAGE_TAG in "
            "ci-base.yml is unchanged — the same tag would name two different images, and "
            "the archive would restore the WRONG one on every future recreate")

if fail:
    print("\nImage-invariant check FAILED:", file=sys.stderr)
    for x in fail:
        print("  - " + x, file=sys.stderr)
    sys.exit(1)
print(f"ok: CA-before-gate in {checked_ca} CI file(s); IMAGE_TAG consistent "
      f"({sorted(distinct)[0] if distinct else 'n/a'}) across {len(tags)} site(s); "
      f"CI build image pinned at {cbi_tag or 'n/a'} in {sum(len(v) for v in pins.values())} place(s)")
PY
