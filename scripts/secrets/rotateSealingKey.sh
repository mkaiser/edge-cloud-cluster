#!/usr/bin/env bash
# Rotates the sealed-secrets TLS keypair.
#
# WARNING: This invalidates ALL existing sealed secrets on the cluster.
# The cluster controller must be restarted with the new key, and all sealed
# files must be re-committed before ArgoCD syncs again.
#
# Steps performed:
#   1. Generate a new RSA-4096 TLS keypair
#   2. Store new cert + key in the Pulumi stack
#   3. Re-seal all deployment secrets with the new cert
#   4. Print next manual steps
#
# The old sealed secrets remain on the cluster until ArgoCD syncs the new ones.
# The controller will fail to decrypt them until you restart it with the new key
# (Pulumi apply handles this via the sealedSecretsTlsCrt/Key stack values).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deployment"

echo "=== Sealed-secrets TLS keypair rotation ==="
echo ""
echo "WARNING: This will invalidate all sealed secrets on the running cluster."
echo "Ensure you have committed and pushed the current sealed files before proceeding."
echo ""
read -rp "Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
echo "Generating new RSA-4096 TLS keypair..."
TMP_KEY=$(mktemp)
TMP_CRT=$(mktemp)
trap 'rm -f "$TMP_KEY" "$TMP_CRT"' EXIT

openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout "$TMP_KEY" \
  -out    "$TMP_CRT" \
  -subj "/CN=sealed-secret/O=sealed-secrets" \
  -days 13650

echo "Storing new keypair in Pulumi stack..."
(cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsCrt < "$TMP_CRT")
(cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsKey < "$TMP_KEY")
echo "  Stored."

echo ""
echo "Re-sealing all deployment secrets with the new cert..."
bash "$DEPLOY_DIR/sealAllSecrets.sh" --regenerate

echo ""
echo "=== Done. Next steps ==="
echo "  1. git add deployment/ && git commit -m 'Rotate sealed-secrets TLS keypair'"
echo "  2. git push"
echo "  3. pulumi up  — updates the controller with the new keypair"
echo "  4. ArgoCD will sync the re-sealed secrets automatically"
