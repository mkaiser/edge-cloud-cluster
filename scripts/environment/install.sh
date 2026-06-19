#!/usr/bin/env bash
set -euo pipefail

# Robust download helper: retries on transient failures and prints errors
download() {
    # usage: download [-o output_file] URL
    local out=""
    OPTIND=1
    while getopts "o:" _opt; do
        case "$_opt" in
            o) out="$OPTARG" ;;
        esac
    done
    shift $((OPTIND-1))
    local url="$1"
    local -a curl_args=( --fail --location --silent --show-error --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors )
    if [ -n "$out" ]; then
        curl_args+=( -o "$out" )
    fi
    curl "${curl_args[@]}" "$url"
}

# ---------------------------------------------------------------------------
# Install functions (always ensure the tool is installed)
# ---------------------------------------------------------------------------
install_argocd() {
    local ARGOCD_VERSION="3.4.2"       # renovate: datasource=github-releases depName=argoproj/argo-cd
    echo "Installing ArgoCD CLI v${ARGOCD_VERSION}..."
    download -o argocd "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
    sudo install -m 555 argocd /usr/local/bin/argocd
    rm -f argocd
}

install_kubeseal() {
    local KUBESEAL_VERSION="0.36.6"    # renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
    echo "Installing kubeseal CLI v${KUBESEAL_VERSION}..."
    download "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
        | tar -xz kubeseal
    sudo install -m 555 kubeseal /usr/local/bin/kubeseal
    rm -f kubeseal
}

install_freelens() {
    local FREELENS_VERSION="1.9.0"     # renovate: datasource=github-releases depName=freelensapp/freelens
    echo "Installing Free Lens v${FREELENS_VERSION}..."
    download -o "freelens-${FREELENS_VERSION}-linux-amd64.deb" "https://github.com/freelensapp/freelens/releases/download/v${FREELENS_VERSION}/freelens-${FREELENS_VERSION}-linux-amd64.deb"
    sudo dpkg -i "freelens-${FREELENS_VERSION}-linux-amd64.deb"
    rm -f "freelens-${FREELENS_VERSION}-linux-amd64.deb"
}

install_helm() {
    local HELM_VERSION="3.17.3"         # renovate: datasource=github-releases depName=helm/helm
    echo "Installing Helm v${HELM_VERSION}..."
    download -o "helm-v${HELM_VERSION}-linux-amd64.tar.gz" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    tar xzf "helm-v${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64/helm
    sudo install -m 555 linux-amd64/helm /usr/local/bin/helm
    rm -rf "helm-v${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64
}

install_helmfile() {
    local HELMFILE_VERSION="1.5.1"      # renovate: datasource=github-releases depName=helmfile/helmfile
    echo "Installing helmfile CLI v${HELMFILE_VERSION}..."
    download -o "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
    tar xzf "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
    sudo install -m 555 helmfile /usr/local/bin/helmfile
    rm -f "helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" helmfile
}

install_hcloud() {
    local HCLOUD_VERSION="1.64.1"      # renovate: datasource=github-releases depName=hetznercloud/cli
    echo "Installing hcloud CLI v${HCLOUD_VERSION}..."
    download -o "hcloud-linux-amd64.tar.gz" "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"
    tar -xzf hcloud-linux-amd64.tar.gz hcloud
    sudo install -m 555 hcloud /usr/local/bin/hcloud
    rm -f hcloud-linux-amd64.tar.gz hcloud
}

install_awscli() {
    local AWSCLI_VERSION="2.34.53"    # renovate: datasource=github-releases depName=aws/aws-cli
    echo "Installing AWS CLI v${AWSCLI_VERSION}..."
    local awscli_dir

    # Use the official AWS CLI v2 installer per AWS documentation
    local tmp_zip arch url
    tmp_zip="/tmp/awscliv2.zip"
    arch="$(uname -m)"
    case "$arch" in
        x86_64) url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64|arm64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *) echo "Unsupported architecture: $arch" >&2; return 1 ;;
    esac

    download -o "$tmp_zip" "$url"
    unzip -q "$tmp_zip" -d /tmp
    # Installer supports --update (will install or update as needed)
    sudo /tmp/aws/install --update -i /usr/local/aws-cli -b /usr/local/bin
    rm -rf /tmp/aws "$tmp_zip"
}

install_kubectl() {
    local KUBECTL_VERSION="1.36.1"      # renovate: datasource=github-releases depName=kubernetes/kubernetes
    echo "Installing kubectl v${KUBECTL_VERSION}..."
    download -o kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    sudo install -m 555 kubectl /usr/local/bin/kubectl
    rm -f kubectl
}

install_fnm() {
    local FNM_VERSION="1.39.0"  # renovate: datasource=github-releases depName=Schniz/fnm
    local FNM_DIR="${HOME}/.local/share/fnm"
    echo "Installing fnm v${FNM_VERSION} + Node 24..."
    download -o /tmp/fnm.zip "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/fnm-linux.zip"
    mkdir -p "$FNM_DIR"
    unzip -q /tmp/fnm.zip fnm -d "$FNM_DIR"
    chmod +x "$FNM_DIR/fnm"
    rm -f /tmp/fnm.zip
    export PATH="$FNM_DIR:$PATH"
    eval "$("$FNM_DIR/fnm" env)"
    "$FNM_DIR/fnm" install 24
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
install_helm
install_helmfile
install_hcloud
install_awscli
install_fnm
install_kubectl

echo "All tools installed."
