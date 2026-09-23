#!/bin/bash
# provisionUsersViaSshPassword.sh — bootstrap SSH-key access on a box we can only reach with
# a password (phase 0, before anything in README.md step 1 can run).
#
# Given an existing password login, it creates the provisioning users, puts our public key in
# each one's authorized_keys, and grants passwordless sudo — which is exactly what
# copyProvisioningScripts.sh / provision-mesh-node-ssh.sh assume already exists. After this
# runs, the box is reachable with `ssh -i <key> <user>@<host>` and the password can be retired.
#
# ⚠ Every connection it makes is PASSWORD-ONLY (see SSH_OPTS below) — unlike the other
# provisioning scripts, which authenticate with the agent. That is deliberate and not
# configurable: this runs before our key exists on the box, so an offered key can only waste
# one of the box's MaxAuthTries and get us disconnected before the password prompt appears.
#
# The public key comes from the PULUMI STACK by default: the private key lives only in the
# Pulumi config (see scripts/pulumi/sshAgentHelpers.sh), and the public half is derived from it
# with `ssh-keygen -y` — nothing is read from disk and no private material is written. When the
# stack is not loaded (a box being prepared from a laptop, say), pass the public key directly
# with --pubkey / --pubkey-string.
#
# ⚠ The public key is installed APPENDED, never overwriting: these boxes frequently carry a
# second admin's key already, and replacing authorized_keys would lock them out. Re-running is
# a no-op per user (the key is matched before appending).
#
# Accounts are created key-only (`adduser --disabled-password`). --set-passwords additionally
# sets a login password per user, for the cases a key cannot serve: the physical/IPMI console,
# a rescue boot, or an `su -` from another account. It is OPTIONAL on purpose — a password is
# one more credential to rotate, and SSH access never needs it.
#
# Usage:
#   ./scripts/provisioning/provisionUsersViaSshPassword.sh <host> [options]
#
# Examples:
#   ./scripts/provisioning/provisionUsersViaSshPassword.sh smartmirror6.example.org \
#       --login orin --ask-password
#   ./scripts/provisioning/provisionUsersViaSshPassword.sh 192.168.178.150 --port 2222 \
#       --login admin --users "cape trecs" --key sshkey-ecc-mesh --ask-password
#   ./scripts/provisioning/provisionUsersViaSshPassword.sh node.example.org --login ubuntu \
#       --pubkey ~/.ssh/id_ed25519.pub --ask-password --hostname orin
#   ./scripts/provisioning/provisionUsersViaSshPassword.sh smartmirror8.example.org \
#       --login cape --ask-password --hostname orin --set-passwords

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# StrictHostKeyChecking=no matches the other provisioning scripts: freshly-imaged boxes have no
# known host key and it changes on every reinstall.
#
# Password auth is forced for EVERY connection this script makes, unconditionally — it exists
# precisely for boxes that only accept a password, and it always runs before our key is
# installed, so there is never a key worth offering.
#
# All three options are needed, and the failure they prevent is badly misleading:
#   PubkeyAuthentication=no        stops the ssh-agent's keys being offered
#   IdentitiesOnly=yes             stops an IdentityFile from ~/.ssh/config being offered too
#   PreferredAuthentications=password  skips gssapi/keyboard-interactive ahead of the prompt
# Without them ssh burns the box's MaxAuthTries (default 6) on keys and is disconnected with
# "Too many authentication failures" BEFORE the password prompt is ever shown — which reads as
# a wrong password or an unreachable host rather than an over-full agent.
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_OPTS="$SSH_OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password -o IdentitiesOnly=yes"

usage() {
  cat <<USAGE
Create the provisioning users on a box reachable only by password, install our SSH public
key for each, and grant passwordless sudo.

Usage:
  provisionUsersViaSshPassword.sh <host> [options]
  provisionUsersViaSshPassword.sh -h | --help

Required:
  <host>                 IP or FQDN of the target box (positional).

Options:
  --port <n>             SSH port                                    (default: 22).
  --login <name>         EXISTING account to log in with; must be able to sudo.
                                                                     (default: root).
  --users "<a b ...>"    Users to create / update                      (default: "cape trecs").
  --key <name>           Pulumi config key holding the PRIVATE key; its public half is
                         derived and installed.                      (default: sshkey-ecc-mesh).
  --pubkey <file>        Use this public-key FILE instead of the Pulumi stack.
  --pubkey-string <key>  Use this literal public key instead of the Pulumi stack.
  --password <pw>        Login password. WARNING: lands in your shell history — prefer
                         --ask-password.
  --ask-password         Prompt for the login password (no echo, not in history).
  --hostname <name>      Also set the box's hostname (hostnamectl).
  --set-passwords        Also set a LOGIN password for each user (prompted per user, twice,
                         no echo). Without it the accounts stay key-only — which is the
                         default because SSH never needs a password. Use it when console,
                         IPMI or rescue-boot login has to work.
                         For an account that ALREADY exists you are asked before its
                         password is touched, so a re-run cannot silently replace one.
  --no-sudo-nopasswd     Create the users and keys but do NOT write /etc/sudoers.d/<user>.
  --dry-run              Print the remote script instead of running it.

Key source precedence: --pubkey-string > --pubkey > Pulumi config key --key.
USAGE
}

# Normalise en/em dashes to "--" before parsing. Editors, chat clients and Windows terminals
# autocorrect a typed "--" into "—", and the result ("—login cape") parses as a POSITIONAL, so
# the run dies on "unexpected argument" while the command LOOKS correct on screen. Rewriting it
# is safe: no option or value here may legitimately begin with a dash character.
ARGV=()
for a in "$@"; do
  case "$a" in
    # Strip the dash character by PATTERN, not with ${a#?}: these are multi-byte in UTF-8 and
    # ${a#?} removes a single byte, leaving the rest of the sequence glued to the option name.
    —*)    fixed="--${a#—}"
           echo "NOTE: '$a' looks like an autocorrected dash — reading it as '$fixed'." >&2
           ARGV+=("$fixed") ;;
    –*)    fixed="--${a#–}"
           echo "NOTE: '$a' looks like an autocorrected dash — reading it as '$fixed'." >&2
           ARGV+=("$fixed") ;;
    *)     ARGV+=("$a") ;;
  esac
done
set -- ${ARGV[@]+"${ARGV[@]}"}

HOST="" ; PORT="" ; LOGIN="" ; USERS="" ; PULUMI_KEY="" ; PUBKEY_FILE="" ; PUBKEY_STRING=""
PASSWORD="" ; ASK_PASSWORD=false ; NEW_HOSTNAME="" ; SUDO_NOPASSWD=true ; DRY_RUN=false
SET_PASSWORDS=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)           usage; exit 0 ;;
    --port)              PORT="$2"; shift 2 ;;
    --login)             LOGIN="$2"; shift 2 ;;
    --users)             USERS="$2"; shift 2 ;;
    --key)               PULUMI_KEY="$2"; shift 2 ;;
    --pubkey)            PUBKEY_FILE="$2"; shift 2 ;;
    --pubkey-string)     PUBKEY_STRING="$2"; shift 2 ;;
    --password)          PASSWORD="$2"; shift 2 ;;
    --ask-password)      ASK_PASSWORD=true; shift ;;
    --hostname)          NEW_HOSTNAME="$2"; shift 2 ;;
    --set-passwords)     SET_PASSWORDS=true; shift ;;
    --no-sudo-nopasswd)  SUDO_NOPASSWD=false; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -*)                  echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *)                   if [ -z "$HOST" ]; then HOST="$1"; shift
                         else echo "ERROR: unexpected argument '$1'" >&2; exit 2; fi ;;
  esac
done

[ -n "$HOST" ] || { echo "ERROR: <host> is required (IP or FQDN)." >&2; usage >&2; exit 2; }
PORT="${PORT:-22}" ; LOGIN="${LOGIN:-root}" ; USERS="${USERS:-cape trecs}"
PULUMI_KEY="${PULUMI_KEY:-sshkey-ecc-mesh}"
ADDR="${LOGIN}@${HOST}"

read -r -a USER_LIST <<<"$USERS"
[ ${#USER_LIST[@]} -gt 0 ] || { echo "ERROR: --users is empty." >&2; exit 2; }
for u in "${USER_LIST[@]}"; do
  # The names are interpolated into a remote shell script and into a sudoers filename, so
  # constrain them to what a Linux account name may actually be rather than trusting the caller.
  case "$u" in
    [a-z_][a-z0-9_-]*) ;;
    *) echo "ERROR: '$u' is not a valid user name." >&2; exit 2 ;;
  esac
done
if [ -n "$NEW_HOSTNAME" ]; then
  case "$NEW_HOSTNAME" in
    [A-Za-z0-9][A-Za-z0-9.-]*) ;;
    *) echo "ERROR: '$NEW_HOSTNAME' is not a valid hostname." >&2; exit 2 ;;
  esac
fi

# ── Resolve the public key ───────────────────────────────────────────────────
# Precedence: explicit string > explicit file > Pulumi stack. The Pulumi path derives the
# public half from the private key with `ssh-keygen -y`, so the private key never lands on disk.
PUBKEY="" ; KEY_SOURCE=""
if [ -n "$PUBKEY_STRING" ]; then
  PUBKEY="$PUBKEY_STRING" ; KEY_SOURCE="--pubkey-string"
elif [ -n "$PUBKEY_FILE" ]; then
  [ -f "$PUBKEY_FILE" ] || { echo "ERROR: --pubkey '$PUBKEY_FILE' not found." >&2; exit 2; }
  PUBKEY="$(head -1 "$PUBKEY_FILE")" ; KEY_SOURCE="file $PUBKEY_FILE"
elif command -v pulumi >/dev/null 2>&1 \
     && PRIV="$(pulumi -C "$ROOT_DIR" config get "$PULUMI_KEY" 2>/dev/null)" \
     && printf '%s' "$PRIV" | grep -q 'BEGIN .*PRIVATE KEY'; then
  PUBKEY="$(printf '%s\n' "$PRIV" | ssh-keygen -y -f /dev/stdin 2>/dev/null)" || {
    echo "ERROR: could not derive a public key from Pulumi config '$PULUMI_KEY'." >&2
    echo "       (passphrase-protected or malformed)" >&2; exit 1; }
  # Stamp the Pulumi key name as the comment, same as sshAgentHelpers.sh does, so the key is
  # identifiable in authorized_keys on the node.
  PUBKEY="$(printf '%s' "$PUBKEY" | cut -d' ' -f1-2) $PULUMI_KEY"
  KEY_SOURCE="Pulumi config '$PULUMI_KEY'"
  unset PRIV
else
  echo "ERROR: no public key available." >&2
  echo "       Load the Pulumi stack first:  source ./scripts/pulumi/initPulumiStack.sh" >&2
  echo "       ...or pass the key directly:  --pubkey <file> | --pubkey-string '<key>'" >&2
  exit 2
fi
case "$PUBKEY" in
  ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|sk-ecdsa-*\ *) ;;
  *) echo "ERROR: resolved key does not look like an SSH public key: ${PUBKEY:0:40}…" >&2; exit 1 ;;
esac

# ── Auth: password (this script's whole point) ───────────────────────────────
# Key auth is already ruled out in SSH_OPTS above. What is decided here is only WHO answers the
# prompt: sshpass with a password held here, or you, interactively, on each connection.
if [ "$ASK_PASSWORD" = "true" ] && [ -z "$PASSWORD" ]; then
  printf 'SSH password for %s: ' "$ADDR" >&2
  read -r -s PASSWORD < /dev/tty ; printf '\n' >&2
  [ -n "$PASSWORD" ] || { echo "ERROR: empty password." >&2; exit 2; }
fi
# With a password in hand, sshpass answers the prompt; without one, sshd prompts you directly
# on each connection. Either way the options above have already ruled out key auth.
SSH_CMD=(ssh)
if [ -n "$PASSWORD" ]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "ERROR: password login needs sshpass (apt-get install -y sshpass)." >&2; exit 2; }
  # Password goes through the environment (-e), never argv, so it stays out of `ps`.
  SSH_CMD=(env "SSHPASS=$PASSWORD" sshpass -e ssh)
fi

# ── User passwords (--set-passwords) ─────────────────────────────────────────
# Collected LOCALLY, before the remote script is built: that script is delivered on stdin of
# `sudo bash -s`, so it has no terminal of its own and cannot prompt for anything.
#
# Which accounts already exist has to be known before prompting, because an existing account's
# password is only touched after an explicit confirmation — a re-run must not silently replace
# a credential another admin set. So probe the box first, then ask.
declare -A USER_PW=()
if [ "$SET_PASSWORDS" = "true" ]; then
  [ -t 0 ] || { echo "ERROR: --set-passwords needs a terminal to prompt on." >&2; exit 2; }

  echo ""
  echo "Checking which accounts already exist on $HOST …"
  # `id` per user, one round trip. A name that is absent prints nothing, so the reply is
  # exactly the list of existing accounts — and a trailing marker proves the probe RAN.
  #
  # Without that marker a failed connection is indistinguishable from "no accounts exist":
  # the command substitution yields an empty string either way, every confirmation is skipped,
  # and the run then replaces the passwords it was supposed to ask about. So treat a missing
  # marker as fatal rather than as an empty result.
  # shellcheck disable=SC2086
  PROBE="$("${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" \
      "for u in ${USER_LIST[*]}; do id -u \"\$u\" >/dev/null 2>&1 && echo \"\$u\"; done; echo __PROBE_OK__" \
      2>/dev/null)" || true
  case "$PROBE" in
    *__PROBE_OK__*) ;;
    *) echo "ERROR: could not query existing accounts on $HOST over SSH." >&2
       echo "       Refusing to prompt for passwords blind — an unreachable probe would" >&2
       echo "       skip the 'account already exists' confirmation for every user." >&2
       echo "       Check the host/port/login, or drop --set-passwords." >&2
       exit 1 ;;
  esac
  EXISTING="$(printf '%s\n' "$PROBE" | grep -v '^__PROBE_OK__$' || true)"

  for u in "${USER_LIST[@]}"; do
    if printf '%s\n' "$EXISTING" | grep -qx "$u"; then
      echo ""
      echo "  ⚠ '$u' ALREADY EXISTS on $HOST."
      echo "    Setting a password replaces whatever it has now — including one set by"
      echo "    another admin, or the locked state that keeps it key-only."
      printf '    Set a password for %s anyway? [y/N] ' "$u"
      read -r reply < /dev/tty
      case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "    skipping $u — its password is left untouched."; continue ;;
      esac
    fi

    # Twice, no echo: a mistyped password on an account whose only other access is a key you
    # are still installing is not noticed until someone stands at the console.
    while :; do
      printf '  new password for %s@%s: ' "$u" "$HOST" >&2
      read -r -s pw1 < /dev/tty ; printf '\n' >&2
      printf '  repeat password for %s: ' "$u" >&2
      read -r -s pw2 < /dev/tty ; printf '\n' >&2
      [ -n "$pw1" ] || { echo "    empty — try again." >&2; continue; }
      [ "$pw1" = "$pw2" ] || { echo "    they do not match — try again." >&2; continue; }
      case "$pw1" in
        *$'\n'*|*:*) echo "    a password may not contain ':' or a newline (chpasswd format)." >&2; continue ;;
      esac
      USER_PW["$u"]="$pw1"
      break
    done
    unset pw1 pw2
  done

  if [ ${#USER_PW[@]} -eq 0 ]; then
    echo ""
    echo "No passwords to set — continuing with keys and sudo only."
  fi
fi

# ── Build the remote script ──────────────────────────────────────────────────
# One script, piped to a single `sudo bash -s` on the far side: the login user's sudo password
# prompt (if any) is then asked once, interactively, rather than per command.
#
# The sudoers file is written via a temp file + `visudo -cf` and only then moved into place. A
# malformed /etc/sudoers.d entry breaks sudo for EVERY user on the box, and this script's own
# login account is usually the only way back in.
build_remote_script() {
  cat <<'REMOTE_HEAD'
set -euo pipefail
PUBKEY="__PUBKEY__"
SUDO_GROUP="$(getent group sudo >/dev/null && echo sudo || echo wheel)"
REMOTE_HEAD

  [ -n "$NEW_HOSTNAME" ] && printf 'hostnamectl set-hostname %q\necho "hostname: %s"\n' \
      "$NEW_HOSTNAME" "$NEW_HOSTNAME"

  for u in "${USER_LIST[@]}"; do
    cat <<REMOTE_USER
USR=$u
if id "\$USR" >/dev/null 2>&1; then
  echo "user \$USR: exists"
else
  # --disabled-password: the account is key-only from the start. A password would be one more
  # credential to rotate, and nothing here ever logs in as these users interactively.
  adduser --disabled-password --gecos "" "\$USR"
  echo "user \$USR: created"
fi
usermod -aG "\$SUDO_GROUP" "\$USR"

HOME_DIR="\$(getent passwd "\$USR" | cut -d: -f6)"
install -d -m 700 -o "\$USR" -g "\$USR" "\$HOME_DIR/.ssh"
touch "\$HOME_DIR/.ssh/authorized_keys"
chown "\$USR:\$USR" "\$HOME_DIR/.ssh/authorized_keys"
chmod 600 "\$HOME_DIR/.ssh/authorized_keys"
# Match on the key BLOB (field 2), not the whole line: the comment differs between callers and
# a comment-only difference would append a duplicate on every run.
BLOB="\$(printf '%s' "\$PUBKEY" | cut -d' ' -f2)"
if grep -qF "\$BLOB" "\$HOME_DIR/.ssh/authorized_keys"; then
  echo "user \$USR: key already present"
else
  printf '%s\n' "\$PUBKEY" >> "\$HOME_DIR/.ssh/authorized_keys"
  echo "user \$USR: key installed"
fi
REMOTE_USER

    if [ "$SUDO_NOPASSWD" = "true" ]; then
      cat <<REMOTE_SUDO
SUDOERS_TMP="\$(mktemp)"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "\$USR" > "\$SUDOERS_TMP"
if visudo -cf "\$SUDOERS_TMP" >/dev/null; then
  install -m 440 -o root -g root "\$SUDOERS_TMP" "/etc/sudoers.d/\$USR"
  echo "user \$USR: passwordless sudo"
else
  echo "user \$USR: ERROR sudoers snippet rejected by visudo — not installed" >&2
  rm -f "\$SUDOERS_TMP"; exit 1
fi
rm -f "\$SUDOERS_TMP"
REMOTE_SUDO
    fi

    # The password is fed to `chpasswd` on ITS OWN stdin via a quoted heredoc, so the value is
    # never an argument (invisible to `ps`) and no shell expansion touches it — a password
    # containing $, ` or \ arrives intact. The delimiter is quoted for the same reason.
    if [ -n "${USER_PW[$u]+x}" ]; then
      cat <<REMOTE_PW
chpasswd <<'EOF_PW_$u'
$u:${USER_PW[$u]}
EOF_PW_$u
# An account created with --disabled-password is also EXPIRED in /etc/shadow on some images,
# which forces a password change at the first console login and looks like the password being
# rejected. Setting one means it is meant to work as given.
passwd -u "$u" >/dev/null 2>&1 || true
chage -M -1 -E -1 "$u" >/dev/null 2>&1 || true
echo "user $u: password set"
REMOTE_PW
    fi
  done
  echo 'echo "done."'
}

REMOTE_SCRIPT="$(build_remote_script)"
# Substituted rather than heredoc-interpolated so the key (which contains / and +) cannot be
# mangled by quoting, and so --dry-run shows exactly what runs.
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PUBKEY__/$PUBKEY}"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Provision users → $ADDR:$PORT"
echo "  Users     : ${USER_LIST[*]}"
echo "  Key source: $KEY_SOURCE"
echo "  Key       : $(printf '%s' "$PUBKEY" | cut -d' ' -f1) …$(printf '%s' "$PUBKEY" | cut -d' ' -f2 | tail -c 17)"
echo "  Auth      : $([ -n "$PASSWORD" ] && echo 'password (sshpass)' || echo 'password (prompted per connection)')"
[ -n "$NEW_HOSTNAME" ] && echo "  Hostname  : $NEW_HOSTNAME"
[ "$SUDO_NOPASSWD" = "true" ] || echo "  Sudo      : NOPASSWD skipped (--no-sudo-nopasswd)"
if [ "$SET_PASSWORDS" = "true" ]; then
  if [ ${#USER_PW[@]} -gt 0 ]; then
    echo "  Passwords : setting for ${!USER_PW[*]}"
  else
    echo "  Passwords : none (all skipped)"
  fi
fi
echo "══════════════════════════════════════════════════"

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "--- remote script (--dry-run, not executed) ---"
  printf '%s\n' "$REMOTE_SCRIPT"
  exit 0
fi

# Capture stderr: "Too many authentication failures" is the single most common way this run
# dies, and a bare disconnect gives no hint that the cause is the ssh-agent's key list rather
# than a wrong password or an unreachable host.
# shellcheck disable=SC2086
if ! CONNECT_ERR="$("${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" 'echo "SSH OK"' 2>&1 >/dev/null)"; then
  printf '%s\n' "$CONNECT_ERR" >&2
  case "$CONNECT_ERR" in
    *"Too many authentication failures"*)
      echo "" >&2
      echo "This is the ssh-agent offering more keys than the box allows (MaxAuthTries," >&2
      echo "default 6) — it disconnects before the password prompt is reached. This script" >&2
      echo "already sets PubkeyAuthentication=no / IdentitiesOnly=yes, so seeing this means" >&2
      echo "something overrode them: check ~/.ssh/config for a Host block matching $HOST." >&2 ;;
    *"Permission denied"*)
      echo "" >&2
      echo "Authentication was refused. Check --login (currently '$LOGIN') and the password." >&2 ;;
  esac
  exit 1
fi
echo "SSH OK"

# -t so a sudo password prompt for the LOGIN user is visible and answerable. The script itself
# arrives on stdin of the remote `bash -s`, which is why sudo cannot read a password from there.
# shellcheck disable=SC2086
printf '%s\n' "$REMOTE_SCRIPT" \
  | "${SSH_CMD[@]}" $SSH_OPTS -p "$PORT" "$ADDR" "sudo -p 'sudo password for $LOGIN: ' bash -s"

echo ""
# Double quotes around the remote command, not single: these lines get pasted into whatever
# shell the operator has open, and cmd.exe/PowerShell do not treat ' as a quote character at
# all — it reaches ssh literally and the remote bash then dies on an unbalanced quote.
# Double quotes work in bash and on Windows alike.
echo "Verify — each of these must succeed WITHOUT a password:"
for u in "${USER_LIST[@]}"; do
  echo "  ssh -p $PORT $u@$HOST \"sudo -n true && echo ok\""
done
if [ ${#USER_PW[@]} -gt 0 ]; then
  echo ""
  echo "Password state (P = password set, L = locked/key-only):"
  echo "  ssh -p $PORT ${USER_LIST[0]}@$HOST \"sudo -n passwd -S ${USER_LIST[*]}\""
fi
echo ""
echo "Next: scripts/provisioning/copyProvisioningScripts.sh $HOST --port $PORT --user ${USER_LIST[0]}"
