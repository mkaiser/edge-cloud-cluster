# ToDo

## Anchors handling for pulumi --> other code substitution via scripts/environment/updateConfigFromProjectSettings.sh

for settings substitutions (from project_settings.ts to deployment YAMLs):
I prefer a more self-exaplanatory anchor that users will quickly understand and won't touch, e.g.
instances: 3 # @anchorStart: pulumi_settings.ha.authentikPg.instances @anchorEnd
is this a good style? Does the start and end make the sed replacements in the update script more robust? make more suggestions.
Also replace the URL settings in, e.g. domain: ecc133.cape-project.eu

## project_settings

Plan:

- Refactoring chores
    - EdgeNode should inherit from ComputeNode.
      the id is just for provisioning via make, right? make provision-edge ARGS=cape-vm-lab
      if yes, make a comment behind id, e.g. "id is used for provisioning of a single node via make, e.g. make provision-edge ARGS=cape-vm-lab"
      Additional values: ssh
      What is "hardware used for"?
      Also I like a description field:, e.g. "transient testbed server in hetComp Lab with Pciegen6"

    - I dislilke the type definitions / exports at the beginning of the file. Maybe we can move them to a separate file and import them here? Just keep the actual settings in project_settings.ts

    - Move highAvailability from general. to high availability section.
      currently there are two high availabily settings:
      line 94: const highAvailability = false;
      and line 104: highAvailability: false, // when true: enforces ≥3 control-plane nodes at deploy time
      --> merge them into one

    - Rename ha: to highAvailability: to be more explicit.
    - Move LonghornReplicaCount to high availability section

    - Move the firewall settings from network.ts to project_settings.

    - Search the other src-files for hardcoded values and move them to project_settings.

    - KubeVIP stuff introduced while fixing magicDNS for edge node join :
      CP mesh IPs. Why do we need them here?
      // Drives how many CP mesh IPs we publish: HA → cp0/cp1/cp2 (.1/.2/.3); non-HA → cp0 only.

## Edge node provisioning

make provision-edge ARGS=cape-vm-lab

Log of an earlier run:  
 make provision-edge ARGS=cape-vm-lab
=== Provisioning on-premise edge node(s): cape-vm-lab ===
Updating (mystack):
Type Name Status Info
pulumi:pulumi:Stack edgecloudinfra-mystack 1 warning
└─ ecc:infra:OnPremiseNodes edge-nodes

-      ├─ command:local:Command   edge-fetch-cape-vm-lab            created (7s)
-      ├─ command:remote:Command  edge-provision-cape-vm-lab        created (2383s)
-      ├─ command:local:Command   edge-label-cape-vm-lab            created (1s)

*      ├─ command:local:Command   edge-label-pcie6-desktop-lab      deleted (0.11s)
*      ├─ command:remote:Command  edge-provision-pcie6-desktop-lab  deleted (0.11s)
*      └─ command:local:Command   edge-fetch-pcie6-desktop-lab      deleted (0.13s)

so edge-label-pcie6-desktop-lab deleted and more.
The command arg ARGS=cape-vm-lab should not touch the other edge servers, right?

skip if nodes are already provisioned. use --force parameter to provision anyway and also override tailscale

if make provision-edge is calles without ALL all edge nodes will be re-provisioned.
If they were already in the cluster they will be re-attached, which is bad. Can we prevent this? maybe by checking if they are already connected and ready?

### Test manual edge server attachment with admin portal approval

- The provisioning of edge servers via pulumi and direkt (or via VPN) ssh access works well.
  For adding edge servers which are off-site, but with physical access, we use the exported scripts.
  scripts/edge-provisioning
  Those scripts contain a pre-auth key. To prevent misuse of this key, this should be a separate from the pulumi-edge pre-auth key.
  As an additional security feature I want to require a manual approval step in the headplane admin portal before the server can join the cluster.

- We should package the provisioning scripts into a single script for taking them offline and to the new edge nodes --> /edge-provisioning/create_provisioning_package.sh

### Test Windows edge nodes

can we attach a running windows node via WSL?

prepared, but never tested: scripts/edge-provisioning/windows-kubernetes-node/README.md

## cloud servers vs. dedicated root

cloud server have gotten very expensive (by factor 8). Cost-optimized variants on Hetzner are not available anymore
January: cost-optimized: CX53 (16 cores, 32 GByte RAM) 20 €/month
June: regular performance: CPX32 (4 cores, 8 GByte RAM) 40 €/month

Research: Book a dedicated server ~60 €/month with 8 cores and 64 GByte RAM and use it as a single-node cluster for testing. This would be more cost-effective than using multiple cloud servers for the same purpose.

- How can we automize booking and provisioning the dedicated server? We cannot do this via pulumi, because the dedicated servers are only available via Hetzner Robot (no CLI).
- Maybe: book a dedicated server, leave a ssh cert and maybe we can integrate this into pulumi?

Check if https://github.com/pulumi/pulumi-terraform-bridge and

```
const hrobotProvider = new tf.Provider("hrobot", {
  provider: "midwork-finds-jobs/hrobot",
  version: "0.1.0",
  envVars: {
    HROBOT_USERNAME: "#ws+XXXXX",
    HROBOT_PASSWORD: "YYYYYY",
  },

const server = tf.getRequiredResource("hrobot_server", "auction", {
  serverId: 12345678,
}, { provider: hrobotProvider });
```

is feasible

## Storage strategy & backup

### Revise strategy

How is data stored? Do we need longhorn for edge and cloud? How much longhorn will be required at minimum?

If we want to keep a low cloud-profile and only want to put into the cloud what needs to be (basic infrastructure + AUTH + VPN services).
How much longhorn storage will this require?
Is there a big difference between High-availability and non-high-availability?

### Backup

- How to really backup / version control the cluster state with external backups?
- Use hetzner storagebox for additional long time backups
- currently only s3-bucket based backup, but no "real offsite backup".

## Reuse cluster for other projects?

can we brand this in authentik to cape and in addition to some other project and have only one dedicated cloud server?

## Renovate

Pull requests are created, but not the way I want them:

- Apply patches automatically
- Group updates for "infrastructure" (pulimi and deployment/infrastructure) and "apps" separately.
- Per group I want a "Update all minor versions" for major versions I want separate update PRs.
- Is it possible to annotate the code so grouping is done automatically at parse time?
- One "Update All" PR

## XWiki:

test github markdown syntax

## Windows VM

debug! no OIDC and argocd fail

## Test prod environment

- prod cert
- restrict firewall --> production

## Documentation

- Price update Hetzner
- Make mermaid chart of the installation steps.
  VSCode --> Hetzner secrets --> Code adaption, update script....
- Update Readme with current deployments (root readme and deployment readme)
- User management:
    - CronJob sends emails every 5 minutes.
    - How to add MFA?
- How to add Edge servers (Pulumi-based (make) vs. manual)

## Ryax deployment in argocd

Argocd deployment still does not work automatically. Manual deployment works.

# Future Stuff

## Gitlab registry:

### Create Docker images for Vivado

### Windows as DockerImage:

## Slurm integration

## proxmox hypervisor integration

## Pulumi webhook comments

Check if https://github.com/mconfalonieri/external-dns-hetzner-webhook supports DNS console comments. Useful to indicate which entries are automated by pulumi / argocd
