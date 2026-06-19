#!/usr/bin/env bash
# Stores SMTP settings in the Pulumi stack.
# ALL values are stored as secrets (--secret) so no personal data (server,
# username, notification recipient) is committed in plaintext to the public repo.
# Scripts that consume them use `pulumi config get`, which decrypts transparently.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$THIS_DIR/inputHelpers.sh"

echo "Configuring mail (SMTP) settings — stored in the Pulumi stack (encrypted)."
echo "  IMAP is not stored (the Nextcloud Mail app derives it from the SMTP server)."
echo ""

read_line_var SMTP_SERVER "SMTP server host"
printf '%s' "$SMTP_SERVER" | pulumi config set --secret smtpServer
echo "  smtpServer — stored (secret)."

read -rp "SMTP port [587]: " SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"
printf '%s' "$SMTP_PORT" | pulumi config set --secret smtpPort
echo "  smtpPort — stored (secret)."

read_line_var SMTP_USER "SMTP/IMAP login username"
printf '%s' "$SMTP_USER" | pulumi config set --secret smtpUsername
echo "  smtpUsername — stored (secret)."

read_secret_var SMTP_PASSWORD "Enter SMTP password (hidden)"
printf '%s' "$SMTP_PASSWORD" | pulumi config set --secret smtpPassword
echo "  smtpPassword — stored (secret)."

read_line_var NOTIFY_RECIPIENT "Notification recipient email"
printf '%s' "$NOTIFY_RECIPIENT" | pulumi config set --secret smtpNotifyRecipient
echo "  smtpNotifyRecipient — stored (secret)."

echo ""
echo "Mail settings stored in Pulumi config."
