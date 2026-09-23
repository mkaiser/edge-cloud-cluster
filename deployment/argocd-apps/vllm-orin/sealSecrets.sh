#!/bin/bash
# Seals the vLLM-on-Orin secrets.
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate the upstream key.
#
# Generates:
#   vllm-orin-upstream-sealed.yaml  — vLLM upstream API key (key api-key). The SINGLE
#     credential LiteLLM presents to THIS vLLM. It is a MACHINE secret, so it is
#     auto-generated and never prompted for (see the KEG-vs-auto policy in
#     doc/backup-restore.md).
#
# ⚠ SEPARATE KEY FROM THE THOR'S, ON PURPOSE. The Thor app seals `vllm-upstream` in the
# `vllm` namespace; this seals `vllm-orin-upstream` in `vllm-orin`. A Secret is namespaced,
# so the Thor's could not be read here anyway — and two independent backends should not
# share one credential: rotating or compromising one must not reach the other. LiteLLM
# therefore carries BOTH (VLLM_API_KEY and VLLM_ORIN_API_KEY) and recovers each from the
# app that owns it. Run this BEFORE litellm/sealSecrets.sh.
#
# The registry PULL credential (vllm-registry-cred) is NOT sealed here — it is created at
# bootstrap by the PreSync job presync-registry-cred.yaml (mints a read_registry deploy
# token in live GitLab + writes the dockerconfigjson). An offline seal cannot work for a
# registry cred: GitLab's DB is recreated empty each cluster, so a sealed token goes stale
# every recreate (wrong host + a token that no longer exists → pull 403).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# --- vLLM upstream API key (shared with LiteLLM, which recovers it from this file) ---
VLLM_ORIN_API_KEY=$(recover_or_generate "$SCRIPT_DIR/vllm-orin-upstream-sealed.yaml" api-key "$REGEN" 32)
seal_secret vllm-orin vllm-orin-upstream vllm-orin-upstream-sealed.yaml \
  --from-literal=api-key="$VLLM_ORIN_API_KEY"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal vLLM-Orin secrets" \
    "$SCRIPT_DIR/vllm-orin-upstream-sealed.yaml"
fi
