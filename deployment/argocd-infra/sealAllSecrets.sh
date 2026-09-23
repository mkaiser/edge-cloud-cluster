#!/usr/bin/env bash
# Seals all argocd-INFRA app secrets for ArgoCD deployment.
# Idempotent: each app's sealSecrets.sh recovers existing values from sealed files.
#
# This script is self-contained and can be run on its own. It is also invoked by
# the super-script deployment/sealAllSecrets.sh, which seals BOTH argocd-infra
# and argocd-apps and aggregates their commits.
#
# Commit behaviour: by DEFAULT all infra apps are sealed first with no per-app
# prompt, then a SINGLE combined prompt at the end lists every changed sealed
# file. When the super-script sets SEAL_DEFER_COMMIT=1 this script instead prints
# its changed files on "SEALED-FILE:" lines and does NOT commit — the super-script
# owns the aggregated commit.
#
# Flags:
#   --regenerate       rotate all auto-generated secrets
#   --commit-per-app   old behaviour: prompt to commit after each app (no final
#                      combined prompt). Env COMMIT_PER_APP=1 also works.
#   --skip-git-commit  seal files without prompting to commit at all.
#
# Run order: authentik must be first because (a) it still holds the OIDC client
# secrets for apps NOT yet migrated to per-app OIDC (headscale, grafana, nextcloud,
# xwiki, zulip, rallly read them from its bundle via blueprint !Env), and (b) it
# now also holds the one shared AUTHENTIK_PROVISIONER_TOKEN that per-app apps
# (Part B; jitsi) recover from the bundle.
#
# Requires the Pulumi stack to be loaded:
#   source ./scripts/pulumi/initPulumiStack.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # deployment/ — holds manageSealedSecrets.sh
REGEN=""; SKIP_GIT_COMMIT=""; PER_APP="${COMMIT_PER_APP:+1}"
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
  --commit-per-app)  PER_APP="1" ;;
esac; done

# Default = defer: each app's sealSecrets.sh appends its changed files to a shared
# temp file (SEAL_EMIT_FILE) instead of prompting; we commit them once at the end.
# Apps run with stdout/stderr passed straight through, so their INTERACTIVE
# prompts work normally (the marker channel is the temp file, never stdout).
# If the super-script already exported SEAL_EMIT_FILE, we inherit it and let the
# super own the final commit (OWN_EMIT="").
CHILD_SKIP="$SKIP_GIT_COMMIT"
OWN_EMIT=""
if [[ "${SEAL_DEFER_COMMIT:-}" == "1" && -n "${SEAL_EMIT_FILE:-}" ]]; then
  CHILD_SKIP=""                         # inherited from super — apps emit, no commit
elif [[ -z "$SKIP_GIT_COMMIT" && -z "$PER_APP" ]]; then
  CHILD_SKIP=""                         # let the helper run (in defer/emit mode)
  SEAL_EMIT_FILE="$(mktemp)"; OWN_EMIT="1"
  export SEAL_DEFER_COMMIT=1 SEAL_EMIT_FILE
fi

if ! (cd "$DEPLOY_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded or sealedSecretsTlsKey missing." >&2
  echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
  exit 1
fi

run() {
  local app="$1"
  echo ""
  echo "━━━ argocd-infra/$app/sealSecrets.sh"
  # No output capture — stdout/stderr go to the terminal so prompts work; the
  # app appends any changed files to $SEAL_EMIT_FILE.
  bash "$SCRIPT_DIR/$app/sealSecrets.sh" $REGEN $CHILD_SKIP
}

echo "=== Sealing argocd-infra secrets ==="

# 1. Authentik first — generates the OIDC bundle the other apps read from
run authentik

# 2. App secrets — order doesn't matter among these
run headscale
run prometheus/kube-prometheus-stack
run longhorn-system
run renovate
# NB no argocd-infra-self: its SMTP credentials are created directly by Pulumi
# (src/argocd.ts, Secret argocd-infra/smtp-credentials), not sealed into git.
# loki seals the Hetzner S3 credentials for its chunk store; samba-ad seals the whole
# sambacc config document, with the AD domain admin password inside it. Both recover their
# existing values from their sealed file, so re-running rotates nothing.
run loki
run samba-ad
# truenas seals the APPLIANCE's own admin credential (not the AD domain admin, which lives
# in the sambacc config). Recovers the existing value from its sealed file, so an unrelated
# re-run does not prompt.
run truenas

echo ""
echo "All argocd-infra secrets sealed."

# Only the OWNER of the emit file commits; if the super created it, it commits.
if [[ -n "$OWN_EMIT" ]]; then
  mapfile -t DEFERRED_FILES < <(sort -u "$SEAL_EMIT_FILE")
  rm -f "$SEAL_EMIT_FILE"; unset SEAL_DEFER_COMMIT SEAL_EMIT_FILE
  # shellcheck source=../manageSealedSecrets.sh
  source "$DEPLOY_DIR/manageSealedSecrets.sh"  # provides ask_and_commit_sealed_files
  echo ""
  if [[ ${#DEFERRED_FILES[@]} -eq 0 ]]; then
    echo "No sealed files changed — nothing to commit."
  else
    ask_and_commit_sealed_files "Seal argocd-infra secrets" "${DEFERRED_FILES[@]}"
  fi
fi
