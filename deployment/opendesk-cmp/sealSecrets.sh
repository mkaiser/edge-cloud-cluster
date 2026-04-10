#!/bin/bash
# SMTP credentials have moved to deployment/secrets/.
# Run deployment/secrets/sealSecrets.sh to create/update the smtp-credentials secret.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../secrets/sealSecrets.sh" "$@"
