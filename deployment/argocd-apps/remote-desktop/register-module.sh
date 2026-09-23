#!/bin/bash
# Register (or unregister) a module on the remote-desktop module share.
#
# The share IS the module registry: the broker permits `module load <name>/<version>`
# iff <share>/modules/<name>/<version>/module.yaml exists. Registering a module is an
# ADMINISTRATIVE act — see the trust model in doc/nested-container-runtime.md.
#
# The share is mounted only in the privileged broker sidecar, so this is a thin wrapper
# around the broker's own admin subcommands (broker.sh: list-modules/register/unregister).
#
#   ./register-module.sh list
#   ./register-module.sh add     <name> <version> [module.yaml]
#   ./register-module.sh remove  <name> <version>
#   ./register-module.sh allowed <name> <version>   <- trust THIS over `list`
#
# ⚠ `list` CAN LIE FOR MINUTES AFTER add/remove. It enumerates the share, and CIFS keeps
# serving this mount a stale directory listing — measured 2026-08-22: a just-registered
# module was absent from `list` while being fully loadable, and a just-unregistered one was
# still shown. `allowed` performs the same direct stat the load path uses (broker.sh
# allowed()) and is cache-immune, so use it to confirm an add/remove actually took.
#
# `add` without a module.yaml path reads the manifest from the module IMAGE itself,
# which is the normal case: the image is the source of truth and the share entry only
# authorizes it. Pass a file to override (e.g. before the image is published).
set -euo pipefail

NS="${REMOTE_DESKTOP_NS:-remote-desktop}"

# ⚠ THE LABEL IS PER-DESKTOP, NOT `app=remote-desktop`. The desktop Deployment labels its
# pods after itself (`app=remote-desktop-gvisor`), so the bare `app=remote-desktop`
# selector matched NOTHING and every invocation died with "no remote-desktop pod" even
# with a healthy running desktop. Match the prefix instead, and pick the first READY pod:
# it is the broker sidecar — not the desktop — that owns the registry mount.
#
# REGISTRY_POD overrides it for the case where only one specific desktop should be used.
POD="${REGISTRY_POD:-}"
if [ -z "$POD" ]; then
  POD="$(kubectl -n "$NS" get pod \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.metadata.labels.app}{"\n"}{end}' \
    2>/dev/null | awk '$2 ~ /^remote-desktop/ {print $1; exit}')"
fi
[ -n "$POD" ] || { echo "ERROR: no running remote-desktop pod in namespace $NS" >&2; exit 1; }

case "${1:-}" in
  list)
    kubectl -n "$NS" exec "$POD" -c broker -- /usr/local/bin/broker list-modules
    ;;
  add)
    NAME="${2:?usage: $0 add <name> <version> [module.yaml]}"
    VER="${3:?usage: $0 add <name> <version> [module.yaml]}"
    SRC="${4:-}"
    if [ -n "$SRC" ]; then
      [ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }
      kubectl -n "$NS" exec -i "$POD" -c broker -- \
        /usr/local/bin/broker register "$NAME" "$VER" --from-stdin < "$SRC"
    else
      kubectl -n "$NS" exec "$POD" -c broker -- \
        /usr/local/bin/broker register "$NAME" "$VER"
    fi
    echo "Users can now: module load ${NAME}/${VER}"
    ;;
  remove)
    NAME="${2:?usage: $0 remove <name> <version>}"
    VER="${3:?usage: $0 remove <name> <version>}"
    kubectl -n "$NS" exec "$POD" -c broker -- \
      /usr/local/bin/broker unregister "$NAME" "$VER"
    echo "New loads are refused; already-loaded sessions keep working."
    ;;
  allowed)
    NAME="${2:?usage: $0 allowed <name> <version>}"
    VER="${3:?usage: $0 allowed <name> <version>}"
    kubectl -n "$NS" exec "$POD" -c broker -- \
      /usr/local/bin/broker allowed "$NAME" "$VER"
    ;;
  *)
    sed -n '2,24p' "$0"; exit 1
    ;;
esac
