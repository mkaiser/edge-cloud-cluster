# vLLM 0.24.0 for the Jetson Thor (Blackwell, sm_110 / arch 11.0), L4T R38 / JetPack 7 /
# CUDA 13.0 (verified on ecc/gpu-model=jetson-thor). Public dustynv/vllm images are
# JetPack-6/CUDA-12.8 and do NOT run here; nvcr.io/nvidia/vllm needs NGC auth —
# so we build our own image and push to registry.gitlab.<tld>.
#
# STRATEGY (r17, CHANGED from r16): install the RELEASED vLLM 0.24.0 abi3 aarch64
# wheel straight from PyPI, paired with the OFFICIAL cu130 PyTorch build from
# download.pytorch.org/whl/cu130. Proven on-node by a Step-0 spike:
# the official SBSA cu130 torch 2.11.0 DRIVES the Thor Tegra iGPU (torch.cuda works,
# engine builds KV cache, generates correctly) — so no source build, and no
# jetson-ai-lab index needed. vLLM's abi3 wheel is Python-version-agnostic
# (cp38-abi3 runs on our cp312). We do NOT use the vLLM nightly index: its dev
# wheels rotate and 404 within hours (unreproducible) — the PyPI RELEASE is stable.
#
# Base carries the CUDA runtime/toolkit — the `nvidia` RuntimeClass injects the
# driver + runtime libs at serve time, but the image must carry CUDA itself.
# arm64 tag confirmed on Docker Hub. Fully-qualified registry (docker.io/) is
# REQUIRED: buildah enforces short-name resolution and can't prompt without a TTY
# in CI ("short-name resolution enforced" otherwise).
#
# CUDA VERSION MUST MATCH THE JETPACK DRIVER — pin the toolkit MINOR to the driver's.
# The Thor runs L4T R38.4.0 (JetPack 7 GA), whose driver's max CUDA API is 13.0. A
# 13.3 base runtime overshoots it and `vllm serve` dies at GPU init with
# `cudaGetDeviceCount() ... Error 803: system has unsupported display driver / cuda
# driver combination` (= cudaErrorSystemDriverMismatch — runtime newer than driver).
# 13.0 also matches the cu130 torch/vllm wheels, so base, torch, and driver all
# align on 13.0. Bump the minor only when JetPack on the node is upgraded
# (nvidia-smi "CUDA Version" on the node = the ceiling).
# renovate: managed by the "Container image tags" regex manager (docker datasource)
FROM docker.io/nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04

# Released vLLM version. 0.24.0 was the first release supporting the target model's
# arch `Qwen3_5MoeForConditionalGeneration` + its `modelopt` NVFP4 quant.
#
# BUMPED 0.24.0 -> 0.27.1 to chase NATIVE FP4 on Thor. On 0.24.0 the pod
# logged `Using 'MARLIN' NvFp4 MoE backend` + "Your GPU does not have native support for
# FP4 computation", i.e. weight-only Marlin EMULATION — measured 9.6 tok/s single-stream
# vs Ollama's 34.6 on the same base model (doc/llm-performance.md).
#
# Upstream now includes sm_110 in the native CUTLASS FP4 path. Two gates, both read from
# the source: the runtime check is
#   `cuda_device_capability >= 100 && < 120`  (csrc/.../nvfp4_scaled_mm_entry.cu)
# which 110 satisfies, and the build gate compiles those kernels for
#   FP4_SM100_ARCHS = "10.0f;10.7f;11.0f"    (CMakeLists.txt, CUDA >= 13.0)
# where `11.0f` IS Thor. The CMake comment says "SM10x/11x FP4 kernels" outright.
#
# ⚠ CAVEAT: we install a PREBUILT WHEEL, so whether those kernels are actually compiled
# in is upstream's build decision, not ours — the CMake above is evidence of intent, not
# proof for this wheel. VERIFY IN-POD after the build: if the "MARLIN"/"does not have
# native support" lines are GONE from the pod log, it worked; if they persist, the wheel
# lacks the sm_110 kernels and only a source build would fix it. Re-run the concurrency
# benchmark either way, because the whole point was the single-stream gap.
# renovate: datasource=pypi depName=vllm
ARG VLLM_VERSION=0.29.0
# TORCH — the ABI-critical pin. vLLM 0.24.0's abi3 wheel declares torch==2.11.0 and
# its kernels (via the `humming-kernels` pkg, see below) link that libtorch ABI.
# Install it from the OFFICIAL cu130 index (NOT the jetson index used pre-r17): the
# spike proved this SBSA cu130 build runs on Thor's Tegra iGPU, and it is the build
# vLLM's wheel was compiled against. Install torch FIRST so the vllm install can't
# swap it for PyPI's default (cu128) 2.11.0 — a different-CUDA same-version torch is
# the classic `undefined symbol` ABI trap. The `+cu130` local tag is on the torch
# wheel; assert it after install. Bump together with VLLM_VERSION.
# renovate: datasource=pypi depName=torch registryUrl=https://download.pytorch.org/whl/cu130/
# ⚠ MUST match what the vLLM wheel declares, or `vllm serve` dies on an undefined
# symbol (the _C ABI mismatch).
# vllm 0.24.0 declared torch==2.11.0; 0.27.1 declares torch==2.13.0 — verified from the
# PyPI metadata, and torch-2.13.0+cu130 manylinux_2_28_aarch64 exists on the official
# cu130 index. The assertion further down enforces the pairing at build time.
ARG TORCH_VERSION=2.13.0
# OFFICIAL cu130 PyTorch wheel index (SBSA/aarch64). torch lives here; everything
# else (vllm + its deps: humming-kernels, triton, compressed-tensors, xgrammar,
# flashinfer, transformers, …) resolves from PyPI.
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
ENV DEBIAN_FRONTEND=noninteractive \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH}

# Shared-library runtime deps the cu130 aarch64 torch wheel links but the
# nvidia/cuda base image (NOT JetPack) lacks. Without them `import torch` dies at
# runtime with `<lib>: cannot open shared object file`. Determined authoritatively by
# `ldd` over torch/lib/*.so in the built image (carried over from r16, same base):
#   - NVPL LAPACK/BLAS  -> libnvpl-lapack0 libnvpl-blas0  (libnvpl_lapack_lp64_gomp.so.0)
#   - cuDSS (sparse solver) -> libcudss0-cuda-13          (libcudss.so.0)
# (ldd also flags libcuda.so.1, but that's the DRIVER stub injected at runtime by the
# nvidia container runtime / CDI — never shipped in the image, so not installed here.)
# All from the CUDA apt repo the base already trusts; -dev not needed (runtime only);
# unpinned — apt resolves the in-repo version matching the base image's CUDA repo.
# NOTE: these gaps did NOT surface in the build's import guards because CI builds on
# the Thor HOST where the host libs leak into the buildah chroot; only the isolated
# runtime pod exposes them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python3-dev \
        libopenblas-dev libnuma1 \
        libnvpl-lapack0 libnvpl-blas0 \
        libcudss0-cuda-13 \
    && rm -rf /var/lib/apt/lists/* \
    # cuDSS installs to a VERSIONED subdir NOT on the default linker path
    # (/usr/lib/aarch64-linux-gnu/libcudss/13/), so `import torch` still can't find
    # libcudss.so.0 after the apt install. NVPL lands in the standard multiarch dir
    # and needs no help; cuDSS does. Register the dir with ld.so + refresh the cache.
    && echo "/usr/lib/aarch64-linux-gnu/libcudss/13" > /etc/ld.so.conf.d/cudss.conf \
    && ldconfig

# Isolated venv (Ubuntu 24.04 is PEP-668 externally-managed).
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install -U pip setuptools wheel

# Install torch FIRST from the official cu130 index (pins the ABI), then the vLLM
# 0.24.0 wheel — letting it pull its OWN dependency set from PyPI.
#
# WHY NOT PIN vllm's sub-deps (triton/xgrammar/compressed-tensors): unlike r16
# (jetson index that omitted them), the PyPI vllm 0.24.0 wheel declares them
# exactly — `compressed-tensors==0.17.0`, `humming-kernels[cu13]==0.1.6`, an
# unpinned triton (resolves to 3.6.0), xgrammar, flashinfer. Pinning a stale
# `triton==3.5.0` (the r16 value) makes pip ResolutionImpossible against 0.24. So we
# name ONLY the wheel and let it resolve; all cu13 nvidia-* sub-deps have aarch64
# wheels on PyPI. `--extra-index-url` cu130 keeps torch satisfied at 2.11.0+cu130
# (already installed) and lets any cuda-13 nvidia-* wheels resolve.
#
# NOTE ON `_C`: vLLM 0.24 has NO bundled `vllm._C` extension — CUDA kernels moved to
# the separate `humming-kernels` pkg (+ triton). So the r16 build-guard
# `import vllm._C` is GONE (it would ModuleNotFoundError = false failure). The guard
# below instead imports `vllm`, the OpenAI api_server, and compressed_tensors — the
# actual serving path — which fails the BUILD on a real ABI/so break.
#
# Flaky-network hardening (the Thor joins over WireGuard; the link can trickle):
# vLLM's dependency tree is multi-GB (torch, flashinfer-cubin, etc.). KEEP pip's HTTP
# cache (no --no-cache-dir) so a killed/retried attempt reuses already-downloaded
# wheels; CI bind-mounts /root/.cache/pip from a node-local hostPath (see
# .gitlab-ci.yml) so it also survives ACROSS builds. Generous per-attempt wall cap
# (2h) under the job's 3h timeout; pip's --retries/--timeout/--resume-retries handle
# transient resets. `timeout` is the outer guard against a dead-socket hang.
RUN retry() { for i in 1 2; do timeout 7200 "$@" && return 0; \
        echo "attempt $i failed/stalled (rc=$?), retrying in 30s..."; sleep 30; done; return 1; } \
    && retry pip install --resume-retries 10 --retries 10 --timeout 120 \
        --index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" \
    && retry pip install --resume-retries 10 --retries 10 --timeout 120 \
        --extra-index-url "${TORCH_INDEX}" \
        "vllm==${VLLM_VERSION}" \
    # Fail the build if resolving vllm silently bumped torch off the +cu130 pin
    # (would reintroduce an ABI mismatch at `vllm serve`). The +cu130 local tag IS
    # present on the official torch wheel — assert both the version and the cuda build.
    && python -c "import torch,sys; v=torch.__version__; cu=torch.version.cuda; \
        ok = v=='${TORCH_VERSION}+cu130' and cu and cu.startswith('13'); \
        sys.exit(0) if ok else (print(f'ERROR: torch {v} cuda {cu} != ${TORCH_VERSION}+cu130 (vllm resolution changed it)') or sys.exit(1))"

# Build-time verification. A heredoc'd script (NOT an inline `python -c`) so the logic
# is readable and the shell quoting stays sane. It:
#  - asserts torch is a CUDA build (torch.version.cuda set);
#  - force-imports vllm, the OpenAI api_server, and compressed_tensors — the serving
#    path — so a torch/vllm ABI break (`undefined symbol`) or a genuinely missing
#    image .so (NVPL/cuDSS) FAILS the build.
# It tolerates EXACTLY ONE gap: `libcuda.so.1`, the NVIDIA DRIVER stub. That is injected
# into the container at RUN time by the nvidia runtime / CDI and is (correctly) not in
# the image; CI also builds in a chroot where the host driver doesn't leak in, so the
# imports may hit `libcuda.so.1: cannot open shared object file` at build time even on
# a perfect image. Any OTHER ImportError still fails. (A green build is
# necessary-not-sufficient — the isolated runtime pod remains the final proof.)
# NOTE: vLLM 0.24 has no `vllm._C` — do NOT re-add that guard (see the install note).
RUN cat > /tmp/verify.py <<'PY' \
 && python /tmp/verify.py \
 && rm -f /tmp/verify.py
import sys, importlib
import torch
assert torch.version.cuda, f"torch has no CUDA (cpu-only build?): {torch.__version__}"
print("torch", torch.__version__, "cuda", torch.version.cuda)

def guard(name, fn):
    try:
        fn()
        print(name, "OK")
    except ImportError as e:
        if "libcuda.so.1" in str(e):
            print(name, "- libcuda.so.1 absent at build (driver injected at runtime), OK")
        else:
            print(name, "FAILED:", e)
            sys.exit(1)

guard("server-import", lambda: (
    importlib.import_module("vllm"),
    importlib.import_module("vllm.entrypoints.openai.api_server"),
))
# Quantized serving deps — a missing compressed_tensors only surfaces at model load
# (get_quantization_config), so assert it at build time too.
guard("compressed_tensors", lambda: importlib.import_module("compressed_tensors"))
print("vllm", importlib.import_module("vllm").__version__, "verify OK")
PY
# NOTE: no `pip cache purge` here. The pip cache lives at /root/.cache/pip, which CI
# bind-mounts from a persistent node-local hostPath (`buildah bud -v`, see
# .gitlab-ci.yml) so it survives ACROSS builds and lets rebuilds skip the slow
# origin. It is a build-time mount only — NOT committed to any image layer — so
# there's nothing to purge for image size, and purging would instead wipe the shared
# persistent cache mid-build. (Without the CI `-v`, the cache is just an ordinary
# in-build dir that vanishes with the build container — still no bloat.)

# ── Hermes tool-call chat template ────────────────────────────────────────────
# vLLM's examples/tool_chat_template_hermes.jinja, vendored so tool_choice:"auto"
# makes the model emit <tool_call> tags that the --tool-call-parser hermes parser can
# parse. RE-VALIDATE for the new model: nvidia/Qwen3.6-35B-A3B-NVFP4 is a Qwen3.5 MoE
# REASONING model and may work with its OWN chat_template + the qwen3 tool parser and
# NOT need this Hermes override — the Deployment chooses whether to pass
# --chat-template. Kept baked in so either path is available without an image rebuild.
# Embedded via a single-quoted heredoc (no shell/jinja expansion) because CI mirrors
# ONLY this Dockerfile + .gitlab-ci.yml into GitLab — a COPY of a sibling file has no
# build context.
RUN mkdir -p /etc/vllm && cat > /etc/vllm/tool_chat_template_hermes.jinja <<'HERMES_TEMPLATE_EOF'
{%- macro json_to_python_type(json_spec) %}
    {%- set basic_type_map = {
    "string": "str",
    "number": "float",
    "integer": "int",
    "boolean": "bool"
} %}

    {%- if basic_type_map[json_spec.type] is defined %}
        {{- basic_type_map[json_spec.type] }}
    {%- elif json_spec.type == "array" %}
        {{- "list[" +  json_to_python_type(json_spec|items) + "]" }}
    {%- elif json_spec.type == "object" %}
        {%- if json_spec.additionalProperties is defined %}
            {{- "dict[str, " + json_to_python_type(json_spec.additionalProperties) + ']' }}
        {%- else %}
            {{- "dict" }}
        {%- endif %}
    {%- elif json_spec.type is iterable %}
        {{- "Union[" }}
        {%- for t in json_spec.type %}
            {{- json_to_python_type({"type": t}) }}
            {%- if not loop.last %}
                {{- "," }}
            {%- endif %}
        {%- endfor %}
        {{- "]" }}
    {%- else %}
        {{- "Any" }}
    {%- endif %}
{%- endmacro %}


{{- bos_token }}
{{- "<|im_start|>system\nYou are a function calling AI model. You are provided with function signatures within <tools></tools> XML tags. You may call one or more functions to assist with the user query. Don't make assumptions about what values to plug into functions. Here are the available tools: <tools> " }}
{%- if tools is iterable and tools | length > 0 %}
    {%- for tool in tools %}
        {%- if tool.function is defined %}
            {%- set tool = tool.function %}
        {%- endif %}
        {{- '{"type": "function", "function": ' }}
        {{- '{"name": "' + tool.name + '", ' }}
        {{- '"description": "' + tool.name + '(' }}
        {%- for param_name, param_fields in tool.parameters.properties|items %}
            {{- param_name + ": " + json_to_python_type(param_fields) }}
            {%- if not loop.last %}
                {{- ", " }}
            {%- endif %}
        {%- endfor %}
        {{- ")" }}
        {%- if tool.return is defined %}
            {{- " -> " + json_to_python_type(tool.return) }}
        {%- endif %}
        {{- " - " + tool.description + "\n\n" }}
        {%- for param_name, param_fields in tool.parameters.properties|items %}
            {%- if loop.first %}
                {{- "    Args:\n" }}
            {%- endif %}
            {{- "        " + param_name + "(" + json_to_python_type(param_fields) + "): " + param_fields.description|trim }}
        {%- endfor %}
        {%- if tool.return is defined and tool.return.description is defined %}
            {{- "\n    Returns:\n        " + tool.return.description }}
        {%- endif %}
        {{- '"' }}
        {{- ', "parameters": ' }}
        {%- if tool.parameters.properties | length == 0 %}
            {{- "{}" }}
        {%- else %}
            {{- tool.parameters|tojson }}
        {%- endif %}
        {{- "}" }}
        {%- if not loop.last %}
            {{- "\n" }}
        {%- endif %}
    {%- endfor %}
{%- endif %}
{{- " </tools>" }}
{{- 'Use the following pydantic model json schema for each tool call you will make: {"properties": {"name": {"title": "Name", "type": "string"}, "arguments": {"title": "Arguments", "type": "object"}}, "required": ["name", "arguments"], "title": "FunctionCall", "type": "object"}}
' }}
{{- "For each function call return a json object with function name and arguments within <tool_call></tool_call> XML tags as follows:
" }}
{{- "<tool_call>
" }}
{{- '{"name": <function-name>, "arguments": <args-dict>}
' }}
{{- '</tool_call><|im_end|>' }}
{%- for message in messages %}
    {%- if message.role == "user" or message.role == "system" or (message.role == "assistant" and message.tool_calls is not defined) %}
        {{- '<|im_start|>' + message.role + '\n' + message.content + '<|im_end|>' + '\n' }}
    {%- elif message.role == "assistant" and message.tool_calls is defined %}
        {{- '<|im_start|>' + message.role }}
        {%- for tool_call in message.tool_calls %}
            {{- '\n<tool_call>\n' }}
            {%- if tool_call.function is defined %}
                {%- set tool_call = tool_call.function %}
            {%- endif %}
            {{- '{' }}
            {{- '"name": "' }}
            {{- tool_call.name }}
            {{- '"' }}
            {%- if tool_call.arguments is defined %}
                {{- ', ' }}
                {{- '"arguments": ' }}
                {{- tool_call.arguments|tojson }}
            {%- endif %}
            {{- '}' }}
            {{- '\n</tool_call>' }}
        {%- endfor %}
        {{- '<|im_end|>\n' }}
    {%- elif message.role == "tool" %}
        {%- if loop.previtem and loop.previtem.role != "tool" %}
            {{- '<|im_start|>tool\n' }}
        {%- endif %}
        {{- '<tool_response>\n' }}
        {{- message.content }}
        {%- if not loop.last %}
            {{- '\n</tool_response>\n' }}
        {%- else %}
            {{- '\n</tool_response>' }}
        {%- endif %}
        {%- if not loop.last and loop.nextitem.role != "tool" %}
            {{- '<|im_end|>' }}
        {%- elif loop.last %}
            {{- '<|im_end|>' }}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
{%- endif %}
HERMES_TEMPLATE_EOF

# ── Kernel-tuning toolchain ───────────────────────────────────────────────────
# These are for scripts/runtime/optimizeModel.sh, which tunes the fused-MoE kernel
# configs on the target GPU. They are NOT needed to serve, and are installed here only
# because the tuning has to run in the serving image: the tuned config it produces is
# keyed to the exact vLLM/torch/triton build that will consume it, so tuning in a
# different image would produce a config for the wrong kernels.
#
# ⚠ ray is a REAL dependency, not a convenience. benchmarks/kernels/benchmark_moe.py
# dispatches every measurement through `@ray.remote(num_gpus=1)` and calls ray.init()
# at module scope, so without it the script dies on `import ray` before parsing argv.
# Pinned rather than floating: ray's actor/serialization protocol is what carries the
# benchmark's torch tensors between driver and worker, so an unexpected major bump can
# break the run in ways that surface only on the node.
# renovate: datasource=pypi depName=ray
ARG RAY_VERSION=2.49.0
RUN pip install --retries 10 --timeout 120 "ray==${RAY_VERSION}" \
    && python -c "import ray; print('ray', ray.__version__)"

# curl: the tuning script fetches the matching benchmark_moe.py for the INSTALLED vllm
# version at run time. The base image genuinely has neither curl nor wget, and carries
# no vLLM source tree, so without this there is no way to obtain the script in-pod —
# a gap that only shows up once the GPU is already idle and the service is down.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The OpenAI-compatible server entrypoint. Args (model, --served-model-name,
# --max-model-len, --api-key) come from the Deployment, not baked here.
EXPOSE 8000
ENTRYPOINT ["vllm"]
CMD ["serve", "--help"]
