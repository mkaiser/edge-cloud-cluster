#!/bin/bash
# Seals the PostgreSQL credentials for the IPTO SCADA anomaly-detector demo.
#
# Idempotent: recovers the existing values from the sealed file on re-runs, so
# re-running this does NOT rotate a live credential.
#
# ⚠ NOTHING here is generated, unlike every other app's seal script. The demo's
# workflow modules carry the whole connection string compiled in — user, database
# AND password — so all three have to match what they expect. Each is recovered
# from the sealed file if present, else taken from its environment variable, else
# prompted for (with the documented value offered as the default).
#
# Coordinate any change with the workflow owners: changing a value here breaks the
# workflow silently. The modules fail at connect time, which surfaces as a failed
# Ryax execution, not as anything that names authentication or a missing database.
#
# ⚠ POSTGRES_USER and POSTGRES_DB are not merely credentials — they are what the
# postgres image's entrypoint CREATES on first start, and that happens exactly once
# on an empty data directory. Changing either after the database exists leaves the
# live cluster untouched and the workflow pointing at a role/database that was never
# created. See README.md ("Schema changes").
#
# Environment overrides (all optional; each falls back to a prompt):
#   CAPE_DEMO_PG_USER      default: postgres
#   CAPE_DEMO_PG_DB        default: parquet_data
#   CAPE_DEMO_PG_PASSWORD  no default — must come from the workflow owners
#
# Generates:
#   postgres-secret-sealed.yaml — POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../manageSealedSecrets.sh
source "$SCRIPT_DIR/../../../manageSealedSecrets.sh"

NAMESPACE="ryaxns-tools"
SEALED_FILE="$SCRIPT_DIR/postgres-secret-sealed.yaml"

REGEN=""; SKIP_GIT_COMMIT=""
for arg in "$@"; do case "$arg" in
  --regenerate)      REGEN="--regenerate" ;;
  --skip-git-commit) SKIP_GIT_COMMIT="--skip-git-commit" ;;
esac; done

# ---------------------------------------------------------------------------
# Resolve one value: sealed file -> environment variable -> prompt.
#
# Usage: val=$(resolve_value <secret-key> <env-var-name> <prompt-label> [default] [--secret])
#
# --secret reads without echo and asks for confirmation; used for the password.
# A non-empty [default] is offered on the prompt and accepted on an empty answer.
#
# ⚠ Every prompt and message goes to STDERR. This function's stdout IS the value —
# a stray echo on stdout ends up sealed into the secret, and the failure is silent
# (the workflow then authenticates with a password containing a prompt string).
# ---------------------------------------------------------------------------
resolve_value() {
  local key="$1" env_var="$2" label="$3" default="${4:-}" mode="${5:-}"
  local val=""

  # 1. Recover from the existing sealed file, unless rotating.
  if [[ -z "$REGEN" ]]; then
    val=$(try_recover "$SEALED_FILE" "$key" || true)
    if [[ -n "$val" ]]; then
      echo "  $key — recovered from sealed file." >&2
      echo "$val"; return 0
    fi
  fi

  # 2. Environment variable, for unattended runs.
  val="${!env_var:-}"
  if [[ -n "$val" ]]; then
    echo "  $key — taken from \$$env_var." >&2
    echo "$val"; return 0
  fi

  # 3. Prompt.
  if [[ "$mode" == "--secret" ]]; then
    local confirm
    while true; do
      read -rsp "  $label: " val >&2; echo >&2
      read -rsp "  confirm: " confirm >&2; echo >&2
      [[ -n "$val" && "$val" == "$confirm" ]] && break
      echo "  Empty or mismatched — try again." >&2
    done
  else
    if [[ -n "$default" ]]; then
      read -rp "  $label [$default]: " val >&2
      val="${val:-$default}"
    else
      while [[ -z "$val" ]]; do read -rp "  $label: " val >&2; done
    fi
  fi
  echo "$val"
}

echo "IPTO SCADA demo — PostgreSQL credentials" >&2
echo "  These must match the workflow modules' compiled-in connection string." >&2

DB_USER=$(resolve_value POSTGRES_USER     CAPE_DEMO_PG_USER     "database user"     "postgres")
DB_NAME=$(resolve_value POSTGRES_DB       CAPE_DEMO_PG_DB       "database name"     "parquet_data")
DB_PASSWORD=$(resolve_value POSTGRES_PASSWORD CAPE_DEMO_PG_PASSWORD "database password" "" --secret)

# Belt and braces: an empty value would seal a broken secret that only fails at
# connect time, inside a Ryax execution, where nobody is looking.
for pair in "POSTGRES_USER:$DB_USER" "POSTGRES_DB:$DB_NAME" "POSTGRES_PASSWORD:$DB_PASSWORD"; do
  [[ -n "${pair#*:}" ]] || { echo "ERROR: ${pair%%:*} is empty — refusing to seal." >&2; exit 1; }
done

seal_secret "$NAMESPACE" postgres-secret postgres-secret-sealed.yaml \
  --from-literal=POSTGRES_USER="$DB_USER" \
  --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=POSTGRES_DB="$DB_NAME"

# The sealed secret must exist before the Deployment's pod starts, and the
# namespace must exist before the sealed secret applies. namespace.yaml is a
# PreSync hook at wave -10; this one sits at -1.
add_sync_wave_presync() {
  local file="$1"
  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
if 'argocd.argoproj.io/sync-wave' in content:
    sys.exit(0)
anno = ('  annotations:\n'
        '    argocd.argoproj.io/hook: PreSync\n'
        '    argocd.argoproj.io/sync-wave: \"-1\"\n')
# Anchor to the TOP-LEVEL metadata.namespace only (exactly 2-space indent at line
# start) — without ^ + MULTILINE this also matches the nested spec.template one and
# inserts a structurally invalid block that never applies.
content = re.sub(r'(^  namespace: [^\n]+\n)', lambda m: m.group(0) + anno,
                 content, count=1, flags=re.MULTILINE)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$file"
}
add_sync_wave_presync "$SEALED_FILE"

# `if` rather than `[[ ... ]] &&`: under `set -e` a false test as the LAST command
# makes the script exit 1, so --skip-git-commit looks like a failure to the caller.
if [[ -z "$SKIP_GIT_COMMIT" ]]; then
  ask_and_commit_sealed_files "Seal IPTO SCADA demo PostgreSQL credentials" \
    "$SEALED_FILE"
fi
