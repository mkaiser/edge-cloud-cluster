# `mesh-hello` — minimal Ryax action

The smallest complete Ryax action: proof that a Site / Node Pool is wired up and
that actions land on the nodes you expect.

```
ryax_metadata.yaml   the action definition (id, inputs, outputs, resources)
ryax_handler.py      the code — a `handle(request: dict) -> dict` function
```

Standard library only, and deliberately **no `requirements.txt` and no
`dependencies:`**. Every python dependency is a nix build in the action-builder and
binary deps pull nixpkgs, so an empty dependency set keeps the first build to a
couple of minutes instead of tens. This action's only job is to answer "does the
pipeline work end to end" — add dependencies once it has passed.

## Outputs

| Output | Why it is here |
|---|---|
| `greeting` | Echoes the `message` input, so you can see data flow through the workflow. |
| `node_name` | **The one that matters.** The Kubernetes node the action ran on — it must be a `unibi-hclab` mesh node, never a cloud node. |
| `pod_name` | The pod Ryax created in `ryaxns-execs`. |
| `architecture` | `x86_64` or `aarch64`. |

`node_name: unknown` is **not** a failure. The Ryax worker builds the action pod
spec itself (it is not rendered by the Helm chart), so which downward-API
variables it injects is not part of the documented contract; the handler tries the
conventional names and degrades instead of raising. Confirm placement directly
while a run is live:

```sh
kubectl get pods -n ryaxns-execs -o wide
```

## You may not need this

Ryax has a **public** repo of ready-made actions, clonable anonymously:
`https://gitlab.com/ryax-tech/workflows/default-actions.git` (33 actions, 13
triggers). For a plain smoke test, add that URL in the UI and build **`echo`** —
it is purpose-built for testing and needs no git push. `print_env` there also dumps
the action pod's whole environment.

`mesh-hello` earns its place only for the one thing those do not do: it returns the
executing node as an **output**, so placement is visible in the run result rather
than buried in a log. If you don't need that, use `echo` and check placement with
`kubectl get pods -n ryaxns-execs -o wide`.

## Using it

Ryax imports actions by **scanning a git repository**, so it must be reachable
from a repo rather than applied from disk:

1. Push this directory to a repository Ryax can reach (the in-cluster GitLab
   works; use a read-only deploy token if private).
2. Ryax UI → **Library → Repositories → Add** → name + clone URL (+ credentials),
   then **New Scan**. `Mesh Hello` appears in the scan results.
3. **Build** it. The action-builder packages it with nix and pushes it to
   `ryax-registry:5000`.
4. New workflow → **HTTP POST** trigger → add the **Mesh Hello** action, linking
   the trigger field to the `message` input.
5. In the action's **Deploy** tab pick the Site / Node Pool, deploy, and trigger.

Full walkthrough, including the Site/Node Pool registration this depends on:
[../README.md](../README.md#adding-a-cluster-node-as-a-ryax-worker-sites-and-node-pools).

## Resource envelope

`resources` in `ryax_metadata.yaml` (0.5 cpu / 256M / 5m) is set to sit inside the
`LimitRange` and `ResourceQuota` that
[../worker-values.yaml](../worker-values.yaml) creates in `ryaxns-execs`. An action
that asks for more than the quota allows is rejected at admission, not queued.
