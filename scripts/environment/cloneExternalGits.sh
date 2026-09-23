#!/bin/bash
set -euo pipefail

# Checkout external git repositories to /external (no submodules)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"

mkdir -p "$EXTERNAL_DIR"

echo "Cloning external repositories to $EXTERNAL_DIR..."

# cloneOrPull <repoUrl> <targetDir> [sparsePath ...]
# When one or more sparsePaths are given, only those top-level folders are
# checked out (sparse cone mode) instead of the whole repo.
cloneOrPull() {
	local repoUrl="$1"
	local targetDir="$2"
	shift 2
	local sparsePaths=("$@")

	if [ -d "$targetDir/.git" ]; then
		echo "Pulling $targetDir..."
		git -C "$targetDir" remote set-url origin "$repoUrl" >/dev/null 2>&1 || true

		# Re-apply sparse set in case the requested paths changed.
		if [ "${#sparsePaths[@]}" -gt 0 ]; then
			git -C "$targetDir" sparse-checkout set "${sparsePaths[@]}" >/dev/null 2>&1 || true
		fi

		# Keep shallow clones shallow. --no-tags: each tag would drag in its own
		# commit/tree/blobs (hundreds of releases in some repos) that gc can never
		# prune — we only want the latest default-branch snapshot.
		git -C "$targetDir" fetch --prune --no-tags --depth 1 origin
		git -C "$targetDir" tag -l | xargs -r git -C "$targetDir" tag -d >/dev/null

		# Fast-forward to remote default branch.
		if git -C "$targetDir" rev-parse --verify -q origin/HEAD >/dev/null; then
			git -C "$targetDir" checkout --detach origin/HEAD >/dev/null 2>&1 || true
			git -C "$targetDir" reset --hard origin/HEAD >/dev/null
		else
			git -C "$targetDir" pull --ff-only
		fi

		# Repeated depth-1 fetches accumulate stale packfiles; reclaim them.
		git -C "$targetDir" gc --prune=now --quiet || true
		return 0
	fi

	if [ -e "$targetDir" ]; then
		echo "Skipping $targetDir (exists, not a git repo)."
		return 0
	fi

	if [ "${#sparsePaths[@]}" -gt 0 ]; then
		echo "Cloning $repoUrl -> $targetDir (sparse: ${sparsePaths[*]})"
		git clone --depth 1 --no-tags --filter=blob:none --sparse "$repoUrl" "$targetDir"
		git -C "$targetDir" sparse-checkout set "${sparsePaths[@]}"
	else
		echo "Cloning $repoUrl -> $targetDir"
		git clone --depth 1 --no-tags "$repoUrl" "$targetDir"
	fi
}

# Clone/update each external repository
cloneOrPull https://gitlab.com/ryax-tech/ryax/ryax-engine.git "$EXTERNAL_DIR/git_ryax-engine"
cloneOrPull https://github.com/xwiki-contrib/xwiki-helm.git "$EXTERNAL_DIR/git_xwiki-contrib_xwiki-helm"
cloneOrPull https://github.com/zulip/docker-zulip.git "$EXTERNAL_DIR/git_zulip_docker-zulip"
# Helm chart for Zulip is at: external/git_zulip_docker-zulip/helm/zulip
# Zulip server source (settings reference: zproject/default_settings.py, middleware, docs)
cloneOrPull https://github.com/zulip/zulip.git "$EXTERNAL_DIR/git_zulip"
cloneOrPull https://github.com/goauthentik/helm.git "$EXTERNAL_DIR/git_goauthentik_helm"
# Authentik core (blueprint discovery / ConfigMap loading logic):
cloneOrPull https://github.com/goauthentik/authentik.git "$EXTERNAL_DIR/git_goauthentik_authentik"
cloneOrPull https://github.com/jitsi-contrib/jitsi-helm.git "$EXTERNAL_DIR/git_jitsi-contrib_jitsi-helm"
cloneOrPull https://github.com/jitsi-contrib/jitsi-oidc-adapter.git "$EXTERNAL_DIR/git_jitsi-contrib_jitsi-oidc-adapter"
cloneOrPull https://github.com/RocketChat/helm-charts.git "$EXTERNAL_DIR/git_RocketChat_helm-charts"
cloneOrPull https://github.com/nextcloud/helm.git "$EXTERNAL_DIR/git_nextcloud_helm"
# Zammad helm chart — authoritative values schema + templates for
# deployment/argocd-apps/zammad. Source of truth for the S3_URL/secrets wiring
# (templates/_helpers.tpl) and for which subcharts are still on bitnamilegacy
# images (values.yaml elasticsearch/minio blocks).
cloneOrPull https://github.com/zammad/zammad-helm.git "$EXTERNAL_DIR/git_zammad_zammad-helm"
# Zammad application — db/seeds/settings.rb is the authority on the OIDC setting
# names (auth_openid_connect / auth_openid_connect_credentials) that
# zammad/postsync-oidc.yaml writes. Sparse: db + doc only (the app is huge).
cloneOrPull https://github.com/zammad/zammad.git "$EXTERNAL_DIR/git_zammad_zammad" db doc
# Headscale + headscale-ui Helm charts (wave8-headscale uses wrenix/helm-charts).
# Sparse checkout: this monorepo holds many unrelated charts; only pull what we
# use. (headplane is deployed from raw manifests in this repo, not from wrenix.)
cloneOrPull https://codeberg.org/wrenix/helm-charts.git "$EXTERNAL_DIR/git_wrenix_helm-charts" headscale headscale-ui
# Headscale server source — reference for the node registration / auth-approval flow
# (auth register/approve, pre-auth keys, register cache) used by the mesh-node adoption scripts.
cloneOrPull https://github.com/juanfont/headscale.git "$EXTERNAL_DIR/git_juanfont_headscale"
# Tailscale client source — reference for magicsock endpoint discovery / interface
# filtering (which local addrs get advertised as WG endpoint candidates, and the
# CNI-device tunnel-recursion issue) and tailscaled flags/env knobs.
cloneOrPull https://github.com/tailscale/tailscale.git "$EXTERNAL_DIR/git_tailscale_tailscale" net wgengine tsnet cmd docs envknob
# The OCI registry we run lab-locally for EDA module images
# (deployment/argocd-apps/image-registry, docker.io/library/registry). Reference for the
# REGISTRY_* env-var names (configuration.md is the authority — every config key maps to
# REGISTRY_<UPPER_SNAKE_PATH>) and for garbage-collect semantics, which matter because that
# deployment deliberately runs WITHOUT GC.
cloneOrPull https://github.com/distribution/distribution.git "$EXTERNAL_DIR/git_distribution_distribution" docs configuration registry
# Headplane admin UI source (deployed at wave8; ghcr.io/tale/headplane). Reference for the
# "Register machine" flow that approves a keyless mesh node (normalizeRegistrationKey +
# api.nodes.register → headscale auth register).
cloneOrPull https://github.com/tale/headplane.git "$EXTERNAL_DIR/git_tale_headplane"

# ArgoCD — the backbone of this repo (TWO instances: argocd-infra waves 0-19 +
# argocd-apps). Source is the reference for application-controller behaviour that is
# easy to get WRONG by guessing: sync-window semantics (does a deny window block a
# child Application being RECREATED, or only block syncs?), selfHeal/prune ordering,
# finalizer handling, and `app terminate-op` for aborting an in-flight sync — all of
# which the teardown path (scripts/pulumi/nsTerminationCleanup.sh) depends on.
#
# ⚠ gitops-engine IS IN THIS LIST FOR A REASON — do not drop it to save space. It is vendored
# INTO this repo (go.mod: `replace github.com/argoproj/argo-cd/gitops-engine => ./gitops-engine`)
# and it owns everything about HOW a sync runs: hook phases, sync waves, the health assessment
# that decides whether a wave completed. `controller/` alone cannot answer any of it. Leaving
# it out is worse than not cloning argo-cd at all, because a grep then returns a confident
# "no match" for a question the checkout was never able to answer — which is exactly how
# `argocd.argoproj.io/hook-weight` went unchallenged in this repo for as long as it did
# (ordering is syncwaves.Wave(): sync-wave, else helm.sh/hook-weight, else 0).
#
# ⚠ AND THIS IS THE DEFAULT BRANCH, NOT THE DEPLOYED RELEASE. Every clone here is
# `--depth 1 --no-tags` off master, so it can be AHEAD of the cluster. For anything
# version-sensitive, read the tag that matches
# `kubectl -n argocd-infra get deploy argocd-server -o jsonpath='{...image}'` on GitHub
# (raw.githubusercontent.com/argoproj/argo-cd/<tag>/...) rather than trusting this tree.
cloneOrPull https://github.com/argoproj/argo-cd.git "$EXTERNAL_DIR/git_argoproj_argo-cd" controller pkg/apis util docs gitops-engine
# notifications-engine: the library behind argocd-notifications. Needed to answer what the
# argocd-notifications-cm actually supports — e.g. that `$key` substitution from the
# notifications Secret applies to SERVICE configs, not to `subscriptions` recipients.
cloneOrPull https://github.com/argoproj/notifications-engine.git "$EXTERNAL_DIR/git_argoproj_notifications-engine" pkg docs
# argo-helm: the argo-cd chart actually deployed (version pinned in
# deployment/argocd-infra/app-of-apps/wave19-argocd-apps.yaml + argocd-infra-self).
# Sparse: only the argo-cd chart, not the whole monorepo of argo charts.
cloneOrPull https://github.com/argoproj/argo-helm.git "$EXTERNAL_DIR/git_argoproj_argo-helm" charts/argo-cd
# Stakater Reloader — rolls a workload when a ConfigMap/Secret it mounts changes, which
# ArgoCD deliberately does not do. Source is the authority on the two facts the ArgoCD
# integration turns on: the default `env-vars` reload strategy PATCHES the container spec
# (a field ArgoCD declares and would fight over), while `annotations` writes only
# reloader.stakater.com/last-reloaded-from on the pod template; and which annotations are
# honoured (auto / auto-annotation / search+match). Chart at
# deployments/kubernetes/chart/reloader.
cloneOrPull https://github.com/stakater/Reloader.git "$EXTERNAL_DIR/git_stakater_Reloader"
# external-dns — owns every DNS record NOT covered by the dns.ts wildcard rrset. Source is
# the reference for annotation semantics that must not be guessed at: which annotations a
# Service source honours (hostname / target / ttl / controller), how `policy: sync` +
# txtOwnerId decide record ownership and deletion, and how the endpoints of a
# type=LoadBalancer vs ClusterIP Service are turned into record targets — which is exactly
# what the wg.<tld> admin-WireGuard record depends on (src/wireguard.ts).
cloneOrPull https://github.com/kubernetes-sigs/external-dns.git "$EXTERNAL_DIR/git_kubernetes-sigs_external-dns" source provider/webhook docs
# node-feature-discovery — labels nodes with hardware facts discovered ON the box, the one
# label class in this cluster NOT derived from project_settings.ts. `source/cpu` is the part
# that matters: it decides which cpuid flags become labels, and its defaults are the trap —
# newDefaultConfig() blacklists SSE42/POPCNT/CX16, so selecting on those yields a label that
# never appears. Read it rather than guessing which feature names are emitted.
cloneOrPull https://github.com/kubernetes-sigs/node-feature-discovery.git "$EXTERNAL_DIR/git_kubernetes-sigs_node-feature-discovery" source deployment docs

cloneOrPull https://github.com/cloudnative-pg/charts.git "$EXTERNAL_DIR/git_cloudnative-pg_charts"
cloneOrPull https://github.com/hetzner/cert-manager-webhook-hetzner.git "$EXTERNAL_DIR/git_hetzner_cert-manager-webhook-hetzner"
cloneOrPull https://github.com/hetznercloud/helm-charts.git "$EXTERNAL_DIR/git_hetzner_helm-charts"
# kube-vip: k3s API VIP (ARP mode) — source + docs. Used to verify manager flags /
# interface-selection / routing-table behaviour for the deployment/argocd-infra/kube-vip
# DaemonSet instead of guessing. See doc/kube-vip-cross-segment.md.
cloneOrPull https://github.com/kube-vip/kube-vip.git "$EXTERNAL_DIR/git_kube-vip_kube-vip"
cloneOrPull https://github.com/lukevella/rallly.git "$EXTERNAL_DIR/git_lukevella_rallly"
cloneOrPull https://github.com/dockur/windows.git "$EXTERNAL_DIR/git_dockur_windows"
cloneOrPull https://github.com/helmforgedev/charts.git "$EXTERNAL_DIR/git_helmforgedev_charts"
# SeaweedFS (S3-backed file layer for cloud↔edge mobile apps).
# Helm chart lives at: external/git_seaweedfs_seaweedfs/k8s/charts/seaweedfs
cloneOrPull https://github.com/seaweedfs/seaweedfs.git "$EXTERNAL_DIR/git_seaweedfs_seaweedfs"
# SeaweedFS CSI driver (provides the `seaweedfs` StorageClass).
# Helm chart at: external/git_seaweedfs_seaweedfs-csi-driver/deploy/helm/seaweedfs-csi-driver
cloneOrPull https://github.com/seaweedfs/seaweedfs-csi-driver.git "$EXTERNAL_DIR/git_seaweedfs_seaweedfs-csi-driver"

# GitLab Runner Helm chart — config.toml/executor TOML schema + entrypoint template.
# Needed to verify the multi-runner token wiring and the k8s executor TOML keys
# (node_selector/node_tolerations/affinity/cap_add) used by app-of-apps/gitlab-runner.yaml.
cloneOrPull https://gitlab.com/gitlab-org/charts/gitlab-runner.git "$EXTERNAL_DIR/git_gitlab-org_gitlab-runner"

# GitLab CHART (the whole cloud-native bundle) — the authority for what
# deployment/argocd-apps/gitlab/values.yaml can actually express. app-of-apps/gitlab.yaml
# pins chart 10.2.0 from https://charts.gitlab.io, and several decisions in this repo turn on
# what a SUBCHART template exposes rather than on what the docs imply. Concretely needed for:
#   charts/registry/  — the container registry: which storage drivers its config template
#                       accepts (`filesystem` is the chart's own default, see
#                       templates/_storage_default.yaml), and the fact that its
#                       deployment.yaml has a FIXED `volumes:` list with no extraVolumes /
#                       persistence hook — which is why an NFS-backed registry cannot be a
#                       values change and why registry-preferclose-service.yaml adds a
#                       SIBLING Service instead of patching the chart's own.
#   charts/gitlab/    — webservice/toolbox/gitaly values shapes.
#   templates/        — REQUIRED, not optional: the chart-wide helpers live here, including
#                       `gitlab.extraVolumes`/`gitlab.extraVolumeMounts`
#                       (templates/_extraObjects.tpl). Eleven of the twelve subcharts call
#                       those helpers; `registry` is the ONLY one that does not, which is the
#                       whole reason an NFS-backed registry needs a chart change rather than
#                       a values change. Without this path the helper is invisible and the
#                       omission looks like a deliberate design decision instead of a gap.
# Sparse checkout: the bundle vendors many subcharts; only pull what is actually consulted.
cloneOrPull https://gitlab.com/gitlab-org/charts/gitlab.git "$EXTERNAL_DIR/git_gitlab-org_charts_gitlab" charts/registry charts/gitlab templates

# NVIDIA k8s device plugin — DaemonSet manifests + Helm chart values (authoritative
# nodeSelector/tolerations/args for deployment/argocd-infra/nvidia-gpu). arm64/Jetson.
cloneOrPull https://github.com/NVIDIA/k8s-device-plugin.git "$EXTERNAL_DIR/git_NVIDIA_k8s-device-plugin"
# nvidia-container-toolkit — install + containerd-config reference for the arm64/JetPack
# host step src/provisioning-scripts/20-install-gpu.sh.
cloneOrPull https://github.com/NVIDIA/nvidia-container-toolkit.git "$EXTERNAL_DIR/git_NVIDIA_nvidia-container-toolkit"

# LLM serving stack (Plan B / doc/llm-agents.md).
# vLLM — OpenAI-compatible server args + entrypoint (deployment/argocd-apps/vllm).
cloneOrPull https://github.com/vllm-project/vllm.git "$EXTERNAL_DIR/git_vllm-project_vllm"
# LiteLLM — gateway/proxy config keys (enable_jwt_auth, virtual keys, UI/OIDC) +
# Helm chart under deploy/ (deployment/argocd-apps/litellm).
cloneOrPull https://github.com/BerriAI/litellm.git "$EXTERNAL_DIR/git_BerriAI_litellm"
# Open WebUI — OIDC env var names + behaviour (deployment/argocd-apps/open-webui).
cloneOrPull https://github.com/open-webui/open-webui.git "$EXTERNAL_DIR/git_open-webui_open-webui"
# Open WebUI Helm chart — values schema for the plain-manifest deployment reference.
cloneOrPull https://github.com/open-webui/helm-charts.git "$EXTERNAL_DIR/git_open-webui_helm-charts"
# Renovate — datasource/manager source for debugging lookup failures (renovate.json).
cloneOrPull https://github.com/renovatebot/renovate.git "$EXTERNAL_DIR/git_renovatebot_renovate" lib docs

# Gateway API ingress (src/ingress.ts + deployment/argocd-infra/gateway).
# Envoy Gateway — EnvoyProxy CRD schema (the hostNetwork/externalIPs patch hatch and
# useListenerPortAsContainerPort have no equivalent in the plain Gateway API spec),
# gateway-helm chart values, and the API reference under site/content/en/docs/api.
cloneOrPull https://github.com/envoyproxy/gateway.git "$EXTERNAL_DIR/git_envoyproxy_gateway" api charts examples site/content/en/docs
# Gateway API upstream — HTTPRoute/Gateway/ReferenceGrant field semantics and the
# conformance expectations charts are written against.
cloneOrPull https://github.com/kubernetes-sigs/gateway-api.git "$EXTERNAL_DIR/git_kubernetes-sigs_gateway-api" apis config site-src
# kube-prometheus-stack — grafana/prometheus ingress + httpRoute values schema
# (deployment/argocd-infra/prometheus/kube-prometheus-stack). Sparse: only the charts tree.
cloneOrPull https://github.com/prometheus-community/helm-charts.git "$EXTERNAL_DIR/git_prometheus-community_helm-charts" charts

# Cilium — the cluster CNI (src/cni.ts). Authoritative source for
# the Helm values schema (install/kubernetes/cilium/values.yaml — routingMode/tunnelProtocol/
# MTU/policyEnforcementMode keys are guessed wrong easily) and for the datapath facts the
# cluster depends on: the real interface names, the kernel requirements audited on Thor, and
# the BGP control plane's "does not program the datapath" limitation that rules out native
# routing over tailscale0.
cloneOrPull https://github.com/cilium/cilium.git "$EXTERNAL_DIR/git_cilium_cilium" Documentation install/kubernetes/cilium

# Longhorn — the default StorageClass provider and the whole of src/storage.ts. The chart is
# the authority on the defaultSettings keys and, crucially, on their DEFAULTS: values.yaml
# leaves most of them `~` (unset), so the effective value is only stated in chart/README.md
# — e.g. storageMinimalAvailablePercentage defaults to 25, which is the disk-pressure floor
# src/storage.ts and 00-cleanup-node.sh both reason about without setting it. crds.yaml carries
# the RecurringJob/Volume/Node field semantics the recurring-jobs manifests depend on.
cloneOrPull https://github.com/longhorn/longhorn.git "$EXTERNAL_DIR/git_longhorn_longhorn" chart

# gVisor (runsc) — the cluster's nested-container runtime. Source is the authority on its
# FUSE protocol version (7.31, pkg/sentry/fsimpl/fuse/connection.go) and on what it does
# NOT implement (no NFS client in pkg/sentry/fsimpl/). Both facts decide what the EDA
# desktop can serve.
cloneOrPull https://github.com/google/gvisor.git "$EXTERNAL_DIR/git_google_gvisor"

# TrueNAS websocket API client (midclt + the Python Client) — the appliance is configured
# entirely through this API, so the source is the authority on
# things the docs get wrong: login_with_password IS a supported remote path
# (__init__.py auth.login_ex/PASSWORD_PLAIN), SCRAM-SHA-512 API keys and `-K <file>` are
# TrueNAS 26+ and NOT 25.10 (so on 25.10 a key crosses the wire in cleartext just like a
# password), and the API rate-limits at 20 auth attempts per 60s with a 10-MINUTE cooldown —
# which is why the configure script must hold ONE persistent session instead of invoking
# midclt per setting.
cloneOrPull https://github.com/truenas/api_client.git "$EXTERNAL_DIR/git_truenas_api_client"

# sambacc — the entrypoint INSIDE quay.io/samba.org/samba-ad-server, i.e. what actually
# provisions and joins the DCs in deployment/argocd-infra/samba-ad. The whole app is built on
# reading this source rather than the image README: the `--setup` step list
# (provision/populate/wait-domain/join), the `_provisioned` marker being smb.conf itself, and
# `_merge_config` running ONCE at provision/join so later `globals` edits are silently ignored
# (which is why apply-global-options exists).
# ⚠ A decisive fact: addc.py `_prep_join`
# passes global_options() straight into `samba-tool domain join`, and `_filter_opts` strips
# ONLY "netbios name" — so `interfaces` and `bind interfaces only` are in force DURING the
# join, before any smb.conf exists.
cloneOrPull https://github.com/samba-in-kubernetes/sambacc.git "$EXTERNAL_DIR/git_samba-in-kubernetes_sambacc"

# Hermes Agent — the agentic runtime in deployment/argocd-apps/hermes. This source is the
# authority on things the image README does not state and that cost real debugging time:
# agent/auxiliary_client.py resolves a custom-provider credential as
# explicit api_key -> $OPENAI_API_KEY -> the literal "no-key-required" (which is why
# model.api_key MUST be set), hermes_cli/web_server.py should_require_auth() exempts loopback
# from the dashboard gate, and hermes_cli/config_defaults.py documents the
# dashboard.basic_auth contract. agent/web_search_registry.py holds the provider fallback
# chain used for the SearXNG wiring.
cloneOrPull https://github.com/NousResearch/hermes-agent.git "$EXTERNAL_DIR/git_NousResearch_hermes-agent"

# SearXNG — self-hosted metasearch, the web-search backend for Hermes. Hermes has a
# first-class `searxng` provider (agent/web_search_registry.py), so no API key and no external
# search service is needed. This repo is the authority on settings.yml (the `search.formats`
# list must include `json` or the API returns 403) and on the required SEARXNG_SECRET.
cloneOrPull https://github.com/searxng/searxng.git "$EXTERNAL_DIR/git_searxng_searxng"

# Grafana Alloy — the log-collector DaemonSet (deployment/argocd-infra/alloy). The
# authority on Alloy river config: which components exist and what arguments they take.
# Needed to verify loki.source.file / local.file_match / loki.process stage.cri against
# source rather than guessing.
# `docs` carries the per-component reference; `internal/component` is the implementation.
cloneOrPull https://github.com/grafana/alloy.git "$EXTERNAL_DIR/git_grafana_alloy" docs internal/component

# Loki — the log store Alloy pushes to. Authority on the HTTP API (the X-Scope-OrgID
# tenant header multi-tenant queries require) and on limits like
# max_global_streams_per_user that the deliberate no-pod/no-node label choice protects.
cloneOrPull https://github.com/grafana/loki.git "$EXTERNAL_DIR/git_grafana_loki" docs production/helm

echo "External repositories checked out to $EXTERNAL_DIR"
