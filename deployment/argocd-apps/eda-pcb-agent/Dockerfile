# eda-pcb-agent — a shared, root-capable KiCad workstation for one AD account.
#
# ⚠ ITS OWN IMAGE, deliberately NOT remote-desktop's base. Two reasons:
#   1. a rebuild here must never be able to take the shared LDAP desktop down, and
#      vice versa — the two images have different bump cadences and different blast radii;
#   2. that base is built FROM a VNC/Lmod/podman/broker image whose whole point is running
#      EDA module images as NESTED containers under gVisor. This pod does none of that; it
#      runs plain runc, which is what buys real setuid/FUSE for the HUMAN in the `desktop`
#      container.
#      ⚠ It does NOT let the AGENT `sudo apt install`, despite what this line used to claim:
#      s6 drops the gateway to the unprivileged `hermes` user, so apt is refused there. A
#      `kubectl exec` lands as root and will tell you otherwise — check what the GATEWAY
#      runs as. See doc/hermes-deployments.md.
#
# Built on unibi-hclab-pcie-tb-s by GitLab CI (.gitlab-ci.yml, tags:[eda]), recover-or-rebuild
# against the lab-local registry.
#
# ⚠ WHAT THIS IMAGE IS FOR: giving the agent a WORKING FIRST BOOT, not a frozen toolchain.
# KiCad, wxPython and git are baked so the pod is useful the moment it starts; everything
# after that the agent builds into $AGENT_PREFIX (~/.local) on the NFS home, which persists.
# So resist growing this file — but note the real constraint, which is the opposite of the
# old claim here: the agent CANNOT apt-install, so every system-level build dependency
# (a -dev header, a shared library) HAS to be baked, because nothing else can put it there.

# ⚠ 26.04, bumped from 24.04 on 2026-09-14 TOGETHER WITH the KiCad PPA below. Both needed a
# rebuild and an IMAGE_TAG bump, so they were done in one pass rather than two.
# Verified against upstream before the bump, because each was a plausible blocker:
#   - the KiCad 9.0 PPA publishes for resolute (26.04), not only noble;
#   - libgtk-3-0t64 still exists on resolute (3.24.52) — the `t64` suffix is a time_t
#     transition artifact and NOT a stable name, so it was the likeliest silent break;
#   - python3-wxgtk4.0 is present in resolute/universe (4.2.4).
# 26.04 is a released LTS (2026-04) supported to 2031, and three cluster nodes already run it.
# ⚠ IF THIS BUILD FAILS, suspect the base and the PPA SEPARATELY — 26.04 also moves sssd/AD,
# xrdp, Python and locales, none of which the KiCad change is about.
# renovate: tracked by "Container image tags" regex (docker datasource)
FROM docker.io/library/ubuntu:26.04
USER 0
ENV DEBIAN_FRONTEND=noninteractive

# ── KiCad from the PROJECT's PPA, not the Ubuntu archive ──────────────────────
# The archive freezes KiCad per release and never moves it: 24.04 shipped 7.0.11, which is
# two majors behind and cannot open boards saved by a newer KiCad. That gap is why
# hermes-bootstrap-configmap.yaml carries a "build KiCad from source" skill — a workaround
# that has never actually run.
#
# ⚠ PIN THE MAJOR (kicad-10.0-releases), never a rolling "latest" PPA. IMAGE_TAG is the only
# cache key for the recover-or-rebuild gate, so an unpinned source would let two builds of
# the SAME tag be different images — the exact failure invariant 3 exists to prevent.
#
# MOVED 9.0 -> 10.0 on 2026-09-19. 9.0.9 could not READ libraries authored by a newer KiCad,
# which is not a corner case: Seeed's official XIAO library ships format 20251024 and 9.0.9
# answered `Unable to load library`, so using the XIAO ESP32C6 symbol meant extracting it,
# rewriting the version string and stripping three unknown tokens
# (duplicate_pin_numbers_are_jumpers, do_not_autoplace, in_pos_files) — per vendor library,
# every time. Reference schematics at 20251028/20260508 were rejected too, which once sent a
# diagnosis down the wrong path because a known-good file read as a tooling fault.
#
# Both directions were verified in a throwaway Ubuntu 26.04 pod before this bump:
#   - KiCad 10.0.6 OPENS the Seeed library unmodified (`sym export svg` plots every symbol).
#   - KiCad 10.0.6 OPENS schematics written in the 9 format (20250114) — a 4-component file
#     from kicad-sch-api exported a netlist carrying all 4 components and their libsource
#     entries. That mattered because kicad-sch-api 0.5.6 still EMITS 20250114, so a one-way
#     upgrade would otherwise have traded a reading problem for an authoring one.
#   ⚠ KiCad 10 indents netlists differently, so `grep -c "(comp "` returns 0 on a perfectly
#     good netlist. Count `(ref "` or use the `(components` block; do not read rc alone.
#
# ⚠ python3-wxgtk4.0 below then resolves from this PPA where it offers one. That matters:
# wxPython IS KiCad's plugin API (see the note in the apt layer), and a KiCad linked
# against a mismatched wxGTK fails at PLUGIN LOAD, not at build — so a green build proves
# nothing here. Verify by loading a plugin, not by starting KiCad.
RUN apt-get update \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository -y ppa:kicad/kicad-10.0-releases \
 && apt-get purge -y software-properties-common \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# ── The desktop, the directory client, and KiCad ──────────────────────────────
# One apt layer: the union is small enough that splitting it only costs cache churn.
RUN apt-get update && apt-get install -y --no-install-recommends \
    # --- session + desktop ---
    #   xrdp/xorgxrdp is the ONLY remote protocol here (no VNC/noVNC): both humans reach
    #   this through remote-desktop's Guacamole, which speaks RDP natively.
    xrdp xorgxrdp \
    xfce4 xfce4-terminal dbus-x11 x11-utils xdg-utils \
    # --- identity: SSSD's ACTIVE DIRECTORY provider ---
    #   ⚠ sssd-ad specifically, not sssd-ldap. The AD provider reads the uidNumber AD
    #   STORES; the Authentik LDAP outpost COMPUTES uid = 5000 + pk instead, and the two
    #   diverge the moment a pk changes — at which point this pod and the fileserver
    #   disagree about the uid and the agent cannot read its own home.
    #   ⚠ Without sssd-ad there is no libsss_ad.so and the pod comes up LOOKING HEALTHY
    #   with no identity at all. See doc/ad-identity-chain.md.
    sssd-ad sssd-krb5 sssd-tools libnss-sss libpam-sss adcli krb5-user ldap-utils \
    # --- KiCad + the plugin API ---
    #   ⚠ python3-wxgtk4.0 is NOT optional garnish: KiCad's addon/plugin API IS wxPython.
    #   It is the package that could not be provided any other way here — there is no
    #   manylinux wheel for it and building it would need the full GTK/webkit toolchain.
    #   Baking it is what makes the plugin ecosystem work at all.
    kicad kicad-libraries kicad-symbols kicad-footprints python3-wxgtk4.0 \
    # --- what the agent needs to work and to bootstrap more ---
    sudo git curl wget ca-certificates locales file xz-utils unzip \
    python3-pip python3-venv \
    tmux less nano vim-tiny procps psmisc \
    # --- 3D view / rendering, and kicad-cli's headless plot path ---
    libgl1 libglu1-mesa libgtk-3-0t64 \
 && rm -rf /var/lib/apt/lists/*

# ── kicad-sch-api: the only way to AUTHOR a schematic ─────────────────────────
# `kicad-cli sch` can READ and export schematics but cannot create one, and the obvious
# third-party alternatives do not work here: `pykicad` cannot emit a `lib_symbols` block at
# all (so its output opens in KiCad showing nothing), and `kiutils` writes format 20211014,
# which this KiCad rejects. Hand-writing the s-expression is what two agent runs tried and
# failed at — a single wrong keyword like `(revision ...)` for `(rev ...)` is rejected with
# nothing but `Failed to load schematic` and no line number.
#
# kicad-sch-api emits format 20250114 (accepted by KiCad 10) and resolves symbols out of
# /usr/share/kicad/symbols itself, so the standard-library policy is enforced by the tool
# rather than left to the agent's judgement. Verified in-pod: 4 components, 40 nets, 80 real
# pins, wires supported, and a create → export → modify → re-export round trip.
#
# ⚠ It lives in a venv because Ubuntu is PEP 668 externally-managed, and the venv needs
# --system-site-packages so `pcbnew` (an apt package, not a wheel) stays importable beside
# it. Put the venv on the IMAGE, not the agent's NFS home: it pulls 78 packages / ~123 MB,
# most of it an MCP server this use has no need for, and a run-time install would make every
# cold start depend on PyPI being reachable.
#
# ⚠ Do NOT add this to PATH ahead of the system python. `pcbnew` scripts and KiCad's own
# tooling expect /usr/bin/python3; the agent invokes this interpreter explicitly.
# renovate: datasource=pypi depName=kicad-sch-api
ARG KICAD_SCH_API_VERSION=0.5.6
# ── kicad-mcp-pro: the MCP server the agent authors THROUGH ───────────────────
#
# Installed into the SAME venv on purpose: kicad-mcp-pro DEPENDS ON kicad-sch-api
# (`pip show kicad-mcp-pro` lists it under Requires), so they are designed to share an
# environment and pip resolves the pair itself. It pins fastmcp back from 4.0.5 to 3.4.7 as
# part of that resolution — upstream's own choice, not a conflict, and kicad_sch_api still
# imports afterwards (verified in the live venv before this was written).
#
# ⚠ NO SWIG. `grep -r 'import pcbnew' src/` in the upstream is ZERO and CI enforces it
# (tests/unit/test_swig_guard.py), so the authoring path is kicad-cli + s-expressions. That
# matters because SWIG pcbnew is removed in KiCad 11; this survives it.
#
# ⚠ TWO SERVERS RUN FROM THIS ONE INSTALL, on two ports — see startup-configmap.yaml.
# `build`/`write` (:3400, 17 tools) is the only authoring path and has NO `run_erc`;
# `review`/`readonly` (:3401, 24 tools) is the only verification path and has no write
# tools. Running either alone reopens the failure of 2026-09-22, in opposite directions.
# The `expert` profile is 387 tools / ~57k tokens of catalog and would eat the context
# window before the model read a single instruction — never set it here.
#
# ⚠ --profile/--mode are CLI FLAGS. Exporting KICAD_MCP_PROFILE in a wrapper that does not
# forward its environment silently yields the default profile, which looks like the server
# "not having" the authoring tools rather than like a config error.
# renovate: datasource=pypi depName=kicad-mcp-pro
ARG KICAD_MCP_PRO_VERSION=3.34.8
RUN python3 -m venv --system-site-packages /opt/kicad-py \
 && /opt/kicad-py/bin/pip install --no-cache-dir "kicad-sch-api==${KICAD_SCH_API_VERSION}" \
 && /opt/kicad-py/bin/pip install --no-cache-dir "kicad-mcp-pro==${KICAD_MCP_PRO_VERSION}" \
 && /opt/kicad-py/bin/python -c "import kicad_sch_api, pcbnew; print('kicad-sch-api + pcbnew OK')" \
 && /opt/kicad-py/bin/kicad-mcp-pro --help >/dev/null \
 && echo "kicad-mcp-pro ${KICAD_MCP_PRO_VERSION} OK"

# UTF-8: KiCad and the agent both write non-ASCII, and a POSIX locale turns that into
# mojibake in schematic text and tracebacks alike.
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ── Root for the agent: a sudoers drop-in, baked into THIS image only ─────────
# ⚠ WHY NOT LDAP. The directory carries IDENTITY only (uidNumber, gidNumber, groups);
# there is no "is root" attribute and sudo authority is a per-machine policy decision.
# The centralised alternative (sudo-ldap + sudoRole objects) would apply on EVERY
# AD-joined host that reads it — including remote-desktop, where unprivileged users have
# interactive shells, and the fileserver. Identity central, authority local.
#
#   • NAME THE USER, never a group — `%domain users` would hand root to every AD account.
#   • MODE 0440 — sudo SILENTLY ignores a drop-in that is group- or world-writable.
#   • visudo -c AT BUILD TIME — a malformed drop-in locks sudo out entirely, so fail the
#     build rather than shipping a pod nobody can escalate in.
#
# ⚠ This works only because the pod runs PLAIN RUNC. Under gVisor setuid is ineffective and
# sudo fails with "effective uid is not 0" no matter how correct this file is.
# ⚠ sudoers ships env_reset, so `sudo -E` does NOT preserve the environment without an
# explicit SETENV tag. Pass what you need as `sudo VAR=value cmd` instead.
RUN printf 'eda-pcb-agent ALL=(ALL) NOPASSWD: ALL\n' \
      > /etc/sudoers.d/eda-pcb-agent-nopasswd \
 && chmod 0440 /etc/sudoers.d/eda-pcb-agent-nopasswd \
 && visudo -cf /etc/sudoers.d/eda-pcb-agent-nopasswd

# xrdp runs as root here (single shared session, no per-user privilege separation to
# preserve) and needs these directories to exist before sesman starts.
RUN mkdir -p /var/run/xrdp /var/log/xrdp /etc/xrdp \
 && rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

# The startup script and sssd/xrdp config are mounted from startup-configmap.yaml, not
# baked — they carry cluster-specific values (realm, DC set) that must follow
# project_settings.ts without an image rebuild.
EXPOSE 3389
CMD ["/bin/bash", "-lc", "exec /startup/startup.sh"]
