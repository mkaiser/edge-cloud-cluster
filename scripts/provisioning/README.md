# Manual node provisioning

For a node that Pulumi cannot reach (`make provision-mesh-node` is the automated path).
Steps run from the **devcontainer** unless the heading says otherwise.

The generated bundle is **keyless**: no pre-auth key travels to the node. The node registers
and stays PENDING until a human approves it. That approval is the second factor.

## 0. Bootstrap key access (only if the box is password-only)

Everything below assumes the box already accepts our SSH key and that the provisioning user
can `sudo` without a password. A freshly-imaged box does not — it has a vendor account and a
password. This turns one into the other:

```bash
bash scripts/provisioning/provisionUsersViaSshPassword.sh <host> --login <vendor-user> \
     --ask-password [--port N] [--users "cape trecs"] [--hostname <name>]
```

It creates each user, appends our public key to their `authorized_keys` and writes
`/etc/sudoers.d/<user>`. The key comes from the **Pulumi stack** (`--key`, default
`sshkey-ecc-mesh`): the public half is derived from the stack's private key with `ssh-keygen -y`,
so nothing private touches disk. Without a loaded stack, pass `--pubkey <file>` or
`--pubkey-string '<key>'`.

Idempotent — it matches on the key blob, and it APPENDS rather than overwrites, so a second
admin's existing key survives. `--dry-run` prints the remote script without running it.

The accounts are created **key-only** (`adduser --disabled-password`), which is all SSH needs.
Add `--set-passwords` when console, IPMI or rescue-boot login has to work too: it prompts per
user, twice, with no echo. For an account that already exists it asks first — a re-run cannot
silently replace a password someone else set.

## 1. Generate the bundle

Do this every time. The bundle embeds the *current* cluster's join token and CA — one from a
previous cluster copies cleanly and then fails at join time with a confusing CA-hash mismatch.

```bash
make provisioning-bundle                                              # + one .tar.gz to carry away
bash scripts/provisioning/generateProvisioningScripts.sh              # writes tmp/provisioning/
bash scripts/provisioning/generateProvisioningScripts.sh --list-nodes # + ready-to-run SSH lines
```

`make provisioning-bundle` (or `--bundle`) additionally packs the folder into
`tmp/provisioning-<subdomain>-<ts>.tar.gz` with a `SHA256SUMS` beside it — one file to hand
over instead of copying a directory, and the make target gets a `logs/` entry for free.

It is a **tar.gz, not a zip**: every script in here has to stay executable and zip does not
carry the mode portably, which would land the recipient on
`bash: ./provision-mesh-node-local.sh: Permission denied`.

⚠ The archive is **sensitive** — `40-join-cluster.sh` embeds the k3s join token, so it is a
cluster-join credential, not just a script set. It is written `0600`; hand it over out-of-band
and delete it from the node after the join (step 6). The tailscale side is keyless, so the
holder still needs a human to approve the node in Headplane (step 3) before the token is
usable at all.

## 2. On the to-be-provisioned node

### 2a. Copy the scripts

By USB, or over the network:

```bash
scp -r tmp/provisioning trecs@192.168.178.150:/tmp
```

Or, with a bundle — copy the `SHA256SUMS` alongside it so the recipient can check it:

```bash
scp tmp/provisioning-*.tar.gz tmp/SHA256SUMS trecs@192.168.178.150:/tmp
# on the node:
cd /tmp && sha256sum -c SHA256SUMS && tar xzf provisioning-*.tar.gz
```

`copyProvisioningScripts.sh <host> [--user U]` does the same but regenerates first, so the
delivered set always matches the live cluster.

### 2b. Run the driver

Log in to the node, then:

```bash
cd /tmp/provisioning
./provision-mesh-node-local.sh --name <node-id>   # no args → interactive menu
```

It self-elevates with sudo — do not prefix it. It chains: cleanup → prereqs → [GPU] → VPN →
join → [nested runtime], and blocks at the VPN step for the approval in step 3.

`<node-id>` MUST be the `id` from `project_settings.ts` `nodes.mesh[]`, **not** the hostname.
A mismatch does not update the existing node — it creates a second node object for the same
box.

Add `--gpu jetson-thor|jetson-orin|nvidia-turing-sm75` and/or `--nested-runtime gvisor` here
if the node needs them. Neither can be added later: they do on-node work bracketing the k3s
join, and step 4 only applies labels.

## 3. Approve the tailnet registration

The node prints a one-time URL and a QR, and waits. Scan the QR, open the URL, or use the
link the administrator received. In Headplane: Machines → "Register machine" → paste the
URL/auth-id → pick user → click.

⚠ The user MUST be `on-premise-resident` (or `-transient`). Any other user gets the node a
tailnet IP that matches no ACL grant, so it never actually joins.

Once approved the node continues on its own through the k3s join.

## 4. Adopt it (devcontainer)

```bash
bash scripts/provisioning/adoptProvisionedNodes.sh <node-id> [--nested-runtime gvisor]
```

Until this runs the node is **unusable**: it carries the `ecc/mesh:NoSchedule` taint with no
`ecc/*` labels and no Longhorn disk config, so nothing schedules on it. This applies the
labels (site / kvm / gpu / nested-runtime), the Longhorn `storageScope` disk tags, the
description, the `tag:k8s-node` tailnet tag, and the provision fingerprint that makes a later
`make provision-mesh-node` skip the node. It prompts for each value.

Pass the same `--nested-runtime` the node was provisioned with — the handler is installed on
the box, but the matching label comes only from here.

## 5. Verify

```bash
bash scripts/provisioning/verifyProvisionedNode.sh <node-id>
```

Read-only. Checks the things that fail *silently* — a node can sit `Ready` for days while
holding no replicas and running no pods: the mesh role and taint, the `ecc/*` labels, the
**live** Longhorn disk tags (not just the annotation), that a `longhorn-<scope>` StorageClass
exists for each tag, that a RuntimeClass targets the nested-runtime label, and the tailnet
entry with its `tag:k8s-node`.

`kubectl get node <id> --show-labels` is the quick one-liner, but it shows only labels —
it cannot see the Longhorn CR, the StorageClasses or the tailnet, which is where the silent
failures actually are.

## 6. Delete the bundle from the node

`40-join-cluster.sh` contains the k3s join token:

```bash
sudo rm -rf /tmp/provisioning
```

---

# Decommissioning

## From the cluster operator (the normal way)

One command does the whole teardown, in the order that matters:

```bash
make decommission-mesh-node ARGS='<node-id>'
make decommission-mesh-node ARGS='<node-id> --dry-run'
```

It wipes the box over SSH, drains and deletes the k8s node + Longhorn node CR, deletes the
headscale entry, and prunes the node's Pulumi command resources. Idempotent — every step
tolerates an already-absent target.

⚠ **Run it BEFORE removing the node from `project_settings.ts`.** The box wipe needs the
node's `ssh.{endpoint,port,user,key}` to reach it. If the node is already gone from config,
the wipe is skipped with a warning and you must clean the box by hand (below).

Commenting a node out of `project_settings.nodes.mesh[]` tears down **nothing**: the box keeps
a live k3s-agent and tailscale identity, its k8s/Longhorn objects linger, and its headscale
entry orphans. There is no `delete` on the provisioning Commands, so `pulumi up` cannot clean
it either.

To clear dead VPN identities left by repeated re-provisions (headscale keeps the old record
and appends `-1`, `-2`, … to the name):

```bash
make prune-orphaned-mesh-nodes            # list, pick, delete
make prune-orphaned-mesh-nodes ARGS=--yes # delete all orphans
```

This removes only the dead VPN identity — never k8s, Longhorn, or the box.

## From the node (local, no cluster access)

`00-cleanup-node.sh` is self-contained and runs standalone. Use it when the cluster is already
gone, the node is unreachable from the devcontainer, or you are re-provisioning by hand. It is
also what the driver runs first in step 2b, so a provision always starts clean.

```bash
sudo bash 00-cleanup-node.sh                  # refuses if /var/lib/longhorn holds replicas
sudo bash 00-cleanup-node.sh --wipe-storage   # wipe those too — what a real re-provision needs
```

Take it from `/tmp/provisioning/` (it ships with the bundle) or from
`src/provisioning-scripts/`. It removes the tailscale identity, the route and MagicDNS
drop-ins, the k3s agent and its whole state tree, and the stale mesh route. Idempotent.

⚠ **`--wipe-storage` is the one unrecoverable action here.** Everything else is re-derivable
on the next provision; `rm -rf /var/lib/longhorn` is not. The disk returns with a new UUID, so
every replica CR naming the old one is orphaned and Longhorn reports the volume `faulted` —
only a backup restore recovers it. Pass it only when you mean it.

Cleaning the box does **not** remove the node from the cluster. Its k8s node object, Longhorn
node CR and headscale entry all survive — finish with `decomissionNode.sh` from the
devcontainer, or `pruneOrphanedNodes.sh` for the VPN entry alone.

---

## Scripts here

| script | role |
| --- | --- |
| `provisionUsersViaSshPassword.sh` | phase 0: password-only box → users + our SSH key + passwordless sudo |
| `generateProvisioningScripts.sh` | build `tmp/provisioning/` from the live cluster (step 1) |
| `copyProvisioningScripts.sh` | regenerate + deliver the bundle over SSH (step 2a) |
| `adoptProvisionedNodes.sh` | post-join labels / storageScope / tag / fingerprint (step 4) |
| `verifyProvisionedNode.sh` | read-only check that a node came out complete (step 5) |
| `decomissionNode.sh` | fully retire one node (box + k8s + headscale + Pulumi state) |
| `pruneOrphanedNodes.sh` | bulk-remove stale headscale entries with no live k8s node |
| `createTrueNasContainer.sh` / `createTrueNasVM.sh` | create the box that then gets provisioned |

The node-side steps themselves live in `src/provisioning-scripts/` — the single source both
this manual path and the Pulumi path render.

Full detail: `doc/mesh-node-management.md`.
