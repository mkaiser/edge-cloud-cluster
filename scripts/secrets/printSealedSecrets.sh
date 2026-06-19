#!/usr/bin/env bash
# Decrypts and prints all sealed secrets in deployment/ using the private key
# from the Pulumi stack.
#
# Usage:
#   source ./scripts/pulumi/initPulumiStack.sh   # load stack once
#   bash scripts/misc/printSealedSecrets.sh
#   bash scripts/misc/printSealedSecrets.sh deployment/xwiki  # single dir
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEARCH_ROOT="${1:-$REPO_DIR/deployment}"

if ! (cd "$REPO_DIR" && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: sealedSecretsTlsKey not found. Load the Pulumi stack first:" >&2
  echo "  source ./scripts/pulumi/initPulumiStack.sh" >&2
  exit 1
fi

PRIVKEY=$(cd "$REPO_DIR" && pulumi config get sealedSecretsTlsKey)

mapfile -t SEALED_FILES < <(find "$SEARCH_ROOT" -name "*-sealed.yaml" | sort)

if [[ ${#SEALED_FILES[@]} -eq 0 ]]; then
  echo "No sealed secret files found in $SEARCH_ROOT"
  exit 0
fi

for file in "${SEALED_FILES[@]}"; do
  rel="${file#"$REPO_DIR/"}"
  echo "━━━ $rel"

  decrypted=$(kubeseal --recovery-unseal \
      --recovery-private-key <(echo "$PRIVKEY") \
      < "$file" -o json 2>/dev/null) || {
    echo "  (decryption failed — wrong key or not a SealedSecret)"
    echo ""
    continue
  }

  echo "$decrypted" \
    | jq -r '.data // {} | to_entries[] | "  \(.key) = \(.value | @base64d)"'
  echo ""
done
