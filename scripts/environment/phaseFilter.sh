#!/usr/bin/env bash
# phaseFilter.sh — terminal-side view of a lifecycle run. Reads the merged stdout+stderr of
# a `make` target on stdin and writes a timestamped, phase-annotated SUMMARY on stdout.
#
# It is one stage in runLogged.sh's pipeline; the LOG is written by the tee ahead of it and
# is never touched here. So this filter can drop as much as it likes — nothing it suppresses
# is lost, it is already on disk. The terminal is the only thing being made readable.
#
#   "$@" 2>&1 | tee -a "$LOG_FILE" | bash phaseFilter.sh
#
# PHASE_VERBOSE=1 turns the filter into a pass-through (still timestamped), which is what
# `make <target> ARGS=--verbose` sets.
#
# ── WHY A TEXT FILTER AND NOT PULUMI EVENTS ─────────────────────────────────────────────
# `pulumi up --event-log <file>` emits exactly the structured stream this wants, and it is
# NOT available: the flag exists only in the Automation API, and this repo drives the plain
# CLI. `pulumi up --event-log x` on v3.253.0 answers `error: unknown flag: --event-log`.
# So the resource lifecycle is recovered by matching pulumi's own rendered output. If this
# project ever moves to the Automation API, this whole file should be replaced by an event
# handler rather than extended.
#
# ── WHY EVERY WRITE IS FLUSHED ──────────────────────────────────────────────────────────
# ⚠ The interactive offers in _lifecycle.sh are `read -rp`, whose prompt is written WITHOUT
# a trailing newline. `read -rp` puts that prompt on STDERR when stdin is a TTY (and prints
# nothing at all when it is not), and runLogged.sh merges stderr into this pipe with 2>&1 —
# so the prompt arrives here as a PARTIAL LINE. A filter that waits for a newline holds it
# until the read times out, i.e. the human is asked a question 60s after their chance to
# answer began. Hence: read by character, flush on every write, never buffer a partial line.
set -uo pipefail

START_EPOCH=${PHASE_FILTER_START:-$(date +%s)}
export START_EPOCH
# Both are read from %ENV by the perl below, so they must be exported, not just set.
export PHASE_VERBOSE="${PHASE_VERBOSE:-}"
export PHASE_HEARTBEAT="${PHASE_HEARTBEAT:-}"

exec perl -e '
use strict; use warnings;
$| = 1;
# The glyphs below are non-ASCII; without this every emit() warns "Wide character".
# ⚠ STDIN is deliberately left as raw bytes: sysread() refuses a :utf8 handle, and the
# read loop needs sysread to spot a prompt that never ends in a newline. So input is
# decoded per line instead (Encode::decode below) — reading UTF-8 as bytes and then
# re-encoding on output would turn every "→" into mojibake.
use Encode ();
binmode(STDOUT, ":encoding(UTF-8)");
# Prompts are forwarded as the raw bytes they arrived as, so they need a handle WITHOUT
# the encoding layer above — pushing already-encoded bytes through it would double-encode
# every non-ASCII character in the question.
open(my $RAW, ">&", \*STDOUT) or die "dup stdout: $!";
binmode($RAW, ":raw");
$RAW->autoflush(1);
sub emit_raw { my ($b) = @_; STDOUT->flush(); print {$RAW} $b; }

my $start   = $ENV{START_EPOCH};
my $verbose = ($ENV{PHASE_VERBOSE} // "") eq "1";

# ── Heartbeat cadence. A phase can be silent for minutes (a robot installimage, an etcd
# learner join); without this the run reads as hung. Only fires when nothing was EMITTED,
# so a chatty phase never doubles up.
my $HEARTBEAT = ($ENV{PHASE_HEARTBEAT} // "") =~ /^\d+$/ ? $ENV{PHASE_HEARTBEAT} : 30;

my @phases;              # registered phase labels, in order
my $phase_idx   = 0;     # 1-based index of the running phase
my $phase_label = "";
my $phase_start = $start;
my $last_emit   = time;
my $last_seen   = "";    # most recent pulumi resource name, for the heartbeat
my %sub_seen;            # sub-phase markers already announced (first occurrence only)

sub stamp {
    my $now = time;
    my $d   = $now - $start;
    my @lt  = localtime($now);
    return sprintf("[%02d:%02d:%02d +%02dm%02ds]", $lt[2], $lt[1], $lt[0], int($d / 60), $d % 60);
}

sub emit {
    my ($line) = @_;
    print stamp() . " " . $line . "\n";
    $last_emit = time;
}

# ── Sub-phases inside the one opaque `pulumi up`. CP0 init and the additional control
# planes are NOT separate shell steps — they are resources inside a single apply, so the
# only way to show progress through them is to recognise their names as they stream past.
# Keep these in sync with the resource names in src/nodes-k3s-base.ts / nodes-k3s-mesh.ts.
my @SUBPHASE = (
    [ qr/robot-installos-/,                 "CP0 box: OS reinstall (rescue + installimage)" ],
    [ qr/k3s-init-cp-join-or-init/,         "CP0: k3s cluster-init"                        ],
    [ qr/wait-for-k3s-setup-init-cp-ready/, "CP0: waiting for k3s to serve"                 ],
    [ qr/wait-for-k3s-join-/,               "additional node: joining cluster"              ],
    [ qr/select-kubeconfig/,                "kubeconfig selected"                           ],
    [ qr/vip-cutover-/,                     "VIP cutover"                                   ],
    [ qr/mesh-provision-/,                  "mesh node: provisioning"                       ],
);

# Errors always survive the filter, whatever else the rules say. "refus" catches the
# lifecycle guards ("refusing to close public SSH"), which are the ones that quietly
# skip a phase rather than failing the run.
my $ERROR_RE = qr/error|ERROR|Error:|failed|FAILED|Failed|WARNING|refus|Traceback|panic:|rc=[1-9]/;

# A pulumi resource line: leading verb glyph, type token, name, then a state verb.
# `created/updated/deleted/replaced` are the ~100 milestone lines of a whole run;
# `creating/updating` are the ~3900 lines of streamed remote stdout.
my $RES_DONE = qr/^\s*[+~\-]{1,2}\s+\S+\s+(\S+)\s+(created|updated|deleted|replaced)\b/;
my $RES_BUSY = qr/^\s*[+~\-]{1,2}\s+\S+\s+(\S+)\s+(creating|updating|deleting|replacing)\b/;

sub handle {
    my ($line) = @_;
    chomp $line;
    $line = Encode::decode("UTF-8", $line, Encode::FB_DEFAULT);

    # ── 1. Phase sentinels (emitted by phase_* in scripts/pulumi/_common.sh). Matched
    # first and unconditionally: these are the backbone of the display, and must appear
    # even in verbose mode where everything else is already passing through.
    if ($line =~ /^\@\@PHASE\s+REGISTER\s+(.*)$/) {
        @phases = split /\|/, $1;
        return;
    }
    if ($line =~ /^\@\@PHASE\s+BEGIN\s+(\d+)\s+(.*)$/) {
        ($phase_idx, $phase_label) = ($1, $2);
        $phase_start = time;
        %sub_seen    = ();
        emit(sprintf("\x{25B6} Phase %d/%d  %s", $phase_idx, scalar(@phases) || $phase_idx, $phase_label));
        return;
    }
    if ($line =~ /^\@\@PHASE\s+END\s+(\S+)\s+(\d+)\s+(.*)$/) {
        my ($status, $secs, $label) = ($1, $2, $3);
        # A skipped phase keeps its number — renumbering the survivors would make two runs
        # of the same target disagree about what "Phase 5" was.
        my %glyph = (ok => "\x{2714}", skip => "\x{2298}", fail => "\x{2718}");
        emit(sprintf("%s Phase %d/%d  %s%s",
                     $glyph{$status} // "?", $phase_idx, scalar(@phases) || $phase_idx, $label,
                     $status eq "skip" ? "  (skipped)"
                                       : sprintf("  %dm%02ds", int($secs / 60), $secs % 60)));
        return;
    }

    if ($verbose) { emit($line); return; }

    # ── 2. Errors and warnings: never filtered.
    if ($line =~ $ERROR_RE) { emit($line); return; }

    # ── 3. Finished resources are the milestones worth showing.
    if ($line =~ $RES_DONE) {
        $last_seen = $1;
        emit("  $1 $2");
        return;
    }

    # ── 4. In-flight resources are the bulk of the noise. Show only the FIRST line that
    # reveals a new sub-phase; drop the rest (they are in the log).
    if ($line =~ $RES_BUSY) {
        $last_seen = $1;
        for my $sp (@SUBPHASE) {
            my ($re, $label) = @$sp;
            if ($line =~ $re && !$sub_seen{$label}++) { emit("  \x{2500} $label"); }
        }
        return;
    }

    # ── 5. Pulumi progress dots and blank lines carry nothing.
    return if $line =~ /^\s*\@\s*(updating|creating|deleting)\.*\s*$/;
    return if $line =~ /^\s*$/;

    # ── 6. Anything else is script-authored prose — someone chose to print it, so show it.
    emit($line);
}

# ── Read loop. See the partial-line warning in the file header: a prompt has no trailing
# newline, so a plain readline() loop would hold it until the read times out.
#
# ⚠ Content alone CANNOT tell a prompt from a line still being written — "Answer? " and the
# first 9 bytes of a longer sentence look identical. What distinguishes them is TIME: the
# writer of a prompt then blocks on the human. So select() with a short timeout, and treat
# "partial line, nothing more arriving" as a prompt. That also makes a stalled partial line
# visible instead of invisible, which is the failure this exists to prevent.
my $PROMPT_QUIET = 0.25;   # seconds of silence that turn a partial line into a prompt

my $rin = "";
vec($rin, fileno(STDIN), 1) = 1;
my $buf = "";

while (1) {
    my $ready = select(my $rout = $rin, undef, undef, $HEARTBEAT);

    if (!$ready) {
        # Nothing at all for a while. Flush a pending partial line (a prompt), else
        # heartbeat so a long silent phase does not read as a hung run.
        if (length $buf) { emit_raw($buf); $buf = ""; next; }
        if ($phase_label ne "" && time - $last_emit >= $HEARTBEAT) {
            my $in = time - $phase_start;
            emit(sprintf("  \x{2026} still in %s (%s%dm%02ds)",
                         $phase_label, $last_seen ne "" ? "$last_seen, " : "",
                         int($in / 60), $in % 60));
        }
        next;
    }

    my $chunk;
    my $n = sysread(STDIN, $chunk, 65536);
    last if !defined($n) || $n == 0;
    $buf .= $chunk;

    # Complete lines first; whatever trails the last newline stays buffered.
    while ($buf =~ s/^([^\n]*)\n//) { handle($1); }

    # A leftover partial line: give the writer a moment. If nothing follows, it is a prompt.
    while (length $buf) {
        last if select(my $r2 = $rin, undef, undef, $PROMPT_QUIET);
        emit_raw($buf);
        $buf = "";
        last;
    }
}
# EOF with a partial line still buffered: forward it verbatim. It is either a prompt the
# writer died on or a truncated final line; either way a timestamp would corrupt it.
emit_raw($buf) if length $buf;
'
