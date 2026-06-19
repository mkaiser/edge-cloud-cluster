#!/usr/bin/env bash
# Seals all app secrets for ArgoCD deployment.
# Idempotent: each script recovers existing values from sealed files.
#
# Flags:
#   --regenerate       rotate all auto-generated secrets
#   --skip-git-commit  seal files without prompting to commit
#
# Run order matters: authentik must be first (its bundle is the source for
# all OIDC client secrets; headscale and others read from it).
#
# Requires the Pulumi stack to be loaded:
#   source ./scripts/pulumi/initPulumiStack.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

if ! (cd "$SCRIPT_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded or sealedSecretsTlsKey missing." >&2
  echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
  exit 1
fi

run() {
  local script="$1"
  echo ""
  echo "━━━ $script"
  bash "$SCRIPT_DIR/$script" $REGEN $SKIP_GIT_COMMIT
}

# 1. Authentik first — generates the OIDC bundle all other apps read from
run infra/authentik/sealSecrets.sh

# 2. App secrets — order doesn't matter among these
run apps/gitlab/sealSecrets.sh
run infra/headscale/sealSecrets.sh
run infra/kube-prometheus-stack/sealSecrets.sh
run infra/longhorn/sealSecrets.sh
run apps/nextcloud/sealSecrets.sh
run infra/renovate/sealSecrets.sh
run apps/ryax/sealSecrets.sh
run infra/argocd-infra/sealSecrets.sh
run apps/xwiki/sealSecrets.sh
run apps/zulip/sealSecrets.sh
run apps/rallly/sealSecrets.sh

echo ""
echo "All secrets sealed."
