# Ollama (GGUF serving, exclusive with vLLM)

OpenAI-compatible llama.cpp/GGUF server on the Jetson-Thor GPU node, serving the
GGUF twin of the vLLM model (`hf.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-IQ3_XXS`).
In-cluster only; LiteLLM exposes it as `coder-ollama`.

## Exclusive with vLLM

One Thor GPU + ~117 GiB GPU-visible unified memory ⇒ only ONE backend runs at a time.
This Deployment ships `replicas: 1` and owns the Thor GPU. vLLM is DISABLED
(`app-of-apps/vllm.yaml.disable`), so there is nothing to be exclusive with today.

Switch at runtime — but note `vllm` cannot succeed today (see the ⚠ below):

```bash
scripts/runtime/switchLLMBackend.sh status   # which backend is up
scripts/runtime/switchLLMBackend.sh ollama   # vLLM down → Ollama up
scripts/runtime/switchLLMBackend.sh vllm     # refuses: vllm has no Deployment

# THOR ONLY. The discrete-GPU node (smartmirror1) runs the separate `ollama-turing`
# app, where pods hold real nvidia.com/gpu allocations so the SCHEDULER enforces one
# pod per card — nothing to switch there.
```

The script scales the outgoing Deployment to 0, waits for its pod to release the
GPU, then scales the incoming one to 1. ArgoCD ignores `/spec/replicas` on both
Deployments (see `app-of-apps/ollama.yaml` / `app-of-apps/vllm.yaml.disable`), so
the switch survives selfHeal.

⚠ **vLLM is currently DISABLED** (`app-of-apps/vllm.yaml.disable`): it sat at
`replicas: 0` by design while ollama-thor holds the GPU, which ArgoCD reports as
Progressing forever. Re-enable it (`git mv` back, sync) before switching to it —
the header of that file has the procedure.

## Model

Pulled by the `prepull-models.yaml` PostSync Job onto a node-local `local-path` PVC — not
lazily, and not by the switch script (which no longer warms any model). The declared
catalogue is three models, ~70 GB total, the largest single pull being ~38 GB — expect a
long warm-up over WireGuard on a fresh node. `OLLAMA_KEEP_ALIVE=-1` keeps a loaded model
resident, bounded by `OLLAMA_MAX_LOADED_MODELS=2`.

LiteLLM routes `coder-ollama` → `http://ollama.ollama.svc:11434/v1`, model name
`hf.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-IQ3_XXS` (Ollama treats the hf.co ref
as the model id and auto-pulls it).

## Image build (ollama v0.32.1 on Thor)

The prebuilt `ghcr.io/nvidia-ai-iot/ollama` image is ollama **v0.11.6**, whose engine
can't load the target model's `qwen35moe` arch (`unknown model architecture`). So the
image is **built on-node by GitLab CI** (like vLLM): `Dockerfile` rebuilds ollama
v0.32.1 FROM the jetson base (which already has the CUDA-13 toolchain), fixing three
gaps — Go 1.26, gcc-14 (for the `sme` ARM CPU feature), and
`-DOLLAMA_LLAMA_BACKENDS=cuda_v13` (the CUDA backend is off by default in v0.32.1).

Pipeline (mirrors vLLM): `.gitlab-ci.yml` (buildah, `tags:[thor]`, internal-registry
push) + `postsync-build-image.yaml` (PreSync: mirror build files into GitLab + trigger)
+ `build-files-configmap.yaml` + `presync-registry-cred.yaml` (PreSync pull secret,
shared `deployments`-group deploy token). Bump `OLLAMA_VERSION` (Dockerfile) + the
matching `IMAGE_TAG`/`image:` tag to rebuild. First build takes ~1-2h on the Thor.

Verified in-pod (2026-07-16): v0.32.1 build detects the GPU (`library=CUDA "NVIDIA
Thor" cuda_v13`, ~58 GiB available) and runs `hf.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-IQ3_XXS`
at `100% GPU`.
