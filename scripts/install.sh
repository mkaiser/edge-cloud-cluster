#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned tool versions — bump these to upgrade
# ---------------------------------------------------------------------------
ARGOCD_VERSION="3.3.6"       # renovate: datasource=github-releases depName=argoproj/argo-cd
KUBESEAL_VERSION="0.36.1"    # renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
FREELENS_VERSION="1.8.1"     # renovate: datasource=github-releases depName=freelensapp/freelens
HELMFILE_VERSION="v1.8.1"     # renovate: datasource=github-releases depName=helmfile/helmfile
HCLOUD_VERSION="1.62.0"      # renovate: datasource=github-releases depName=hetznercloud/cli
HCLOUD_UI_VERSION="1.62.2"    # renovate: datasource=github-releases depName=apricote/hcloud-upload-image
TALOSCTL_VERSION="1.12.6"    # renovate: datasource=github-releases depName=siderolabs/talos


forceInstall=0  # set to 1 to reinstall tools that are already present

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
githubLatest() {
    # $1 = owner/repo
    curl --silent "https://api.github.com/repos/$1/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
}

checkVersion() {
    # $1 = installed version, $2 = latest version, $3 = tool name
    local installVersion="$1" latestVersion="$2" name="$3"
    if [ "$installVersion" != "$latestVersion" ]; then
        echo -e "\033[38;5;208mInfo: $name $installVersion is not the latest version ($latestVersion)\033[0m"
    fi
}

# ---------------------------------------------------------------------------
# Install functions
# ---------------------------------------------------------------------------
install_argocd() {
    checkVersion "$ARGOCD_VERSION" "$(githubLatest argoproj/argo-cd)" "argocd"
    if [ "$forceInstall" -ne 1 ] && command -v argocd >/dev/null 2>&1; then return; fi
    echo "Installing ArgoCD CLI..."
    curl -sSL -o argocd \
        "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
    sudo install -m 555 argocd /usr/local/bin/argocd
    rm -f argocd
}

install_kubeseal() {
    checkVersion "$KUBESEAL_VERSION" "$(githubLatest bitnami-labs/sealed-secrets)" "kubeseal"
    if [ "$forceInstall" -ne 1 ] && command -v kubeseal >/dev/null 2>&1; then return; fi
    echo "Installing kubeseal CLI..."
    curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
        | tar -xz kubeseal
    sudo install -m 555 kubeseal /usr/local/bin/kubeseal
    rm -f kubeseal
}

install_freelens() {
    checkVersion "$FREELENS_VERSION" "$(githubLatest freelensapp/freelens)" "freelens"
    if [ "$forceInstall" -ne 1 ] && command -v freelens >/dev/null 2>&1; then return; fi
    echo "Installing Free Lens..."
    curl -sSLO "https://github.com/freelensapp/freelens/releases/download/v${FREELENS_VERSION}/freelens-${FREELENS_VERSION}-linux-amd64.deb"
    sudo dpkg -i "freelens-${FREELENS_VERSION}-linux-amd64.deb"
    rm -f "freelens-${FREELENS_VERSION}-linux-amd64.deb"
}

install_helmfile() {
    checkVersion "$HELMFILE_VERSION" "$(githubLatest helmfile/helmfile)" "helmfile"
    if [ "$forceInstall" -ne 1 ] && command -v helmfile >/dev/null 2>&1; then return; fi
    echo "Installing helmfile CLI..."
    curl -sSLO "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
    tar xzf "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
    sudo install -m 555 helmfile /usr/local/bin/helmfile
    rm -f "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
}

install_hcloud() {
    checkVersion "$HCLOUD_VERSION" "$(githubLatest hetznercloud/cli)" "hcloud"
    if [ "$forceInstall" -ne 1 ] && command -v hcloud >/dev/null 2>&1; then return; fi
    echo "Installing hcloud CLI..."
    curl -sSLO "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"
    tar -xzf hcloud-linux-amd64.tar.gz hcloud
    sudo install -m 555 hcloud /usr/local/bin/hcloud
    rm -f hcloud-linux-amd64.tar.gz hcloud
}

install_hcloud_upload_image() {
    checkVersion "$HCLOUD_UI_VERSION" "$(githubLatest apricote/hcloud-upload-image)" "hcloud-upload-image"
    if [ "$forceInstall" -ne 1 ] && command -v hcloud-upload-image >/dev/null 2>&1; then return; fi
    echo "Installing hcloud-upload-image..."
    curl -sSLO "https://github.com/apricote/hcloud-upload-image/releases/download/v${HCLOUD_UI_VERSION}/hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
    sudo dpkg -i --force-depends "hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
    rm -f "hcloud-upload-image_${HCLOUD_UI_VERSION}_amd64.deb"
}

install_talosctl() {
    checkVersion "$TALOSCTL_VERSION" "$(githubLatest siderolabs/talos)" "talosctl"
    if [ "$forceInstall" -ne 1 ] && command -v talosctl >/dev/null 2>&1; then return; fi
    echo "Installing talosctl..."
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
