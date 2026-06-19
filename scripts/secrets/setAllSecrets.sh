#!/bin/bash
# Configure all secrets for a fresh cluster or rotate auto-generated ones.
#
# Usage:
#   bash setAllSecrets.sh              — full interactive setup (first deploy)
#   bash setAllSecrets.sh --regenerate — rotate all auto-generated secrets only
#                                        (skips external secrets: S3, SMTP, hcloud, deploy key)
set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$THIS_DIR/../.." && pwd)/deployment"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

function display_pulumi_config() {
    echo -e "\ncurrent pulumi config:"
    pulumi config
    echo -e "\n"
}

function commit_sealed_files() {
    local changed=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && changed+=("$f")
    done < <(git -C "$DEPLOY_DIR/.." diff --name-only -- '*.yaml' 2>/dev/null | grep -- '-sealed\.yaml')
    # also catch untracked sealed files
    while IFS= read -r f; do
        [[ -n "$f" ]] && changed+=("$f")
    done < <(git -C "$DEPLOY_DIR/.." ls-files --others --exclude-standard -- '*.yaml' 2>/dev/null | grep -- '-sealed\.yaml')

    if [[ ${#changed[@]} -eq 0 ]]; then
        echo "No sealed files changed — nothing to commit."
        return 0
    fi

    echo ""
    echo "Changed sealed files:"
    for f in "${changed[@]}"; do echo "  - $f"; done
    echo ""
    read -rp "Commit and push all sealed files? [y/N]: " do_commit
    if [[ "$do_commit" =~ ^[Yy]$ ]]; then
        git -C "$DEPLOY_DIR/.." add "${changed[@]}"
        git -C "$DEPLOY_DIR/.." commit -m "Seal all secrets"
        git -C "$DEPLOY_DIR/.." push
    fi
}

if [[ "$REGEN" == "--regenerate" ]]; then
  echo "=== Regenerating auto-generated secrets ==="
  echo ""
  bash "$THIS_DIR/setArgoCd.sh"    --regenerate
  echo ""
  bash "$THIS_DIR/setWireGuard.sh" --regenerate
  echo ""
  # rotateSealingKey.sh has its own confirmation prompt — if user says yes it
  # calls sealAllSecrets.sh --regenerate internally with the new key.
  # If user says no it exits cleanly and we call sealAllSecrets.sh below.
  bash "$THIS_DIR/rotateSealingKey.sh"
  echo ""
  bash "$DEPLOY_DIR/sealAllSecrets.sh" --regenerate --skip-git-commit
  echo ""
  echo "Regeneration complete. External secrets (S3, SMTP, hcloud, deploy key) unchanged."
  echo ""
  display_pulumi_config
  commit_sealed_files
  echo ""
  read -rp "Print all sealed secrets? [y/N]: " show_sealed
  if [[ "$show_sealed" =~ ^[Yy]$ ]]; then
    bash "$THIS_DIR/../misc/printSealedSecrets.sh"
  fi
  exit 0
fi

# --- Full interactive setup ---
display_pulumi_config

read -rp "Clear all existing Pulumi config values? [y/N]: " clear_config
if [[ "$clear_config" =~ ^[Yy]$ ]]; then
    echo "Clearing pulumi config..."
    pulumi config --stack mystack --json \
      | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).keys()))' \
      | while read -r k; do pulumi config rm --stack mystack "$k"; done
    echo "Pulumi config cleared."
else
    echo "Keeping existing pulumi config."
fi

echo ""
bash "$THIS_DIR/setHcloudToken.sh"

echo ""
bash "$THIS_DIR/setS3ObjectStorage.sh"

echo ""
bash "$THIS_DIR/setMailCredentials.sh"

echo ""
bash "$THIS_DIR/setWireGuard.sh"

echo ""
bash "$THIS_DIR/setArgoCd.sh"

echo ""
bash "$THIS_DIR/setGitHubDeployKey.sh"

echo ""
bash "$THIS_DIR/setEdgeSshKey.sh"

echo ""
bash "$THIS_DIR/setSealingKey.sh"

echo ""
bash "$DEPLOY_DIR/sealAllSecrets.sh" --skip-git-commit

echo "Configuration complete!"
echo -e "\n"


commit_sealed_files

echo ""
read -rp "Print all pulumi and sealed secrets? [y/N]: " reveal_secrets
if [[ "$reveal_secrets" =~ ^[Yy]$ ]]; then
    display_pulumi_config
  bash "$THIS_DIR/printSealedSecrets.sh"
fi
