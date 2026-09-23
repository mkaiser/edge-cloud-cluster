# _meshNodes.sh — shared parser for the node arrays in project_settings.ts.
#
# Sourced (not executed) by node scripts (cleanupMeshNodes.sh, checkComputeNodes.sh,
# decomissionNode.sh). Provides:
#   meshNodesTsv  <settings>  — nodes.mesh  records
#   cloudNodesTsv <settings>  — nodes.cloud records (hcloud + robot in one list)
#
# WHY not load the TS: nodes are declared in TypeScript but these scripts must run without a
# node/ts-node toolchain (e.g. in the destroy path, in CI). The perl parse is brace-depth
# aware so it survives the nested ssh: { ... } struct and //-commented-out node blocks.
#
# Single source of truth for the parse — every consumer MUST share this so they never drift
# when the node schema changes.

# _nodesTsv <path-to-project_settings.ts> <array-name> <as-type>
# Internal: depth-aware split of a `<array>: [ ... ] as <Type>[]` block into node objects,
# emitting one TSV record each. Not called directly — see the two wrappers below.
_nodesTsv() {
    local settings="$1"
    # Passed via env (not perl -s / @ARGV): -s consumes leading -flags from @ARGV and would
    # eat the file argument, and the block name must be interpolated into the regex.
    local ECC_ARR="$2" ECC_ASTYPE="$3"
    export ECC_ARR ECC_ASTYPE
    perl -0777 -ne '
        my ($arr, $astype) = ($ENV{ECC_ARR}, $ENV{ECC_ASTYPE});
        s{//[^\n]*}{}g;  # strip //-to-EOL comments so commented-out node blocks do not leak in
        # isolate the "<arr>: [ ... ]" block (up to the closing "] as <astype>")
        if (/\Q$arr\E:\s*\[(.*?)\]\s*as\s+\Q$astype\E/s) {
            my $blk = $1;
            # Depth-aware split into top-level { ... } node objects. A brace counter is required
            # because each node nests an ssh: { ... } struct — a plain regex would either stop
            # at the inner "}" or mis-span across the commented blocks between nodes.
            my @objs; my $depth = 0; my $cur = "";
            for my $ch (split //, $blk) {
                $depth++ if $ch eq "{";
                $cur .= $ch if $depth > 0;
                if ($ch eq "}") { $depth--; if ($depth == 0) { push @objs, $cur; $cur = ""; } }
            }
            for my $o (@objs) {
                my ($id)   = $o =~ /id:\s*"([^"]+)"/;
                next unless $id;
                my ($key)  = $o =~ /key:\s*"([^"]+)"/;       # inside the ssh: { ... } struct
                my ($host) = $o =~ /endpoint:\s*"([^"]+)"/;  # ssh endpoint (hostname or IP)
                my ($port) = $o =~ /port:\s*(\d+)/;
                my ($user) = $o =~ /user:\s*"([^"]+)"/;
                # Cloud-only fields. A cloud node has no ssh.endpoint — it is reached at its
                # publicIp, so fall back to that rather than dropping the record.
                my ($prov) = $o =~ /provider:\s*"([^"]+)"/;
                my ($pub)  = $o =~ /publicIp:\s*"([^"]+)"/;
                my ($role) = $o =~ /k8sRole:\s*"([^"]+)"/;
                # A mesh node MUST resolve to a reachable host (endpoint is required there, and
                # cleanup/decommission SSH to it) — drop the record if it has none. A cloud node
                # legitimately has neither: hcloud assigns publicIp at CREATE time, so a
                # declared-but-not-yet-built node has no address. Emit it with "-" so the
                # inventory still lists it; SSH consumers are mesh-only.
                $host ||= $pub;
                if (!$host) {
                    next unless $prov;   # no provider => mesh record => unusable, skip
                    $host = "-";
                }
                $port ||= 22; $user ||= "root";
                # enabled defaults to true; only an explicit "enabled: false" parks the node.
                my $enabled = ($o =~ /enabled:\s*false/) ? "false" : "true";
                $prov ||= "mesh"; $role ||= "";
                print "$id\t$key\t$host\t$port\t$user\t$enabled\t$prov\t$role\n";
            }
        }
    ' "$settings" 2>/dev/null || true
}

# meshNodesTsv <path-to-project_settings.ts>
# Prints TSV records to stdout, one per nodes.mesh entry:
#   "<id>\t<sshKey>\t<host>\t<port>\t<user>\t<enabled>\t<provider>\t<k8sRole>"
# <enabled> is "true"/"false" (ComputeNode.enabled, default true when omitted); <provider> is
# the literal "mesh" for these records. Callers predating a column cut/read only the fields
# they need — but a `read` MUST name a trailing catch-all var, or the last one absorbs the rest.
# Empty output = no mesh nodes. Never fails the caller (|| true on the perl invocation).
meshNodesTsv() {
    _nodesTsv "$1" "mesh" "ComputeNodeMesh"
}

# cloudNodesTsv <path-to-project_settings.ts>
# Same record shape as meshNodesTsv, for nodes.cloud. <provider> is "hcloud" or "robot"
# (the two are declared in ONE list and split by that field). <host> is the ssh.endpoint when
# present, else the node's publicIp.
cloudNodesTsv() {
    _nodesTsv "$1" "cloud" "ComputeNodeCloud"
}
