#!/usr/bin/env bash
# Run Renovate LOCALLY against the GitHub repo to CREATE pull requests on demand
# (same effect as the in-cluster CronJob, triggered from your machine).
#
# Automerge is FORCE-DISABLED here: PRs are opened but never merged automatically,
# even though renovate.json enables automerge for minor updates.
#
# By default it targets only the CURRENT branch as base (avoids opening PRs on
# every branch via renovate.json's baseBranchPatterns). Use --all-branches to
# honor the repo config instead.
#
# Token (GitHub PAT, 'repo' scope): ALWAYS read from the Pulumi stack config
# value `githubPatToken` (set via scripts/secrets/setGithubPatToken.sh). Prompts
# for PULUMI_CONFIG_PASSPHRASE if not already exported. Works whether the cluster
# is up or down.
# Set $RENOVATE_TOKEN only if you deliberately want to bypass the stack.
#
# Engine: Docker image ghcr.io/renovatebot/renovate:43 (preferred — bundles the
# required Node), otherwise npx under fnm Node 24.
#
# Usage:
#   ./scripts/environment/runRenovateOffline.sh                # create PRs against current branch
#   ./scripts/environment/runRenovateOffline.sh --all-branches # honor renovate.json baseBranchPatterns
#   ./scripts/environment/runRenovateOffline.sh --dry-run      # preview only: no push, no PRs
#   ./scripts/environment/runRenovateOffline.sh --debug        # verbose logs
#   ./scripts/environment/runRenovateOffline.sh --update-all   # collapse ALL pending updates into one "Update All" PR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE="ghcr.io/renovatebot/renovate:43"  # keep in sync with deployment/argocd-infra/renovate/cronjob.yaml
NPM_SPEC="renovate@43"
# Derived from argocd.git.repoUrl rather than duplicated: that setting is the single source
# of truth for the repo slug (the anchor engine rewrites every manifest occurrence from it),
# so a hardcoded copy here would be one more literal to drift — and one more place the repo
# owner's name leaks into a public release.
REPOSITORY="$(sed -nE 's#.*repoUrl: "git@github\.com:([^"]+)\.git".*#\1#p' \
    "$REPO_ROOT/project_settings.ts" | head -n1)"
[ -n "$REPOSITORY" ] || { echo "ERROR: could not read argocd.git.repoUrl from project_settings.ts" >&2; exit 1; }

# Same reason as REPOSITORY above: mail.senderEmail is the one address project_settings.ts
# owns, so the commit author follows a domain change instead of being a literal that leaks
# into a public release.
GIT_AUTHOR_ADDR="$(sed -nE 's#.*senderEmail: "([^"]+)".*#\1#p' \
    "$REPO_ROOT/project_settings.ts" | head -n1)"
[ -n "$GIT_AUTHOR_ADDR" ] || { echo "ERROR: could not read mail.senderEmail from project_settings.ts" >&2; exit 1; }
RENOVATE_AUTHOR="Renovate Bot <$GIT_AUTHOR_ADDR>"

LOG_LEVEL="info"
DRY=0
ALL_BRANCHES=0
UPDATE_ALL=0
for arg in "$@"; do
    case "$arg" in
        --debug)        LOG_LEVEL="debug" ;;
        --dry-run)      DRY=1 ;;
        --all-branches) ALL_BRANCHES=1 ;;
        --update-all)   UPDATE_ALL=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# --- Resolve the GitHub PAT ---------------------------------------------------
# Read the GitHub PAT straight from the Pulumi stack config (githubPatToken).
# Works even when the cluster is down — no unsealing needed.
token_from_stack() {
    command -v pulumi >/dev/null 2>&1 || return 1

    if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
        read -rsp "  Enter PULUMI_CONFIG_PASSPHRASE to read the token: " PULUMI_CONFIG_PASSPHRASE
        echo >&2
        export PULUMI_CONFIG_PASSPHRASE
    fi
    pulumi -C "$REPO_ROOT" login "file://$REPO_ROOT/.pulumi-state" >/dev/null 2>&1 || true
    pulumi -C "$REPO_ROOT" stack select mystack >/dev/null 2>&1 || true

    local token
    token="$(pulumi -C "$REPO_ROOT" config get githubPatToken 2>/dev/null)" || return 1
    [ -n "$token" ] && printf '%s' "$token"
}

resolve_token() {
    # Explicit override (deliberate opt-out of the stack).
    if [ -n "${RENOVATE_TOKEN:-}" ]; then printf '%s' "$RENOVATE_TOKEN"; return 0; fi

    # Always read the token from the Pulumi stack (works cluster up or down).
    echo "  Reading githubPatToken from the Pulumi stack..." >&2
    local t; t="$(token_from_stack)" && [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    return 1
}

echo "Resolving GitHub token..."
if ! TOKEN="$(resolve_token)" || [ -z "$TOKEN" ]; then
    cat >&2 <<EOF
ERROR: could not obtain the GitHub PAT from the Pulumi stack.
  - Provide the correct PULUMI_CONFIG_PASSPHRASE and ensure githubPatToken is set
    (run scripts/secrets/setGithubPatToken.sh), or
  - set RENOVATE_TOKEN to deliberately bypass the stack.
EOF
    exit 1
fi
echo "Token resolved (length ${#TOKEN}, prefix ${TOKEN:0:4}****)."

# --- Build the force-override config -----------------------------------------
# 'force' has the highest precedence and overrides renovate.json — used here to
# guarantee automerge stays OFF and (by default) to pin the base branch.
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
# --update-all: a single highest-precedence packageRule (force outranks
# renovate.json) groups every pending update into one "Update All" PR.
PR_FRAG=""
if [ "$UPDATE_ALL" -eq 1 ]; then
    PR_FRAG=',"packageRules":[{"matchPackageNames":["*"],"groupName":"Update All","groupSlug":"update-all"}]'
    echo "Grouping: ALL pending updates collapsed into one \"Update All\" PR."
fi
if [ "$ALL_BRANCHES" -eq 1 ]; then
    FORCE="{\"automerge\":false,\"platformAutomerge\":false${PR_FRAG}}"
    echo "Base branches: per renovate.json baseBranchPatterns (all branches)."
else
    # Renovate 43 renamed baseBranches -> baseBranchPatterns; a value without
    # surrounding slashes is matched exactly (not as a regex).
    FORCE="{\"automerge\":false,\"platformAutomerge\":false,\"baseBranchPatterns\":[\"$CURRENT_BRANCH\"]${PR_FRAG}}"
    echo "Base branch: $CURRENT_BRANCH (use --all-branches to override)."
fi

if [ "$DRY" -eq 1 ]; then
    echo "Mode: DRY-RUN (no push, no PRs)."
else
    echo "Mode: LIVE — will create/update PRs on $REPOSITORY (automerge disabled)."
fi
echo

# --- Run ----------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "Engine: docker ($IMAGE)"; echo
    dry_args=(); [ "$DRY" -eq 1 ] && dry_args=(-e RENOVATE_DRY_RUN=full)
    docker run --rm \
        -e RENOVATE_TOKEN="$TOKEN" \
        -e RENOVATE_REPOSITORIES="$REPOSITORY" \
        -e RENOVATE_FORCE="$FORCE" \
        -e RENOVATE_GIT_AUTHOR="$RENOVATE_AUTHOR" \
        -e LOG_LEVEL="$LOG_LEVEL" \
        "${dry_args[@]}" \
        "$IMAGE"
elif command -v npx >/dev/null 2>&1; then
    echo "Engine: npx ($NPM_SPEC via fnm Node 24) — Docker daemon not reachable"; echo
    fnm_cmd=()
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "$node_major" -gt 24 ] && command -v fnm >/dev/null 2>&1; then
        eval "$(fnm env 2>/dev/null)"
        fnm_cmd=(fnm exec --using=24)
    fi
    env_args=(
        RENOVATE_TOKEN="$TOKEN"
        RENOVATE_REPOSITORIES="$REPOSITORY"
        RENOVATE_FORCE="$FORCE"
        RENOVATE_GIT_AUTHOR="$RENOVATE_AUTHOR"
        LOG_LEVEL="$LOG_LEVEL"
    )
    [ "$DRY" -eq 1 ] && env_args+=(RENOVATE_DRY_RUN=full)
    env "${env_args[@]}" "${fnm_cmd[@]}" npx --force "$NPM_SPEC"
else
    echo "ERROR: need a running Docker daemon or npx (Node.js) to run Renovate." >&2
    exit 1
fi
