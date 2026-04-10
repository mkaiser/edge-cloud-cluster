#!/bin/bash
# Seals shared cluster secrets for ArgoCD deployment.
# Can be run BEFORE cluster creation — uses the sealed-secrets public key
# stored in Pulumi config (sealedSecretsTlsCrt), no live cluster required.
# Commit ALL output files — sealed files are encrypted and safe for git.
#
# Generates:
#   smtp-credentials-sealed.yaml  — SMTP relay credentials for outbound mail.
#                                   Used by openDesk (postfix), and available
#                                   to any other app in the argocd namespace.
#
# Secret name: smtp-credentials (namespace: argocd)
#
# Note on YAML-unsafe passwords: the opendesk postfix chart renders smtp.password
# unquoted (upstream bug). Passwords must not start with: & * ! | > ' " % @ `
# and must not contain ': ' or ' #'. The script enforces this.
set -euo pipefail

NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../manageSealedSecrets.sh"

# --- SMTP relay credentials ---
echo "Enter SMTP relay credentials for outbound mail."
echo "Used by openDesk (postfix) and other apps in the cluster."
echo "Leave username/password empty if your relay does not require authentication."
echo ""
read -rp "SMTP host (e.g. mail.your-server.de): " SMTP_HOST
read -rp "SMTP port (default 587): " SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"
read -rp "SMTP username: " SMTP_USER

# Validate password for YAML safety (opendesk postfix chart renders it unquoted).
YAML_UNSAFE_START='[&*!|>'"'"'"%@`]'
while true; do
  read -rsp "SMTP password: " SMTP_PASS
  echo ""
  if [[ -z "$SMTP_PASS" ]]; then
    break
  fi
  INVALID=""
  if [[ "${SMTP_PASS:0:1}" =~ $YAML_UNSAFE_START ]]; then
    INVALID="Password starts with '${SMTP_PASS:0:1}' which is a YAML indicator character."
  elif [[ "$SMTP_PASS" == *": "* ]]; then
    INVALID="Password contains ': ' (colon-space) which breaks YAML plain scalars."
  elif [[ "$SMTP_PASS" == *" #"* ]]; then
    INVALID="Password contains ' #' (space-hash) which starts a YAML comment."
  fi
  if [[ -n "$INVALID" ]]; then
    echo "ERROR: $INVALID"
    echo "Please use a password starting with a letter or digit, avoiding: & * ! | > ' \" % @ \`"
    echo "and not containing ': ' or ' #'."
  else
    break
  fi
done

read -rp "Bootstrap notification recipient (e.g. admin@example.com): " NOTIFY_RECIPIENT

seal_secret "$NAMESPACE" smtp-credentials smtp-credentials-sealed.yaml \
  --from-literal=host="$SMTP_HOST" \
  --from-literal=port="$SMTP_PORT" \
  --from-literal=username="$SMTP_USER" \
  --from-literal=password="$SMTP_PASS" \
  --from-literal=sendBootstrapFinishMailRecipient="$NOTIFY_RECIPIENT"
SEALED_FILES+=("smtp-credentials-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do
  ABS_FILES+=("${SCRIPT_DIR}/${f}")
done
ask_and_commit_sealed_files "Seal smtp-credentials" "${ABS_FILES[@]}"
