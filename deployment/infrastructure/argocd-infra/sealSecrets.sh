#!/bin/bash
# Seals ArgoCD SMTP credentials for notifications and bootstrap-finished mail.
# Values derived from the Pulumi stack — run scripts/secrets/setMailCredentials.sh first.
#
# Generates:
#   argocd-infra/smtp-credentials-sealed.yaml  — argocd/smtp-credentials
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$REPO_DIR/manageSealedSecrets.sh"

SKIP_GIT_COMMIT=""
for arg in "$@"; do [[ "$arg" == "--skip-git-commit" ]] && SKIP_GIT_COMMIT="--skip-git-commit"; done

if ! (cd "$REPO_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded. Run: source ./scripts/pulumi/initPulumiStack.sh" >&2; exit 1
fi
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
SMTP_HOST="$(pc smtpServer)"; SMTP_PORT="$(pc smtpPort)"
SMTP_USER="$(pc smtpUsername)"; SMTP_PASS="$(pc smtpPassword)"
NOTIFY_RECIPIENT="$(pc smtpNotifyRecipient)"
: "${SMTP_HOST:?smtpServer not set}"; : "${SMTP_PORT:?smtpPort not set}"; : "${SMTP_PASS:?smtpPassword not set}"
echo "SMTP ${SMTP_USER}@${SMTP_HOST}:${SMTP_PORT}, notify: ${NOTIFY_RECIPIENT:-<none>}"

seal_secret "argocd" smtp-credentials smtp-credentials-sealed.yaml \
  --from-literal=host="$SMTP_HOST" \
  --from-literal=port="$SMTP_PORT" \
  --from-literal=username="$SMTP_USER" \
  --from-literal=password="$SMTP_PASS" \
  --from-literal=sendBootstrapFinishMailRecipient="$NOTIFY_RECIPIENT"
SEALED_FILES+=("${SCRIPT_DIR}/smtp-credentials-sealed.yaml")

[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal argocd smtp-credentials" "${SEALED_FILES[@]}"
