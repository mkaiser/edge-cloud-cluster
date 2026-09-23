#!/usr/bin/env bash
# Log one whole command run to logs/<ts>-<slug>.log.
#
# Two callers:
#   1. the Makefile's .maketrap target, which re-execs make with MAKELOG_ACTIVE=1 so
#      the inner make runs the real (unwrapped) rules;
#   2. by hand, for any long-running command you want captured the same way:
#        bash scripts/environment/runLogged.sh pulumi-preview pulumi preview
#
#   $1   = slug for the filename
#   $2.. = the command to run
#
# Only stdout/stderr are teed. stdin is deliberately NOT touched, so `read -rp`,
# `read -rsp` and the `[ -t 0 ]` prompt gates in scripts/pulumi/_lifecycle.sh keep
# working. Consequence: stdout is a pipe, so init_tty_colors (_common.sh) blanks
# the colors and pulumi streams plainly instead of rendering interactive progress.
#
# The LOG gets the full raw stream; the TERMINAL gets phaseFilter.sh's summary of it
# (~4700 lines to ~200 on a bootstrap). Nothing is lost by filtering — the tee has
# already written every byte to disk before the filter sees it.
# PHASE_VERBOSE=1 makes the filter a pass-through, for when you want the firehose live.
#
# ⚠ Because stderr is merged in here, `read -rp`'s prompt (stderr, and NO trailing
# newline when stdin is a TTY) travels through the filter as a partial line. That is
# why phaseFilter.sh must never buffer one — see its header.
set -uo pipefail # NOT -e: the trailer must still be written when the run fails

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
goals="$1"
shift

mkdir -p "$REPO_ROOT/logs"
slug="$(printf '%s' "$goals" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
[ -n "$slug" ] || slug="default"
# Calls from the Makefile trap (MAKELOG_ARGS is set) get a make- prefix so they sort
# apart from hand-run commands; standalone callers own their slug verbatim.
[ -n "${MAKELOG_ARGS+x}" ] && slug="make-$slug"

# Two runs can start in the same second; never let them share a file.
base="$REPO_ROOT/logs/$(date '+%Y-%m-%d__%H-%M-%S')-${slug}"
LOG_FILE="$base.log"
n=2
while [ -e "$LOG_FILE" ]; do
    LOG_FILE="$base~$n.log"
    n=$((n + 1))
done

# The Makefile trap passes the goal list and sets MAKELOG_ARGS; reconstruct the
# `make …` line the user typed. Any other caller logs its own argv verbatim.
if [ -n "${MAKELOG_ARGS+x}" ]; then
    cmdline="make ${goals}${MAKELOG_ARGS:+ ARGS=$MAKELOG_ARGS}"
else
    cmdline="$*"
fi

start=$(date +%s)
printf '=== START %s\n=== command: %s\n=== cwd:     %s\n\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$cmdline" "$REPO_ROOT" >>"$LOG_FILE"

# PIPESTATUS[0] is still the command's own status with the filter appended — the filter
# is the LAST stage, and only [0] is read. Verified: `bash -c 'exit 7'` reports 7.
# The filter's clock must be the RUN's start, so elapsed matches the log trailer's
# duration=. Export it: it belongs to the filter's env, not the command's.
export PHASE_FILTER_START="$start"
"$@" 2>&1 | tee -a "$LOG_FILE" | bash "$REPO_ROOT/scripts/environment/phaseFilter.sh"
rc=${PIPESTATUS[0]} # capture immediately; tee's/the filter's status would mask it

dur=$(($(date +%s) - start))
printf '\n=== END   %s rc=%s duration=%ss\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$rc" "$dur" >>"$LOG_FILE"

# Say on the TERMINAL how the run ended. The `=== END … rc=` trailer above goes only to the
# log, so without this a failed run and a clean one look identical on screen — and with the
# filter suppressing most output, a failure that printed nothing recognisable would scroll
# past unnoticed. The log still gets the authoritative trailer either way.
if [ "$rc" -eq 0 ]; then
    printf '\n[%s] done  rc=0  %dm%02ds\n' "$(date '+%H:%M:%S')" "$((dur / 60))" "$((dur % 60))" >&2
else
    printf '\n[%s] FAILED  rc=%s  %dm%02ds\n' "$(date '+%H:%M:%S')" "$rc" "$((dur / 60))" "$((dur % 60))" >&2
fi

echo "log: ${LOG_FILE#"$REPO_ROOT"/}" >&2
exit "$rc"
