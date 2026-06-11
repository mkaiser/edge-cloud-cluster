#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"

usage() {
    cat <<'EOF'
Usage:
    ./scripts/domainSettings.sh get
    ./scripts/domainSettings.sh set <domain>

Commands:
  get           Print current cluster.baseDomain from project_settings.ts
  set <domain>  Set cluster.baseDomain in project_settings.ts
EOF
}

extract_base_domain() {
    sed -nE 's/^[[:space:]]*(const[[:space:]]+)?baseDomain[[:space:]]*[:=][[:space:]]*"([^"]+)".*/\2/p' "$PROJECT_SETTINGS" | head -n1
}

set_base_domain() {
    local new_domain="$1"

    NEW_DOMAIN="$new_domain" perl -i -pe '
        BEGIN { $done = 0 }
        if (!$done && s/^(\s*(?:const\s+)?baseDomain\s*[:=]\s*")[^"]+(".*)$/$1$ENV{NEW_DOMAIN}$2/) {
            $done = 1;
        }
    ' "$PROJECT_SETTINGS"
}

if [ ! -f "$PROJECT_SETTINGS" ]; then
    echo "Missing project settings file: $PROJECT_SETTINGS"
    exit 1
fi

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

case "$1" in
    get)
        if [ "$#" -ne 1 ]; then
            usage
            exit 1
        fi
        current_domain="$(extract_base_domain)"
        if [ -z "$current_domain" ]; then
            echo "Could not extract cluster.baseDomain from project_settings.ts"
            exit 1
        fi
        echo "$current_domain"
        ;;
    set)
        if [ "$#" -ne 2 ]; then
            usage
            exit 1
        fi

        new_domain="$2"
        if [ -z "$new_domain" ]; then
            echo "Domain must not be empty."
            exit 1
        fi

        if [[ ! "$new_domain" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$new_domain" != *.* ]]; then
            echo "Invalid domain '$new_domain'. Expected something like example.com"
            exit 1
        fi

        old_domain="$(extract_base_domain)"
        if [ -z "$old_domain" ]; then
            echo "Could not extract cluster.baseDomain from project_settings.ts"
            exit 1
        fi

        set_base_domain "$new_domain"
        updated_domain="$(extract_base_domain)"
        if [ "$updated_domain" != "$new_domain" ]; then
            echo "Failed to update cluster.baseDomain in project_settings.ts"
            exit 1
        fi

        echo "Updated cluster.baseDomain: '$old_domain' -> '$updated_domain'"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
