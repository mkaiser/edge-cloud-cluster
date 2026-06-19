#!/bin/bash
set -euo pipefail

# Checkout external git repositories to /external (no submodules)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"

mkdir -p "$EXTERNAL_DIR"

echo "Cloning external repositories to $EXTERNAL_DIR..."

# cloneOrUpdate <repoUrl> <targetDir> [sparsePath ...]
# When one or more sparsePaths are given, only those top-level folders are
# checked out (sparse cone mode) instead of the whole repo.
cloneOrUpdate() {
	local repoUrl="$1"
	local targetDir="$2"
	shift 2
	local sparsePaths=("$@")

	if [ -d "$targetDir/.git" ]; then
		echo "Updating $targetDir..."
		git -C "$targetDir" remote set-url origin "$repoUrl" >/dev/null 2>&1 || true

		# Re-apply sparse set in case the requested paths changed.
		if [ "${#sparsePaths[@]}" -gt 0 ]; then
			git -C "$targetDir" sparse-checkout set "${sparsePaths[@]}" >/dev/null 2>&1 || true
		fi

		# Keep shallow clones shallow.
		git -C "$targetDir" fetch --prune --tags --depth 1 origin

		# Fast-forward to remote default branch.
		if git -C "$targetDir" rev-parse --verify -q origin/HEAD >/dev/null; then
			git -C "$targetDir" checkout --detach origin/HEAD >/dev/null 2>&1 || true
			git -C "$targetDir" reset --hard origin/HEAD >/dev/null
		else
			git -C "$targetDir" pull --ff-only
		fi
		return 0
	fi

	if [ -e "$targetDir" ]; then
		echo "Skipping $targetDir (exists, not a git repo)."
		return 0
	fi

	if [ "${#sparsePaths[@]}" -gt 0 ]; then
		echo "Cloning $repoUrl -> $targetDir (sparse: ${sparsePaths[*]})"
		git clone --depth 1 --filter=blob:none --sparse "$repoUrl" "$targetDir"
		git -C "$targetDir" sparse-checkout set "${sparsePaths[@]}"
	else
		echo "Cloning $repoUrl -> $targetDir"
		git clone --depth 1 "$repoUrl" "$targetDir"
	fi
}

# Clone/update each external repository
cloneOrUpdate https://gitlab.com/ryax-tech/ryax/ryax-engine.git "$EXTERNAL_DIR/git_ryax-engine"
cloneOrUpdate https://github.com/xwiki-contrib/xwiki-helm.git "$EXTERNAL_DIR/git_xwiki-contrib_xwiki-helm"
cloneOrUpdate https://github.com/zulip/docker-zulip.git "$EXTERNAL_DIR/git_zulip_docker-zulip"
# Helm chart for Zulip is at: external/git_zulip_docker-zulip/helm/zulip
# Zulip server source (settings reference: zproject/default_settings.py, middleware, docs)
cloneOrUpdate https://github.com/zulip/zulip.git "$EXTERNAL_DIR/git_zulip"
cloneOrUpdate https://github.com/goauthentik/helm.git "$EXTERNAL_DIR/git_goauthentik_helm"
# Authentik core (blueprint discovery / ConfigMap loading logic):
cloneOrUpdate https://github.com/goauthentik/authentik.git "$EXTERNAL_DIR/git_goauthentik_authentik"
cloneOrUpdate https://github.com/jitsi-contrib/jitsi-helm.git "$EXTERNAL_DIR/git_jitsi-contrib_jitsi-helm"
cloneOrUpdate https://github.com/jitsi-contrib/jitsi-oidc-adapter.git "$EXTERNAL_DIR/git_jitsi-contrib_jitsi-oidc-adapter"
cloneOrUpdate https://github.com/RocketChat/helm-charts.git "$EXTERNAL_DIR/git_RocketChat_helm-charts"
cloneOrUpdate https://github.com/nextcloud/helm.git "$EXTERNAL_DIR/git_nextcloud_helm"
# Headscale + headscale-ui Helm charts (wave8-headscale uses wrenix/helm-charts).
# Sparse checkout: this monorepo holds many unrelated charts; only pull what we
# use. (headplane is deployed from raw manifests in this repo, not from wrenix.)
cloneOrUpdate https://codeberg.org/wrenix/helm-charts.git "$EXTERNAL_DIR/git_wrenix_helm-charts" headscale headscale-ui

cloneOrUpdate https://github.com/cloudnative-pg/charts.git "$EXTERNAL_DIR/git_cloudnative-pg_charts"
cloneOrUpdate https://github.com/hetzner/cert-manager-webhook-hetzner.git "$EXTERNAL_DIR/git_hetzner_cert-manager-webhook-hetzner"
cloneOrUpdate https://github.com/hetznercloud/helm-charts.git "$EXTERNAL_DIR/git_hetzner_helm-charts"
cloneOrUpdate https://github.com/lukevella/rallly.git "$EXTERNAL_DIR/git_lukevella_rallly"
cloneOrUpdate https://github.com/dockur/windows.git "$EXTERNAL_DIR/git_dockur_windows"
cloneOrUpdate https://github.com/helmforgedev/charts.git "$EXTERNAL_DIR/git_helmforgedev_charts"
# SeaweedFS (S3-backed file layer for cloud↔edge mobile apps).
# Helm chart lives at: external/git_seaweedfs_seaweedfs/k8s/charts/seaweedfs
cloneOrUpdate https://github.com/seaweedfs/seaweedfs.git "$EXTERNAL_DIR/git_seaweedfs_seaweedfs"
# SeaweedFS CSI driver (provides the `seaweedfs` StorageClass).
# Helm chart at: external/git_seaweedfs_seaweedfs-csi-driver/deploy/helm/seaweedfs-csi-driver
cloneOrUpdate https://github.com/seaweedfs/seaweedfs-csi-driver.git "$EXTERNAL_DIR/git_seaweedfs_seaweedfs-csi-driver"

echo "External repositories checked out to $EXTERNAL_DIR"
