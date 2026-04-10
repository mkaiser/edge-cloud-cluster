#!/bin/bash
# Generates the kube-prometheus-stack Grafana credentials as a SealedSecret
# using the shared manageSealedSecrets.sh script.
#
# The kube-prometheus-stack Helm chart creates a secret named
# "kube-prometheus-stack-grafana" with keys admin-user and admin-password.
# When that secret is not auto-created by the chart (e.g. when an existing
# secret is referenced), this script creates it as a SealedSecret that can
# be committed to git safely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SCRIPT="$SCRIPT_DIR/../manageSealedSecrets.sh"
# shellcheck source=../manageSealedSecrets.sh
source "$MANAGE_SCRIPT"

namespace="prometheus"
secret_name="kube-prometheus-stack-grafana"
output_file="kube-prometheus-stack/${secret_name}-sealed.yaml"
service_description="Prometheus Grafana dashboard admin credentials"


echo "Insert credentials for ${service_description}:"

# Prompt for username
read -p "Enter username: " admin_user
admin_user="${admin_user}"

# Prompt for password with confirmation
read -s -p "Enter password: " admin_password
echo ""
read -s -p "Confirm password: " admin_password_confirm
echo ""

if [ "$admin_password" != "$admin_password_confirm" ]; then
  echo "Passwords do not match. Aborting." >&2
  exit 1
fi

# Delegate to the shared sealing script
"$MANAGE_SCRIPT" "$namespace" "$secret_name" "$output_file" \
  --from-literal=admin-user="${admin_user}" \
  --from-literal=admin-password="${admin_password}"

ask_and_commit_sealed_files "Seal $namespace secrets" "${SCRIPT_DIR}/${secret_name}-sealed.yaml"
