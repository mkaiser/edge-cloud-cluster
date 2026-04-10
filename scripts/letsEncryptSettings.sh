#!/bin/bash
# Utility to read and update Let's Encrypt email from project_settings.ts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"

if [ ! -f "$PROJECT_SETTINGS" ]; then
    echo "Error: Missing project settings file: $PROJECT_SETTINGS"
    exit 1
fi

if [ "$#" -eq 0 ] || [ "$1" = "get" ]; then
    # Get current Let's Encrypt email
    current_email=$(sed -nE 's/^[[:space:]]*email:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | grep -v "TODO" | head -n1)
    if [ -z "$current_email" ]; then
        echo "Error: Could not determine Let's Encrypt email from project_settings.ts"
        exit 1
    fi
    echo "$current_email"

elif [ "$1" = "set" ]; then
    if [ "$#" -ne 2 ]; then
        echo "Usage: $0 set <email>"
        echo "Example: $0 set admin@example.com"
        exit 1
    fi

    new_email="$2"

    # Validate email format (basic check)
    if ! [[ "$new_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid email format."
        echo "Got: $new_email"
        exit 1
    fi

    echo "Updating Let's Encrypt email from:"
    echo "  $(sed -nE 's/^[[:space:]]*email:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | grep -v "TODO" | head -n1)"
    echo "to:"
    echo "  $new_email"

    # Replace the Let's Encrypt email using Perl in the letsEncrypt export block
    NEW_EMAIL="$new_email" perl -i -pe 's#^(\s*email:\s*")[^"]+(")#$1$ENV{NEW_EMAIL}$2#m' "$PROJECT_SETTINGS"

    if [ $? -eq 0 ]; then
        echo "Successfully updated Let's Encrypt email in project_settings.ts"
    else
        echo "Error: Failed to update Let's Encrypt email"
        exit 1
    fi

else
    echo "Usage: $0 [get|set <email>]"
    echo ""
    echo "Commands:"
    echo "  get              Show current Let's Encrypt email from project_settings.ts"
    echo "  set <email>      Update Let's Encrypt email in project_settings.ts"
    echo ""
    echo "Examples:"
    echo "  $0 get"
    echo "  $0 set admin@example.com"
    exit 1
fi
