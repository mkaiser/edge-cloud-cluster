# /etc/profile.d/z10-module.sh — user-facing `module` command for the remote-desktop.
#
# Wraps real Lmod: for `module load <name>/<ver>`, first ask the privileged broker to
# PREPARE the module (drop a request, wait for it to become READY), which publishes its
# manifest. The tool itself lives in an OCI image that the desktop's podman runs, so the
# load then generates launchers rather than manipulating the env. Every other subcommand
# (avail/list/unload/…) is merged with Lmod's own view.
#
# Users are unprivileged; they can only WRITE a request file into the broker's 0733 request
# dir. They never touch the registry credential or the image store.

# ⚠ BASH ONLY — bail out under any other shell.
#
# This file lives in /etc/profile.d/, so EVERY POSIX-sh login sources it too, and its
# contents are bash-specific (`declare -f`, function syntax, `[[ ]]`). Under dash the
# `declare -f module` below fails ("declare: not found"), the surrounding `eval` then gets
# truncated input and dies with "Syntax error: end of file unexpected", and the sourcing
# script exits non-zero.
#
# That broke RDP logins outright: /etc/xrdp/startwm.sh is `#!/bin/sh`, sources /etc/profile
# (hence this file), and so exited 2 before ever reaching Xsession. xrdp-sesman logged only
# "Window manager exited with non-zero exit code 2 ... exited quickly (0 secs)" and tore the
# session down — the user saw an immediate disconnect right after a SUCCESSFUL login, with
# nothing in .xsession-errors (the failure happens before Xsession redirects into it).
#
# `${BASH_VERSION:-}` is the portable test: dash leaves it unset, bash always sets it.
if [ -z "${BASH_VERSION:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# Source Lmod's init, then RENAME Lmod's own `module` function to `_lmod_module` so the
# wrapper below can
# delegate to it. This is required, not cosmetic: Lmod's `ml` is a function that runs
# `eval "$(ml_cmd "$@")"`, and ml_cmd emits literally `module load 'x'`. If the wrapper
# delegated via `ml`, every `module load` would re-enter the wrapper through ml_cmd's
# emitted `module` call and recurse forever — `module load` hangs with no output and no
# error (it looks exactly like a slow broker fetch). Delegate to the renamed function.
if [ -f /usr/share/lmod/lmod/init/bash ]; then
  . /usr/share/lmod/lmod/init/bash
  # capture Lmod's definition under a new name, before we shadow `module`
  eval "_lmod_module() $(declare -f module | tail -n +2)"
  # Lmod's own /etc/profile.d/lmod.sh exports BASH_ENV=<lmod init>, which bash sources for
  # every NON-INTERACTIVE shell. That re-runs Lmod's init AFTER this file and silently
  # restores the raw `module` function, so in a script the wrapper is gone and `module load`
  # of a module (which has no Lmod modulefile by design) fails.
  # Interactive shells are unaffected (bash ignores BASH_ENV there),
  # which is why a terminal works and a script does not — a nasty asymmetry to debug.
  # Drop it: the modulefile tree is registered above, so nothing here needs BASH_ENV.
  unset BASH_ENV
fi

_REQ_DIR=/run/module-requests      # broker: fetch + prepare (privileged sidecar)

# Container-runtime modules are launched through generated wrappers in $HOME/.local/bin (they
# cannot put anything on PATH themselves — the tool lives in another container). That dir is
# NOT on the default PATH in this image, so the wrappers existed but "command not found".
# Add it. Also note $HOME is /home/headless for the image's built-in root session, so the
# wrappers follow $HOME rather than the account name — always use $HOME, never a literal path.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

# _module_request <reqdir> <spec> <tries> <what> → 0 on READY, 1 on error/timeout
# Both privileged helpers use the same protocol: drop "name/version" into a 0733 dir, poll
# for a .status.<reqfile> line of "READY|ERROR <msg>".
_module_request() {
  local dir="$1" spec="$2" tries="$3" what="$4" id reqf statf i st msg
  id="$$-$(date +%s%N)"
  reqf="$dir/req.$id"
  statf="$dir/.status.req.$id"
  printf '%s\n' "$spec" > "$reqf" 2>/dev/null || { echo "module: cannot reach $what" >&2; return 1; }
  for i in $(seq 1 "$tries"); do
    if [ -f "$statf" ]; then
      st=$(cut -d' ' -f1 "$statf"); msg=$(cut -d' ' -f2- "$statf")
      case "$st" in
        READY) rm -f "$statf"; return 0 ;;
        ERROR) echo "module: $what error: $msg" >&2; rm -f "$statf"; return 1 ;;
      esac
    fi
    sleep 5
  done
  echo "module: timed out waiting for $spec ($what)" >&2; return 1
}

_module_fetch() {  # $1 = name/version  → 0 when the broker has prepared it, 1 on error
  # NOTE: separate `local` statements are required. In a single `local spec="$1"
  # n="${spec%%/*}"`, bash expands n BEFORE spec is assigned, so n/v come out EMPTY and
  # every fast-path test silently checks "/modules/.ready/-" (always missing) — which sends
  # already-loaded modules back to the broker and makes `module load` look like a hang.
  local spec="$1"
  local n="${spec%%/*}" v="${spec##*/}"
  # There is no mount step: every module is an OCI image the desktop's podman runs, so
  # "ready" means the broker has published the manifest. The image itself is pulled later,
  # by module-podmand, on first launch.
  [ -f "/modules/.ready/$n-$v" ] && return 0
  printf 'Loading %s (fetching from registry on first use, please wait)...\n' "$spec"
  # up to ~1 h: generous because the broker may have to read the manifest out of the image.
  _module_request "$_REQ_DIR" "$spec" 720 broker || return 1
  return 0
}

# The broker publishes each module's manifest BESIDE its module dir, as
# /modules/<name>/<version>.module.yaml — not inside it, so the CLI has one lookup path.
_module_manifest() { printf '/modules/%s/%s.module.yaml' "${1%%/*}" "${1##*/}"; }

# Shim dir for a container module's cli_entries. Wrappers here are named after the REAL
# binary, so this dir goes on PATH only while the module is loaded.
_module_shim_dir() { printf '%s/.local/module-bin/%s/%s' "$HOME" "${1%%/*}" "${1##*/}"; }

# _module_shim_path add|remove <name/version> — put the module's CLI shims on PATH (or take
# them off again). Idempotent in both directions; same guard style as the .local/bin block
# near the top of this file.
_module_shim_path() {
  local action="$1" dir
  dir=$(_module_shim_dir "$2")
  case "$action" in
    add)
      [ -d "$dir" ] || return 0
      case ":$PATH:" in
        *":$dir:"*) : ;;
        *) PATH="$dir:$PATH"; export PATH ;;
      esac ;;
    remove)
      # Rebuild PATH without this dir. Plain string surgery would also hit a longer path
      # that merely has $dir as a prefix, so filter element-wise.
      local out="" p
      local IFS=:
      for p in $PATH; do
        [ "$p" = "$dir" ] && continue
        out="${out:+$out:}$p"
      done
      PATH="$out"; export PATH ;;
  esac
}

# _module_loaded_containers → the container modules loaded in THIS shell, one
# "<name>/<version>" per line.
#
# There is no Lmod record to consult: `module load` of a container module never calls Lmod
# (it has no modulefile), so $LOADEDMODULES stays empty and `module list` alone reports
# "No modules loaded" over a perfectly good module. PATH is the authority instead — it is
# what _module_shim_path add/remove maintains, so it tracks load AND unload in the current
# shell and cannot go stale the way a marker file under $HOME would (that is per-user, and
# would leak state into every other shell and survive a container restart).
#
# Derives name/version from the shim dir layout ($HOME/.local/module-bin/<name>/<version>)
# rather than parsing anything: _module_shim_dir builds those paths, so the two stay
# consistent by construction.
_module_loaded_containers() {
  local shimroot="$HOME/.local/module-bin" p
  local IFS=:
  for p in $PATH; do
    case "$p" in
      "$shimroot"/*/*)
        # strip the root, leaving "<name>/<version>"
        printf '%s\n' "${p#"$shimroot"/}" ;;
    esac
  done
}

module() {
  case "${1:-}" in
    load|add)
      shift
      local rc=0 m
      for m in "$@"; do
        # ANY slashed spec is the broker's, and every module the broker serves is
        # `runtime: container` (it refuses anything else), so there is no second branch to
        # pick between: fetch it, then write the launchers. A container module gets no Lmod
        # env — the tool runs in its own container via podman.
        #
        # An unslashed name goes to Lmod, which is what serves its own modulefiles. Note
        # this means Lmod's HIERARCHICAL names (Core/lmod, Core/settarg) are not reachable
        # through the wrapper — they look like module specs and are sent to the broker,
        # which rejects them. Harmless: nothing on this desktop loads them.
        if case "$m" in */*) true ;; *) false ;; esac; then
          _module_fetch "$m" || { rc=1; continue; }
          _module_gui_launcher "$m" || rc=1
          _module_shim_path add "$m"
          # Print the REAL command names, not a "<entry>" placeholder — a container module
          # puts nothing on PATH, so these wrappers are the only way to launch it and the
          # user has no other way to discover what they are called.
          # One command per line: the names are long and near-identical, so a single
          # space-separated run-on is hard to read and easy to mistype.
          local _cmds _clis
          # ⚠ THE `|| true` IS LOAD-BEARING UNDER `set -e`. A module with only
          # `cli_entries` and no `desktop_entries` — petalinux is exactly that — has no
          # module-<name>-* wrappers, so the glob matches nothing and `ls` exits non-zero.
          # `2>/dev/null` hides the MESSAGE but not the STATUS, and a caller running
          # `set -e` (any CI job) then dies right here, AFTER the module has actually
          # loaded successfully: rc=0 standalone, exit 2 under set -e, with no error text
          # anywhere. Measured on ecc204 — the second `module load` in a pipeline killed
          # the job silently while both modules were READY.
          _cmds=$(cd "$HOME/.local/bin" 2>/dev/null && ls module-"${m%%/*}"-* 2>/dev/null || true)
          _clis=$(cd "$(_module_shim_dir "$m")" 2>/dev/null && ls 2>/dev/null || true)
          if [ -n "$_cmds" ]; then
            printf '%s ready — GUI launchers:\n' "$m"
            printf '%s\n' "$_cmds" | sed 's/^/  - /'
            printf '(or launch it from the Applications menu)\n'
          else
            printf '%s ready — launch it from the Applications menu\n' "$m"
          fi
          # CLI entries are on PATH under their REAL names, so a batch script can call them
          # directly. Listed separately because the two naming schemes look nothing alike.
          if [ -n "$_clis" ]; then
            printf 'on PATH for scripts/batch:\n'
            printf '%s\n' "$_clis" | tr '\n' ' ' | sed 's/^/  /; s/ $/\n/'
          fi
          continue
        fi
        _lmod_module load "$m" || rc=1
      done
      return $rc ;;
    unload|rm)
      # A container module has NO Lmod modulefile, so plain `_lmod_module unload` errors out
      # ("Unable to locate a modulefile"). Take the CLI shims off PATH instead, and only
      # forward to Lmod for the bare names it actually knows about.
      shift
      local rc=0 m
      for m in "$@"; do
        if case "$m" in */*) true ;; *) false ;; esac; then
          _module_shim_path remove "$m"
          continue
        fi
        _lmod_module unload "$m" || rc=1
      done
      return $rc ;;
    list)
      # Lmod knows only its OWN modulefiles. A container module is loaded by putting its
      # CLI shims on PATH and writing GUI launchers — Lmod is never involved — so plain
      # `module list` reports "No modules loaded" even when one is loaded and working.
      # `module avail` already merges the container modules into Lmod's view for
      # DISCOVERABILITY; this is the same treatment for what is currently LOADED, so the
      # two commands agree and `unload` has something to correspond to.
      #
      # Lmod prints its own "No modules loaded" to stderr when it has nothing loaded.
      # Suppress that ONLY when we have container modules to show instead, otherwise the
      # user would see an empty response to `module list`.
      local _loaded; _loaded=$(_module_loaded_containers)
      if [ -n "$_loaded" ]; then
        if [ -n "${LOADEDMODULES:-}" ]; then
          _lmod_module "$@"
        fi
        printf '\nCurrently loaded container modules:\n'
        printf '%s\n' "$_loaded" | sed 's/^/   /'
        printf 'Unload with: module unload <name>/<version>\n'
      else
        _lmod_module "$@"
      fi
      return 0 ;;
    avail|av)
      # Lmod only lists modules that have a modulefile, and no container module ever gets
      # one — so every module on the share is invisible to plain `module avail`. Without
      # this, a user cannot discover what is loadable.
      # The registry lives on the SMB share, which is mounted only in the broker, so read
      # the index the broker publishes at /modules/.registered.
      _lmod_module "$@"
      if [ -s /modules/.registered ]; then
        printf '\n--------------------------- registered on the share ----------------------------\n'
        sed 's/^/   /' /modules/.registered
        printf 'Any of these can be loaded with: module load <name>/<version>\n'
        printf '(first load fetches the payload and can take a while).\n'
      fi
      return 0 ;;
    *)
      _lmod_module "$@" ;;   # spider / show / purge / … straight to Lmod
  esac
}

# `ml` is Lmod's shorthand and normally expands to a `module ...` call via ml_cmd. Since
# `module` is now the wrapper, route ml through the wrapper deliberately (so `ml load x`
# gets the fetch+mount treatment too) instead of leaving it pointing at raw Lmod.
ml() {
  case "${1:-}" in
    load|add|unload|rm|list|avail|av|spider|show|purge|use|unuse|swap|help|"")
      module "$@" ;;
    -*) module "$@" ;;
    *)  module load "$@" ;;   # bare `ml <name>/<ver>` means load, per Lmod
  esac
}

# Registry base for container-runtime module images. The desktop container pulls it
# image itself (sandbox-isolated) with the read-only registry cred; the broker only
# published the manifest. Overridable via env (same values as the broker sidecar).
: "${REGISTRY_HOST:=registry.gitlab.subdomain1.your-domain.tld}" # automatically updated from project-settings:{general.subdomain,general.domain}
: "${MODULE_IMAGE_BASE:=deployments/infrastructure/eda/modules}"
_MODULE_AUTHFILE=/var/run/registry-cred/.dockerconfigjson

# Write ~/.local/share/applications/<name>.desktop whose Exec re-establishes the
# module env itself — a desktop ICON inherits no shell, so it must self-load. The wrapper
# runs the module image via `podman run` with the proven nested-container recipe
# (doc/nested-container-runtime.md).
_module_gui_launcher() {  # $1 = name/version
  local spec="$1" name="${1%%/*}" ver="${1##*/}" appdir mf
  appdir="$HOME/.local/share/applications"
  mkdir -p "$appdir" "$HOME/.local/bin"
  # read desktop_entries from the broker-published manifest (beside the mount dir)
  mf=$(_module_manifest "$spec")
  [ -f "$mf" ] || return 0
  # ⚠ STDERR IS KEPT. This used to be `2>/dev/null || true`, which hid a REAL failure for
  # six days: the generator died on os.chmod(EPERM) against a root-owned shim, rewrote only
  # part of the entry list, and `module load` still printed "ready". The build then ran a
  # superseded image digest with no indication anywhere. The `|| true` stays — a launcher
  # that cannot be written must not abort the load, since the module itself is usable — but
  # the reason now reaches the user instead of /dev/null.
  #
  # ⚠ NOTHING MAY COME BETWEEN THESE ENV ASSIGNMENTS AND THE `python3` THEY PREFIX. A
  # comment inserted after a trailing `\` ENDS the continuation: the assignments then run as
  # their own no-op command and the generator starts with an EMPTY environment, dying on
  # `KeyError: 'MODULE_AUTHFILE'`. That is exactly what happened here on 2026-09-19 — and it
  # was only visible because the stderr above is no longer swallowed.
  REGISTRY_HOST="$REGISTRY_HOST" MODULE_IMAGE_BASE="$MODULE_IMAGE_BASE" \
  MODULE_AUTHFILE="$_MODULE_AUTHFILE" \
  python3 - "$mf" "$spec" "$appdir" "$HOME/.local/bin" "$HOME/.local/module-bin" <<'PY' || \
    echo "WARNING: could not (re)generate launchers for $spec — see the error above; the shims on PATH may pin a STALE image digest" >&2
import sys,os,re,tempfile
try: import yaml; d=yaml.safe_load(open(sys.argv[1]))
except Exception: sys.exit(0)
spec, appdir, bindir, shimroot = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

# ⚠ REPLACE THE FILE, DO NOT WRITE THROUGH IT. A shim left behind by an earlier
# `module load` that ran as a DIFFERENT uid (a root one, say) is not chmod-able by this
# user even when the directory is group-writable: open(w,'w') succeeds and os.chmod then
# raises EPERM, which used to abort the whole generator PART-WAY THROUGH the entry list.
# The result was a shim dir where some tools pinned the new image digest and the rest
# still pinned the old one — and because the caller swallows stderr, nothing said so.
# Measured 2026-09-18: petalinux shims from 2026-09-12 kept pinning a superseded digest
# across every subsequent `module load`, so the build ran a stale image.
# Writing to a temp file and os.replace()-ing it needs only directory permission, so it
# works regardless of who owns the old file, and it is atomic for concurrent loads.
def _write_shim(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.shim-')
    try:
        with os.fdopen(fd, 'w') as fh:
            fh.write(text)
        os.chmod(tmp, 0o755)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
name, ver = spec.split('/', 1)
reg  = os.environ['REGISTRY_HOST']; base = os.environ['MODULE_IMAGE_BASE']
authf = os.environ['MODULE_AUTHFILE']
# An optional `image:` key overrides the REPO PATH (version still appended), so two apps can
# publish the same module NAME from separate GitLab projects. Must match broker.sh's
# module_image() — if this drifts, the wrapper pulls a different image than the broker
# prepared. Traversal/absolute values fall back to the default, as in the broker.
repo = str(d.get('image') or '').strip().strip('"\'')
if not repo or '..' in repo or repo.startswith('/'):
    repo = f'{base}/{name}'
# ⚠ PIN BY DIGEST WHEN THE MANIFEST CARRIES ONE — broker.sh's module_image() does, and this
# is the half that was missing. Two consequences of running on the tag, both measured on
# petalinux/2024.1 (2026-09-04/05):
#   - SECURITY: registration authorises the broker to run an image AS ROOT, and the digest
#     in the manifest is what names the approved bytes. A wrapper on `:<ver>` runs whatever
#     that tag points at today, so the pin the broker records protects nothing on the path
#     users actually take.
#   - STALE IMAGE: module-podmand skips the pull when `podman image exists <ref>` is true,
#     and a tag it already holds is always "true". A FORCE_REBUILD that republishes the same
#     tag therefore NEVER reaches the desktop — it kept running the old image, and the only
#     symptom was the bug you just fixed still reproducing. A digest ref changes with the
#     rebuild, so the pull happens by itself.
# Validation mirrors the broker's: exactly sha256 + 64 hex, else fall back to the tag.
dig = str(d.get('digest') or '').strip().strip('"\'')
hexpart = dig[7:] if dig.startswith('sha256:') else ''
if len(hexpart) == 64 and all(c in '0123456789abcdef' for c in hexpart):
    image = f'{reg}/{repo}@{dig}'
else:
    image = f'{reg}/{repo}:{ver}'

# NB container env is NOT decided here: the run-request protocol has five fixed fields
# plus argv and no env field, so module-podmand chooses what the container sees. Adding a
# license flag to the generated wrapper has no effect — fix the allow-list in
# module-podman.sh instead.

# The launcher body is identical for a GUI entry and a CLI entry — same two-phase
# pull/run protocol, same request layout. Only the FILENAME and whether a .desktop file is
# written differ. Built once here so the two loops below cannot drift apart.
def container_wrapper(spec, image, cmd, exe):
        # Recipe: cgroups off (RO subtree_control), host net (inherits pod /etc/hosts
        # hostAliases → FlexNet), X11 socket in. Storage driver is NOT passed here — it
        # comes from /etc/containers/storage.conf (overlay + fuse-overlayfs). Passing
        # --storage-driver on the CLI overrides the whole [storage.options.overlay] block,
        # so the mount_program would be lost and podman would fall back to a native overlay
        # mount that the FUSE rootfs rejects.
        # $HOME is bound in at the SAME path (and is the working dir) so the tool can read
        # project files and write results back: without it a container module is
        # write-isolated from the user's files and only usable as a GUI scratchpad — no
        # batch/CLI use at all. Same path inside and out means a path the tool prints is
        # still valid in the desktop shell. $HOME is the per-user Longhorn homes PVC.
        # ⚠ A NORMAL f-string, NOT raw: the template relies on python collapsing `\\` to a
        # single `\` for every shell LINE-CONTINUATION below. Making it raw (tried once)
        # leaves those as `\\` and every continuation becomes a syntax error
        # (`syntax error near unexpected token '||'`). The consequence is that any escape
        # meant for the SHELL must be doubled here — see the printf below.
        return f'''#!/bin/bash
# Container launcher for {spec} ({exe}) — runs the module image via podman
# inside this sandboxed pod. Recipe: doc/nested-container-runtime.md.
set -e
# The image must live in the SHARED ROOT store (graphroot /var/lib/containers/storage —
# the hostPath these pods mount). An LDAP user cannot pull into it: bare `podman` as a
# non-root user opens a ROOTLESS store, which has no /etc/subuid entry for LDAP users
# (they do not exist at image build time), no newuidmap/newgidmap, and under gVisor the
# mapping is refused outright ("newuidmap: write to uid_map failed: Operation not
# permitted"). sudo is not an option either — setuid is not effective under gVisor.
#
# BOTH the pull AND the run go through module-podmand, the root helper, via a 0733
# request dir. The run cannot stay with the user either:
# the image lands in the ROOT store while the user's podman reads their own rootless
# graphroot (~/.local/share/containers/storage), so after a successful pull the user's
# `podman image exists` STILL returns false and `podman run` would try to re-pull into a
# store it cannot write. The helper passes the caller's uid/HOME/cwd/DISPLAY through, and
# runs the container as --user <caller>, so the GUI and file ownership are unchanged.
_PULL_REQ=/run/module-pulls
_rid="$(id -u).$$.$(date +%s)"

# 1. Ensure the image is in the root store. Only the helper can answer that.
echo "{image}" > "$_PULL_REQ/$_rid" 2>/dev/null \\
  || {{ echo "ERROR: cannot reach the module helper ($_PULL_REQ)" >&2; exit 1; }}
_announced=0
# Poll FAST at first, then back off. The helper answers an already-present image in
# milliseconds, so a flat `sleep 3` charged every invocation ~3 s of pure waiting — invisible
# for a GUI launched once, but a batch script calls these tools dozens of times. Measured on
# the gVisor desktop: flat sleeps made a trivial `hw_server -version` take 8.4 s against 2.6 s
# for the same raw `podman run`. Back-off keeps a genuine cold pull (10-20 min) cheap to wait
# on without spinning.
#
# ⚠ BOUND THE WAIT FOR THE FIRST ACKNOWLEDGEMENT, not the whole request. A genuine cold
# pull is 10-20 min and must be waited out, but the helper writes a status file within
# milliseconds of picking the request up — so silence past ~60 s means module-podmand is
# not running at all, not that the pull is slow. Unbounded, that case spins in sleep
# FOREVER with no output: observed for real (7+ min wall, 0:01 CPU, no error) after the
# helper died. One line of diagnosis beats an infinite silent hang.
_n=0
_waited=0
while :; do
  _st=$(cat "$_PULL_REQ/.status.$_rid" 2>/dev/null || true)
  case "$_st" in
    READY*) break ;;
    ERROR*) echo "ERROR: could not pull {image} (${{_st#ERROR }})" >&2; exit 1 ;;
    PULLING*)
      if [ "$_announced" = "0" ]; then
        echo "Fetching {spec} image (first run, this can take 10-20 min over the mesh)..." >&2
        _announced=1
      fi ;;
    "") # No status file yet — the request has not been picked up.
      # 56 iterations ≈ 60 s under the back-off below (20×0.1 + 20×0.5 + 16×3).
      if [ "$_waited" -ge 56 ]; then
        echo "ERROR: module helper not responding — no acknowledgement in ~60s." >&2
        echo "       module-podmand is not running; see /var/log/module-podmand.log." >&2
        rm -f "$_PULL_REQ/$_rid" 2>/dev/null
        exit 1
      fi
      _waited=$((_waited+1)) ;;
  esac
  _n=$((_n+1))
  if   [ "$_n" -le 20 ]; then sleep 0.1
  elif [ "$_n" -le 40 ]; then sleep 0.5
  else                        sleep 3
  fi
done
rm -f "$_PULL_REQ/.status.$_rid" 2>/dev/null || true

# 2. Ask the helper to run it. One field per line; argv is passed through verbatim and is
# never re-split or eval'd on either side.
# ⚠ USE printf BELOW, NEVER `for _a in ...; do echo "$_a"; done`. echo EATS its own flags, so
# an argument that happens to be one is silently DELETED from argv: `-n` (and `-en`, `-nE`)
# vanish entirely, `-e`/`-E` emit only a newline. Measured 2026-09-10 —
# `petalinux-create -t project --template zynqMP -n p` arrived as
#   ... --template / zynqMP / p
# with the `-n` gone, so PetaLinux's argparse reported "unrecognized arguments: p" and the
# failure read as a CLI-syntax problem in the TOOL. The identical argv via a direct
# `podman run` worked, which is what isolated it. printf is immune and needs no `--`.
# ⚠ The format spec is written DOUBLED below because this whole block is a PYTHON format
# template (see the `python3 - <<'PY'` generator above): a single escape is expanded when
# the shim is GENERATED, which put a real newline inside the quotes and split this very
# comment across two lines — the second of which the shell then tried to EXECUTE. Same
# reason `{{`/`}}` and `\\` are doubled everywhere else in the template.
_rrid="run.$(id -u).$$.$(date +%s)"
{{
  echo "{image}"
  id -u
  echo "$HOME"
  echo "$PWD"
  echo "${{DISPLAY:-:10}}"
  printf '%s\\n' {cmd} "$@"
}} > "$_PULL_REQ/$_rrid" 2>/dev/null \\
  || {{ echo "ERROR: cannot reach the module helper ($_PULL_REQ)" >&2; exit 1; }}

# Stream the container's output back to OUR stderr. Without this the tool's output only ever
# reaches /var/log/module-run.* and a batch script that parses tool output gets nothing.
# stderr, not stdout, so a script doing `vivado ... > out.txt` is not polluted by progress
# text; the helper merges the container's own stdout+stderr into this one file anyway.
# `tail -F` (not -f) because the file may not exist yet when we start — the helper creates it
# when the request is picked up, a second or two later.
_runlog="/var/log/module-run.$(id -u).$_rrid.log"
# ⚠ -s 0.1, NOT the 1 s default. `tail -F` re-stats the file on a POLL, and with the
# default 1 s poll a FAST command (vivado -version, a --help, any error path) finishes and
# is drained before tail's first read — so the tool ran, wrote its output, and the user saw
# NOTHING. Measured 2026-09-09: `vivado -version` in the desktop printed nothing at all
# while /var/log/module-run.*.log held the full version banner; reproduced 5/5 with 0 bytes
# captured. A long run (synthesis) always won the race, which is why this only ever showed
# up on quick commands.
tail -n +1 -F -s 0.1 "$_runlog" >&2 2>/dev/null &
_tailpid=$!
_cleanup() {{ kill "$_tailpid" 2>/dev/null || true; }}
trap _cleanup EXIT

# Same acknowledgement bound as the pull loop: the run itself may take hours (synthesis),
# but the helper writes RUNNING within milliseconds of picking the request up, so silence
# means it is dead rather than busy.
_n=0
_waited=0
while :; do
  _st=$(cat "$_PULL_REQ/.status.$_rrid" 2>/dev/null || true)
  case "$_st" in
    # 64 iterations ≈ 60 s under this loop's back-off (20×0.1 + 20×0.5 + 24×2).
    "") if [ "$_waited" -ge 64 ]; then
          echo "ERROR: module helper not responding — no acknowledgement in ~60s." >&2
          echo "       module-podmand is not running; see /var/log/module-podmand.log." >&2
          rm -f "$_PULL_REQ/$_rrid" 2>/dev/null
          _cleanup; trap - EXIT
          exit 1
        fi
        _waited=$((_waited+1)) ;;
    # The helper reports "DONE <rc>" — propagate that rc so `set -e` and `if` work in a
    # batch script. A bare DONE (older helper) is treated as success.
    DONE*)  _rc="${{_st#DONE }}"
            case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
            # Let `tail -F` drain the rest of the log. It polls the file every second, so a
            # flat `sleep 1` was a coin-flip on catching the last lines AND charged every run
            # a full second. Wait for the tail to go quiet instead: stop when the log stops
            # growing, capped so a pathological writer cannot hang the wrapper.
            # ⚠ THE FLOOR IS WHAT MAKES THIS CORRECT, not the stability test. "Size stopped
            # growing" is TRUE IMMEDIATELY for a command that already finished, so without a
            # minimum wait the loop broke after ~200 ms — before `tail` had polled even once
            # — and killed it with the output unread. Wait at least 3 tail polls (0.1 s each)
            # before the stability test is allowed to end the loop.
            _prev=-1; _same=0
            for _i in $(seq 1 40); do
              _sz=$(stat -c %s "$_runlog" 2>/dev/null || echo 0)
              if [ "$_sz" = "$_prev" ] && [ "$_i" -ge 4 ]; then
                _same=$((_same+1)); [ "$_same" -ge 2 ] && break
              else
                [ "$_sz" = "$_prev" ] || _same=0
                _prev=$_sz
              fi
              sleep 0.1
            done
            _cleanup; trap - EXIT
            # ⚠ `|| true` ON BOTH, AND IT IS THE EXIT CODE THAT DEPENDS ON IT. This wrapper
            # runs under `set -e`, and $_runlog lives in /var/log, which is root-owned and
            # NOT writable by a desktop user — so `rm -f` there fails with EACCES (rm -f
            # ignores a missing file, never a permission error). The script then died on
            # that line, one statement BEFORE `exit "$_rc"`, and exited 1 no matter what the
            # tool returned. Measured 2026-09-05: podmand logged `container exited rc=0` and
            # wrote `DONE 0`, `bash -x` showed `_rc=0`, and the wrapper still exited 1 —
            # i.e. every batch run by a normal user reported failure on success. Root was
            # unaffected (it can unlink in /var/log), which is why GUI use never showed it.
            # The daemon deletes its own log anyway; this is best-effort tidying.
            rm -f "$_PULL_REQ/.status.$_rrid" 2>/dev/null || true
            rm -f "$_runlog" 2>/dev/null || true
            exit "$_rc" ;;
    ERROR*) echo "ERROR: could not start {spec} (${{_st#ERROR }})" >&2
            _cleanup; trap - EXIT
            rm -f "$_PULL_REQ/.status.$_rrid" 2>/dev/null
            exit 1 ;;
  esac
  # Same fast-then-slow shape as the pull loop above: a short command returns almost
  # immediately, a long synthesis run does not need sub-second polling.
  _n=$((_n+1))
  if   [ "$_n" -le 20 ]; then sleep 0.1
  elif [ "$_n" -le 40 ]; then sleep 0.5
  else                        sleep 2
  fi
done
'''
# ── GUI entries → $HOME/.local/bin/module-<name>-<exec> + a .desktop file ─────────────
for e in (d.get('desktop_entries') or []):
    exe=e.get('exec'); nm=e.get('name',exe); cats=e.get('categories','')
    if not exe: continue
    wrap=os.path.join(bindir, f'module-{name}-{exe}')
    # `command` is the in-CONTAINER command for THIS entry (a full path/args is fine);
    # `exec` is only the short wrapper/desktop-file name. Falls back to exec.
    _write_shim(wrap, container_wrapper(spec, image, e.get('command') or exe, exe))
    de=os.path.join(appdir, f'module-{name}-{exe}.desktop')
    open(de,'w').write(f'''[Desktop Entry]
Type=Application
Name={nm}
Exec={wrap} %F
Terminal=false
Categories={cats}
''')

# ── CLI entries → $HOME/.local/module-bin/<name>/<version>/<entry> (on PATH) ──────────
# Per-module/per-version dir, NOT .local/bin: these wrappers carry the tool's OWN name
# (`vivado`, not `module-vivado-vivado`) because a batch script calls them by that name.
# Dropping them in the shared .local/bin would collide across modules and across versions,
# and could shadow a system binary for every shell — not just while the module is loaded.
shimdir = os.path.join(shimroot, name, ver)
os.makedirs(shimdir, exist_ok=True)
for e in (d.get('cli_entries') or []):
    en = str(e.get('name') or '').strip()
    cmd = e.get('command') or en
    # The manifest comes off the SMB share, which is writable by anyone who can register a
    # module. Validate the entry name before it becomes a path component so a `../` cannot
    # escape the shim dir and overwrite an arbitrary file in $HOME. Same posture as the
    # image-ref checks in module-podman.sh.
    if not en or not re.match(r'^[A-Za-z0-9._-]+$', en):
        continue
    w = os.path.join(shimdir, en)
    _write_shim(w, container_wrapper(spec, image, cmd, en))
PY
}
