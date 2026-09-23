#!/usr/bin/env bash
# Stores SMTP transport credentials in the Pulumi stack (all encrypted):
#   smtpServer            — SMTP host (kept secret: published in SPF but not committed in plaintext)
#   smtpPort              — SMTP port (default 587)
#   smtpUsername          — SMTP/IMAP login
#   smtpPassword          — SMTP password
#   smtpNotifyRecipient   — notification recipient for cluster alerts
# The from/sender + admin + Let's Encrypt ACME contact address is the plain literal
# `senderEmail` in project_settings.ts (single source of truth) — NOT a stack key.
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
source "$THIS_DIR/inputHelpers.sh"

echo "Configuring mail settings — stored in the Pulumi stack (encrypted)."
echo ""

# --- SMTP settings ---
read_line_var SMTP_SERVER "SMTP server host"
printf '%s' "$SMTP_SERVER" | (cd "$REPO_DIR" && pulumi config set --secret smtpServer)
echo "  smtpServer — stored."

read -rp "SMTP port [587]: " SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"
printf '%s' "$SMTP_PORT" | (cd "$REPO_DIR" && pulumi config set --secret smtpPort)
echo "  smtpPort — stored."

read_line_var SMTP_USER "SMTP/IMAP login username"
printf '%s' "$SMTP_USER" | (cd "$REPO_DIR" && pulumi config set --secret smtpUsername)
echo "  smtpUsername — stored."

read_secret_var SMTP_PASSWORD "Enter SMTP password (hidden)"
printf '%s' "$SMTP_PASSWORD" | (cd "$REPO_DIR" && pulumi config set --secret smtpPassword)
echo "  smtpPassword — stored."

read_line_var NOTIFY_RECIPIENT "Notification recipient email (cluster alerts)"
printf '%s' "$NOTIFY_RECIPIENT" | (cd "$REPO_DIR" && pulumi config set --secret smtpNotifyRecipient)
echo "  smtpNotifyRecipient — stored."

echo ""
echo "Mail settings stored."
