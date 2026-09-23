#!/usr/bin/env bash

set -euo pipefail

# Tune the fused-MoE kernel configs for the model vLLM currently serves on the Thor.
#   ./optimizeModel.sh status    # is a tuned config present, and is it in use?
#   ./optimizeModel.sh tune      # run the tuning (TAKES THE MODEL DOWN)
#   ./optimizeModel.sh collect   # copy a finished config out of the NFS store
#
# WHAT THIS TUNES. vLLM picks fused-MoE kernel parameters (block sizes, warps, stages)
# from a per-device JSON table shipped in the wheel. It has one for each GPU upstream
# tuned on, and the Thor is not among them, so the engine logs
#   Using default MoE config. Performance might be sub-optimal!
# and falls back to generic defaults. Tuning searches the parameter space on the real
# device and writes the table vLLM was looking for.
#
# The filename is derived, never chosen: E is the expert count and N the shard
# intermediate size, both read from the model config at load time, and the device name
# comes from the driver. Serving Qwen3.6-35B-A3B at TP=1 on a Thor asks for
#   E=256,N=512,device_name=NVIDIA_Thor.json
# Change the model or the tensor-parallel size and it is a different file, so a tuned
# config does NOT carry across a model swap.
#
# ⚠ THIS TAKES THE MODEL DOWN. The Thor has ONE non-shareable GPU, held by the serving
# vLLM pod, and the benchmark needs it exclusively. Everything that talks to
# `thor/qwen3.6-35b-a3b-nvfp4` — the eda-pcb-agent, Open WebUI, LiteLLM callers — is
# unavailable from `tune` until the pod is back.
#
# ⚠ BUDGET THE RUN BEFORE STARTING IT, because there is NO partial result. The script
# searches ~1920 configurations PER BATCH SIZE and calls save_configs() exactly once,
# after the last one finishes — so a run that is killed, or that overruns the window it
# had, writes nothing at all and the whole downtime is wasted. Measured on the Thor:
# roughly 30-45 min per batch size, so upstream's default list of 18 (1 … 4096) is a
# 9-14 hour job.
#
# BATCH_SIZES therefore trims that list rather than taking the default. The large
# entries cost the most and buy the least here: this deployment serves a handful of
# agent sessions, not a high-concurrency endpoint, so anything past a few hundred
# concurrent tokens-in-flight is tuning for traffic that never arrives. Widen it only
# if the serving profile actually changes, and budget the extra passes.
#
# ⚠ ArgoCD auto-sync MUST be suspended for the duration, and this script does that
# itself. ignoreDifferences on /spec/replicas keeps selfHeal from re-scaling the
# Deployment, but it does NOT stop an ordinary sync from recreating the pod — and a
# recreated pod takes the GPU back, after which the tuning Job sits Pending forever with
# no error that names the cause. The script restores the previous syncPolicy on exit,
# including on Ctrl-C.
#
# ⚠ That restore-on-exit is right for tuning and WRONG for the A/B that follows it. Once
# auto-sync is back, selfHeal reverts any `kubectl patch` on the Deployment within
# minutes — so an experiment that removes the tuned-config mount to measure the untuned
# baseline silently gets the mount back, rolls a fresh pod, and measures the TUNED
# configuration while looking like it measured the control. Suspend auto-sync again
# around any such comparison, and gate the measurement on evidence from the pod itself
# (here: the `Using default MoE config` warning MUST be present for an untuned control)
# rather than on having issued the patch.
#
# The tuning runs in the SERVING IMAGE on purpose. The config it produces is keyed to the
# exact vLLM/torch/triton build that will consume it, so tuning in a different image
# would tune the wrong kernels. The image carries ray and curl for this (Dockerfile,
# "Kernel-tuning toolchain") — ray because benchmark_moe.py dispatches every measurement
# through @ray.remote, curl to fetch the benchmark script matching the installed vLLM.

NS=vllm
DEPLOY=vllm
# Trimmed from upstream's 18-entry default (… 1024 2048 4096) — see the budget note above.
BATCH_SIZES="1 2 4 8 16 32 64 128 256"
JOB=vllm-moe-tune
APP_NS=argocd-apps
NODE=unibi-hclab-thor-eval
# Written to the shared ai-models NFS store rather than the pod: a tuned config is
# expensive to produce and must outlive the Job, the pod and the cluster.
OUT_SUBDIR=moe-configs

die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }

# The serving pod is the only authority for what is actually running: the Deployment spec
# can differ from the live process (a hand-scaled replica, a mid-rollout pod), and the
# tuned config has to match the process.
serving_pod() {
    kubectl -n "$NS" get pods -l app="$DEPLOY" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep . || true
}

# Read the config filename from the engine log rather than reconstructing it. vLLM prints
# the exact path it failed to find, which spares us re-deriving E and N from the model
# config and getting it subtly wrong.
wanted_config() {
    local pod="$1"
    kubectl -n "$NS" logs "$pod" -c vllm 2>/dev/null \
        | grep -oE '[^ /]+\.json' \
        | grep -E '^E=[0-9]+,N=[0-9]+,device_name=' \
        | tail -1 || true
}

# The model the pod was STARTED with, read from its argv. The Deployment manifest is the
# wrong source here for the same reason as above.
serving_model() {
    local pod="$1"
    kubectl -n "$NS" exec "$pod" -c vllm -- \
        sh -c 'tr "\0" "\n" < /proc/1/cmdline' 2>/dev/null \
        | sed -n '/^serve$/{n;p;}' | head -1 || true
}

serving_image() {
    kubectl -n "$NS" get deploy "$DEPLOY" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

# A Job reports succeeded/failed as ABSENT fields while it runs, so jsonpath yields empty
# strings and a naive read prints " succeeded /  failed" for a healthy in-flight run.
job_status() {
    kubectl -n "$NS" get job "$JOB" >/dev/null 2>&1 || { echo "none"; return; }
    if [ "$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
        echo "succeeded"
    elif [ "$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)" = "1" ]; then
        echo "FAILED"
    else
        echo "running (started $(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.startTime}' 2>/dev/null))"
    fi
}

status() {
    local pod cfg model
    pod=$(serving_pod)
    if [ -z "$pod" ]; then
        echo "vllm: no Running pod (scaled to 0, or mid-rollout)"
    else
        model=$(serving_model "$pod")
        echo "vllm pod:   $pod"
        echo "model:      ${model:-<could not read argv>}"
        cfg=$(wanted_config "$pod")
        if [ -n "$cfg" ]; then
            echo "MoE config: MISSING — engine asked for $cfg and fell back to defaults"
        else
            # No warning in the log means the engine found a config for this device. It
            # is not proof one was tuned HERE: the wheel may simply ship a matching one.
            echo "MoE config: in use (no 'default MoE config' warning in the engine log)"
        fi
    fi
    echo ""
    echo "tuning job: $(job_status)"
}

# Suspend ArgoCD auto-sync, remembering the previous policy so it can be put back
# EXACTLY as it was. Restoring a hardcoded policy instead would silently rewrite whatever
# the Application actually had.
SAVED_POLICY=""
POLICY_SUSPENDED=0
suspend_autosync() {
    SAVED_POLICY=$(kubectl -n "$APP_NS" get app "$DEPLOY" \
        -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
    if [ -z "$SAVED_POLICY" ]; then
        echo "ArgoCD auto-sync already off — leaving it alone."
        return
    fi
    echo "Suspending ArgoCD auto-sync (was: $SAVED_POLICY)"
    kubectl -n "$APP_NS" patch app "$DEPLOY" --type merge \
        -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
    POLICY_SUSPENDED=1
}

restore_autosync() {
    [ "$POLICY_SUSPENDED" = "1" ] || return 0
    echo "Restoring ArgoCD auto-sync..."
    kubectl -n "$APP_NS" patch app "$DEPLOY" --type merge \
        -p "{\"spec\":{\"syncPolicy\":{\"automated\":$SAVED_POLICY}}}" >/dev/null \
        && POLICY_SUSPENDED=0
}

# Bring the model back and undo the auto-sync change whatever happens — a failed tune
# that leaves the service down and ArgoCD suspended is worse than no tune at all.
RESTORE_REPLICAS=0
cleanup() {
    local rc=$?
    if [ "$RESTORE_REPLICAS" = "1" ]; then
        echo ""
        echo "Restoring vllm to 1 replica..."
        kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=1 >/dev/null 2>&1 || true
    fi
    restore_autosync
    exit $rc
}

tune() {
    need kubectl
    local pod image model cfg
    pod=$(serving_pod)
    [ -n "$pod" ] || die "no Running vllm pod — start the service before tuning, the script reads the model and target config from it"

    model=$(serving_model "$pod")
    [ -n "$model" ] || die "could not read the served model from the pod's argv"
    cfg=$(wanted_config "$pod")
    image=$(serving_image)

    echo "model:  $model"
    echo "image:  $image"
    if [ -n "$cfg" ]; then
        echo "target: $cfg"
    else
        echo "target: (engine reported no missing config — tuning may not help)"
    fi
    echo ""
    echo "batch sizes: $BATCH_SIZES"
    echo ""
    echo "⚠ This takes the model DOWN for the whole run (hours), and writes NOTHING"
    echo "  until the last batch size completes — an interrupted run wastes the downtime."
    printf "Type 'yes' to continue: "
    read -r reply
    [ "$reply" = "yes" ] || { echo "Aborted."; exit 1; }

    trap cleanup EXIT INT TERM

    suspend_autosync

    echo "Scaling vllm to 0 to free the GPU..."
    RESTORE_REPLICAS=1
    kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
    while kubectl -n "$NS" get pods -l app="$DEPLOY" --no-headers 2>/dev/null | grep -q .; do
        sleep 5
    done
    echo "GPU free at $(date '+%H:%M:%S %Z')"

    kubectl -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null

    # The benchmark script is fetched at run time for the vLLM version actually
    # installed, not vendored: it imports a dozen private symbols from vllm.* and a
    # version-mismatched copy fails on import, or worse, tunes against a different
    # kernel signature than the one that will run.
    kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      runtimeClassName: nvidia
      nodeSelector:
        kubernetes.io/hostname: $NODE
      tolerations:
        - { key: ecc/mesh, operator: Equal, value: "true", effect: NoSchedule }
        - { key: ecc/gpu,  operator: Equal, value: "true", effect: NoSchedule }
      imagePullSecrets:
        - name: vllm-registry-cred
      volumes:
        - name: model-cache
          persistentVolumeClaim: { claimName: vllm-model-cache }
        - name: out
          persistentVolumeClaim: { claimName: nfs-ai-models }
        - name: dshm
          emptyDir: { medium: Memory, sizeLimit: 8Gi }
      containers:
        - name: tune
          image: $image
          resources:
            limits: { nvidia.com/gpu: 1 }
          env:
            - { name: HF_HOME,        value: /models/hf }
            - { name: HF_HUB_OFFLINE, value: "1" }
          volumeMounts:
            - { name: model-cache, mountPath: /models }
            - { name: out,         mountPath: /out }
            - { name: dshm,        mountPath: /dev/shm }
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -euo pipefail
              echo "=== MoE tune \$(date -u '+%F %T UTC') ==="
              nvidia-smi --query-gpu=name --format=csv,noheader
              V=\$(python3 -c 'import vllm; print(vllm.__version__)')
              echo "vllm \$V"
              curl -sSfL -o /tmp/benchmark_moe.py \
                "https://raw.githubusercontent.com/vllm-project/vllm/v\${V}/benchmarks/kernels/benchmark_moe.py"
              mkdir -p /out/$OUT_SUBDIR
              python3 /tmp/benchmark_moe.py \
                --model "$model" \
                --tp-size 1 \
                --dtype auto \
                --trust-remote-code \
                --tune \
                --batch-size $BATCH_SIZES \
                --save-dir /out/$OUT_SUBDIR
              echo "=== done \$(date -u '+%F %T UTC') ==="
              ls -la /out/$OUT_SUBDIR/
YAML

    echo "Tuning Job started. Follow it with:"
    echo "  kubectl -n $NS logs -f job/$JOB"
    echo ""
    # Said here because it looks exactly like a hang, and the obvious check agrees.
    echo "NOTE: the progress bar stalls for minutes at a time and the GPU reads ~0% while"
    echo "      it does. That is Triton JIT-compiling the next kernel variant, which is"
    echo "      CPU-bound. To tell a real hang apart, look for the ray::BenchmarkW process"
    echo "      in state R burning CPU and still holding GPU memory:"
    echo "        kubectl -n $NS exec job/$JOB -- ps -eo pid,stat,pcpu,comm --sort=-pcpu | head -3"
    echo "        kubectl -n $NS exec job/$JOB -- nvidia-smi --query-compute-apps=pid,used_memory --format=csv"
    echo ""
    echo "Waiting for completion (hours) — Ctrl-C restores the service without waiting."
    while true; do
        if [ "$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
            echo "Tuning SUCCEEDED at $(date '+%H:%M:%S %Z')"
            kubectl -n "$NS" logs job/"$JOB" 2>/dev/null | tail -5
            break
        fi
        if [ "$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)" = "1" ]; then
            echo "Tuning FAILED at $(date '+%H:%M:%S %Z') — last log lines:"
            kubectl -n "$NS" logs job/"$JOB" 2>/dev/null | tail -20
            break
        fi
        sleep 60
    done

    echo ""
    echo "Next: './optimizeModel.sh collect' to retrieve the config."
    echo "It must then be baked into the image — the wheel only reads configs from"
    echo "vllm/model_executor/layers/fused_moe/configs/ inside site-packages."
}

# Read the results out of the NFS store. The serving pod mounts that PVC read-only, so a
# short-lived pod is the way in when vllm is down.
#
# ⚠ The reader MUST be pinned to the Thor and carry the mesh/gpu tolerations, even though
# it wants no GPU and could run anywhere. csi-driver-nfs only runs its node plugin on the
# LAN nodes, so a reader scheduled onto a cloud node never mounts: it sits in
# ContainerCreating until the wait times out, and the only line naming the cause is a
# FailedMount event saying `driver name nfs.csi.k8s.io not found in the list of registered
# CSI drivers` — which reads like a broken driver rather than a misplaced pod.
collect() {
    need kubectl
    local dest="${1:-./moe-configs}"
    mkdir -p "$dest"
    echo "Listing $OUT_SUBDIR in the ai-models store..."
    kubectl -n "$NS" delete pod moe-config-reader --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: moe-config-reader
  namespace: $NS
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $NODE
  tolerations:
    - { key: ecc/mesh, operator: Equal, value: "true", effect: NoSchedule }
    - { key: ecc/gpu,  operator: Equal, value: "true", effect: NoSchedule }
  volumes:
    - name: out
      persistentVolumeClaim: { claimName: nfs-ai-models }
  containers:
    - name: moe-config-reader
      image: busybox:1.36
      command: ["sleep", "300"]
      volumeMounts:
        - { name: out, mountPath: /out }
YAML
    # Generous timeout: this pulls busybox onto a LAN node over the mesh link on a cold
    # cache, which is slow enough to trip a 120s wait even when everything is correct.
    if ! kubectl -n "$NS" wait --for=condition=Ready pod/moe-config-reader --timeout=300s >/dev/null; then
        echo "reader pod never became Ready — recent events:" >&2
        kubectl -n "$NS" describe pod moe-config-reader 2>/dev/null | sed -n '/Events:/,$p' | tail -10 >&2
        kubectl -n "$NS" delete pod moe-config-reader --wait=false >/dev/null 2>&1 || true
        die "could not read the ai-models store"
    fi
    kubectl -n "$NS" exec moe-config-reader -- ls -la "/out/$OUT_SUBDIR" || true
    for f in $(kubectl -n "$NS" exec moe-config-reader -- sh -c "ls /out/$OUT_SUBDIR/*.json 2>/dev/null" || true); do
        echo "fetching $(basename "$f")"
        kubectl -n "$NS" exec moe-config-reader -- cat "$f" > "$dest/$(basename "$f")"
    done
    kubectl -n "$NS" delete pod moe-config-reader --wait=false >/dev/null 2>&1 || true
    # An empty dest means the tuning never wrote anything; saying "Saved" there would
    # report success for a run that produced nothing.
    if ! ls "$dest"/*.json >/dev/null 2>&1; then
        die "no .json configs found in the store — has a tuning run finished?"
    fi
    echo "Saved to $dest:"
    ls -la "$dest"
}

case "${1:-status}" in
    status)  status ;;
    tune)    tune ;;
    collect) collect "${2:-}" ;;
    *) echo "usage: $0 [status|tune|collect [dest-dir]]" >&2; exit 1 ;;
esac
