#!/usr/bin/env bash
# Seal a Kubernetes secret for use with the sealed-secrets controller.
#
# Usage (direct):
#   ./manageSealedSecrets.sh <namespace> <secret-name> <output-yaml> [--from-literal=key=value ...]
#
# Usage (sourced — provides ask_and_commit_sealed_files):
#   source ./manageSealedSecrets.sh
#   ask_and_commit_sealed_files "Seal foo secrets" /abs/path/file1.yaml /abs/path/file2.yaml
#
# Examples:
#   ./manageSealedSecrets.sh wireguard wireguard-ui-secret wireguard-ui/ui-secret-sealed.yaml \
#       --from-literal=ui-password=mypassword
#
#   ./manageSealedSecrets.sh myapp myapp-credentials myapp/credentials-sealed.yaml \
#       --from-literal=db-user=admin --from-literal=db-pass=secret123
#
# If no --from-literal args are given, the script prompts interactively for key=value pairs.
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared function: seal a Kubernetes secret using the cert from Pulumi config.
# Does NOT require a live cluster — works fully offline before cluster creation.
#
# Usage: seal_secret <namespace> <secret_name> <output_file> [--from-literal=k=v ...]
#   output_file is relative to the caller's SCRIPT_DIR (must be set by caller).
# ---------------------------------------------------------------------------
seal_secret() {
  local namespace=$1
  local secret_name=$2
  local output_file=$3
  shift 3

  local repo_dir
  repo_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"

  if ! (cd "$repo_dir" && pulumi config get sealedSecretsTlsCrt &>/dev/null); then
    echo "ERROR: Could not read sealedSecretsTlsCrt from Pulumi config."
    echo "Run ./scripts/secrets/setAllSecrets.sh to configure the sealed-secrets keypair first."
    exit 1
  fi

  kubectl create secret generic "$secret_name" \
    --namespace "$namespace" \
    "$@" \
    --dry-run=client -o yaml | \
    kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --cert <(cd "$repo_dir" && pulumi config get sealedSecretsTlsCrt) \
      --format yaml > "${SCRIPT_DIR}/${output_file}"
  echo "Written: ${output_file}"
}

# ---------------------------------------------------------------------------
# Shared function: git add / commit / push a list of sealed-secret files.
# Usage: ask_and_commit_sealed_files <commit_msg> <file1> [file2 ...]
# ---------------------------------------------------------------------------
ask_and_commit_sealed_files() {
    local commit_msg="$1"
    shift
    local files=("$@")

    if [ ${#files[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "Files to commit:"
    for f in "${files[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "Commit message: $commit_msg"
    read -rp "Push to git? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy] ]]; then
        git add "${files[@]}" && \
        git commit -m "$commit_msg" && \
        git push
        echo "Sealed secret committed and pushed to git."
    fi
}

# Only execute sealing logic when run directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NS="kube-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <namespace> <secret-name> <output-yaml> [--from-literal=key=value ...]"
    echo ""
    echo "Examples:"
    echo "  $0 wireguard wireguard-ui-secret wireguard-ui/ui-secret-sealed.yaml --from-literal=ui-password=mypass"
    echo "  $0 myapp db-creds myapp/db-sealed.yaml  (interactive mode)"
    exit 1
fi

NS="$1"
SECRET_NAME="$2"
OUTPUT_FILE="$3"
shift 3

# Resolve output path relative to script directory
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="$SCRIPT_DIR/$OUTPUT_FILE"
fi

# Verify Pulumi cert is available
if ! (cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt &>/dev/null); then
    echo "ERROR: Could not extract sealedSecretsTlsCrt from Pulumi config."
    echo "Run setAllSecrets.sh to configure the sealed-secrets keypair first."
    exit 1
fi

# Collect --from-literal args
LITERAL_ARGS=("$@")

# Interactive mode if no --from-literal args provided
if [ ${#LITERAL_ARGS[@]} -eq 0 ]; then
    echo ""
    echo "No --from-literal args provided. Enter key=value pairs interactively."
    echo ""
    while true; do
        read -rp "  Key name (or Ctrl+D to finish): " key_name || break
        [ -z "$key_name" ] && continue
        read -rsp "  Value for '$key_name': " key_value
        echo ""
        LITERAL_ARGS+=("--from-literal=${key_name}=${key_value}")
    done
    echo ""

    if [ ${#LITERAL_ARGS[@]} -eq 0 ]; then
        echo "ERROR: No key=value pairs provided."
        exit 1
    fi
fi

# Seal the secret using the certificate from Pulumi (no file on disk)
mkdir -p "$(dirname "$OUTPUT_FILE")"
kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NS" \
    "${LITERAL_ARGS[@]}" \
    --dry-run=client -o yaml | \
    kubeseal \
        --controller-name="$CONTROLLER_NAME" \
        --controller-namespace="$CONTROLLER_NS" \
        --cert <(cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt) \
        --format yaml > "$OUTPUT_FILE"

echo ""
echo "Secret $SECRET_NAME sealed to: $OUTPUT_FILE"

# Check if cluster is reachable and offer deployment options
echo ""
if kubectl cluster-info &>/dev/null; then
    read -rp "Cluster is online. Apply the sealed secret directly? [y/N]: " apply_choice
    if [[ "$apply_choice" =~ ^[Yy] ]]; then
        if ! kubectl get namespace "$NS" &>/dev/null; then
            echo "Namespace '$NS' does not exist. Creating it..."
            kubectl create namespace "$NS"
        fi
        kubectl apply -f "$OUTPUT_FILE"
    fi
fi

fi # end BASH_SOURCE guard
