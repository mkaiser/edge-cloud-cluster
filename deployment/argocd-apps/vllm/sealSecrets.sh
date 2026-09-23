#!/bin/bash
# Seals vLLM secrets (Plan B).
# Idempotent: recovers existing values from sealed files on re-runs.
# Pass --regenerate to rotate the upstream key.
#
# Generates:
#   vllm-upstream-sealed.yaml       — vLLM upstream API key (key api-key). The SINGLE
#     credential LiteLLM presents to vLLM; LiteLLM seals the SAME plaintext
#     (litellm/sealSecrets.sh recovers it from here). Rotating means re-running BOTH.
# The registry PULL credential (vllm-registry-cred) is NOT sealed here — it is created
# at bootstrap by the PreSync job presync-registry-cred.yaml (mints a read_registry
# deploy token in live GitLab + writes the dockerconfigjson). See that file for why an
# offline seal can't work for a registry cred. The CI build pushes with CI_REGISTRY_*.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# --- vLLM upstream API key (shared with LiteLLM) ---
VLLM_API_KEY=$(recover_or_generate "$SCRIPT_DIR/vllm-upstream-sealed.yaml" api-key "$REGEN" 32)
seal_secret vllm vllm-upstream vllm-upstream-sealed.yaml \
  --from-literal=api-key="$VLLM_API_KEY"

# --- GitLab registry PULL credential ---
# NOT sealed here. A registry pull cred must exist BOTH as a k8s secret AND as a live
# GitLab credential, and GitLab's DB is recreated empty each cluster — which an offline
# seal can't satisfy (the old sealed vllm-registry-cred went stale every recreate: wrong
# host + a token that no longer existed → pull 403). It is now created at bootstrap by
# the PreSync job deployment/argocd-apps/vllm/presync-registry-cred.yaml, which mints a
# read_registry deploy token in GitLab and writes the dockerconfigjson into the vllm ns
# with the current (plaintext) registry host. Self-heals on every recreate; nothing to
# seal.

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal vLLM secrets" \
    "$SCRIPT_DIR/vllm-upstream-sealed.yaml"
fi
