#!/usr/bin/env bash
# Seals all argocd-APPS secrets for ArgoCD deployment.
# Idempotent: each app's sealSecrets.sh recovers existing values from sealed files.
#
# This script is self-contained and can be run on its own. It is also invoked by
# the super-script deployment/sealAllSecrets.sh, which seals BOTH argocd-infra
# and argocd-apps and aggregates their commits.
#
# NOTE: this folder is being prepared to live in its own repository. It still
# sources deployment/manageSealedSecrets.sh (one level up); when argocd-apps moves
# out, manageSealedSecrets.sh must be vendored/relocated alongside it.
#
# Commit behaviour: by DEFAULT all apps are sealed first with no per-app prompt,
# then a SINGLE combined prompt at the end lists every changed sealed file. When
# the super-script sets SEAL_DEFER_COMMIT=1 this script instead prints its changed
# files on "SEALED-FILE:" lines and does NOT commit — the super-script owns the
# aggregated commit.
#
# Flags:
#   --regenerate       rotate all auto-generated secrets
#   --commit-per-app   old behaviour: prompt to commit after each app (no final
#                      combined prompt). Env COMMIT_PER_APP=1 also works.
#   --skip-git-commit  seal files without prompting to commit at all.
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
  echo "━━━ argocd-apps/$app/sealSecrets.sh"
  # No output capture — stdout/stderr go to the terminal so prompts work; the
  # app appends any changed files to $SEAL_EMIT_FILE.
  bash "$SCRIPT_DIR/$app/sealSecrets.sh" $REGEN $CHILD_SKIP
}

echo "=== Sealing argocd-apps secrets ==="

# Order doesn't matter among these — each app is self-contained.
run nextcloud
run gitlab
run cape-demo/ryax
run xwiki
run zulip
run rallly
run jitsi
run rocketchat
run windows
run zammad
# EDA desktops — recover AUTHENTIK_PROVISIONER_TOKEN from the argocd-infra authentik
# bundle (run argocd-infra/authentik/sealSecrets.sh first).
run remote-desktop
# The second desktop. Seals only its own rdp-password: its Guacamole tile reads
# remote-desktop's DB password LIVE from that namespace rather than sealing a second copy
# that would diverge on rotation.
run remote-desktop-bender
# image-registry seals ONE password into FOUR namespaces (image-registry, gitlab-runner and
# both desktops), so it must not be skipped: without it every EDA build trigger exits 1
# with "run deployment/argocd-apps/image-registry/sealSecrets.sh and sync that app first",
# and a fresh cluster comes up with the whole EDA build stack broken.
run image-registry
# eda-fileserver seals its SCOPED AUTHENTIK PROVISIONER TOKEN, and nothing else: no
# TrueNAS credential is sealed here, because the provisioning Job MINTS its own scoped
# TrueNAS API key on first run and caches it in a Secret it owns, while the appliance admin
# it bootstraps from is sealed for that namespace by argocd-infra/truenas/sealSecrets.sh
# alongside the truenas and samba-ad copies. Must follow argocd-infra/authentik, which
# generates the bundle this token is recovered from.
run eda/fileserver
# eda/secrets seals the EDA LICENCE SERVERS into every namespace that RUNS a module
# (both desktops and gitlab-runner today). Like image-registry it must not be skipped:
# without it the desktop and the [eda-run] build pods start with no licence, `module load`
# still succeeds, and the tool then fails its own licence checkout — a confusing failure
# several steps from the cause.
run eda/secrets
# eda-pcb-agent recovers AUTHENTIK_PROVISIONER_TOKEN from the argocd-infra authentik bundle,
# like remote-desktop and eda/fileserver above, so it must follow argocd-infra/authentik.
# It seals no copy of any shared superuser credential — the three it needs are read live
# from their own namespaces (see the header of its script).
run eda-pcb-agent
# The four eda-* module BUILD apps have NO secrets of their own: their installer media is
# on the TrueNAS artifacts export and their registry credential is sealed by image-registry
# above. Nothing to seal.

# LLM stack (Plan B) — ORDER MATTERS: litellm recovers the upstream key of EVERY vLLM
# backend (vllm = Thor, vllm-orin = Orin; each owns its own key), and both open-webui and
# hermes recover litellm's master key. Keep the vllm* apps → litellm → the rest.
run vllm
run vllm-orin
run litellm
run open-webui
# hermes was missing from this list, which is why `hermes-secrets` never existed and the
# pod sat in Init:CreateContainerConfigError for 2+ days. Must follow litellm.
# searxng before hermes: hermes does not consume its secret (only its URL), so order is
# cosmetic, but keeping the search backend ahead of its consumer matches the vllm->litellm
# convention above.
run searxng
run hermes

# Self-contained: the external GitLab clone URL + read_repository PAT for the mirror job.
# Nothing else recovers from it, so its position is free.
run osxcar-sdv-switch

# The SCADA demo's PostgreSQL credentials. Self-contained and nothing recovers from it, so
# its position is free. ⚠ Unlike every other app here it GENERATES nothing — the workflow
# modules carry the connection string compiled in, so it recovers from its sealed file,
# else $CAPE_DEMO_PG_{USER,DB,PASSWORD}, else prompts.
run cape-demo/ipto-scada-anomaly-detector

echo ""
echo "All argocd-apps secrets sealed."

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
    ask_and_commit_sealed_files "Seal argocd-apps secrets" "${DEFERRED_FILES[@]}"
  fi
fi
