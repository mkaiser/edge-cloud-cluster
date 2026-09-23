#!/bin/bash
set -euo pipefail

# Sender/recipient both default to project_settings.ts `senderEmail` (the canonical
# from/admin address, e.g. no-reply@mydomain.tld). Positional args override either.
#   Usage: $0 [sender-email] [recipient-email]

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"

sender_email=$(sed -nE 's/^[[:space:]]*senderEmail[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO_DIR/project_settings.ts" | head -n1)

ADDR_SENDER="${1:-$sender_email}"
ADDR_RECIPIENT="${2:-$sender_email}"

if [ -z "$ADDR_SENDER" ] || [ -z "$ADDR_RECIPIENT" ]; then
    echo "Usage: $0 [sender-email] [recipient-email]"
    echo "Defaults are read from project_settings.ts (senderEmail)."
    echo "Example: $0 no-reply@mydomain.tld user@example.com"
    exit 1
fi

echo "Sender:    $ADDR_SENDER"
echo "Recipient: $ADDR_RECIPIENT"

# Extract SMTP credentials from Kubernetes secret
echo "Retrieving SMTP credentials from Kubernetes secret 'smtp-credentials'..."
SMTP_HOST=$(kubectl get secret smtp-credentials -n argocd-infra -o jsonpath='{.data.host}' | base64 -d 2>/dev/null || echo "")
SMTP_PORT=$(kubectl get secret smtp-credentials -n argocd-infra -o jsonpath='{.data.port}' | base64 -d 2>/dev/null || echo "")
SMTP_USERNAME=$(kubectl get secret smtp-credentials -n argocd-infra -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "")
SMTP_PASSWORD=$(kubectl get secret smtp-credentials -n argocd-infra -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_PORT" ] || [ -z "$SMTP_USERNAME" ] || [ -z "$SMTP_PASSWORD" ]; then
    echo "Error: Could not retrieve SMTP credentials from Kubernetes secret"
    exit 1
fi

echo "Sending test email via $SMTP_HOST:$SMTP_PORT..."

# Send email using curl with SMTP
curl --silent --show-error \
    --url "smtp://$SMTP_HOST:$SMTP_PORT" \
    --ssl-reqd \
    --mail-from "$ADDR_SENDER" \
    --mail-rcpt "$ADDR_RECIPIENT" \
    --user "$SMTP_USERNAME:$SMTP_PASSWORD" \
    --upload-file - <<EOF
From: $ADDR_SENDER
To: $ADDR_RECIPIENT
Subject: Test email from testMail.sh

This is a test email sent via SMTP credentials from Kubernetes.

Sent at: $(date)
EOF

echo "✓ Email sent successfully to $ADDR_RECIPIENT"
