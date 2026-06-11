#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TYPE="${1:-}"

case "$TYPE" in
    restore)
        echo "Type: restore"
        pulumi config set restoreClusterFromS3Backup true
        ;;
    new)
        echo "Type: new"
        pulumi config rm restoreClusterFromS3Backup 2>/dev/null || true
        ;;
    *)
        echo "Usage: $0 <type>"
        echo "  restore  - restore cluster from S3 backup"
        echo "  new      - create a fresh cluster"
        exit 1
        ;;
esac

start=$(date +%s)
echo "$(date): Starting infrastructure deployment"

if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
    echo "PULUMI_CONFIG_PASSPHRASE is not set."
    read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE
    echo ""
    export PULUMI_CONFIG_PASSPHRASE
fi

# Check for unpushed commits and offer to push
upstream_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
if [ -n "$upstream_branch" ]; then
    unpushed_count=$(git -C "$REPO_ROOT" rev-list --count "$upstream_branch..HEAD" 2>/dev/null || echo 0)
    if [ "$unpushed_count" -gt 0 ]; then
        echo "Detected $unpushed_count unpushed commit(s) on $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)."
        git -C "$REPO_ROOT" --no-pager log --oneline "$upstream_branch..HEAD"
        printf "Unpushed commits found. Push before deploy? [p=push/i=ignore]: "
        read -r push_choice
        if [ "$push_choice" = "p" ] || [ "$push_choice" = "P" ] || [ "$push_choice" = "push" ] || [ "$push_choice" = "PUSH" ]; then
            git -C "$REPO_ROOT" push || exit 1
        elif [ "$push_choice" = "i" ] || [ "$push_choice" = "I" ] || [ "$push_choice" = "ignore" ] || [ "$push_choice" = "IGNORE" ] || [ -z "$push_choice" ]; then
            :
        else
            echo "Invalid choice. Aborting deployment."
            exit 1
        fi
    fi
fi

CI=true pulumi up -y

source "$SCRIPT_DIR/../runtime/getKubeConfig.sh"

end=$(date +%s)
elapsed=$((end - start))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))
echo "Infrastructure deployed. You can now run 'kubectl get nodes' to see the cluster nodes."
echo "$(date) Elapsed time: ${minutes}m ${seconds}s"

source "$SCRIPT_DIR/../runtime/argocdLoginCLI.sh"