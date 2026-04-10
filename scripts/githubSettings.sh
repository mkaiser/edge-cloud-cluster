#!/bin/bash
# Utility to read and update GitHub repository URL from project_settings.ts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"

if [ ! -f "$PROJECT_SETTINGS" ]; then
    echo "Error: Missing project settings file: $PROJECT_SETTINGS"
    exit 1
fi

if [ "$#" -eq 0 ] || [ "$1" = "get" ]; then
    # Get current GitHub repo URL
    current_url=$(sed -nE 's/^[[:space:]]*repoUrl[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)
    if [ -z "$current_url" ]; then
        echo "Error: Could not determine GitHub repo URL from project_settings.ts"
        exit 1
    fi
    echo "$current_url"

elif [ "$1" = "set" ]; then
    if [ "$#" -ne 2 ]; then
        echo "Usage: $0 set <github-repo-url>"
        echo "Example: $0 set git@github.com:my-org/my-repo.git"
        exit 1
    fi

    new_url="$2"

    # Validate URL format (basic check)
    if ! [[ "$new_url" =~ ^git@github\.com:[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\.git$ ]]; then
        echo "Error: Invalid GitHub URL format. Expected: git@github.com:owner/repo.git"
        echo "Got: $new_url"
        exit 1
    fi

    echo "Updating GitHub repo URL from:"
    echo "  $(sed -nE 's/^[[:space:]]*repoUrl[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1)"
    echo "to:"
    echo "  $new_url"

    # Replace the GitHub repo URL using Perl, similar to domainSettings.sh pattern
    NEW_URL="$new_url" perl -i -pe 's/^(\s*repoUrl:\s*")[^"]+(".*)$/$1$ENV{NEW_URL}$2/' "$PROJECT_SETTINGS"

    if [ $? -eq 0 ]; then
        echo "Successfully updated GitHub repo URL in project_settings.ts"
    else
        echo "Error: Failed to update GitHub repo URL"
        exit 1
    fi

else
    echo "Usage: $0 [get|set <github-repo-url>]"
    echo ""
    echo "Commands:"
    echo "  get                    Show current GitHub repo URL from project_settings.ts"
    echo "  set <url>              Update GitHub repo URL in project_settings.ts"
    echo ""
    echo "Examples:"
    echo "  $0 get"
    echo "  $0 set git@github.com:my-org/my-repo.git"
    exit 1
fi
