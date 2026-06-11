#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOMAIN_SETTINGS_SCRIPT="$SCRIPT_DIR/domainSettings.sh"
GITHUB_SETTINGS_SCRIPT="$SCRIPT_DIR/githubSettings.sh"
GENERIC_DOMAIN="your-domain.tld"
GENERIC_GITHUB_URL="git@github.com:owner/repo.git"
GENERIC_LETS_ENCRYPT_EMAIL="admin@your-domain.tld"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"

if [ ! -x "$DOMAIN_SETTINGS_SCRIPT" ]; then
    echo "Missing or non-executable script: $DOMAIN_SETTINGS_SCRIPT"
    exit 1
fi

if [ ! -x "$GITHUB_SETTINGS_SCRIPT" ]; then
    echo "Missing or non-executable script: $GITHUB_SETTINGS_SCRIPT"
    exit 1
fi

extract_email() {
    sed -nE 's/.*letsEncrypt[[:space:]]*:[[:space:]]*\{[[:space:]]*email[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_SETTINGS" | head -n1
}

set_email() {
    NEW_EMAIL="$1" perl -i -pe \
        's/(letsEncrypt\s*:\s*\{\s*email\s*:\s*")[^"]+(")/\1$ENV{NEW_EMAIL}\2/' \
        "$PROJECT_SETTINGS"
}

cd "$REPO_ROOT"

old_domain="$("$DOMAIN_SETTINGS_SCRIPT" get)"
if [ -z "$old_domain" ]; then
    echo "Could not extract cluster.baseDomain via $DOMAIN_SETTINGS_SCRIPT"
    exit 1
fi

old_github_url="$("$GITHUB_SETTINGS_SCRIPT" get)"
if [ -z "$old_github_url" ]; then
    echo "Could not extract github.repoUrl via $GITHUB_SETTINGS_SCRIPT"
    exit 1
fi

old_lets_encrypt_email="$(extract_email)"
if [ -z "$old_lets_encrypt_email" ]; then
    echo "Could not extract letsEncrypt.email from project_settings.ts"
    exit 1
fi

echo "Saved old domain: $old_domain"
echo "Saved old GitHub URL: $old_github_url"
echo "Saved old Let's Encrypt email: $old_lets_encrypt_email"

if [ "$old_domain" != "$GENERIC_DOMAIN" ]; then
    echo "Setting project_settings.ts baseDomain to '$GENERIC_DOMAIN' ..."
    "$DOMAIN_SETTINGS_SCRIPT" set "$GENERIC_DOMAIN"
fi

if [ "$old_github_url" != "$GENERIC_GITHUB_URL" ]; then
    echo "Setting project_settings.ts github.repoUrl to '$GENERIC_GITHUB_URL' ..."
    "$GITHUB_SETTINGS_SCRIPT" set "$GENERIC_GITHUB_URL"
fi

if [ "$old_lets_encrypt_email" != "$GENERIC_LETS_ENCRYPT_EMAIL" ]; then
    echo "Setting project_settings.ts letsEncrypt.email to '$GENERIC_LETS_ENCRYPT_EMAIL' ..."
    set_email "$GENERIC_LETS_ENCRYPT_EMAIL"
fi

echo "Updating deployment manifests from project_settings.ts with generic release settings..."
"$SCRIPT_DIR/updateConfigFromProjectSettings.sh"

echo
echo "Domain is set to '$GENERIC_DOMAIN', GitHub URL is set to '$GENERIC_GITHUB_URL', and email is set to '$GENERIC_LETS_ENCRYPT_EMAIL'."
read -r -p "Do you want to restore old settings (domain '$old_domain', URL '$old_github_url', email '$old_lets_encrypt_email') in project_settings.ts now? (y/n) " reply

if [[ "$reply" =~ ^[Yy]$ ]]; then
    "$DOMAIN_SETTINGS_SCRIPT" set "$old_domain"
    "$GITHUB_SETTINGS_SCRIPT" set "$old_github_url"
    set_email "$old_lets_encrypt_email"
    echo "Updating deployment manifests from project_settings.ts with restored settings..."
    "$SCRIPT_DIR/updateConfigFromProjectSettings.sh"
else
    echo "Kept project_settings.ts baseDomain as '$GENERIC_DOMAIN'."
    echo "Kept project_settings.ts github.repoUrl as '$GENERIC_GITHUB_URL'."
    echo "Kept project_settings.ts letsEncrypt.email as '$GENERIC_LETS_ENCRYPT_EMAIL'."
fi
