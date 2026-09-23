# Ollama v0.34.2 for the Jetson Thor (Blackwell sm_110 / arch 11.0), L4T R38 /
# JetPack 7 / CUDA 13.0. Built on-node by GitLab CI (.gitlab-ci.yml, tags:[thor])
# and pushed to registry.gitlab.<tld> — sm_110/CUDA-13 kernels can't cross-build.
#
# WHY BUILD AT ALL (the prebuilt image is right there): the prebuilt jetson image
# ghcr.io/nvidia-ai-iot/ollama:r38.2... is ollama **v0.11.6**, whose engine does
# NOT know the `qwen35moe` architecture (Qwen3.5/3.6 MoE) — the target model
# (Qwen3.6-35B-A3B, the GGUF twin of what vLLM serves) fails to load with
# `unknown model architecture: 'qwen35moe'`. That arch landed in ollama v0.32.1.
# So we build v0.32.1 FROM the prebuilt image, which already carries the whole
# CUDA-13 build+runtime stack (nvcc 13.0, cmake, the /opt/ollama git checkout,
# start_ollama, the runtime libs, IS_SBSA=True, ld.so.conf → the payload dir).
#
# renovate: managed by the "Container image tags" regex manager (docker datasource)
FROM ghcr.io/nvidia-ai-iot/ollama:r38.2.arm64-sbsa-cu130-24.04

# Ollama version to build. v0.32.1 is the first RELEASE tag whose engine supports
# `qwen35moe` (added upstream in commit da70c322; present in
# fs/ggml/ggml.go at this tag). Bump to rebuild.
# renovate: datasource=github-releases depName=ollama/ollama versioning=semver
# CRITICAL name-collision trap: the base image sets ENV OLLAMA_VERSION=0.11.6. If we
# named this ARG OLLAMA_VERSION, then EVERYWHERE `${OLLAMA_VERSION}` expands — incl.
# the RHS of `ENV OLLAMA_VERSION=${OLLAMA_VERSION}` — Docker resolves it to the
# inherited ENV (0.11.6), NOT the ARG: an inherited ENV always wins over a same-named
# ARG. So the build silently checked out v0.11.6 twice (CUDA lib landed in
# build/lib/ollama/ not cuda_v13/ → final test -f failed). Fix: use a DIFFERENTLY
# named ARG (OLLAMA_BUILD_VERSION) and assign the ENV from it — no collision, our
# value wins.
# BUMPED 0.32.15 -> 0.34.2 (latest, 2026-09-15). Carries the qwen3_5 MTP
# speculative-draft work that motivated the previous bump, plus 0.33's prefill-cache
# correctness fixes (a cancelled prefill now keeps its restore points instead of
# reprocessing from zero). Go 1.26.0 is required by v0.34.2's go.mod; GO_VERSION below
# is 1.27.1, so the pinned toolchain already satisfies it.
#
# ⚠ THIS BUMP DOES NOT FIX TOOL CALLING, and was not expected to. qwen3-coder:30b leaks
# its tool calls into message content as literal
#     <function=NAME><parameter=KEY>…</parameter></function></tool_call>
# (note the orphan closing tag with no opener) because Ollama's compiled-in
# `PARSER qwen3-coder` never engages when the model omits the opening <tool_call> tag —
# a known model flub. That is ollama/ollama#16686, OPEN since 2026-06-12, and all three
# candidate fixes (#17742, #16398, #17021) are open and UNMERGED as of this bump. So do
# not read "we are current" as "tool calling is fixed"; the fix here is the Modelfile
# override that replaces that parser. Re-check those PRs before assuming otherwise.
ARG OLLAMA_BUILD_VERSION=0.34.2
#
# ⚠ THE IMAGE FOR THIS TAG HAS NEVER BEEN BUILT — the build is BLOCKED UPSTREAM, and
# not by anything in this file. Three attempts on 2026-09-18 (pipeline 13, jobs 14/16/17)
# all died at the same Go module, from three different IPs:
#     github.com/klauspost/compress@v1.18.3: Get
#     "https://storage.googleapis.com/proxy-golang-org-prod/…": connection reset by peer
# proxy.golang.org answers that zip with a 302 whose target then resets the TLS
# connection. Reproduced from OUTSIDE the cluster too (3/3 from the devcontainer,
# `curl: (35) TLS connect error: unexpected eof while reading`), so it is NOT the mesh
# link, NOT the [thor] runner and NOT this bump: v0.32.15's go.mod requires the SAME
# module version, so rebuilding the PREVIOUS tag would fail identically today.
#
# Consequence: `ollama` in namespace `ollama` sits in ImagePullBackOff for
# v0.34.2-cu13-sm110-r1. That is expected, not a misconfiguration. The previously built
# v0.32.15-cu13-sm110-r2 image still exists in image-archives if a rollback is ever
# wanted — only the REBUILD is blocked, not the old artifact.
#
# Deliberately NOT worked around (decision 2026-09-18): Thor is moving to vLLM, which
# scales ollama-thor to 0 anyway. If this image is ever needed again, first re-test that
# module fetch; if it still fails, build with GOPROXY=direct (fetch from GitHub instead
# of Google's proxy) rather than retrying the pipeline.
ENV OLLAMA_VERSION=${OLLAMA_BUILD_VERSION}

# Two toolchain gaps in the base image block a v0.32.1 build (both verified on-node):
#  1. Go: base has 1.22.7; v0.32.1 go.mod requires 1.26.0.
#  2. GCC: base has gcc-13.3, but v0.32.1's llama.cpp GGML_CPU_ALL_VARIANTS compiles
#     an armv9.2 CPU variant with `-march=...+sme` (Scalable Matrix Extension) that
#     gcc-13 rejects ("invalid feature modifier 'sme'"). gcc-14 (Ubuntu 24.04 apt)
#     knows sme. We build C/C++ AND the CUDA host compiler with gcc-14.
# renovate: datasource=golang-version depName=go
ARG GO_VERSION=1.27.1

# Thor GPU compute capabilities to emit. 110 = sm_110 (Thor Blackwell); 87 (Orin)
# and 121 kept to match the base image's own CUDA_ARCHITECTURES so one image also
# runs on sibling Jetsons if ever needed. The GPU BACKEND itself is selected by
# OLLAMA_LLAMA_BACKENDS below — WITHOUT that the build is CPU-only (see the build RUN).
# (The base also sets ENV CUDA_ARCHITECTURES=87;110;121 — same name-collision trap as
# OLLAMA_VERSION above; use a differently-named ARG so our value wins.)
ARG CUDA_ARCH=87;110;121
ENV CUDA_ARCHITECTURES=${CUDA_ARCH}

RUN set -eux; \
    # --- gcc-14 for the SME CPU variant ---
    apt-get update; \
    apt-get install -y --no-install-recommends gcc-14 g++-14; \
    rm -rf /var/lib/apt/lists/*; \
    # --- Go 1.26 (base's 1.22 is too old); install alongside, prepend to PATH ---
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz; \
    rm -rf /opt/go && mkdir -p /opt/go; \
    tar -C /opt/go --strip-components=1 -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    /opt/go/bin/go version

ENV PATH=/opt/go/bin:${PATH} \
    CC=gcc-14 \
    CXX=g++-14

# Build ollama v0.32.1 with the CUDA-13 GGML backend.
#
# THE CRITICAL FLAG — OLLAMA_LLAMA_BACKENDS=cuda_v13: v0.32.1 restructured the build
# so the GGML CUDA backend is a superbuild sub-project gated by this cache var, which
# defaults to EMPTY = CPU-only (no libggml-cuda.so → model runs on CPU). cuda_v13 is
# the CUDA-13 backend (NOT cuda_jetpack6, which targets JetPack-6/CUDA-12.6). This is
# NOT in jetson-containers' build.sh — that predates the restructure.
# -j4 (not $(nproc)): the ~365MB CUDA lib compile can OOM-kill nvcc on the Thor's
# ~15GiB usable RAM at full parallelism.
RUN set -eux; \
    cd "${OLLAMA_HOME}"; \
    git fetch --depth 1 origin "refs/tags/v${OLLAMA_VERSION}:refs/tags/v${OLLAMA_VERSION}"; \
    git checkout -f "v${OLLAMA_VERSION}"; \
    rm -rf build; \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc-14 -DCMAKE_CXX_COMPILER=g++-14 \
        -DOLLAMA_LLAMA_BACKENDS=cuda_v13 \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DCMAKE_CUDA_HOST_COMPILER=gcc-14 \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DOLLAMA_VERSION="${OLLAMA_VERSION}"; \
    cmake --build build -j4; \
    go build -ldflags "-X github.com/ollama/ollama/version.Version=${OLLAMA_VERSION}" -o "${OLLAMA_HOME}/ollama" .; \
    # Re-point the symlinks (build.sh's targets) at the freshly built binary, and
    # register the payload dir with the dynamic linker.
    ln -sf "${OLLAMA_HOME}/ollama" /usr/local/bin/ollama; \
    ln -sf /usr/local/bin/ollama /usr/bin/ollama; \
    ln -sf /usr/local/bin/ollama /bin/ollama; \
    echo "${OLLAMA_HOME}/build/lib/ollama" > /etc/ld.so.conf.d/ollama.conf; \
    ldconfig; \
    # Sanity: the CUDA backend lib must exist, else the build silently went CPU-only.
    test -f "${OLLAMA_HOME}/build/lib/ollama/cuda_v13/libggml-cuda.so"; \
    ollama --version || true

# CMD/ENTRYPOINT inherited from the base (start_ollama). The k8s Deployment
# overrides command to run `ollama serve` in the foreground anyway.
