#!/bin/bash
# Seals the EDA LICENCE SERVERS — the values every EDA tool needs at RUN time.
#
# WHY ITS OWN APP: these are EDA concerns, not desktop ones. They lived in
# `remote-desktop-secrets` because the desktop was once the only thing that ran a module,
# and five EDA module manifests then had to reference another app's secret by name. The
# desktop is now one runtime among two (the [eda-run] CI runner is the other), so the
# licence belongs with EDA and the desktop secret keeps only db-password/rdp-password.
#
# ⚠ TWO KEYS, ONE HOST, NOT INTERCHANGEABLE:
#   license-flexnet  the FULL ';'-separated FlexNet list -> XILINXD_LICENSE_FILE,
#                    LM_LICENSE_FILE, MODULE_LICENSE_SERVER (Vivado / Vitis)
#   license-server   a SINGLE port@host                  -> SALT_LICENSE_SERVER (HyperLynx)
#
# Vivado needs EVERY port the site serves (the lab runs five) and FlexNet takes them as one
# ';'-separated list. Siemens/SALT does NOT use that syntax, so handing it the list risks
# `module load hyperlynx/2604` regressing to the SIGABRT (rc=134) "no licence" failure
# desktop-gvisor.yaml documents. Same box, different syntax — do not merge the keys.
#
# ⚠ ONE VALUE, SEALED INTO EVERY CONSUMER NAMESPACE. A k8s Secret is namespaced and nothing
# in this cluster replicates one across namespaces (reloader restarts pods on change;
# sealed-secrets-guard unsticks the controller — neither copies). So the same in-memory
# value is sealed once per namespace, exactly as image-registry/sealSecrets.sh does it:
# "sealed HERE so one password cannot drift into three".
#
#   remote-desktop/eda-secrets          the desktop pod (users run synthesis by hand)
#   remote-desktop-bender/eda-secrets   the second desktop, same reason
#   gitlab-runner/eda-secrets           the [eda-run] build pods (CI runs it unattended)
#
# ⚠ NEITHER KEY IS A CREDENTIAL. A licence host:port grants nothing without an entitlement
# on the server; they are sealed only because that is how this repo carries site values that
# should not be in git. If you need them visible, move them to project_settings.ts — but
# then remember the anchor must be registered in KNOWN_KEYS or the rewrite silently no-ops.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../manageSealedSecrets.sh"

REGEN=""
for arg in "$@"; do case "$arg" in
  --regenerate) REGEN="--regenerate" ;;
  # Accepted and ignored: the sealed files here are committed by the caller, so there is
  # no git-commit block to skip. Parsed anyway so sealAllSecrets.sh can pass it uniformly.
  --skip-git-commit) : ;;
esac; done

echo "=== EDA licence servers ==="

# Recover from THIS app's own sealed files first, then from the old remote-desktop location
# so an existing cluster migrates without re-typing anything.
RD_SEALED="$SCRIPT_DIR/eda-secrets-remote-desktop-sealed.yaml"
LEGACY="$SCRIPT_DIR/../../remote-desktop/remote-desktop-secrets-sealed.yaml"

LICENSE_FLEXNET=$(try_recover "$RD_SEALED" license-flexnet)
[[ -z "$LICENSE_FLEXNET" ]] && LICENSE_FLEXNET=$(try_recover "$LEGACY" license-flexnet)
LICENSE_SERVER=$(try_recover "$RD_SEALED" license-server)
[[ -z "$LICENSE_SERVER" ]] && LICENSE_SERVER=$(try_recover "$LEGACY" license-server)

if [[ -z "$LICENSE_SERVER" || "$REGEN" == "--regenerate" ]]; then
  read -rp "  SALT licence server for HyperLynx (single port@host): " LICENSE_SERVER
fi
[[ -n "$LICENSE_SERVER" ]] || { echo "ERROR: SALT licence server empty" >&2; exit 1; }

if [[ -z "$LICENSE_FLEXNET" || "$REGEN" == "--regenerate" ]]; then
  echo "  FlexNet list for Vivado — EVERY port the site serves, ';'-separated."
  echo "  e.g. 27000@host;27100@host;27200@host;27300@host;27400@host"
  read -rp "  FlexNet licence list [default: ${LICENSE_SERVER}]: " LICENSE_FLEXNET
  [[ -z "$LICENSE_FLEXNET" ]] && LICENSE_FLEXNET="$LICENSE_SERVER"
fi

# ⚠ A single port in the FlexNet list is almost certainly a mistake — that was the bug this
# split exists to fix (one key held 27000 only, so Vivado saw one port everywhere). Warn
# rather than fail: a site that genuinely runs one port is legitimate.
case "$LICENSE_FLEXNET" in
  *";"*) : ;;
  *) echo "  NOTE: the FlexNet list has a single entry. Vivado needs every port the site"
     echo "        serves; check with the licence admin if synthesis fails to check out." ;;
esac

SEALED_FILES=()
for ns_file in "remote-desktop:eda-secrets-remote-desktop-sealed.yaml" \
               "remote-desktop-bender:eda-secrets-remote-desktop-bender-sealed.yaml" \
               "gitlab-runner:eda-secrets-gitlab-runner-sealed.yaml"; do
  ns="${ns_file%%:*}"; out="${ns_file##*:}"
  seal_secret "$ns" eda-secrets "$out" \
    --from-literal=license-flexnet="$LICENSE_FLEXNET" \
    --from-literal=license-server="$LICENSE_SERVER"
  SEALED_FILES+=("$SCRIPT_DIR/$out")
done

echo
echo "Sealed eda-secrets into: remote-desktop, remote-desktop-bender, gitlab-runner"
echo "  license-flexnet -> XILINXD_LICENSE_FILE / LM_LICENSE_FILE / MODULE_LICENSE_SERVER"
echo "  license-server  -> SALT_LICENSE_SERVER (HyperLynx)"
