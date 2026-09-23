#!/usr/bin/env bash
# Seal a Kubernetes secret for use with the sealed-secrets controller.
#
# Usage (direct):
#   ./manageSealedSecrets.sh <namespace> <secret-name> <output-yaml> [--from-literal=key=value ...]
#
# Usage (sourced — provides ask_and_commit_sealed_files):
#   source ./manageSealedSecrets.sh
#   ask_and_commit_sealed_files "Seal foo secrets" /abs/path/file1.yaml /abs/path/file2.yaml
#
# Examples:
#   ./manageSealedSecrets.sh wireguard wireguard-ui-secret wireguard-ui/ui-secret-sealed.yaml \
#       --from-literal=ui-password=mypassword
#
#   ./manageSealedSecrets.sh myapp myapp-credentials myapp/credentials-sealed.yaml \
#       --from-literal=db-user=admin --from-literal=db-pass=secret123
#
# If no --from-literal args are given, the script prompts interactively for key=value pairs.
set -euo pipefail

# kubeseal is required for both sealing and recovery. Without it, recovery
# (try_recover) silently returns empty — callers then re-prompt for values that
# already exist and the final seal step fails. Abort early with a clear message.
if ! command -v kubeseal >/dev/null 2>&1; then
  echo "ERROR: 'kubeseal' not found in PATH — required to seal and recover secrets." >&2
  echo "  Install it from https://github.com/bitnami-labs/sealed-secrets/releases" >&2
  echo "  (e.g. download kubeseal-<ver>-linux-amd64.tar.gz, extract, move to /usr/local/bin)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate the Pulumi project root (the directory holding Pulumi.yaml) by walking
# UP from SCRIPT_DIR.
#
# ⚠ Do NOT replace this with a fixed "${SCRIPT_DIR}/../.." — that resolves
# correctly only for an app sitting exactly two levels below the repo root
# (deployment/argocd-apps/<app>/). An app nested one level deeper, e.g.
# deployment/argocd-apps/cape-demo/<app>/, would land inside deployment/ instead,
# where `pulumi config get` finds no project and the seal aborts with the
# misleading "sealedSecretsTlsKey unreadable — Pulumi stack not loaded?".
# ---------------------------------------------------------------------------
pulumi_root() {
  local d="$SCRIPT_DIR"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/Pulumi.yaml" ]] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  echo "ERROR: no Pulumi.yaml found above $SCRIPT_DIR" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Shared function: store a secret in the Pulumi stack if not already present.
# Idempotent — existing values are kept; never rotates a live credential.
#
# Usage: ensure_secret <pulumi-key> <generated-value>
# SCRIPT_DIR must be set by the caller (used to locate the Pulumi project root).
# ---------------------------------------------------------------------------
ensure_secret() {
  local key="$1" gen="$2"
  if (cd "$SCRIPT_DIR" && pulumi config get "$key" &>/dev/null); then
    echo "  $key — already set, keeping."
  else
    (cd "$SCRIPT_DIR" && pulumi config set --secret "$key" "$gen")
    echo "  $key — generated."
  fi
}

# ---------------------------------------------------------------------------
# Recover a key from an existing sealed file, or generate a fresh random value.
# Idempotent — preserves existing secrets across runs.
#
# Usage: recover_or_generate <sealed-file> <key-name> [--regenerate]
# SCRIPT_DIR must be set by the caller.
# ---------------------------------------------------------------------------
recover_or_generate() {
  local sealed_file="$1" key="$2" regenerate="${3:-}" length="${4:-24}"
  if [[ "$regenerate" != "--regenerate" ]] && [[ -f "$sealed_file" ]]; then
    local privkey
    if ! privkey=$(cd "$SCRIPT_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || [[ -z "$privkey" ]]; then
      echo "ERROR: sealedSecretsTlsKey unreadable — Pulumi stack not loaded?" >&2
      echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
      exit 1
    fi
    # Unseal the whole bundle first so we can tell "wrong key" (no entry
    # decrypts) apart from "this key simply isn't in the bundle yet".
    local json
    if ! json=$(kubeseal --recovery-unseal \
        --recovery-private-key <(echo "$privkey") \
        < "$sealed_file" -o json 2>/dev/null); then
      echo "ERROR: '$sealed_file' exists but cannot be decrypted with the current" >&2
      echo "  sealedSecretsTlsKey — it was sealed with a different key." >&2
      echo "  Refusing to silently regenerate (that would rotate every secret in this bundle)." >&2
      echo "  If this is intentional (e.g. a fresh cluster after destroy), re-run with --regenerate." >&2
      exit 1
    fi
    local val
    val=$(echo "$json" | jq -r --arg k "$key" '.data[$k] // empty' | base64 -d 2>/dev/null)
    if [[ -n "$val" ]]; then
      echo "  $key — recovered from sealed file." >&2
      echo "$val"; return
    fi
    echo "  $key — not present in sealed file, generating new value." >&2
  fi
  openssl rand -hex "$length"
}

# ---------------------------------------------------------------------------
# Recover a key from an existing sealed file; fail if not found.
# Use for secrets that must match a value set elsewhere (e.g. OIDC secrets
# generated by authentik/sealSecrets.sh).
#
# Usage: recover_from_sealed <sealed-file> <key-name>
# SCRIPT_DIR must be set by the caller.
# ---------------------------------------------------------------------------
recover_from_sealed() {
  local sealed_file="$1" key="$2"
  if [[ ! -f "$sealed_file" ]]; then
    echo "ERROR: $sealed_file not found. Run deployment/argocd-infra/authentik/sealSecrets.sh first." >&2
    exit 1
  fi
  local privkey
  if ! privkey=$(cd "$SCRIPT_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || [[ -z "$privkey" ]]; then
    echo "ERROR: sealedSecretsTlsKey unreadable — Pulumi stack not loaded?" >&2
    echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
    exit 1
  fi
  local val
  val=$(kubeseal --recovery-unseal \
      --recovery-private-key <(echo "$privkey") \
      < "$sealed_file" -o json 2>/dev/null \
    | jq -r --arg k "$key" '.data[$k] // empty' \
    | base64 -d 2>/dev/null)
  if [[ -z "$val" ]]; then
    echo "ERROR: key '$key' not found in $sealed_file. Run deployment/argocd-infra/authentik/sealSecrets.sh first." >&2
    exit 1
  fi
  echo "$val"
}

# ---------------------------------------------------------------------------
# Shared function: seal a Kubernetes secret using the cert from Pulumi config.
# Does NOT require a live cluster — works fully offline before cluster creation.
#
# Usage: seal_secret <namespace> <secret_name> <output_file> [--sealed-annotation=k=v ...] [--template-annotation=k=v ...] [--template-label=k=v ...] [--from-literal=k=v ...]
#   output_file is relative to the caller's SCRIPT_DIR (must be set by caller).
#   --sealed-annotation=k=v     adds annotation k=v to the SealedSecret's OWN
#                               metadata. Use this for argocd.argoproj.io/sync-wave
#                               — ArgoCD orders the SealedSecret resource it applies
#                               by the wave on that resource, NOT on the generated
#                               Secret (a template-scoped wave is silently ignored
#                               for ordering and deadlocks consuming hooks).
#   --template-annotation=k=v  adds annotation k=v to the SealedSecret template
#                               metadata, i.e. to the generated/unsealed Secret.
#   --template-label=k=v        adds label k=v to the SealedSecret template metadata,
#                               i.e. to the unsealed Secret (e.g. argocd part-of label,
#                               required for ArgoCD to read secrets into $secret refs).
#                               May be repeated; must come before --from-literal args.
# ---------------------------------------------------------------------------

# Inject template_annotations[] / template_labels[] (dynamically scoped from the
# calling seal_secret) into the template.metadata of a SealedSecret YAML file.
# Idempotent: only adds keys not already present.
inject_template_metadata() {
  local file="$1"
  local ann_yaml="" lbl_yaml=""
  local kv k v
  for kv in "${template_annotations[@]:-}"; do
    [[ -z "$kv" ]] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    ann_yaml+="        ${k}: \"${v}\""$'\n'
  done
  for kv in "${template_labels[@]:-}"; do
    [[ -z "$kv" ]] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    lbl_yaml+="        ${k}: \"${v}\""$'\n'
  done
  [[ -z "$ann_yaml" && -z "$lbl_yaml" ]] && return 0
  python3 - "$file" "$ann_yaml" "$lbl_yaml" <<'PYEOF'
import sys, re

path, ann_yaml, lbl_yaml = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()

def inject(content, block_yaml, block_name):
    if not block_yaml:
        return content
    marker = f'      {block_name}:\n'
    if marker in content:
        # Block exists — append only keys not already present.
        existing = content.split(marker, 1)[1]
        to_add = ''.join(
            line + '\n' for line in block_yaml.rstrip('\n').split('\n')
            if line.split(':')[0].strip() not in
               [l.split(':')[0].strip() for l in existing.split('\n') if l.startswith('        ')]
        )
        return content.replace(marker, marker + to_add, 1)
    # No block — insert after "    metadata:"
    return re.sub(r'(    metadata:\n)', r'\1' + marker + block_yaml, content, count=1)

content = inject(content, lbl_yaml, 'labels')
content = inject(content, ann_yaml, 'annotations')

with open(path, 'w') as f:
    f.write(content)
PYEOF
}

# Inject sealed_annotations[] into the SealedSecret's own (top-level, 0-indent)
# metadata.annotations. ArgoCD reads sync-wave off the SealedSecret resource it
# applies, so wave annotations must live here — NOT on spec.template.metadata.
# Idempotent: only adds keys not already present.
inject_sealed_metadata() {
  local file="$1"
  local ann_yaml="" kv k v
  for kv in "${sealed_annotations[@]:-}"; do
    [[ -z "$kv" ]] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    ann_yaml+="    ${k}: \"${v}\""$'\n'
  done
  [[ -z "$ann_yaml" ]] && return 0
  python3 - "$file" "$ann_yaml" <<'PYEOF'
import sys, re

path, ann_yaml = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()

# Top-level metadata block: "metadata:" at column 0, its keys at 2-space indent.
marker = '\nmetadata:\n'
if marker in content:
    head, rest = content.split(marker, 1)
    # Existing 2-space-indent lines of this metadata block (up to next 0-indent key).
    existing_keys = []
    for line in rest.split('\n'):
        if line and not line.startswith(' '):
            break
        if line.startswith('  ') and not line.startswith('    '):
            existing_keys.append(line.split(':')[0].strip())
    if 'annotations' in existing_keys:
        amarker = '\n  annotations:\n'
        if amarker in content:
            ahead, arest = content.split(amarker, 1)
            present = [l.split(':')[0].strip() for l in arest.split('\n') if l.startswith('    ')]
            to_add = ''.join(l + '\n' for l in ann_yaml.rstrip('\n').split('\n')
                              if l.split(':')[0].strip() not in present)
            content = ahead + amarker + to_add + arest
    else:
        content = head + marker + '  annotations:\n' + ann_yaml + rest

with open(path, 'w') as f:
    f.write(content)
PYEOF
}

seal_secret() {
  local namespace=$1
  local secret_name=$2
  local output_file=$3
  shift 3

  # Separate metadata args from --from-literal args.
  # --template-annotation / --template-label  -> spec.template.metadata (generated Secret)
  # --sealed-annotation                       -> SealedSecret's own metadata (e.g. sync-wave,
  #                                              which ArgoCD reads off the SealedSecret resource)
  local template_annotations=()
  local template_labels=()
  local sealed_annotations=()
  local literal_args=()
  for arg in "$@"; do
    if [[ "$arg" == --template-annotation=* ]]; then
      template_annotations+=("${arg#--template-annotation=}")
    elif [[ "$arg" == --template-label=* ]]; then
      template_labels+=("${arg#--template-label=}")
    elif [[ "$arg" == --sealed-annotation=* ]]; then
      sealed_annotations+=("${arg#--sealed-annotation=}")
    else
      literal_args+=("$arg")
    fi
  done

  local repo_dir abs_out
  repo_dir="$(pulumi_root)"
  abs_out="${SCRIPT_DIR}/${output_file}"

  local privkey
  if ! privkey=$(cd "$repo_dir" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || [[ -z "$privkey" ]]; then
    echo "ERROR: sealedSecretsTlsKey unreadable — Pulumi stack not loaded?" >&2
    echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
    exit 1
  fi

  # Offline idempotency: compare intended values with the decrypted sealed file.
  # Skip resealing if they already match — no live cluster needed.
  local intended
  intended=$(kubectl create secret generic "$secret_name" --namespace "$namespace" "${literal_args[@]}" \
    --dry-run=client -o go-template='{{range $k,$v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null | sort)

  if [[ -f "$abs_out" ]]; then
    local sealed_current
    sealed_current=$(kubeseal --recovery-unseal \
        --recovery-private-key <(echo "$privkey") \
        < "$abs_out" -o json 2>/dev/null \
      | jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | sort) || true
    if [[ -n "$sealed_current" ]] && [[ "$intended" = "$sealed_current" ]]; then
      # Data unchanged, but template labels/annotations are plaintext metadata —
      # re-apply them in place (idempotent) so newly-added ones land without reseal.
      inject_template_metadata "$abs_out"
      inject_sealed_metadata "$abs_out"
      echo "Unchanged: ${namespace}/${secret_name}"
      return 0
    fi
  fi

  local cert
  if ! cert=$(cd "$repo_dir" && pulumi config get sealedSecretsTlsCrt 2>/dev/null) || [[ -z "$cert" ]]; then
    echo "ERROR: sealedSecretsTlsCrt unreadable — Pulumi stack not loaded?" >&2
    echo "  Run: source ./scripts/pulumi/initPulumiStack.sh" >&2
    exit 1
  fi

  local tmp_out
  tmp_out=$(mktemp)
  if ! kubectl create secret generic "$secret_name" --namespace "$namespace" "${literal_args[@]}" \
      --dry-run=client -o yaml \
    | kubeseal \
        --controller-name=sealed-secrets-controller \
        --controller-namespace=kube-system \
        --cert <(echo "$cert") \
        --format yaml > "$tmp_out"; then
    echo "ERROR: kubeseal failed for $secret_name" >&2
    rm -f "$tmp_out"
    exit 1
  fi

  # Inject template annotations/labels if requested (hooks, argocd part-of label).
  inject_template_metadata "$tmp_out"
  # Inject SealedSecret-level annotations if requested (e.g. sync-wave).
  inject_sealed_metadata "$tmp_out"

  mv "$tmp_out" "$abs_out"
  echo "Written: ${output_file}"
}

# ---------------------------------------------------------------------------
# Interactive prompt: keep existing [k] / replace [r] / generate [g].
# Sets global KEG_CHOICE = "keep" | "replace" | "generate".
#
# Usage: prompt_keg <label> <has_existing> [allow_generate=true]
#   has_existing: "true" if a current sealed value was found, else "false"
#   allow_generate: "true" to offer the [g] option (default), "false" to omit it
# ---------------------------------------------------------------------------
prompt_keg() {
  local label="$1" has_existing="$2" allow_generate="${3:-true}"
  KEG_CHOICE=""
  while true; do
    local choice
    if [[ "$has_existing" == "true" ]]; then
      if [[ "$allow_generate" == "true" ]]; then
        read -rp "  $label — keep [k] / replace [r] / generate [g]: " choice
        [[ "$choice" =~ ^[KkRrGg]$ ]] && break
      else
        read -rp "  $label — keep [k] / replace [r]: " choice
        [[ "$choice" =~ ^[KkRr]$ ]] && break
      fi
    else
      if [[ "$allow_generate" == "true" ]]; then
        read -rp "  $label — enter [e] / generate [g]: " choice
        [[ "$choice" =~ ^[EeGg]$ ]] && break
      else
        read -rp "  $label — enter [e]: " choice
        [[ "$choice" =~ ^[Ee]$ ]] && break
      fi
    fi
  done
  case "$choice" in
    [Kk]) KEG_CHOICE="keep" ;;
    [Rr]) KEG_CHOICE="replace" ;;
    [Ee]) KEG_CHOICE="enter" ;;
    [Gg]) KEG_CHOICE="generate" ;;
  esac
}

# ---------------------------------------------------------------------------
# User-facing admin password: recover existing, else let the user choose to
# enter [e] a custom password or generate [g] a random one. On re-runs offers
# keep [k] / enter [e] / generate [g]. Use for human-login passwords (admin,
# superadmin, bootstrap) — NOT for internal DB/OIDC/token secrets (those stay
# on recover_or_generate).
#
# Prints the chosen password on stdout (status messages go to stderr).
#
# Usage: pass=$(recover_keg_or_enter <label> <sealed-file> <key-name> [--regenerate] [length])
# SCRIPT_DIR must be set by the caller.
# ---------------------------------------------------------------------------
recover_keg_or_enter() {
  local label="$1" sealed_file="$2" key="$3" regenerate="${4:-}" length="${5:-24}"
  local existing=""
  if [[ "$regenerate" != "--regenerate" ]] && [[ -f "$sealed_file" ]]; then
    existing=$(try_recover "$sealed_file" "$key")
  fi

  local result="" need_enter="false"
  if [[ -n "$existing" ]]; then
    prompt_keg "$label" "true" "true" >&2
    case "$KEG_CHOICE" in
      keep)     echo "  $label — kept." >&2; result="$existing" ;;
      generate) result=$(openssl rand -hex "$length"); echo "  $label — generated." >&2 ;;
      enter)    need_enter="true" ;;
    esac
  else
    prompt_keg "$label" "false" "true" >&2
    if [[ "$KEG_CHOICE" == "generate" ]]; then
      result=$(openssl rand -hex "$length"); echo "  $label — generated." >&2
    else
      need_enter="true"
    fi
  fi

  if [[ "$need_enter" == "true" ]]; then
    while true; do
      read -rsp "  $label — enter password: " result >&2; echo >&2
      local confirm
      read -rsp "  confirm password: " confirm >&2; echo >&2
      [[ "$result" == "$confirm" ]] && [[ -n "$result" ]] && break
      echo "  Passwords do not match or empty — try again." >&2
    done
  fi
  echo "$result"
}

# ---------------------------------------------------------------------------
# Try to recover a key from a sealed file; returns empty string on any failure.
# Never exits. Safe to use with [[ -n ... ]] checks.
#
# Usage: val=$(try_recover <sealed-file> <key-name>)
# ---------------------------------------------------------------------------
try_recover() {
  local sealed_file="$1" key="$2"
  [[ -f "$sealed_file" ]] || { echo ""; return; }
  local privkey
  privkey=$(cd "$SCRIPT_DIR" && pulumi config get sealedSecretsTlsKey 2>/dev/null) || { echo ""; return; }
  [[ -n "$privkey" ]] || { echo ""; return; }
  kubeseal --recovery-unseal \
      --recovery-private-key <(echo "$privkey") \
      < "$sealed_file" -o json 2>/dev/null \
    | jq -r --arg k "$key" '.data[$k] // empty' \
    | base64 -d 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Shared function: git add / commit / push a list of sealed-secret files.
# Usage: ask_and_commit_sealed_files <commit_msg> <file1> [file2 ...]
# ---------------------------------------------------------------------------
ask_and_commit_sealed_files() {
    local commit_msg="$1"
    shift
    local files=("$@")

    if [ ${#files[@]} -eq 0 ]; then
        return 0
    fi

    # Only commit files that actually changed (seal_secret skips unchanged ones).
    # Skip paths that don't exist on disk — a caller passing a stale/wrong path
    # must never poison the commit (git add would abort the whole batch).
    local changed=()
    for f in "${files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "WARNING: skipping non-existent sealed file: $f" >&2
            continue
        fi
        if ! git diff --quiet -- "$f" 2>/dev/null || ! git ls-files --error-unmatch "$f" &>/dev/null; then
            changed+=("$f")
        fi
    done

    if [ ${#changed[@]} -eq 0 ]; then
        echo "No sealed files changed — nothing to commit."
        return 0
    fi

    # Defer mode: when an orchestrator (a sealAllSecrets.sh) sets
    # SEAL_DEFER_COMMIT=1 it also points SEAL_EMIT_FILE at a temp file. Append
    # this script's changed files there (NOT to stdout — stdout must stay clean
    # for interactive prompts) and skip the per-app commit; the orchestrator
    # commits the aggregated list once.
    if [[ "${SEAL_DEFER_COMMIT:-}" == "1" ]]; then
        [[ -n "${SEAL_EMIT_FILE:-}" ]] && printf '%s\n' "${changed[@]}" >> "$SEAL_EMIT_FILE"
        echo "Deferred ${#changed[@]} changed file(s) to combined commit."
        return 0
    fi

    echo ""
    echo "Files to commit:"
    for f in "${changed[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "Commit message: $commit_msg"
    read -rp "Push to git? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy] ]]; then
        git add "${changed[@]}" && \
        git commit -m "$commit_msg" && \
        git push
        echo "Sealed secret committed and pushed to git."
    fi
}

# ---------------------------------------------------------------------------
# Shared function: remove (git rm / rm) a list of committed *-sealed.yaml files.
# The mirror of seal_secret/ask_and_commit_sealed_files — used by every
# removeSealedSecret.sh and by removeAllSealedSecrets.sh (Part C).
#
# Usage: remove_sealed <commit_msg> <file1> [file2 ...]
# Honors two flags via the caller's environment:
#   REMOVE_YES=1             skip the interactive confirmation (destructive)
#   REMOVE_SKIP_GIT_COMMIT=1 delete the files but do not git-commit the removal
# Files not present (already removed) are skipped silently.
# ---------------------------------------------------------------------------
remove_sealed() {
    local commit_msg="$1"
    shift
    local files=("$@")

    # Keep only files that currently exist on disk.
    local present=()
    for f in "${files[@]}"; do [[ -e "$f" ]] && present+=("$f"); done
    if [ ${#present[@]} -eq 0 ]; then
        echo "No sealed files to remove — nothing to do."
        return 0
    fi

    echo ""
    echo "Sealed files to REMOVE:"
    for f in "${present[@]}"; do echo "  - $f"; done
    echo ""

    if [[ "${REMOVE_YES:-}" != "1" ]]; then
        read -rp "Permanently remove these sealed files? [y/N]: " choice
        [[ "$choice" =~ ^[Yy] ]] || { echo "Aborted."; return 0; }
    fi

    # Prefer git rm for tracked files so the removal is staged; fall back to rm.
    local removed=()
    for f in "${present[@]}"; do
        if git ls-files --error-unmatch "$f" &>/dev/null; then
            git rm -q -- "$f" && removed+=("$f")
        else
            rm -f -- "$f" && removed+=("$f")
        fi
    done

    if [[ "${REMOVE_SKIP_GIT_COMMIT:-}" != "1" ]] && [ ${#removed[@]} -gt 0 ]; then
        # Commit only if there is something staged (git rm staged the deletions).
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "$commit_msg" && echo "Removed sealed files committed."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Shared function: idempotently de-provision an app's Authentik OIDC objects
# (application + OAuth2 provider) via the scoped provisioner token. Used by the
# OIDC apps' removeSealedSecret.sh so the provider/tile is cleaned even if the
# ArgoCD PreDelete hook never ran (orphan class 2). Best-effort: needs cluster
# access + the provisioner token; skips quietly otherwise.
#
# Usage: authentik_deprovision <app-slug> [<provider-name>]
#   provider-name defaults to <app-slug>.
# Requires REPO_DIR to be set by the caller (repo root).
# ---------------------------------------------------------------------------
authentik_deprovision() {
  local slug="$1" provider="${2:-$1}" pf api auth token pk
  token=$(try_recover "$REPO_DIR/argocd-infra/authentik/authentik-secrets-sealed.yaml" AUTHENTIK_PROVISIONER_TOKEN)
  if [[ -z "$token" ]]; then
    echo "Provisioner token unavailable — skipping Authentik API cleanup for '$slug'."
    return 0
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Cluster unreachable — skipping Authentik API cleanup for '$slug'."
    return 0
  fi
  echo "Port-forwarding Authentik to delete provider/application '$slug'..."
  kubectl port-forward -n authentik svc/authentik-server 19009:80 >/tmp/ak-deprovision-pf.log 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' RETURN
  api="http://127.0.0.1:19009/api/v3"; auth="Authorization: Bearer ${token}"
  for _ in $(seq 1 15); do
    curl -fsS -H "$auth" "$api/core/applications/?slug=${slug}" >/dev/null 2>&1 && break
    sleep 1
  done
  echo "Deleting application '$slug'..."
  curl -fsS -X DELETE -H "$auth" "$api/core/applications/${slug}/" >/dev/null 2>&1 || true
  pk=$(curl -fsS -H "$auth" "$api/providers/oauth2/?name=${provider}" 2>/dev/null \
    | python3 -c "import json,sys; r=json.load(sys.stdin).get('results',[]); print(r[0]['pk'] if r else '')" 2>/dev/null || true)
  if [[ -n "$pk" ]]; then
    echo "Deleting OAuth2 provider '$provider' (pk=$pk)..."
    curl -fsS -X DELETE -H "$auth" "$api/providers/oauth2/${pk}/" >/dev/null 2>&1 || true
  fi
  echo "Authentik cleanup for '$slug' done."
}

# Only execute sealing logic when run directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NS="kube-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <namespace> <secret-name> <output-yaml> [--from-literal=key=value ...]"
    echo ""
    echo "Examples:"
    echo "  $0 wireguard wireguard-ui-secret wireguard-ui/ui-secret-sealed.yaml --from-literal=ui-password=mypass"
    echo "  $0 myapp db-creds myapp/db-sealed.yaml  (interactive mode)"
    exit 1
fi

NS="$1"
SECRET_NAME="$2"
OUTPUT_FILE="$3"
shift 3

# Resolve output path relative to script directory
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="$SCRIPT_DIR/$OUTPUT_FILE"
fi

# Verify Pulumi cert is available
if ! (cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt &>/dev/null); then
    echo "ERROR: Could not extract sealedSecretsTlsCrt from Pulumi config."
    echo "Run setAllSecrets.sh to configure the sealed-secrets keypair first."
    exit 1
fi

# Collect --from-literal args
LITERAL_ARGS=("$@")

# Interactive mode if no --from-literal args provided
if [ ${#LITERAL_ARGS[@]} -eq 0 ]; then
    echo ""
    echo "No --from-literal args provided. Enter key=value pairs interactively."
    echo ""
    while true; do
        read -rp "  Key name (or Ctrl+D to finish): " key_name || break
        [ -z "$key_name" ] && continue
        read -rsp "  Value for '$key_name': " key_value
        echo ""
        LITERAL_ARGS+=("--from-literal=${key_name}=${key_value}")
    done
    echo ""

    if [ ${#LITERAL_ARGS[@]} -eq 0 ]; then
        echo "ERROR: No key=value pairs provided."
        exit 1
    fi
fi

# Seal the secret using the certificate from Pulumi (no file on disk)
mkdir -p "$(dirname "$OUTPUT_FILE")"
kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NS" \
    "${LITERAL_ARGS[@]}" \
    --dry-run=client -o yaml | \
    kubeseal \
        --controller-name="$CONTROLLER_NAME" \
        --controller-namespace="$CONTROLLER_NS" \
        --cert <(cd "$REPO_DIR" && pulumi config get sealedSecretsTlsCrt) \
        --format yaml > "$OUTPUT_FILE"

echo ""
echo "Secret $SECRET_NAME sealed to: $OUTPUT_FILE"

# Check if cluster is reachable and offer deployment options
echo ""
if kubectl cluster-info &>/dev/null; then
    read -rp "Cluster is online. Apply the sealed secret directly? [y/N]: " apply_choice
    if [[ "$apply_choice" =~ ^[Yy] ]]; then
        if ! kubectl get namespace "$NS" &>/dev/null; then
            echo "Namespace '$NS' does not exist. Creating it..."
            kubectl create namespace "$NS"
        fi
        kubectl apply -f "$OUTPUT_FILE"
    fi
fi

fi # end BASH_SOURCE guard
