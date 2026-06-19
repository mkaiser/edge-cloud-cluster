# Redundancy & High Availability

How cluster redundancy, Longhorn replication, and edge-node integration are
configured in this project. All knobs live in [`project_settings.ts`](../project_settings.ts);
the derivation logic lives in [`src/storage.ts`](../src/storage.ts) and
[`src/nodes-k3s.ts`](../src/nodes-k3s.ts).

---

## Configuration knobs

| Setting | Location | Meaning |
|---|---|---|
| `general.highAvailability` | `project_settings.ts` | When `true`, the deploy fails fast unless ≥3 control-plane nodes are configured (etcd quorum). |
| `storage.longhorn.replicaCount` | `project_settings.ts` | `"auto"` → `min(3, cloudNodeCount)`; or an explicit `1 \| 2 \| 3`. |
| `ComputeNode.longhornTag` | `project_settings.ts` | `"cloud"` (default) or `"edge"` — selects which StorageClass / disk group a node's Longhorn disk belongs to. |
| `nodes.edge[]` | `project_settings.ts` | Pulumi-managed on-prem/VPN nodes; `longhornTag` defaults to `"edge"`. |

`general.highAvailability` is intent, not mechanism: it does not add nodes, it
asserts that you meant to run HA and stops a silent single-CP deploy. Uncomment
`cp1`/`cp2` in `nodes.controlPlane` to actually provide the quorum.

---

## Longhorn replica derivation

Only **cloud-tagged** nodes (control-plane + workers without an `edge` tag) count
as replica targets for the default `longhorn` StorageClass. Edge nodes are
excluded on purpose: Longhorn writes synchronously to every replica, so a volume
with one cloud and one edge replica would block every write on the WAN
round-trip. Edge-local data uses the separate `longhorn-edge` StorageClass.

With `replicaCount: "auto"`:

| Cloud nodes | Replicas |
|---|---|
| 1 | 1 |
| 2 | 2 |
| 3+ | 3 |

Soft anti-affinity means asking for more replicas than nodes just piles copies on
one disk, so the count never exceeds the cloud node count. An explicit
`1 \| 2 \| 3` overrides the derivation. Existing volumes are reconciled to the new
count by the `longhorn-reconcile-replica-count` command in `src/storage.ts`.

---

## PVC storage inventory

| Application | Component | Size |
|---|---|---|
| ArgoCD | helm-cache | 2 Gi |
| Authentik | postgres | 8 Gi |
| Authentik | redis | 2 Gi |
| Headscale | postgres | 1 Gi |
| Headplane | data | 2 Gi |
| GitLab | postgres | 20 Gi |
| GitLab | redis | 5 Gi |
| GitLab | minio | 50 Gi |
| Nextcloud | postgres | 8 Gi |
| Nextcloud | redis | 2 Gi |
| Nextcloud | app-data | 10 Gi |
| RocketChat | mongodb | 16 Gi |
| Zulip | postgres | 16 Gi |
| Zulip | redis | 2 Gi |
| Zulip | rabbitmq | 4 Gi |
| Rallly | postgres | 4 Gi |
| XWiki | postgres | 8 Gi |
| XWiki | app-data | 5 Gi |
| Windows | postgres (guacamole) | 5 Gi |
| Windows | vm-storage | 40 Gi |
| **Total raw data** | | **~210 Gi** |

Total **provisioned** Longhorn storage = raw × replica count. Each node also
reserves 80 Gi (`storageReserved` in `src/nodes-k3s.ts`) that is not available to
volumes.

### Disk requirements by redundancy mode

| Mode | CP nodes | `highAvailability` | `replicaCount` | Provisioned | Per-node usable need |
|---|---|---|---|---|---|
| Single-node | 1× CPX52 | false | auto → 1 | ~210 Gi | ~210 Gi (44% of 480) |
| 2-replica | 2× CX33 | false | auto → 2 | ~420 Gi | ~210 Gi/node |
| Full HA | 3× CX33 | true | auto → 3 | ~630 Gi | ~210 Gi/node |
| Full HA large | 3× CPX52 | true | auto → 3 | ~630 Gi | ~210 Gi/node (44%) |

CX33 ships 80 Gi local disk — far below the ~210 Gi/node a full replica set
needs. For real HA, either attach Hetzner volumes or use a node type with enough
local SSD (CPX52 = 480 Gi). Size the node disk to **raw ÷ (nodes ÷ replicas) +
80 Gi reserve**.

---

## How to enable HA

1. Uncomment `cp1` and `cp2` in `project_settings.ts → nodes.controlPlane`
   (pick a node type with enough disk — see table above).
2. Set `general.highAvailability: true`.
3. Keep `storage.longhorn.replicaCount: "auto"` (→ 3) or set it explicitly.
4. `make create` (or `pulumi up`). New CP nodes join sequentially — etcd admits
   one learner at a time.
5. Longhorn auto-rebalances replicas onto the new nodes
   (`replicaAutoBalance: best-effort`).

The deploy throws a `RunError` immediately if `highAvailability: true` but fewer
than 3 control-plane nodes are configured.

---

## Edge nodes (on-premise, via VPN)

### Core rule: never mix cloud and edge replicas in one volume

Longhorn acknowledges a write only after **all** replicas confirm it. A volume
spanning a cloud node and an edge node makes every write wait for the WAN
round-trip. Keep replica groups homogeneous via node tags and StorageClasses:

| StorageClass | `diskSelector` / `nodeSelector` | Use |
|---|---|---|
| `longhorn` (default) | `cloud` (pinned only when edge nodes exist) | all current cloud apps |
| `longhorn-edge` | `edge` | edge-local workloads only |

`longhorn-edge` is created (in `src/storage.ts`) only when `nodes.edge.length > 0`.
When edge nodes exist, the default `longhorn` class is additionally pinned to
cloud disks/nodes so cloud-app replicas can never land on edge hardware.

Edge-local replication (resident node ↔ resident node over the LAN) is only worth
it with **≥2 stable edge nodes**; with one edge node use replica count 1 there.

### Node tiers

| Tier | Lifetime | Headscale user | Enrollment | Longhorn |
|---|---|---|---|---|
| cloud | permanent | `k3s-cloud` | pre-auth key in secret `headscale-preauthkey-cloud` (auto, via mesh-gateway DaemonSet) | `cloud` |
| on-premise-resident | days–weeks | `on-premise-resident` | pre-auth key minted on demand | `edge` (opt-in) |
| on-premise-transient | hours–days | `on-premise-transient` | pre-auth key minted on demand | none |

**Why pre-auth keys for every tier (not manual approval):** the headscale
registration endpoint is reachable by anyone who knows the server URL. A manual
Headplane approval queue could be flooded with bogus pending registrations.
Pre-auth keys sidestep that queue entirely.

**Key handling:**
- The **cloud** key is stored in the `headscale-preauthkey-cloud` K8s secret and
  consumed automatically by the `mesh-gateway` DaemonSet.
- **On-premise** keys are **never** stored in a K8s secret. They are minted on
  demand by `scripts/runtime/generateEdgeJoinScript.sh` (admin-run, with cluster
  access) and baked into a `DO-NOT-COMMIT` join script.

Pre-auth key expiry limits when **new** registrations are accepted; it does
**not** expire already-joined nodes. Remove a node via Headplane or
`headscale nodes expire --identifier <id>`.

### Enrolling on-premise nodes

The headscale post-deploy job creates the three users. To provision edge nodes:

```bash
# default tier = on-premise-resident
./scripts/runtime/generateEdgeJoinScript.sh

# transient tier
EDGE_TIER=on-premise-transient ./scripts/runtime/generateEdgeJoinScript.sh
```

This generates `tmp/provisioning/{0_install_prerequisites,1_connectVPN,2_joinCluster}.sh`
and a `provision-edge-server.sh` wrapper. Run them on the node (or via the
wrapper). The generated scripts contain a freshly-minted pre-auth key — do not
commit them.

A resident node that should serve `longhorn-edge` volumes needs its disk tagged
`edge` after it joins (the generated join script labels nodes for the default
disk but not the edge tag):

```bash
NODE=<edge-node-name>
kubectl label node "$NODE" node.longhorn.io/create-default-disk=config --overwrite
kubectl annotate node "$NODE" \
  'node.longhorn.io/default-disks-config=[{"path":"/var/lib/longhorn","allowScheduling":true,"tags":["edge"]}]' \
  --overwrite
```

Transient nodes skip Longhorn entirely.

### Network topology

```
on-premise-resident A ←── direct WireGuard (Tailscale mesh) ──→ on-premise-resident B
         │                                                                │
         └──────────────── Headscale DERP / mesh ──────────────────────────┘
                                      │
                  Cloud CP (advertises 10.0.0.0/23, k3s-api → 10.0.0.100)
```

Cloud CPs join the mesh automatically (mesh-gateway DaemonSet) and advertise the
Hetzner private subnet `10.0.0.0/23`, so edge nodes reach the k3s API at
`10.0.0.100:6443`. Longhorn replication between two resident nodes goes directly
over the Tailscale mesh (LAN), never through the cloud or the public internet.

### Timing — no chicken-and-egg

Control-plane formation uses the **Hetzner private network**, not Tailscale, so
CPs form the K3s/etcd cluster before headscale exists:

```
make create
 ├─ cp0/cp1/cp2 form K3s cluster      (Hetzner private net — no headscale dependency)
 ├─ ArgoCD syncs waves
 ├─ headscale deployed → post-deploy job creates users + cloud key secret
 ├─ wave barrier waits for headscale-preauthkey-cloud
 └─ mesh-gateway DaemonSet enrolls CPs into the mesh automatically
        └─ edge nodes can now enroll (generateEdgeJoinScript.sh) and join K3s
```
