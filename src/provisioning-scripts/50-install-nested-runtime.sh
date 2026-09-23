#!/bin/bash
# 50-install-nested-runtime.sh — nested-container runtime enablement for mesh nodes.
#
# SHARED mesh-join logic — single source of truth, consumed by BOTH:
#   - scripts/provisioning/generateProvisioningScripts.sh (manual provisioning)
#   - src/nodes-k3s-mesh.ts (Pulumi command.remote.Command)
#
# CONDITIONAL step: run ONLY on nodes that declare `nestedRuntime` (project_settings
# ComputeNodeMesh.nestedRuntime). Installs a containerd runtime handler so a pod on
# this node can run inner OCI containers WITHOUT being privileged — the remote-desktop
# Model-B path (a module runs as its own container inside the desktop pod; HyperLynx).
#
# Supported: "gvisor" (runsc userspace kernel). It needs no /dev/kvm.
# sysbox-ce was evaluated and is broken on Ubuntu 25.10 / kernel 6.17 / k3s containerd 2.3
# (sysfs "mount through procfd" EPERM); see doc/nested-container-runtime.md.
#
# Runs BEFORE 40-join-cluster.sh: the k3s agent must (re)start AFTER the containerd
# drop-in exists so the generated config imports the handler. On a re-provision
# where the agent is already installed, this script restarts it itself.
#
# Usage: 50-install-nested-runtime.sh --runtime=gvisor
# Run as root or with sudo.

set -euo pipefail
trap 'echo "ERROR: 50-install-nested-runtime.sh failed at line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

RUNTIME="gvisor"
for arg in "$@"; do
  case "$arg" in
    --runtime=*) RUNTIME="${arg#*=}" ;;
    *) echo "WARNING: 50-install-nested-runtime.sh: ignoring unknown arg '$arg'" >&2 ;;
  esac
done

case "$RUNTIME" in
  gvisor) ;;
  *)
    echo "ERROR: unsupported nestedRuntime '$RUNTIME' (gvisor)" >&2
    exit 1
    ;;
esac

echo "=== Nested-container runtime enablement (runtime=${RUNTIME}) ==="

# The handler writes its own drop-in under config-v3.toml.d/, so it composes with any
# other handler k3s already knows about.

DROPIN_DIR=/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
mkdir -p "$DROPIN_DIR"

# ── 1. Install gVisor (runsc) ─────────────────────────────────────────────────
# gVisor is a userspace kernel — no KVM needed, containers start in ~0.7s, and it uses
# native overlay storage.
GVISOR_ARCH="$(uname -m)"
echo "Installing gVisor (runsc) for ${GVISOR_ARCH}…"
apt-get install -y curl

# ⚠ ALREADY-INSTALLED IS A SUCCESS, NOT A REASON TO RE-DOWNLOAD. 00-cleanup-node.sh does not
# remove /usr/local/bin, so on a re-provision the binaries are usually still there. Fetching
# them again turns a working node into a broken one the moment the download path is
# unavailable — which is exactly what happened on 2026-09-16 (see the egress note below).
# ⚠ "Present" means it can actually START A SANDBOX, not that the two binaries exist. A node
# left with runsc but no gvisor-bin/ sidecars satisfies a file check and still fails every
# pod, and the skip would then make the re-provision a no-op that cannot repair it.
if [ -x /usr/local/bin/runsc ] && [ -x /usr/local/bin/containerd-shim-runsc-v1 ] \
   && /usr/local/bin/runsc --network=none --ignore-cgroups do /bin/true >/dev/null 2>&1; then
  echo "runsc already present and working: $(/usr/local/bin/runsc --version 2>/dev/null | head -n1) — skipping download."
else

# ⚠ EGRESS IS NOT GUARANTEED. Measured 2026-09-16 from the unibi-hclab boxes: TCP to
# storage.googleapis.com:443 connects and is then RESET during the TLS Client Hello (SNI
# filtering on the university network), while github.com from the same box returns 200. A
# single un-retried curl there wiped runsc off two nodes that had been running gVisor
# workloads the day before. So: retry, then fall back to the GitHub release mirror, and fail
# LOUDLY rather than leaving a node that claims a runtime it does not have.
tmp=$(mktemp -d)
CURL_RETRY=(--retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 15)

# SOURCE 1 — storage.googleapis.com, bare binaries each with a .sha512 beside it.
# Upstream's documented path, and the fastest when it is reachable.
fetch_google() {
  local base="https://storage.googleapis.com/gvisor/releases/release/latest/${GVISOR_ARCH}" f
  for f in runsc containerd-shim-runsc-v1; do
    curl -fsSL "${CURL_RETRY[@]}" -o "$tmp/$f" "${base}/${f}" || return 1
    curl -fsSL "${CURL_RETRY[@]}" -o "$tmp/$f.sha512" "${base}/${f}.sha512" || return 1
    ( cd "$tmp" && sha512sum -c "$f.sha512" ) >/dev/null 2>&1 || {
      echo "  WARNING: checksum mismatch for $f (googleapis)" >&2; return 1; }
  done
}

# SOURCE 2 — the GitHub release, which ships a TARBALL plus a SHA512SUMS covering it.
# ⚠ Different layout, not the same files under another host: the assets are
# gvisor-<arch>.tar.bz2 (runsc and containerd-shim-runsc-v1 sit at its top level) and one
# SHA512SUMS for the whole release. Do NOT "simplify" this into the loop above.
# Resolving `latest` needs the API because the assets are versioned (release-YYYYMMDD.N)
# and there is no stable /releases/latest/download/<file> path for them — that 404s.
fetch_github() {
  local api="https://api.github.com/repos/google/gvisor/releases/latest" tb url sums
  tb="gvisor-${GVISOR_ARCH}.tar.bz2"
  url="$(curl -fsSL "${CURL_RETRY[@]}" "$api" 2>/dev/null \
         | grep -oE "\"browser_download_url\": \"[^\"]*${tb}\"" | head -1 | cut -d'"' -f4)"
  [ -n "$url" ] || { echo "  WARNING: could not resolve $tb from the GitHub API" >&2; return 1; }
  sums="${url%/*}/SHA512SUMS"
  curl -fsSL "${CURL_RETRY[@]}" -o "$tmp/$tb" "$url" || return 1
  curl -fsSL "${CURL_RETRY[@]}" -o "$tmp/SHA512SUMS" "$sums" || return 1
  # SHA512SUMS covers every asset in the release; check only the one we downloaded.
  ( cd "$tmp" && grep " [ *]\?${tb}\$" SHA512SUMS | sha512sum -c - ) >/dev/null 2>&1 || {
    echo "  WARNING: checksum mismatch for $tb (github)" >&2; return 1; }
  # ⚠ EXTRACT THE WHOLE TARBALL, not just the two top-level binaries. Releases from
  # 20260914 on also ship a `gvisor-bin/` directory of sidecar helpers, and runsc refuses to
  # start a sandbox without them:
  #   cannot create sandbox process: sidecar "gvisor_sentry" not usable
  #   (stat /usr/local/bin/gvisor-bin/gvisor_sentry: no such file or directory)
  #   and --sidecar-usage-policy is set to STRICT
  # The google source ships bare binaries with no sidecars and is unaffected, which is why
  # this only bites on the GitHub fallback path.
  tar xjf "$tmp/$tb" -C "$tmp" || return 1
}

ok=0
for src in fetch_google fetch_github; do
  echo "  fetching gVisor via ${src#fetch_}…"
  if "$src"; then ok=1; break; fi
  echo "  …failed, trying next source" >&2
done
[ "$ok" = "1" ] || {
  echo "ERROR: could not fetch gVisor from any source." >&2
  echo "  - https://storage.googleapis.com/gvisor/releases/…" >&2
  echo "  - https://github.com/google/gvisor/releases/…" >&2
  echo "This node declares nestedRuntime: gvisor, so it MUST NOT be left advertising a" >&2
  echo "runtime it cannot run — failing instead. Check egress to the hosts above." >&2
  rm -rf "$tmp"; exit 1; }
for f in runsc containerd-shim-runsc-v1; do
  install -m 0755 "$tmp/$f" "/usr/local/bin/$f"
done
# Sidecar helpers, when the source provided them (GitHub tarball only — see fetch_github).
# runsc resolves them relative to its own location, so they must land beside it.
if [ -d "$tmp/gvisor-bin" ]; then
  rm -rf /usr/local/bin/gvisor-bin
  cp -a "$tmp/gvisor-bin" /usr/local/bin/gvisor-bin
  chmod 0755 /usr/local/bin/gvisor-bin/* 2>/dev/null || true
fi
rm -rf "$tmp"
echo "runsc installed: $(runsc --version 2>/dev/null | head -n1)"

fi

# net-raw lets the sandbox use raw sockets (ping, and anything doing its own L3).
# Without it tools inside the sandbox fail in ways that look like network faults.
mkdir -p /etc/containerd
cat > /etc/containerd/runsc.toml <<'EOF'
# gVisor runtime options. Managed by src/provisioning-scripts/50-install-nested-runtime.sh.
[runsc_config]
  net-raw = "true"
EOF

# k3s owns /var/lib/rancher/k3s/agent/etc/containerd/config.toml and regenerates
# config.toml on every restart but always imports config-v3.toml.d/*.toml.
cat > "$DROPIN_DIR/runsc.toml" <<'EOF'
# gVisor (runsc) runtime handler for k3s containerd (config v3). Pods with
# runtimeClassName: runsc get a userspace-kernel sandbox — nested containers work
# without privileged: true. Managed by
# src/provisioning-scripts/50-install-nested-runtime.sh — survives k3s config regen
# (drop-in import), never edit config.toml directly.
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
  [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc.options]
    TypeUrl = "io.containerd.runsc.v1.options"
    ConfigPath = "/etc/containerd/runsc.toml"
    # Match the cgroup driver k3s uses for its own runc handler. Consistency is right on
    # its own, but be aware of what it does NOT buy:
    #
    # ⚠ THIS DOES NOT MAKE POD LIMITS ENFORCED FOR runsc. With `limits: cpu 12 /
    # memory 20Gi` the gVisor desktop still reports nproc=24 / 30 GB and `cpu.max=max` at
    # BOTH its pod slice and its container scope, and under load it reaches ~2x its limit.
    # A plain runc pod on the same node with `cpu: 100m` correctly gets
    # `cpu.max=10000 100000`, so the kubelet is fine; the runsc shim creates a FLAT cgroup
    # dir named after the systemd path instead of resolving it into a scope.
    # Consequence: a benchmark must pin parallelism by hand (taskset / tool -jobs), and the
    # runsc limit cannot be relied on to protect this node's other tenants (Samba AD DC,
    # Longhorn instance-manager).
    SystemdCgroup = true
EOF
echo "wrote ${DROPIN_DIR}/runsc.toml"

# ── 4. Restart the k3s agent so containerd re-reads (if already installed) ────
# 40-join-cluster.sh installs/starts the agent AFTER this step on a first provision, so the
# generated config will already import the drop-in. On a re-provision the agent exists →
# restart it now so the handler is live.
# NB: test the unit directly. `systemctl list-unit-files | grep -q '^k3s-agent\.service'`
# looks equivalent but reported "not installed" on a node where the unit plainly existed —
# the listing is paged/formatted differently depending on the invoking environment, and a
# false negative here silently skips the restart, so the new handler never goes live.
if systemctl cat k3s-agent.service >/dev/null 2>&1; then
  echo "k3s-agent present — restarting to load the ${RUNTIME} runtime handler…"
  systemctl restart k3s-agent
  sleep 5
else
  echo "k3s-agent not yet installed — the handler loads when 40-join-cluster.sh starts it."
fi

# ── 5. Assert the runtime is actually usable ─────────────────────────────────
# ⚠ THE POINT OF THIS BLOCK: a node that declares nestedRuntime gets the
# `ecc/nested-runtime=gvisor` + `ecc/nested-runtime-gvisor=true` labels from
# src/nodes-k3s-mesh.ts REGARDLESS of what happened here, and pods select on those labels.
# So a silent failure above does not produce a node that merely lacks gVisor — it produces
# one that ADVERTISES gVisor and fails every runsc pod scheduled onto it. Fail here instead,
# while the operator is still looking at the provisioning output.
#
# `runsc --version` alone is not enough: it answers before the platform is checked. Running
# `runsc do` exercises the actual sandbox (ptrace/KVM platform selection included).
if ! /usr/local/bin/runsc --version >/dev/null 2>&1; then
  echo "ERROR: runsc is installed but will not execute. This node advertises gVisor and" >&2
  echo "       cannot run it — refusing to finish." >&2
  exit 1
fi
if ! /usr/local/bin/runsc --network=none --ignore-cgroups do /bin/true >/dev/null 2>&1; then
  echo "ERROR: 'runsc do /bin/true' failed — the sandbox cannot start on this kernel." >&2
  echo "       The node advertises gVisor via its nested-runtime labels, so leaving it in" >&2
  echo "       this state would break every runsc pod scheduled here." >&2
  exit 1
fi
echo "runsc sandbox verified: $(/usr/local/bin/runsc --version 2>/dev/null | head -n1)"

echo "=== Nested-container runtime enablement done ==="
