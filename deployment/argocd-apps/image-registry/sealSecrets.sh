#!/bin/bash
# Seals the image-registry htpasswd credential.
# Idempotent: recovers the existing password from the sealed file on re-runs.
# Pass --regenerate to rotate it.
#
# WHY THIS REGISTRY IS AUTHENTICATED AT ALL — it is not routine hardening. What this
# registry serves gets executed AS ROOT: the remote-desktop broker's allowed() gate
# authorises a module by <repo>:<tag> and does NOT verify the CONTENT at that tag. Without
# auth, anything able to reach the Service could overwrite an already-registered tag —
# including the desktop container, where unprivileged LDAP users have shells — and the next
# `module load` would run it as root. See deployment.yaml and networkpolicy.yaml.
#
# Produces TWO secrets from ONE password, which must stay in step:
#   image-registry/image-registry-auth      htpasswd file, read by the registry itself
#   gitlab-runner/image-registry-cred     dockerconfigjson, used by the [eda] CI to push
#   remote-desktop{,-bender}/image-registry-cred  dockerconfigjson, the brokers' pull cred
#
# ⚠ bcrypt only. registry:3 rejects htpasswd entries in any other format, and the failure
# is a 401 on every push with nothing obviously wrong in the registry log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  # Accepted and ignored: this script has no git-commit block of its own (the sealed
  # files are committed by the caller), so there is nothing to skip. Parsed anyway so
  # sealAllSecrets.sh can pass it uniformly to every app.
  --skip-git-commit) : ;;
esac; done
# ⚠ TWO ACCOUNTS, AND THE SPLIT IS THE SECURITY BOUNDARY. `eda-push` is for CI only;
# `eda-pull` is what the remote-desktop broker gets. Enforcement is NOT in the registry —
# distribution's htpasswd backend authenticates without authorising, so both accounts would
# be able to push. The nginx front in authz-configmap.yaml refuses non-GET/HEAD for
# eda-pull. Changing either name means changing that map.
PUSH_USER="eda-push"
PULL_USER="eda-pull"
SEALED="$SCRIPT_DIR/image-registry-auth-sealed.yaml"

PUSH_PASSWORD=$(recover_or_generate "$SEALED" push-password "$REGEN" 32)
PULL_PASSWORD=$(recover_or_generate "$SEALED" pull-password "$REGEN" 32)
[[ -n "$PUSH_PASSWORD" && -n "$PULL_PASSWORD" ]] || { echo "ERROR: could not obtain passwords" >&2; exit 1; }

# ⚠ BCRYPT IS THE ONLY FORMAT registry:3 accepts — "entries with other hash types are
# ignored" (distribution configuration.md). So `openssl passwd -apr1`, which IS available
# on a bare devcontainer, is useless here: it produces a valid htpasswd line that the
# registry silently drops, and every push then 401s with nothing wrong in the log.
#
# Three sources, in order of what a devcontainer actually has:
bcrypt_line() {  # $1=user $2=password -> "user:$2b$..."
  local u="$1" p="$2"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbB "$u" "$p"
  elif python3 -c 'import bcrypt' >/dev/null 2>&1; then
    USERNAME="$u" PASSWORD="$p" python3 -c '
import os, bcrypt
u = os.environ["USERNAME"]; p = os.environ["PASSWORD"].encode()
print(u + ":" + bcrypt.hashpw(p, bcrypt.gensalt()).decode())
'
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm httpd:2 htpasswd -nbB "$u" "$p" 2>/dev/null | tr -d '\r'
  fi
}
PUSH_LINE=$(bcrypt_line "$PUSH_USER" "$PUSH_PASSWORD")
PULL_LINE=$(bcrypt_line "$PULL_USER" "$PULL_PASSWORD")
HTPASSWD_LINE=$(printf '%s\n%s' "$PUSH_LINE" "$PULL_LINE")
if [ -z "$HTPASSWD_LINE" ]; then
  echo "ERROR: cannot generate a BCRYPT htpasswd entry. Install one of:" >&2
  echo "  apt-get install -y apache2-utils        # provides htpasswd" >&2
  echo "  pip install --break-system-packages bcrypt" >&2
  echo "Do NOT substitute 'openssl passwd' — registry:3 ignores non-bcrypt entries." >&2
  exit 1
fi
# Fail fast on a malformed entry rather than shipping one the registry will drop.
for line in "$PUSH_LINE" "$PULL_LINE"; do
  case "$line" in
    *:'$2'*) : ;;
    *) echo "ERROR: generated htpasswd entry is not bcrypt: ${line%%:*}:..." >&2; exit 1 ;;
  esac
done

# The registry reads this file directly.
# nginx reads htpasswd; the two passwords are kept so re-runs recover instead of rotating.
seal_secret image-registry image-registry-auth image-registry-auth-sealed.yaml \
  --from-literal=htpasswd="$HTPASSWD_LINE" \
  --from-literal=push-password="$PUSH_PASSWORD" \
  --from-literal=pull-password="$PULL_PASSWORD"

# Pull/push credential for the CI and the broker. A dockerconfigjson with explicit
# username/password (NOT only a base64 `auth` field) — broker.sh parses those two keys and
# passes them to skopeo --creds; see its AUTHFILE note.
REGISTRY_HOST="image-registry.image-registry.svc.cluster.local:5000"
# ⚠ THE KUBELET REACHES THIS REGISTRY AT A DIFFERENT HOST STRING, and a pull secret is
# matched by that string. The in-cluster FQDN above is unresolvable from the node's
# resolver, so kubelet pulls go to the NodePort on loopback instead — see service.yaml.
# A secret keyed only to the FQDN is silently never applied to a 127.0.0.1:30500/... image
# and the pull fails with "no basic auth credentials".
NODE_REGISTRY_HOST="127.0.0.1:30500"
dockercfg() {  # $1=user $2=password $3=host
  REG="$3" U="$1" P="$2" python3 -c '
import json, os, base64
u, p, r = os.environ["U"], os.environ["P"], os.environ["REG"]
print(json.dumps({"auths": {r: {
    "username": u, "password": p,
    "auth": base64.b64encode(f"{u}:{p}".encode()).decode(),
}}}))
'
}

# ⚠ WHICH NAMESPACE GETS WHICH ACCOUNT IS THE WHOLE POINT OF THE SPLIT.
#   gitlab-runner   → eda-push : the [eda] CI builds and publishes module images.
#   remote-desktop  → eda-pull : the broker only ever pulls, and this credential is mounted
#                                into a MULTI-USER LDAP DESKTOP where unprivileged users
#                                have shells. A push-capable credential there makes a
#                                shell equivalent to root on the next `module load`.
# Do not "fix a failing push from the desktop" by handing it the push account.
seal_secret gitlab-runner image-registry-cred image-registry-cred-gitlab-runner-sealed.yaml \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(dockercfg "$PUSH_USER" "$PUSH_PASSWORD" "$REGISTRY_HOST")"

seal_secret remote-desktop image-registry-cred image-registry-cred-remote-desktop-sealed.yaml \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(dockercfg "$PULL_USER" "$PULL_PASSWORD" "$REGISTRY_HOST")"

# The second desktop's broker. Same READ-ONLY account and the same reasoning as above: this
# is the IN-POD credential skopeo uses (Service name, cluster DNS), which is a different
# secret from the kubelet's NodePort-keyed image-registry-cred-node below. A broker without
# it fails its first pull with `no basic auth credentials`.
seal_secret remote-desktop-bender image-registry-cred image-registry-cred-remote-desktop-bender-sealed.yaml \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(dockercfg "$PULL_USER" "$PULL_PASSWORD" "$REGISTRY_HOST")"

# The [eda-run] runner's build pods (app-of-apps/gitlab-runner-eda-run.yaml) — the READ-ONLY
# account, under a DISTINCT NAME.
#
# ⚠ A SECOND SECRET IN gitlab-runner, deliberately. That namespace already holds
# `image-registry-cred` with the PUSH account, for the image BUILDS on the [eda] runner. An
# [eda-run] job only ever RUNS a module, and what this registry serves is executed AS ROOT
# by the broker — so handing those pods a push-capable credential would let a job overwrite
# a module tag and choose what runs as root. Same reasoning as the desktop entry above; the
# name differs only because one namespace cannot hold two secrets called the same thing.
seal_secret gitlab-runner image-registry-cred-pull image-registry-cred-pull-gitlab-runner-sealed.yaml \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(dockercfg "$PULL_USER" "$PULL_PASSWORD" "$REGISTRY_HOST")"

# The KUBELET pull credential, keyed to the NodePort host. This is the half of the old
# /etc/rancher/k3s/registries.yaml that could NOT move into containerd's certs.d directory:
# hosts.toml has no auth field, and the config.toml that does is read only at agent start.
# Supplying it as an imagePullSecret instead is what removes the node-by-node k3s restart.
# Always the READ-ONLY account: the kubelet only ever pulls.
# ⚠ gitlab-runner IS IN THIS LIST, and it is not obvious why. The [eda-run] runner's build
# pods use the remote-desktop base image (it carries the module runtime) and pull it from
# the NodePort — so the KUBELET pulls `127.0.0.1:30500/...` and needs a secret keyed to THAT
# host string. The FQDN-keyed image-registry-cred does NOT apply to it: a pull secret is
# matched by registry HOST STRING, so the pull fails with `no basic auth credentials`
# (measured on ecc204 — the job died in prepare_script before any script ran).
for ns in ollama remote-desktop remote-desktop-bender hermes gitlab-runner; do
  seal_secret "$ns" image-registry-cred-node \
    "image-registry-cred-node-${ns}-sealed.yaml" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$(dockercfg "$PULL_USER" "$PULL_PASSWORD" "$NODE_REGISTRY_HOST")"
done

echo
echo "Sealed image-registry credentials: push='$PUSH_USER', pull='$PULL_USER'."
echo "  image-registry/image-registry-auth     (htpasswd, read by the registry)"
echo "  gitlab-runner/image-registry-cred    (CI push)"
echo "  remote-desktop,remote-desktop-bender/image-registry-cred (broker pull)"
echo "  ollama,remote-desktop,remote-desktop-bender,hermes,gitlab-runner/image-registry-cred-node"
echo "                                         (KUBELET pull via $NODE_REGISTRY_HOST)"
echo
echo "⚠ The two -cred files live in OTHER apps' namespaces but are sealed HERE so one"
echo "  password cannot drift into three. They are applied by this app; the consuming"
echo "  apps only reference them by name."
