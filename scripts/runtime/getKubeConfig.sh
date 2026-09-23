#!/bin/bash
# getKubeConfig.sh — write ~/.kube/config from the Pulumi stack (or via SSH).
#
# Invoked BOTH sourced (up.sh, _lifecycle.sh) and as `bash ...` (init.sh,
# runRenovateViaKubernetes.sh). So it must NOT use bare `return` (fatal when run) NOR
# `exit` (would kill the caller's shell when sourced). Instead every path sets RC and
# funnels through a single `return/exit` trampoline at the end that picks the right one.
#
# CRITICAL: never redirect a fetch straight onto $KUBECONFIG. `> "$KUBECONFIG"` truncates
# the file the instant the command starts, so a FAILED fetch leaves a 0-byte kubeconfig and
# destroys the working one. Every fetch writes a temp file, is verified non-empty, and only
# then atomically replaces the target.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourced or executed? (BASH_SOURCE[0] == $0 only when executed directly.)
_gkc_sourced=0
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && _gkc_sourced=1
# Single exit point that works in both contexts.
_gkc_finish() { if [[ "$_gkc_sourced" == "1" ]]; then return "${1:-0}"; else exit "${1:-0}"; fi; }

# check if PULUMI_CONFIG_PASSPHRASE is set, else prompt it via setPulumiPassphrase.sh
if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    echo "PULUMI_CONFIG_PASSPHRASE is not set. Please enter it now."
    source "$SCRIPT_DIR/../pulumi/setPulumiPassphrase.sh"
else
    echo "PULUMI_CONFIG_PASSPHRASE is already set. Using existing value."
fi

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
export KUBECONFIG="$KUBECONFIG_PATH"

mode="${1:-}"

# Fetch into a temp file, verify non-empty, then atomically move onto $KUBECONFIG.
# Prints its own error and returns non-zero on any failure — never touches the live
# file unless the new content is good. Args: <description> <command...>
_gkc_write() {
    local desc="$1"; shift
    local tmp; tmp="$(mktemp "${KUBECONFIG_PATH}.XXXXXX.tmp")"
    if "$@" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        mv "$tmp" "$KUBECONFIG_PATH"
        return 0
    fi
    rm -f "$tmp"
    echo "Error: $desc — the live kubeconfig at $KUBECONFIG_PATH is left untouched." >&2
    return 1
}

# NOTE: the stack exports a SINGLE kubeconfig output named `kubeconfig` (main.ts) — since
# the stable-hostname change it already targets the API VIP (network.apiServerHost), reached
# over the admin WireGuard tunnel. There is NO `kubeconfigVpn` output; the old `vpn` branch
# referenced one that never existed, which (combined with the truncating redirect) is exactly
# what wiped ~/.kube/config to 0 bytes. `vpn` and the default now both fetch `kubeconfig`.
if [[ "$mode" == "ssh" ]]; then
    echo "Fetching kubeconfig via SSH (Debian/K3s only)..."
    if ! CP_IP=$(pulumi stack output controlPlaneIP 2>/dev/null); then
        echo "Error: Failed to fetch controlPlaneIP from Pulumi stack." >&2
        _gkc_finish 1; return $? 2>/dev/null
    fi
    _gkc_fetch_ssh() {
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$CP_IP" \
            "cat /etc/rancher/k3s/k3s.yaml" | sed "s|https://127.0.0.1:6443|https://$CP_IP:6443|g"
    }
    if _gkc_write "SSH kubeconfig fetch from $CP_IP failed (empty or unreachable)" _gkc_fetch_ssh; then
        echo "✓ Kubeconfig saved to $KUBECONFIG_PATH (via SSH)"
    else
        _gkc_finish 1; return $? 2>/dev/null
    fi
else
    if [[ "$mode" == "vpn" ]]; then
        echo "Fetching kubeconfig (private-IP/VIP via WireGuard VPN) from Pulumi stack..."
    else
        echo "Fetching kubeconfig from Pulumi stack..."
    fi
    if _gkc_write "'pulumi stack output kubeconfig' failed (missing output or wrong passphrase)" \
            pulumi stack output kubeconfig --show-secrets; then
        echo "✓ Kubeconfig saved to $KUBECONFIG_PATH"
    else
        _gkc_finish 1; return $? 2>/dev/null
    fi
fi

_gkc_finish 0
