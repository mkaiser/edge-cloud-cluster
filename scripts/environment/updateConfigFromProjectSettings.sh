#!/bin/bash
# Project: edgecloudinfra
# File: scripts/environment/updateConfigFromProjectSettings.sh
# Purpose: Push project_settings.ts into the YAML/shell that cannot import it.
#
# Author: Martin Kaiser
# Copyright (c) 2026 Martin Kaiser
# License: MIT
# SPDX-License-Identifier: MIT
#
# Two steps:
#   applyProjectSettings.py   THE anchor engine. Evaluates project_settings.ts (via node, so
#                             getters resolve; no Pulumi stack, passphrase or network), then
#                             makes ONE pass over the corpus, writing only the files whose
#                             text actually changed.
#   checkDomainAnchors.py     every cluster hostname must carry an anchor — it is the only
#                             signal that says a hostname belongs to the cluster, and without
#                             it the hostname collapses to the bare apex in bare-domain mode
#                             and can never be rewritten back
#
# This path is what every doc, README section and CLAUDE.md instruction names, so it stays.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --old-domain: the base domain the FILES currently carry, when general.domain itself has just
# changed. Every rewrite keys on the NEW domain, so without it a domain change is a silent
# no-op — the manifests keep the old domain while Pulumi moves to the new one. Absent, it is
# auto-detected from the general.tld anchor, so a plain hand edit of general.domain also works;
# the flag exists for callers that already know the previous value (prepareRelease.sh).
apply_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --old-domain)
            [ -n "${2:-}" ] || { echo "--old-domain needs a value" >&2; exit 1; }
            apply_args+=(--old-domain "$2"); shift 2 ;;
        --old-domain=*)
            apply_args+=(--old-domain "${1#*=}"); shift ;;
        --check)
            # Write nothing; exit non-zero if any managed value has drifted. Wired into
            # precommit.sh — the direct test for "a manifest drifted from project_settings.ts".
            apply_args+=(--check); shift ;;
        *)
            echo "Usage: $0 [--old-domain <previous general.domain>] [--check]"
            echo "Rewrites every machine-managed literal in deployment manifests from project_settings.ts."
            exit 1 ;;
    esac
done

# PHASE_VERBOSE=1 prints every resolved value. They are all derivable from project_settings.ts
# and none is a decision the reader makes, so they are DETAIL, not output.
[ "${PHASE_VERBOSE:-}" = "1" ] && apply_args+=(--verbose)

cd "$REPO_ROOT"

python3 "$SCRIPT_DIR/applyProjectSettings.py" "${apply_args[@]}"

python3 "$SCRIPT_DIR/checkDomainAnchors.py"

echo "ArgoCD/deployment manifest update completed from project_settings.ts."
