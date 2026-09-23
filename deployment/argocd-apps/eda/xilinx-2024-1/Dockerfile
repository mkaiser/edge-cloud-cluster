# Vivado 2024.1 CONTAINER module image — a SELF-CONTAINED runnable image.
#
# `module load xilinx/2024.1` generates a `podman run` wrapper (module-cli.sh) that
# executes this image inside the sandboxed desktop pod. It therefore carries its OWN system
# libs, so a missing dependency is a change HERE rather than a remote-desktop base bump.
# It pays for that with an unpack on the node at first launch.

# ── Stage 1: batch install into /opt/Xilinx ───────────────────────────────────
# renovate: DISABLED for EDA apps (packageRules "EDA (2/2)") — these bases are pinned on
# purpose and each bump is a multi-hour rebuild that takes the app down. Bump by hand.
FROM docker.io/library/ubuntu:22.04 AS install

# BASE IS 22.04 (jammy), NOT 24.04, and that is load-bearing. AMD's supported-OS list for
# 2024.1 (UG973) stops at "Ubuntu Linux ... 22.04.3 LTS" — 24.04 is NOT a supported host for
# this release. Building on 24.04 is what made xsetup hang: it printed "It took N minutes to
# install files" and then sat in finalisation forever (pipelines #46 and #51 both idled ~2 h
# past that line and had to be cancelled; the successful #29 printed "Installation completed
# successfully" 6 s after it).
#
# The documented cause of that exact symptom is a missing ncurses 5 / tinfo 5, which xsetup
# dlopens during finalisation. 22.04 ships BOTH as real packages, so they are installed here
# by name. 24.04 ships only the .so.6 generation, and the compat symlinks this file creates
# for the RUNTIME stage are useless to xsetup — that stage is built AFTER the install stage
# has already run, so the install stage had no libncurses.so.5/libtinfo.so.5 at all.
#
# ⚠ Do NOT "modernise" this to 24.04 to match the runtime stage. The two stages are
# deliberately on different releases: install must be on a version AMD supports, runtime is
# 24.04 for a current library set. That split is why the compat symlinks below still exist.
#
# xsetup bundles its own JRE but dlopens X/terminfo libs even in batch mode
# (package set per Tosainu/docker-vivado).
# The package set is taken from the installer's OWN installLibs.sh doUbuntu() branch (read
# out of the 2026.1 media, which ships the same script), not from a blog post. Only the
# entries that a BATCH install in a container actually needs are here — no xvfb (nothing is
# displayed), no git/make/g++/libtool (no user builds happen at image-build time).
#
# python3 is REQUIRED, not optional: with Vitis enabled, xsetup's post-install step byte-
# compiles the Vitis SDK and without an interpreter the install still "succeeds" but prints
#   ######## Execution of Pre/Post Installation Tasks Failed ########
#   Error: The SDK needs a python installed
# which is a silently degraded Vitis. Observed exactly that in pipeline #64.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates file locales xz-utils \
    libtinfo5 libncurses5 \
    libtinfo6 libncurses6 libx11-6 libxext6 libxrender1 libxtst6 libxi6 \
    python3 python3-dev \
    libnss3 libgdk-pixbuf-2.0-0 libgtk-3-0 libxss1 libasound2 libsecret-1-0 \
    libyaml-dev graphviz net-tools unzip zip \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
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
#   1. Normalize the layout to /opt/Xilinx/2024.1/<Product>, for EVERY product, not just
#      Vivado. 2025.1+ install there natively; 2024.1 uses /opt/Xilinx/<Product>/<ver>.
#      Normalizing keeps the COPY paths in stage 2 static — but it MUST be all-or-nothing.
#      Moving Vivado alone (what this did until 2026-09-03) leaves a layout that matches
#      NEITHER release, and Vivado's own launcher then cannot find its siblings: bin/vivado
#      sources bin/setupEnv.sh, which sets RDI_APPROOT from the binary's location, and
#      bin/rdiArgs.sh takes RDI_INSTALLVERSION=`basename $RDI_APPROOT` — the literal string
#      "Vivado" once Vivado sits under 2024.1/, not "2024.1". Its two Vitis_HLS lookups,
#      $RDI_INSTALLROOT/Vitis_HLS/$RDI_INSTALLVERSION and $RDI_BASEROOT/Vitis_HLS, then both
#      miss and the user gets `WARNING: Default location for XILINX_HLS not found` on every
#      vivado run, with XILINX_HLS unset and Vitis_HLS/bin off PATH. XILINX_VITIS misses the
#      same way. With ALL products moved, $RDI_BASEROOT/Vitis_HLS resolves — that elif is
#      exactly the 2025.1+ branch.
#   2. Rewrite the settings64 scripts, which the move would otherwise break. They are the one
#      part of the tree that is NOT relocatable: xsetup bakes absolute paths into them at
#      install time, so Vivado's settings64.sh sources /opt/Xilinx/Vivado/2024.1/
#      .settings64-Vivado.sh and that file exports the pre-move XILINX_VIVADO. Everything
#      else finds itself relative to argv[0] via setupEnv.sh.
#   3. Assert the result: Vivado's settings64.sh exists, Vitis_HLS landed under the new root
#      (so the XILINX_HLS lookup above can succeed), and no settings64 script still names the
#      old layout.
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
    "$XSETUP" --batch ConfigGen --product Vivado --edition 'Vivado ML Standard' || true; \
    find /root/.Xilinx -name 'install_config*.txt' -exec sh -c 'echo "---- {} ----"; cat {}' \; || true; \
    echo "==== fix install_config.txt (Edition + module names!) against the reference above ===="; \
    exit 1; \
    fi; \
    rm -rf /opt/Xilinx/.xinstall /opt/Xilinx/Downloads /opt/Xilinx/xic /root/.Xilinx; \
    for p in /opt/Xilinx/*/2024.1; do \
      [ -d "$p" ] || continue; \
      prod=$(basename "$(dirname "$p")"); \
      mkdir -p /opt/Xilinx/2024.1; \
      mv "$p" "/opt/Xilinx/2024.1/$prod"; \
      rmdir "$(dirname "$p")" || echo "NOTE: /opt/Xilinx/$prod not empty after the move"; \
    done; \
    for f in /opt/Xilinx/2024.1/*/settings64.sh /opt/Xilinx/2024.1/*/settings64.csh \
             /opt/Xilinx/2024.1/*/.settings64-*.sh /opt/Xilinx/2024.1/*/.settings64-*.csh; do \
      [ -f "$f" ] || continue; \
      sed -i 's|/opt/Xilinx/\([A-Za-z0-9_]*\)/2024\.1|/opt/Xilinx/2024.1/\1|g' "$f"; \
    done; \
    [ -f /opt/Xilinx/2024.1/Vivado/settings64.sh ] || { echo "ERROR: settings64.sh missing — unexpected install layout:" >&2; find /opt/Xilinx -maxdepth 3 -type d >&2; exit 1; }; \
    [ -d /opt/Xilinx/2024.1/Vitis_HLS ] || { echo "ERROR: Vitis_HLS is not under the normalised root — the XILINX_HLS lookup will miss:" >&2; find /opt/Xilinx -maxdepth 2 -type d >&2; exit 1; }; \
    if grep -l '/opt/Xilinx/[A-Za-z0-9_]*/2024\.1' /opt/Xilinx/2024.1/*/settings64.sh /opt/Xilinx/2024.1/*/.settings64-*.sh >/dev/null 2>&1; then \
      echo "ERROR: a settings64 script still names the pre-normalisation layout:" >&2; \
      grep -l '/opt/Xilinx/[A-Za-z0-9_]*/2024\.1' /opt/Xilinx/2024.1/*/settings64.sh /opt/Xilinx/2024.1/*/.settings64-*.sh >&2; \
      exit 1; \
    fi; \
    DATA=$(readlink -f /opt/Xilinx/2024.1/Vivado/data); \
    [ -d "$DATA" ] || { echo "ERROR: device data dir not found (data -> $DATA)" >&2; ls -la /opt/Xilinx/2024.1/Vivado/data >&2; exit 1; }; \
    if [ -L /opt/Xilinx/2024.1/Vivado/data ]; then rm -f /opt/Xilinx/2024.1/Vivado/data; fi; \
    mv "$DATA" /xilinx-data; \
    [ -d /xilinx-data ] && [ ! -L /xilinx-data ] || { echo "ERROR: /xilinx-data is not a real directory" >&2; exit 1; }; \
    du -sh /opt/Xilinx /xilinx-data
# ── end of the SHARED install stage ───────────────────────────────────────────

# ── Stage 1b: a REAL OpenSSL 1.0, lifted from Rocky 8 ─────────────────────────
# Vivado's OWN bundled libthrift-0.11.0.so has DT_NEEDED libcrypto.so.10 / libssl.so.10 AND
# needs their OPENSSL_1.0.x VERSIONED SYMBOLS. A compat SYMLINK onto OpenSSL 3 cannot supply
# those: the loader opens the file, then rejects it with
#   version `libcrypto.so.10' not found (required by .../libthrift-0.11.0.so)
# which is what failed pipeline #64 on p4bm-vitisnet (Vitis Networking P4). A missing FILE and
# a missing SYMBOL VERSION look alike in `ldd` output but only the first is symlink-fixable.
#
# No Debian/Ubuntu release ships OpenSSL 1.0 any more (checked on jammy AND noble:
# libssl1.0.0, libssl1.0.2 and compat-openssl10 are all absent), so it has to come from
# somewhere else. AMD's own installLibs.sh is the authority on what this needs, and it
# resolves the question:
#   doRocky():   dnf install -y compat-openssl10        <- installed
#   doUbuntu():  #apt-get install -y compat-openssl10   <- COMMENTED OUT by AMD
# i.e. AMD requires OpenSSL 1.0 for these tools and simply has no Ubuntu package to name.
# So take theirs: Rocky 8's compat-openssl10 (1.0.2o) ships libcrypto.so.10 and libssl.so.10
# as REAL files whose recorded SONAME matches the filename and which export
# OPENSSL_1.0.1 + OPENSSL_1.0.2. Verified before writing this, not assumed.
#
# Safe to graft onto Ubuntu: their only DT_NEEDED entries are libdl/libz/libc — no RHEL-only
# dependency comes along. They are additive (distinct sonames), so nothing on the system
# links them by accident; ONLY a binary explicitly asking for .so.10 resolves here.
#
# ⚠ This is an END-OF-LIFE crypto library, deliberately scoped: it exists for Vivado's
# bundled thrift, which uses it for tool-internal RPC. Nothing here terminates TLS for
# anything the cluster exposes. Do NOT widen its use, and do not expect security updates —
# 1.0.2 has been unsupported upstream since 2019.
# renovate: DISABLED for EDA apps (packageRules "EDA (2/2)") — these bases are pinned on
# purpose and each bump is a multi-hour rebuild that takes the app down. Bump by hand.
FROM quay.io/rockylinux/rockylinux:8 AS openssl10
RUN set -e; \
    dnf install -y --setopt=install_weak_deps=False compat-openssl10 >/dev/null; \
    for so in libcrypto.so.10 libssl.so.10; do \
      [ -f "/usr/lib64/$so" ] || { echo "ERROR: /usr/lib64/$so not shipped by compat-openssl10" >&2; exit 1; }; \
    done; \
    mkdir -p /openssl10; \
    cp -a /usr/lib64/libcrypto.so.1.0* /usr/lib64/libcrypto.so.10 \
          /usr/lib64/libssl.so.1.0*    /usr/lib64/libssl.so.10    /openssl10/; \
    ls -la /openssl10

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
    libxft2 libfontconfig1 libfreetype6 libsm6 libice6 libglib2.0-0 \
    libgl1 libglx0 libopengl0 libegl1 \
    libssl3t64 libcurl4t64 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# The real OpenSSL 1.0 from stage 1b (see there for why a symlink cannot do this job).
# Landed in a DEDICATED dir + ld.so.conf.d entry rather than dropped into the multiarch dir,
# so it can never shadow the system OpenSSL 3 for anything else in the image.
COPY --from=openssl10 /openssl10/ /opt/openssl10/
RUN set -e; \
    echo /opt/openssl10 > /etc/ld.so.conf.d/zz-openssl10.conf; \
    ldconfig; \
    for so in libcrypto.so.10 libssl.so.10; do \
      [ -f "/opt/openssl10/$so" ] || { echo "ERROR: /opt/openssl10/$so missing" >&2; exit 1; }; \
      ldconfig -p | grep -q "$so" || { echo "ERROR: $so not in the ldconfig cache" >&2; exit 1; }; \
    done; \
    printf '%s\n' "openssl 1.0 bundled:" "$(ls /opt/openssl10)"

# RHEL7-era SONAMEs that Vivado 2024.1 links but Ubuntu 24.04 does not ship. Vivado bundles
# ~81 of its own libraries under lib/lnx64.o (found via settings64.sh's LD_LIBRARY_PATH);
# these are the ones it expects from the SYSTEM under a name that no longer exists:
#   libtinfo.so.5  -> ncurses 5; 24.04 ships .so.6
#   libcurl.so.4   -> present as libcurl.so.4 via libcurl4t64, symlink only
# Compat symlinks onto the modern versions, verified against the real unresolved set from
# pipeline #33 rather than guessed.
#
# ⚠ libcrypto.so.10 / libssl.so.10 are NOT in this list any more, and must not be added back
# as symlinks onto OpenSSL 3. "The ABIs are close enough; they are used for licensing/HTTP,
# not the synthesis core" holds only for the binaries pipeline #33 happened to check. It is
# FALSE for Vivado's bundled libthrift-0.11.0.so, which needs OPENSSL_1.0.x *versioned
# symbols* — a symlink satisfies the filename and then fails at load time. See stage 1b:
# they come from a real OpenSSL 1.0 in /opt/openssl10.
#
# ⚠ DO NOT verify these with `ldconfig -p`. ldconfig indexes a library under the SONAME
# recorded INSIDE the file, not under its filename, so `libcrypto.so.10 -> libcrypto.so.3`
# never appears in the cache and the check fails on a working image (pipeline #35 died that
# way). The dynamic loader still resolves it: a binary with DT_NEEDED libcrypto.so.10 finds
# and runs against the symlink — confirmed with patchelf + ldd on a real ubuntu:24.04 pod.
# So assert the FILE resolves to a readable target, which is what actually matters.
RUN set -e; \
    ARCH_DIR=/usr/lib/x86_64-linux-gnu; \
    ln -sf "$ARCH_DIR"/libtinfo.so.6  "$ARCH_DIR"/libtinfo.so.5; \
    [ -e "$ARCH_DIR"/libcurl.so.4 ] || ln -sf "$ARCH_DIR"/libcurl.so.4t64 "$ARCH_DIR"/libcurl.so.4; \
    ldconfig; \
    for so in libtinfo.so.5 libcurl.so.4; do \
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
COPY --from=install /xilinx-data /opt/Xilinx/2024.1/Vivado/data

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
    VROOT=/opt/Xilinx/2024.1/Vivado; \
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
RUN /opt/Xilinx/2024.1/Vivado/bin/vivado -version || \
    echo "NOTE: 'vivado -version' exited non-zero (often license/DISPLAY, not linkage) — continuing."

# Module manifest. Note the SOURCE is module.yaml (this app's own, declaring
# runtime: container + the non-default `image:` repo) but the in-image PATH is always
# /module.yaml — the broker and module CLI read that fixed location for every module.
COPY module.yaml /module.yaml
