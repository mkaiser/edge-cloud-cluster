#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Install functions (always ensure the tool is installed)
# ---------------------------------------------------------------------------
install_argocd() {
    local ARGOCD_VERSION="3.4.2"       # renovate: datasource=github-releases depName=argoproj/argo-cd
    echo "Installing ArgoCD CLI v${ARGOCD_VERSION}..."
    curl -sSL -o argocd \
        "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
    sudo install -m 555 argocd /usr/local/bin/argocd
    rm -f argocd
}

install_kubeseal() {
    local KUBESEAL_VERSION="0.36.6"    # renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
    echo "Installing kubeseal CLI v${KUBESEAL_VERSION}..."
    curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
        | tar -xz kubeseal
    sudo install -m 555 kubeseal /usr/local/bin/kubeseal
    rm -f kubeseal
}

install_freelens() {
    local FREELENS_VERSION="1.9.0"     # renovate: datasource=github-releases depName=freelensapp/freelens
    echo "Installing Free Lens v${FREELENS_VERSION}..."
    curl -sSLO "https://github.com/freelensapp/freelens/releases/download/v${FREELENS_VERSION}/freelens-${FREELENS_VERSION}-linux-amd64.deb"
    sudo dpkg -i "freelens-${FREELENS_VERSION}-linux-amd64.deb"
    rm -f "freelens-${FREELENS_VERSION}-linux-amd64.deb"
}

install_helmfile() {
    local HELMFILE_VERSION="1.5.1"      # renovate: datasource=github-releases depName=helmfile/helmfile
    echo "Installing helmfile CLI v${HELMFILE_VERSION}..."
    curl -sSLO "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
    tar xzf "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
    sudo install -m 555 helmfile /usr/local/bin/helmfile
    rm -f "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
}

install_hcloud() {
    local HCLOUD_VERSION="1.64.1"      # renovate: datasource=github-releases depName=hetznercloud/cli
    echo "Installing hcloud CLI v${HCLOUD_VERSION}..."
    curl -sSLO "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"
    tar -xzf hcloud-linux-amd64.tar.gz hcloud
    sudo install -m 555 hcloud /usr/local/bin/hcloud
    rm -f hcloud-linux-amd64.tar.gz hcloud
}

install_hcloud_upload_image() {
    local HCLOUD_UI_VERSION="1.4.0"     # renovate: datasource=github-releases depName=apricote/hcloud-upload-image
    echo "Installing hcloud-upload-image v${HCLOUD_UI_VERSION}..."
    curl -sSLO "https://github.com/apricote/hcloud-upload-image/releases/download/v${HCLOUD_UI_VERSION}/hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
    sudo dpkg -i --force-depends "hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
    rm -f "hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
}

install_talosctl() {
    local TALOSCTL_VERSION="1.13.2"    # renovate: datasource=github-releases depName=siderolabs/talos
    echo "Installing talosctl v${TALOSCTL_VERSION}..."
    curl -sSLO "https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}/talosctl-linux-amd64"
    sudo install -m 555 talosctl-linux-amd64 /usr/local/bin/talosctl
    rm -f talosctl-linux-amd64
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.install"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

install_argocd
install_kubeseal
install_freelens
install_helmfile
install_hcloud
install_hcloud_upload_image
install_talosctl

echo "All tools installed."
