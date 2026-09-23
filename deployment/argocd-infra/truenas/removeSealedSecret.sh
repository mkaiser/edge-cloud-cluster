#!/bin/bash
# Remove (git rm) this folder's committed *-sealed.yaml files — the mirror of
# sealSecrets.sh in the same folder. Part C: symmetric remove tooling for a
# clean/vanilla git release (SealedSecrets only; the Pulumi-config set*.sh family
# is out of scope). Run via deployment/removeAllSealedSecrets.sh for a full strip.
#
# Flags:
#   --force              non-interactive (skip the destructive confirmation)
#   --skip-git-commit  remove files but do not git-commit the removal
#
# ⚠ THIS DOES NOT TOUCH THE APPLIANCE. The TrueNAS box is persistent and is NOT recreated
# with the cluster: removing this sealed file only removes the cluster's COPY of the admin
# credential. The appliance keeps the same password, and the account still exists — so this
# is not a revocation. To actually rotate, change it on the appliance and re-run
# sealSecrets.sh. Note the sealed file is the ONLY store for this password, so removing it
# here discards the repo's only copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../manageSealedSecrets.sh
source "$REPO_DIR/deployment/manageSealedSecrets.sh"

export REMOVE_YES=0 REMOVE_SKIP_GIT_COMMIT=0
for arg in "$@"; do case "$arg" in
  --force)             REMOVE_YES=1 ;;
  --skip-git-commit) REMOVE_SKIP_GIT_COMMIT=1 ;;
esac; done

# This folder's sealed files (the set sealSecrets.sh produces).
mapfile -t SEALED_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*-sealed.yaml' | sort)

remove_sealed "Remove sealed secrets in $(basename "$SCRIPT_DIR")" "${SEALED_FILES[@]}"
