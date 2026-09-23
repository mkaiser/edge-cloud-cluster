# KiCad 10.0.6 as a runnable EDA module container.
#
# Unlike every other module in this directory there is NO installer media and NO license
# server: KiCad is FOSS and comes from its own apt PPA. So this Dockerfile has no /installer
# bind mount, no .run extraction and no entrypoint that materialises a credential — only an
# apt install and the runtime plumbing a GUI needs inside a podman container.
#
# Ubuntu, not the centos:stream9 the other modules use, because the KiCad project publishes
# its releases as a Launchpad PPA and that is the only first-party binary channel with the
# matching library packages. Fedora's copr equivalent lags the release.
#
# ⚠ THE BASE RELEASE AND THE PPA ARE COUPLED. A PPA publishes per Ubuntu series, so the base
# tag below must be a series the KiCad PPA actually builds for — `add-apt-repository` happily
# adds a suite that 404s and the failure surfaces later, as "kicad has no installation
# candidate". Verified 2026-09-20 against
# ppa.launchpadcontent.net/kicad/kicad-10.0-releases/ubuntu/dists/: `resolute` (26.04) is
# published and carries kicad 10.0.6~ubuntu26.04.1 for every package installed below.
# Check the same path before moving this tag.
FROM docker.io/library/ubuntu:26.04

# ⚠ THE PPA MAJOR IS PINNED (`kicad-10.0-releases`), never a rolling `kicad-releases`.
# IMAGE_TAG is the SOLE cache key for the recover-or-rebuild gate, so an unpinned source lets
# two builds of the same tag be different images — the gate would then say "10.0.6 already
# exists" over an image that is no longer 10.0.6. The exact patch level is asserted below, so
# a PPA that moves 10.0.6 -> 10.0.7 under us FAILS THE BUILD instead of shipping silently.
#
# ⚠ kicad-symbols, kicad-footprints and kicad-templates are NOT optional. Without them a
# schematic opens with every symbol unresolved — a page of question marks, which reads as a
# corrupt file rather than a missing package, and is exactly the failure a human opening the
# agent's board would hit first. kicad-libraries is the metapackage that pulls the set; the
# individual names are listed too so a metapackage rename cannot silently drop one.
#
# Runtime deps for the GUI inside podman:
#   dbus-x11      — `dbus-launch` for the entrypoint. KiCad is wxWidgets/GTK and its
#                   embedded views retry a missing session bus; the desktop base image ships
#                   dbus and a module image does not inherit it. See kicad-entry below.
#   libgl/libglu  — 3D viewer and the OpenGL canvas both editors default to.
#   xauth         — the launcher re-keys the X cookie into the container; without the binary
#                   the GUI cannot authenticate to xrdp's X server.
#
# ⚠ THE SVG DECODER IS A HARD GUI CRASH, and the fix is NOT what it looks like. On 26.04
# the GUI aborts the moment it draws an SVG icon — opening the File menu, or loading a
# project:
#   Gtk:ERROR ensure_surface_for_gicon: assertion failed (error == NULL):
#     Failed to load .../Adwaita/scalable/status/image-missing.svg ... Bail out!
#
# gdk-pixbuf on 26.04 links libglycin-2 and routes SVG through GNOME's `glycin`, which
# sandboxes every decode by spawning `bwrap --unshare-all`. Under gVisor that cannot work:
#     $ bwrap --unshare-net ... /bin/true
#     bwrap: Creating new namespace failed: Operation not permitted
#     (with --cap-add SYS_ADMIN it gets further and dies on
#      "loopback: Failed RTM_NEWADDR" — gVisor's netstack cannot bring up lo in a nested
#      netns. --privileged does NOT help either; all three were measured.)
#
# ⚠ REMOVING THE GLYCIN SVG LOADER DOES NOT WORK, AND BOTH ATTEMPTS SHIPPED BROKEN.
# Deleting the binary left glycin-svg.conf claiming image/svg+xml, so glycin still spawned
# bwrap and failed on the missing exec — identical trace. Deleting the .conf too then gave
#     Failed to load ...: Unsupported image format
# because gdk-pixbuf offers SVG *only* through glycin here: with all glycin loaders removed
# it reports "No image loaders are configured", and librsvg2-common's classic
# libpixbufloader_svg.so is never consulted even when correctly registered in loaders.cache.
# Measured directly with gdk_pixbuf_new_from_file() — `gdk-pixbuf-query-loaders` lists the
# classic loader, and gdk-pixbuf still will not use it.
#
# ⇒ KEEP glycin, and neutralise its SANDBOX instead. glycin's sandbox mode is the GObject
# property `sandbox-selector` (Auto|Bwrap|FlatpakSpawn|NotSandboxed), set by the APPLICATION
# in code — KiCad does not set it and there is no environment variable, so it cannot be
# configured from here. What CAN be changed is the `bwrap` it invokes: the shim installed
# below drops the namespace flags (which are unavailable in this sandbox anyway) and execs
# the loader directly. Verified: gdk_pixbuf_new_from_file() on the exact icon in the crash
# trace returns a pixbuf.
#
# ⚠ This trades away glycin's kernel sandbox for the decoder. That sandbox is ALREADY
# unavailable here — bwrap cannot create the namespaces at all — so the choice is a working
# GUI or none. The decoder still runs as a separate short-lived process under the calling
# user, inside a gVisor-sandboxed pod, inside a container.
#
# ⚠ The CLI is unaffected — kicad-cli renders SVGs happily, including a 209-symbol library
# export — so NO CLI check can catch this. It needs a GUI launch, and the crash is
# INTERACTION-triggered: 40 s with a project open produced nothing, because nothing drew a
# menu.

#   adwaita-icon-theme / hicolor-icon-theme — the icons themselves. The crash above is GTK
#   failing to load its own fallback icon, so the theme must be present as well as loadable.
#
# ⚠ `universe` is enabled EXPLICITLY. The stock ubuntu:26.04 image carries only `main`, and
# libglu1-mesa lives in universe on 26.04 (verified 2026-09-20 against the archive's
# Packages.gz; the other ten packages here are all in main). Relying on add-apt-repository's
# PPA call to pull universe in as a side effect is not something to depend on.
#   fonts/locales — otherwise the UI renders with fallback metrics and boxes for glyphs.
# The PPA signing key, vendored — see the note inside the RUN below.
COPY kicad-ppa-key.asc /tmp/kicad-ppa-key.asc

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      software-properties-common gpg-agent ca-certificates; \
    add-apt-repository -y universe; \
    # ⚠ The PPA is added BY HAND, not with `add-apt-repository ppa:...`. That command asks
    # Launchpad's key service for the signing key on every build, and that service fails
    # independently of the archive: measured twice on 2026-09-21 (pipelines 41 and 45, nine
    # minutes apart) with
    #   lazr.restfulclient.errors.ServerError: HTTP Error 500
    #   b'GPGKeyTemporarilyNotFoundError'
    # while ppa.launchpadcontent.net itself answered 200 the whole time. A third-party
    # outage must not be able to fail this build, so the key is vendored beside the
    # Dockerfile (kicad-ppa-key.asc) and only the ARCHIVE is fetched at build time.
    #
    # The vendored key was read out of the previously built image and its fingerprint
    # checked against Launchpad's own API (signing_key_fingerprint):
    #   FDA854F61C4D0D9572BB95E5245D5502FAD7A805
    # Re-verify against that field if the PPA ever rotates its key.
    install -m 0644 /tmp/kicad-ppa-key.asc /etc/apt/keyrings/kicad-ppa.asc; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://ppa.launchpadcontent.net/kicad/kicad-10.0-releases/ubuntu/' \
      'Suites: resolute' \
      'Components: main' \
      'Signed-By: /etc/apt/keyrings/kicad-ppa.asc' \
      > /etc/apt/sources.list.d/kicad-ppa.sources; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      kicad \
      kicad-libraries \
      kicad-symbols \
      kicad-footprints \
      kicad-templates \
      kicad-packages3d \
      dbus-x11 \
      libgl1 libglu1-mesa libglx-mesa0 \
      xauth \
      librsvg2-common \
      adwaita-icon-theme hicolor-icon-theme \
      fonts-dejavu-core locales \
      xdg-utils; \
    rm -f /tmp/kicad-ppa-key.asc; \
    apt-get purge -y software-properties-common gpg-agent; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ⚠ Installing `locales` does NOT generate any. Ubuntu ships the package with every locale
# COMMENTED OUT in /etc/locale.gen, so a container that only sets LANG gets
#   bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)
# on every single launch, and wxWidgets then falls back to the C locale — which silently
# changes DECIMAL SEPARATOR handling in a PCB tool. Generate it explicitly.
#
# en_US.UTF-8 specifically, because module-podman.sh passes `-e LC_ALL="${LC_ALL:-en_US.UTF-8}"`
# into every module container — so that is the value this image is actually run with.
RUN set -eux; \
    sed -i -E 's/^# *(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen; \
    locale-gen; \
    locale -a | grep -q '^en_US.utf8$' \
      || { echo "ERROR: en_US.UTF-8 was not generated" >&2; exit 1; }

# Assert the EXACT version this module claims. module.yaml says 10.0.6 and the broker pins the
# image by digest under that name, so a PPA that has moved on must fail HERE — at build time,
# where it is one line in a pipeline log — rather than at a user's `module load`, where the
# only symptom is a version string nobody reads.
RUN set -eux; \
    v="$(kicad-cli version)"; \
    echo "kicad-cli version: $v"; \
    case "$v" in \
      10.0.6*) : ;; \
      *) echo "ERROR: expected KiCad 10.0.6, PPA delivered '$v'." >&2; \
         echo "       Either pin module.yaml + IMAGE_TAG to the new patch level, or pin the" >&2; \
         echo "       package version here. Do NOT ship a mismatched tag." >&2; \
         exit 1 ;; \
    esac

# Assert the in-process SVG loader is present AND registered. gdk-pixbuf only uses a loader
# that appears in loaders.cache, and if it is absent GTK falls back to the glycin/bwrap path
# that crashes here. This is invisible until someone launches the GUI, so make it a build
# failure instead.
#
# ⚠ Do NOT call `gdk-pixbuf-query-loaders --update-cache` to "make sure". librsvg2-common's
# postinst already fires a dpkg trigger that regenerates the cache once its library is
# configured, so the cache is correct by the time this runs. The binary is also NOT on PATH
# (it lives at /usr/lib/<triplet>/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders), so calling it by
# bare name fails the build with exit 127 — which is exactly what happened on 2026-09-21.
RUN set -eux; \
    ls /usr/lib/*/gdk-pixbuf-2.0/*/loaders/libpixbufloader_svg.so >/dev/null \
      || { echo "ERROR: libpixbufloader_svg.so missing — the GUI will abort on its first SVG icon" >&2; exit 1; }; \
    if ! grep -q 'svg' /usr/lib/*/gdk-pixbuf-2.0/*/loaders.cache 2>/dev/null; then \
      echo "loaders.cache has no svg entry — regenerating"; \
      QL=$(ls /usr/lib/*/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders 2>/dev/null | head -1); \
      [ -x "$QL" ] || { echo "ERROR: gdk-pixbuf-query-loaders not found to regenerate the cache" >&2; exit 1; }; \
      "$QL" --update-cache; \
    fi; \
    grep -q 'svg' /usr/lib/*/gdk-pixbuf-2.0/*/loaders.cache \
      || { echo "ERROR: svg loader not registered in loaders.cache" >&2; exit 1; }; \
    ls /usr/share/icons/Adwaita/scalable/status/image-missing.svg >/dev/null \
      || echo "NOTE: Adwaita image-missing.svg not at the expected path (theme layout changed?)"; \
    \
    # Neutralise glycin's bwrap sandbox (see the long note above). The namespace flags it
    # asks for are unavailable under gVisor, so the shim drops them and execs the payload.
    # ⚠ Argument-consuming flags must be skipped with the RIGHT ARITY or the payload argv is
    # corrupted: --chdir/--seccomp/--dbus-fd take 1, --setenv takes 2 (and is re-exported so
    # the loader still sees XDG_RUNTIME_DIR etc.), the bind/symlink forms take 2.
    mv /usr/bin/bwrap /usr/bin/bwrap.real; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# glycin sandbox shim — see the note in the kicad-10 Dockerfile.' \
      'while [ $# -gt 0 ]; do' \
      '  case "$1" in' \
      '    --unshare-all|--unshare-net|--unshare-user|--unshare-ipc|--unshare-pid|--unshare-uts|--unshare-cgroup|--die-with-parent|--clearenv) shift ;;' \
      '    --chdir|--seccomp|--dbus-fd) shift 2 ;;' \
      '    --setenv) export "$2"="$3"; shift 3 ;;' \
      '    --ro-bind|--ro-bind-try|--bind|--bind-try|--symlink) shift 3 ;;' \
      '    --dev|--tmpfs|--proc) shift 2 ;;' \
      '    --) shift; break ;;' \
      '    -*) shift ;;' \
      '    *) break ;;' \
      '  esac' \
      'done' \
      'exec "$@"' \
      > /usr/bin/bwrap; \
    chmod 0755 /usr/bin/bwrap; \
    sh -n /usr/bin/bwrap; \
    [ -x /usr/bin/bwrap.real ] \
      || { echo "ERROR: the real bwrap was not preserved" >&2; exit 1; }; \
    ls /usr/libexec/glycin-loaders/*/glycin-svg >/dev/null \
      || { echo "ERROR: glycin-svg is missing — gdk-pixbuf offers SVG only through glycin here" >&2; exit 1; }; \
    ls /usr/share/glycin-loaders/*/conf.d/glycin-svg.conf >/dev/null \
      || { echo "ERROR: glycin-svg.conf is missing — nothing will claim image/svg+xml" >&2; exit 1; }

# Assert every binary module.yaml points at. A renamed or unpackaged tool must fail the build,
# not generate a launcher that dies with "No such file or directory" for one user, months
# later. The list is the union of desktop_entries and cli_entries.
RUN set -eux; \
    for b in kicad kicad-cli eeschema pcbnew gerbview pcb_calculator bitmap2component; do \
      [ -x "/usr/bin/$b" ] || { echo "ERROR: /usr/bin/$b missing from the built image" >&2; exit 1; }; \
    done

# Assert the symbol and footprint libraries actually landed. The packages can install while
# the tables they populate are empty, and that is indistinguishable from a corrupt project
# once a user opens a schematic — so check for real content, not just the directory.
RUN set -eux; \
    ls /usr/share/kicad/symbols/*.kicad_sym >/dev/null \
      || { echo "ERROR: no symbol libraries in /usr/share/kicad/symbols" >&2; exit 1; }; \
    ls -d /usr/share/kicad/footprints/*.pretty >/dev/null \
      || { echo "ERROR: no footprint libraries in /usr/share/kicad/footprints" >&2; exit 1; }; \
    echo "symbols: $(ls /usr/share/kicad/symbols/*.kicad_sym | wc -l) libs, footprints: $(ls -d /usr/share/kicad/footprints/*.pretty | wc -l) libs"

COPY module.yaml /module.yaml

# Entrypoint shim: start a session bus, then exec the requested command.
#
# ⚠ THIS CONTAINER RUNS AS THE CALLING USER (`podman run --user $uid`, see
# remote-desktop/module-podman.sh), and HOME is the caller's AD home on NFS — not the image's
# build-time HOME. So the shim must never write into the root-owned install tree; KiCad's own
# config lands under the user's real $HOME, which is what we want (settings and library tables
# persist across launches).
#
# The bus is best-effort: `kicad-cli` in a batch job must still run if dbus is unavailable.
#
# printf, not a heredoc — the build-files ConfigMap carries this file as a YAML block scalar
# and a nested heredoc is a reliable way to break it. Single-quoted lines keep "$@" literal so
# it is evaluated when the container starts.
RUN printf '%s\n' \
      '#!/bin/bash' \
      '# Session bus for the GTK/wxWidgets GUI. Start one unless the caller shared theirs.' \
      'set -euo pipefail' \
      'if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then' \
      '  eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true' \
      '  export DBUS_SESSION_BUS_ADDRESS' \
      'fi' \
      '# Force the in-process gdk-pixbuf SVG path. KiCad is GTK3/wxWidgets, and its SVG icons' \
      '# go through gdk-pixbuf, which on 26.04 can dispatch to the newer glycin loader. That' \
      '# one sandboxes each decode with `bwrap --unshare-all`, which cannot work inside the' \
      '# gVisor-sandboxed desktop pod, and GTK turns that failure into a FATAL assertion on' \
      '# its first SVG icon.' \
      '# librsvg2-common is installed so the classic loader exists; this makes sure it is used.' \
      'export GDK_PIXBUF_MODULE_FILE="${GDK_PIXBUF_MODULE_FILE:-$(ls /usr/lib/*/gdk-pixbuf-2.0/*/loaders.cache 2>/dev/null | head -1)}"' \
      '# KiCad writes settings under $HOME; on a shared desktop that is the caller AD home.' \
      '# XDG_RUNTIME_DIR is not set inside the container and GTK warns loudly without it.' \
      'if [ -z "${XDG_RUNTIME_DIR:-}" ]; then' \
      '  XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/kicad-runtime-$(id -u)"' \
      '  mkdir -p "$XDG_RUNTIME_DIR" && chmod 0700 "$XDG_RUNTIME_DIR"' \
      '  export XDG_RUNTIME_DIR' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/kicad-entry \
    && chmod +x /usr/local/bin/kicad-entry \
    && bash -n /usr/local/bin/kicad-entry

ENV LANG=en_US.UTF-8
# The module.yaml `command`s point straight at /usr/bin/<tool>; the entrypoint wraps whichever
# one is launched so the bus exists before the GUI starts.
ENTRYPOINT ["/usr/local/bin/kicad-entry"]
