#!/bin/bash
# Seals Headscale secrets for ArgoCD deployment.
# Can be run BEFORE cluster creation — uses the sealed-secrets public key
# stored in Pulumi config (sealedSecretsTlsCrt), no live cluster required.
# Commit ALL output files — sealed files are encrypted and safe for git.
#
# Requires: deployment/authentik/sealSecrets.sh to have been run first
# (OIDC secret is recovered from the authentik bundle).
#
# Generates:
#   oidc-client-secret-sealed.yaml     — OIDC client secret for headscale + headplane
#   pg-user-secret-sealed.yaml         — PostgreSQL user credentials for CNPG Cluster
#   s3-secret-sealed.yaml              — Hetzner S3 credentials for CNPG barman backups
set -euo pipefail

NAMESPACE="headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

SKIP_GIT_COMMIT=""
for arg in "$@"; do [[ "$arg" == "--skip-git-commit" ]] && SKIP_GIT_COMMIT="--skip-git-commit"; done

# Add argocd sync-wave annotation to a sealed secret file so it is applied
# at that wave within the Application (before the CNPG Cluster at wave 0).
add_sync_wave() {
  local file="$1" wave="$2"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
# Insert after 'namespace: X' in top-level SealedSecret metadata if not already present
content = re.sub(
    r'(  namespace: [^\n]+\n)(?!  annotations:)',
    lambda m: m.group(0) + anno,
    content, count=1
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$file" "$wave"
}

pcfg() { (cd "$SCRIPT_DIR/../.." && pulumi config get "$1" 2>/dev/null || true); }

AUTHENTIK_BUNDLE="$SCRIPT_DIR/../authentik/authentik-secrets-sealed.yaml"
OIDC_CLIENT_SECRET=$(recover_from_sealed "$AUTHENTIK_BUNDLE" HEADSCALE_OIDC_CLIENT_SECRET)

seal_secret "$NAMESPACE" headscale-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

# PostgreSQL user credentials for CNPG Cluster bootstrap (headscale-pg-user secret)
PG_BUNDLE="$SCRIPT_DIR/pg-user-secret-sealed.yaml"
PG_PASSWORD=$(recover_or_generate "$PG_BUNDLE" password)

seal_secret "$NAMESPACE" headscale-pg-user pg-user-secret-sealed.yaml \
  --from-literal=username="headscale" \
  --from-literal=password="$PG_PASSWORD"
add_sync_wave "${SCRIPT_DIR}/pg-user-secret-sealed.yaml" "-1"
SEALED_FILES+=("pg-user-secret-sealed.yaml")

# Hetzner S3 credentials for CNPG barman backups (headscale-s3-secret)
S3_ACCESS_KEY=$(pcfg hetznerS3AccessKey)
S3_SECRET_KEY=$(pcfg hetznerS3SecretKey)
[[ -z "$S3_ACCESS_KEY" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET_KEY" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }

seal_secret "$NAMESPACE" headscale-s3-secret s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  --from-literal=SECRET_ACCESS_KEY="$S3_SECRET_KEY"
add_sync_wave "${SCRIPT_DIR}/s3-secret-sealed.yaml" "-1"
SEALED_FILES+=("s3-secret-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do
  ABS_FILES+=("${SCRIPT_DIR}/${f}")
done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
