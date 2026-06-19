#bin/bash

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced, not executed directly."
    echo "Usage: source ${0}"
    echo "   or: . ${0}"
    exit 1
fi

use_existing=""
if [[ -s /tmp/passphrase ]]; then
    read -p "Passphrase found at /tmp/passphrase. Use it [Y] or enter a new one [e]? [Y/e]: " use_existing
fi

if [[ -s /tmp/passphrase ]] && [[ "$use_existing" =~ ^[Yy]?$ ]]; then
    PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
    echo "Using existing passphrase from /tmp/passphrase."
else
    echo "Enter the PULUMI_CONFIG_PASSPHRASE (the passphrase to protect your pulumi stack)."
    echo "Do yourself a favor and never use a backtick in this passphrase..."
    read -s -p "PULUMI_CONFIG_PASSPHRASE: " PULUMI_CONFIG_PASSPHRASE
    echo
fi
read -p "Store it as environment variable for this session? [Y/n]: " store_env
if [[ "$store_env" =~ ^[Yy]?$ ]]; then
    export PULUMI_CONFIG_PASSPHRASE
    echo "PULUMI_CONFIG_PASSPHRASE stored as environment variable only for this session."
fi

if [[ ! -s /tmp/passphrase ]] || [[ ! "$use_existing" =~ ^[Yy]?$ ]]; then
    read -p "Save passphrase to /tmp/passphrase to make it available to LLMs? [y/N]: " save_llm
    if [[ "$save_llm" =~ ^[Yy]$ ]]; then
        printf '%s' "$PULUMI_CONFIG_PASSPHRASE" > /tmp/passphrase
        echo "Passphrase saved to /tmp/passphrase."
    fi
fi
