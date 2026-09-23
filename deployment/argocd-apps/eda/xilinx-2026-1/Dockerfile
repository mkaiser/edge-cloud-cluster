# Xilinx 2026.1 CONTAINER module image — a SELF-CONTAINED runnable image.
#
# `module load xilinx/2026.1` generates a `podman run` wrapper (module-cli.sh) that executes
# this image inside the desktop pod. It therefore carries its OWN system libs, so a missing
# dependency is a change HERE rather than a remote-desktop base bump.

# ── Stage 1: batch install into /opt/Xilinx ───────────────────────────────────
# renovate: DISABLED for EDA apps (packageRules "EDA (2/2)") — these bases are pinned on
# purpose and each bump is a multi-hour rebuild that takes the app down. Bump by hand.
FROM docker.io/library/ubuntu:24.04 AS install

# xsetup bundles its own JRE but dlopens X/terminfo libs even in batch mode
# (package set per Tosainu/docker-vivado, noble variant).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates file locales xz-utils \
    libtinfo6 libncurses6 libx11-6 libxext6 libxrender1 libxtst6 libxi6 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8

COPY install_config.txt /install_config.txt

# /installer = bind mount of the EXTRACTED SDI (buildah bud -v
# /build-scratch/xilinx-2024-1-extracted:/installer:ro) — not part of the image.
# On config/module-name drift (AMD renames device modules between releases), fall back to
# ConfigGen and dump the generated reference config into the build log so install_config.txt
# can be fixed without shelling into the node. 2024.1 is an OLDER release than the 2026.1
# module this was ported from, so this fallback is EXPECTED to fire on the first build:
# 2024.1 still has the ML Standard/Enterprise edition split that 2026.1 dropped, and its
# device-module names are the older spellings.
#
# The bulk of the commentary for this RUN is kept HERE rather than inside it, purely so the
# command chain stays readable. (Whole-line `#` comments inside a `\`-continued chain are
# stripped by the parser before the line is joined — buildah and docker both do this, and
# this very RUN relies on it — so putting them inside would work, it would just bury the
# commands.)
#
# What the RUN does after the install, in order:
#   1. Normalize the layout to /opt/Xilinx/2026.1/<Product>. 2025.1+ — 2026.1 included —
#      install there natively, so this is a no-op here; it is kept identical to the 2024.1
#      Dockerfile, where it is load-bearing. It MUST stay all-or-nothing: moving Vivado alone
#      out of a /opt/Xilinx/<Product>/<ver> tree strands its siblings, because bin/rdiArgs.sh
#      takes RDI_INSTALLVERSION=`basename $RDI_APPROOT` and both of its Vitis_HLS lookups then
#      miss ("WARNING: Default location for XILINX_HLS not found"). That is what the 2024.1
#      image shipped with until 2026-09-03.
#   2. Rewrite the settings64 scripts, the one part of the tree that is NOT relocatable:
#      xsetup bakes absolute paths into them at install time. Also a no-op when nothing moved.
#   3. Assert the result: Vivado's settings64.sh exists and no settings64 script still names
#      a pre-normalisation path.
#   4. Split the bulk device data out so the final image ships two layers (a failed registry
#      push then resumes with less loss). The two releases ship Vivado/data DIFFERENTLY and
#      the code must handle both:
#        - 2026.1: a SYMLINK -> ../../data (a tree shared between products). A plain `mv`
#          would relocate the LINK and leave /xilinx-data dangling, so the link must be
#          removed and the RESOLVED directory moved instead; otherwise the COPY in stage 2
#          fails with `lstat "/xilinx-data"("/data"): no such file or directory`.
#        - 2024.1: a REAL directory. Confirmed on pipeline #30, which died here with
#          `rm: cannot remove '.../data': Is a directory`. `rm -f` does NOT silently no-op
#          on a directory — it exits 1, and `set -e` then kills the build after a successful
#          6-minute install. Hence the `[ -L ]` guard: unlink only when it IS a link, and
#          let `mv` relocate the real directory directly.
#      `readlink -f` covers both shapes (on a real dir it returns that dir).
#      (`du -sh` follows symlinks and so cannot verify the result — `test -d` does not, hence
#      the explicit `[ -d ] && [ ! -L ]` assertion afterwards.)
RUN set -e; \
    # ⚠ CONTAINER-AWARENESS FOR THE INSTALLER JVM. xsetup bundles its own JRE, which sizes
    # its thread pools from the HOST cpu count (24 on unibi-hclab-pcie-tb-s) while the build
    # pod is capped at cpu_limit=16 by the [eda] runner (was 8 when #46 wedged). Under runc that cap IS enforced, so
    # the JVM oversubscribes itself and, on the FULL module set, wedged in a lock convoy:
    # 40 threads on futex_do_wait, ~0% CPU, 12 KB/min of I/O, no output for 2 h after
    # writing 90 GB — with 230 min of job timeout still unused, so not a timeout
    # ActiveProcessorCount makes the JVM agree with its cgroup.
    # UseContainerSupport is the default on modern JREs but is stated explicitly because the
    # bundled JRE's vintage is not guaranteed.
    export JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=16 -XX:+UseContainerSupport"; \
    XSETUP=$(find /installer -maxdepth 2 -name xsetup -type f | head -1); \
    [ -n "$XSETUP" ] || { echo "ERROR: xsetup not found under /installer — is the SDI tar extracted?" >&2; exit 1; }; \
    echo "Using installer: $XSETUP"; \
    if ! "$XSETUP" --batch Install \
    --agree XilinxEULA,3rdPartyEULA \
    --config /install_config.txt \
    --location /opt/Xilinx; then \
    echo "==== INSTALL FAILED — generating ConfigGen reference config for comparison ===="; \
    "$XSETUP" --batch ConfigGen --product Vivado --edition 'Vivado Design Suite' || true; \
    find /root/.Xilinx -name 'install_config*.txt' -exec sh -c 'echo "---- {} ----"; cat {}' \; || true; \
    echo "==== fix install_config.txt (Edition + module names!) against the reference above ===="; \
    exit 1; \
    fi; \
    rm -rf /opt/Xilinx/.xinstall /opt/Xilinx/Downloads /opt/Xilinx/xic /root/.Xilinx; \
    for p in /opt/Xilinx/*/2026.1; do \
      [ -d "$p" ] || continue; \
      prod=$(basename "$(dirname "$p")"); \
      mkdir -p /opt/Xilinx/2026.1; \
      mv "$p" "/opt/Xilinx/2026.1/$prod"; \
      rmdir "$(dirname "$p")" || echo "NOTE: /opt/Xilinx/$prod not empty after the move"; \
    done; \
    for f in /opt/Xilinx/2026.1/*/settings64.sh /opt/Xilinx/2026.1/*/settings64.csh \
             /opt/Xilinx/2026.1/*/.settings64-*.sh /opt/Xilinx/2026.1/*/.settings64-*.csh; do \
      [ -f "$f" ] || continue; \
      sed -i 's|/opt/Xilinx/\([A-Za-z0-9_]*\)/2026\.1|/opt/Xilinx/2026.1/\1|g' "$f"; \
    done; \
    [ -f /opt/Xilinx/2026.1/Vivado/settings64.sh ] || { echo "ERROR: settings64.sh missing — unexpected install layout:" >&2; find /opt/Xilinx -maxdepth 3 -type d >&2; exit 1; }; \
    if grep -l '/opt/Xilinx/[A-Za-z0-9_]*/2026\.1' /opt/Xilinx/2026.1/*/settings64.sh /opt/Xilinx/2026.1/*/.settings64-*.sh >/dev/null 2>&1; then \
      echo "ERROR: a settings64 script still names the pre-normalisation layout:" >&2; \
      grep -l '/opt/Xilinx/[A-Za-z0-9_]*/2026\.1' /opt/Xilinx/2026.1/*/settings64.sh /opt/Xilinx/2026.1/*/.settings64-*.sh >&2; \
      exit 1; \
    fi; \
    DATA=$(readlink -f /opt/Xilinx/2026.1/Vivado/data); \
    [ -d "$DATA" ] || { echo "ERROR: device data dir not found (data -> $DATA)" >&2; ls -la /opt/Xilinx/2026.1/Vivado/data >&2; exit 1; }; \
    if [ -L /opt/Xilinx/2026.1/Vivado/data ]; then rm -f /opt/Xilinx/2026.1/Vivado/data; fi; \
    mv "$DATA" /xilinx-data; \
    [ -d /xilinx-data ] && [ ! -L /xilinx-data ] || { echo "ERROR: /xilinx-data is not a real directory" >&2; exit 1; }; \
    du -sh /opt/Xilinx /xilinx-data
# ── end of the SHARED install stage ───────────────────────────────────────────

# ── Stage 2: runnable Vivado image ────────────────────────────────────────────
# Carries its own runtime libs: the module runs as its own container, so nothing outside
# the image is on its library path.
# renovate: DISABLED for EDA apps (packageRules "EDA (2/2)") — these bases are pinned on
# purpose and each bump is a multi-hour rebuild that takes the app down. Bump by hand.
FROM docker.io/library/ubuntu:24.04

# Vivado's GUI + batch runtime deps. Batch synthesis still needs the X/render libs: the
# binaries link them unconditionally and fail at load time, not at first GUI call.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates locales \
    libtinfo6 libncurses6 libx11-6 libxext6 libxrender1 libxtst6 libxi6 \
    libpixman-1-0 \
    libxft2 libfontconfig1 libfreetype6 libsm6 libice6 libglib2.0-0 \
    libgl1 libglx0 libopengl0 libegl1 \
    libssl3t64 libcurl4t64 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# RHEL7-era SONAMEs that Xilinx 2026.1 links but Ubuntu 24.04 does not ship. Vivado bundles
# ~81 of its own libraries under lib/lnx64.o (found via settings64.sh's LD_LIBRARY_PATH);
# these four are the ONLY ones it expects from the system under a name that no longer exists:
#   libcrypto.so.10 / libssl.so.10  -> OpenSSL 1.0 sonames; 24.04 ships OpenSSL 3 (.so.3)
#   libtinfo.so.5                   -> ncurses 5; 24.04 ships .so.6
#   libcurl.so.4                    -> present as libcurl.so.4 via libcurl4t64, symlink only
# Compat symlinks onto the modern versions. This is the standard Vivado-on-modern-distro
# workaround; the ABIs are close enough for the tools that dlopen them (they are used for
# licensing/HTTP, not for the synthesis core). Verified against the real unresolved set from
# pipeline #33 rather than guessed.
#
# ⚠ DO NOT verify these with `ldconfig -p`. ldconfig indexes a library under the SONAME
# recorded INSIDE the file, not under its filename, so `libcrypto.so.10 -> libcrypto.so.3`
# never appears in the cache and the check fails on a working image (pipeline #35 died that
# way). The dynamic loader still resolves it: a binary with DT_NEEDED libcrypto.so.10 finds
# and runs against the symlink — confirmed with patchelf + ldd on a real ubuntu:24.04 pod.
# So assert the FILE resolves to a readable target, which is what actually matters.
RUN set -e; \
    ARCH_DIR=/usr/lib/x86_64-linux-gnu; \
    ln -sf "$ARCH_DIR"/libcrypto.so.3 "$ARCH_DIR"/libcrypto.so.10; \
    ln -sf "$ARCH_DIR"/libssl.so.3    "$ARCH_DIR"/libssl.so.10; \
    ln -sf "$ARCH_DIR"/libtinfo.so.6  "$ARCH_DIR"/libtinfo.so.5; \
    # ⚠ 2026.1-ONLY: VPDGLabyrinth (and friends) link libncurses.so.5, which 24.04 does not
    # ship — it has .so.6. 2024.1 needed only libtinfo.so.5, so this line is a real 2026.1
    # difference, found by the linkage gate at STEP 8 on pipeline #57, not by guesswork.
    ln -sf "$ARCH_DIR"/libncurses.so.6 "$ARCH_DIR"/libncurses.so.5; \
    [ -e "$ARCH_DIR"/libcurl.so.4 ] || ln -sf "$ARCH_DIR"/libcurl.so.4t64 "$ARCH_DIR"/libcurl.so.4; \
    ldconfig; \
    for so in libcrypto.so.10 libssl.so.10 libtinfo.so.5 libncurses.so.5 libcurl.so.4; do \
      [ -e "$ARCH_DIR/$so" ] || { echo "ERROR: compat soname $so missing from $ARCH_DIR" >&2; exit 1; }; \
      [ -r "$(readlink -f "$ARCH_DIR/$so")" ] || { echo "ERROR: $so resolves to a missing target" >&2; exit 1; }; \
    done; \
    echo "compat SONAMEs OK"

# Assert the SONAMEs Vivado links, so a missing library fails the BUILD rather than a user's
# launch hours later. Silent-at-startup missing libs cost a full build cycle on hyperlynx
# (libgomp exited 0; libOpenGL.so.0 only errored at launch).
# Comments stay ABOVE the RUN: mid-chain `#` would comment out the rest of the joined line.
RUN for so in libX11.so.6 libXext.so.6 libXrender.so.1 libXtst.so.6 libXi.so.6 \
              libtinfo.so.6 libfreetype.so.6 libfontconfig.so.1 libGL.so.1; do \
      ldconfig -p | grep -q "$so" \
        || { echo "ERROR: $so missing from the runtime image" >&2; exit 1; }; \
    done; \
    echo "runtime SONAMEs OK"
ENV LANG=en_US.UTF-8

COPY --from=install /opt/Xilinx /opt/Xilinx
COPY --from=install /xilinx-data /opt/Xilinx/2026.1/Vivado/data

# Assert the installed tree can actually LOAD in this image. This is deliberately a
# LINKAGE test, not a
# "vivado runs" test: `vivado -version` shells through a Tcl/Java launcher that can exit
# non-zero for license or $DISPLAY reasons that have nothing to do with this image, and
# failing a 4 h build on that would be a false negative.
#
# ⚠ ldd MUST RUN WITH VIVADO'S OWN LIBRARY PATH. Vivado bundles ~81 of its libraries
# (librdi_*, libxv_*, libboost_*, libtcl8.6, libprotobuf.so.32, libpython3.8, ...) under
# lib/lnx64.o and finds them at runtime via settings64.sh's LD_LIBRARY_PATH. A BARE `ldd`
# cannot see that directory, so it reports all 81 as "not found" and the assertion fails a
# perfectly good image — pipeline #33 died exactly that way, flagging 39 binaries when only
# FOUR libraries were genuinely absent. Export LD_LIBRARY_PATH first; then a remaining
# "not found" is a REAL missing system library.
#
# Implementation notes (kept OUT of the RUN below: a `#` comment inside a `\`-continued
# chain is joined onto one line by the parser and silently comments out everything after it):
#   - `ldd` on a non-ELF (Vivado's wrapper scripts) prints "not a dynamic executable"; those
#     are skipped WITHOUT `file`, which is not installed in this image.
#   - a zero examined-count fails the build: an assertion that checks nothing must not pass.
RUN set -e; \
    VROOT=/opt/Xilinx/2026.1/Vivado; \
    BIN="$VROOT/bin/unwrapped"; \
    [ -d "$BIN" ] || { echo "ERROR: $BIN missing — unexpected install layout" >&2; ls -la "$VROOT/bin" >&2; exit 1; }; \
    LIBDIR=$(ls -d "$VROOT"/lib/lnx64.o 2>/dev/null || true); \
    [ -n "$LIBDIR" ] || { echo "ERROR: $VROOT/lib/lnx64.o missing — cannot resolve bundled libs" >&2; exit 1; }; \
    export LD_LIBRARY_PATH="$LIBDIR:$LIBDIR/Default:$VROOT/tps/lnx64/python-3.8.3/lib:${LD_LIBRARY_PATH:-}"; \
    checked=0; missing=0; \
    for f in $(find "$BIN" -maxdepth 2 -type f -perm -u+x); do \
      out=$(ldd "$f" 2>/dev/null) || continue; \
      case "$out" in *"not a dynamic executable"*) continue ;; esac; \
      checked=$((checked+1)); \
      if printf '%s\n' "$out" | grep 'not found'; then \
        echo "ERROR: unresolved libraries in $f (see above)" >&2; missing=1; \
      fi; \
    done; \
    [ "$missing" -eq 0 ] || exit 1; \
    [ "$checked" -gt 0 ] || { echo "ERROR: no ELF binaries examined under $BIN — the check is not doing anything" >&2; ls -la "$BIN" >&2; exit 1; }; \
    echo "linkage OK: $checked ELF binaries under $BIN, no unresolved libraries"
# Informational only — never gates the build (see above).
RUN /opt/Xilinx/2026.1/Vivado/bin/vivado -version || \
    echo "NOTE: 'vivado -version' exited non-zero (often license/DISPLAY, not linkage) — continuing."

# Module manifest. Note the SOURCE is module.yaml (this app's own, declaring
# runtime: container + the non-default `image:` repo) but the in-image PATH is always
# /module.yaml — the broker and module CLI read that fixed location for every module.
COPY module.yaml /module.yaml
