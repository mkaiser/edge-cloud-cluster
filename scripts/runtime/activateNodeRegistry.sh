#!/bin/bash
# Restart k3s on the lab nodes so a node picks up registry config it cannot pick up live.
#
# ⚠ THIS IS NO LONGER PART OF BOOTSTRAP OR OF A RECREATE. Since 2026-09-04 the lab registry
# config activates itself: image-registry/node-registries-config.yaml writes containerd's
# own certs.d/<host>/hosts.toml, which containerd re-reads on EVERY pull, and the pull
# credential is an ordinary imagePullSecret. Neither path needs an agent restart, so a fresh
# cluster no longer has an ImagePullBackOff window and nobody has to run this.
#
# WHAT IT IS STILL FOR: the one case the DaemonSet write cannot fix — a node carrying
# STALE k3s-generated registry state from the old /etc/rancher/k3s/registries.yaml route
# (an auth entry baked into containerd's config.toml at its last start, which is read only
# at agent start). Restarting k3s clears it. Also the generic "make this node re-read
# everything" hammer.
#
#   bash scripts/runtime/activateNodeRegistry.sh            # all unibi-hclab nodes
#   bash scripts/runtime/activateNodeRegistry.sh --check    # report only, change nothing
#
# ⚠ ONE NODE AT A TIME, waiting for Ready in between. Two lab nodes carry on-prem AD DCs, and
# restarting k3s bounces containerd and every pod on that node: serialised, one DC is always
# up; parallel, the site loses its directory. That is also why this is a script a human runs
# and NOT a privileged DaemonSet restarting its own node — a bad file would then take out the
# whole site with no way back in.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_SETTINGS="$REPO_ROOT/project_settings.ts"
HOSTPORT="127.0.0.1:30500"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 2; }
if ! pulumi -C "$REPO_ROOT" stack --show-name </dev/null &>/dev/null; then
    echo "ERROR: no Pulumi stack selected — the node SSH key lives there." >&2
    echo "  source ./scripts/pulumi/initPulumiStack.sh" >&2
    exit 2
fi

# The lab nodes, from the cluster rather than from settings: what matters is which nodes
# actually carry ecc/fileserver-lan=true right now, not which ones are declared.
mapfile -t LAB_NODES < <(kubectl get nodes -l ecc/fileserver-lan=true -o name 2>/dev/null | sed 's|node/||')
[ ${#LAB_NODES[@]} -gt 0 ] || { echo "No nodes with ecc/fileserver-lan=true — nothing to do."; exit 0; }

# ssh coordinates per node id, parsed from project_settings the same way provisionMeshNodes
# does (brace-depth, not field order — `host: { … }` nests).
node_ssh() {
    perl -0777 -ne '
        my ($want) = @ARGV;
        if (/mesh:\s*\[([\s\S]*?)\]\s*as\s+ComputeNodeMesh/) {
            my $body = $1; my $depth = 0; my $cur = "";
            for my $ch (split //, $body) {
                $depth++ if $ch eq "{";
                $cur .= $ch if $depth > 0;
                if ($ch eq "}" && --$depth == 0) {
                    if ($cur =~ /id:\s*"\Q$want\E"/) {
                        my ($ep) = $cur =~ /endpoint:\s*"([^"]+)"/;
                        my ($pt) = $cur =~ /port:\s*(\d+)/;
                        my ($us) = $cur =~ /user:\s*"([^"]+)"/;
                        my ($ky) = $cur =~ /key:\s*"([^"]+)"/;
                        print "$ep\t$pt\t$us\t$ky\n" if $ep;
                        exit;
                    }
                    $cur = "";
                }
            }
        }
    ' "$PROJECT_SETTINGS" "$1" 2>/dev/null
}

KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
trap 'rm -f "$KEYFILE"' EXIT

restarted=0; skipped=0; failed=0
for node in "${LAB_NODES[@]}"; do
    IFS=$'\t' read -r EP PT US KY < <(node_ssh "$node")
    if [ -z "${EP:-}" ]; then
        echo "  $node: no ssh block in project_settings — SKIPPED (cannot reach it)."
        failed=$((failed+1)); continue
    fi
    pulumi -C "$REPO_ROOT" config get "$KY" 2>/dev/null > "$KEYFILE" || true
    grep -q 'BEGIN .*PRIVATE KEY' "$KEYFILE" || {
        echo "  $node: ssh key '$KY' not in the Pulumi stack — SKIPPED."; failed=$((failed+1)); continue; }

    ssh_node() { ssh -n -i "$KEYFILE" -p "$PT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes \
        -o IdentitiesOnly=yes "$US@$EP" "$@" 2>/dev/null; }

    # ⚠ NO "already active" SHORT-CIRCUIT ANY MORE. hosts.toml is now written by the
    # DaemonSet rather than by k3s, so its presence proves nothing about whether this node
    # still carries stale k3s-generated state — which is the only reason left to run this.
    # Restarting is idempotent; skipping on a file that is always present would make the
    # script a no-op exactly when it is needed.
    if ! ssh_node "sudo test -f '/var/lib/rancher/k3s/agent/etc/containerd/certs.d/$HOSTPORT/hosts.toml'"; then
        echo "  $node: certs.d/$HOSTPORT/hosts.toml is NOT there — the image-registry"
        echo "    DaemonSet has not written it. Restarting k3s would not help; re-run once it has."
        failed=$((failed+1)); continue
    fi
    if $CHECK_ONLY; then
        echo "  $node: would restart k3s (config present, containerd unaware)."
        restarted=$((restarted+1)); continue
    fi

    echo "  $node: restarting k3s to pick up the registry config ..."
    ssh_node 'sudo systemctl is-active k3s >/dev/null 2>&1 && sudo systemctl restart k3s || sudo systemctl restart k3s-agent' || true
    # Wait for the node to come back before touching the next one — two of these carry AD DCs.
    for _ in $(seq 1 30); do
        [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
        sleep 5
    done
    # Verify the pull itself, not the presence of a file — after a restart the useful
    # question is whether containerd can actually fetch through $HOSTPORT. Credentials come
    # from the pods' imagePullSecret, so an unauthenticated probe is expected to 401; only
    # a TLS/routing failure is a real problem here.
    probe=$(ssh_node "sudo k3s crictl pull $HOSTPORT/image-archives/does-not-exist:probe 2>&1 | tail -1")
    case "$probe" in
        *"no basic auth credentials"*|*"not found"*|*"NotFound"*|*"unauthorized"*|*401*|*404*)
            echo "    $node: Ready, and containerd reaches $HOSTPORT over TLS."
            restarted=$((restarted+1)) ;;
        *)
            echo "    ⚠ $node: restarted but $HOSTPORT is not reachable as expected:" >&2
            echo "      $probe" >&2
            echo "      Check certs.d/$HOSTPORT/hosts.toml and the image-registry CA." >&2
            failed=$((failed+1)) ;;
    esac
done

echo "node registry activation: $restarted restarted, $skipped already current, $failed unresolved"
[ "$failed" -eq 0 ]
