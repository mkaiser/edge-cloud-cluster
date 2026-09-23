#!/bin/bash
# Assert every manifest in deployment/argocd-infra/truenas/ is named in the app's
# directory.include allow-list.
#
# WHY THIS EXISTS: the list is an ALLOW-LIST, so a new manifest here is silently ignored
# until someone remembers to add it — and nothing reports that. The app stays Synced and
# Healthy while the file does nothing at all.
#
# It has already cost an outage. s3-app-job.yaml shipped 2026-09-02 without being added, so
# on the ecc193 recreate the S3 converge never ran; GitLab references the certificate that
# job publishes via global.certificates.customCAs, so EVERY GitLab pod sat in Init for three
# hours unable to mount `custom-ca-certificates`. Both apps read Healthy throughout.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP="$REPO_DIR/deployment/argocd-infra/app-of-apps/wave16-truenas.yaml"
DIR="$REPO_DIR/deployment/argocd-infra/truenas"

INC=$(grep -m1 -o 'include: "{[^}]*}"' "$APP" | sed 's/include: "{//; s/}"//')
[ -n "$INC" ] || { echo "ERROR: could not read directory.include from $APP" >&2; exit 1; }

fail=0
for f in "$DIR"/*.yaml; do
    b=$(basename "$f")
    case ",$INC," in
        *",$b,"*) ;;
        *) echo "ERROR: $b is not in wave16-truenas.yaml directory.include" >&2; fail=1 ;;
    esac
done
# And the converse: a name in the list with no file is a typo that silently applies nothing.
IFS=','; for b in $INC; do
    [ -f "$DIR/$b" ] || { echo "ERROR: include names '$b' but no such file exists" >&2; fail=1; }
done; unset IFS

[ "$fail" -eq 0 ] || { echo "ArgoCD would ignore the file(s) above while reporting Synced." >&2; exit 1; }
echo "OK: truenas manifests and directory.include agree"
