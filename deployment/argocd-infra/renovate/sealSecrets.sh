#!/usr/bin/env bash
# Seals the Renovate GitHub PAT for the Renovate CronJob.
# Value derived from the Pulumi stack (githubPatToken) — run
# scripts/secrets/setGithubPatToken.sh first.
# The token needs 'repo' scope to read the private repo and open pull requests.
#
# Generates:
#   renovate-token-sealed.yaml  — GitHub PAT for Renovate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/manageSealedSecrets.sh"

SKIP_GIT_COMMIT=""
for arg in "$@"; do [[ "$arg" == "--skip-git-commit" ]] && SKIP_GIT_COMMIT="--skip-git-commit"; done

if ! (cd "$REPO_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded. Run: source ./scripts/pulumi/initPulumiStack.sh" >&2; exit 1
fi

namespace="renovate"
secret_name="renovate-token"
sealed_file="$SCRIPT_DIR/${secret_name}-sealed.yaml"

TOKEN="$(cd "$REPO_DIR/.." && pulumi config get githubPatToken 2>/dev/null || true)"
: "${TOKEN:?githubPatToken not set — run scripts/secrets/setGithubPatToken.sh}"

seal_secret "$namespace" "$secret_name" "${secret_name}-sealed.yaml" \
  --from-literal=token="$TOKEN"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal $namespace secrets" "$sealed_file"
fi
