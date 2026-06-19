#!/bin/bash
# Ensure an hcloud token is available for the CLI.
#
# Order of preference:
#   1. HCLOUD_TOKEN already in the environment / an active hcloud context
#   2. derive the token from the loaded Pulumi stack (`pulumi config get hcloudToken`)
#
# Safe to `source` (does not exit the caller) and idempotent (re-running with an
# existing "default" context is a no-op). Returns non-zero if no token can be found.

ensure_hcloud_token() {
    # Already usable? (explicit token or a non-empty active context)
    if [ -n "${HCLOUD_TOKEN:-}" ] || [ -n "$(hcloud context active 2>/dev/null)" ]; then
        return 0
    fi

    # Fall back to the Pulumi stack (requires `pulumi stack select <stack>`).
    if HCLOUD_TOKEN=$(pulumi config get hcloudToken 2>/dev/null) && [ -n "$HCLOUD_TOKEN" ]; then
        export HCLOUD_TOKEN
        # Persist as the "default" context too, unless one already exists.
        if ! hcloud context list -o noheader 2>/dev/null | grep -qw default; then
            hcloud context create default --token-from-env >/dev/null 2>&1 || true
        fi
        return 0
    fi

    echo "ERROR: no HCLOUD_TOKEN and no active hcloud context." >&2
    echo "       Load the Pulumi stack first (source ./scripts/pulumi/initPulumiStack.sh)" >&2
    echo "       or export HCLOUD_TOKEN before running." >&2
    return 1
}

# When executed directly (not sourced), run it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ensure_hcloud_token
fi
