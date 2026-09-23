#!/bin/bash
# Seals the Hetzner S3 credentials Loki uses for its chunk/index store.
#
# Loki keeps log chunks in Hetzner Object Storage rather than on a PVC: the cloud
# tier runs storage.longhorn.replicaCount=1 (so a PVC would be unreplicated), logs grow
# without bound, and a PVC does not survive an eccN cluster recreate while an S3
# bucket keyed on general.name does.
#
# Generates:
#   loki-s3-secret-sealed.yaml — ACCESS_KEY_ID / SECRET_ACCESS_KEY
#
# The key NAMES match what s3-buckets-job.yaml and the Loki chart's
# `loki.storage.s3.{accessKeyId,secretAccessKey}` env wiring expect. Same Hetzner
# credentials as every other app bucket; nothing app-specific is generated here,
# so re-running is always safe and never rotates anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
S3_ACCESS=$(pc hetznerS3AccessKey)
S3_SECRET=$(pc hetznerS3SecretKey)
[[ -z "$S3_ACCESS" ]] && { echo "ERROR: hetznerS3AccessKey not in Pulumi config" >&2; exit 1; }
[[ -z "$S3_SECRET" ]] && { echo "ERROR: hetznerS3SecretKey not in Pulumi config" >&2; exit 1; }

seal_secret loki loki-s3-secret loki-s3-secret-sealed.yaml \
  --from-literal=ACCESS_KEY_ID="$S3_ACCESS" --from-literal=SECRET_ACCESS_KEY="$S3_SECRET"

echo
echo "Sealed: deployment/argocd-infra/loki/loki-s3-secret-sealed.yaml"
echo "Commit it, then let ArgoCD sync the loki app."
