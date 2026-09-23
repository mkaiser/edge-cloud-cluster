#!/usr/bin/env bash

set -uo pipefail

# Mint (or re-mint) the ArgoCD API tokens the argocd-mcp MCP server authenticates with,
# and store them in the Pulumi stack.
#
#   ./argocdMcpToken.sh            # ensure both tokens exist and work; mint what is missing
#   ./argocdMcpToken.sh --check    # report only, never write (exit 1 if a token is bad)
#   ./argocdMcpToken.sh --force    # re-mint both unconditionally
#
# WHY THE STACK AND NOT A SEALED SECRET: the consumer is a LOCAL process in the
# devcontainer (.mcp.json), not a pod. A sealed secret would never be unsealed by
# anything. The stack is the established route for a local-tool credential here —
# same as argocdAdminPasswordPlain, which this script reads to log in.
#
# WHY IT RE-MINTS: a recreate issues a new server.secretkey, which invalidates every
# previously issued token. The stored value then looks fine and fails at use. So the
# test is always "does this token actually answer the API", never "is it non-empty".
#
# The mcp-reader account itself is declared in git and is NOT created here:
#   deployment/argocd-infra/argocd-infra-self/values.yaml   (configs.cm + configs.rbac)
#   deployment/argocd-infra/argocd-apps/values.yaml
# If this script reports the account is missing, that commit has not reconciled yet.
#
# ⚠ REST, NOT THE argocd CLI. The Gateway terminates TLS without ALPN (HTTP/1.1 only),
# so `argocd login` dies with "gRPC connection not ready: context deadline exceeded"
# against a host whose plain HTTPS answers perfectly — measured 2026-09-23 with the
# /etc/hosts IPv4 pin already correct, so this is NOT the IPv6 issue argocdLoginCLI.sh
# works around. The two REST calls below (POST /api/v1/session, then
# POST /api/v1/account/<name>/token) need no CLI, no gRPC and no /etc/hosts pin.

MODE="ensure"
case "${1:-}" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    "") ;;
    *) echo "Usage: $0 [--check|--force]"; exit 2 ;;
esac

if [ -t 1 ]; then GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
else GRN=''; YEL=''; RED=''; RST=''; fi

ACCOUNT="mcp-reader"
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
cd "$REPO_DIR" || exit 1

fail=0

# ── admin password + cert posture, once for both instances ───────────────────
if ! admin_password=$(pulumi config get argocdAdminPasswordPlain --non-interactive 2>/dev/null); then
    echo "${RED}Failed to read Pulumi config 'argocdAdminPasswordPlain'.${RST}"
    echo "Load the stack first: source ./scripts/pulumi/initPulumiStack.sh"
    exit 1
fi
cert_issuer_type=$(pulumi stack output certIssuerType --non-interactive 2>/dev/null || true)

curl_tls=()
[ "$cert_issuer_type" = "letsencrypt-staging" ] && curl_tls+=(-k)

# ── token still valid? asks the API, never just "is it set" ──────────────────
token_works() {  # $1=base_url $2=token
    local url="$1" tok="$2" code
    [ -n "$tok" ] || return 1
    code=$(curl -s "${curl_tls[@]}" -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer $tok" "${url}/api/v1/applications" 2>/dev/null)
    [ "$code" = "200" ]
}

mint_token() {  # $1=instance $2=base_url ; echoes the JWT on stdout
    local instance="$1" url="$2" session payload

    # 1. admin session (REST — see the ALPN note in the header)
    payload=$(printf '{"username":"admin","password":%s}' \
        "$(printf '%s' "$admin_password" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
    session=$(curl -s "${curl_tls[@]}" --max-time 20 -X POST \
        -H 'Content-Type: application/json' -d "$payload" \
        "${url}/api/v1/session" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    if [ -z "$session" ]; then
        echo "${RED}  admin session failed at ${url}/api/v1/session${RST}" >&2
        return 1
    fi

    # 2. mint the account token
    curl -s "${curl_tls[@]}" --max-time 20 -X POST \
        -H "Authorization: Bearer $session" -H 'Content-Type: application/json' -d '{}' \
        "${url}/api/v1/account/${ACCOUNT}/token" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null
}

for instance in infra apps; do
    case "$instance" in
        infra) stack_output="argocdURL";     cfg_key="argocdMcpTokenInfra" ;;
        apps)  stack_output="argocdAppsURL"; cfg_key="argocdMcpTokenApps" ;;
    esac

    echo "── $instance ──────────────────────────────────────────────"

    if ! base_url=$(pulumi stack output "$stack_output" --non-interactive 2>/dev/null) \
        || [ -z "$base_url" ] || [ "$base_url" = "ArgoCD disabled" ]; then
        echo "${YEL}  stack output '$stack_output' unusable ('${base_url:-}') — skipping.${RST}"
        fail=1; continue
    fi
    base_url="${base_url%/}"
    echo "  url: $base_url"

    stored=$(pulumi config get "$cfg_key" --non-interactive 2>/dev/null || true)

    if [ "$MODE" != "force" ] && token_works "$base_url" "$stored"; then
        echo "  ${GRN}token OK${RST} (answers /api/v1/applications)"
        continue
    fi

    if [ -n "$stored" ]; then
        echo "  ${YEL}stored token does not authenticate${RST} (recreate? revoked?)"
    else
        echo "  no token stored yet"
    fi

    if [ "$MODE" = "check" ]; then
        echo "  ${RED}--check: not minting.${RST} Run without --check to fix."
        fail=1; continue
    fi

    echo "  minting a new token for account '$ACCOUNT'..."
    if ! new_token=$(mint_token "$instance" "$base_url") || [ -z "$new_token" ]; then
        echo "  ${RED}could not mint a token.${RST}"
        echo "  ${YEL}Check the account exists (it is declared in git, not here):${RST}"
        echo "    kubectl -n argocd-$instance get cm argocd-cm -o jsonpath='{.data.accounts\\.$ACCOUNT}'"
        fail=1; continue
    fi

    if ! token_works "$base_url" "$new_token"; then
        echo "  ${RED}the freshly minted token does NOT authenticate — not storing it.${RST}"
        echo "  ${YEL}Most likely the RBAC rules for '$ACCOUNT' have not reconciled yet.${RST}"
        fail=1; continue
    fi

    pulumi config set --secret "$cfg_key" "$new_token" >/dev/null 2>&1 \
        && echo "  ${GRN}minted and stored${RST} in Pulumi config '$cfg_key'" \
        || { echo "  ${RED}could not write '$cfg_key' to the stack.${RST}"; fail=1; }
done

echo
if [ "$fail" -eq 0 ]; then
    echo "${GRN}Both ArgoCD MCP tokens are present and authenticate.${RST}"
else
    echo "${YEL}One or more instances need attention (see above).${RST}"
fi
exit "$fail"
