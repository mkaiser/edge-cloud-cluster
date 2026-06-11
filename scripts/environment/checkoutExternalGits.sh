#!/bin/bash
set -e

# Checkout external git repositories to /external (no submodules)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"

mkdir -p "$EXTERNAL_DIR"

echo "Cloning external repositories to $EXTERNAL_DIR..."

# Clone each external repository
git clone https://gitlab.opencode.de/bmi/opendesk/deployment/options/argocd-deploy.git "$EXTERNAL_DIR/git_opendesk-argocd-deploy" &
git clone https://gitlab.opencode.de/bmi/opendesk/deployment/opendesk.git "$EXTERNAL_DIR/git_opendesk" &
git clone https://github.com/univention/nubus-stack "$EXTERNAL_DIR/git_nubus-stack" &
git clone https://gitlab.com/ryax-tech/ryax/ryax-engine.git "$EXTERNAL_DIR/git_ryax-engine" &
git clone https://github.com/mkaiser/edge-cloud-cluster.git "$EXTERNAL_DIR/git_mkaiser_edge-cloud-cluster" &
wait

echo "External repositories checked out to $EXTERNAL_DIR"
