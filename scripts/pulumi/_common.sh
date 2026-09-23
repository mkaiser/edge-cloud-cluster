# _common.sh — shared helpers for the cluster-lifecycle scripts (bootstrap/restore/destroy/up).
#
# SOURCE this (don't execute it): several helpers `export` into the caller's shell
# (load_pulumi_passphrase) or set color vars (init_tty_colors). Running it as a subprocess
# would lose those. Every function here is:
#   - idempotent (safe to call twice), and
#   - free of `exit` (a lib that exits would kill any script/harness that sources it) —
#     helpers signal failure with a nonzero `return`; the CALLER decides whether to abort.
#
# This is the single source of truth for the passphrase/login/select handshake, the
# project_settings.ts field accessors (targetState, gated node fields), and the interactive
# + timing primitives the lifecycle scripts share. Same convention as _meshNodes.sh (leading
# underscore, sourced, function-per-concern).

# Guard against accidental direct execution (its whole job is to mutate the caller's shell).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: _common.sh must be sourced, not executed." >&2
    echo "Usage: source \"\$SCRIPT_DIR/_common.sh\"" >&2
    exit 1
fi

# ── Pulumi passphrase / login / stack select ───────────────────────────────────────────

# load_pulumi_passphrase — ensure PULUMI_CONFIG_PASSPHRASE is set+exported.
# No-op if already set. Else read /tmp/passphrase (LLM/non-interactive path, see
# setPulumiPassphrase.sh) or prompt. Never exits; on a non-tty run with no file the
# `read` simply returns empty and downstream pulumi commands fail with a clear error.
load_pulumi_passphrase() {
    if [ -n "${PULUMI_CONFIG_PASSPHRASE:-}" ]; then
        return 0
    fi
    if [ -f /tmp/passphrase ]; then
        PULUMI_CONFIG_PASSPHRASE="$(cat /tmp/passphrase)"
    else
        read -rsp "Enter Pulumi passphrase: " PULUMI_CONFIG_PASSPHRASE
        echo ""
    fi
    export PULUMI_CONFIG_PASSPHRASE
}

# pulumi_login_select — `pulumi login file://<state>` + `stack select mystack`, quietly.
# Reads REPO_ROOT from the caller (every lifecycle script sets it). Returns pulumi's exit
# code; does NOT exit, so callers that want fatal-on-fail keep their own `|| { ...; exit; }`.
pulumi_login_select() {
    pulumi login "file://${REPO_ROOT}/.pulumi-state" >/dev/null 2>&1 \
        && pulumi stack select mystack >/dev/null 2>&1
}

# init_pulumi — the common pair: load passphrase, then login+select.
init_pulumi() {
    load_pulumi_passphrase && pulumi_login_select
}

# ── project_settings.ts extractors ──────────────────────────────────────────────────────

# ps_settings_file [override] — resolve the project_settings.ts path. Order: explicit arg,
# then $PS_FILE, then $REPO_ROOT/project_settings.ts. Keeps callers free of dir-var drift.
ps_settings_file() {
    if [ -n "${1:-}" ]; then echo "$1"
    elif [ -n "${PS_FILE:-}" ]; then echo "$PS_FILE"
    else echo "${REPO_ROOT}/project_settings.ts"; fi
}

# ps_target_state [settings] — print general.targetState, or empty.
# One of bootstrap|restore|production|shutdown|destroy (see TargetState in
# project_settings_types.ts).
ps_target_state() {
    local f; f="$(ps_settings_file "${1:-}")"
    sed -nE 's/.*targetState:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n1
}

# ── ps_set_target_state <bootstrap|restore|production|shutdown|destroy> ────────────────
# Set general.targetState in project_settings.ts and resync the YAML manifests. Verifies the
# write. This is the ONE way the lifecycle state changes — it used to be three independent
# knobs — a posture enum plus two `pulumi config set` booleans — which could disagree.
#
# Lives here rather than in _lifecycle.sh because destroyCluster.sh and shutdownCluster.sh
# need it too, and they deliberately do not pull in the phase machinery.
ps_set_target_state() {
    local target="$1" f
    f="$(ps_settings_file)"
    case "$target" in
        bootstrap|restore|production|shutdown|destroy) ;;
        *)
            echo "ps_set_target_state: unknown state '$target'" >&2
            echo "  expected one of: bootstrap restore production shutdown destroy" >&2
            exit 1
            ;;
    esac
    local current; current="$(ps_target_state)"
    echo "targetState: ${current:-<unset>} → ${target}"

    perl -pi -e 's/(targetState:\s*")[^"]+(" as TargetState)/${1}'"$target"'${2}/' "$f"
    local now; now="$(ps_target_state)"
    if [[ "$now" != "$target" ]]; then
        echo "ERROR: failed to set targetState in project_settings.ts (now: '$now')" >&2
        exit 1
    fi
    bash "$REPO_ROOT/scripts/environment/updateConfigFromProjectSettings.sh"
}

# ps_node_field <gate_regex> <field> [settings] — print the first `<field>: "..."` that
# appears at or after the first line matching <gate_regex>, skipping //-commented lines.
# One-pass and stateful. head -n1 is applied
# HERE so every caller gets first-match semantics consistently (like _meshNodes.sh owning
# its slice). Examples:
#   ps_node_field 'provider:\s*"robot"'   privateIp   # robot box private IP (WG-only)
#   ps_node_field 'clusterLink:\s*"init"' publicIp    # init-CP box public IP
ps_node_field() {
    local gate="$1" field="$2" f
    f="$(ps_settings_file "${3:-}")"
    PS_GATE="$gate" PS_FIELD="$field" perl -ne '
        BEGIN { $gate = qr/$ENV{PS_GATE}/; $field = $ENV{PS_FIELD}; }
        next if m{^\s*//};                 # skip commented-out example nodes / prose
        $in = 1 if /$gate/;
        if ($in && /\Q$field\E:\s*"([^"]+)"/) { print "$1\n"; $in = 0; }
    ' "$f" 2>/dev/null | head -n1
}

# ── Interactive + timing primitives ─────────────────────────────────────────────────────

# timed_prompt <seconds> <prompt> <default_on_timeout> — print <prompt>, read one line with a
# <seconds> timeout; on timeout print a newline (so the log isn't left mid-line) and yield
# <default_on_timeout>; on input yield the entered text. Result goes to STDOUT — capture it
# `ans=$(timed_prompt ...)`. Ends with an explicit `return 0` so a timed-out `read`'s nonzero
# status never trips the caller's `set -e`.
timed_prompt() {
    local secs="$1" prompt="$2" default="$3" reply
    if read -t "$secs" -rp "$prompt" reply; then
        printf '%s' "$reply"
    else
        echo "" >&2            # newline after the timed-out prompt (to stderr, not the result)
        printf '%s' "$default"
    fi
    return 0
}

# step_time <label> <start_epoch> — print absolute time + elapsed m/s for a step.
step_time() {
    local d=$(( $(date +%s) - $2 ))
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') [$1] step took $((d/60))m $((d%60))s"
}

# ── Phase reporting ─────────────────────────────────────────────────────────────────────
# The lifecycle entrypoints announce their progress through these three helpers. They print
# `@@PHASE …` sentinel lines, which scripts/environment/phaseFilter.sh turns into the
# banners the terminal shows; the sentinels themselves are filtered out of that view. A run
# without the filter (a script invoked by hand) just shows the raw sentinel — ugly but
# never wrong, so no caller has to care whether it is running under `make`.
#
# ⚠ REGISTER THE PHASE LIST, do not hardcode "N/7". Which phases a run actually attempts
# depends on the branch taken: bootstrap.sh:60 has a much shorter existing-cluster path, and
# the hardening/mesh/commit offers each self-skip when the run is non-interactive or the
# prompt times out. A literal denominator drifts from reality the moment a phase is skipped
# — shutdownCluster.sh already carries that bug (it says "Step 5/7" in one place and
# "Step 6/6" in another).

# phase_register <label>... — declare the phases this run will attempt, in order.
phase_register() {
    PHASE_LIST=("$@")
    PHASE_INDEX=0
    local IFS='|'
    echo "@@PHASE REGISTER ${PHASE_LIST[*]}"
}

# phase_begin <label> — start the next phase. The label must match the registered one;
# the index is taken from the registration so the numbering cannot drift from the list.
phase_begin() {
    local label="$1" i
    PHASE_INDEX=$((${PHASE_INDEX:-0} + 1))
    # Prefer the registered position of this label — a phase skipped without a phase_end
    # would otherwise shift every later number by one.
    for i in "${!PHASE_LIST[@]}"; do
        [ "${PHASE_LIST[$i]}" = "$label" ] && { PHASE_INDEX=$((i + 1)); break; }
    done
    PHASE_LABEL="$label"
    PHASE_START=$(date +%s)
    echo "@@PHASE BEGIN ${PHASE_INDEX} ${label}"
}

# phase_end [ok|skip|fail] — close the running phase. Defaults to ok.
# A skipped phase KEEPS its number (see the warning above).
phase_end() {
    local status="${1:-ok}"
    local secs=$(( $(date +%s) - ${PHASE_START:-$(date +%s)} ))
    echo "@@PHASE END ${status} ${secs} ${PHASE_LABEL:-?}"
    PHASE_LABEL=""
}

# init_tty_colors — set YEL GRN LBLU RST (empty when stdout is not a terminal / piped to log).
init_tty_colors() {
    if [ -t 1 ]; then
        YEL=$'\033[33m'; GRN=$'\033[32m'; LBLU=$'\033[96m'; RST=$'\033[0m'
    else
        YEL=''; GRN=''; LBLU=''; RST=''
    fi
}
