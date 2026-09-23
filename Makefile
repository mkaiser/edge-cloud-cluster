.PHONY: help setup check check-nodes check-mesh backup precommit precommit-all hooks destroy shutdown prepare-release up bootstrap production breakglass restore provision-mesh-node provisioning-bundle decommission-mesh-node prune-orphaned-mesh-nodes

# Bare `make` lists the targets. It used to run `setup` (npm ci + a tool install), which is a
# slow and surprising thing to trigger by typing three letters — and the one thing a newcomer
# is most likely to type. `help` is defined FIRST so it is the default goal even before
# .DEFAULT_GOAL is read.
.DEFAULT_GOAL := help

# ── automatic per-invocation logging ────────────────────────────────────────────────────
# Every `make <goals>` is re-exec'd once through runLogged.sh, which tees the whole run to
# logs/<timestamp>-make-<goals>.log. MAKELOG_ACTIVE guards the recursion: the inner make
# takes the `else` branch below and runs the real rules.
# Only stdout/stderr are redirected — stdin stays a TTY, so interactive `read -rp` /
# `read -rsp` prompts and the `[ -t 0 ]` gates in scripts/pulumi/_lifecycle.sh still work.
ifndef MAKELOG_ACTIVE
# Recursive `=`, NOT `:=` — .DEFAULT_GOAL is set further down, so `:=` would expand to empty
# here and a bare `make` would log as "default". (Bare `make` is `help`, which bypasses the
# trap entirely, but a goal named via .DEFAULT_GOAL must still name itself in the log.)
MAKELOG_GOALS = $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))

# -n / -t / -q must stay side-effect free: run the inner make directly, write no log.
ifneq (,$(filter n t q,$(firstword $(MAKEFLAGS))))
MAKELOG_RUN =
else
MAKELOG_RUN = bash scripts/environment/runLogged.sh "$(MAKELOG_GOALS)"
endif

# ARGS=--verbose turns off the terminal filter (scripts/environment/phaseFilter.sh) for
# this run, so the raw stream is shown live instead of the phase summary. The LOG is the
# full stream either way, so this is only about what you watch, never about what is kept.
# The flag is stripped before ARGS reaches the target: the lifecycle scripts reject unknown
# arguments (bootstrap.sh does, deliberately), so passing it through would abort the run.
MAKELOG_VERBOSE = $(if $(filter --verbose,$(ARGS)),1,)
MAKELOG_TARGET_ARGS = $(filter-out --verbose,$(ARGS))

# ── help ────────────────────────────────────────────────────────────────────────────────
# Derived from the `## <group>|<summary>` tags on the target lines themselves, so a new
# target documents itself where it is defined and this list can never drift out of sync.
# Deliberately NOT wrapped in .maketrap: it is read-only and instant, and logging it would
# drop a logs/ file on every `make` typo.
help:
	@echo "edgecloudinfra — make targets"
	@awk -F'## ' '/^[a-zA-Z][a-zA-Z0-9_-]*:.*## /{ \
	      split($$2, a, "|"); t = $$1; sub(/:.*/, "", t); \
	      if (!(a[1] in seen)) { seen[a[1]] = 1; order[++n] = a[1] } \
	      names[a[1]] = names[a[1]] t "\n"; help[a[1] "\0" t] = a[2] } \
	    END { for (i = 1; i <= n; i++) { g = order[i]; printf "\n  %s\n", g; \
	            c = split(names[g], ts, "\n"); \
	            for (j = 1; j < c; j++) printf "    %-26s %s\n", ts[j], help[g "\0" ts[j]] } }' \
	    $(MAKEFILE_LIST)
	@echo ""
	@echo "  Most targets take ARGS='...', e.g. make destroy ARGS=--force"
	@echo "  Every run is logged to logs/<timestamp>-make-<goals>.log"
	@echo ""

.PHONY: .maketrap
.maketrap:
	@MAKELOG_ACTIVE=1 MAKELOG_ARGS='$(MAKELOG_TARGET_ARGS)' PHASE_VERBOSE='$(MAKELOG_VERBOSE)' $(MAKELOG_RUN) \
	    $(MAKE) --no-print-directory $(MAKELOG_GOALS) ARGS='$(MAKELOG_TARGET_ARGS)'

# Every real target becomes a no-op that just depends on the trap. Keep this list in sync
# with the targets in the `else` branch — a target missing here bypasses logging.
setup check check-nodes check-mesh precommit-all precommit hooks up \
provision-mesh-node provisioning-bundle decommission-mesh-node prune-orphaned-mesh-nodes \
bootstrap production restore breakglass shutdown backup destroy prepare-release: .maketrap
	@:

else
# ────────────────────────────────────────────────────────────────────────────────────────

setup: hooks  ## Setup|install npm packages, tools and the git hooks
	# npm packages (requires mounted filesystem for package.json)
	npm ci
	# install more tools directly from github
	bash scripts/environment/install.sh

check:  ## Setup|run every static check (tsc, anchors, IPs, CI strings)
	npx tsc --noEmit 2>&1
	python3 scripts/environment/checkHardcodedIps.py
	python3 scripts/environment/checkDomainAnchors.py
	python3 scripts/environment/checkSiteAnchors.py
	python3 scripts/environment/checkRwoRolloutStrategy.py
	python3 scripts/environment/checkDnsEgressPeers.py
	python3 scripts/environment/checkCiScriptStrings.py
	bash scripts/environment/updateConfigFromProjectSettings.sh --check

# Read-only reconcile of the declared compute nodes (project_settings.ts nodes.cloud +
# nodes.mesh) vs live k8s node objects, in cloud / dedicated / mesh sections.
# Reports OK / NOT_READY / MISSING / UNDECLARED / DISABLED; non-zero exit on drift.
#   make check-nodes                    # fail on drift
#   make check-nodes ARGS=--warn-only   # report only, always exit 0
check-nodes:  ## Setup|reconcile declared compute nodes against the live cluster
	bash scripts/pulumi/checkComputeNodes.sh $(ARGS)

# Back-compat alias for the pre-cloud-sections name.
check-mesh: check-nodes

precommit-all:  ## Setup|format every .ts and typecheck the whole project
	npx prettier --write "**/*.ts"
	npx tsc --noEmit 2>&1

precommit:  ## Setup|run the pre-commit checks over the staged files
	bash scripts/environment/precommit.sh

hooks:  ## Setup|point git at .githooks
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

# Second-pass on-premise mesh provisioning (run after the VPN/mesh is up).
#   make provision-mesh-node                             # all ENABLED mesh nodes; reconcile to no-op
#   make provision-mesh-node ARGS=ubuntu-vm              # ONE node, force re-provision (implied:
#                                                        #   detach + cordon/drain + re-join + re-auth)
#   make provision-mesh-node ARGS='ubuntu-vm --no-force' # ONE node, non-destructive reconcile
# NB: always use ARGS='<id>' — a bare `make provision-mesh-node <id>` does NOT forward <id>
# (Make treats it as a second goal) and would run for ALL nodes. See the script header.
# Boxes are SSH-probed up front: an unreachable one is skipped (warning) instead of dialed for
# ~176s, and a node that is already Ready with a matching fingerprint is skipped entirely.
# A node that is Ready but missing its ecc/* labels gets a label-only reconcile — no drain.
provision-mesh-node:  ## Mesh nodes|adopt/reconcile mesh nodes   ARGS='<id>' for one
	bash scripts/pulumi/provisionMeshNodes.sh $(ARGS)

# Pack the keyless carry-scripts into ONE .tar.gz to hand to a node that this devcontainer
# cannot reach over SSH (USB, another operator, a third party). Unpack on the box and run
# ./provision-mesh-node-local.sh — no kubectl and no inbound SSH needed there.
#   make provisioning-bundle
# Needs a LIVE cluster: the generator reads CP0 via kubectl and SSHes to it for the k3s token.
# ⚠ The archive is SENSITIVE (it embeds that token) and is valid ONLY for the cluster it was
# generated against — token and headscale CA both change on a recreate, so regenerate after one.
provisioning-bundle:  ## Mesh nodes|pack keyless carry-scripts for an unreachable box
	bash scripts/provisioning/generateProvisioningScripts.sh --bundle $(ARGS)

# Fully retire ONE mesh node so it leaves no ghost (box wipe + k8s/Longhorn + headscale + state).
#   make decommission-mesh-node ARGS=ubuntu-vm            # full teardown by id
#   make decommission-mesh-node ARGS='ubuntu-vm --dry-run'
# Run BEFORE removing the node from project_settings.nodes.mesh[] (needs its ssh details for the
# box wipe). Same ARGS='<id>' caveat as provision-mesh-node. See the script header.
decommission-mesh-node:  ## Mesh nodes|fully retire ONE mesh node   ARGS='<id>'
	bash scripts/provisioning/decomissionNode.sh $(ARGS)

# Bulk-remove ORPHANED headscale entries (stale VPN identities with no live k8s node).
# These pile up because each re-provision re-registers the box under a -N-suffixed name and
# never deletes the predecessor. VPN identity only — does NOT touch k8s/Longhorn/the box.
#   make prune-orphaned-mesh-nodes            # list, pick, delete (interactive)
#   make prune-orphaned-mesh-nodes ARGS=--yes # delete ALL orphans, no prompt
prune-orphaned-mesh-nodes:  ## Mesh nodes|delete stale headscale entries with no live node
	bash scripts/provisioning/pruneOrphanedNodes.sh $(ARGS)


# Cluster lifecycle + firewall posture (general.targetState).
#   bootstrap:  no cluster in the stack → CREATE one (fresh), with public SSH+6443 open.
#               cluster exists → just re-open that posture on it (pulumi up).
#               (Force a recreate over a live cluster: make destroy first, or FORCE_CREATE=1.)
#               ARGS=--complete answers the three post-create offers (production hardening,
#               mesh-node provisioning, commit & push) with yes → unattended recreate.
#   production: harden — close public SSH+6443; the admin WireGuard tunnel is the only
#               way in. Refuses unless the tunnel actually works (ARGS=--force skips probe).
# Apply the current Pulumi program to an EXISTING cluster, logged like every other target.
#   make up                  # apply (refreshes the mesh skip-list first — see below)
#   make up ARGS=--refresh   # anything after ARGS goes straight to `pulumi up`
#
# ⚠ THIS TARGET WAS DELETED ONCE, DELIBERATELY, AND THE HAZARD IT WAS DELETED FOR IS REAL.
# `pulumi up` re-evaluates the mesh nodes, and whether that is a no-op depends ENTIRELY on
# two config keys: meshNodeProvisionSkip (which boxes to leave alone) and
# meshNodeProvisionForce. If the skip-list is stale or EMPTY, the provision command's gate
# falls through to the full SSH flow — which runs 00-cleanup-node.sh, and that does
# `rm -rf /var/lib/longhorn` (00-cleanup-node.sh:122). Every Longhorn replica on the box is
# destroyed and the disk comes back with a NEW UUID, so the replica CRs still referencing
# the old one are orphaned. Longhorn then reports the volume `faulted` and loops
# "All replicas are failed … Bringing up 0 replicas for auto-salvage" forever.
# Measured 2026-08-30: this wiped all three unibi-lab nodes and took ad-onprem-0 down for
# 14 h with two unrecoverable AD volumes.
#
# So this target does NOT call `pulumi up` directly. scripts/pulumi/up.sh re-probes the
# boxes and REFRESHES meshNodeProvisionSkip first (meshSkipUnreachable.sh), which is the
# guard that makes an apply safe. Never bypass it by running `pulumi up` by hand — an
# unlogged bare apply is exactly how the above happened, with no log to point at afterwards.
up:  ## Lifecycle|pulumi up, with the mesh-node safety probe (never bare pulumi up)
	bash scripts/pulumi/up.sh $(ARGS)

bootstrap:  ## Lifecycle|bring the cluster up   ARGS=--complete for unattended
	bash scripts/pulumi/bootstrap.sh $(ARGS)

production:  ## Lifecycle|harden the firewall (closes 22/6443; needs the WG tunnel)
	bash scripts/pulumi/production.sh $(ARGS)

restore:  ## Lifecycle|create the cluster from an S3 backup
	bash scripts/pulumi/restore.sh $(ARGS)


# Lockout recovery — NO pulumi up, NO kubernetes (both may be what's broken). Restores
# the coarse Robot firewall via the Robot API and re-opens SSH in the host nft table
# over any SSH path that still works; prints the rescue-console procedure otherwise.
# (A Robot-API source-IP allow rule can NOT substitute: the Robot layer is already
# permissive — the lock is host nftables, which no Hetzner API can edit.)
breakglass:  ## Lifecycle|lockout recovery over the Robot API (no pulumi, no k8s)
	bash scripts/runtime/breakglass.sh

shutdown:  ## Lifecycle|stop the cluster, keeping its data   ARGS=--force
	bash scripts/pulumi/shutdownCluster.sh $(ARGS)

backup:  ## Lifecycle|back up etcd + Longhorn to S3
	bash scripts/pulumi/backupCluster.sh

destroy:  ## Lifecycle|tear the cluster down AND delete its data   ARGS=--force
	bash scripts/pulumi/destroyCluster.sh $(ARGS)

prepare-release:  ## Release|build an anonymized public copy under release/
	bash scripts/environment/prepareRelease.sh

endif