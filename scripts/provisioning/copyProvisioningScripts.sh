#!/bin/bash
# copyProvisioningScripts.sh — copy the generated mesh carry-scripts to a remote box over SSH.
#
# For the "no inbound provisioning from here" case: instead of driving the join over SSH
# (provision-mesh-node-ssh.sh), this only DELIVERS tmp/provisioning/ to the node. You then
# run provision-mesh-node-local.sh there — as root, on a box that needs no `cape` user and
# no key of ours. It is the network-friendly alternative to carrying the folder on a USB
# stick; the resulting on-node flow is identical.
#
# It runs scripts/provisioning/generateProvisioningScripts.sh itself on every invocation, so the
# copied set always embeds the CURRENT cluster's join token — that needs kubectl and SSH to
# CP0. --no-generate skips it and copies tmp/provisioning/ as-is.
#
# ⚠ The payload is SENSITIVE: 40-join-cluster.sh embeds the k3s join token, which is a
# cluster-join credential. Delete the folder from the node once the join is done (the final
# hint below says so). The carry-scripts are keyless — a leaked copy still cannot join
# without a human approving the registration in Headplane — but the token is worth
# protecting regardless.
#
# Usage:
#   ./scripts/provisioning/copyProvisioningScripts.sh <host> [--port N] [--user U] [--dest PATH]
#                                           [--password PW | --ask-password] [--yes]
#                                           [--no-generate]
#
# Examples:
#   ./scripts/provisioning/copyProvisioningScripts.sh 192.168.178.150
#   ./scripts/provisioning/copyProvisioningScripts.sh node.example.org --port 2222 --user root
#   ./scripts/provisioning/copyProvisioningScripts.sh 10.0.0.5 --ask-password

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$ROOT_DIR/tmp/provisioning"
GENERATOR="$SCRIPT_DIR/generateProvisioningScripts.sh"

# StrictHostKeyChecking=no matches the other provisioning scripts: these are freshly-imaged
# boxes whose host key is not known yet and changes on every reinstall.
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

usage() {
  cat <<USAGE
Copy the generated mesh carry-scripts (tmp/provisioning/) to a remote node.

Usage:
  copyProvisioningScripts.sh <host> [options]
  copyProvisioningScripts.sh -h | --help

Required:
  <host>               IP or FQDN of the target node (positional).

Options:
  --port <n>           SSH port                              (default: 22).
  --user <name>        SSH user                              (default: root).
  --dest <path>        Destination directory on the node     (default: /tmp/provisioning).
                       ⚠ DELETED AND RECREATED on every run (with sudo if it belongs to
                       another user), so the node gets exactly the current script set.
                       Must be an absolute path of >=2 segments; system dirs are refused.
  --password <pw>      Authenticate with a password instead of an ssh-agent key (needs
                       sshpass). ⚠ visible in your shell history — prefer --ask-password.
  --ask-password       Same, but prompt for it (no echo, not in history).
  --yes                Skip the login prompt at the end (non-interactive).
  --no-generate        Do NOT regenerate first; copy whatever is already in
                       tmp/provisioning/. Only for iterating on a hand-edited set —
                       it risks shipping a stale join token.

The carry-scripts are REGENERATED on every run (needs kubectl + SSH to CP0), so the
copied set always carries the current cluster's join token.
USAGE
}

HOST="" ; PORT="" ; USER_NAME="" ; DEST="" ; PASSWORD="" ; ASK_PASSWORD=false ; ASSUME_YES=false
GENERATE=true
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    --no-generate)  GENERATE=false; shift ;;
    --port)         PORT="$2"; shift 2 ;;
    --user)         USER_NAME="$2"; shift 2 ;;
    --dest)         DEST="$2"; shift 2 ;;
    --password)     PASSWORD="$2"; shift 2 ;;
    --ask-password) ASK_PASSWORD=true; shift ;;
    --yes)          ASSUME_YES=true; shift ;;
    -*)             echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *)              if [ -z "$HOST" ]; then HOST="$1"; shift
                    else echo "ERROR: unexpected argument '$1'" >&2; exit 2; fi ;;
  esac
done

[ -n "$HOST" ] || { echo "ERROR: <host> is required (IP or FQDN)." >&2; usage >&2; exit 2; }
PORT="${PORT:-22}" ; USER_NAME="${USER_NAME:-root}" ; DEST="${DEST:-/tmp/provisioning}"
ADDR="${USER_NAME}@${HOST}"

# ── The scripts must already be generated ────────────────────────────────────
# Regenerate FIRST, every run (unless --no-generate). The carry-scripts embed the current
# cluster's k3s join token, headscale URL and CA bundle, so a set left over from an earlier
# cluster copies cleanly and only fails much later on the node — with a CA-hash mismatch that
# reads as a broken token rather than a stale file. Generating here makes that impossible
# instead of merely warning about it, and the generator is idempotent (it mints a fresh
# pre-auth key and rewrites the folder), so the cost is a few seconds.
if [ "$GENERATE" = "true" ]; then
  echo "Generating carry-scripts (bash $GENERATOR)…"
  # Needs kubectl + SSH to CP0. Output is noisy and ends in a long usage banner that is
  # irrelevant here, so keep only what matters and surface the full log on failure.
  GEN_LOG="$(mktemp)"
  if bash "$GENERATOR" >"$GEN_LOG" 2>&1; then
    echo "  carry-scripts regenerated."
  else
    echo "ERROR: $GENERATOR failed — not copying a stale/absent set." >&2
    echo "       Its output follows; re-run it by hand to iterate." >&2
    echo "       (--no-generate copies what is already in tmp/provisioning/.)" >&2
    echo "────────────────────────────────────────────────────────" >&2
    tail -30 "$GEN_LOG" >&2
    rm -f "$GEN_LOG"
    exit 1
  fi
  rm -f "$GEN_LOG"
  echo ""
fi

# Verify by CONTENT, not just directory existence: the folder survives a failed generate run,
# and copying a half-written set produces a node that fails several minutes into the join
# instead of here. Still checked after a successful generate — it is the assertion that the
# generator produced what the local path will look for.
REQUIRED=(00-cleanup-node.sh 10-install-prereqs.sh 30-connect-vpn.sh 40-join-cluster.sh
          50-install-nested-runtime.sh provision-mesh-node-local.sh README.md)
MISSING=()
for f in "${REQUIRED[@]}"; do [ -f "$SRC_DIR/$f" ] || MISSING+=("$f"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: $SRC_DIR is missing: ${MISSING[*]}" >&2
  if [ "$GENERATE" = "true" ]; then
    echo "       ...even though the generator reported success — it did not write the" >&2
    echo "       expected set. Run it by hand: bash $GENERATOR" >&2
  else
    echo "       Generate the carry-scripts first (or drop --no-generate):" >&2
    echo "         bash $GENERATOR" >&2
  fi
  exit 1
fi

# Only reachable with --no-generate; otherwise the set was just written. A stale set from a
# previous cluster copies cleanly and then fails at join time with a confusing CA-hash
# mismatch, so surface the age rather than let it be discovered on the node.
if [ "$GENERATE" != "true" ]; then
  AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$SRC_DIR/40-join-cluster.sh") ) / 60 ))
  if [ "$AGE_MIN" -gt 1440 ]; then
    echo "WARNING: the carry-scripts are $(( AGE_MIN / 1440 )) day(s) old and --no-generate was"
    echo "         given. If the cluster was recreated since, the embedded join token is stale."
    echo ""
  fi
fi

# ── Auth mode: ssh-agent key (default) or password ───────────────────────────
# Mirrors provision-mesh-node-ssh.sh. PubkeyAuthentication=no is required, not cosmetic:
# with several keys in the agent, ssh offers them first and a box with the default
# MaxAuthTries=6 disconnects before reaching the password prompt — which looks like a wrong
# password rather than an exhausted key list.
SSH_CMD=(ssh) ; SCP_CMD=(scp)
if [ "$ASK_PASSWORD" = "true" ] && [ -z "$PASSWORD" ]; then
  printf 'SSH password for %s: ' "$ADDR" >&2
  read -r -s PASSWORD < /dev/tty ; printf '\n' >&2
  [ -n "$PASSWORD" ] || { echo "ERROR: empty password." >&2; exit 2; }
fi
if [ -n "$PASSWORD" ]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "ERROR: --password needs sshpass (apt-get install -y sshpass)." >&2; exit 2; }
  SSH_OPTS="$SSH_OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password"
  # Password goes through the environment (-e), never argv, so it stays out of `ps`.
  SSH_CMD=(env "SSHPASS=$PASSWORD" sshpass -e ssh)
  SCP_CMD=(env "SSHPASS=$PASSWORD" sshpass -e scp)
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Copy carry-scripts → $ADDR:$PORT"
echo "  Source: $SRC_DIR"
echo "  Dest  : $DEST"
echo "  Auth  : $([ -n "$PASSWORD" ] && echo 'password (sshpass)' || echo 'ssh-agent key')"
echo "══════════════════════════════════════════════════"

# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" 'echo "SSH OK"'

# Replace the destination outright, then copy the folder CONTENTS (the trailing /.) so the
# node ends up with exactly what we just generated — no files left behind by an older run
# with a different script set.
#
# The removal is not optional tidiness: `mkdir -p` SUCCEEDS on a directory that already
# exists but belongs to ANOTHER user, and the failure then surfaces only mid-transfer as a
# pile of "scp: dest open ... Permission denied" lines. A previous hand-run under a different
# login (root, or a second admin account) leaves exactly that behind.
#
# sudo is used only if plain rm fails, and the path is validated first: $DEST is interpolated
# into a remote shell command, so an unconstrained value would be an arbitrary `sudo rm -rf`.
# Refuse anything that is not an absolute path of at least two segments, and refuse a handful
# of system directories outright — this script only ever needs a scratch dir.
case "$DEST" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    echo "ERROR: refusing to use '$DEST' as the destination (it is a system directory)." >&2
    exit 2 ;;
  /*/*) : ;;   # absolute, >=2 segments — e.g. /tmp/provisioning
  *)  echo "ERROR: --dest must be an absolute path with at least two segments (got '$DEST')." >&2
      exit 2 ;;
esac
case "$DEST" in
  *..*) echo "ERROR: --dest must not contain '..' (got '$DEST')." >&2; exit 2 ;;
esac

# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" "
  if [ -e '$DEST' ]; then
    rm -rf '$DEST' 2>/dev/null || sudo -n rm -rf '$DEST' 2>/dev/null || {
      echo \"cannot remove existing $DEST (owned by another user and no passwordless sudo)\" >&2
      ls -ld '$DEST' >&2
      exit 1; }
  fi
  mkdir -p '$DEST'" || {
  echo "ERROR: could not prepare $DEST on $HOST as '$USER_NAME'." >&2
  echo "       Remove it by hand, or copy elsewhere with --dest:" >&2
  echo "         ssh -p $PORT $ADDR 'sudo rm -rf $DEST'" >&2
  exit 1; }
# shellcheck disable=SC2086
"${SCP_CMD[@]}" $SSH_OPTS -P "$PORT" -r "$SRC_DIR/." "$ADDR:$DEST/"

# The scripts are copied without the executable bit on some filesystems, and the join token
# inside them should not be world-readable on a shared box.
# shellcheck disable=SC2086
"${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" "chmod 700 '$DEST' && chmod 600 '$DEST'/*.sh"

COPIED=$(cd "$SRC_DIR" && ls -1 *.sh 2>/dev/null | wc -l)
echo ""
echo "Copied $COPIED script(s) to $ADDR:$DEST"
echo ""
echo "Next, ON THE NODE (as root):"
echo "    cd $DEST && sudo bash provision-mesh-node-local.sh --name <node-id>"
echo "  (run with no args for an interactive menu)"
echo ""
echo "Then approve + finish FROM HERE:"
echo "  1) 30-connect-vpn.sh prints a registration URL — approve it in Headplane, or:"
echo "       kubectl exec -n headscale deploy/headscale -- \\"
echo "         headscale auth register --user on-premise-resident --auth-id <auth-id>"
echo "     ⚠ user MUST be on-premise-resident (or -transient) — a node registered to any"
echo "       other user gets a tailnet IP but matches no ACL grant, so it never joins."
echo "  2) Tag it (keyless joins cannot carry a tag):"
echo "       kubectl exec -n headscale deploy/headscale -- \\"
echo "         headscale nodes tag -i <node-id> -t tag:k8s-node"
echo "  3) Apply labels / storageScope / fingerprint:"
echo "       ./scripts/provisioning/adoptProvisionedNodes.sh <node-id>"
echo ""
echo "⚠ $DEST/40-join-cluster.sh contains the k3s join token — delete the folder"
echo "  from the node once the join is done:  sudo rm -rf $DEST"
echo ""

# ── Offer an interactive login ───────────────────────────────────────────────
if [ "$ASSUME_YES" = "true" ]; then exit 0; fi
# Only offer if there is a terminal to hand over to — under a pipe or CI, `read` would
# either block or consume piped data as the answer.
if [ ! -t 0 ] && [ ! -e /dev/tty ]; then exit 0; fi

printf 'Log in to %s now? (y/N): ' "$ADDR"
read -r ans < /dev/tty || ans=""
case "$ans" in
  y|Y|yes|YES)
    echo "Opening shell on $ADDR (cd $DEST)…"
    # -t forces a PTY so the remote shell is fully interactive. Landing directly in $DEST
    # saves the cd; `exec bash -l` keeps it a normal login shell afterwards.
    # `|| true` so an exit code from the remote shell (e.g. Ctrl-D after a failed command)
    # does not trip `set -e` and print a spurious error after a normal logout.
    # shellcheck disable=SC2086
    "${SSH_CMD[@]}" $SSH_OPTS -t -p "$PORT" "$ADDR" "cd '$DEST' 2>/dev/null; exec bash -l" || true
    ;;
  *)
    echo "Not logging in. To connect later:"
    echo "    ssh -p $PORT $ADDR"
    ;;
esac
