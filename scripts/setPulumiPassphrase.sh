#bin/bash

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced, not executed directly."
    echo "Usage: source ${0}"
    echo "   or: . ${0}"
    exit 1
fi

read -s -p "Enter the PULUMI_CONFIG_PASSPHRASE (the passphrase to protect your pulumi stack): " PULUMI_CONFIG_PASSPHRASE
echo
read -p "Store it as environment variable for this session? [Y/n]: " store_env
if [[ "$store_env" =~ ^[Yy]?$ ]]; then
    export PULUMI_CONFIG_PASSPHRASE
    echo "PULUMI_CONFIG_PASSPHRASE stored as environment variable only for this session."
fi
