#!/usr/bin/env bash
set -euo pipefail

# Robust download helper: retries on transient failures, prints errors.
# Skips the download entirely if the output file already exists (cache in
# INSTALL_DIR). On any failure removes the (partial) output file so a re-run
# retries cleanly instead of finding a corrupt cached file.
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

    if [ -n "$out" ] && [ -e "$out" ]; then
        echo "  (cached) $out"
        return 0
    fi

    local -a curl_args=( --fail --location --silent --show-error --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors )
    if [ -n "$out" ]; then
        curl_args+=( -o "$out" )
    fi
    if ! curl "${curl_args[@]}" "$url"; then
        [ -n "$out" ] && rm -f "$out"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Install functions (skip if the target version is already installed; on any
# failure, remove the downloaded file so the cache never holds a bad result)
# ---------------------------------------------------------------------------
install_argocd() {
    # Keep in step with the SERVER, pinned via the argo-cd chart in src/argocd.ts
    # (chart 10.7.2 = ArgoCD v3.5.2). Bump both together, not this alone.
    local ARGOCD_VERSION="3.5.3"       # renovate: datasource=github-releases depName=argoproj/argo-cd
    if command -v argocd >/dev/null 2>&1 && argocd version --client --short 2>/dev/null | grep -q "v${ARGOCD_VERSION}"; then
        echo "ArgoCD CLI v${ARGOCD_VERSION} already installed."
        return 0
    fi
    echo "Installing ArgoCD CLI v${ARGOCD_VERSION}..."
    # The cache filename MUST carry the version: download() skips the fetch when the output
    # file exists, so a version-less name pins the cache to whatever was downloaded FIRST and
    # every later bump silently reinstalls the old binary. Measured 2026-09-23 — the guard
    # above correctly saw the mismatch, then download() handed back a Sep-1 v3.4.2 and
    # reinstalled it, so the CLI sat 3 minor versions behind the pin indefinitely.
    local f="argocd-v${ARGOCD_VERSION}-linux-amd64"
    download -o "$f" "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64" || return 1
    sudo install -m 555 "$f" /usr/local/bin/argocd || { rm -f "$f"; return 1; }
}

install_kubeseal() {
    local KUBESEAL_VERSION="0.40.0"    # renovate: datasource=github-releases depName=bitnami-labs/sealed-secrets
    if command -v kubeseal >/dev/null 2>&1 && kubeseal --version 2>&1 | grep -q "${KUBESEAL_VERSION}"; then
        echo "kubeseal CLI v${KUBESEAL_VERSION} already installed."
        return 0
    fi
    echo "Installing kubeseal CLI v${KUBESEAL_VERSION}..."
    local f="kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
    download -o "$f" "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/${f}" || return 1
    tar -xzf "$f" kubeseal || { rm -f "$f"; return 1; }
    sudo install -m 555 kubeseal /usr/local/bin/kubeseal || { rm -f "$f" kubeseal; return 1; }
}

install_freelens() {
    local FREELENS_VERSION="1.10.3"     # renovate: datasource=github-releases depName=freelensapp/freelens
    if dpkg -s freelens >/dev/null 2>&1 && dpkg-query -W -f='${Version}' freelens 2>/dev/null | grep -q "${FREELENS_VERSION}"; then
        echo "Free Lens v${FREELENS_VERSION} already installed."
        return 0
    fi
    echo "Installing Free Lens v${FREELENS_VERSION}..."
    local f="freelens-${FREELENS_VERSION}-linux-amd64.deb"
    download -o "$f" "https://github.com/freelensapp/freelens/releases/download/v${FREELENS_VERSION}/${f}" || return 1
    sudo dpkg -i "$f" || { rm -f "$f"; return 1; }
}

install_helm() {
    local HELM_VERSION="4.3.0"          # renovate: datasource=github-releases depName=helm/helm
    if command -v helm >/dev/null 2>&1 && helm version --short 2>/dev/null | grep -q "v${HELM_VERSION}"; then
        echo "Helm v${HELM_VERSION} already installed."
        return 0
    fi
    echo "Installing Helm v${HELM_VERSION}..."
    local f="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    download -o "$f" "https://get.helm.sh/${f}" || return 1
    tar xzf "$f" linux-amd64/helm || { rm -f "$f"; rm -rf linux-amd64; return 1; }
    sudo install -m 555 linux-amd64/helm /usr/local/bin/helm || { rm -f "$f"; rm -rf linux-amd64; return 1; }
}

install_helmfile() {
    local HELMFILE_VERSION="1.8.0"      # renovate: datasource=github-releases depName=helmfile/helmfile
    if command -v helmfile >/dev/null 2>&1 && helmfile version 2>/dev/null | grep -q "${HELMFILE_VERSION}"; then
        echo "helmfile CLI v${HELMFILE_VERSION} already installed."
        return 0
    fi
    echo "Installing helmfile CLI v${HELMFILE_VERSION}..."
    local f="helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
    download -o "$f" "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/${f}" || return 1
    tar xzf "$f" helmfile || { rm -f "$f" helmfile; return 1; }
    sudo install -m 555 helmfile /usr/local/bin/helmfile || { rm -f "$f" helmfile; return 1; }
}

install_hcloud() {
    local HCLOUD_VERSION="1.68.0"      # renovate: datasource=github-releases depName=hetznercloud/cli
    if command -v hcloud >/dev/null 2>&1 && hcloud version 2>/dev/null | grep -q "${HCLOUD_VERSION}"; then
        echo "hcloud CLI v${HCLOUD_VERSION} already installed."
        return 0
    fi
    echo "Installing hcloud CLI v${HCLOUD_VERSION}..."
    # The upstream asset name is version-less, so the CACHE name must be spelled separately —
    # see the note in install_argocd (hcloud had the same drift: pinned 1.68.0, installed
    # 1.64.1 from a Sep-1 cache).
    local asset="hcloud-linux-amd64.tar.gz"
    local f="hcloud-v${HCLOUD_VERSION}-linux-amd64.tar.gz"
    download -o "$f" "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/${asset}" || return 1
    tar -xzf "$f" hcloud || { rm -f "$f" hcloud; return 1; }
    sudo install -m 555 hcloud /usr/local/bin/hcloud || { rm -f "$f" hcloud; return 1; }
}

install_awscli() {
    local AWSCLI_VERSION="2.34.53"    # renovate: datasource=github-releases depName=aws/aws-cli
    if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q "aws-cli/${AWSCLI_VERSION}"; then
        echo "AWS CLI v${AWSCLI_VERSION} already installed."
        return 0
    fi
    echo "Installing AWS CLI v${AWSCLI_VERSION}..."
    local arch url f
    arch="$(uname -m)"
    case "$arch" in
        x86_64) url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64|arm64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *) echo "Unsupported architecture: $arch" >&2; return 1 ;;
    esac
    f="awscli-exe-linux-${arch}.zip"

    download -o "$f" "$url" || return 1
    rm -rf aws
    unzip -q "$f" -d . || { rm -f "$f"; rm -rf aws; return 1; }
    # Installer supports --update (will install or update as needed)
    sudo ./aws/install --update -i /usr/local/aws-cli -b /usr/local/bin || { rm -f "$f"; rm -rf aws; return 1; }
}

install_kubectl() {
    local KUBECTL_VERSION="1.37.0"      # renovate: datasource=github-releases depName=kubernetes/kubernetes
    if command -v kubectl >/dev/null 2>&1 && kubectl version --client 2>/dev/null | grep -q "v${KUBECTL_VERSION}"; then
        echo "kubectl v${KUBECTL_VERSION} already installed."
        return 0
    fi
    echo "Installing kubectl v${KUBECTL_VERSION}..."
    local f="kubectl-v${KUBECTL_VERSION}"
    download -o "$f" "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" || return 1
    sudo install -m 555 "$f" /usr/local/bin/kubectl || { rm -f "$f"; return 1; }
}

install_gh() {
    local GH_VERSION="2.101.0"           # renovate: datasource=github-releases depName=cli/cli
    if command -v gh >/dev/null 2>&1 && gh --version 2>/dev/null | grep -q "${GH_VERSION}"; then
        echo "GitHub CLI v${GH_VERSION} already installed."
        return 0
    fi
    echo "Installing GitHub CLI v${GH_VERSION}..."
    local f="gh_${GH_VERSION}_linux_amd64.tar.gz"
    local d="gh_${GH_VERSION}_linux_amd64"
    download -o "$f" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${f}" || return 1
    tar -xzf "$f" "${d}/bin/gh" || { rm -f "$f"; rm -rf "$d"; return 1; }
    sudo install -m 555 "${d}/bin/gh" /usr/local/bin/gh || { rm -f "$f"; rm -rf "$d"; return 1; }
}

install_fnm() {
    local FNM_VERSION="1.39.0"  # renovate: datasource=github-releases depName=Schniz/fnm
    local FNM_DIR="${HOME}/.local/share/fnm"
    if [ -x "$FNM_DIR/fnm" ] && "$FNM_DIR/fnm" --version 2>/dev/null | grep -q "${FNM_VERSION}"; then
        echo "fnm v${FNM_VERSION} already installed."
    else
        echo "Installing fnm v${FNM_VERSION}..."
        local f="fnm-linux-v${FNM_VERSION}.zip"
        download -o "$f" "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/fnm-linux.zip" || return 1
        mkdir -p "$FNM_DIR"
        unzip -q -o "$f" fnm -d "$FNM_DIR" || { rm -f "$f"; return 1; }
        chmod +x "$FNM_DIR/fnm"
    fi
    export PATH="$FNM_DIR:$PATH"
    eval "$("$FNM_DIR/fnm" env)"
    "$FNM_DIR/fnm" install 24
}

install_pulumi_best_practices_skill() {
    # Pulumi's official agent-skills repo, vendored as a plain skill directory rather
    # than installed as a plugin: /plugin is an interactive UI command, so it cannot run
    # from make setup, and of the 17 skills in that plugin only this one applies here
    # (the debug/ESC ones drive Pulumi Cloud via `pulumi api`; this repo uses a LOCAL
    # file backend, so they cannot work at all).
    #
    # Pinned by COMMIT, not tag: upstream publishes no git tags at all, so a branch clone
    # would silently track main and drift -- the stale-checkout trap in CLAUDE.md. Renovate
    # bumps the digest; the stamp file forces a reinstall whenever it changes.
    local PULUMI_SKILLS_COMMIT="9b794aec9c4169f137285c2763c06064d247dd47" # renovate: datasource=git-refs depName=pulumi/agent-skills packageName=https://github.com/pulumi/agent-skills
    local SKILL_DIR="$HOME/.claude/skills/pulumi-best-practices"
    local STAMP="$SKILL_DIR/.version"

    if [ -f "$STAMP" ] && grep -qx "${PULUMI_SKILLS_COMMIT}" "$STAMP"; then
        echo "pulumi-best-practices skill already installed (${PULUMI_SKILLS_COMMIT:0:8})."
        return 0
    fi
    echo "Installing pulumi-best-practices skill (${PULUMI_SKILLS_COMMIT:0:8})..."

    local c="$INSTALL_DIR/agent-skills"
    rm -rf "$c"
    git clone -q --filter=blob:none --no-checkout \
        https://github.com/pulumi/agent-skills.git "$c" || { rm -rf "$c"; return 1; }
    git -C "$c" checkout -q "${PULUMI_SKILLS_COMMIT}" -- pulumi/skills/pulumi-best-practices \
        || { echo "  commit ${PULUMI_SKILLS_COMMIT} or skill path missing upstream"; rm -rf "$c"; return 1; }

    local src="$c/pulumi/skills/pulumi-best-practices"
    [ -f "$src/SKILL.md" ] || { echo "  SKILL.md missing upstream"; rm -rf "$c"; return 1; }

    mkdir -p "$(dirname "$SKILL_DIR")"
    rm -rf "$SKILL_DIR"
    cp -r "$src" "$SKILL_DIR" || { rm -rf "$c"; return 1; }
    echo "${PULUMI_SKILLS_COMMIT}" > "$STAMP"
    rm -rf "$c"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.install"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

install_argocd
install_kubeseal
# install_freelens
install_helm
install_helmfile
install_hcloud
install_awscli
install_gh
install_fnm
install_kubectl
install_pulumi_best_practices_skill

echo "All tools installed."
