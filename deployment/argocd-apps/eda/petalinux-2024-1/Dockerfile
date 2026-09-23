# PetaLinux 2024.1 CONTAINER module image — a SELF-CONTAINED runnable image.
#
# `module load petalinux/2024.1` generates a `podman run` wrapper (module-cli.sh) that
# executes this image inside the sandboxed desktop pod. It therefore carries its OWN system
# libs, so a missing dependency is a change HERE rather than a remote-desktop base bump.
# It pays for that with an unpack on the node at first launch.

# ⚠ SINGLE STAGE, unlike the xilinx modules, and that is deliberate. Their two-stage split
# exists because xsetup needs an OLD host (ncurses 5) while the tools want a current one.
# PetaLinux has the opposite property: the packages the INSTALLER checks for are the same
# packages BitBake needs at RUN time (gcc, make, flex, bison, cpio, the python3 set …).
# Splitting stages here would mean installing the identical list twice and shipping the
# second copy anyway, so there is nothing to gain and one more place to drift.
#
# renovate: DISABLED for EDA apps (packageRules "EDA (2/2)") — these bases are pinned on
# purpose and each bump is a multi-hour rebuild that takes the app down. Bump by hand.
FROM docker.io/library/ubuntu:22.04

# BASE IS 22.04 (jammy). UG1144 for 2024.1 lists Ubuntu 20.04.x / 22.04.x as the supported
# hosts; 24.04 is not on it, and the PetaLinux installer checks the host release itself.
# Same rule as the xilinx modules: install on a release AMD supports, never "modernise" it
# to match another image.

# i386 is enabled for ONE package: zlib1g:i386, which UG1144 lists among the required host
# packages (the MicroBlaze/32-bit prebuilt tooling links it). Enabling the architecture is
# the only way to install it, and it costs one extra apt index.
RUN dpkg --add-architecture i386

# The host-package list from UG1144's "PetaLinux Tools Installation Requirements" plus the
# Yocto host tools its build needs. It is deliberately the FULL documented list rather than a
# trimmed one: the installer verifies these itself and refuses to continue when one is
# missing, and BitBake's own sanity check does the same at RUN time — so a package trimmed
# here fails a user's build hours later, not this build.
#
# ⚠ `less` AND `lsb-release` ARE NOT OPTIONAL, and --no-install-recommends is why they had
# to be named. The installer runs its own tool check and refuses outright:
#     [ERROR] You are missing the following system tools required by PetaLinux:
#      - less
#      - lsb_release
# The missing lsb_release also produces a MISLEADING line above that one:
#     Usage: grep [OPTION]... PATTERNS [FILE]...
#     [WARNING] This is not a supported OS
# — the OS check greps lsb_release's output, and with no such binary grep gets an empty
# pattern and prints its usage. The base IS a supported OS (jammy); do not chase that
# warning by changing the FROM line.
#
# ⚠ tftpd IS DELIBERATELY ABSENT, though UG1144 lists it. Its postinst registers the
# service with an inetd superserver, and with none installed dpkg exits 1 and takes the
# whole apt step — and the build — down with it (measured: the first pipeline, 2026-09-04,
# `Errors were encountered while processing: tftpd`). Nothing here can use it either: a
# TFTP server serves boot images to a board over the LAN, and this container has no
# service manager and no board. If the installer ever refuses without it, install
# `tftpd-hpa` (systemd unit, no inetd dependency) rather than putting `tftpd` back.
#
# Notable entries that look droppable and are not:
#   xterm        — checked by the installer even though nothing here opens a window
#   gcc-multilib — 32-bit host artefacts in the Zynq-7000 (arm) flow
#   python3-git / python3-jinja2 / python3-subunit / python3-pexpect — BitBake imports them
# ⚠ python3-yaml IS FOR THE SYSTEM INTERPRETER, and it is load-bearing for the bitbake
# dispatch below. The SDK sysroot ships its own PyYAML (6.0), so PetaLinux's own tooling
# never needed this package — but the dispatcher hands every bitbake-server-starting script
# to /usr/bin/python3, and `devtool` loads meta-xilinx's boot-jtag.py plugin, which does
# `import yaml`. Without it `devtool create-workspace` dies with
#   ModuleNotFoundError: No module named 'yaml'
# which is precisely the regression an earlier attempt at this fix hit and wrongly blamed on
# replacing the SDK interpreter. Measured 2026-09-18: system python had no yaml at all.
#   zstd, liblz4-tool, cpio, pax, gzip, unzip, xz-utils — sstate/rootfs packing
#   locales      — Yocto refuses to build unless the locale is a UTF-8 one (see ENV below)
# ⚠ libtinfo5 IS IN THIS LIST FOR THE .so.5 SONAME, and libncurses5-dev does NOT cover it:
# on jammy that name is a TRANSITIONAL package for libncurses-dev and ships only
# libtinfo.so.6. The XSCT tools PetaLinux bundles are PREBUILT against ncurses 5, so
# petalinux-config dies inside gen-machineconf with
#   error loading hsi package: couldn't load file "libxv_commontasks.so":
#   libtinfo.so.5: cannot open shared object file
# reporting only "[ERROR]" plus a Tcl traceback from xsdb.tcl. The missing library is named
# three frames down, so it reads as a broken .xsa rather than a missing package. Measured on
# job 72 (2026-09-10) — the eSDK extraction had already SUCCEEDED by that point.
# jammy still carries libtinfo5 (6.3-2ubuntu0.3 → libtinfo.so.5.9), so no focal backport.
#
# ⚠ dnsutils IS FOR nslookup, which gen-machineconf REQUIRES. Its xilinx_mirrors.py runs
# common_utils.check_tool('nslookup') and raises outright when it is absent:
#   [ERROR] nslookup is required but not found in the path
# petalinux-config then fails at "Generating plnxtool conf file" — the stage right after
# the layer work. Nothing else in this image pulls it in (measured: absent from both the
# base packages and the PetaLinux sysroot).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates locales file sudo less lsb-release \
    iproute2 gawk gcc g++ git make net-tools libncurses5-dev zlib1g:i386 libssl-dev \
    flex bison libselinux1 gnupg wget diffstat chrpath socat xterm autoconf libtool tar \
    unzip texinfo zlib1g-dev gcc-multilib build-essential libsdl1.2-dev libglib2.0-dev \
    screen pax gzip cpio python3 python3-pip python3-pexpect python3-git python3-jinja2 \
    python3-subunit python3-yaml xz-utils debianutils iputils-ping libegl1-mesa mesa-common-dev pylint \
    zstd liblz4-tool rsync bc lz4 \
    libtinfo5 \
    dnsutils \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ⚠ COLUMNS/LINES ARE LOAD-BEARING, NOT COSMETIC. Every petalinux-* tool is a python3
# argparse script, argparse builds a HelpFormatter on the first add_argument(), and that
# calls shutil.get_terminal_size() — which SEGFAULTS in this sandbox:
#
#   Fatal Python error: Segmentation fault
#     File ".../python3.10/shutil.py", line 1410 in get_terminal_size
#     File ".../python3.10/argparse.py", line 170 in __init__
#     File "/opt/petalinux/scripts/petalinux-util", line 120 in main
#
# So EVERY tool died with rc=139 and no output at all — measured 2026-09-05 in the gVisor
# desktop and reproduced with a plain `podman run`. The ioctl behind it (TIOCGWINSZ on a
# non-tty) normally raises OSError and falls back to 80x24; here it takes the interpreter
# down instead.
#
# shutil.get_terminal_size() reads COLUMNS and LINES FIRST and returns immediately when
# both are positive integers, so setting them skips the ioctl entirely. BOTH are required —
# either one missing or <= 0 sends it back to the syscall. The shim exports the same
# defaults, so a caller that unsets them cannot reintroduce the crash.
ENV COLUMNS=80
ENV LINES=24

# /bin/sh MUST be bash. Ubuntu points it at dash, and both PetaLinux's settings.sh and
# BitBake's sanity check reject that outright ("/bin/sh is not bash") — the installer prints
# it as a warning, the first `petalinux-build` as a hard error. dpkg-reconfigure is the
# supported way to flip it; a bare `ln -sf` is undone by the next dash upgrade.
RUN set -e; \
    echo "dash dash/sh boolean false" | debconf-set-selections; \
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash; \
    sh=$(readlink -f /bin/sh); \
    [ "$sh" = "/usr/bin/bash" ] || { echo "ERROR: /bin/sh still points at $sh" >&2; exit 1; }

# ⚠ THE INSTALLER REFUSES TO RUN AS ROOT ("PetaLinux installer should not be run as root"),
# so the install below runs as this user, which owns the install directory. It is a
# BUILD-TIME identity only: at run time module-podman.sh passes `--user <caller uid>`, so
# the container is entered by the desktop user, never by uid 1000. That is why the tree is
# made world-readable after the install.
RUN useradd -m -u 1000 -s /bin/bash petalinux \
    && mkdir -p /opt/petalinux \
    && chown petalinux:petalinux /opt/petalinux

USER petalinux

# /installer = bind mount of the directory holding the staged .run installer
# (buildah bud -v /build-scratch/petalinux-2024-1-media:/installer:ro) — never part of a
# layer. The CI job stages the single file there and makes it executable; it cannot be
# executed off the read-only NFS export directly.
#
# PLATFORMS: all four the installer offers — arm (Zynq-7000), aarch64 (Zynq UltraScale+,
# Versal), aarch64_dt and microblaze.
#
# aarch64_dt is NOT another architecture — it is the SAME silicon as aarch64 through the
# System Device Tree flow, where the hardware handoff is an SDT (AMD's Lopper-based
# description of the whole heterogeneous SoC, from Vivado/Vitis sdtgen) instead of an .xsa.
# The two flows coexist in 2024.1 and a project picks one at creation, so installing only
# `aarch64` would fail every SDT-based project on missing sources.
#
# ⚠ A PLATFORM COSTS ~17 MB, NOT GIGABYTES — measured on the built image, where
# components/yocto/{arm,aarch64,aarch64_dt} were 17 MB each out of an 11 GB install. These
# entries select Yocto RECIPE LAYERS; the bulk of the image is components/xsct (9.8 GB),
# which every platform shares. An earlier version of this comment called MicroBlaze "a
# separate multi-GB source set" and left it out on that basis — that was a guess, and the
# measurement refuted it. Installing all four is effectively free.
#
# `-y` is this installer's "automatic yes to all prompts" — the counterpart to the xilinx
# modules' `xsetup --agree XilinxEULA,3rdPartyEULA`. It answers the EULA prompts, so no
# stdin feed is needed.
#
# ⚠ --platform IS SPACE-SEPARATED ("arm aarch64"), NOT comma-separated. A comma is not a
# syntax error, it is an unknown platform:
#     ERROR: Unsupported platform specified: arm,aarch64, Use from "aarch64 arm microblaze aarch64_dt".
#
# Both facts came out of the failure path below, which dumped the installer's own --help
# into the build log on the first attempt (2026-09-04). Keep that dump: this media cannot
# be inspected from anywhere else — the artifacts export is only reachable from the [eda]
# runner — so a build log is the only place its usage text is ever visible.
RUN set -e; \
    RUNFILE=$(find /installer -maxdepth 1 -name 'petalinux-*installer.run' -type f | head -1); \
    [ -n "$RUNFILE" ] || { echo "ERROR: no petalinux-*installer.run under /installer — did the CI stage step run?" >&2; ls -la /installer >&2; exit 1; }; \
    echo "Using installer: $RUNFILE"; \
    if ! "$RUNFILE" -y \
         --dir /opt/petalinux \
         --platform "arm aarch64 aarch64_dt microblaze" \
         --log /tmp/petalinux-install.log; then \
      echo "==== INSTALL FAILED — dumping the installer usage and log ===="; \
      "$RUNFILE" --help 2>&1 | head -60 || true; \
      echo "---- tail of /tmp/petalinux-install.log ----"; \
      tail -100 /tmp/petalinux-install.log 2>/dev/null || echo "(no log written)"; \
      exit 1; \
    fi; \
    rm -f /tmp/petalinux-install.log; \
    du -sh /opt/petalinux

USER root

# Make the tree readable and traversable by ANY uid. The container is entered as the desktop
# user (an AD uid in the 5000s), not as the uid that installed it, so a mode that only suits
# the owner turns every tool into "Permission denied" — and only at run time.
#
# $PETALINUX/.petalinux is the one path PetaLinux writes back INTO the install tree (WebTalk
# and installation state), so it is created here and made sticky-world-writable. Without it
# the first tool run by a non-owner fails on a write to a directory it may not create.
RUN set -e; \
    chmod -R a+rX /opt/petalinux; \
    mkdir -p /opt/petalinux/.petalinux; \
    chmod 1777 /opt/petalinux/.petalinux

# ── WHERE THE SPACE WENT ────────────────────────────────────────────────────────
# Informational, never fails. The image is tens of GB and the only lever over that is
# `--platform`, so the per-component breakdown is the number anyone deciding whether to
# add or drop a source set actually needs — and a container image cannot be measured after
# the fact without pulling all of it. Printing it at build time puts it in the build log,
# which is also where the recreate timings live.
#
# Two levels deep over the whole tree, then a deeper pass under components/ (where the
# per-platform source sets live). `|| true` on every line: this must never fail a 40-minute
# build over a du error, and the layout is not yet confirmed for this release.
RUN set -e; \
    echo "==== INSTALLED SIZE: total ===="; \
    du -sh /opt/petalinux 2>/dev/null || true; \
    echo "==== INSTALLED SIZE: top two levels (largest last) ===="; \
    du -h --max-depth=2 /opt/petalinux 2>/dev/null | sort -h || true; \
    echo "==== INSTALLED SIZE: components/ three levels down ===="; \
    du -h --max-depth=3 /opt/petalinux/components 2>/dev/null | sort -h || true; \
    echo "==== INSTALLED SIZE: end ===="

# The shim every cli_entry points at. PetaLinux is unusable without its environment: the
# tools are not on PATH, and running one directly prints "please source settings.sh". The
# module system cannot do that sourcing for a CONTAINER module (env.source is inert — see
# module.yaml), so it happens here, once, in the image.
#
# One script, symlinked under each tool's name; it re-derives which tool to run from
# $0 (basename of the symlink it was invoked through).
#
# ⚠ IT DOES NOT HARD-CODE THE TOOL DIRECTORY, and must not. This file first assumed
# $PETALINUX/tools/common/petalinux/bin — the path older PetaLinux releases use — and the
# 2024.1 install has no `tools/` directory at all (measured: the tree is components/,
# sysroots/, scripts/, templates/, licenses/). Ask the install where its tools are instead:
# source settings.sh and let PATH answer, with /usr/local/bin (this shim dir) stripped from
# the lookup so it cannot find us and recurse forever.
#
# Written with printf rather than a heredoc: a heredoc inside a Dockerfile RUN depends on
# BuildKit-style heredoc support, and this image is built by buildah.
RUN set -e; \
    printf '%s\n' \
      '#!/bin/bash' \
      '# GENERATED by the module image build (see this app Dockerfile) — do not edit in place.' \
      '# Sources the PetaLinux environment, then execs the tool this script was called as.' \
      'set -e' \
      'cmd=$(basename "$0")' \
      '[ -r /opt/petalinux/settings.sh ] || { echo "ERROR: /opt/petalinux/settings.sh is missing from this image" >&2; exit 1; }' \
      '# ⚠ SOURCE settings.sh WITH NO CALLER ARGUMENTS. A sourced script sees the CALLERS' \
      '# positional parameters, and settings.sh reads $1 as the PetaLinux install dir. So' \
      '# `petalinux-util --version` made it take "--version" as that directory: it ran' \
      '# `readlink -f --version`, captured readlink OWN VERSION TEXT as $PETALINUX, and' \
      '# every path under it then missed —' \
      '#   .../settings.sh: line 103: readlink (GNU coreutils) 8.32 ... Written by Dmitry' \
      '#   V. Levin./.environment-setup-x86_64-petalinux-linux: No such file or directory' \
      '# Save the arguments, clear them, and pass the install dir explicitly.' \
      'args=("$@")' \
      'set --' \
      '# See the ENV block in the Dockerfile: without a positive COLUMNS *and* LINES,' \
      '# shutil.get_terminal_size() segfaults the interpreter and every tool exits 139' \
      '# with no output. Defaults only — a caller with a real terminal keeps its own.' \
      ': "${COLUMNS:=80}" "${LINES:=24}"' \
      'export COLUMNS LINES' \
      '# errexit is OFF across the source: settings.sh is not written to be sourced under' \
      '# `set -e` and returns non-zero for warnings that do not stop the tools working.' \
      '# Its stderr is kept — only the banner on stdout is dropped.' \
      'set +e' \
      '. /opt/petalinux/settings.sh /opt/petalinux >/dev/null' \
      'set -e' \
      '# Resolve the tool from the environment settings.sh just set, with /usr/local/bin' \
      '# (this shim dir) removed so the lookup cannot find us and recurse forever.' \
      'real=$(PATH=$(printf "%s" "$PATH" | tr ":" "\\n" | grep -vx /usr/local/bin | paste -sd:) command -v "$cmd" 2>/dev/null)' \
      '# Fallback for the case where settings.sh declined to set PATH (it is picky about' \
      '# who runs it). The tools live SOMEWHERE under $PETALINUX in every layout.' \
      '[ -n "$real" ] || real=$(find /opt/petalinux -maxdepth 6 \( -type f -o -type l \) -name "$cmd" 2>/dev/null | head -1)' \
      '[ -n "$real" ] && [ -x "$real" ] || { echo "ERROR: cannot locate $cmd in this image" >&2; exit 1; }' \
      '# ⚠ The PATH that reaches the tool is PetaLinux-s own: settings.sh above puts' \
      '# $PETALINUX_NATIVE_SYSROOT/usr/bin first. Do NOT try to strip it here — the real' \
      '# petalinux-config re-establishes that environment internally, so a strip in this' \
      '# shim is silently undone. The bitbake wrapper installed below is what fixes it.' \
      '# ⚠ Prepend the bitbake interpreter DISPATCHER (built above). settings.sh has just' \
      '# put the SDK python first; the dispatcher sits ahead of it and routes ONLY the' \
      '# bitbake entry points to /usr/bin/python3, leaving every other python3 call on the' \
      '# SDK interpreter that PetaLinux own tooling needs. See the long note above.' \
      'if [ -d /opt/petalinux/bbpin ]; then PATH=/opt/petalinux/bbpin:$PATH; export PATH; fi' \
      'exec "$real" "${args[@]}"' \
      > /usr/local/bin/petalinux-shim; \
    chmod 0755 /usr/local/bin/petalinux-shim

# Assert the install produced what module.yaml promises, and create the shim link for each
# tool. A renamed or missing tool fails THIS build; the alternative is a module that loads
# and then dies on the user's first command, hours after the pipeline went green.
#
# The search is a `find`, not a path: see the shim above for why this file no longer
# believes it knows where the tools live. The resolved path of each tool is printed, so the
# build log records the layout this release actually produced.
#
# ⚠ `-type f -o -type l`, and no `-perm -u+x`. A tool that turns out to be a SYMLINK into
# the sysroot — which is how SDK-style layouts usually expose them — matches neither
# `-type f` nor a permission test applied to the link itself, so the stricter form would
# report a tool as absent while it sits right there. `-x` is still checked at the point of
# use, in the shim, where it follows the link.
#
# ⚠ KEEP THIS LIST AND module.yaml's cli_entries IN SYNC. They are two copies of the same
# set by necessity (one is a k8s-side manifest, the other is baked into the image), and the
# link is what makes /usr/local/bin/<tool> exist at all — an entry missing here becomes a
# "No such file or directory" from podman.
RUN set -e; \
    [ -r /opt/petalinux/settings.sh ] || { echo "ERROR: settings.sh missing — unexpected install layout:" >&2; find /opt/petalinux -maxdepth 2 >&2; exit 1; }; \
    for t in petalinux-create petalinux-config petalinux-build petalinux-package \
             petalinux-boot petalinux-util petalinux-devtool petalinux-upgrade; do \
      real=$(find /opt/petalinux -maxdepth 6 \( -type f -o -type l \) -name "$t" 2>/dev/null | head -1); \
      [ -n "$real" ] || { echo "ERROR: $t is not anywhere under /opt/petalinux — the install did not provide it:" >&2; find /opt/petalinux -maxdepth 3 -type d >&2; exit 1; }; \
      echo "  $t -> $real"; \
      ln -sf /usr/local/bin/petalinux-shim "/usr/local/bin/$t"; \
    done; \
    echo "tool shims OK"

# Record what --platform actually installed, and flag a platform that produced nothing.
#
# ⚠ A WARNING, NOT AN ASSERTION, and deliberately so until the first green pipeline. The
# installer exits 0 having installed only the platforms it recognised, so a typo or a
# renamed platform in a future media drop is otherwise invisible — but the exact directory
# names PetaLinux 2024.1 lays down have not been seen by anyone here yet, and a hard check
# written against a GUESSED layout would fail a good 30-minute build. So this prints the
# real tree into the build log instead.
#
# TURN IT INTO A HARD FAILURE once that log shows the actual layout: replace the WARN with
# an exit 1 naming the directory that must exist per platform.
RUN set -e; \
    [ -d /opt/petalinux/components ] || { echo "ERROR: /opt/petalinux/components missing — the install did not lay down any tool tree:" >&2; find /opt/petalinux -maxdepth 2 >&2; exit 1; }; \
    echo "==== installed component tree (depth 3) ===="; \
    find /opt/petalinux/components -maxdepth 3 -type d | sort; \
    echo "==== platform check ===="; \
    for p in arm aarch64 aarch64_dt microblaze; do \
      if find /opt/petalinux -maxdepth 6 -name "*$p*" | grep -q .; then \
        echo "  $p: present"; \
      else \
        echo "  WARN: nothing under /opt/petalinux names platform '$p' — did --platform take?"; \
      fi; \
    done

# ⚠ THE BITBAKE INTERPRETER DISPATCHER. THIS IS THE FIX FOR "Unable to start bitbake
# server (None)" with a ZERO-BYTE bitbake-cookerdaemon.log.
#
# TWO INTERPRETERS, TWO INCOMPATIBLE REQUIREMENTS:
# ⚠ THE DISPATCH LIST COVERS EVERY POKY SCRIPT THAT STARTS A BITBAKE SERVER, not just the
# `bitbake*` ones. `devtool` proved it: with only the bitbake-* entries dispatched, the build
# cleared "Adding user layers", generated the machine and plnxtool conf files, and THEN died
# on `devtool create-workspace` with the same "Unable to start bitbake server (None)".
# The members were derived by grepping poky/scripts for tinfoil / bb.server / `import bb`,
# which is the rule to re-apply if a future release adds another such script.
#
#   - bitbake starts its server by re-execing bin/bitbake-server via
#     os.execl(sys.executable, ...) (bb/server/process.py:531). The SDK interpreter
#     CANNOT BE AN execl TARGET, for two independent reasons measured 2026-09-18:
#       * its `sys.executable` is the EMPTY STRING, so that execl execs nothing at all;
#       * and a re-exec'd copy dies in interpreter init anyway, because its sys.prefix
#         still points at the SDK's build-time path
#         /usr/local/oe-sdk-hardcoded-buildpath/... which does not exist here:
#           Fatal Python error: init_fs_encoding: failed to get the Python codec of
#           the filesystem encoding / ModuleNotFoundError: No module named 'encodings'
#         (PYTHONHOME is set nowhere — not by settings.sh, not by the sysroot's
#         .environment-setup script — so it only works via its own bash wrapper.)
#     Either way the server child never exists, the parent read()s EOF, prints the
#     literal None, and bitbake-cookerdaemon.log stays 0 bytes. A fork+execl test
#     SEGFAULTS (rc=139) under the SDK python and returns b"FD-OK" under the system one.
#   - petalinux-config and gen-machineconf NEED the SDK interpreter. Running them under
#     the system one corrupts the heap — "munmap_chunk(): invalid pointer" x99, failing on
#     the FIRST line before "Getting hardware description" (job 37).
#
# So neither "use the SDK python" nor "use the system python" works globally. This
# dispatcher picks per invocation: bitbake entry points get the system interpreter,
# everything else keeps the SDK one. It hooks in because those scripts start with
# `#!/usr/bin/env python3`, i.e. they resolve the interpreter from PATH at exec time.
#
# ⚠ IT IS PREPENDED TO PATH BY THE MODULE SHIM AFTER settings.sh — see /usr/local/bin
# above. Do NOT prepend it before exec-ing the tool itself: that is what job 37 did and it
# routed PetaLinux own python calls to the system interpreter too.
#
# ⚠ A DISPATCHER, NOT A REPLACEMENT OF THE SDK python3 INTERPRETER. Swapping that file for
# a different interpreter was tried and breaks gen-machineconf with "ModuleNotFoundError:
# No module named yaml". The second half of the RUN below DOES rewrite the SDK's python3
# WRAPPER, which is a different thing: it keeps the stock body verbatim and only diverts
# argv naming a bitbake entry point, so every other caller still gets the SDK interpreter
# with its own module path intact (asserted in the build: `import yaml` must still work).
#
# ⚠ AND NOT A WRAPPER WRITTEN ONTO THE EXTRACTED bitbake. petalinux-config extracts the
# eSDK DURING the same call that later runs bitbake, so there is no window to patch those
# files — before is too early, after is too late.
#
# Verified in this image against the real petalinux-config: PetaLinux own stages all run,
# it clears "Adding user layers", reaches "Generating plnxtool conf file", and
# bitbake-layers writes a 6592-byte daemon log.
RUN set -e; \
    SR=/opt/petalinux/sysroots/x86_64-petalinux-linux; \
    [ -x "$SR/usr/bin/python3.10.real" ] || { echo "ERROR: SDK python3.10.real missing" >&2; exit 1; }; \
    mkdir -p /opt/petalinux/bbpin; \
    { \
      echo '#!/bin/sh'; \
      echo '# Dispatch: bitbake gets the system python (it must pass inherited fds across'; \
      echo '# execl); everything else keeps the SDK python. See the Dockerfile note.'; \
      echo 'for a in "$@"; do'; \
      echo '  case "$a" in'; \
      echo '    */bitbake|*/bitbake-layers|*/bitbake-getvar|*/bitbake-diffsigs|*/bitbake-server|*/bitbake-worker|*/bitbake-whatchanged|*/devtool|*/recipetool|*/wic|*/oe-pkgdata-util|*/oe-check-sstate|*/oe-debuginfod|*/oe-pkgdata-browser)'; \
      echo '      exec /usr/bin/python3 "$@" ;;'; \
      echo '  esac'; \
      echo 'done'; \
      echo 'exec /opt/petalinux/sysroots/x86_64-petalinux-linux/usr/bin/python3.10.real "$@"'; \
    } > /opt/petalinux/bbpin/python3; \
    chmod 0755 /opt/petalinux/bbpin/python3; \
    cp /opt/petalinux/bbpin/python3 /opt/petalinux/bbpin/python3.10; \
    echo "dispatcher installed: $(/opt/petalinux/bbpin/python3 -V 2>&1)"; \
    \
    # ⚠ THE PATH DISPATCHER ALONE IS NOT ENOUGH — THIS SECOND HALF IS WHAT ACTUALLY
    # FIXES THE BUILD. Measured 2026-09-18 by dumping the env gen-machineconf hands to
    # its `bitbake-layers` subprocess (instrumenting RunCmd in the EXTRACTED project):
    #
    #   PATH[ 2] = /opt/petalinux/sysroots/x86_64-petalinux-linux/usr/bin   <- SDK python
    #   PATH[17] = /opt/petalinux/bbpin                                     <- dispatcher
    #   shutil.which("python3") -> .../sysroots/.../usr/bin/python3
    #
    # petalinux-config RE-ESTABLISHES the SDK environment internally, putting the sysroot
    # bin FIFTEEN entries ahead of the dispatcher the module shim prepended. So bitbake
    # ran under the SDK interpreter after all — which cannot be an execl target — and the
    # daemon log stayed 0 bytes. A/B in one run, same project, same layer:
    #   SDK bin first  -> `Unable to start bitbake server (None)`, daemon log 0 bytes
    #   bbpin first    -> rc=0, daemon log 5964 bytes, layer added
    #
    # PATH order cannot be controlled from outside (petalinux-config rebuilds it), so put
    # the SAME dispatch INSIDE the SDK's own python3 wrapper — the one chokepoint every
    # SDK python3 call passes through, at ANY PATH position.
    #
    # ⚠ THIS IS STILL A DISPATCHER, NOT A REPLACEMENT of the SDK interpreter, which is why
    # it does NOT reintroduce the `ModuleNotFoundError: No module named yaml` regression an
    # earlier attempt hit: the stock wrapper body is preserved verbatim and only argv naming
    # a bitbake entry point is diverted. Verified in this image — `import yaml` still works
    # under the SDK python after the rewrite.
    SRB="$SR/usr/bin"; \
    [ -f "$SRB/python3.10" ] || { echo "ERROR: SDK python3.10 wrapper missing" >&2; exit 1; }; \
    grep -q 'python3.10.real' "$SRB/python3.10" || { echo "ERROR: unexpected SDK wrapper body" >&2; cat "$SRB/python3.10" >&2; exit 1; }; \
    cp "$SRB/python3.10" "$SRB/python3.10.stock"; \
    { \
      echo '#!/bin/bash'; \
      echo '# GENERATED by the module image build. Stock OE SDK wrapper PLUS the bitbake'; \
      echo '# dispatch — see the long note in the app Dockerfile. The stock body is kept'; \
      echo '# verbatim below so non-bitbake callers are byte-for-byte unaffected.'; \
      echo 'realpath=`readlink -fn $0`'; \
      echo 'realdir=`dirname $realpath`'; \
      echo 'export TERMINFO_DIRS=$realdir/../../etc/terminfo:/etc/terminfo:/usr/share/terminfo:/usr/share/misc/terminfo:/lib/terminfo PYTHONNOUSERSITE=1'; \
      echo '# bitbake re-execs its server via os.execl(sys.executable, ...); this interpreter'; \
      echo '# has an EMPTY sys.executable and dies in init when re-exec-ed, so hand those'; \
      echo '# entry points to the system python instead.'; \
      echo 'for a in "$@"; do'; \
      echo '  case "$a" in'; \
      echo '    */bitbake|*/bitbake-layers|*/bitbake-getvar|*/bitbake-diffsigs|*/bitbake-server|*/bitbake-worker|*/bitbake-whatchanged|*/devtool|*/recipetool|*/wic|*/oe-pkgdata-util|*/oe-check-sstate|*/oe-debuginfod|*/oe-pkgdata-browser)'; \
      echo '      exec /usr/bin/python3 "$@" ;;'; \
      echo '  esac'; \
      echo 'done'; \
      echo 'exec -a "$0" $realdir/python3.10.real "$@"'; \
    } > "$SRB/python3.10"; \
    chmod 0755 "$SRB/python3.10"; \
    "$SRB/python3.10" -c 'import yaml' || { echo "ERROR: SDK python lost yaml after the rewrite" >&2; exit 1; }; \
    echo "SDK python3 wrapper carries the bitbake dispatch; yaml still imports"

# ⚠ THE SDK'S OWN `git` IS BROKEN ON THIS HOST AND MUST NOT WIN ON PATH.
#
# Same shape as the python3 problem above, same cause (the SDK environment puts
# $PETALINUX/sysroots/.../usr/bin first), different victim. Measured 2026-09-19:
#
#   $ git ls-remote https://github.com/lvgl/lvgl.git HEAD
#   error: git-remote-https died of signal 11          # SIGSEGV, rc=128
#
# The SDK ships git 2.37.6 built against GLIBC_2.36. This base is Ubuntu 22.04 (jammy),
# which has glibc 2.35 — and the base CANNOT move, because UG1144 lists 20.04/22.04 as the
# supported hosts and the installer checks the host release itself (see the FROM note).
# `ldd` on the SDK's git-remote-https spells it out:
#
#   .../libexec/git-core/git-remote-https: /lib/x86_64-linux-gnu/libc.so.6:
#     version `GLIBC_2.36' not found (required by .../usr/lib/libexpat.so.1)
#   libcurl.so.4 => not found
#
# so the helper loads a mixture of SDK and system libraries and dies. Pointing
# LD_LIBRARY_PATH at the SDK's own lib dir does NOT fix it — the glibc requirement is
# unsatisfiable here — which is why this is a dispatch and not a library-path tweak.
#
# WHERE IT BITES: BitBake fetches `SRC_URI = "git://...;protocol=https"` by running `git
# ls-remote`, and a recipe using ${AUTOREV} does that on EVERY parse. The failure surfaces
# as a fetcher error deep in a Python traceback —
#   ExpansionError: Failure expanding variable SRCPV ... FetchError ... exit code 128
# — which reads as a network or credential problem, not as a broken host tool.
#
# The system git (2.34.1) does the same job correctly, and Yocto's own design agrees: its
# HOSTTOOLS mechanism exists precisely so the build uses HOST binaries for host-side work.
# So shadow the SDK entry with a dispatcher to the system git. Local git operations are
# unaffected (verified: init/add/commit fine through the wrapper).
RUN set -e; \
    SRB=/opt/petalinux/sysroots/x86_64-petalinux-linux/usr/bin; \
    [ -x "$SRB/git" ] || { echo "ERROR: SDK git missing — unexpected sysroot layout" >&2; exit 1; }; \
    [ -x /usr/bin/git ] || { echo "ERROR: system git missing" >&2; exit 1; }; \
    mv "$SRB/git" "$SRB/git.sdk-broken"; \
    { \
      echo '#!/bin/sh'; \
      echo '# GENERATED by the module image build — see the long note in the app Dockerfile.'; \
      echo '# The SDK git is linked against GLIBC_2.36 and SIGSEGVs on this jammy base, so'; \
      echo '# every git call goes to the system git instead. The original is kept beside'; \
      echo '# this file as git.sdk-broken for diagnosis.'; \
      echo 'exec /usr/bin/git "$@"'; \
    } > "$SRB/git"; \
    chmod 0755 "$SRB/git"; \
    PATH="$SRB:$PATH" git --version; \
    echo "SDK git dispatches to the system git (SDK original kept as git.sdk-broken)"

# ⚠ KEEP THE SDK SYSROOT OUT OF THE PATH BITBAKE INHERITS — this is the SYSTEMIC fix that
# the python3 and git dispatchers above were each treating one symptom of.
#
# Yocto builds $TMPDIR/hosttools by resolving every name in HOSTTOOLS against
# `BB_ORIGENV["PATH"]` — the PATH bitbake was INVOKED with — and symlinking whatever it
# finds (poky `base.bbclass:setup_hosttools_dir` → `bb.utils.which(path, tool)`). PetaLinux
# sources settings.sh first, which puts $PETALINUX/sysroots/.../usr/bin at the front, so
# Yocto captured the SDK copies as "host" tools: measured 2026-09-20, 29 of 121 hosttools
# symlinks pointed into the SDK sysroot, including bash, sh, python3, make, tar, git, wget,
# awk, find and xargs.
#
# Those binaries are built against GLIBC_2.36 and this base is jammy/glibc 2.35 (and cannot
# move — UG1144 lists 20.04/22.04 and the installer checks the host release), so they
# SIGSEGV. It surfaces as a fetcher error that names neither the tool nor the sysroot:
#   wget ... failed with exit code -11, no output
#   ERROR: pseudo-native ... do_fetch: Bitbake Fetcher Error
# (-11 is SIGSEGV.) Reproduced deterministically at rc=139 via the hosttools symlink.
#
# ⚠ A PER-BINARY DISPATCHER DOES NOT SCALE HERE and must not be the answer: there are 29
# of them and a future release may capture more. Fixing PATH where hosttools are RESOLVED
# fixes every one at once, including ones that do not exist yet.
#
# ⚠ SCOPED TO THE BITBAKE INVOCATION ONLY. PetaLinux's own tooling genuinely needs the SDK
# sysroot on PATH — that is why the python3 dispatcher exists rather than a blanket
# removal — so this edits `get_bitbake_env()`, which builds the env for every bitbake run
# and nothing else. It sits beside the `unset LD_LIBRARY_PATH` already there for the same
# class of reason.
#
# ⚠ wget RUNS FINE from the SDK sysroot directly and under a plain sourced settings.sh. It
# only crashes through the hosttools symlink in the build's own PATH, so a probe that does
# not reproduce that PATH shape will wrongly clear this.
# ⚠ NO HEREDOC IN A RUN — buildah does not support them ("PYEOF;: unterminated heredoc",
# measured on pipeline 28, exit 125). Same reason the tool shim above is written with printf.
#
# ⚠ AND NOT A `sed a\` INSERT EITHER. That was tried and SILENTLY DID NOTHING: a shell
# variable is NOT expanded inside sed's append text, so `sed "/anchor/a\  $STRIP"` inserts
# the LITERAL string `$STRIP`. Three images were published before that was caught, because
# the build-time guard below used to grep the WHOLE FILE — and matched the Dockerfile's own
# text and the .orig backup, so it passed while the change was absent. Measured 2026-09-20.
#
# So: write the replacement lines with printf into a file, splice them in with awk (no
# variable interpolation anywhere), and then verify INSIDE the function.
RUN set -e; \
    BU=/opt/petalinux/scripts/libs/bitbake_utils.py; \
    [ -f "$BU" ] || { echo "ERROR: bitbake_utils.py missing — unexpected layout" >&2; exit 1; }; \
    grep -q '^        plnx_vars.BuildDir.format(proot), logfile)$' "$BU" || { echo "ERROR: get_bitbake_env tail anchor not found" >&2; sed -n '88,112p' "$BU" >&2; exit 1; }; \
    cp "$BU" "$BU.orig"; \
    printf '%s\n' \
      '    # INJECTED by the module image build — see the long note in the app Dockerfile.' \
      '    # Yocto resolves HOSTTOOLS against BB_ORIGENV["PATH"] and symlinks whatever it' \
      "    # finds into \${TMPDIR}/hosttools. Without this it captures the SDK's GLIBC_2.36" \
      '    # binaries as host tools and they SIGSEGV on this glibc-2.35 base.' \
      '    # ⚠ MUST COME AFTER the three source lines above — each of them re-adds the SDK' \
      '    # sysroot to PATH, so stripping before them is a measured no-op.' \
      '    # Seed ${TMPDIR}/hosttools with links to the SYSTEM copies BEFORE bitbake runs.' \
      '    # setup_hosttools_dir() skips any tool whose link already exists' \
      '    # (`if not os.path.exists(desttool)`), so a pre-seeded link wins without' \
      '    # touching PATH at all — which matters because the SDK sysroot must STAY on' \
      '    # PATH for PetaLinux own tools (mconf and ~249 others live only there).' \
      '    _tmpdir = plnx_utils.get_config_value(plnx_vars.TmpDirConf,' \
      '                                          plnx_vars.SysConfFile.format(proot))' \
      '    if not _tmpdir:' \
      '        _tmpdir = os.path.join(plnx_vars.BuildDir.format(proot), "tmp")' \
      '    _ht = os.path.join(_tmpdir, "hosttools")' \
      '    _sdk = os.path.join("/opt/petalinux/sysroots", "x86_64-petalinux-linux")' \
      '    try:' \
      '        os.makedirs(_ht, exist_ok=True)' \
      '        for _d in ("usr/bin", "usr/sbin", "bin", "sbin"):' \
      '            _sd = os.path.join(_sdk, _d)' \
      '            if not os.path.isdir(_sd):' \
      '                continue' \
      '            for _t in os.listdir(_sd):' \
      '                for _p in ("/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/"):' \
      '                    _sys = _p + _t' \
      '                    if os.path.isfile(_sys) and os.access(_sys, os.X_OK):' \
      '                        _lnk = os.path.join(_ht, _t)' \
      '                        if not os.path.exists(_lnk):' \
      '                            try:' \
      '                                os.symlink(_sys, _lnk)' \
      '                            except OSError:' \
      '                                pass' \
      '                        break' \
      '    except OSError:' \
      '        pass' \
      > /tmp/strip.py; \
    awk '{ print } /^        plnx_vars\.BuildDir\.format\(proot\), logfile\)$/ && !done { while ((getline l < "/tmp/strip.py") > 0) print l; done=1 }' "$BU" > "$BU.new"; \
    mv "$BU.new" "$BU"; \
    rm -f /tmp/strip.py; \
    python3 -c "import py_compile; py_compile.compile('$BU', doraise=True)"; \
    sed -n '/^def get_bitbake_env/,/^def /p' "$BU" > /tmp/fn.txt; \
    grep -q '_ht = os.path.join(_tmpdir, "hosttools")' /tmp/fn.txt || { echo "ERROR: hosttools seeding is not inside get_bitbake_env" >&2; cat /tmp/fn.txt >&2; exit 1; }; \
    grep -q 'os.symlink(_sys, _lnk)' /tmp/fn.txt || { echo "ERROR: the seeding symlink call is missing" >&2; cat /tmp/fn.txt >&2; exit 1; }; \
    grep -q 'return source_cmd' /tmp/fn.txt || { echo "ERROR: get_bitbake_env has no return" >&2; cat /tmp/fn.txt >&2; exit 1; }; \
    python3 -c "import sys; fn=open('/tmp/fn.txt').read(); sys.exit(0 if fn.index('os.symlink(_sys, _lnk)') < fn.index('return source_cmd') else 1)" || { echo "ERROR: the seeding is AFTER the return — it would never run" >&2; cat /tmp/fn.txt >&2; exit 1; }; \
    rm -f /tmp/fn.txt; \
    echo "hosttools seeding installed INSIDE get_bitbake_env, before the return"

# Informational only — never gates the build. `petalinux-util --version` shells through the
# whole environment and can exit non-zero for reasons that say nothing about the image.
RUN /usr/local/bin/petalinux-util --version || \
    echo "NOTE: 'petalinux-util --version' exited non-zero — continuing."

# Module manifest. Note the SOURCE is module.yaml (this app's own, declaring
# runtime: container + the non-default `image:` repo) but the in-image PATH is always
# /module.yaml — the broker and module CLI read that fixed location for every module.
COPY module.yaml /module.yaml
