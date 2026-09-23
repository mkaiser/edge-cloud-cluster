# HyperLynx 2604 — RUNNABLE container-runtime module image (podman-run inside the
# remote-desktop pod). Like every module image it is self-contained and executed as its
# own container.
#
# BASE = CentOS Stream 9 (RHEL 9 family): HyperLynx is a RHEL-targeted Siemens tool, so its
# RHEL-era libs are (mostly) present here and little side-loading is needed. Where a SONAME the tool wants is absent (e.g. libicu.so.60 — el9 ships a
# newer ICU), we still vendor it from the staged media.
#
# NOT redhat/ubi9: UBI's repos are a SUBSET of RHEL and ship no xorg-x11-server-Xvfb and no
# glibc-langpack-de, even with EPEL + CRB enabled (verified against ubi9:9.5). Xvfb is
# mandatory here, so UBI cannot build this image. Stream 9 has all of them in stock repos.
#
# BUILD INPUT: the Siemens installer media lives read-only on the SMB file server
# (install-files/hyperlynx/). The CI job extracts the tar to node-local /build-scratch and
# bind-mounts THAT at /installer BUILD-TIME ONLY (buildah -v; never committed to a layer).
# SIP's installer is a Java/AWT app with NO headless mode → Xvfb is mandatory even for the
# unattended batch replay.

# ── Stage 1: install HyperLynx from the staged media under Xvfb ──────────────────────
# renovate: tracked by "Container image tags" regex (docker datasource)
FROM quay.io/centos/centos:stream9 AS install
# Xvfb + Java/AWT X libs + tools for the batch installer (all in stock Stream 9 repos;
# epel-release + CRB are enabled for the runtime stage's motif). NOTE: bsdtar is its OWN
# package on el9 — `libarchive` is only the library (Ubuntu bundles the CLI in
# libarchive-tools), and without it this stage dies with 'bsdtar: command not found'.
RUN dnf -y install epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
      xorg-x11-server-Xvfb xorg-x11-utils \
      libXext libXrender libXtst libXi \
      fontconfig glibc-langpack-en glibc-langpack-de \
      java-11-openjdk-headless \
      tar gzip which findutils bsdtar file \
    && dnf clean all

# Install into a fixed prefix. SIP's recorded batchInstall.sh hardcodes /home/cape/... —
# map both to the target via symlinks, same as the Ubuntu app's install initContainer.
ENV TARGET=/opt/hyperlynx
RUN mkdir -p /home/cape "$TARGET" \
    && ln -sfn "$TARGET" /home/cape/hyperlynx \
    && ln -sfn /installer /home/cape/hyperlynx_install
ENV HOME=$TARGET

# batchInstall.sh exports LC_ALL=de_DE (recorded on a German host).
# Media at /installer (bind-mount): batchInstall.sh, HyperLynx2604_linux64.tar (+SHASUMS),
# and the RHEL compat libs. The tar is pre-extracted on the node by the CI step (see
# .gitlab-ci.yml) into /installer/HyperLynx2604_linux64/ so this RUN stays deterministic.
RUN --mount=type=bind,source=.,target=/ctx \
    set -eu; \
    export LC_ALL=de_DE.UTF-8 || true; \
    # Pre-seed the SALT license server as EMPTY here (never baked): registrator.ini is
    # written at RUNTIME from the injected env, not at build. The installer only needs a
    # placeholder so it does not prompt.
    printf '[defaults]\nSALT_LICENSE_SERVER=\n' > "$TARGET/registrator.ini"; \
    export CFGR_INI="$TARGET/registrator.ini" SDD_PATCH_SKIP=1; \
    # Xvfb — poll until it accepts connections (a fixed sleep races SIP's AWT init).
    Xvfb :99 -screen 0 1600x1000x24 & XVFB_PID=$!; \
    for _ in $(seq 1 30); do DISPLAY=:99 xdpyinfo >/dev/null 2>&1 && break; sleep 0.5; done; \
    DISPLAY=:99 xdpyinfo >/dev/null 2>&1 || { echo "Xvfb never became ready" >&2; exit 1; }; \
    # /installer is a READ-ONLY bind mount, so chmod cannot work here — the CI step
    # already stages both files executable on /build-scratch. Kept non-fatal in case a
    # future media copy loses the exec bit (the share itself drops it — memory
    # smb-lab-fileserver-validation), so the real failure surfaces at exec time instead.
    chmod +x /installer/batchInstall.sh /installer/HyperLynx2604_linux64/install.aol 2>/dev/null || true; \
    [ -x /installer/batchInstall.sh ] || { echo "ERROR: batchInstall.sh is not executable" >&2; exit 1; }; \
    echo "[$(date -u +%F' '%T)] replaying SIP batch install (expect ~10-20 min)..."; \
    DISPLAY=:99 /installer/batchInstall.sh; \
    kill "$XVFB_PID" 2>/dev/null || true; \
    [ -d "$TARGET/HL2604" ] || { echo "ERROR: install finished but $TARGET/HL2604 missing" >&2; exit 1; }

# Vendor the SONAMEs HyperLynx links that el9 may not provide (libicu.so.60 — Siemens RN
# workaround for the DRC engine + Channel Explorer; libunistring.so.2 for HLSA). Staged in
# the media bucket. Copy next to the binaries that link them (hlsagui.sh only puts its own
# dir on LD_LIBRARY_PATH → needs a copy in hlsa/).
RUN set -eu; SDD="$TARGET/HL2604/SDD_HOME"; \
    mkdir -p /tmp/compat; cd /tmp/compat; \
    if ls /installer/libicu-*.rpm >/dev/null 2>&1; then bsdtar -xf /installer/libicu-*.rpm; fi; \
    if ls /installer/libunistring2_*.deb >/dev/null 2>&1; then \
      mkdir -p uls && (cd uls && bsdtar -xf /installer/libunistring2_*.deb data.tar* && bsdtar -xf data.tar*); fi; \
    for d in "$SDD/common/amd64_linux/lib" "$SDD/i3dpa"; do \
      [ -d "$d" ] && cp -a /tmp/compat/usr/lib64/libicu*.so.60* "$d/" 2>/dev/null || true; done; \
    for d in "$SDD/common/amd64_linux/lib" "$SDD/hlsa"; do \
      [ -d "$d" ] && cp -a /tmp/compat/uls/usr/lib/x86_64-linux-gnu/libunistring.so.2* "$d/" 2>/dev/null || true; done; \
    # The copies above are best-effort per-directory, so verify the SONAMEs actually
    # landed somewhere. A missing libicu.so.60 does not fail the build — it makes the DRC
    # GUI exit SILENTLY at runtime (memory hyperlynx-linux-launch-quirks), which is far
    # more expensive to debug than failing here.
    ls "$SDD/common/amd64_linux/lib"/libicu*.so.60* >/dev/null 2>&1 \
      || { echo "ERROR: libicu.so.60 was not vendored — is libicu-*.rpm in the media?" >&2; exit 1; }; \
    ls "$SDD/common/amd64_linux/lib"/libunistring.so.2* >/dev/null 2>&1 \
      || { echo "ERROR: libunistring.so.2 was not vendored — is libunistring2_*.deb in the media?" >&2; exit 1; }; \
    rm -rf /tmp/compat

# ── Stage 2: the runnable image ──────────────────────────────────────────────────────
# renovate: tracked by "Container image tags" regex (docker datasource)
FROM quay.io/centos/centos:stream9
# HyperLynx runtime deps: Motif, GTK2/GL for the classic GUIs; Qt6 xcb deps + libgomp for
# the DRC/HLSA Qt GUIs (libgomp is dlopen'd by hldrcqt — missing ⇒ SILENT exit 0). EPEL for
# openmotif. NVPL not needed (no CUDA). fontconfig + locales for AWT.
#
# GL: HyperLynx bundles its own Qt6, which links the GLVND-SPLIT libraries
# (libOpenGL.so.0 / libGLX.so.0), NOT the legacy libGL.so.1 that mesa-libGL provides.
# mesa-libGL pulls in libglvnd + libglvnd-glx + libglvnd-egl as dependencies, but NOT
# libglvnd-opengl — verified in the shipped 2604 image, which had the other three and was
# missing exactly the one that ships libOpenGL.so.0. hldrcqt then dies at startup with
#   "libOpenGL.so.0: cannot open shared object file"
# so libglvnd-opengl must be named EXPLICITLY. mesa-libGL is still required for the classic
# Motif/GTK2 GUIs, so both stay. The others are listed to pin the intent, not because they
# are missing today.
#
# ⚠ dbus-x11 (for `dbus-launch`) is NOT optional here, however much it looks like desktop
# cruft in a CLI-ish image. The DRC GUI embeds a Chromium view, and Chromium's bus.cc RETRIES
# A SESSION BUS CONNECTION FOREVER when it cannot reach one — measured 2026-09-17: 22 of 32
# lines in a single launch, several per second, forever. Without this package the retry can
# never succeed because the BINARY DOES NOT EXIST; the desktop base image ships dbus and this
# one did not, and that asymmetry is what made the errors look like harmless desktop noise
# carried over from the desktop pod. The entrypoint starts the bus — see hyperlynx-entry.
RUN dnf -y install epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
      motif gtk2 mesa-libGL mesa-libGLU \
      libglvnd-opengl libglvnd-glx libglvnd-egl \
      libXext libXrender libXtst libXi libxkbfile \
      libxkbcommon-x11 libwayland-server libxcrypt-compat \
      libgomp libatomic nss alsa-lib \
      xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm \
      fontconfig glibc-langpack-en glibc-langpack-de \
      dbus-x11 \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    # Assert the GL SONAMEs that are dlopen'd at RUNTIME (ldd cannot see those, so they
    # must be listed explicitly). A missing one only surfaces when a user launches the GUI.
    && for so in libOpenGL.so.0 libGLX.so.0 libGL.so.1 libEGL.so.1; do \
         ldconfig -p | grep -q "$so" \
           || { echo "ERROR: $so missing from the runtime image" >&2; exit 1; }; \
       done

COPY --from=install /opt/hyperlynx /opt/hyperlynx
COPY module.yaml /module.yaml

# SYSTEM-LIBRARY DEPENDENCY GATE. The hand-written GL list above only covers libraries that
# are dlopen'd at runtime (ldd cannot see those). Link-time misses are caught here instead
# of one bug per release: libgomp, libicu.so.60, libunistring.so.2, libOpenGL.so.0,
# libatomic.so.1 and libxkbfile.so.1 were each found by a user hitting "error while loading
# shared libraries" at LAUNCH — one build cycle apiece.
#
# TWO THINGS MAKE THIS NON-OBVIOUS, and getting either wrong makes the gate useless:
#
# 1. ONLY SYSTEM LIBRARIES COUNT. HyperLynx ships its own libs (libhldrc_*, libsccz,
#    libtrans_*, libqexp, libolh_64), bundled Intel MKL (libmkl_*, libiomp5), a bundled
#    Python (libpython3.11) and a vendored libicuuc.so.60. Those resolve at launch through
#    the LD_LIBRARY_PATH the vendor wrappers set, which ldd does NOT apply by default — so
#    a naive ldd reports ~20 unresolved SONAMEs that are all fine (verified: it failed the
#    build on 20 false positives and zero real misses).
#
# 2. TRANSITIVE DEPS HIDE BEHIND BUNDLED LIBS. libxkbfile.so.1 is not NEEDED by any
#    executable — it is pulled in by a bundled Qt library. When ldd cannot resolve that
#    bundled lib it also cannot recurse into it, so the system dep behind it stays
#    invisible and the gate passes clean while the GUI still dies at launch.
#
# 3. BUT SCANNING EVERY BUNDLED .so IS ALSO WRONG. The payload ships optional backends it
#    never loads here — Oracle (libclntsh), MySQL, ODBC, GStreamer 0.10, Python 2.7,
#    Tcl/Tk, InfiniBand (libibverbs/libpsm2). Probing all 3527 objects reported 54
#    "missing" SONAMEs, ~53 of them dependencies of libraries nothing ever opens. A gate
#    that demands those be installed is just as useless as one that misses libxkbfile.
#
# 4. A FEW REACHABLE MISSES ARE STILL FINE. bswConsole links Intel MPI, which enumerates
#    fabric providers (InfiniBand/verbs, EFA, PSM2, UCX) at RUNTIME and silently falls back
#    to shared memory / TCP when a provider's library is absent — which is what this cluster
#    uses. libnuma is in the same class. Those are listed in /tmp/optional.txt and reported
#    but not fatal. Everything else missing FAILS the build: a Qt/X11 library really does
#    mean "the GUI cannot start", which is the whole point of the gate.
#
#    Two more sit on that list for a different reason — they are NOT installable:
#    libQt6Quick3D / libQt6Quick3DRuntimeRender are not packaged in Stream 9 at all (only
#    Qt5 is), and libmfc.so is a Siemens-internal name, not a system library. They belong
#    to the 3D viewport path; the 2D DRC/HLSA/BSW flows this module exists for do not need
#    them. If a 3D view is ever required, the fix is a bundled Qt6 Quick3D from the vendor
#    media, NOT a dnf package — so failing the build on them would just be a permanent
#    blocker with no available remedy.
#
# So: walk the dependency graph by REACHABILITY from the three launched executables,
# following only edges that actually resolve. Export the payload's own search path first so
# bundled libs resolve and the walk can continue THROUGH them (that is what makes the
# transitive libxkbfile visible). Unused backends are never reached, so they never appear.
# A SONAME that stays unresolved and is not present anywhere under the payload tree is a
# genuine system miss.
RUN set -e; \
    find /opt/hyperlynx -name '*.so*' -printf '%f\n' 2>/dev/null | sort -u > /tmp/bundled.txt; \
    find /opt/hyperlynx -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u > /tmp/libdirs.txt; \
    LD_LIBRARY_PATH="$(tr '\n' ':' < /tmp/libdirs.txt)"; export LD_LIBRARY_PATH; \
    echo "dependency gate: $(wc -l < /tmp/libdirs.txt) bundled library dirs on the probe path"; \
    printf '%s\n' \
      libibverbs.so.1 libefa.so.1 libpsm2.so.2 libucp.so.0 libnuma.so.1 \
      libQt6Quick3D.so.6 libQt6Quick3DRuntimeRender.so.6 \
      libmfc.so \
      > /tmp/optional.txt; \
    SDD=/opt/hyperlynx/HL2604/SDD_HOME; \
    : > /tmp/frontier.txt; \
    for d in "$SDD/hldrc/linux64/bin" "$SDD/hlsa" "$SDD/hlsa/linux64/bin" \
             "$SDD/hyperlynx" "$SDD/hyperlynx/linux64/bin"; do \
      [ -d "$d" ] && find "$d" -maxdepth 1 -type f -perm -u+x >> /tmp/frontier.txt 2>/dev/null; \
    done; \
    sort -u /tmp/frontier.txt -o /tmp/frontier.txt; \
    [ -s /tmp/frontier.txt ] \
      || { echo "ERROR: dependency gate found no entry-point binaries — the payload layout changed" >&2; exit 1; }; \
    echo "dependency gate: $(wc -l < /tmp/frontier.txt) entry-point binaries"; \
    : > /tmp/seen.txt; : > /tmp/missing.txt; \
    while [ -s /tmp/frontier.txt ]; do \
      : > /tmp/next.txt; \
      while read -r f; do \
        head -c4 "$f" 2>/dev/null | grep -q ELF || continue; \
        grep -qxF "$f" /tmp/seen.txt && continue; \
        echo "$f" >> /tmp/seen.txt; \
        ldd "$f" 2>/dev/null | while read -r line; do \
          case "$line" in \
            *"not found"*) echo "${line%% *}" >> /tmp/raw.txt ;; \
            *"=>"*) p="${line#*=> }"; p="${p%% (*}"; \
                    case "$p" in /opt/hyperlynx/*) echo "$p" >> /tmp/next.txt ;; esac ;; \
          esac; \
        done; \
      done < /tmp/frontier.txt; \
      sort -u /tmp/next.txt > /tmp/frontier.txt 2>/dev/null || : > /tmp/frontier.txt; \
    done; \
    echo "dependency gate: walked $(wc -l < /tmp/seen.txt) reachable ELF objects"; \
    if [ -s /tmp/raw.txt ]; then \
      sort -u /tmp/raw.txt | while read -r so; do \
        grep -qxF "$so" /tmp/bundled.txt && continue; \
        grep -qxF "$so" /tmp/optional.txt && { echo "  optional, absent (ok): $so"; continue; }; \
        echo "$so" >> /tmp/missing.txt; \
      done; \
    fi; \
    if [ -s /tmp/missing.txt ]; then \
      echo "ERROR: SYSTEM libraries missing from the runtime image:" >&2; \
      sort -u /tmp/missing.txt >&2; \
      echo "These are not shipped by HyperLynx — add the providing package(s) above." >&2; \
      exit 1; \
    fi; \
    echo "dependency gate: no system library is missing"; \
    rm -f /tmp/missing.txt /tmp/raw.txt /tmp/bundled.txt /tmp/libdirs.txt \
          /tmp/frontier.txt /tmp/next.txt /tmp/seen.txt

# /home/cape symlink some installed files embed (recorded batch paths).
RUN mkdir -p /home/cape && ln -sfn /opt/hyperlynx /home/cape/hyperlynx

# In-container launch wrappers (one per module.yaml desktop_entry command). These carry
# the launch quirks (memory hyperlynx-linux-launch-quirks): SDD_PATCH_SKIP, QTWEBENGINE
# sandbox off (Qt WebEngine zygote refuses root), stale single-instance socket cleanup,
# and hlsagui's mandatory cd. Kept INSIDE the image so the module.yaml `command` is a
# stable path regardless of the host.
# NOTE: written with printf, NOT heredocs. buildah's Dockerfile parser consumes only the
# FIRST heredoc in a RUN and then reads the next `cat` as a new instruction, failing with
# `Unknown instruction: "CAT"`. \$@ / \$SDD stay escaped so they land literally in the
# wrapper instead of being expanded at build time.
RUN set -eu; SDD=/opt/hyperlynx/HL2604/SDD_HOME; BIN="$SDD/bin"; \
    mkdir -p "$BIN"; \
    printf '%s\n' \
      '#!/bin/bash' \
      'export SDD_PATCH_SKIP=1 QTWEBENGINE_DISABLE_SANDBOX=1' \
      '# stale single-instance socket → the GUI would exit silently' \
      'rm -f /tmp/hldrcqt_2604 2>/dev/null || true' \
      "exec bash $SDD/hldrc/linux64/bin/HyperLynxDRC \"\$@\"" \
      > "$BIN/run-drc"; \
    printf '%s\n' \
      '#!/bin/bash' \
      'export SDD_PATCH_SKIP=1 QTWEBENGINE_DISABLE_SANDBOX=1' \
      "cd $SDD/hlsa && exec ./hlsagui.sh \"\$@\"" \
      > "$BIN/run-hlsa"; \
    printf '%s\n' \
      '#!/bin/bash' \
      'export SDD_PATCH_SKIP=1' \
      "exec $SDD/hyperlynx/run_bswConsole \"\$@\"" \
      > "$BIN/run-bsw"; \
    chmod +x "$BIN/run-drc" "$BIN/run-hlsa" "$BIN/run-bsw"; \
    # Fail now if a wrapper is empty/malformed rather than at first GUI launch.
    for w in run-drc run-hlsa run-bsw; do \
      head -1 "$BIN/$w" | grep -q '^#!/bin/bash$' \
        || { echo "ERROR: $BIN/$w was not written correctly" >&2; exit 1; }; done

# registrator.ini is (re)written at RUNTIME from the injected SALT_LICENSE_SERVER env by
# an entrypoint shim, so the license value is NEVER baked into the image.
#
# ⚠ IT IS WRITTEN TO $TMPDIR, NOT TO /opt/hyperlynx. The launcher runs the container as the
# CALLING user (`podman run --user $uid`, see remote-desktop/module-podman.sh) while the whole
# /opt/hyperlynx tree is root-owned 0755, so a redirect into it fails with
# `registrator.ini: Permission denied`. That failure used to be SILENT and cost a debug
# session: the shim had no `set -e`, so the redirect failed, CFGR_INI was never exported, the
# baked placeholder with an EMPTY SALT_LICENSE_SERVER= stayed in place, and the GUI got as far
# as its splash screen before dying on a license error. Do not "fix" that by chmod-ing the
# install tree or by dropping --user: a writable path is the fix.
#
# printf, not a heredoc — see the note above the run-* wrappers. Single-quoted lines keep
# $SALT_LICENSE_SERVER / $@ literal so they are evaluated when the container starts.
RUN printf '%s\n' \
      '#!/bin/bash' \
      '# Write the license file from the injected env (never baked), then exec the cmd.' \
      'set -euo pipefail' \
      'if [ -n "${SALT_LICENSE_SERVER:-}" ]; then' \
      '  CFGR_INI="${TMPDIR:-/tmp}/registrator.$(id -u).ini"' \
      "  printf '[defaults]\\nSALT_LICENSE_SERVER=%s\\n' \"\$SALT_LICENSE_SERVER\" > \"\$CFGR_INI\"" \
      '  export CFGR_INI LM_LICENSE_FILE="$SALT_LICENSE_SERVER"' \
      'else' \
      '  echo "hyperlynx-entry: SALT_LICENSE_SERVER is unset — the tool will have no license" >&2' \
      'fi' \
      '# Session bus for the DRC GUI. Chromium retries a missing bus forever (see the' \
      '# dbus-x11 note above), so start one unless the caller already shared theirs.' \
      '# Best-effort: a headless/CLI use of this image must still run if dbus is absent.' \
      'if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then' \
      '  eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true' \
      '  export DBUS_SESSION_BUS_ADDRESS' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/hyperlynx-entry \
    && chmod +x /usr/local/bin/hyperlynx-entry \
    && bash -n /usr/local/bin/hyperlynx-entry
ENV LANG=en_US.UTF-8
# The module.yaml `command`s call the run-* wrappers directly; the entrypoint shim wraps
# them so the license file is materialised first regardless of which GUI is launched.
ENTRYPOINT ["/usr/local/bin/hyperlynx-entry"]
