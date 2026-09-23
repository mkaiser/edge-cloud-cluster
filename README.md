# Overview

This projects helps you to setup a complete Kubernetes Edge-Cloud Cluster within minutes using the Infrastructure-from-Code tool [Pulumi](https://www.pulumi.com) and GitOps via [ArgoCD](https://argoproj.github.io/cd/). The cluster is designed with a focus on edge-first workloads, where the control-plane and basic infrastructure run in the cloud ([Hetzner](https://www.hetzner.com)), while worker nodes can be added on-premises at the edge via VPN. The project includes a set of preconfigured applications commonly used by developers in SMEs, such as Nextcloud, XWiki, GitLab, Jitsi, and more - all integrated with Authentik for single sign-on.

Within the [European-funded project CAPE](https://wwww.cape-project.eu/), this infrastructure serves as a reference implementation and playground for testing various applications, configurations, and edge scenarios and will be continuously developed and improved with the goal to have create a cloud-provider-agnostic bootstrapping setup using the sovereign cloud API [SECAPI](https://www.secapi.eu/).

<table>
  <tr>
    <td width="50%">
      <img src="doc/images/overview-edge-cloud-infrastructure.drawio.svg" alt="Edge-Cloud infrastructure overview" />
    </td>
    <td width="35%">
      <img src="doc/images/authentik_dashboard.png" alt="Authentik Dashboard" />
    </td>
  </tr>
</table>

# Project Goals

- Perform most of the **heavy lifting for setting up a Kubernetes cluster** on Hetzner with a set of preconfigured applications, which should meet the needs of hard/software developers of SME.
- Provide a **reference implementation** with a solid infrastructure software stack: Identify and Access Management (IAM) provider, monitoring, backup, restore, high availability, etc.
- **"Edge-first for workloads"**: Use cloud servers to setup the basic infrastructure. Edge-worker nodes attach to the cloud infrastructure via VPN and provide cost-effective and privacy-preserving on-site calculations.
- **IfC and GitOps**: The infrastructure follows best practices in terms of infrastructure from code (IfC via Pulumi) and GitOps reproducibility via ArgoCD.
- **Modular approach**: You can easily add/remove applications and adjust the deployment to your needs, e.g., you can to use multiple control plane nodes to achieve high-availability.
- **Updates via GitOps**: By using renovate, all software components of this project can be easily maintained/updated via automated Github pull requests. If something broke, just revert the commit and the cluster will self-heal.
- **Flexible edge-cloud architecture**: Edge nodes are considered ephemeral and can be added/removed at any time. The cluster is be able to handle this autonomously and allows applications to move between cloud and edge nodes.
- **Open Source first**: All used components are open source and can be replaced by alternatives if needed.

# Cluster Bootstrapping process

![Cluster bootstrapping steps](doc/images/edgecloud-cluster-setup-steps.drawio.svg)

1. **Cloud Infrastructure setup:**
   The infrastructure engineer opens the provided devcontainer, creates a new Pulumi stack and seals the secrets (e.g. provider access tokens) using the provided shell scripts. After modifiying the file [project_settings.ts](project_settings.ts), which is the single source of truth for Pulumi and cluster configuration, Pulumi will setup the described Infrastructure as Code in the cloud. This includes networking, storage, DNS, TLS certificates and initial OS-provisioning and Kubernetes setup on cloud servers. Finally ArgoCD will be started.

2. **GitOps Deployment:**
   ArgoCD continuously monitors a configurableGit repository for changes. The minimal implementation contains the basic infrastructure: A self-managing ArgoCD, Prometheus and Grafana for monitoring, renovate update management, followed by [Authentik](https://goauthentik.io) for Identity and Authorization (IaM) management including an application dashboard/portal. [headscale](https://github.com/juanfont/headscale) and [headplane](https://github.com/juanfont/headplane) is used for VPN management.

    The initial software stack contains a pre-configured nextcloud for ofice and file storage, a xwiki for documentation and a gitlab for code hosting and CI/CD. Finally the RYAX workflow orchestration engine is deployed using a helm chart.

3. **Mesh node integration:**
   After the VPN server is online, it is used as a VPN service provider to establish a virtual network between cloud and mesh nodes. The mesh nodes ("mesh" = externally-hosted machines adopted over SSH that join over the VPN — not physically at the network edge) connect outbound to the cloud VPN and join the cloud’s Kubernetes cluster.
   The infrastructure engineer can choose between two ways to integrate mesh nodes into the cluster:

    (a) Fully automated, Pulumi-based, by defining the nodes in [project_settings.ts](project_settings.ts) (`nodes.mesh`) and running `make provision-mesh-node`

    (b) Manual provisioning using a self-contained script including manual approval via the headplane admin portal. This is useful for integrating and onboarding of transient mesh nodes by non-infrastructure experts.

4. **Run-time usage:**
   DevOps Engineers can monitor the cluster and start deploying their applications and workloads using ArgoCD or RYAX. The Ryax web-based user interface can now be used by non-expert developers or users to deploy preconfigured applications like LLMs or vision processing algorithms (ClickOps), or use a low-code approach.

# Deployment Overview

The deployed set of applications is categorized into two groups: Infrastructure Apps and User Apps. The infrastructure apps are required for the cluster to run and are deployed by Pulumi and ArgoCD as part of the bootstrapping process.
The user apps are optional and can be deployed by users via ArgoCD.

## Infrastructure Apps

The list shows REQUIRED infrastructure applications, in ArgoCD sync-wave order. Waves 0–19 are
owned by the **infra** ArgoCD instance (`argocd-infra`); barriers at waves 1, 3 and 18 gate
advancement until everything below them is Synced+Healthy.

RAM columns: `req/limit` are the summed Kubernetes memory request/limit of the namespace's running
containers (— = unset); `usage` is the live snapshot on cluster <clusterN> (`kubectl top pods -A`).
Storage is summed PVC capacity (`kubectl get pvc -A`); Longhorn itself uses raw Hetzner block
volumes, not PVCs.

| App | Wave | RAM (req/limit) | RAM (usage) | Storage (PVC) | Deployed by | Purpose |
| --- | ---- | --------------- | ----------- | ------------- | ----------- | ------- |
| Cilium | 0 | — / — | (kube-system) | — | Pulumi, adopted by ArgoCD | CNI pod network (k3s runs `flannel-backend: none`) |
| ArgoCD (infra) | 0 | — / — | ~1380Mi | 2Gi | Pulumi | GitOps for waves 0–19, self-managed thereafter |
| Envoy Gateway | 0 | 800Mi / 1024Mi | ~155Mi | — | Pulumi | Gateway API controller + shared Gateway, HTTP→HTTPS redirect |
| External-DNS | 0 | — / — | ~70Mi | — | ArgoCD (infra) | Hetzner DNS records from HTTPRoute/Ingress hosts |
| kube-vip | 0 | — / — | (kube-system) | — | ArgoCD (infra) | Stable VIP 10.0.0.100 for the k3s API across CP nodes |
| PriorityClasses | 0 | — / — | — | — | ArgoCD (infra) | Scheduling priorities for graceful degradation (manifests only) |
| Sealed Secrets | 0 | — / — | (kube-system) | — | Pulumi | Encrypted secrets in git |
| sealed-secrets-guard | 0 | — / — | — | — | ArgoCD (infra) | CronJob that restarts the controller when a SealedSecret has no Secret |
| SeaweedFS | 0 | — / — | ~285Mi | 60Gi | ArgoCD (infra) | S3-backed file layer for cloud↔edge apps |
| ReferenceGrants | 1 | — / — | — | — | ArgoCD (infra) | Cross-namespace Gateway API backendRef grants |
| Longhorn | (Pulumi) + 2 | — / — | ~6830Mi | (block) | Pulumi (chart), ArgoCD (config) | Replicated block storage across cloud nodes |
| CloudNativePG | 2 | — / — | ~95Mi | — | ArgoCD (infra) | PostgreSQL operator (authentik, headscale, apps) |
| Prometheus | 2 | 224Mi / — | ~3720Mi | 5Gi | ArgoCD (infra) | Metrics, alerting, Pushgateway |
| SeaweedFS CSI | 2 | — / — | — | — | ArgoCD (infra) | `seaweedfs` StorageClass |
| node-feature-discovery | 2 | 608Mi / 1280Mi | ~270Mi | — | ArgoCD (infra) | Hardware-derived node labels (the only labels not from `project_settings.ts`) |
| nvidia-gpu | 2 | — / — | — | — | ArgoCD (infra) | `nvidia` RuntimeClass + device plugin for GPU mesh nodes |
| nested-runtime | 2 | — / — | — | — | ArgoCD (infra) | `runsc` (gVisor) RuntimeClass for nested-container nodes |
| Reloader | 2 | 128Mi / 256Mi | ~45Mi | — | ArgoCD (infra) | Restarts pods when a mounted ConfigMap/Secret changes |
| system-upgrade-controller | 2–4 | — / — | ~65Mi | — | ArgoCD (infra) | k3s node version upgrades (plans at waves 3–4) |
| Authentik | 6 | 128Mi / 512Mi | ~1450Mi | 10Gi | ArgoCD (infra) | Identity and access management (OIDC) |
| Headscale | 8 | 408Mi / 1600Mi | ~770Mi | 7Gi | ArgoCD (infra) | Self-hosted Tailscale control plane (mesh VPN) |
| Headplane | 8 | — / — | — | — | ArgoCD (infra) | Headscale admin GUI |
| mesh-gateway | 10 | — / — | — | — | ArgoCD (infra) | Tailscale on every CP host; bridges private plane ↔ mesh plane |
| node-guard | 10 | — / — | — | — | ArgoCD (infra) | Host nftables guards on every node (mesh anti-loop) |
| mesh-monitoring | 11 | — / — | — | — | ArgoCD (infra) | iperf3 + ping probes for mesh link health |
| Descheduler | 12 | — / — | — | — | ArgoCD (infra) | Relocates running pods when node affinity later stops matching |
| Samba AD | 13 | 1584Mi / 6336Mi | ~975Mi | 36Gi | ArgoCD (infra) | On-prem AD domain controllers (SMB identity for TrueNAS) |
| Loki | 14 | — / — | ~500Mi | 20Gi | ArgoCD (infra) | Cluster log store (not publicly routed; reached via Grafana) |
| Grafana | 14 | — / — | (prometheus) | — | ArgoCD (infra) | Dashboards over Prometheus + Loki |
| Alloy | 15 | 1246Mi / 3584Mi | ~675Mi | — | ArgoCD (infra) | Log collector DaemonSet shipping to Loki |
| TrueNAS | 16 | — / — | — | — | ArgoCD (infra) | Lab appliance integration: AD join, Authentik proxy, NFS exports |
| csi-driver-nfs | 17 | 280Mi / 2800Mi | ~165Mi | — | ArgoCD (infra) | Node driver for the static TrueNAS NFS PVs |
| ArgoCD (apps) | 19 | — / — | ~1830Mi | — | ArgoCD (infra) | GitOps for the user apps instance |
| Renovate | 19 | — / — | CronJob | — | ArgoCD (infra) | Dependency PRs against GitHub |
| notify | 19 | — / — | — | — | ArgoCD (infra) | One-shot bootstrap-complete notification |
| cert-manager | (Pulumi) | — / — | ~180Mi | — | Pulumi | TLS certificates (wildcard + per-host) |
| WireGuard | (Pulumi) | 80Mi / 160Mi | ~20Mi | — | Pulumi | Dedicated admin VPN (the only way in once hardened) |
| **Total** | | **5486Mi / 17808Mi** | **~19Gi** | **~140Gi** | | |

(*) Longhorn RAM is spread across many pods, not one process, and scales with **node count** and
**attached volume count/size**. The bulk is a per-node `instance-manager` pod, which runs the
userspace engine + replica process for *every* volume attached to that node (each pre-allocates
buffers/page cache). The rest: one `longhorn-manager` and one `csi-plugin` per node, plus HA CSI
sidecars (provisioner/attacher/resizer/snapshotter ×3) and a `share-manager` per RWX volume.
Moving/consolidating volumes shifts where the instance-manager RAM lands but does not remove it —
it is inherent to Longhorn running storage engines in userspace.

## User Apps

User configurable OPTIONAL applications, deployed by the **apps** ArgoCD instance
(`argocd-apps`, `deployment/argocd-apps/app-of-apps/`). None of them is required for the
cluster to run.

RAM columns: `req/limit` are the summed Kubernetes memory request/limit of the namespace's
running containers (— = unset); `usage` is the live snapshot on cluster <clusterN>
(`kubectl top pods -A`). Storage is summed PVC capacity (`kubectl get pvc -A`); NFS-backed
apps additionally use TrueNAS datasets that are not PVCs.

### Collaboration and office

| App | RAM (req/limit) | RAM (usage) | Storage (PVC) | Purpose |
| --- | --------------- | ----------- | ------------- | ------- |
| Nextcloud | 128Mi / 512Mi | ~1050Mi | 20Gi | File sync and share |
| Nextcloud Collabora | (in nextcloud ns) | | | Online document editing backend for Nextcloud |
| XWiki | — / — | ~2580Mi | 13Gi | Wiki / documentation, OIDC + Postgres |
| Zulip | 960Mi / 3904Mi | ~5100Mi | 32Gi | Team messaging |
| Rocket.Chat | 1024Mi / 4096Mi | ~1330Mi | 16Gi | Team messaging |
| Jitsi | 128Mi / 512Mi | ~740Mi | 32Gi | Video conferencing |
| Rallly | 640Mi / 2012Mi | ~580Mi | 4Gi | Group availability polling |
| Zammad | 1728Mi / 3392Mi | ~3460Mi | 20Gi | Ticketing / helpdesk |
| **Subtotal** | **4608Mi / 14428Mi** | **~14.5Gi** | **137Gi** | |

### Code hosting and CI

| App | RAM (req/limit) | RAM (usage) | Storage (PVC) | Purpose |
| --- | --------------- | ----------- | ------------- | ------- |
| GitLab | 6199Mi / — | ~6890Mi | 125Gi | Self-hosted code hosting, registry, CI |
| GitLab Runner | 640Mi / 2560Mi | ~160Mi | 503Gi | Default untagged cloud CI runner |
| GitLab Runner (mesh) | (in gitlab-runner ns) | | | Runner pinned to mesh nodes |
| GitLab Runner (thor) | (in gitlab-runner ns) | | | arm64 GPU-node runner |
| GitLab Runner (eda) | (in gitlab-runner ns) | | | Privileged buildah runner for EDA image builds |
| GitLab Runner (eda-run) | (in gitlab-runner ns) | | | gVisor runner executing EDA toolchains via `module load` |
| gitlab-mirror | — / — | — | 200Gi | Hourly bare-repo mirror of GitLab onto NFS |
| gitlab-s3-proxy | 64Mi / 256Mi | ~10Mi | — | Lab-pinned TCP proxy to the appliance S3 endpoint |
| ci-build-image | — / — | — | — | Builds the CI image (buildah + skopeo); no workload |
| osxcar-sdv-switch | — / — | — | — | Mirrors an external repo and runs its EDA deploy pipeline |
| **Subtotal** | **6903Mi / 2816Mi** | **~6.9Gi** | **828Gi** | |

### EDA / engineering workstations

| App | RAM (req/limit) | RAM (usage) | Storage (PVC) | Purpose |
| --- | --------------- | ----------- | ------------- | ------- |
| remote-desktop | 2336Mi / 28800Mi | ~1000Mi | 611Gi | Ubuntu/Xfce EDA desktop, runtime `module load` |
| remote-desktop-bender | 2336Mi / 28800Mi | ~630Mi | 606Gi | Second EDA desktop, pinned to the `bender` node |
| desktop-rollout | — / — | — | — | CronJob syncing remote-desktop only while it has no sessions |
| eda-pcb-agent | 3104Mi / 24704Mi | ~355Mi | 500Gi | Shared KiCad PCB workstation over RDP |
| eda-fileserver | — / — | — | 2Gi | Provisions the TrueNAS datasets and NFS exports for EDA |
| eda-xilinx-2024-1 | — / — | — | — | Builds the Vivado 2024.1 module image |
| eda-xilinx-2026-1 | — / — | — | — | Builds the Xilinx 2026.1 module image |
| eda-petalinux-2024-1 | — / — | — | — | Builds the PetaLinux 2024.1 module image |
| eda-hyperlynx-2604 | — / — | — | — | Builds the Siemens HyperLynx 2604 module image |
| image-registry | 192Mi / 8448Mi | ~420Mi | 500Gi | Lab-local OCI registry for the EDA module images |
| windows | 4096Mi / 6144Mi | ~3570Mi | 45Gi | Windows 11 VM (QEMU/KVM), reached over RDP |
| **Subtotal** | **12064Mi / 96896Mi** | **~5.8Gi** | **2264Gi** | |

### AI

| App | RAM (req/limit) | RAM (usage) | Storage (PVC) | Purpose |
| --- | --------------- | ----------- | ------------- | ------- |
| Ollama | 4096Mi / 32768Mi | ~10150Mi | 40Gi | GGUF model serving on the Jetson Thor GPU node |
| ollama-turing | 2048Mi / 12288Mi | ~160Mi | — | Ollama on the discrete-GPU mesh node (2× RTX 2070) |
| LiteLLM | 1152Mi / 2560Mi | ~985Mi | 4Gi | LLM gateway, per-user virtual keys |
| Open WebUI | 640Mi / 2560Mi | ~830Mi | 12Gi | Web chat UI, routed through LiteLLM |
| Hermes | 2048Mi / 12288Mi | ~345Mi | 520Gi | Coding agent with an OpenAI-compatible endpoint for IDE extensions |
| SearXNG | 192Mi / 512Mi | ~120Mi | — | In-cluster metasearch backend for Hermes |
| **Subtotal** | **10176Mi / 62976Mi** | **~12.3Gi** | **576Gi** | |

### Workflow

| App | RAM (req/limit) | RAM (usage) | Storage (PVC) | Purpose |
| --- | --------------- | ----------- | ------------- | ------- |
| Ryax | 7542Mi / 9024Mi | ~4930Mi | 176Gi | Low-code workflow engine (ClickOps deployment of workloads) |
| **Subtotal** | **7542Mi / 9024Mi** | **~4.8Gi** | **176Gi** | |

**Total (user apps): 40.3Gi requested / 181.8Gi limit, ~44.3Gi RAM in use, ~3.9Ti PVC.**

The limit total is deliberately far above physical RAM: the EDA desktops and the model servers
carry high ceilings so a single session can burst, and they are never all busy at once.

`vllm` (`app-of-apps/vllm.yaml.disable`) is present but disabled — it is exclusive with Ollama on
Thor's GPU. `module-runtime` is a documented pod-spec contract checked at pre-commit, not an
Application.

# Setup Instructions

Enough said! Let's start creating your edge-cloud cluster. See [setup instructions](doc/setup-instructions.md)

# Architecture and Implementation Details

[Architecture overview](doc/cloud-mesh-architecture.md)

[Cluster lifecycle management](doc/cluster-lifecycle-management.md)

[Storage architecture](doc/storage-architecture.md)

[High-availability strategy](doc/redundancy-ha.md)

[AD identity chain](doc/ad-identity-chain.md) — how a person becomes a uid, and the two
independent sources that can disagree. Read before touching anything uid-related.

[Development](doc/development.md)

[GPU metrics](doc/gpu-metrics.md) — per-card utilization for the two GPU mesh nodes, and why
the Jetson deliberately reports no GPU memory.

# Frequently Asked Questions

<details>
<summary>What are the resource requirements for the control plane?</summary>

See table in README.md bottom. TODO linkme

Minimum system works on a single server with

- 12 GByte of DDR memory
- 1.5 of 16 CPUs (10%) are busy in idle state
- 1 TB object/S3 bucket storage

</details>

<details>
<summary>What does it cost?</summary>

--> TODO update

- 26€ monthly costs (no redundance, single control plane server):
    - 16€ Server: CX53 (16CPU/32GB/320GB)
    - 5€ 100 GByte SSD Block storage
    - 5€ Object storage / S3 bucket

- 47€ monthly costs (with high availability (HA), 3 Kubernetes control plane servers): - 32€ (2x 16€) server CX53 (16CPU/32GB/320GB) - 5€ server CX33 (4CPU/8GB/80GB) - 5€ 100 GByte SSD Block storage - 5€ Object storage / S3 bucket
    </details>

<details>
<summary>Lets encrypt staging vs. production certificates</summary>

- If you re-create the cluster multiple times within a couple of days, you might hit the rate limits of Let's Encrypt production certificates.
- I use subdomains for testing like `myAwesomeCluster`, which are set in [project_settings.ts](project_settings.ts) (`subdomain`), then run `./scripts/environment/updateConfigFromProjectSettings.sh` to apply updated domain settings in ArgoCD.
- in Pulumi you can select between staging or production certificates, see [project_settings.ts](project_settings.ts) ("certIssuerType") and running `./scripts/environment/updateConfigFromProjectSettings.sh` to apply the new domain settings in ArgoCD. - Hint: To open a website with an untrusted (or staging) certificate in chrome just type `thisisunsafe` in Vivaldi (probably other chrome-based browsers too)
- A single wildcard cert covers almost every host (per-host certs are the exception). See [doc/tls-certificates.md](doc/tls-certificates.md) for the wildcard-by-default architecture, backup/recovery flow, and CA consumers.
    </details>

<details>
<summary>Why ArgoCD?</summary>

It is a well known GitOps tool, which allows us to deploy applications in a declarative way. It also provides a nice UI to monitor the deployment status and logs.

</details>

<details>
<summary>Why don't you use a separate git repository for ArgoCD?</summary>

It is a well known GitOps tool, which allows us to deploy applications in a declarative way. It also provides a nice UI to monitor the deployment status and logs.
It is good practice to keep cluster infrastructure and application deployment separate. Here we want to keep everything in one repository for simplicity. In a production environment with different infra/deployment teams, you might want to separate them.

</details>

<details>
<summary>Why Hetzner as cloud provider?</summary>
I am hosting several private stuff on Hetzner for years and I am very happy. They offer a good balance between price and performance and up-time. They also have good API support.
So the answer is: I am familiar with Hetzner. But the code base is meant to be easily adaptable to other cloud providers, especially via SECAPI. --> Roadmap
</details>

<details>
<summary>Why didn't you use openDesk?</summary>
I started with [opendesk](https://www.opendesk.eu/) TODO fix link, because it sounded like a good fit for our use case and is well maintained, production-ready and used by the german government.
But after deploying it the footprint was too high. It required more than 24 Gbyte RAM to deploy most of the apps. The IaM components Nubus/keycloak were very resource hungry and the encapsulated approach of opendesk made it difficult to configure these components to fit my needs. So I decided to build this cluster infrastructure from scratch using separate tools.
</details>

<details>
<summary>Secrets in git - are you crazy?</summary>
In general: Bad idea! But here, the secrets are well encrypted using kubeseal. See this [article](https://aws.amazon.com/de/blogs/opensource/managing-secrets-deployment-in-kubernetes-using-sealed-secrets/) for a detailed explanation.

- Pulumi: Secrets are encrypted/decrypted with the Pulumi passphrase.
- ArgoCD: Secrets are encrypted with a mechanism called SealedSecrets. You create the key for this in Pulumi and encrypt secrets for ArgoCD within the folder /deployment. Pulumi passes the key to ArgoCD, which can then decrypt thos secrets at deploy-time.
  </details>

<details>
<summary>Why testing with subdomains?</summary>
I recreated the cluster around 100 times. To avoid hitting the rate limits of Let's Encrypt production certificates, I use a subdomains like "\*.testNN." (incrementing number) for my tests and increment regularly (adjust project_settings.ts and run `./scripts/environment/updateConfigFromProjectSettings.sh` to apply the new domain settings in ArgoCD).

Also in my office there is a DNS proxy, which caches DNS entries with a long TTL. So after re-creating the cluster the IP addresses changed, but the DNS were still cached with the old IPs. By using different subdomains, I can avoid this issue.

</details>

# Acknowledgements

<table>
  <tr>
    <td width="25%">
      <img src="doc/images/CAPE_logo_text_light_mode_white_background.png" alt="CAPE - European Open Compute Architecture for Powerful Edge" width="200">
    </td>
    <td width="65%">
This work is part of the <a href="https://www.cape-project.eu">CAPE project</a>, which has received funding from the European Union's Horizon Europe research and innovation programme under grant agreement No 101135. The content of this project reflects only the authors' view and the European Commission is not responsible for any use that may be made of the information it contains.
    </td>
  </tr>
</table>

# Disclaimer

- This project was not audited for security, so it should not be used in production environments without further adjustments and hardening.
- It is not meant to be an "all-in-one", "ready-to-deploy-and-use" solution, but rather a starting point and reference implementation for further development and adjustments to your needs.

# Open Source Strategy

All used software parts in this project are open source and can be replaced by alternatives if needed.

# Publications

The basic infrastructure for this project was published at the [Computer Frontiers 2026 conference](https://www.computingfrontiers.org/2026/), as part of a multi-partner project presentation. The paper can be downloaded [here CAPE's Composable Server Infrastructure for the Edge-Cloud Continuum.pdf](https://cape-project.eu/wp-content/uploads/2026/05/2026-05-20_CF26_CAPEs_Composable_Server_Infrastructure_web.pdf)

# Roadmap

- see [ToDo.md](ToDo.md) for detailed tasks and next steps
- Improve documentation, add more screenshots
- Test, test, test
- Harden the cluster for production use
- Generalize setup and make it work for other cloud provider --> SECAPI
- Move repository to github.com/cape-project-eu
