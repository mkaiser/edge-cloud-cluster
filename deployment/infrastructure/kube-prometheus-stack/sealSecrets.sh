#!/bin/bash
# Seals kube-prometheus-stack secrets.
# Idempotent: recovers existing password from the sealed file on re-runs.
# Pass --regenerate to rotate auto-generated secrets.
#
# Generates:
#   kube-prometheus-stack-grafana-sealed.yaml  — admin-user / admin-password
#   alertmanager-config-sealed.yaml            — prometheus/alertmanager-config (SMTP)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_FILES=()
# shellcheck source=../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../manageSealedSecrets.sh"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if ! (cd "$REPO_DIR/.." && pulumi config get sealedSecretsTlsKey &>/dev/null); then
  echo "ERROR: Pulumi stack not loaded. Run: source ./scripts/pulumi/initPulumiStack.sh" >&2; exit 1
fi
pc() { (cd "$REPO_DIR/.." && pulumi config get "$1"); }
SMTP_HOST="$(pc smtpServer)"; SMTP_PORT="$(pc smtpPort)"
SMTP_USER="$(pc smtpUsername)"; SMTP_PASS="$(pc smtpPassword)"
NOTIFY_RECIPIENT="$(pc smtpNotifyRecipient)"
: "${SMTP_HOST:?smtpServer not set}"; : "${SMTP_PORT:?smtpPort not set}"; : "${SMTP_PASS:?smtpPassword not set}"
echo "SMTP ${SMTP_USER}@${SMTP_HOST}:${SMTP_PORT}, notify: ${NOTIFY_RECIPIENT:-<none>}"

SEALED_FILE="$SCRIPT_DIR/kube-prometheus-stack-grafana-sealed.yaml"

ADMIN_PASSWORD=$(recover_or_generate "$SEALED_FILE" admin-password "$REGEN")

seal_secret prometheus kube-prometheus-stack-grafana kube-prometheus-stack-grafana-sealed.yaml \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$ADMIN_PASSWORD"
SEALED_FILES+=("kube-prometheus-stack-grafana-sealed.yaml")

# Alertmanager config — rendered from template with SMTP credentials from stack.
AM_TEMPLATE="$SCRIPT_DIR/alertmanager-config.yaml.template"
AM_RENDERED="$(mktemp)"
trap 'rm -f "$AM_RENDERED"' EXIT
SMTP_FROM="$SMTP_USER" SMTP_SMARTHOST="${SMTP_HOST}:${SMTP_PORT}" \
SMTP_USERNAME="$SMTP_USER" SMTP_PASSWORD="$SMTP_PASS" RECIPIENT="$NOTIFY_RECIPIENT" \
perl -pe 's/__SMTP_FROM__/$ENV{SMTP_FROM}/g;
          s/__SMTP_SMARTHOST__/$ENV{SMTP_SMARTHOST}/g;
          s/__SMTP_USERNAME__/$ENV{SMTP_USERNAME}/g;
          s/__SMTP_PASSWORD__/$ENV{SMTP_PASSWORD}/g;
          s/__RECIPIENT__/$ENV{RECIPIENT}/g' "$AM_TEMPLATE" > "$AM_RENDERED"
seal_secret "prometheus" alertmanager-config alertmanager-config-sealed.yaml \
  --from-file=alertmanager.yaml="$AM_RENDERED"
SEALED_FILES+=("alertmanager-config-sealed.yaml")

ABS_FILES=()
for f in "${SEALED_FILES[@]}"; do ABS_FILES+=("${SCRIPT_DIR}/${f}"); done
[[ -z "$SKIP_GIT_COMMIT" ]] && ask_and_commit_sealed_files "Seal prometheus secrets" "${ABS_FILES[@]}"
