#!/bin/bash
# Seals the SearXNG secret.
# Idempotent: recovers the existing value from the sealed file on re-runs.
# Pass --regenerate to rotate the signing key.
#
# Generates:
#   searxng-secrets-sealed.yaml — key `secret-key`, consumed as SEARXNG_SECRET.
#     Signs SearXNG's per-query/session tokens. It MUST be set: the upstream default is the
#     literal placeholder `secret_key: "ultrasecretkey"` in settings.yml, which the env var
#     overrides. Rotating it is harmless here — SearXNG keeps no durable state, so nothing is
#     invalidated beyond in-flight sessions (and the only client is a machine).
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

SECRET_KEY=$(recover_or_generate "$SCRIPT_DIR/searxng-secrets-sealed.yaml" secret-key "$REGEN" 32)

seal_secret searxng searxng-secrets searxng-secrets-sealed.yaml \
  --from-literal=secret-key="$SECRET_KEY"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST command makes the
# script exit 1, so --skip-git-commit looks like a failure to the caller.
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal SearXNG secrets" "$SCRIPT_DIR/searxng-secrets-sealed.yaml"
fi
