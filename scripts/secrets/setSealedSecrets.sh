#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "Configuring Sealed Secrets encryption key..."
echo "The sealed-secrets controller uses a TLS keypair to encrypt/decrypt SealedSecrets."
read -p "Generate a NEW keypair (first deploy) [n,N] or enter an EXISTING one? [eE]: " sealed_secrets_choice
if [[ "$sealed_secrets_choice" =~ ^[Ee] ]]; then
    echo "Paste the TLS certificate. Press Enter and then Ctrl+D when done:"
    sealed_secrets_crt=$(cat)
    echo "$sealed_secrets_crt" | pulumi config set --secret sealedSecretsTlsCrt
    echo ""
    echo "Paste the TLS private key. Press Enter and then Ctrl+D when done:"
    sealed_secrets_key=$(cat)
    echo "$sealed_secrets_key" | pulumi config set --secret sealedSecretsTlsKey
    echo "Sealed Secrets keypair stored in Pulumi config."
elif [[ "$sealed_secrets_choice" =~ ^[Nn] ]]; then
    echo "Generating new sealed-secrets TLS keypair..."
    openssl req -x509 -nodes -newkey rsa:4096 -keyout /tmp/sealed-secrets.key \
        -out /tmp/sealed-secrets.crt -subj "/CN=sealed-secret/O=sealed-secrets" -days 13650
    cat /tmp/sealed-secrets.crt | pulumi config set --secret sealedSecretsTlsCrt
    cat /tmp/sealed-secrets.key | pulumi config set --secret sealedSecretsTlsKey
    rm -f /tmp/sealed-secrets.key /tmp/sealed-secrets.crt
    echo "New sealed-secrets keypair generated and stored in Pulumi config."
fi
