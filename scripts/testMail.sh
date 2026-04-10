#!/bin/bash
set -euo pipefail

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: $0 <sender-email> <recipient-email>"
    echo "Example: $0 no-reply@cape-project.eu user@example.com"
    exit 1
fi

ADDR_SENDER="$1"
ADDR_RECIPIENT="$2"

# Extract SMTP credentials from Kubernetes secret
echo "Retrieving SMTP credentials from Kubernetes secret 'smtp-credentials'..."
SMTP_HOST=$(kubectl get secret smtp-credentials -n argocd -o jsonpath='{.data.host}' | base64 -d 2>/dev/null || echo "")
SMTP_PORT=$(kubectl get secret smtp-credentials -n argocd -o jsonpath='{.data.port}' | base64 -d 2>/dev/null || echo "")
SMTP_USERNAME=$(kubectl get secret smtp-credentials -n argocd -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "")
SMTP_PASSWORD=$(kubectl get secret smtp-credentials -n argocd -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

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
