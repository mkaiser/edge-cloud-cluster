#!/bin/bash
# Post-devcontainer-restart bootstrap. MUST be sourced (sets env in YOUR shell):
#
#   source ./scripts/init.sh
#
# Steps:
#   0. relink Claude's auto-memory dir to the repo-tracked .claude/memory/
#      (per-machine $HOME setup; a devcontainer rebuild resets it).
#   1. source initPulumiStack.sh  -> passphrase + `pulumi login` + stack select
#      (persisted in the calling shell; make can't do this — child-shell env dies).
#   2. stack initialized?  (kubeconfig output = a cluster was deployed; same signal
#      checkClusterExists.sh treats as authoritative).
#   3. if so, reconnect the admin WireGuard tunnel (wgAdminUp.sh).
#   4. ensure kubeconfig is fresh (getKubeConfig.sh vpn, only if stale) and smoke
#      test with `kubectl get node`.
#   5. log the argocd CLI into both instances (infra + apps) as named contexts.
#   6. ensure the argocd-mcp API tokens and write the token registry the MCP
#      server reads (.mcp.json); exports ARGOCD_MCP_* into the calling shell.

# ── Must be sourced ──────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: this script must be sourced, not executed."
    echo "Usage: source ${0}"
    exit 1
fi

_INIT_REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# ── 0. Claude auto-memory symlink ────────────────────────────────────────────
# Claude only reads/writes ~/.claude/projects/<slug>/memory; point it at the
# repo-tracked .claude/memory/ so memories stay committed & shared. Idempotent,
# and non-fatal — a broken link must not stop the cluster bootstrap.
bash "$_INIT_REPO_ROOT/scripts/environment/linkClaudeMemory.sh" \
    || echo "WARNING: could not link Claude memory dir — memories may not be tracked in git."

# ── 0b. Claude session home: verify volume + one-time backup restore ────────
# ~/.claude/projects holds session transcripts; devcontainer.json mounts it as
# a named volume so sessions survive rebuilds. Non-fatal — a missing session
# must not stop the cluster bootstrap.
bash "$_INIT_REPO_ROOT/scripts/environment/initClaudeHome.sh" \
    || echo "WARNING: Claude session home check failed — see scripts/environment/initClaudeHome.sh."

# ── 1. Pulumi env in THIS shell ──────────────────────────────────────────────
source "$_INIT_REPO_ROOT/scripts/pulumi/initPulumiStack.sh"

# ── Ensure passphrase survives for the WG step ───────────────────────────────
# wgAdminUp.sh runs `pulumi stack output --show-secrets` in a subprocess, which
# needs PULUMI_CONFIG_PASSPHRASE exported. initPulumiStack.sh unsets it when the
# user declines "store env"; recover it from /tmp/passphrase (CLAUDE.md convention).
if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" && -s /tmp/passphrase ]]; then
    export PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
fi

# ── 2. Stack initialized? ────────────────────────────────────────────────────
if pulumi -C "$_INIT_REPO_ROOT" stack output kubeconfig --show-secrets >/dev/null 2>&1; then
    # ── 3. Reconnect admin WireGuard ─────────────────────────────────────────
    echo "Stack initialized — reconnecting admin WireGuard..."
    bash "$_INIT_REPO_ROOT/scripts/runtime/wgAdminUp.sh"

    # ── 4. Ensure kubeconfig is fresh, then smoke-test kubectl ───────────────
    # Only re-fetch when there's no working config (missing file, or /healthz
    # fails over the tunnel we just brought up) — don't clobber a good one on
    # every source. `vpn` mode = private IPs via wgadmin (10.0.0.0/16 routing).
    _KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    if [[ ! -s "$_KUBECONFIG" ]] || ! kubectl --request-timeout=10s get --raw=/healthz >/dev/null 2>&1; then
        echo "Kubeconfig missing or stale — fetching via VPN..."
        bash "$_INIT_REPO_ROOT/scripts/runtime/getKubeConfig.sh" vpn
    else
        echo "Kubeconfig already healthy — skipping fetch."
    fi

    echo "--- kubectl get node ---"
    if ! kubectl --request-timeout=10s get node; then
        echo "kubectl get node failed — is the WireGuard tunnel up and the cluster running?"
    fi
    unset _KUBECONFIG

    # ── 5. Log the argocd CLI into both instances ───────────────────────────
    # Two contexts (infra + apps); `argocd context <host>` switches. Non-fatal —
    # ArgoCD may be disabled or still syncing, that must not break the shell.
    for _INSTANCE in infra apps; do
        echo "--- argocd login ($_INSTANCE) ---"
        bash "$_INIT_REPO_ROOT/scripts/runtime/argocdLoginCLI.sh" "$_INSTANCE" \
            || echo "WARNING: argocd CLI login for '$_INSTANCE' failed — run scripts/runtime/argocdLoginCLI.sh $_INSTANCE manually."
    done
    unset _INSTANCE

    # ── 6. ArgoCD MCP tokens + token registry ───────────────────────────────
    # The argocd-mcp server (.mcp.json) authenticates with an API token per
    # instance. They live in the Pulumi stack; a recreate invalidates both (new
    # server.secretkey), so ensure them here rather than assuming. Non-fatal —
    # a broken MCP token must never block the shell or a bootstrap.
    echo "--- argocd MCP tokens ---"
    if bash "$_INIT_REPO_ROOT/scripts/runtime/argocdMcpToken.sh"; then
        # The registry pairs base URL -> token so ONE server serves both
        # instances. It holds two live credentials: mode 0600, and NEVER inside
        # the repo.
        _MCP_REG="${XDG_RUNTIME_DIR:-/tmp}/argocd-mcp-tokens.json"
        if _MCP_INFRA_URL=$(pulumi stack output argocdURL --non-interactive 2>/dev/null) &&
            _MCP_APPS_URL=$(pulumi stack output argocdAppsURL --non-interactive 2>/dev/null) &&
            _MCP_INFRA_TOK=$(pulumi config get argocdMcpTokenInfra --non-interactive 2>/dev/null) &&
            _MCP_APPS_TOK=$(pulumi config get argocdMcpTokenApps --non-interactive 2>/dev/null); then
            (
                umask 077
                python3 -c 'import json,sys; print(json.dumps([
                    {"baseUrl": sys.argv[1].rstrip("/"), "token": sys.argv[2]},
                    {"baseUrl": sys.argv[3].rstrip("/"), "token": sys.argv[4]}]))' \
                    "$_MCP_INFRA_URL" "$_MCP_INFRA_TOK" "$_MCP_APPS_URL" "$_MCP_APPS_TOK" \
                    > "$_MCP_REG"
            ) && chmod 600 "$_MCP_REG" 2>/dev/null
            export ARGOCD_MCP_TOKEN_REGISTRY="$_MCP_REG"
            export ARGOCD_MCP_BASE_URL="${_MCP_INFRA_URL%/}"
            echo "argocd-mcp: token registry at $_MCP_REG (default base URL: $ARGOCD_MCP_BASE_URL)"
        else
            echo "WARNING: could not assemble the argocd-mcp token registry — the argocd MCP server will not authenticate."
        fi
        unset _MCP_REG _MCP_INFRA_URL _MCP_APPS_URL _MCP_INFRA_TOK _MCP_APPS_TOK
    else
        echo "WARNING: scripts/runtime/argocdMcpToken.sh failed — the argocd MCP server will not authenticate."
    fi
else
    echo "Stack not initialized / no cluster deployed — skipping WireGuard reconnect."
fi

unset _INIT_REPO_ROOT
