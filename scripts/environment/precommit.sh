#!/bin/bash
set -euo pipefail

STAGED_TS=$(git diff --cached --name-only --diff-filter=ACMR -- '*.ts')
if [ -z "$STAGED_TS" ]; then
    echo "No staged TypeScript files. Skipping TS pre-commit checks."
    exit 0
fi

echo "Running TS pre-commit checks for:"
echo "$STAGED_TS"
echo "$STAGED_TS" | xargs npx prettier --write
echo "$STAGED_TS" | xargs git add
npx tsc --noEmit 2>&1
