#!/bin/bash
# remote-desktop module broker — the privilege boundary.
#
# Runs as a PRIVILEGED sidecar in the desktop pod. The desktop container (where
# unprivileged LDAP users have shells) does NOT run privileged and cannot pull
# images or write the cache — it can only DROP A REQUEST (a filename under the
# shared request dir). Only a module NAME crosses the boundary; this loop validates its
# shape (regex) and that it is registered on the module share, then does the privileged
# work:
#   validate the name → confirm it is registered on the module share → publish its
#   module.yaml + the READY marker into the shared emptyDir.
#
# ⚠ The broker does NOT pull, unpack or run the image. Every module is
# `runtime: container`: the DESKTOP's podman pulls and runs it at launch (via
# module-podmand, the root helper there), because the image must land in that container's
# store to be runnable. What crosses the boundary from here is metadata only.
#
# Mounts (see desktop-gvisor.yaml):
#   /run/module-requests   emptyDir, shared, mode 0733 (users write, can't enumerate)
#   /modules               shared emptyDir — the broker publishes module.yaml and the
#                          READY marker here (plain FILES, which DO cross the sandbox
#                          boundary). No mounts land here.
#   /registry/modules/<name>/<version>/module.yaml  the module REGISTRY: a module exists
#                          and is permitted iff its manifest is here. No separate
#                          allowlist. Its own TrueNAS dataset+export, mounted ONLY here
#                          (never in the desktop container, never in the [eda] runner), so
#                          write access to it IS the security boundary — see allowed().
#   /var/run/registry-cred/.dockerconfigjson  skopeo --authfile (remote-desktop-registry-cred)
set -u

REQ_DIR=/run/module-requests
MOUNT_ROOT=/modules
# Node-local scratch: per-module flock files and the temp dirs used when a manifest has to
# be read out of an image. No module payload is stored here any more.
LOCAL_CACHE=/var/lib/modules
# The module registry lives on its own TrueNAS NFS export (see nfs-eda-modulefiles-pv.yaml).
# Overridable so a test pod can point at a scratch copy.
REGISTRY_ROOT="${MODULE_REGISTRY_ROOT:-/registry}"
MODULE_STORE="$REGISTRY_ROOT/modules"   # <name>/<version>/module.yaml == allowed
AUTHFILE=/var/run/registry-cred/.dockerconfigjson
REGISTRY="${REGISTRY_HOST:?REGISTRY_HOST must be set}"
IMAGE_BASE="${IMAGE_BASE:-deployments/infrastructure/eda/modules}"  # <registry>/<IMAGE_BASE>/<name>:<version>
TLS_VERIFY="${REGISTRY_TLS_VERIFY:-false}"
# image-registry serves TLS from a PRIVATE in-cluster CA, so verification needs that CA
# explicitly. --cert-dir takes a plain directory of *.crt (NOT an OpenSSL hash dir), which
# is what the image-registry-ca ConfigMap mount provides.
#
# ⚠ THE TEST IS "does it CONTAIN a .crt", NOT "does the directory exist". The ConfigMap
# volume is optional:true, so when the ConfigMap is missing the kubelet still creates an
# EMPTY directory — and a -d test passes on it. skopeo was then given --cert-dir pointing
# at nothing and failed every pull with `x509: certificate signed by unknown authority`,
# which reads as a trust problem in the CA rather than an absent one. Measured 2026-09-04
# on ecc196, where it stalled an EDA module registration for 45 minutes.
# Falling back to the system trust store here does NOT hide a real failure: it surfaces the
# honest error instead of a misleading one, and the desktop must still start before the CA
# has ever been distributed.
CERT_DIR="${REGISTRY_CERT_DIR:-}"
CERT_DIR_FLAG=""
if [ -n "$CERT_DIR" ] && ls "$CERT_DIR"/*.crt >/dev/null 2>&1; then
  CERT_DIR_FLAG="--cert-dir=$CERT_DIR"
else
  [ -n "$CERT_DIR" ] && log "WARNING: REGISTRY_CERT_DIR=$CERT_DIR holds no *.crt — TLS verification will use the system trust store only"
fi

mkdir -p "$REQ_DIR" "$MOUNT_ROOT" "$MOUNT_ROOT/.ready" "$LOCAL_CACHE" "$LOCAL_CACHE/.locks"
chmod 0733 "$REQ_DIR"

# ⚠ STDERR, NOT STDOUT. module_image() both LOGS (the tag-pinning warning) and RETURNS
# its value on stdout, and its callers capture that value with $(...). A log line on
# stdout is therefore captured AS the image reference: skopeo gets handed the warning
# text instead of a docker:// URL and fails. Measured 2026-09-04 on ecc196 — this made
# `broker digest` return "-" for a module whose image was present and pullable, which
# stalled an EDA register hook for an hour and read as a CA fault.
log() { echo "[broker $(date -u +%H:%M:%S)] $*" >&2; }

# module_image <name> <ver> — the registry ref for a module.
#
# Defaults to <IMAGE_BASE>/<name>:<ver>. An optional `image:` key in the REGISTERED manifest
# overrides the REPO PATH (the version is still appended), so two apps can publish the same
# module NAME from separate GitLab projects while both stay one `module load <name>/<ver>`
# for the user.
#
# Parsed with sed, not a YAML parser: this runs on the hot path and the key is a flat
# top-level scalar.
# module_repo <name> <ver> — the REPO PATH for a module, with no tag and no digest.
# Split out of module_image() so `broker digest` can build a TAG ref: that caller must be
# able to see a rebuild, which a digest-pinned ref can never show it (see the note there).
module_repo() {
  local name="$1" ver="$2" repo
  local man="$MODULE_STORE/${name}/${ver}/module.yaml"
  repo=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$man" 2>/dev/null \
         | tr -d '"'"'"' \r' | head -1)
  case "$repo" in
    ""|*..*|/*) repo="${IMAGE_BASE}/${name}" ;;
  esac
  printf '%s' "$repo"
}

module_image() {
  local name="$1" ver="$2" repo dig
  local man="$MODULE_STORE/${name}/${ver}/module.yaml"
  repo=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$man" 2>/dev/null \
         | tr -d '"'"'"' \r' | head -1)
  # The manifest is operator-supplied, but it still builds a URL — refuse traversal and
  # absolute paths rather than trusting it.
  case "$repo" in
    ""|*..*|/*) repo="${IMAGE_BASE}/${name}" ;;
  esac

  # ⚠ PIN BY DIGEST WHEN THE MANIFEST CARRIES ONE. Registering a module authorises the
  # broker to run an image AS ROOT, and `allowed()` only asserts that
  # <name>/<version>/module.yaml exists — it never looks at the image. With a tag ref, the
  # thing that actually runs is whatever `:<version>` points at TODAY, so anyone able to
  # overwrite that tag chooses what runs as root, without touching the module store at all.
  # A digest ref removes that: the bytes are named, not the label.
  #
  # ⚠ STRICT FORMAT CHECK, NOT A TRIM. This value goes straight into a registry URL, and
  # the manifest is operator-supplied like `image:` above. Anything that is not exactly
  # sha256 + 64 hex is discarded rather than passed through.
  dig=$(sed -n 's/^[[:space:]]*digest:[[:space:]]*//p' "$man" 2>/dev/null \
        | tr -d '"'"'"' \r' | head -1)
  # ⚠ EXACT LENGTH AND CHARSET, CHECKED SEPARATELY. A `case` glob spelling out 64
  # [0-9a-f] groups is unreadable AND was written with the wrong repeat count on the first
  # attempt — it silently rejected every valid digest and fell through to the tag, i.e. it
  # disabled the pinning it was added to perform, while the warning made it look
  # intentional. Length and charset as two explicit tests cannot go wrong that quietly.
  local hex=""
  case "$dig" in sha256:*) hex="${dig#sha256:}" ;; esac
  if [ "${#hex}" -eq 64 ] && [ -z "$(printf '%s' "$hex" | tr -d '0-9a-f')" ]; then
    printf 'docker://%s/%s@%s' "$REGISTRY" "$repo" "$dig"
    return 0
  fi

  # No usable digest: fall back to the tag so an already-registered module keeps loading,
  # but say so every time. This is a REAL gap, not a formality — re-register the module to
  # close it (`broker register` records the digest).
  log "WARNING: ${name}/${ver} is pinned by TAG, not digest — whoever can overwrite" \
      "${repo}:${ver} controls what runs as root here. Re-register to pin it."
  printf 'docker://%s/%s:%s' "$REGISTRY" "$repo" "$ver"
}

# NOTE: no /dev/fuse handling here. The broker mounts nothing (see the header).

# Only create the module store INSIDE a real mount. Creating it while $REGISTRY_ROOT is
# unmounted would leave an empty local dir that looks like a valid (but empty) registry.
if mountpoint -q "$REGISTRY_ROOT"; then
  mkdir -p "$MODULE_STORE"
else
  log "WARNING: $REGISTRY_ROOT is not mounted — no modules can be loaded until it is"
fi

# --- registry creds: parse "user:pass" from the dockerconfigjson for the registry
# host, and pass via skopeo --creds. (--authfile is unreliable here: our
# dockerconfigjson has username/password but no base64 `auth` field, which skopeo's
# authfile parser expects; --creds always works. Verified.)
CREDS=""
export AUTHFILE
if [ -f "$AUTHFILE" ]; then
  CREDS=$(REG="$REGISTRY" python3 -c '
import json,os
d=json.load(open(os.environ["AUTHFILE"]))["auths"]
h=os.environ["REG"]
e=d.get(h) or (list(d.values())[0] if d else {})
u=e.get("username"); p=e.get("password")
if not (u and p) and e.get("auth"):
    import base64; u,p=base64.b64decode(e["auth"]).decode().split(":",1)
print(f"{u}:{p}" if u and p else "")
' 2>/dev/null)
fi
[ -n "$CREDS" ] || log "WARNING: no registry creds parsed from $AUTHFILE"

# --- status back to the user: a per-request status file the caller polls ---
status() {  # $1=reqfile $2=state $3=msg
  echo "$2 $3" > "$REQ_DIR/.status.$(basename "$1")" 2>/dev/null || true
}

# allowed <name> <version> — the module REGISTRY is the authority.
#
# A module is permitted iff it is registered in the store the broker mounts at
# $MODULE_STORE, i.e. $MODULE_STORE/<name>/<version>/module.yaml exists. Registering a
# module = writing its manifest there; there is no separate allowlist to maintain.
#
# TRUST MODEL: whoever can write the registry can make this broker pull and run an image as
# root. The export is mounted ONLY into this privileged broker — never into the desktop
# container where unprivileged users have shells, and never into the [eda] GitLab runner —
# so a desktop user cannot register a module from inside the pod. WHICH PODS MOUNT IT is
# the security boundary: the export itself is rw to the lab LAN and cannot be narrower
# (broker and runner share a node, so NFS cannot tell them apart by source IP).
#
# FAIL-CLOSED: if the registry is missing/unmounted/unreadable, every load is rejected.
# An unreachable registry must never widen access.
allowed() {
  local name="$1" ver="$2"
  if [ ! -d "$MODULE_STORE" ]; then
    log "DENY: module share $MODULE_STORE is not present — failing closed"
    return 1
  fi
  # A mounted-but-empty dir is indistinguishable from an unmounted one by content
  # alone; readability is what we can actually assert.
  if [ ! -r "$MODULE_STORE" ] || [ ! -x "$MODULE_STORE" ]; then
    log "DENY: module share $MODULE_STORE unreadable — failing closed"
    return 1
  fi
  [ -f "$MODULE_STORE/${name}/${ver}/module.yaml" ]
}

# extract_module_yaml <ocidir>  — print the image's /module.yaml to stdout without a
# full rootfs unpack. Walks the layer tars newest-last (later layers win) and pulls the
# last-seen module.yaml.
#
# PERFORMANCE: module.yaml sits at the image ROOT, so it appears within the first few
# entries of the layer tar. A single `tar -xO` that STOPS at the first match is therefore
# near-instant, whereas scanning the whole member list is not: these layers are gzipped
# and Vivado's is ~30 GB, so a full pass costs many minutes of pure gzip -d per layer.
# The original version did that TWICE per layer (`tar -tf` to test, then `tar -xOf` to
# read) and wedged a vivado load for ~50 min at 91% CPU in gzip.
# `--occurrence=1` makes GNU tar exit after the first match instead of reading to EOF.
extract_module_yaml() {
  local ocidir="$1" l out="" got=""
  for l in $(skopeo inspect --authfile "$AUTHFILE" --raw "oci:${ocidir}:latest" 2>/dev/null \
             | python3 -c 'import sys,json;[print(x["digest"].split(":")[1]) for x in json.load(sys.stdin).get("layers",[])]' 2>/dev/null); do
    local blob="$ocidir/blobs/sha256/$l"
    [ -f "$blob" ] || continue
    # Try both spellings; --occurrence=1 stops the read at the first hit.
    got=$(tar -xO --occurrence=1 -f "$blob" ./module.yaml 2>/dev/null) \
      || got=$(tar -xO --occurrence=1 -f "$blob" module.yaml 2>/dev/null) || got=""
    [ -n "$got" ] && out="$got"
  done
  printf '%s' "$out"
}

# ── NO container-image archive, deliberately ────────────────────────────────────
# Do NOT re-introduce a `docker-archive` tar of each module image on the artifacts export.
# The lab-local registry's blob store is its own TrueNAS dataset (datapool/images) and
# survives a cluster recreate exactly as such a tar would — the tar is a SECOND copy of the
# same layers, ~190 GB for three modules. Its one claimed advantage is format independence
# (restores with no registry, CA or credential), but this sidecar cannot use it: it holds a
# PULL-ONLY deploy token, so every push back is rejected at the first blob.
#
# WHAT RESTORES: the registry blob store for a normal `module load`, and failing that the
# app's own CI pipeline, which rebuilds from the installer media that stays on the artifacts
# export. That is hours per module — accepted, and the reason the media is never deleted.
#
# ⚠ CONSEQUENCE: this sidecar does not mount /artifacts at all. Do not add it without a
# reason; it would also give the broker write access to the vendor media tree.


# ── MODULE DISCOVERY: two advisory candidate sources, one authoritative stat ────
# Nothing here decides what may run — allowed() does, by statting the share, and it is
# unchanged. This only decides what `module avail` LISTS.
#
# ⚠ DO NOT MAKE readdir THE ONLY SOURCE. It was, and the failure is measured: a network
# mount can serve a stale directory listing for minutes after a register/unregister/mv,
# so a module was registered, `allowed` said ALLOWED, and `module avail` did not list it
# until the pod restarted. Statting a path the listing hides does NOT repopulate it, so
# no amount of re-checking recovers from that.
#
# ⚠ AND DO NOT GO BACK TO A HARD-CODED LIST. That was the previous fix and it cost a
# module: every new module had to be added to a literal in this file, which lives in the
# desktop BASE IMAGE — so adding one module meant an IMAGE_TAG bump and a desktop restart,
# and forgetting it left the module loadable-but-undiscoverable with nothing to point at.
#
# So take the UNION of two sources that fail in opposite directions, and let the stat
# decide:
#   1. $CATALOG_FILE — written by `broker register` / `broker unregister` below, i.e. by
#      the only operations that can make a module loadable at all. Immune to the listing
#      cache (it is a file read, and this pod is the writer), and it survives a restart.
#   2. a readdir of the store — self-maintaining, and the fallback that makes a module
#      registered by some other route (or before the catalog file existed) visible. It may
#      LAG; it cannot invent an entry that the stat below then rejects.
# Neither source can hide what the other sees, and a phantom in either is dropped by the
# stat. A module still LOADS by exact name whether or not it is listed here.
CATALOG_FILE="$MODULE_STORE/.catalog"

# One `<name>/<version>` per line, validated to the same shape process() accepts so a
# hand-edited catalog line can never become a path traversal.
module_candidates() {
  {
    [ -f "$CATALOG_FILE" ] && cat "$CATALOG_FILE"
    find "$MODULE_STORE" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null
  } | grep -E '^[a-z0-9][a-z0-9._-]*/[A-Za-z0-9._-]+$' | sort -u
}

# catalog_add / catalog_del keep source 1 in step with reality. tmp+mv so a concurrent
# reader never sees a half-written file; failures are non-fatal because source 2 still
# covers discovery and the stat still covers correctness.
# ⚠ THE TEMP NAME CARRIES $$ AND MUST. With a fixed name, `mv` failed with
# "cannot stat '.../.catalog.tmp': No such file or directory" on a file the same function
# had just written (measured on the ecc199 register hook) — the same stale-lookup caching
# on this NFS mount that makes a plain readdir unusable for discovery. A name no lookup has
# seen before cannot have a cached negative entry.
catalog_add() {
  local spec="$1" tmp="$MODULE_STORE/.catalog.$$.tmp"
  { [ -f "$CATALOG_FILE" ] && cat "$CATALOG_FILE"; printf '%s\n' "$spec"; } \
    | grep -E '^[a-z0-9][a-z0-9._-]*/[A-Za-z0-9._-]+$' | sort -u > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$CATALOG_FILE" || rm -f "$tmp"
}
catalog_del() {
  local spec="$1" tmp="$MODULE_STORE/.catalog.$$.tmp"
  [ -f "$CATALOG_FILE" ] || return 0
  grep -vxF "$spec" "$CATALOG_FILE" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$CATALOG_FILE" || rm -f "$tmp"
}

# registered_modules — print every candidate that is actually registered, one per line.
# The stat is the same cache-immune test allowed() uses, so this cannot report a module
# that would then refuse to load. Used by publish_index and list-modules so both agree.
registered_modules() {
  local spec
  module_candidates | while IFS= read -r spec; do
    [ -f "$MODULE_STORE/$spec/module.yaml" ] && printf '%s\n' "$spec"
  done
}


process() {  # $1 = request file holding a single "name/version" line
  local reqf="$1" spec name ver img lockf
  spec=$(head -1 "$reqf" 2>/dev/null | tr -d ' \r\n')
  rm -f "$reqf"
  # Validate shape: <name>/<version>. SECURITY: spec comes from an unprivileged user and
  # is used to build filesystem paths below, so this must run BEFORE any path is formed.
  # Neither component may contain "/", and "." / ".." are rejected outright — "foo/.."
  # matches the character class but would resolve to the parent directory.
  if ! printf '%s' "$spec" | grep -qE '^[a-z0-9][a-z0-9._-]*/[a-zA-Z0-9._-]+$'; then
    log "REJECT bad spec: '$spec'"; status "$reqf" ERROR "invalid module spec"; return
  fi
  name="${spec%%/*}"; ver="${spec##*/}"
  case "$name" in .|..) name="" ;; esac
  case "$ver" in .|..) ver="" ;; esac
  if [ -z "$name" ] || [ -z "$ver" ]; then
    log "REJECT bad spec: '$spec'"; status "$reqf" ERROR "invalid module spec"; return
  fi
  if ! allowed "$name" "$ver"; then
    log "REJECT not registered on the module share: '$spec'"
    status "$reqf" ERROR "module not available"; return
  fi
  # Safe to consult the manifest here: allowed() above already required it to exist.
  img=$(module_image "$name" "$ver")
  lockf="$LOCAL_CACHE/.locks/${name}-${ver}"

  # Already prepared? fast path — the .ready marker PLUS a manifest that still matches the
  # share. Anything stricter (a `skopeo inspect`) would put a registry round-trip on every
  # `module load`; `cmp` on two small local files costs nothing.
  #
  # ⚠ THE MANIFEST COMPARISON IS LOAD-BEARING, do not reduce this back to the marker alone.
  # Re-registering a module (`broker register`, or the app's PostSync register Job after a
  # rebuild) rewrites the manifest on the share — a new `digest:` pin, or new entries. The
  # marker does not change, so a marker-only fast path serves the OLD published manifest
  # forever and every desktop keeps launching the OLD digest. Measured 2026-09-15: hyperlynx
  # was rebuilt and re-pinned to a fixed image, and both desktops went on running the broken
  # one because they were already prepared. It reads as "the fix did not work" rather than as
  # a staleness bug, because the registry, the tag and the share all look correct.
  if [ -f "$MOUNT_ROOT/.ready/${name}-${ver}" ] \
     && cmp -s "$MODULE_STORE/${name}/${ver}/module.yaml" "$MOUNT_ROOT/${name}/${ver}.module.yaml"; then
    status "$reqf" READY "already prepared"; return
  fi

  # Serialize per module/version: two users requesting the same one → 2nd waits,
  # then finds it ready.
  exec 9>"$lockf"
  if ! flock -w 3600 9; then log "lock timeout $spec"; status "$reqf" ERROR "busy"; return; fi

  # Re-check after acquiring the lock (another holder may have finished).
  # ⚠ SAME MANIFEST COMPARISON AS THE FAST PATH ABOVE, and for the same reason — this is a
  # SECOND marker-only gate, and guarding only the first one fixes nothing: the first falls
  # through on a stale manifest and then THIS one returns "prepared" anyway. Measured
  # 2026-09-17: after a rebuild + re-register the broker answered READY prepared while still
  # serving the previous digest, with `cmp` correctly reporting the two files as different.
  if [ -f "$MOUNT_ROOT/.ready/${name}-${ver}" ] \
     && cmp -s "$MODULE_STORE/${name}/${ver}/module.yaml" "$MOUNT_ROOT/${name}/${ver}.module.yaml"; then
    status "$reqf" READY "prepared"; flock -u 9; return
  fi

  status "$reqf" WORKING "fetching ${spec}"
  mkdir -p "$MODULE_STORE/${name}" "$LOCAL_CACHE/${name}" "$MOUNT_ROOT/${name}"

  # Publish the manifest and mark the module ready. Nothing is unpacked or mounted here:
  # the desktop's podman pulls and runs the image itself at launch, with the same
  # registry credential. See doc/nested-container-runtime.md.
  #
  # The REGISTERED manifest on the share is the same file that is baked into the image
  # (register-module.sh copies it out), so read it from there — no pull required. That
  # matters: pulling a multi-GB image merely to read one small YAML would double the cost
  # of every load. Fall back to reading it out of the image only if the share entry is
  # missing or unreadable.
  #
  # ocidir MUST be initialised, not just declared: `local ocidir` leaves it UNSET, and the
  # `[ -n "$ocidir" ]` cleanup below then aborts the whole broker under `set -u`
  # ("ocidir: unbound variable") on the normal path where the share manifest exists and the
  # fallback branch never runs. That killed the loop mid-prepare, so the module never got
  # its .ready marker and `module load` failed with a bare Lmod "not found".
  local ocidir="" myaml shared_yaml
  shared_yaml="$MODULE_STORE/${name}/${ver}/module.yaml"
  myaml=$(cat "$shared_yaml" 2>/dev/null)
  if [ -z "$myaml" ]; then
    ocidir=$(mktemp -d "$LOCAL_CACHE/.oci.XXXXXX")
    if ! skopeo copy ${CERT_DIR_FLAG:+$CERT_DIR_FLAG} --src-tls-verify="$TLS_VERIFY" --src-creds "$CREDS" \
         "$img" "oci:${ocidir}/oci:latest" >>/tmp/broker.log 2>&1; then
      log "ERROR skopeo copy failed for $img"; status "$reqf" ERROR "pull failed"
      rm -rf "$ocidir"; flock -u 9; return
    fi
    myaml=$(extract_module_yaml "$ocidir/oci")
    rm -rf "$ocidir"; ocidir=""
  fi
  if [ -z "$myaml" ]; then
    log "ERROR no module.yaml on the share or in the image for $spec"
    status "$reqf" ERROR "manifest missing"; flock -u 9; return
  fi

  # FAIL CLOSED on anything but `runtime: container`. There is no other runtime: the
  # native one (squashfuse-mounted .sqsh trees driven by Lmod) is gone, and gVisor — the
  # only nested runtime — cannot serve a squashfs mount at all (reads return ENOSYS). A
  # manifest asking for one must therefore say so HERE, where the request has a status
  # file to fail into. Publishing it instead produced a module that prepared cleanly and
  # then had no way to run: module-cli found no container image to launch and Lmod found
  # no modulefile, so `module load` ended in a bare "not found".
  if ! printf '%s\n' "$myaml" | grep -qE '^[[:space:]]*runtime:[[:space:]]*"?container"?[[:space:]]*$'; then
    log "ERROR $spec: manifest is not 'runtime: container' — no other runtime is served"
    status "$reqf" ERROR "unsupported runtime (only 'container' is served)"
    flock -u 9; return
  fi

  # The manifest lives NEXT TO the module dir, not inside it, so the CLI has one lookup
  # path. The dir itself is created (empty) because the CLI expects it to exist.
  mkdir -p "$MOUNT_ROOT/${name}/${ver}"
  printf '%s\n' "$myaml" > "$MOUNT_ROOT/${name}/${ver}.module.yaml"

  # Verify the desktop's podman will actually be able to pull it — a cheap manifest
  # inspect with the same credential, not a full pull, so a missing image fails here with
  # a clear message instead of at first launch.
  if ! skopeo inspect ${CERT_DIR_FLAG:+$CERT_DIR_FLAG} --tls-verify="$TLS_VERIFY" --creds "$CREDS" "$img" >>/tmp/broker.log 2>&1; then
    # The registry has no copy, and there is no archive to fall back to (see the header):
    # the ONLY repair is to run the app's CI pipeline, which rebuilds the image from the
    # installer media on the artifacts export and pushes it.
    log "ERROR $spec: image $img is not in the registry and there is no archive."
    log "      Repair: run the app's GitLab pipeline to rebuild it from installer media."
  fi

  mkdir -p "$MOUNT_ROOT/.ready"; touch "$MOUNT_ROOT/.ready/${name}-${ver}"
  status "$reqf" READY "loaded (container)"
  log "READY $spec (container)"
  flock -u 9
}

# ── Admin subcommands ───────────────────────────────────────────────────────────
# Registering a module = writing its manifest to the share (see allowed()). These run
# in THIS container because it is the only one that mounts the share. Driven from the
# devcontainer by register-module.sh; not reachable by desktop users.
case "${1:-}" in
  archive|archive-async|restore)
    # Retired together with the image archives (see the header). These copied a module
    # image to/from a docker-archive tar on the artifacts export. `restore` could never
    # work: this sidecar holds a pull-only deploy token, so every push is rejected at the
    # first blob.
    #
    # The registry blob store is now the only copy, and it survives a recreate on its own
    # dataset. If an image is genuinely missing, run the app's GitLab pipeline: it rebuilds
    # from the installer media that stays on the artifacts export.
    echo "broker: '$1' is retired — container images are not archived." >&2
    echo "  The registry blob store (datapool/images) is the only copy and survives a" >&2
    echo "  recreate. To recover a missing image, run that module's GitLab pipeline." >&2
    exit 2
    ;;
  digest)
    # broker digest <name> <version> — print "<share-digest> <registry-digest>".
    # Either field is "-" when unknown. Exists so callers (the ArgoCD build trigger) can ask
    # "does the share hold THIS image?" without needing the registry credential or reproducing
    # the module_image/`image:` resolution — both live in here, and embedding a skopeo call
    # with nested quoting inside a `kubectl exec … sh -c` is a reliable source of silent
    # failures. Read-only and cheap.
    dname="${2:?usage: broker digest <name> <version>}"
    dver="${3:?usage: broker digest <name> <version>}"
    case "$dname" in .|..|*/*) echo "invalid name" >&2; exit 2 ;; esac
    case "$dver"  in .|..|*/*) echo "invalid version" >&2; exit 2 ;; esac
    # ⚠ THE FIRST FIELD IS ALWAYS "-". It would carry the digest of the image's
    # docker-archive on the artifacts export; there are no archives (see the header), so
    # there is nothing to report. The field is KEPT rather than dropped because
    # the ArgoCD build triggers parse two whitespace-separated values — emitting one would
    # shift the registry digest into the wrong variable and silently misreport every module.
    # ⚠ INSPECT THE TAG, NOT module_image(). module_image() returns the ref from the
    # REGISTERED manifest, which is digest-pinned — so inspecting it asks the registry
    # "what is the digest of <this exact digest>" and gets that same digest back. The
    # answer is then true by construction and a REBUILD IS INVISIBLE: the tag can move
    # and this still reports the old value forever.
    #
    # That is not theoretical. Measured 2026-09-21: after a successful rebuild moved the
    # tag to bed4596c, this kept returning the pinned a6fdd82a, and the register hook —
    # whose whole job is to notice the new image — accepted it and reported
    # "Registered and verified ... (digest-pinned)" over an image built before the fix.
    # Callers ask this to learn whether the registry has something NEW, so it must read
    # the mutable tag; the pin is what they compare it against.
    dreg=$(skopeo inspect ${CERT_DIR_FLAG:+$CERT_DIR_FLAG} --tls-verify="$TLS_VERIFY" --creds "$CREDS" --format '{{.Digest}}' \
             "docker://${REGISTRY}/$(module_repo "$dname" "$dver"):${dver}" 2>/dev/null | tr -d ' \r\n')
    echo "- ${dreg:--}"
    exit 0
    ;;
  list-modules)
    # Stats every candidate (see module_candidates) instead of trusting a directory
    # listing: a network mount can serve the PRE-CHANGE listing for minutes after a
    # register/unregister/mv, so a readdir alone can hide a module that is ALLOWED and
    # ready to load. The catalog file the register path maintains is the source that
    # cannot be hidden that way; the stat is what makes either source safe to trust.
    registered_modules
    exit 0
    ;;
  # allowed <name> <version> — the AUTHORITATIVE "is this loadable?" check, and the one to
  # trust when list-modules disagrees (see the cache note above). Same test the load path
  # uses, so it cannot drift from it.
  allowed)
    aname="${2:?usage: broker allowed <name> <version>}"
    aver="${3:?usage: broker allowed <name> <version>}"
    if allowed "$aname" "$aver"; then
      echo "ALLOWED $aname/$aver"; exit 0
    fi
    echo "NOT REGISTERED $aname/$aver" >&2; exit 1
    ;;
  register)
    rname="${2:?usage: broker register <name> <version> [--from-stdin]}"
    rver="${3:?usage: broker register <name> <version> [--from-stdin]}"
    case "$rname" in .|..|*/*) echo "invalid name" >&2; exit 2 ;; esac
    case "$rver"  in .|..|*/*) echo "invalid version" >&2; exit 2 ;; esac
    mountpoint -q "$REGISTRY_ROOT" || { echo "ERROR: $REGISTRY_ROOT not mounted" >&2; exit 1; }
    if [ "${4:-}" = "--from-stdin" ]; then
      rman=$(cat)
    else
      # Default: take the manifest from the module image itself (source of truth).
      #
      # This deliberately does NOT use module_image(): that reads the `image:` key out of the
      # REGISTERED manifest, which is precisely what we are about to create — a module whose
      # image lives outside the default repo cannot be discovered by pulling it. Register
      # those by passing the manifest explicitly instead:
      #   register-module.sh add <name> <ver> path/to/module.yaml   (-> --from-stdin)
      rtmp=$(mktemp -d "$LOCAL_CACHE/.reg.XXXXXX")
      if ! skopeo copy ${CERT_DIR_FLAG:+$CERT_DIR_FLAG} --src-tls-verify="$TLS_VERIFY" --src-creds "$CREDS" \
           "docker://${REGISTRY}/${IMAGE_BASE}/${rname}:${rver}" "oci:${rtmp}/oci:latest" >/dev/null 2>&1; then
        echo "ERROR: cannot pull ${IMAGE_BASE}/${rname}:${rver} from the registry." >&2
        echo "       If this module publishes to a non-default repo (an \`image:\` key in its" >&2
        echo "       module.yaml), pass the manifest explicitly:" >&2
        echo "         register-module.sh add ${rname} ${rver} <path/to/module.yaml>" >&2
        rm -rf "$rtmp"; exit 1
      fi
      rman=$(extract_module_yaml "$rtmp/oci")
      rm -rf "$rtmp"
    fi
    [ -n "$rman" ] || { echo "ERROR: no /module.yaml found in the image" >&2; exit 1; }

    # ⚠ RECORD THE DIGEST AT REGISTRATION. This is what lets module_image() pin the image
    # instead of trusting the tag, and registration is the only moment where "the image the
    # operator meant" is unambiguous. Resolve it from the SAME ref that will be loaded,
    # honouring an `image:` key in the manifest being registered — note module_image() reads
    # the STORED manifest, which does not exist yet, so the repo is derived here.
    rrepo=$(printf '%s\n' "$rman" | sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
            | tr -d '"'"'"' \r' | head -1)
    case "$rrepo" in ""|*..*|/*) rrepo="${IMAGE_BASE}/${rname}" ;; esac
    rdig=$(skopeo inspect ${CERT_DIR_FLAG:+$CERT_DIR_FLAG} --tls-verify="$TLS_VERIFY" \
             --creds "$CREDS" --format '{{.Digest}}' \
             "docker://${REGISTRY}/${rrepo}:${rver}" 2>/dev/null | tr -d ' \r\n')

    # Any pre-existing `digest:` is dropped before appending, so re-registering a rebuilt
    # tag repins rather than leaving a stale digest that would fail every pull.
    rman=$(printf '%s\n' "$rman" | sed '/^[[:space:]]*digest:[[:space:]]*/d')
    case "$rdig" in
      sha256:*)
        rman=$(printf '%s\ndigest: %s\n' "$rman" "$rdig")
        echo "Pinned ${rname}/${rver} to ${rdig}"
        ;;
      *)
        # ⚠ REGISTRATION STILL SUCCEEDS, DELIBERATELY. A registry blip during a recreate
        # must not leave modules unloadable — availability wins here, and the gap is made
        # loud instead of silent: module_image() warns on EVERY load until a re-register
        # pins it. Failing closed here would trade a visible warning for an outage.
        echo "WARNING: could not resolve a digest for ${rrepo}:${rver} — registering" >&2
        echo "         TAG-PINNED. Whoever can overwrite that tag controls what runs as" >&2
        echo "         root. Re-run this registration once the registry is reachable." >&2
        ;;
    esac

    mkdir -p "$MODULE_STORE/${rname}/${rver}"
    printf '%s\n' "$rman" > "$MODULE_STORE/${rname}/${rver}/module.yaml"
    # Record it for discovery. The manifest above is what makes the module LOADABLE; this
    # is only what makes `module avail` list it without depending on a directory listing
    # the mount may still be caching.
    catalog_add "${rname}/${rver}"
    echo "registered ${rname}/${rver}"
    exit 0
    ;;
  unregister)
    rname="${2:?usage: broker unregister <name> <version>}"
    rver="${3:?usage: broker unregister <name> <version>}"
    case "$rname" in .|..|*/*) echo "invalid name" >&2; exit 2 ;; esac
    case "$rver"  in .|..|*/*) echo "invalid version" >&2; exit 2 ;; esac
    rm -f "$MODULE_STORE/${rname}/${rver}/module.yaml"
    rmdir "$MODULE_STORE/${rname}/${rver}" 2>/dev/null || true
    catalog_del "${rname}/${rver}"
    echo "unregistered ${rname}/${rver}"
    exit 0
    ;;
esac

log "broker starting; registry=$REGISTRY base=$IMAGE_BASE watching $REQ_DIR"
# Give the CSI mount a moment to expose its contents before counting. The mount itself is
# already there (mountpoint -q above), but on a fresh pod the entries can lag briefly, and
# reporting "0 module(s) registered" reads like a broken share. Only affects this log line
# — allowed() re-checks the share on every request.
for _ in $(seq 1 10); do
  [ -n "$(ls -A "$MODULE_STORE" 2>/dev/null)" ] && break
  sleep 1
done
log "module share $MODULE_STORE: $(registered_modules | wc -l) of $(module_candidates | wc -l) candidate module(s) registered"

# Publish the REGISTRY INDEX into the shared dir so the desktop's `module avail` can list
# every registered module, not just the ones already prepared. The share is mounted only
# here, and no module has an Lmod modulefile, so without this index a module is
# undiscoverable from a user shell — you would have to already know its name.
publish_index() {
  local tmp="$MOUNT_ROOT/.registered.tmp"
  if registered_modules > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$MOUNT_ROOT/.registered"
  else
    rm -f "$tmp"
  fi
}
publish_index
# NB there is deliberately no cache-recovery pass at startup, and none is needed: a
# module's image lives in podman's own store, and a `module load` re-publishes the
# manifest from the share in milliseconds.

# Watch loop: inotify if available, else poll.
#
# process() runs in a SUBSHELL so a fatal error inside it (e.g. `set -u` on an unset var —
# this actually happened: an uninitialised `ocidir` aborted the broker mid-prepare) kills only
# that request, not the whole broker. A dead broker is silent and indistinguishable from a
# slow fetch: the module never gets its .ready marker and `module load` fails with a bare Lmod
# "not found". If the subshell dies without writing a status, say so and keep serving.
while true; do
  for reqf in "$REQ_DIR"/req.*; do
    [ -e "$reqf" ] || continue
    rname=$(basename "$reqf")
    ( process "$reqf" ) || true
    if [ ! -f "$REQ_DIR/.status.$rname" ]; then
      log "ERROR request $rname died without a status — reporting failure"
      echo "ERROR broker failed internally" > "$REQ_DIR/.status.$rname" 2>/dev/null || true
      rm -f "$reqf"
    fi
  done
  # Refresh the registry index so a module registered while we run becomes visible to
  # `module avail` without needing a pod restart.
  publish_index
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -t 30 -e create -e moved_to "$REQ_DIR" >/dev/null 2>&1 || true
  else
    sleep 3
  fi
done
