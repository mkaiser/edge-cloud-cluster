#!/bin/bash
# /usr/local/bin/module-podmand — root helper that PULLS container-module images into
# the shared root podman store on behalf of unprivileged LDAP users.
#
# WHY THIS EXISTS: container modules must use the shared ROOT store (graphroot
# /var/lib/containers/storage — the hostPath these pods mount). An LDAP user running
# bare `podman` gets a ROOTLESS store instead, which cannot work here:
#   - no /etc/subuid entry: LDAP users do not exist at image build time, and the base
#     image only ships ranges for its static `ubuntu`/`desktop` users, so the pull dies
#     with "no subuid ranges found for user".
#   - newuidmap/newgidmap are absent (no uidmap package).
#   - and even with both fixed, gVisor refuses the mapping outright:
#     "newuidmap: write to uid_map failed: Operation not permitted".
#
# WHY NOT sudo: setuid is not effective under gVisor — `sudo -n podman` fails with
# "effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option
# set?" even though the setuid bit is present and / is not nosuid. It DOES work under
# a VM-based runtime, but sudo is not usable under gVisor either.
#
# The pattern mirrors the broker's: a 0733 request dir that users can write into but not
# enumerate, a root loop that re-validates every request independently, and a status file
# the caller polls. Users never get a root shell and never name a path — only
# `<name>/<version>`, which is re-validated here before any path is built.
#
# RUNNING is delegated too, and it has to be: the image lands in the ROOT store
# (/var/lib/containers/storage) while an LDAP user's podman reads their own rootless
# graphroot (~/.local/share/containers/storage). A user therefore cannot even see the
# pulled image — `podman image exists` returns false and `podman run` would try to pull
# it again into the store it cannot write. Verified: after a successful root pull,
# `su testadmin -c 'podman image exists <img>'` still said no.
#
# The GUI still works because the run request carries the caller's DISPLAY, HOME and cwd,
# and the helper passes exactly those through to `podman run` (see do_run).
set -u

REQ_DIR=/run/module-pulls
AUTHFILE=/var/run/registry-cred/.dockerconfigjson

mkdir -p "$REQ_DIR"
chmod 0733 "$REQ_DIR"                  # users write requests, cannot enumerate

log() { echo "[module-podmand $(date -u +%H:%M:%S)] $*"; }

# su_xauth_ok <uid> <display> <outfile> — write a HOSTNAME-AGNOSTIC X cookie for <uid>.
#
# Runs `xauth` AS THE USER (their ~/.Xauthority is 0600 and only they can read it), extracts
# the entry for <display>, and rewrites its address family to the wildcard `ffff` so the
# cookie matches from inside a container, whose hostname differs from the pod's. Returns 1
# and writes nothing if the user has no entry for that display.
#
# ⚠ 0600 AND owned by the caller. This file is a bearer token for that user's whole X
# session; the desktop is multi-user, so a readable cookie in a shared dir would let any
# logged-in user take over another's display.
su_xauth_ok() {
  local uid="$1" disp="$2" out="$3" uname_
  uname_=$(getent passwd "$uid" | cut -d: -f1) || return 1
  [ -n "$uname_" ] || return 1
  rm -f "$out" 2>/dev/null || true
  # ⚠ xauth TAKES A LOCK next to its output file (`<file>-c`/`<file>-l`), so it must write
  # somewhere the USER can create files — not into our 0711 dir, where it fails with
  # `xauth: timeout in locking authority file` and produces nothing. Build it in the user's
  # own $HOME, then move it into place as root.
  local tmp_="\$HOME/.module-xauth.$$"
  # `sed 's/^..../ffff/'` swaps the 2-byte family field for the wildcard; nmerge writes it back.
  su - "$uname_" -c "rm -f $tmp_; xauth nlist '$disp' 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f $tmp_ nmerge - 2>/dev/null" || true
  local real_
  real_=$(su - "$uname_" -c "printf '%s' $tmp_" 2>/dev/null) || true
  if [ -n "$real_" ] && [ -s "$real_" ]; then
    mv -f "$real_" "$out" 2>/dev/null || cp -f "$real_" "$out" 2>/dev/null
    rm -f "$real_" "$real_-c" "$real_-l" 2>/dev/null || true
  fi
  [ -s "$out" ] || { rm -f "$out" 2>/dev/null || true; return 1; }
  chown "$uid" "$out" 2>/dev/null || true
  chmod 0600 "$out" 2>/dev/null || true
  return 0
}

status() {  # $1=reqbase $2=state $3=msg
  echo "$2 $3" > "$REQ_DIR/.status.$1" 2>/dev/null || true
  chmod 0644 "$REQ_DIR/.status.$1" 2>/dev/null || true
}

# Registry creds → a NORMALISED authfile, written once at startup.
#
# ⚠ NEVER `podman pull --creds user:password`. argv is world-readable in /proc, so on this
# multi-user LDAP desktop every logged-in user could read the image-registry password out of
# `ps` — a credential that is push-capable in CI and guards a store whose images the broker
# runs AS ROOT (see image-registry/README.md, which treats publish rights as root-execution
# rights). --authfile keeps it in a 0600 file owned by root instead.
#
# The mounted secret cannot be used directly: it carries username/password but no base64
# `auth` field, which podman's authfile parser requires — without it podman 403s even on
# readable repos (memory skopeo-authfile-needs-auth-field). So synthesise the field here.
RUNAUTH=/run/module-podmand-auth.json

write_authfile() {
  ( umask 0077
    python3 -c 'import base64,json,sys
d = json.load(open(sys.argv[1]))["auths"]
out = {}
for host, a in d.items():
    u, p = a.get("username", ""), a.get("password", "")
    e = dict(a)
    # Only synthesise it; never overwrite an `auth` the secret already carries.
    if "auth" not in e and u:
        e["auth"] = base64.b64encode(f"{u}:{p}".encode()).decode()
    out[host] = e
json.dump({"auths": out}, open(sys.argv[2], "w"))' "$AUTHFILE" "$RUNAUTH"
  ) 2>/dev/null || return 1
  chmod 0600 "$RUNAUTH" 2>/dev/null || true
}

do_pull() {  # $1 = request file holding a single image reference
  local reqf="$1" base img
  base=$(basename "$reqf")
  img=$(head -1 "$reqf" 2>/dev/null | tr -d ' \r\n')
  rm -f "$reqf"

  # Validate BEFORE using it. Only our own module registry path is pullable, so a
  # request cannot turn this into an arbitrary-image-pull primitive. Anchored, and no
  # shell metacharacters or traversal.
  case "$img" in
    *..*|*' '*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*)
      log "REJECT metachar/traversal: '$img'"; status "$base" ERROR "invalid image ref"; return ;;
  esac
  # NB the host part must allow a :PORT — the lab-local registry is reached as
  # image-registry.image-registry.svc.cluster.local:5000. A host pattern without the optional
  # (:[0-9]+) rejects every in-cluster registry ref as "invalid image ref", which reads
  # like a malformed manifest rather than a too-strict validator.
  # ⚠ EITHER FORM: `<repo>:<tag>` OR `<repo>@sha256:<64 hex>`. The generated launcher pins
  # the digest whenever the registered manifest carries one (module-cli.sh, matching
  # broker.sh's module_image()), so a tag-only pattern rejects every pinned module with
  # "invalid image ref" — the pin would silently disable the very modules it protects.
  if ! printf '%s' "$img" | grep -qE '^[a-z0-9.-]+(:[0-9]+)?/[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+|@sha256:[0-9a-f]{64})$'; then
    log "REJECT bad ref: '$img'"; status "$base" ERROR "invalid image ref"; return
  fi
  # Must live under this cluster's module registry path — nothing else.
  if ! printf '%s' "$img" | grep -qE "^${REGISTRY_HOST}/${MODULE_IMAGE_BASE}/"; then
    log "REJECT out-of-scope repo: '$img'"; status "$base" ERROR "image not a registered module"; return
  fi

  if podman image exists "$img" 2>/dev/null; then
    log "already present: $img"; status "$base" READY "already present"; return
  fi

  status "$base" PULLING "fetching image"
  # Serialise per IMAGE, not globally: a cold pull is 10-20 min over the mesh, so a single
  # in-line loop would block every other user's request behind it (observed while testing:
  # a second request sat unprocessed for the whole pull). One flock per image also stops
  # two users racing the same multi-GB fetch into the same store.
  # ⚠ THE LOCK LIVES IN THE STORE, NOT IN $REQ_DIR. $REQ_DIR is a pod-local emptyDir, so a
  # lock there serialises only the users of ONE pod — two pods sharing a graphroot (the
  # desktop and an [eda-run] build pod on the same node) would each take their own lock and
  # both start the same 42.8 GB fetch. Podman's own storage.lock protects the metadata but
  # does NOT stop two concurrent pulls of one image wasting the bandwidth twice.
  # Placing it beside the graphroot makes it node-wide, which is what a shared cache needs.
  # ⚠ Test the GRAPHROOT ITSELF, not the concatenation: on a `podman info` failure the
  # substitution is empty and a naive "$root/.module-pull-locks" becomes the absolute
  # "/.module-pull-locks", which mkdir may happily CREATE at the filesystem root — giving
  # each pod its own lock and silently losing the cross-pod serialisation this is for.
  local graphroot lockdir lock
  graphroot="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
  if [ -d "$graphroot" ]; then
    lockdir="$graphroot/.module-pull-locks"
    mkdir -p "$lockdir" 2>/dev/null || lockdir=""
  else
    lockdir=""
  fi
  if [ -z "$lockdir" ]; then
    # Degraded, and say so loudly: the pull still happens, it is just no longer serialised
    # against other pods sharing this node's store.
    log "WARN cannot resolve podman graphroot — pull lock falls back to the pod-local $REQ_DIR"
    lockdir="$REQ_DIR"
  fi
  lock="$lockdir/.lock.$(printf '%s' "$img" | tr -c 'a-zA-Z0-9._-' '_')"
  (
    exec 9>"$lock"
    flock 9
    if podman image exists "$img" 2>/dev/null; then
      log "already present after wait: $img"; status "$base" READY "already present"; exit 0
    fi
    # Same stale-marker guard as do_run: a PULL also re-stamps `.has-mount-program`, and it
    # runs first, so clearing it only at run time would still leave the pull's mounts (and
    # the run that follows) routed through fuse-overlayfs. See the long note in do_run.
    if [ "$(cat /var/lib/containers/storage/overlay/.has-mount-program 2>/dev/null)" = "true" ] \
       && ! grep -qE '^\s*mount_program\s*=' /etc/containers/storage.conf 2>/dev/null; then
      log "clearing stale .has-mount-program marker before pull"
      rm -f /var/lib/containers/storage/overlay/.has-mount-program 2>/dev/null || true
    fi
    log "pulling $img"
    if podman pull --authfile "$RUNAUTH" --tls-verify=false "$img" >/dev/null 2>&1; then
      log "pulled $img"
      status "$base" READY "pulled"
    else
      log "FAILED to pull $img"
      status "$base" ERROR "pull failed"
    fi
  ) &
}

# do_run: execute a container-module image as root, on behalf of the calling user.
#
# The request file is NUL-free, one field per line, written by the generated launcher:
#   line 1  image reference        (validated exactly as for a pull)
#   line 2  caller uid
#   line 3  caller HOME
#   line 4  caller cwd
#   line 5  caller DISPLAY
#   line 6+ the command and its arguments, one per line (never re-split, never eval'd)
#
# Argument handling is security-critical: the argv is read into a bash array and passed
# straight to `podman run`, so no shell ever re-parses it, and it cannot smuggle a flag to
# podman itself or name a different image. It CAN choose the command — the module images
# declare no ENTRYPOINT, so argv[0] is what runs. That is acceptable only because the
# container runs as the caller (see the uid handling below): a user picking their own
# command inside the module image gets nothing they do not already have in the desktop pod.
#
# ⚠ THE CALLER'S UID IS THE REQUEST FILE'S OWNER, NEVER A LINE INSIDE THE FILE. REQ_DIR is
# 0733 precisely so any desktop user can drop a request, so every byte of its CONTENT is
# attacker-chosen. Line 2 used to be taken on trust: writing `0` there yielded
# `podman run --user 0` in a `--cgroups=disabled --network=host` container, i.e. root on the
# node's container runtime from an unprivileged LDAP session. The creator's uid is recorded
# on the inode by the kernel and cannot be forged, so that is the only usable source. Line 2
# is still READ — it holds the protocol's 5-line header shape that `tail -n +6` depends on —
# but its value is discarded.
#
# uid 0 is NOT rejected: the image's built-in root session legitimately loads modules, and
# for it the file owner IS 0. Taking the owner is what makes that safe — root gets root
# because it already was root, not because it asked.
do_run() {  # $1 = request file
  local reqf="$1" base img uid home cwd disp fuid hown
  base=$(basename "$reqf")
  fuid=$(stat -c %u "$reqf" 2>/dev/null || true)
  { read -r img; read -r uid; read -r home; read -r cwd; read -r disp; } < "$reqf"
  mapfile -t argv < <(tail -n +6 "$reqf")
  rm -f "$reqf"

  case "$fuid" in
    ''|*[!0-9]*)
      log "REJECT run: cannot determine the owner of '$base'"; status "$base" ERROR "unknown caller"; return ;;
  esac
  [ "$uid" = "$fuid" ] || log "NOTE: request '$base' claimed uid '$uid'; using its owner $fuid"
  uid="$fuid"

  case "$img" in
    *..*|*' '*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*)
      log "REJECT run metachar: '$img'"; status "$base" ERROR "invalid image ref"; return ;;
  esac
  # Same two accepted forms as the pull path above — a digest-pinned module must be
  # runnable, not just pullable.
  if ! printf '%s' "$img" | grep -qE "^${REGISTRY_HOST}/${MODULE_IMAGE_BASE}/[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+|@sha256:[0-9a-f]{64})$"; then
    log "REJECT run out-of-scope: '$img'"; status "$base" ERROR "image not a registered module"; return
  fi
  # HOME/cwd must be real paths owned by the caller — never a way to bind-mount /etc, and
  # never a way to mount a DIFFERENT user's home. The ownership test is what enforces the
  # second half; the /home/ prefix alone does not, since every user's home lives there.
  # A stat that fails (a home that is not there at all) is a rejection, not a pass.
  #
  # uid 0 is exempt, and must be: the image's built-in root session runs with
  # HOME=/home/headless, a directory seeded from the base image and owned by ITS account,
  # not by root. Root can read any home regardless, so the test would cost that session its
  # modules and buy nothing.
  case "$home" in /home/*) ;; *) log "REJECT run home: '$home'"; status "$base" ERROR "bad home"; return ;; esac
  if [ "$uid" != "0" ]; then
    hown=$(stat -c %u "$home" 2>/dev/null || true)
    if [ "$hown" != "$uid" ]; then
      log "REJECT run home: '$home' is owned by '${hown:-?}', caller is $uid"
      status "$base" ERROR "home not owned by caller"; return
    fi
  fi
  case "$disp" in :[0-9]*) ;; *) disp=":10" ;; esac
  # cwd is only `-w`, not a mount, but it must still resolve INSIDE a directory that IS
  # mounted — anything else names a path the container does not have and podman fails with
  # a bare "chdir" error that reads like a broken image.
  #
  # ⚠ A BATCH CALLER WORKS OUTSIDE $HOME, AND ITS WORKSPACE MUST BE MOUNTED. A CI job runs
  # in /builds/<group>/<project>, so clamping cwd to $home silently started the tool in the
  # wrong directory: Vivado came up fine and then died with
  #   couldn't read file "../_vivado_batch.tcl": no such file or directory
  # for a file that exists — measured on job 65. The tool's own log names the missing file,
  # never the wrong directory, so this reads as a repo/path bug rather than a mount gap.
  # So mount the workspace ROOT (the first two path components, e.g. /builds/deployments)
  # rather than the leaf: deploy.sh walks UP out of its own directory (`../`) and symlinks
  # into a sibling submodule checkout, both of which break if only the leaf is present.
  local _ws_args="" _ws_root="" _wown=""
  case "$cwd" in
    "$home"|"$home"/*) ;;                      # inside $HOME: already mounted below
    /builds/*)
      # ⚠ RESTRICTED TO /builds/ ON PURPOSE — THIS IS A MOUNT INTO A ROOT CONTAINER.
      # $home above is guarded by BOTH a /home/* prefix and an ownership test, precisely so
      # a caller cannot bind-mount /etc. This path needs the same discipline: without the
      # prefix restriction an unprivileged desktop user could request cwd=/etc/anything and
      # get /etc mounted into a container running as root. /builds is the Kubernetes
      # executor's workspace root and exists only in a CI pod, so an interactive user has
      # no /builds to point at.
      # ⚠ Do NOT widen this to a general "first two components" rule.
      #
      # Take the first TWO components (/builds/<group>): deploy.sh walks UP out of its own
      # directory (`../`) and symlinks into a sibling submodule checkout, so mounting only
      # the leaf breaks both.
      _ws_root=$(printf '%s' "$cwd" | cut -d/ -f1-3)
      # No `..` anywhere in the request — cut() would otherwise hand back a prefix that
      # resolves elsewhere.
      case "$cwd" in *..*) log "REJECT run cwd: '$cwd' contains .."; status "$base" ERROR "bad cwd"; return ;; esac
      if [ -n "$_ws_root" ] && [ -d "$_ws_root" ]; then
        # ⚠ OWNERSHIP IS TESTED ON $cwd, NOT ON $_ws_root, AND THAT IS DELIBERATE.
        # $_ws_root is the shared group directory (/builds/<group>) which the RUNNER creates
        # as root and which holds every project's checkout; a caller legitimately owns only
        # its OWN project subtree beneath it. Testing the root instead rejected the very
        # case this branch exists for:
        #   REJECT run cwd: '/builds/deployments' is owned by '0', caller is 1001
        # (measured on job 70). Requiring the caller to own the shared root would mean
        # chowning the whole tree to one build's user, which is worse than what is being
        # prevented.
        #
        # What the test still guarantees is the thing that matters: the caller cannot name a
        # directory it does not own, so it cannot use this to reach another user's files.
        # The mount is wider than the cwd out of necessity (deploy.sh walks up and symlinks
        # into a sibling submodule), which is why the /builds/ prefix restriction above is
        # load-bearing rather than decorative — it is what keeps that widening inside the
        # CI workspace and away from /etc.
        # Root is exempt for the same reason as $home.
        if [ "$uid" != "0" ]; then
          _wown=$(stat -c %u "$cwd" 2>/dev/null || true)
          if [ "$_wown" != "$uid" ]; then
            log "REJECT run cwd: '$cwd' is owned by '${_wown:-?}', caller is $uid"
            status "$base" ERROR "workspace not owned by caller"; return
          fi
        fi
        _ws_args="-v $_ws_root:$_ws_root"
        log "workspace outside \$HOME — mounting $_ws_root and running in $cwd"
      else
        log "cwd '$cwd' has no mountable root — falling back to \$HOME"
        cwd="$home"
      fi
      ;;
    /scratch/*)
      # ⚠ SAME POSTURE AS /builds/ ABOVE — THIS IS A MOUNT INTO A ROOT CONTAINER — but
      # with a STRICTER rule, because /scratch is reachable by every desktop user while
      # /builds only exists in a CI pod.
      #
      # WHY IT IS NEEDED: $HOME is the nfs-homes NFS PV seen through gVisor's v9fs, and
      # NFSv4 synthesises system.nfs4_acl / system.nfs4_dacl on every file. listxattr
      # enumerates them, getxattr then fails, so Yocto's sstate_task_postfunc —
      # `cp -afl --preserve=xattr` — dies on every task:
      #   cp: getting attribute 'system.nfs4_dacl': Operation not supported
      # A PetaLinux TMPDIR therefore CANNOT live under $HOME. /scratch is a node-local
      # hostPath (see desktop-gvisor.yaml), carries no NFS xattrs and copies cleanly.
      # /tmp is NOT an alternative: it is a RAM-backed tmpfs here and a Yocto TMPDIR is
      # tens of GB. Point PetaLinux at it with CONFIG_TMP_DIR_LOCATION.
      #
      # ⚠ THE UID IS PART OF THE PATH, DELIBERATELY. The mount is /scratch/<uid>, never
      # /scratch itself: /scratch is 1777 and shared by every user on the node, so mounting
      # the whole thing into a root container would hand one user's build write access to
      # every other user's scratch. Requiring the caller's own uid as the FIRST component
      # is what keeps them apart, and it is checked against the CALLER's uid — not merely
      # parsed out of the request — so it cannot be spoofed by naming someone else's dir.
      #
      # Unlike /builds this does NOT widen to a shared parent: there is no sibling-submodule
      # case here, so the narrowest mount that works is the right one.
      #
      # ⚠ /scratch/<uid> IS NOT PRE-CREATED, AND THAT IS NOT AN OVERSIGHT. The desktop
      # startup makes /scratch 1777+sticky rather than laying down per-user dirs, because
      # these users are AD accounts with no local uid here — guessing would create dirs
      # owned by the wrong id (see the comment in desktop-gvisor.yaml). Sticky means the
      # user creates their own and nobody else can remove it; the ownership test below is
      # what then proves it really is theirs. So a caller must `mkdir -p /scratch/$(id -u)`
      # once — until they do, this branch falls back to $HOME with the log line below.
      case "$cwd" in *..*) log "REJECT run cwd: '$cwd' contains .."; status "$base" ERROR "bad cwd"; return ;; esac
      _ws_root="/scratch/$uid"
      case "$cwd" in
        "$_ws_root"|"$_ws_root"/*) ;;
        *) log "REJECT run cwd: '$cwd' is not under /scratch/$uid (caller uid $uid)"
           status "$base" ERROR "scratch dir not owned by caller"; return ;;
      esac
      if [ -d "$_ws_root" ]; then
        # Ownership test as well as the path rule: the directory must actually BE the
        # caller's, so a pre-existing /scratch/<uid> planted by someone else is refused.
        # Root is exempt for the same reason as $home and /builds.
        if [ "$uid" != "0" ]; then
          _wown=$(stat -c %u "$_ws_root" 2>/dev/null || true)
          if [ "$_wown" != "$uid" ]; then
            log "REJECT run cwd: '$_ws_root' is owned by '${_wown:-?}', caller is $uid"
            status "$base" ERROR "scratch dir not owned by caller"; return
          fi
        fi
        _ws_args="-v $_ws_root:$_ws_root"
        log "workspace on node-local scratch — mounting $_ws_root and running in $cwd"
      else
        log "cwd '$cwd' has no mountable root — falling back to \$HOME"
        cwd="$home"
      fi
      ;;
    *) cwd="$home" ;;
  esac
  [ -d "$cwd" ] || cwd="$home"

  # ⚠ USER/LOGNAME MUST BE SET, and nothing else sets them here. A login shell exports
  # them; the run-request protocol has no env field, so a container started this way gets
  # neither. Measured inside the petalinux module container — the ENTIRE env is
  #   HOME=... LANG=... PATH=... PWD=...
  # with no USER, no LOGNAME and no LC_ALL. BitBake's server startup and Yocto's sanity
  # checks read all three, and when the server cannot start petalinux-config reports only
  #   ERROR: Unable to start bitbake server (None)
  # — the literal None being the exception it failed to render — while
  # bitbake-cookerdaemon.log stays EMPTY because the server dies before opening it. So the
  # symptom names nothing at all. What isolated it: running the SAME bitbake by hand on the
  # runner (where runuser sets USER) prints "BitBake Build Tool Core version 2.2.0" and
  # works, so bitbake is fine on this host and only the container's env differs.
  # Resolve the NAME from the uid rather than trusting the request: the uid is already the
  # authenticated value (the request file's owner).
  local _uname
  _uname=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
  [ -n "$_uname" ] || _uname="$uid"

  if ! podman image exists "$img" 2>/dev/null; then
    log "run requested but image absent: $img"; status "$base" ERROR "image not present"; return
  fi

  log "running $img (uid=$uid) ${argv[*]}"
  status "$base" RUNNING "starting container"
  # PER-RUN log, not the shared /var/log/module-run.$uid.log. Two reasons, both required for
  # batch use: concurrent runs by the same user interleave unreadably in one file, and the
  # caller streams this file back to its own stderr — it must contain THIS run's output only.
  # The name is derived from the request basename, which is generated by the launcher and
  # already validated as a path component by the REQ_DIR scan (never user-supplied text).
  local runlog="/var/log/module-run.$uid.$base.log"
  : > "$runlog" 2>/dev/null || true
  chown "$uid" "$runlog" 2>/dev/null || true
  chmod 0644 "$runlog" 2>/dev/null || true
  # ⚠ THE X11 MOUNT IS CONDITIONAL, and it must be. podman REFUSES TO START a container
  # when a bind-mount SOURCE does not exist, exiting 125 before the command ever runs —
  # and /tmp/.X11-unix exists only where an X server does. In the desktop pod it always
  # does; in a HEADLESS consumer (the [eda-run] CI build pod, a batch job) it never does,
  # so an unconditional `-v /tmp/.X11-unix:...` made EVERY module launch fail with a bare
  # `container exited rc=125` and nothing in the tool's own log. Measured on ecc204: the
  # 40 GB image pulled fine and then every binary in it reported "not found", because the
  # container had not started at all.
  # DISPLAY is passed only alongside it: without the socket it would name a display that
  # cannot be reached, which turns a clean "no GUI here" into a confusing X error.
  #
  # ⚠ THE SOCKET IS NOT ENOUGH — THE X COOKIE HAS TO COME WITH IT. xrdp's per-user X server
  # uses MIT-MAGIC-COOKIE-1 auth, and every entry in ~/.Xauthority is keyed by the POD
  # HOSTNAME (`<pod>/unix:10`). A container gets a different hostname, so even bind-mounting
  # the user's own .Xauthority does NOT match: the tool dies with
  #   Authorization required, but no authorization protocol specified
  #   HyperLynxDRC: line 72: 20 Aborted   ${HLD_HOME}/hldrcqt
  # which reads like a crash, not an auth failure — and the process can linger with NO window
  # while the log shows only harmless Qt/dbus noise, so it presents as "the GUI does not show".
  # Measured 2026-09-17 on remote-desktop-bender.
  #
  # The fix is to re-key the cookie to the WILDCARD family (`ffff`), which matches regardless
  # of hostname, and hand the container that file instead. `xauth nlist | sed | nmerge` is the
  # documented way to do this. Written per-launch under the user's own runtime dir, 0600 and
  # owned by the caller: the cookie grants full access to that user's X session, so it must
  # never be world-readable or shared between users on this multi-session desktop.
  # ⚠ MOUNT THE CALLER'S OWN SCRATCH REGARDLESS OF cwd. The branch above only fires when
  # the caller RUNS FROM scratch, which is not how the case that motivated it works: a
  # PetaLinux build runs from the project under $HOME and merely POINTS its TMPDIR at
  # scratch (CONFIG_TMP_DIR_LOCATION). With a cwd-keyed mount only, the container never
  # sees /scratch and the build dies on
  #   PermissionError: [Errno 13] Permission denied: '/scratch'
  # which reads as a permissions bug rather than a missing mount. Measured 2026-09-20.
  #
  # Same safety rule as that branch, and it is the rule that makes this safe to do
  # unconditionally: ONLY /scratch/<caller uid>, never /scratch itself (1777, shared by
  # every user on the node), with the uid taken from the CALLER and an ownership test on
  # the directory. Absent or foreign-owned ⇒ simply not mounted, never an error, because
  # most module launches have nothing to do with scratch.
  local _scr_args="" _scr_dir="" _sown=""
  _scr_dir="/scratch/$uid"
  if [ -d "$_scr_dir" ]; then
    _sown=$(stat -c %u "$_scr_dir" 2>/dev/null || true)
    if [ "$uid" = "0" ] || [ "$_sown" = "$uid" ]; then
      case "$_ws_args" in
        *" $_scr_dir:$_scr_dir"*) ;;                 # already mounted by the cwd branch
        *) _scr_args="-v $_scr_dir:$_scr_dir" ;;
      esac
    else
      log "not mounting $_scr_dir — owned by '${_sown:-?}', caller is $uid"
    fi
  fi

  local _x11_args="" _xauth=""
  if [ -d /tmp/.X11-unix ]; then
    _x11_args="-e DISPLAY=$disp -v /tmp/.X11-unix:/tmp/.X11-unix"
    # Best-effort: a module that needs no GUI still runs if this fails.
    _xauth="/run/module-xauth/xauth.$uid.$base"
    mkdir -p /run/module-xauth 2>/dev/null || true
    chmod 0711 /run/module-xauth 2>/dev/null || true
    if su_xauth_ok "$uid" "$disp" "$_xauth"; then
      _x11_args="$_x11_args -e XAUTHORITY=$_xauth -v $_xauth:$_xauth:ro"
    else
      log "could not build an X cookie for uid=$uid display=$disp — GUI modules may fail to open a window"
      _xauth=""
    fi
  else
    log "no /tmp/.X11-unix — running headless (no DISPLAY passed)"
  fi
  (
    # --user: the process inside the container runs as the CALLER, not root, so files it
    # writes into the bind-mounted $HOME stay owned by that user.
    #
    # ⚠ LICENSE VARS ARE AN EXPLICIT ALLOW-LIST, and it must cover every name a module's
    # `env.set_from_secret` declares. HyperLynx reads SALT_LICENSE_SERVER (see
    # eda-hyperlynx-2604/module.yaml) and it was MISSING here: `module load hyperlynx/2604`
    # succeeds, the launcher runs, and the tool then dies with SIGABRT because it had no
    # license server. Passing the var through only works if the DESKTOP pod exports it too
    # (desktop-*.yaml maps the sealed license secret), so a new tool needs BOTH sides.
    # ⚠ HyperLynx needs MGLS_LICENSE_FILE **as well as** SALT_LICENSE_SERVER — two Siemens
    # vendor daemons on one host (`saltd` and `mgcld`), addressed by two different vars.
    # Forwarding only SALT gets the GUI as far as "No licenses for HyperLynx's primary
    # features were obtained ... License server is not defined", which reads like a missing
    # entitlement but is a missing ADDRESS. See desktop-bender.yaml for the measurement.
    # ⚠ --ipc=host IS A PERFORMANCE FLAG FOR GUI MODULES, and the reason is MIT-SHM. The
    # X server runs in the DESKTOP container and hands clients shared-memory segments for
    # every frame (rdpClientConAllocateSharedMemory in the Xorg log, ~12 MB a time). Without
    # this flag the module lands in its OWN ipc namespace with podman's default 64 MB
    # /dev/shm, so it cannot attach to them and every redraw is copied through the X socket
    # instead. Measured 2026-09-22 on the gVisor desktop: module ipc:[31] + 63M against the
    # desktop's ipc:[3] + 126G; with the flag the module joins ipc:[3] and sees the same
    # 126G. A heavy OpenGL canvas like KiCad's feels laggier than the Xfce desktop around it
    # precisely because Xfce redraws are cheap and its are not.
    # ⚠ NO --shm-size NEEDED. Joining the host ipc namespace brings the desktop's /dev/shm
    # with it; --shm-size would only size a PRIVATE one, which is what we are getting rid of.
    # ⚠ Scope: this shares an IPC namespace with the desktop container, NOT with the node —
    # "host" here means this pod. The module already shares that pod's network namespace and
    # runs as the calling user, so it is not a new trust boundary.
    # ⚠ The env a container sees is decided HERE: the run-request protocol has no env field,
    # so a license flag added to the generated wrapper (module-cli.sh) has no effect.
    # ⚠ SKIP_BBPATH_SEARCH is forwarded for PetaLinux: gen-machineconf otherwise calls
    # bb.tinfoil.Tinfoil().prepare(), which HANGS in this sandbox (the server answers
    # setFeatures/updateConfig then goes silent — see the CI job's own note). The variable
    # only reaches the tool if it is BOTH exported by the caller AND listed here.
    # ⚠ CLEAR THE STALE `.has-mount-program` MARKER BEFORE EVERY RUN, not just at startup.
    # podman records whether the store was last used WITH a fuse-overlayfs mount_program in
    # this file, and then trusts the marker over storage.conf. The startup script removes it
    # once at boot (startup-configmap.yaml), but podman REWRITES it on every single run — so
    # one run that observes a mount_program re-stamps it `true` and every later mount is
    # routed back through fuse-overlayfs, which cannot work under gVisor.
    #
    # The failure does not look like a storage problem. The container starts with an EMPTY
    # rootfs, so crun reports the ENTRYPOINT missing:
    #   crun: executable file `/usr/local/bin/kicad-entry` not found in $PATH
    # which reads as a broken IMAGE. Measured 2026-09-21 on unibi-hclab-pcie-tb-s: a stale
    # `true` marker failed EVERY module — and `podman run alpine echo OK` failed identically
    # with `echo` not found, which is what proved it was the node and not the image.
    #
    # Cheap: one unlink on a tmpfs-backed path per run, against a container launch.
    if [ "$(cat /var/lib/containers/storage/overlay/.has-mount-program 2>/dev/null)" = "true" ] \
       && ! grep -qE '^\s*mount_program\s*=' /etc/containers/storage.conf 2>/dev/null; then
      log "clearing stale .has-mount-program marker (config has no mount_program)"
      rm -f /var/lib/containers/storage/overlay/.has-mount-program 2>/dev/null || true
    fi
    podman run --rm \
      --cgroups=disabled \
      --network=host \
      --ipc=host \
      --user "$uid" \
      ${_x11_args} \
      -v "$home":"$home" ${_ws_args} ${_scr_args} -w "$cwd" -e HOME="$home" \
      -e USER="$_uname" -e LOGNAME="$_uname" \
      -e LC_ALL="${LC_ALL:-en_US.UTF-8}" \
      ${MODULE_LICENSE_SERVER:+-e MODULE_LICENSE_SERVER="$MODULE_LICENSE_SERVER"} \
      ${XILINXD_LICENSE_FILE:+-e XILINXD_LICENSE_FILE="$XILINXD_LICENSE_FILE"} \
      ${LM_LICENSE_FILE:+-e LM_LICENSE_FILE="$LM_LICENSE_FILE"} \
      ${SALT_LICENSE_SERVER:+-e SALT_LICENSE_SERVER="$SALT_LICENSE_SERVER"} \
      ${MGLS_LICENSE_FILE:+-e MGLS_LICENSE_FILE="$MGLS_LICENSE_FILE"} \
      ${SKIP_BBPATH_SEARCH:+-e SKIP_BBPATH_SEARCH="$SKIP_BBPATH_SEARCH"} \
      "$img" "${argv[@]}" >>"$runlog" 2>&1
    # Capture rc IMMEDIATELY — `log` below runs a command and would overwrite $?.
    # Plain assignment, not `local`: this is a subshell, and although bash does accept
    # `local` here (the subshell inherits the function context) that is a subtlety not worth
    # depending on.
    rc=$?
    # The per-launch X cookie is a bearer token for the user's display — drop it as soon as
    # the container that needed it is gone, rather than leaving one file per launch behind.
    [ -n "$_xauth" ] && rm -f "$_xauth" 2>/dev/null
    log "container exited rc=$rc for $img"
    # The rc travels in the STATUS LINE so the caller can exit with it. Without this a batch
    # script never sees a failure: the launcher used to exit 0 on any DONE, so `set -e` did
    # not fire and a failed synthesis looked like success.
    status "$base" DONE "$rc"
  ) &
}

# ⚠ REQUIRED, deliberately NOT defaulted. Both are set on the desktop container by
# desktop-gvisor.yaml; the same pair is set on the broker sidecar, which aborts on them
# being unset (broker.sh) — this side must behave identically or the two disagree
# silently.
#
# A default here would have to name SOME registry, and the only plausible one is GitLab's
# — but EDA module images are published ONLY to the lab-local image-registry. Falling back
# produces a module that prepares fine (the broker has the right host) and then fails at
# first run with "could not pull … (pull failed)", which reads like a credential or
# network fault rather than a wrong registry. Failing here instead makes the startup
# supervisor log the reason on every restart attempt.
for _v in REGISTRY_HOST MODULE_IMAGE_BASE; do
  eval "_val=\${$_v:-}"
  [ -n "$_val" ] || { log "FATAL: $_v is not set — refusing to serve container modules"; exit 78; }
done

# Non-fatal: a pull from an unauthenticated registry still works, and failing the daemon
# outright would take out modules that do not need credentials at all. Log it, because the
# symptom otherwise is a 401 that reads like a wrong password.
write_authfile || log "WARN: could not build $RUNAUTH from $AUTHFILE — pulls will be unauthenticated"

log "started (req dir $REQ_DIR, registry ${REGISTRY_HOST}/${MODULE_IMAGE_BASE})"
while :; do
  for f in "$REQ_DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .status.*|.lock.*) continue ;; esac
    # A pull request is a single line (the image). A run request has the 5-line header
    # plus argv, so anything with more than one line is a run.
    if [ "$(wc -l < "$f" 2>/dev/null || echo 1)" -gt 1 ]; then
      do_run "$f"
    else
      do_pull "$f"
    fi
  done
  # 0.1 s, not 2 s: this is the latency floor for EVERY request — a request dropped just
  # after a scan waits the full interval before the helper even notices it. Batch scripts
  # invoke these tools dozens of times, so 2 s of dispatch delay per call was the single
  # largest avoidable cost (a trivial `hw_server -version` measured 8.4 s end-to-end against
  # 2.6 s for the equivalent raw `podman run`). The loop is a directory stat on a tmpfs, so
  # polling ten times a second is negligible next to the podman work it dispatches.
  sleep 0.1
done
