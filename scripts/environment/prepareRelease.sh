#!/usr/bin/env bash
# Anonymizes project_settings.ts for public release:
# - baseDomain → your-domain.tdl
# - subdomain  → ecc
# Then regenerates all derived config files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$REPO_ROOT/project_settings.ts"

ORIG_BASE=$(grep 'const baseDomain = ' "$SETTINGS" | sed 's/.*"\(.*\)".*/\1/')
ORIG_SUB=$(grep 'const subdomain = ' "$SETTINGS" | sed 's/.*"\(.*\)".*/\1/')

sed -i \
    's/const baseDomain = "[^"]*"/const baseDomain = "your-domain.tld"/' \
    "$SETTINGS"

sed -i \
    's/const subdomain = "[^"]*"/const subdomain = "ecc"/' \
    "$SETTINGS"

bash "$REPO_ROOT/scripts/environment/updateConfigFromProjectSettings.sh"

read -rp "Restore baseDomain=\"$ORIG_BASE\" subdomain=\"$ORIG_SUB\"? [yN] " REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    sed -i "s/const baseDomain = \"[^\"]*\"/const baseDomain = \"$ORIG_BASE\"/" "$SETTINGS"
    sed -i "s/const subdomain = \"[^\"]*\"/const subdomain = \"$ORIG_SUB\"/" "$SETTINGS"
    bash "$REPO_ROOT/scripts/environment/updateConfigFromProjectSettings.sh"
    echo "Restored."
fi
