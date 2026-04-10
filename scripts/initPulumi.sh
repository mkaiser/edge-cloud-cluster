#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced, not executed directly."
    echo "Usage: source ${0}"
    echo "   or: . ${0}"
    exit 1
fi

# ensure pulumi state folder exists
mkdir -p .pulumi-state


source "$SCRIPT_DIR/setPulumiPassphrase.sh"

if [[ ! "$store_env" =~ ^[Yy]?$ ]]; then
    echo "PULUMI_CONFIG_PASSPHRASE will not be stored as environment variable. You will need to set it manually before running pulumi commands."
fi


# Check if stack exists, if not create one
pulumi login "file://$(pwd)/.pulumi-state"
stack_count=$(pulumi stack ls | wc -l)
if [[ $stack_count -eq 1 ]]; then
    echo "Creating new pulumi stack \"mystack\""
    pulumi stack init mystack
else
    echo "Using existing stack \"mystack\""
fi
pulumi stack select mystack


read -p "Do you want to enter PULUMI secrets now? Previous store secrets stored in Pulumi.mystack.yaml be overriden! [y/N]: " enter_pulumi_secrets
if [[ "$enter_pulumi_secrets" =~ ^[Yy]$ ]]; then
    source "$SCRIPT_DIR/setPulumiSecrets.sh"
else
    echo "Skipping secrets configuration. You can run \"./scripts/setPulumiSecrets.sh\" later to configure secrets."
fi

if [[ ! "$store_env" =~ ^[Yy]$ ]]; then
    unset PULUMI_CONFIG_PASSPHRASE
    echo "PULUMI_CONFIG_PASSPHRASE cleared from environment."
fi


# NOTE HINT FIXME I think this is bad, but I often forget this...
export HCLOUD_TOKEN=$(pulumi config get hcloudToken)

hcloud context create default --token-from-env  
# mabye test --quiet 