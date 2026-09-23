#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$THIS_DIR/inputHelpers.sh"

echo ""
echo "Configuring Sealed Secrets TLS keypair..."
echo "The sealed-secrets controller uses this keypair to encrypt/decrypt SealedSecrets."
echo ""

if (cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt &>/dev/null); then
    echo "  A keypair is already stored in the Pulumi stack."
    while true; do
        read -rp "Keep existing [k], enter new [e], or generate new [g]? " choice
        [[ "$choice" =~ ^[KkEeGg]$ ]] && break
        echo "  Please answer k, e, or g."
    done
else
    echo "  No keypair found in the Pulumi stack."
    while true; do
        read -rp "Enter existing keypair [e] or generate new [g]? " choice
        [[ "$choice" =~ ^[EeGg]$ ]] && break
        echo "  Please answer e or g."
    done
fi

case "$choice" in
  [Kk])
    echo "  Keeping existing sealed-secrets keypair."
    ;;
  [Ee])
    read_multiline_var sealed_secrets_crt "Paste the TLS certificate"
    printf '%s\n' "$sealed_secrets_crt" | (cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsCrt)
    echo ""
    read_multiline_var sealed_secrets_key "Paste the TLS private key"
    printf '%s\n' "$sealed_secrets_key" | (cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsKey)
    echo "  Sealed Secrets keypair stored in Pulumi config."
    ;;
  [Gg])
    echo "  Generating new sealed-secrets TLS keypair..."
    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout /tmp/sealed-secrets.key \
        -out    /tmp/sealed-secrets.crt \
        -subj "/CN=sealed-secret/O=sealed-secrets" -days 13650
    cat /tmp/sealed-secrets.crt | (cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsCrt)
    cat /tmp/sealed-secrets.key | (cd "$REPO_DIR" && pulumi config set --secret sealedSecretsTlsKey)
    rm -f /tmp/sealed-secrets.key /tmp/sealed-secrets.crt
    echo "  New sealed-secrets keypair generated and stored in Pulumi config."
    ;;
esac
