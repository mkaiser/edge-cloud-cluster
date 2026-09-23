#!/bin/bash
# Seals Headscale secrets for ArgoCD deployment.
# Can be run BEFORE cluster creation — uses the sealed-secrets public key
# stored in Pulumi config (sealedSecretsTlsCrt), no live cluster required.
# Commit ALL output files — sealed files are encrypted and safe for git.
#
# Part B (self-contained OIDC): the OIDC client secret is generated HERE (no
# longer recovered from the central authentik bundle) and the scoped provisioner
# token is sealed alongside; headscale/authentik-provider.yaml registers the
# provider/tile live via the Authentik API.
#
# Generates:
#   oidc-client-secret-sealed.yaml            — OIDC client secret for headscale + headplane (key client-secret)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token (Part B)
#   pg-user-secret-sealed.yaml                — PostgreSQL user credentials for CNPG Cluster
#   s3-secret-sealed.yaml                     — Hetzner S3 credentials for CNPG barman backups
set -euo pipefail

NAMESPACE="headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# Add argocd sync-wave annotation to a sealed secret file so it is applied
# at that wave within the Application (before the CNPG Cluster at wave 0).
add_sync_wave() {
  local file="$1" wave="$2"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
# Idempotent: if a sync-wave annotation already exists anywhere, leave the file
# alone (re-runs must not append a second, mis-indented block).
if 'argocd.argoproj.io/sync-wave' in content:
    sys.exit(0)
# Anchor to the TOP-LEVEL metadata.namespace only (exactly 2-space indent at
# line start). Without ^ + MULTILINE the old regex also matched the 6-space
# template.metadata.namespace and inserted a 2-space 'annotations:' under spec
# (structurally invalid -> the SealedSecret never applied).
content = re.sub(
    r'(^  namespace: [^\n]+\n)',
    lambda m: m.group(0) + anno,
    content, count=1, flags=re.MULTILINE
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$file" "$wave"
}

pcfg() { (cd "$SCRIPT_DIR/../.." && pulumi config get "$1" 2>/dev/null || true); }

AUTHENTIK_BUNDLE="$SCRIPT_DIR/../authentik/authentik-secrets-sealed.yaml"

# OIDC client secret — owned here now (key client-secret), consumed by the
# headscale post-deploy job + the authentik-provider.yaml registration job.
OIDC_CLIENT_SECRET=$(recover_or_generate "$SCRIPT_DIR/oidc-client-secret-sealed.yaml" client-secret "$REGEN" 32)
seal_secret "$NAMESPACE" headscale-oidc-client-secret oidc-client-secret-sealed.yaml \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET"
SEALED_FILES+=("oidc-client-secret-sealed.yaml")

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$AUTHENTIK_BUNDLE" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
if [[ -z "$PROV_TOKEN" ]]; then
  read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo
fi
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret "$NAMESPACE" authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"
SEALED_FILES+=("authentik-provisioner-token-sealed.yaml")

# PostgreSQL user credentials for CNPG Cluster bootstrap (headscale-pg-user secret)
PG_BUNDLE="$SCRIPT_DIR/pg-user-secret-sealed.yaml"
PG_PASSWORD=$(recover_or_generate "$PG_BUNDLE" password "$REGEN")

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
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal $NAMESPACE secrets" "${ABS_FILES[@]}"
fi
