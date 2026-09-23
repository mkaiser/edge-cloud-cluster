#!/bin/bash
# Seals the EXTERNAL GitLab credentials the osxcar-sdv-switch job checks out with.
#
# Two values, one secret (they are useless apart — a URL with no token cannot clone a
# private repo, and a token with no URL names nothing):
#   url    — the external repository's clone URL (https://...git)
#   token  — a GitLab PERSONAL ACCESS TOKEN on that instance, scope read_repository
#
# ⚠ NO USERNAME. A GitLab PAT carries its own identity, so HTTP Basic just needs the token
# in the PASSWORD field; the username is ignored and the job sends the fixed literal
# `oauth2` (GitLab's documented placeholder). Asking for a real username here would invite
# someone to pair the PAT with their account name, which works by accident and then breaks
# confusingly the day the token is swapped for a project/group token whose implied user
# differs.
#
# Idempotent: re-running recovers the existing values from the sealed file and reseals
# only when something actually changed (seal_secret compares the decrypted file first),
# so it is safe to run on every recreate.
#
# Needs the Pulumi stack loaded (the sealing key comes from the stack, NOT the cluster):
#   source ./scripts/pulumi/initPulumiStack.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NAMESPACE="osxcar-sdv-switch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEAL="${SCRIPT_DIR}/../../manageSealedSecrets.sh"
# shellcheck source=../../manageSealedSecrets.sh
source "$SEAL"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done
SEALED_FILES=()

echo "=== osxcar-sdv-switch external Git credentials ==="

SEALED="$SCRIPT_DIR/external-git-sealed.yaml"

# try_recover returns empty when the file is absent, so a first run prompts for all three.
EXT_URL=$(try_recover "$SEALED" url)
EXT_TOKEN=$(try_recover "$SEALED" token)

if [[ -n "$EXT_URL" && -n "$EXT_TOKEN" && "$REGEN" != "--regenerate" ]]; then
  echo "  external-git — kept (pass --regenerate to re-enter)."
else
  # ⚠ Prompt for each value rather than keeping a default in git. There is no sensible
  # placeholder for someone else's GitLab instance, and a committed dummy URL would clone
  # successfully-looking nothing.
  read -rp "  external repo clone URL (https://host/group/repo.git): " _u
  [[ -n "$_u" ]] && EXT_URL="$_u"
  # -s: never echoed, and never passed on the command line where `ps` would show it.
  read -rsp "  personal access token (scope read_repository): " _p; echo
  [[ -n "$_p" ]] && EXT_TOKEN="$_p"
fi

[[ -n "$EXT_URL"   ]] || { echo "ERROR: url empty" >&2; exit 1; }
[[ -n "$EXT_TOKEN" ]] || { echo "ERROR: token empty" >&2; exit 1; }

# ⚠ The URL must NOT already carry credentials. The job supplies the token through a git
# askpass helper, so a URL like https://u:p@host/… would authenticate with the EMBEDDED
# credential instead of the sealed token — silently, and it would also write that
# credential into the checkout's remote URL on the shared NFS home.
case "$EXT_URL" in
  *"@"*://* | *://*@*) echo "ERROR: strip the credentials from the URL — supply them separately" >&2; exit 1 ;;
esac

seal_secret "$NAMESPACE" external-git "external-git-sealed.yaml" \
  --from-literal=url="$EXT_URL" \
  --from-literal=token="$EXT_TOKEN"
SEALED_FILES+=("$SCRIPT_DIR/external-git-sealed.yaml")

ask_and_commit_sealed_files "osxcar-sdv-switch: seal external Git credentials" "${SEALED_FILES[@]}"
