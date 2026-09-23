#!/bin/bash
# Seals the remote-desktop secrets for ArgoCD deployment.
# Idempotent: recovers existing values from the sealed files on re-runs.
# Pass --regenerate to rotate generated passwords.
#
# Guacamole is a PUBLIC OIDC client (no client secret). Generates:
#   remote-desktop-secrets-sealed.yaml        — db + rdp (licences: see eda/secrets)
#   guacamole-pg-user-sealed.yaml             — CNPG bootstrap user (password == db-password)
#   remote-desktop-s3-secret-sealed.yaml      — Hetzner S3 keys (CNPG backup bucket)
#   authentik-provisioner-token-sealed.yaml   — scoped Authentik API token
#
# provisioner-token is recovered (from the central
# authentik bundles) — no re-entry needed on this cluster.
set -euo pipefail

NAMESPACE="remote-desktop"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

# Add an argocd sync-wave annotation to a sealed secret file (CNPG bootstrap user +
# S3 secret must exist at wave -1, before the guacamole-pg Cluster reconciles).
add_sync_wave() {
  local file="$1" wave="$2"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f: content = f.read()
anno = '  annotations:\n    argocd.argoproj.io/sync-wave: \"' + sys.argv[2] + '\"\n'
if 'argocd.argoproj.io/sync-wave' in content: sys.exit(0)
content = re.sub(r'(^  namespace: [^\n]+\n)', lambda m: m.group(0) + anno, content, count=1, flags=re.MULTILINE)
with open(sys.argv[1], 'w') as f: f.write(content)
" "$file" "$wave"
}

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

SEALED="$SCRIPT_DIR/remote-desktop-secrets-sealed.yaml"

DB_PASSWORD=$(recover_or_generate "$SEALED" db-password "$REGEN")
RDP_PASSWORD=$(recover_or_generate "$SEALED" rdp-password "$REGEN")


# ⚠ NO LICENCE KEYS HERE ANY MORE. They moved to eda/secrets (sealed as `eda-secrets`
# into BOTH remote-desktop and gitlab-runner from one value) because licensing is an EDA
# concern, not a desktop one: five EDA module manifests reference it and the desktop is now
# only one of two runtimes that needs it. Do not re-add them — two copies would drift, and
# the FlexNet/SALT split (see eda/secrets/sealSecrets.sh) is easy to get wrong.
seal_secret "$NAMESPACE" remote-desktop-secrets remote-desktop-secrets-sealed.yaml \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=rdp-password="$RDP_PASSWORD"
SEALED_FILES+=("remote-desktop-secrets-sealed.yaml")



# CNPG bootstrap user — password == db-password so the app + connection-seed
# (which use remote-desktop-secrets:db-password) authenticate as guacamole_user.
seal_secret "$NAMESPACE" guacamole-pg-user guacamole-pg-user-sealed.yaml \
  --from-literal=username="guacamole_user" \
  --from-literal=password="$DB_PASSWORD"
add_sync_wave "$SCRIPT_DIR/guacamole-pg-user-sealed.yaml" "-1"
SEALED_FILES+=("guacamole-pg-user-sealed.yaml")

# Hetzner S3 keys (CNPG barmanObjectStore + s3-buckets-job). wave -1.
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }
seal_secret "$NAMESPACE" remote-desktop-s3-secret remote-desktop-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"
add_sync_wave "$SCRIPT_DIR/remote-desktop-s3-secret-sealed.yaml" "-1"
SEALED_FILES+=("remote-desktop-s3-secret-sealed.yaml")

# Scoped Authentik provisioner token (same plaintext as central AUTHENTIK_PROVISIONER_TOKEN).
PROV_TOKEN=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
[[ -z "$PROV_TOKEN" ]] && PROV_TOKEN=$(try_recover "$SCRIPT_DIR/authentik-provisioner-token-sealed.yaml" token)
[[ -z "$PROV_TOKEN" ]] && { read -rsp "  paste AUTHENTIK_PROVISIONER_TOKEN (from authentik-secrets bundle): " PROV_TOKEN; echo; }
[[ -z "$PROV_TOKEN" ]] && { echo "ERROR: provisioner token empty — run authentik/sealSecrets.sh first" >&2; exit 1; }
seal_secret "$NAMESPACE" authentik-provisioner-token authentik-provisioner-token-sealed.yaml \
  --from-literal=token="$PROV_TOKEN"
SEALED_FILES+=("authentik-provisioner-token-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST
# command makes the script exit 1, so --skip-git-commit looks like a failure
# to the caller (sealAllSecrets.sh runs each app with `bash <script>`).
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal remote-desktop secrets" "${ABS_FILES[@]}"
fi
echo "remote-desktop secrets sealed."
