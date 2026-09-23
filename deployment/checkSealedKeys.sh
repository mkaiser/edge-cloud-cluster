#!/bin/bash
# Assert every committed SealedSecret can be opened with the key THIS STACK will build the
# next cluster from.
#
# WHY IT MATTERS, and why it is a lifecycle check rather than a cosmetic one:
# src/sealedsecrets.ts seeds the controller's `sealed-secrets-key` Secret from the Pulumi
# config values sealedSecretsTlsCrt/Key. So a file sealed with ANY OTHER certificate — a
# key the live controller rotated to, a colleague's stack, a hand-run kubeseal that fetched
# the cert from the cluster instead of the stack — is undecryptable on the next cluster.
#
# The failure is silent in the worst way: the SealedSecret applies cleanly, no Secret is
# ever produced, and the app that needed it comes up without credentials. On ecc193 exactly
# this had happened to the three image-registry secrets (found 2026-09-02, while renaming
# them): 98 other files were fine, those three would have brought the registry up with no
# htpasswd and no pull credential, surfacing hours later as CI auth errors that point
# nowhere near the cause.
#
# ⚠ RUN IT BEFORE A DESTROY, not only before a create. A mismatch found while the OLD
# cluster still exists is repairable without losing anything: the live Secret still holds
# the plaintext, so the value can be recovered and re-sealed with the right key. The same
# mismatch found after the destroy is a rotation — you can only generate a NEW secret and
# hope nothing outside the cluster knew the old one.
#
#   bash deployment/checkSealedKeys.sh          exit 1 if any file cannot be opened
#
# Needs the Pulumi stack loaded (PULUMI_CONFIG_PASSPHRASE + a selected stack) and kubeseal.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v kubeseal >/dev/null 2>&1 || {
    echo "ERROR: kubeseal not found — required to verify sealed secrets." >&2
    echo "  Install it (scripts/environment/install.sh) and re-run." >&2
    exit 2
}

if ! KEY=$(cd "$REPO_ROOT" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || [ -z "$KEY" ]; then
    echo "ERROR: cannot read sealedSecretsTlsKey from the Pulumi stack." >&2
    echo "  Load it first: source ./scripts/pulumi/initPulumiStack.sh" >&2
    exit 2
fi

checked=0
bad=()
while IFS= read -r f; do
    checked=$((checked + 1))
    kubeseal --recovery-unseal --recovery-private-key <(echo "$KEY") \
        < "$f" -o json >/dev/null 2>&1 || bad+=("$f")
done < <(find "$REPO_ROOT/deployment" -name '*-sealed.yaml' | sort)

if [ ${#bad[@]} -gt 0 ]; then
    echo "" >&2
    echo "Sealed-secret key check FAILED — ${#bad[@]} of $checked file(s) cannot be opened" >&2
    echo "with this stack's sealedSecretsTlsKey, so the NEXT cluster will not unseal them:" >&2
    for f in "${bad[@]}"; do
        echo "  - ${f#"$REPO_ROOT"/}" >&2
    done
    cat >&2 <<'MSG'

  Each one applies cleanly and produces NO Secret, so the app that needs it comes up
  without credentials and fails much later, far from here.

  While the current cluster is still UP, repair without losing the values:
    kubectl -n <ns> get secret <name> -o yaml     # the plaintext is still there
    ... then re-seal it through that app's sealSecrets.sh, which seals with the
        stack certificate (deployment/manageSealedSecrets.sh uses sealedSecretsTlsCrt).
  Only if the value is genuinely unrecoverable, regenerate it: <app>/sealSecrets.sh --regenerate.
MSG
    exit 1
fi

echo "ok: all $checked sealed file(s) open with this stack's sealedSecretsTlsKey"
