#!/bin/bash
# Seals the S3 credentials for the appliance's SeaweedFS endpoint.
#
# These are the ONLY thing standing between the lab LAN and an object store that holds
# every CI artifact. SeaweedFS decides whether to enforce authentication at all with
# `isAuthEnabled = len(identities) > 0` (weed/s3api/auth_credentials.go) — so an empty or
# missing credential does not fail closed, it serves anonymous read AND write. See
# plans/truenas-s3-setup.md.
#
# Generates:
#   truenas-s3-admin-sealed.yaml — S3_ACCESS_KEY / S3_SECRET_KEY, namespace samba-ad
#
# Both values are MACHINE credentials — no human ever types them — so they are generated,
# never prompted. `recover_or_generate` keeps them stable across re-runs by unsealing the
# existing file; pass --regenerate to rotate.
#
# ⚠ THE SEALED FILE IS THE SOURCE OF TRUTH, NOT THE APPLIANCE. After --regenerate you must
# re-run the converge that pushes AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY into the app's
# `seaweedfs.additional_envs`, or the sealed value and the live endpoint disagree and every
# GitLab request fails with SignatureDoesNotMatch.
#
# ⚠ GitLab's own connection secret is sealed by deployment/argocd-apps/gitlab/sealSecrets.sh,
# which recovers THESE values with `recover_from_sealed` rather than generating its own.
# Rotating here therefore means resealing there too.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEAL="${SCRIPT_DIR}/../../manageSealedSecrets.sh"
# shellcheck source=../../manageSealedSecrets.sh
source "$SEAL"

NAMESPACE="samba-ad"   # same namespace as truenas-admin: the converge Job runs there
SEALED="$SCRIPT_DIR/truenas-s3-admin-sealed.yaml"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done
SEALED_FILES=()

echo "=== TrueNAS S3 credential setup ==="

# 20 and 40 characters, matching the shape AWS SDKs and tooling expect. Hex rather than
# base64 on purpose: an S3 access key travels through URLs, shell variables and TOML/YAML
# config, and `+` and `/` need escaping in several of those.
ACCESS_KEY=$(recover_or_generate "$SEALED" S3_ACCESS_KEY "$REGEN" 10)
SECRET_KEY=$(recover_or_generate "$SEALED" S3_SECRET_KEY "$REGEN" 20)

seal_secret "$NAMESPACE" truenas-s3-admin truenas-s3-admin-sealed.yaml \
  --from-literal=S3_ACCESS_KEY="$ACCESS_KEY" \
  --from-literal=S3_SECRET_KEY="$SECRET_KEY"
SEALED_FILES+=("$SEALED")

echo
echo "Sealed S3 credentials into ${NAMESPACE}/truenas-s3-admin."
echo "  access key: ${ACCESS_KEY:0:6}… (${#ACCESS_KEY} chars)"
echo "  secret key: (${#SECRET_KEY} chars, not shown)"
echo
if [[ "$REGEN" == "--regenerate" ]]; then
  echo "⚠ ROTATED. The live endpoint still has the OLD key until the converge Job runs and"
  echo "  updates seaweedfs.additional_envs. Until then S3 requests fail with"
  echo "  SignatureDoesNotMatch — which reads like a clock or path-style problem, not a"
  echo "  credential one. Re-seal GitLab's connection secret as well."
fi

ask_and_commit_sealed_files "$SKIP_GIT_COMMIT" "${SEALED_FILES[@]}"
