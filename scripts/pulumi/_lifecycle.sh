# _lifecycle.sh — cluster-lifecycle PHASES for the bootstrap/production/restore entrypoints.
#
# SOURCE this (don't execute). It holds the cluster-lifecycle work as named, sequential phase
# functions. Each entrypoint (bootstrap.sh / production.sh / restore.sh) sources this +
# _common.sh and calls the phases in order — no script re-invokes a sibling entrypoint, and
# there is no `exec` hand-off. Keep it that way.
#
# Requires (from the sourcing entrypoint): REPO_ROOT, PS_FILE, and `source _common.sh` already
# done (for init_pulumi, ps_*, timed_prompt, step_time, colors).
#
# The phases DO call `exit` on hard errors (they run inside an executed entrypoint, where aborting
# is correct). Under the entrypoint's `set -euo pipefail`, a failing phase also aborts the
# sequence — which is what we want (e.g. a failed phase_create must not fall through to hardening).
#
# TRAP G: locate every sibling script from $REPO_ROOT via its explicit subfolder
# ($REPO_ROOT/scripts/pulumi, $REPO_ROOT/scripts/runtime) — NEVER $SCRIPT_DIR. phase_create SOURCEs
# runtime scripts (getKubeConfig.sh, wgAdminUp.sh) that each set SCRIPT_DIR to their own dir,
# clobbering it to scripts/runtime/ in the caller's scope (they are sourced, not executed). A later
# `bash "$SCRIPT_DIR/up.sh"` would then resolve to scripts/runtime/up.sh (does not exist).
# $REPO_ROOT is set once by the entrypoint and never reassigned.

# ── lifecycle_prompt <seconds> <prompt> ─────────────────────────────────────────────────
# timed_prompt wrapper for the three post-create offers (harden / mesh-provision / commit).
# COMPLETE_RUN=1 (`make bootstrap ARGS=--complete`) yields "y" immediately so a recreate runs
# unattended; without it this is plain timed_prompt with an EMPTY default — i.e. a timeout
# skips the step (hence the _auto_skip suffix on the callers).
lifecycle_prompt() {
    if [ "${COMPLETE_RUN:-}" = "1" ]; then
        # Echo the prompt+answer to STDERR, never stdout: stdout IS the result (callers do
        # `ans=$(lifecycle_prompt ...)` and regex-match it), so a banner on stdout would be
        # captured too and fail the ^[yY]$ test — silently skipping every step.
        echo "${2}y   [--complete]" >&2
        printf 'y'
        return 0
    fi
    timed_prompt "$1" "$2" ""
}

# ── phase_production_preflight ──────────────────────────────────────────────────────────
# Prove the admin WireGuard path works BEFORE anything closes the public door. Flipping to
# "production" with a dead tunnel is a guaranteed lockout on robot boxes. `ssh
# root@<robotPrivateIp> true` over the tunnel. Returns 0 if OK (or no robot nodes → nothing to
# probe), 1 on failure — the CALLER decides whether --force overrides.
#
# HOST KEYS: this probe is deliberately known_hosts-free (StrictHostKeyChecking=no +
# UserKnownHostsFile=/dev/null, same as the provisioning scripts). Every recreate gives the same
# private IP a NEW host key, and accept-new accepts an unknown host but REFUSES a changed one —
# so it turned every recreate into a preflight failure that silently skipped hardening. Clearing
# the stale entry instead is not reliable: one malformed line anywhere in known_hosts makes
# `ssh-keygen -R` refuse to rewrite the file at all. Nothing is lost by dropping the pin — the
# transport is the already-authenticated WireGuard tunnel and the probe runs `true`.
phase_production_preflight() {
    local robot_private_ip; robot_private_ip="$(ps_node_field 'provider:\s*"robot"' privateIp)"
    if [[ -z "$robot_private_ip" ]]; then
        echo "  (no robot nodes — skipping tunnel preflight; hcloud posture is API-recoverable)"
        return 0
    fi
    echo "Production preflight: ssh root@${robot_private_ip} through the WireGuard tunnel…"
    # RETRY, don't judge on one attempt. The tunnel is UDP over the open internet and a
    # single probe is a coin flip whenever the path is briefly lossy — one dropped SSH
    # handshake used to skip hardening for the whole run (measured 2026-09-05: a lossy
    # window turned `Connection reset by peer` into a silently unhardened cluster).
    # A genuinely dead tunnel fails all attempts, so this costs nothing when it is really down.
    local ssh_err attempt
    for attempt in 1 2 3 4 5; do
        if ssh_err=$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "root@${robot_private_ip}" true 2>&1); then
            [ "$attempt" -gt 1 ] && echo "  tunnel OK (attempt $attempt/5)." || echo "  tunnel OK."
            return 0
        fi
        [ "$attempt" -lt 5 ] && { echo "  attempt $attempt/5 failed — retrying in 5s…"; sleep 5; }
    done
    echo "       (5 attempts, all failed)" >&2
    sed 's/^/       ssh: /' <<<"$ssh_err" >&2
    cat >&2 <<EOF
ERROR: cannot reach root@${robot_private_ip} over the VPN — refusing to close public SSH.
       Bring the tunnel up first (source ./scripts/init.sh, or scripts/runtime/wgAdminUp.sh)
       or, if you are certain, re-run with --force:  make production ARGS=--force
EOF
    return 1
}

# ── phase_offer_push ────────────────────────────────────────────────────────────────────
# Before deploying, warn about commits on the current branch that aren't on its upstream and
# offer to push them. WHY: ArgoCD deploys from the pushed git ref, not the local tree — an
# unpushed commit means the cluster reconciles against stale manifests. No upstream / nothing
# unpushed → silent no-op. Invalid answer aborts (fail-safe: don't deploy against an unclear
# push state). Empty answer = ignore (the deploy-anyway default).
# NON-INTERACTIVE (no TTY on stdin, e.g. the detached runs CLAUDE.md mandates): push, don't
# prompt — see the comment in the body.
phase_offer_push() {
    local upstream_branch; upstream_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
    [ -n "$upstream_branch" ] || return 0

    local unpushed_count; unpushed_count=$(git -C "$REPO_ROOT" rev-list --count "$upstream_branch..HEAD" 2>/dev/null || echo 0)
    [ "$unpushed_count" -gt 0 ] || return 0

    echo "Detected $unpushed_count unpushed commit(s) on $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)."
    git -C "$REPO_ROOT" --no-pager log --oneline "$upstream_branch..HEAD"

    # ⚠ NON-INTERACTIVE RUNS MUST NOT DIE HERE. Every long lifecycle target is required by
    # CLAUDE.md to run detached, which closes stdin — and `read` on a closed stdin returns
    # non-zero, so under `set -e` this function used to abort the whole deploy before it
    # started. Measured 2026-09-07: it killed a detached `make bootstrap` (rc=2 at 305s) and
    # two detached `make restore` runs (rc=2 at 171s) before anything was deployed.
    # PUSH is the safe default here, not ignore: ArgoCD reconciles the PUSHED ref, so
    # deploying with commits unpushed is what actually breaks the cluster.
    local push_choice
    if [ ! -t 0 ]; then
        echo "  stdin is not a TTY (detached run) — pushing automatically."
        git -C "$REPO_ROOT" push || exit 1
        return 0
    fi
    printf "Unpushed commits found. Push before deploy? [p=push/i=ignore]: "
    if ! read -r push_choice; then
        echo ""
        echo "  no answer on stdin — pushing automatically."
        git -C "$REPO_ROOT" push || exit 1
        return 0
    fi
    case "$push_choice" in
        p|P|push|PUSH)                git -C "$REPO_ROOT" push || exit 1 ;;
        i|I|ignore|IGNORE|"")         : ;;
        *) echo "Invalid choice. Aborting deployment."; exit 1 ;;
    esac
}

# ── phase_create <fresh|restore> ────────────────────────────────────────────────────────
# The full first-create body: restore/fresh config, guards, ssh-agent keys, pulumi up,
# kubeconfig, WireGuard, argocd login, portal print. (Was createCluster.sh:34-153.)
# GUARD: never wipe a live cluster (checkClusterExists), overridable with FORCE_CREATE=1/--force
# upstream. A create can NOT inherit a closed firewall: this function SETS targetState to
# bootstrap or restore, both of which are open postures.
phase_create() {
    local type="$1"

    # Guard: never wipe a running cluster. A fresh create bumps robotForceReinstall and
    # reinstalls the dedicated CP0 box, destroying the cluster. Abort if one is live, BEFORE
    # any pulumi config mutation. `restore` rebuilds from backup, same hazard.
    source "$REPO_ROOT/scripts/pulumi/checkClusterExists.sh"
    if cluster_exists; then
        echo "ERROR: a live cluster already exists for this Pulumi stack." >&2
        echo "       a fresh create / 'make restore' would reinstall the dedicated CP0 node and WIPE it." >&2
        echo "       Run 'make destroy' first, or 'make up' to reconcile the existing cluster." >&2
        echo "       To recreate/recover anyway: FORCE_CREATE=1 make bootstrap  (or make restore ARGS=--force)." >&2
        exit 1
    fi

    case "$type" in
        restore)
            echo "Type: restore"
            # Sets the open posture AND the restore-from-S3 behaviour in one value: k3s
            # restores etcd from the S3 snapshot and Longhorn restores its volumes.
            ps_set_target_state restore
            ;;
        fresh)
            echo "Type: fresh"
            # Open posture, fresh etcd. This must be set EXPLICITLY rather than left unset:
            # the restore path is selected by this same value, so a create that inherited
            # "restore" would restore leftover backups onto a supposedly fresh cluster.
            ps_set_target_state bootstrap
            # Force a from-scratch OS reinstall of robot (dedicated) boxes: bump
            # robotForceReinstall to a fresh value so the installimage path puts each box back
            # into rescue + hardware-resets + reinstalls, wiping stale prior-cluster state
            # (etcd/k3s/network). Value changes every fresh create → fires exactly once;
            # unchanged across routine `pulumi up`, so a healthy cluster is never re-wiped.
            pulumi config set robotForceReinstall "$(date +%s)"
            ;;
        *)
            echo "phase_create: unknown type '$type' (expected fresh|restore)" >&2
            exit 1
            ;;
    esac

    phase_begin "Create cluster"
    local start; start=$(date +%s)

    # Silence Alertmanager for the run. A bring-up trips `for: 15m` rules simply by taking
    # ~42 min, and send_resolved doubles each into a second mail — ~20 non-actionable mails
    # per recreate. The window auto-expires, so a failed or killed run cannot leave
    # monitoring off. Best-effort: never fails the deployment.
    bash "$REPO_ROOT/scripts/runtime/alertSilence.sh" start 60 || true

    # Offer to push unpushed commits before deploying (ArgoCD reconciles from the pushed ref).
    phase_offer_push

    # Load node SSH private keys from the Pulumi config into the ssh-agent (see sshAgentHelpers.sh):
    # the local provisioning Commands' bare `ssh` calls need them, else create hangs in the wait
    # loops with "Permission denied".
    source "$REPO_ROOT/scripts/pulumi/sshAgentHelpers.sh"
    ensure_node_ssh_keys_in_agent

    # No teardown flag to reset: the case above already set targetState to bootstrap/restore,
    # and "destroy" is a value of that same field rather than a second flag that could linger.

    # The VPN/headscale mesh is NOT up during initial bring-up, so mesh-node SSH must not run here.
    # `make provision-mesh-node` flips meshVpnReady true (second pass) and leaves it true; reset it
    # to false at the start of a fresh create so MeshNodesComponent stays off.
    local current_vpn_ready; current_vpn_ready=$(pulumi config get meshVpnReady 2>/dev/null || echo "false")
    if [[ "$current_vpn_ready" == "true" ]]; then
        echo "Resetting meshVpnReady to false — mesh nodes are provisioned only after the VPN is up (make provision-mesh-node)."
        pulumi config set meshVpnReady false
    fi

    # A FRESH cluster has no ArgoCD and no Helm release, so Pulumi must bootstrap and own the
    # `argocd` release again — clear the ownership latch. Crash-safe by the same argument as
    # meshVpnReady above: destroy also clears it, but a failed/skipped destroy must not strand
    # it true, which would leave the new cluster with NO ArgoCD at all (Pulumi would skip the
    # Release and nothing else installs it).
    bash "$REPO_ROOT/scripts/pulumi/argocdOwnershipLatch.sh" --clear

    # Pin the stable admin API hostname (network.apiServerHost) to the init CP's PUBLIC IP:
    # during first create nothing private is reachable yet (the admin WG tunnel only comes up
    # after this pulumi up), and the provider/select-kubeconfig kubeconfig points at the
    # hostname. wgAdminUp.sh (below) re-pins it to the VIP once the tunnel works.
    bash "$REPO_ROOT/scripts/runtime/setKubeApiHost.sh" --public

    CI=true pulumi up -y --skip-preview
    source "$REPO_ROOT/scripts/runtime/getKubeConfig.sh"

    echo "Infrastructure deployed. 'kubectl get nodes' now works."
    step_time "Pulumi up" "$start"
    phase_end ok

    # The admin tunnel comes up BEFORE hardening, and that order is load-bearing:
    # phase_production_preflight proves this tunnel works before anything closes public SSH.
    phase_begin "Admin VPN"
    local wg_start; wg_start=$(date +%s)
    source "$REPO_ROOT/scripts/runtime/wgAdminUp.sh"
    step_time "WireGuard connected" "$wg_start"
    phase_end ok

    # argocd CLI login is flaky right after bring-up; a failure here must not abort the run.
    phase_begin "ArgoCD login"
    local argocd_start; argocd_start=$(date +%s)
    local argocd_status=ok
    if ! bash "$REPO_ROOT/scripts/runtime/argocdLoginCLI.sh" infra; then
        echo "${YEL}WARNING: argocd CLI login failed — continuing anyway. Run ./scripts/runtime/argocdLoginCLI.sh infra later.${RST}" >&2
        argocd_status=fail
    fi
    step_time "ArgoCD CLI connected" "$argocd_start"
    phase_end "$argocd_status"

    # Record the ArgoCD Helm-release ownership handoff BEFORE any later `pulumi up` in this
    # run (production hardening, mesh provisioning). Once `argocd-infra-self` is Synced over a
    # live release, a later pass that re-constructs the Release would `helm install` over it
    # and fail with "cannot re-use a name that is still in use". Never fatal: if the handoff is
    # not confirmed yet the latch stays off and Pulumi simply keeps owning the release.
    bash "$REPO_ROOT/scripts/pulumi/argocdOwnershipLatch.sh" || true

    echo "#########################################"
    echo "${LBLU}Portal: $(pulumi stack output portalURL)${RST}"
    echo "#########################################"
}

# ── offer_phase_harden_auto_skip ────────────────────────────────────────────────────────
# After a fresh/restore create (Bootstrap posture: public SSH/6443 open), offer to close them.
# The hardening path itself (preflight + flip + up) refuses on a dead tunnel, so a locked-out
# state is not reachable here. Default = SKIP: 60s to opt in with 'y'. Skipped in
# CI/non-interactive runs, unless COMPLETE_RUN=1 (--complete) answers it yes.
offer_phase_harden_auto_skip() {
    phase_begin "Firewall hardening"
    if [ "${COMPLETE_RUN:-}" != "1" ] && ! { [ -t 0 ] && [ "${CI:-}" != "true" ]; }; then
        echo "non-interactive run — skipping auto-hardening." >&2
        echo "Cluster stays in Bootstrap posture (public SSH/6443 open). Run 'make production'." >&2
        phase_end skip
        return 0
    fi
    local invoke_prod; invoke_prod="$(lifecycle_prompt 60 \
        "next step. Hardening the firewall for production. Do you want to invoke production hardening now? [yY to execute] (auto-skip in 60s) ")"
    if [[ ! "$invoke_prod" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "Skipping production hardening. Run 'make production' when ready."
        phase_end skip
        return 0
    fi

    local prod_start; prod_start=$(date +%s)
    # Same sequence make production runs, inline (no re-invocation of a sibling entrypoint):
    # prove the tunnel, flip the posture, apply. A dead tunnel refuses instead of locking us out.
    if ! phase_production_preflight; then
        echo "Skipped production hardening (tunnel preflight failed). Cluster stays in Bootstrap posture." >&2
        echo "Bring the tunnel up and run 'make production' when ready." >&2
        phase_end skip
        return 0
    fi
    ps_set_target_state production
    bash "$REPO_ROOT/scripts/pulumi/up.sh"
    echo "Public SSH/6443 are now closed on public nodes. Locked out? make breakglass"
    step_time "Production hardening" "$prod_start"
    phase_end ok
}

# ── phase_offer_mesh_provision_auto_skip ────────────────────────────────────────────────
# The headscale VPN comes up a few minutes after bring-up. Poll for it, then offer to run
# provision-mesh-node. Default = SKIP on the 120s timeout. Skipped in CI/non-interactive,
# unless COMPLETE_RUN=1 (--complete) answers it yes. The VPN poll below runs either way —
# --complete removes the human answer, not the wait.
phase_offer_mesh_provision_auto_skip() {
    source "$REPO_ROOT/scripts/runtime/vpnReadyCheck.sh"
    phase_begin "Mesh nodes"
    [ "${COMPLETE_RUN:-}" = "1" ] || { [ -t 0 ] && [ "${CI:-}" != "true" ]; } || { phase_end skip; return 0; }

    echo "Polling the cluster's mesh node VPN connection service (up to 15 min)."
    local vpn_start deadline; vpn_start=$(date +%s); deadline=$(( $(date +%s) + 15 * 60 ))
    # One line per 30s attempt used to print the same sentence 15 times. The filter's
    # heartbeat already says a phase is still running, so report only the ATTEMPT COUNT,
    # which is the part that actually changes.
    local attempt=0
    until vpn_ready_check; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "VPN not ready after 15 min. Retry later; then run 'make provision-mesh-node'." >&2
            break
        fi
        attempt=$((attempt + 1))
        echo "  mesh VPN not ready yet (attempt ${attempt}, retrying in 30s)"
        sleep 30
    done
    vpn_ready_check || { phase_end skip; return 0; }
    echo "${GRN}Cluster mesh VPN is ready now.${RST}"
    step_time "Cluster mesh VPN ready" "$vpn_start"

    local prov; prov="$(lifecycle_prompt 120 "Provision the mesh nodes now? [yY to execute] (auto-skip in 120s) ")"
    if [[ "$prov" =~ ^[yY]([eE][sS])?$ ]]; then
        local prov_script="$REPO_ROOT/scripts/pulumi/provisionMeshNodes.sh"
        [ -f "$prov_script" ] || { echo "ERROR: $prov_script not found" >&2; exit 1; }
        local prov_start; prov_start=$(date +%s)
        bash "$prov_script"
        step_time "Mesh nodes provisioned" "$prov_start"
        phase_end ok
    else
        echo "Skipped. Run 'make provision-mesh-node' when ready."
        phase_end skip
    fi
}

# ── phase_offer_commit_push_auto_skip ───────────────────────────────────────────────────
# Flipping targetState rewrote project_settings.ts + the resynced manifests. Those are
# uncommitted; the shared repo expects them on main. Offer to commit+push — 'y' executes,
# anything else (and the 60s timeout) skips. CI/non-tty: skip, unless COMPLETE_RUN=1
# (--complete) answers it yes.
# Only the lifecycle-owned paths below are staged; unrelated dirt in the tree is left alone.
# Nothing here may abort the run: the cluster work already succeeded by this point, so a
# failing commit/push only prints and returns.
# $1 = commit message subject.
phase_offer_commit_push_auto_skip() {
    local msg="$1"
    [ "${COMPLETE_RUN:-}" = "1" ] || { [ -t 0 ] && [ "${CI:-}" != "true" ]; } || return 0

    # The paths this phase owns. Staging is scoped to them, so the dirty-check must be too.
    local paths=( .pulumi-state Pulumi.mystack.yaml project_settings.ts deployment src )
    [ -n "$(git -C "$REPO_ROOT" status --porcelain -- "${paths[@]}")" ] || return 0

    local branch; branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "main" ]]; then
        echo "" >&2
        echo "Config changes are uncommitted, but HEAD is '$branch' (expected main)." >&2
        echo "Not committing automatically. Commit & push manually when ready." >&2
        return 0
    fi

    echo ""
    echo "Lifecycle-owned changes (only these are staged):"
    git -C "$REPO_ROOT" --no-pager status --short -- "${paths[@]}"
    local do_push; do_push="$(lifecycle_prompt 60 \
        "Commit & push these changes? [yY to execute] (auto-skip in 60s) ")"
    if [[ ! "$do_push" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "Skipped. Commit & push manually when ready."
        return 0
    fi

    echo "Executing commit & push."
    # Stage only the owned paths that actually exist: a path absent from the tree (e.g.
    # .pulumi-state before the first stack init) makes `git add` exit 128 and, under the
    # entrypoint's `set -e`, would abort the run after the cluster work already succeeded.
    local existing=()
    local p
    for p in "${paths[@]}"; do
        [ -e "$REPO_ROOT/$p" ] && existing+=( "$p" )
    done
    if [ ${#existing[@]} -eq 0 ]; then
        echo "None of the lifecycle-owned paths exist. Skipped."
        return 0
    fi
    if ! git -C "$REPO_ROOT" add -- "${existing[@]}"; then
        echo "WARNING: git add failed. Commit & push manually." >&2
        return 0
    fi
    if git -C "$REPO_ROOT" diff --cached --quiet; then
        echo "Nothing staged after all (changes are outside the lifecycle-owned paths). Skipped."
        return 0
    fi
    if ! git -C "$REPO_ROOT" commit -m "$msg"; then
        echo "WARNING: commit failed. Commit & push manually." >&2
        return 0
    fi
    if ! git -C "$REPO_ROOT" push; then
        echo "WARNING: push failed (no upstream? rejected?). Push manually: git push" >&2
    fi
}
