# node-feature-discovery

Labels every node with facts read off the hardware, published under
`feature.node.kubernetes.io/*`. This is the only label class in the cluster not derived from
`project_settings.ts` — see "Declared vs discovered" in `doc/cloud-mesh-architecture.md`.

## Why it exists

`unibi-hclab-fs-vm` is a QEMU/KVM guest on the TrueNAS appliance, and TrueNAS gives it the
default CPU model. Measured with `grep flags /proc/cpuinfo`, counting SSE4.2/POPCNT/CX16/
SSSE3/SSE4.1:

| node | model | v2 flags |
| --- | --- | --- |
| `unibi-hclab-fs-vm` | `QEMU Virtual CPU version 2.5+` | **1 of 5** |
| `unibi-hclab-pcie-tb-d` | `Intel Core Ultra 7 265K` | 5 of 5 |
| `unibi-hclab-pcie-tb-s` | `INTEL XEON SILVER 4510` | 5 of 5 |

The host silicon is fine; the hypervisor does not expose the feature set. Anything built for
the x86-64-v2 baseline dies at import on that node — `ryax-intelliscale` crash-looped 60 times
with `NumPy was built with baseline optimizations: (X86_V2) but your machine doesn't support`.
Nothing expressed that constraint, so whether a pod worked was decided by where it landed.

Consumers now require:

```yaml
- key: feature.node.kubernetes.io/cpu-cpuid.X86_64_V2
  operator: In
  values: ["true"]
```

Present on capable nodes, absent below v2. Positive matching means nothing has to delete a
stale label when a node improves — give the VM a `host`-passthrough CPU model and it earns the
label on the next detection cycle, with no change here.

## Two traps

**1. Do not select on the individual feature flags.** NFD's `newDefaultConfig()`
(`source/cpu/cpu.go`) blacklists `SSE42`, `POPCNT`, `CX16`, `SSE4` and `SSSE3` by default —
exactly the x86-64-v2 features. A selector on `cpu-cpuid.SSE42` matches a label that is never
emitted, and the pod is silently unschedulable. Use the `X86_64_V*` level flags, which are not
blacklisted and which NFD derives itself from the psABI level
(`source/cpu/cpuid_amd64.go` → `microarchLevelFlags(cpuid.CPU.X64Level())`). They are
cumulative: a v4 CPU carries V1 through V4.

Setting an `attributeWhitelist` instead is worse than it looks — a whitelist REPLACES the
blacklist wholesale (`initCpuidFilter`), suppressing every flag not named in it.

**2. The worker tolerations are load-bearing.** The chart default is `worker.tolerations: []`,
and every mesh node is tainted `ecc/mesh=true:NoSchedule` (GPU nodes additionally
`ecc/gpu=true:NoSchedule`). At the default the DaemonSet runs on the cloud node alone,
characterises none of the mesh fleet, and reports Healthy throughout. The only symptom is a
DESIRED count of 1.

## Checking it

```sh
# the DaemonSet reached every schedulable node
kubectl -n node-feature-discovery get ds node-feature-discovery-worker

# who has v2 and who does not
kubectl get nodes -L feature.node.kubernetes.io/cpu-cpuid.X86_64_V2,kubernetes.io/arch
```

Expect the label absent on `unibi-hclab-fs-vm` (below baseline) and on arm64 nodes, where it
does not apply. A node whose CNI is down carries `node.cilium.io/agent-not-ready`, which these
tolerations deliberately do not cover — it is unschedulable anyway, and it gets labelled once
the agent recovers.
