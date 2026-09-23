#!/bin/bash
# Assert that editing a seal script's OUTPUT-AFFECTING code comes with regenerated
# *-sealed.yaml files in the same directory.
#
# WHY THIS EXISTS: it has cost two outages in one day, both on a cluster recreate, both
# invisible until then.
#
#   - image-registry/sealSecrets.sh was changed to mint eda-push and eda-pull, but the sealed
#     file was not regenerated. It still carried the single `eda` user and a `password` key,
#     so the recreate deployed an htpasswd with NEITHER account: every CI push and broker
#     pull 401s, and the module postsync jobs fail reading .data.push-password.
#   - gitlab/sealSecrets.sh was changed to point the container registry at its own bucket,
#     but the sealed file was not regenerated. The registry does not read values.yaml for
#     storage — it reads the sealed secret — so it kept asking for a bucket the same change
#     had removed from the creation list, and crash-looped on NoSuchBucket.
#
# Both are the same mistake: editing a generator without regenerating what it generates.
# Neither fails at edit time, at review time, or on the running cluster. They fail on the
# NEXT RECREATE, because the old secret keeps working until it is rebuilt from git.
#
# ⚠ COMMENT-ONLY EDITS ARE EXEMPT. Rewriting a header explains something; it changes no
# sealed byte, and failing on it would train people to bypass the check.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
[ -n "$STAGED" ] || { echo "OK: nothing staged"; exit 0; }

fail=0
while IFS= read -r script; do
    case "$script" in
        */sealSecrets.sh|*/sealToken.sh|*/sealRunnerToken.sh) ;;
        *) continue ;;
    esac
    [ -f "$script" ] || continue
    dir=$(dirname "$script")

    # Does the staged diff change anything that could alter the sealed OUTPUT?
    #
    # Two classes are exempt because neither can move a sealed byte:
    #   1. comment and blank lines (stripped below);
    #   2. REPO PATHS. A seal script names sibling files and sourced helpers by path, so a
    #      directory rename or a script relocation rewrites lines here while producing byte-
    #      identical output. Without this the check fires on every such move, and the only
    #      way past it is `git commit --no-verify`, which disables EVERY check — the one
    #      habit this file exists to avoid teaching.
    #
    # Mechanics: normalise path-looking tokens to <PATH>, drop the +/- marker, then
    # `sort | uniq -u`. A removed line and its added counterpart become identical and cancel;
    # anything genuinely different survives. Whitespace-only reindentation cancels too, which
    # is correct for the same reason.
    #
    # ⚠ The residual blind spot, stated rather than hidden: a change that swaps one path for
    # another where the path IS the content (`--from-file=./a` -> `--from-file=./b`) also
    # cancels. That is why the cancelled lines are PRINTED below instead of silently skipped —
    # a reviewer sees what the check chose to ignore.
    norm_diff=$(git diff --cached -U0 -- "$script" \
        | grep -E '^[+-]' \
        | grep -vE '^(\+\+\+|---)' \
        | sed 's/^[+-][[:space:]]*//' \
        | grep -vE '^(#|$)' \
        | sed -E 's#(\.\./)+[A-Za-z0-9_./-]+#<PATH>#g; s#\b(deployment|scripts|src|plans|doc)/[A-Za-z0-9_./-]+#<PATH>#g')
    substantive=$(printf '%s\n' "$norm_diff" | sed '/^$/d' | sort | uniq -u | head -1)
    if [ -z "$substantive" ]; then
        if [ -n "$(printf '%s' "$norm_diff" | tr -d '[:space:]')" ]; then
            echo "note: $script changed, but only in comments or repo paths — no sealed byte can move:" >&2
            git diff --cached -U0 -- "$script" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
                | grep -vE '^[+-][[:space:]]*(#|$)' | sed 's/^/        /' >&2
        fi
        continue
    fi

    # Was any sealed file in the same directory regenerated alongside it?
    if printf '%s\n' "$STAGED" | grep -qE "^${dir}/.*-sealed\.yaml$"; then
        continue
    fi

    echo "ERROR: $script changed, but no *-sealed.yaml in $dir was regenerated." >&2
    echo "       first non-comment change:" >&2
    echo "         $substantive" >&2
    fail=1
done <<< "$STAGED"

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

A seal script's output lives in its *-sealed.yaml files, and nothing regenerates them for
you. The running cluster keeps working from the OLD sealed values, so this only breaks on
the next recreate — which is the worst time to find out.

Re-run the script (Pulumi stack loaded), then stage what it rewrites:

    source ./scripts/pulumi/initPulumiStack.sh
    bash <that>/sealSecrets.sh

If the edit genuinely cannot change the sealed output and is not a comment, say so in the
commit message and stage the sealed file unchanged (`git add` is a no-op for it) — or split
the comment change into its own commit.
EOF
    exit 1
fi

echo "OK: seal scripts and their sealed output are in step"
