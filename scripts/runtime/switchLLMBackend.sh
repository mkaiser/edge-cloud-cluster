#!/usr/bin/env bash

set -euo pipefail

# Switch which LLM backend owns the single THOR GPU: vLLM or Ollama.
#   ./switchLLMBackend.sh vllm     # Ollama down -> vLLM up
#   ./switchLLMBackend.sh ollama   # vLLM down -> Ollama up
#   ./switchLLMBackend.sh status   # show which backend is up
#
# SCOPE: the Thor ONLY. It is NOT a cluster-wide LLM switch.
# The discrete-GPU node (smartmirror1, app `ollama-turing`) needs nothing like this:
# its pods hold real nvidia.com/gpu allocations, so the SCHEDULER enforces one pod per
# card. This script exists purely because ollama-on-Tegra cannot request nvidia.com/gpu
# (it uses the legacy env path to dodge the CDI `void` stack-smash), leaving it invisible
# to the scheduler — so exclusivity there has to be arranged by hand.
#
# The two Thor backends are EXCLUSIVE: one nvidia.com/gpu on the Thor and shared unified
# memory — both models can never coexist. Switching scales the outgoing Deployment to 0,
# waits for its pod to fully terminate (freeing the GPU + memory), then scales the
# incoming one to 1.
#
# Either backend may be ABSENT (ollama-thor currently ships as
# app-of-apps/ollama.yaml.disable). Every step therefore tolerates a missing Deployment
# instead of aborting under `set -e`.
#
# ArgoCD does NOT fight this: the vllm Application carries ignoreDifferences on
# /spec/replicas + RespectIgnoreDifferences (app-of-apps/vllm.yaml), so selfHeal leaves
# the runtime scale alone. That covers selfHeal only — an ordinary sync still recreates
# the pod, which matters when something else needs the GPU (see optimizeModel.sh).
#
# ⚠ ollama-thor is DISABLED as of 2026-09-18 (app-of-apps/ollama.yaml.disable): its
# compiled-in qwen3-coder parser leaks tool calls into message content, so the agent
# could not call a single tool. `switchLLMBackend.sh ollama` will refuse with "ollama has
# no Deployment in namespace ollama" until the app is re-enabled — that is the
# already-handled absent-backend path, not a new failure.
#
# LiteLLM's `thor/qwen3.6-35b-a3b-nvfp4` route (vLLM) is ENABLED. The vllm switch below
# CHECKS the deployed ConfigMap for it rather than assuming either way.

# Backend -> namespace/deployment (both are named like their namespace).
ns_of() { echo "$1"; }
deploy_of() { echo "$1"; }

# True when the backend's Deployment actually exists. Everything else is guarded on this:
# an absent Deployment (disabled app) must be a SKIP, never a hard failure.
exists() {
    kubectl -n "$(ns_of "$1")" get deploy "$(deploy_of "$1")" >/dev/null 2>&1
}

# NOTE the `| grep . ||` normalisation, matching ready_of(). Without it this returned an
# EMPTY string when the field was absent and the literal "?" when the Deployment was
# missing — and both compare unequal to "0", so scale_down_and_wait() sailed past its
# already-down early return and ran `kubectl scale` against a nonexistent Deployment.
# Under `set -e` that aborted the script BEFORE the incoming backend was scaled up.
replicas_of() {
    exists "$1" || { echo "-"; return; }
    kubectl -n "$(ns_of "$1")" get deploy "$(deploy_of "$1")" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null | grep . || echo "0"
}

ready_of() {
    exists "$1" || { echo "-"; return; }
    kubectl -n "$(ns_of "$1")" get deploy "$(deploy_of "$1")" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep . || echo "0"
}

status() {
    for b in vllm ollama; do
        if exists "$b"; then
            echo "$b: spec.replicas=$(replicas_of "$b") ready=$(ready_of "$b")"
        else
            echo "$b: NOT DEPLOYED (app disabled or not synced yet)"
        fi
    done
    echo ""
    echo "Thor only. The discrete-GPU node is scheduler-managed — see ollama-turing."
}

scale_down_and_wait() {
    local b="$1" ns dep
    ns=$(ns_of "$b"); dep=$(deploy_of "$b")
    if ! exists "$b"; then
        echo "$b is not deployed — nothing to scale down."
        return
    fi
    if [ "$(replicas_of "$b")" = "0" ] && \
       ! kubectl -n "$ns" get pods -l app="$dep" -o name 2>/dev/null | grep -q .; then
        echo "$b already down."
        return
    fi
    echo "Scaling $b to 0..."
    kubectl -n "$ns" scale deploy "$dep" --replicas=0
    # Wait for the pod to FULLY terminate — the GPU (and the unified memory the
    # model occupies) is only free once the container is gone, and the incoming
    # backend's nvidia.com/gpu request stays Pending until then.
    echo "Waiting for $b pod to terminate (frees the GPU)..."
    local start; start=$(date +%s)
    while kubectl -n "$ns" get pods -l app="$dep" -o name 2>/dev/null | grep -q .; do
        if [ $(( $(date +%s) - start )) -gt 300 ]; then
            echo "ERROR: $b pod still terminating after 300s. Inspect: kubectl -n $ns get pods"
            exit 1
        fi
        sleep 5
    done
    echo "$b is down."
}

scale_up() {
    local b="$1" ns dep
    ns=$(ns_of "$b"); dep=$(deploy_of "$b")
    if ! exists "$b"; then
        echo "ERROR: $b has no Deployment in namespace $ns — cannot scale it up." >&2
        echo "       Its app-of-apps entry is probably still *.disable, or ArgoCD has" >&2
        echo "       not synced it yet. Enable/sync the app first." >&2
        exit 1
    fi
    echo "Scaling $b to 1..."
    kubectl -n "$ns" scale deploy "$dep" --replicas=1
    echo "Waiting for $b to become ready..."
    if ! kubectl -n "$ns" rollout status deploy "$dep" --timeout=600s; then
        echo "WARN: $b not ready after 10m (a cold model download can take much"
        echo "longer — vLLM budgets 45m). Watch: kubectl -n $ns get pods -w"
        return
    fi
    echo "$b is up."
}

# Open WebUI hides a model with a `model` row whose base_model_id is NULL and
# is_active is false (utils/models.py drops it from the served list) — the same
# mechanism open-webui/postsync-hide-wildcard-model.yaml uses.
#
# WHY THIS BELONGS IN THE SWITCH. `coder` is a real route that answers ONLY while the
# Thor vLLM is scaled up, and it sorts first in the picker — so while ollama-thor holds
# the GPU a new chat lands on it and dies with "InternalServerError - Connection error",
# which reads as a cluster fault. The PostSync Job hides it for the ollama-thor steady
# state; this function is what makes the OTHER direction correct. Without it, switching
# to vLLM would leave the working backend invisible.
#
# Best-effort by design: the desktop/CI caller may have no reach into the open-webui
# Postgres, and a failure here must never abort a GPU hand-off that already succeeded.
set_webui_model_visibility() {
    local model_id="$1" active="$2"
    local pg="open-webui-pg-1"

    kubectl -n open-webui get pod "$pg" >/dev/null 2>&1 || {
        echo "  (open-webui Postgres not reachable — skipping picker visibility for '$model_id')"
        return 0
    }

    # -U postgres, NOT the open-webui role: this goes in over the LOCAL socket, where
    # pg_hba uses peer authentication and the app role has no matching OS user
    # ("FATAL: Peer authentication failed"). The PostSync Job connects over TCP with a
    # password instead, which is why it can use the app role.
    kubectl -n open-webui exec "$pg" -c postgres -- \
        psql -U postgres -d open-webui -v ON_ERROR_STOP=1 -q -c "
            INSERT INTO model (id, user_id, base_model_id, name, params, meta,
                               created_at, updated_at, is_active)
            VALUES ('${model_id}', 'system:gitops', NULL, '${model_id}', '{}', '{}',
                    extract(epoch from now())::bigint,
                    extract(epoch from now())::bigint, ${active})
            ON CONFLICT (id) DO UPDATE
              SET is_active = ${active},
                  user_id = COALESCE(model.user_id, 'system:gitops'),
                  updated_at = extract(epoch from now())::bigint;" >/dev/null 2>&1 \
        && echo "  Open WebUI: '${model_id}' visible=${active}" \
        || echo "  (could not set picker visibility for '${model_id}' — harmless, fix by hand)"
}

TARGET="${1:-}"
case "$TARGET" in
    vllm)
        scale_down_and_wait ollama
        scale_up vllm
        # vLLM now owns the GPU: show `coder`, hide the ollama-thor routes.
        set_webui_model_visibility thor/qwen3.6-35b-a3b-nvfp4 true
        # The `coder` route was re-enabled in litellm/config.yaml on 2026-09-18, so the
        # unconditional "it is commented out" warning that used to print here was stale and
        # actively misleading. CHECK instead of asserting — the route can always be
        # commented out again, and a switch that silently leaves nothing serving is exactly
        # what that warning existed to prevent.
        if kubectl -n litellm get cm litellm-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
             | grep -qF "model_name: thor/qwen3.6-35b-a3b-nvfp4"; then
            echo "  LiteLLM 'thor/qwen3.6-35b-a3b-nvfp4' route: present"
        else
            echo "⚠ LiteLLM's 'thor/qwen3.6-35b-a3b-nvfp4' route is NOT in the deployed config — add it in"
            echo "  deployment/argocd-apps/litellm/config.yaml, or vLLM will serve nothing."
        fi
        ;;
    ollama)
        scale_down_and_wait vllm
        scale_up ollama
        # ollama-thor owns the GPU: `coder` cannot answer, so keep it out of the picker.
        set_webui_model_visibility thor/qwen3.6-35b-a3b-nvfp4 false
        # No model warm-up here, and no model ref: the catalogue lives in
        # deployment/argocd-apps/ollama/prepull-models.yaml and its PostSync Job pulls it.
        # Ollama also pulls lazily on first request.
        echo "LiteLLM route 'coder-ollama' is live."
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 vllm|ollama|status"
        exit 1
        ;;
esac
