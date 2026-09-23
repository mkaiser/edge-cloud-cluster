#!/bin/bash
# Assert that every sealSecrets.sh on disk is actually invoked by its area's
# sealAllSecrets.sh, and that every app the area script names still exists.
#
# WHY A CHECK RATHER THAN DISCOVERY BY find: the area scripts drive the seal order, and the
# order is load-bearing — authentik first (it generates the OIDC bundle the others recover
# from), then vllm -> litellm -> open-webui/hermes (each recovers the previous one's key).
# A `find`-driven loop would run them in directory order and silently break that chain, so
# the explicit `run <app>` list stays and this script guards it instead.
#
# The failure it catches is silent in the worst way. An app missing from the list is not
# skipped visibly: sealAllSecrets.sh prints "All secrets sealed" and exits 0, the running
# cluster keeps working from sealed values already in git, and the gap only surfaces on the
# NEXT RECREATE as a pod stuck in Init:CreateContainerConfigError for a Secret nobody
# generated. That is exactly how hermes-secrets went missing for two days, and it is
# recorded in the area script's own comment next to `run hermes`.
#
# The reverse direction matters too: a `run <app>` naming a directory that no longer has a
# sealSecrets.sh aborts the whole area run with "No such file or directory", so the apps
# AFTER it in the list never seal at all.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

fail=0

for area in argocd-infra argocd-apps; do
    list="deployment/$area/sealAllSecrets.sh"
    [ -f "$list" ] || { echo "ERROR: $list is missing" >&2; fail=1; continue; }

    # App names as the area script invokes them: `run <app>` at the start of a line, where
    # <app> is the path under deployment/<area>/ (nested ones like eda/fileserver included).
    listed=$(grep -E '^run [^ ]+$' "$list" | awk '{print $2}' | sort)
    ondisk=$(find "deployment/$area" -name sealSecrets.sh \
        | sed "s|^deployment/$area/||;s|/sealSecrets.sh$||" | sort)

    while IFS= read -r app; do
        [ -n "$app" ] || continue
        printf '%s\n' "$listed" | grep -qxF "$app" || {
            echo "ERROR: $area/$app/sealSecrets.sh exists but $list never runs it" >&2
            fail=1
        }
    done <<<"$ondisk"

    while IFS= read -r app; do
        [ -n "$app" ] || continue
        [ -f "deployment/$area/$app/sealSecrets.sh" ] || {
            echo "ERROR: $list runs '$app', but deployment/$area/$app/sealSecrets.sh does not exist" >&2
            fail=1
        }
    done <<<"$listed"
done

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

Fix the area script, not this check:

  - app on disk but not run  -> add `run <app>` to deployment/<area>/sealAllSecrets.sh,
                                placed so any recover-from dependency seals first, with a
                                comment saying what it seals.
  - app run but file absent  -> drop that `run <app>` line (the app was removed or renamed).

Leaving it is not harmless: a missing app seals nothing while the run still reports success,
and the gap only shows up on the next cluster recreate.
EOF
    exit 1
fi

echo "OK: every sealSecrets.sh is invoked by its area's sealAllSecrets.sh"
