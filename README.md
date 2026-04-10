# Overview

![alt text](doc/EdgeCloud_overview.drawio.svg)

# Project Goal

- Perform most of the heavy lifting for setting up a Kubernetes cluster on Hetzner with a set of preconfigured applications, which should meet the needs of hard/software developers of SME.
- It is not meant to be an "all-in-one", "ready-to-deploy-and-use" solution, but rather a starting point and reference implementation for further development and adjustments to your needs.
- The infrastructure follows best practices in terms of reproducibility, GitOps (via ArgoCD).
- The project is meant to be modular. You can easily add/remove applications and adjust the deployment to your needs.
- openDesk is used as a base installation, especially for the user management and self-service portal. You can de-select applications you don't need.
- This project was not audited for security, so it should not be used in production environments without further adjustments and hardening.

# Cluster Bootstrapping process

## Prerequisites

- Hetzner Account
    - API Token
    - eMail address: no-reply@your-domain.tld (for lets encrypt certificate registration and eMail notifications)
    - S3 Bucket access
        - Access key
        - Secret key
        - Buckets named
            - "edgecloud-headscale"
            - "edgecloud-gitlab"
            - "edgecloud-etcd"
            - "edgecloud-nextcloud"
    - SSH Key (e.g. sshkey_ed25519_edgecloudinfra_Martin)
- Github account to fork this repo and a classic access token with pull request permissions (for renovate / automated checking for updates)
- A good Password manager, because you will create a lot secrets during the bootstrapping process, which you need to keep track of.
- Some time ~ 3 hours:
    - 1h setup (git clone, startup DevContainer, URL adjustments, enter secrets)
    - 1h passive/automated infrastructure provisioning and app deployment via ArgoCD (~40 min including gitlab on 2x CX53 (16CPU/32GB/320GB))
    - 1h login, create accounts, add edge servers via VPN, test things
    - Probably some time to give me feedback and create issues ;)

## Configuration options

- See project_settings.ts
- Find/replace: "domain.tld" with "your-actual-domain.tld"

# Bootstrapping process

1. Configuration

- adjust project_settings.ts (clustername, URLs, hetzner servers, regions)
- adjust ArgoCD-deployed OpenDesk:
  edit `deployment/argocd/opendesk-chart-overrides.yaml`

```
global:
additionalMailDomains: - "domainA.tld" - "domainB.tld" - "domainC.tld" #
```

- Create secrets

    **Step 1 — Pulumi secrets** (`./scripts/setPulumiSecrets.sh`):

    | Secret                             | Where to get it                                                      |
    | ---------------------------------- | -------------------------------------------------------------------- |
    | Hetzner API token                  | Hetzner Cloud Console → Security → API Tokens                        |
    | Hetzner S3 access key + secret key | Hetzner Console → Object Storage                                     |
    | Storagebox password                | Hetzner Console → Storage Boxes                                      |
    | ArgoCD admin password              | Choose freely (min. 8 chars)                                         |
    | ArgoCD server secret key           | Choose freely (random string, e.g. `openssl rand -hex 32`)           |
    | Sealed-secrets TLS keypair         | Generated automatically on first deploy; paste existing on re-deploy |
    | WireGuard keypairs                 | Generated automatically on first deploy; paste existing on re-deploy |

    **Step 2 — Sealed secrets** (run each `sealSecrets.sh` before `make up` — no live cluster needed):

    | Script                                              | Prompts for                                                                               |
    | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
    | `./deployment/secrets/sealSecrets.sh`               | SMTP host, port, username, password; notification recipient email                         |
    | `./deployment/argocd/sealSecrets.sh`                | _(none — generates OIDC client secret automatically)_                                     |
    | `./deployment/headscale/sealSecrets.sh`             | _(none — generates OIDC client secret automatically)_                                     |
    | `./deployment/kube-prometheus-stack/sealSecrets.sh` | Grafana admin username + password                                                         |
    | `./deployment/renovate/sealSecrets.sh`              | GitHub Classic Access Token (needs `read:packages`, `read:org`, pull request permissions) |
    | `./deployment/gitlab/sealSecrets.sh`                | GitLab root password _(only when gitlab.yaml is enabled / not suffixed with .disable)_    |

    > Sealed secrets are encrypted with the sealed-secrets public key from Pulumi config and are safe to commit.
    > Each script offers to commit and push automatically after sealing.

2. Create Infrastructure
    - add PULUMI_PASSPHRASE to your environment: `source ./scripts/initPulumi.sh`
    - invoke `make up`
    - Wait ~ 5 Minutes
    - Login to ArgoCD URL (Pulumi stack output) and monitor the server's resource usage `./scripts/printResources.sh`
    - You will receive staged email notifications as services become ready:
        1. **OpenDesk/Nubus ready** — after sync wave 2
        2. **Headscale/VPN ready** — after sync wave 5
        3. **GitLab ready** — after sync wave 6 (if enabled)
        4. **Cluster bootstrap complete** — after all waves finish
        - If a sync fails or any app goes degraded, a failure email is sent immediately.
        - Check ArgoCD UI for detailed status at any time.

3. Post-bootstrapping configuration
    - TODO
        - Test if admin wireguard VPN is working. If this does not work, the next steps will lock you out of the cluster.
        - set deployment type to "production" in project_settings.sh
        - run `make up` again to apply production settings and restrict the firewall

4. First time login to Opendesk dashboard as administrator
    - Retrieve the automatically generated administrator password: `./scripts/getNubusAdminPassword.sh`
    - Login to https://portal.testNN.domain.tld"
    - Follow the instructions and create a TOTP
      (--> select "Cannot scan QR code?" --> Copy the Key and paste it into your password manager supporting TOTP.

# Integrate on premises edge servers

1. Test if headplane is up and running: `https://headplane.testNN.domain.tld/admin/`

2. Ensure that ssh key is present on edge server

Obsolete?? BEGIN
After ArgoCD sync, retrieve preauthkey for edge servers:
`kubectl get secret headscale-preauthkey -n headscale -o jsonpath='{.data.key}' | base64 -d`
Obsolete?? END

Install on tailscale on edge server: `curl -fsSL https://tailscale.com/install.sh | sh`

`tailscale up --login-server=https://vpn.domain.tld --authkey=<key>`

copy

# FAQ:

## Why does Headplane return 404 on the root URL?

Headplane serves its UI under `/admin/`.

- Use: `https://headplane.testNN.domain.tld/admin/`
- `https://headplane.testNN.domain.tld/` returning `404` is expected.

## Why do you use OpenDesk?

It is a well maintained, open-source project with more features than we actually need, but it provides a good base for user management and a self-service portal. You can easily de-select applications you don't need.

## Minimum cloud resource requirements?

Bootstrapping works on a single CX53 server (16CPU/32GB/320GB):

- 20 GByte of DDR memory
- 1.5 of 16 CPUs (10%) are busy in idle state
- 50 GByte block SSD storage
- 1 TB object/S3 bucket storage

## What does it cost?

- 26€ monthly costs (no redundance, single control plane server):
    - 16€ Server: CX53 (16CPU/32GB/320GB)
    - 5€ 100 GByte SSD Block storage
    - 5€ Object storage / S3 bucket

- 47€ monthly costs (with high availability (HA), 3 Kubernetes control plane servers):
    - 32€ (2x 16€) server CX53 (16CPU/32GB/320GB)
    - 5€ server CX33 (4CPU/8GB/80GB)
    - 5€ 100 GByte SSD Block storage
    - 5€ Object storage / S3 bucket

## Lets encrypt staging vs. production certificates

- If you re-create the cluster multiple times within a couple of days, you might hit the rate limits of Let's Encrypt production certificates.
- I use the subdomain "\*.testNN." (incrementing number) for my tests and increment them by setting project_settings.ts`("testNumber") and running`./scripts/updateArgoCdFromProjectSettings.sh` to apply the new domain settings in ArgoCD.
- in Pulumi you can select between staging or production certificates, see `setting project_settings.ts` ("certIssuerType") and running `./scripts/updateArgoCdFromProjectSettings.sh` to apply the new domain settings in ArgoCD.
    - Hint: To open a website with an untrusted (or staging) certificate in chrome just type `thisisunsafe` in Vivaldi (probably other chrome-based browsers too)

## Why ArgoCD?

It is a well known GitOps tool, which allows us to deploy applications in a declarative way. It also provides a nice UI to monitor the deployment status and logs.

### Why don't you use a separate git repository for ArgoCD?

It is a good practise to keep cluster infrastructure and application deployment separate. Here we want to keep everything in one repository for simplicity. In a production environment with different infra/deployment teams, you might want to separate them.

## Why Hetzner?

I am hosting several private stuff on Hetzner for years and I am very happy. They offer a good balance between price and performance and up-time. They also have good API support.
So the answer is: I am familiar with Hetzner. But the code base is meant to be easily adaptable to other cloud providers, especially via SECAPI. --> Roadmap

## Helper scripts

TODO
see ./scripts

## Secrets in git - are you crazy?

In general: Bad idea! But here, the secrets are encrypted. I think this is okay if you push them in non-public repositories and if it is not a production environment.

- Pulumi: Secrets are en/decrpyted with the Pulumi_Passphrase.
- ArgoCD: Secrets are encrypted with a mechanism called SealedSecrets. You create the key for this in Pulumi and encrypt secrets for ArgoCD within the folder /deployment. Pulumi passes the key to ArgoCD, which can then decrypt thos secrets at deploy-time.

## Why testing with testNN subdomains?

I recreated the cluster around 100 times. To avoid hitting the rate limits of Let's Encrypt production certificates, I use the subdomains "\*.testNN." (incrementing number) for my tests and increment regularly (adjust project_settings.ts and run `./scripts/updateArgoCdFromProjectSettings.sh` to apply the new domain settings in ArgoCD).

Also in in my office there is a DNS proxy, which caches DNS entries with a long TTL. So after re-creating the cluster the IP addreses changed, but the DNS were still cached with the old IPs. By using different subdomains, I can avoid this issue.

# Development

## Pre-commit checks

- This repo uses a local Git hooks directory at `.githooks/`.
- Activate it in each clone with `make hooks`.
- The `pre-commit` hook runs `make precommit`, which only processes staged `*.ts` files.
- `make precommit` formats staged TypeScript files, re-stages them, then runs `npx tsc --noEmit`.
- To run checks on all TypeScript files manually, use `make precommit-all`.
- As users will customized domains, there is a script 'scripts/prepareRelease.sh' which replaces custom domains with "domain.tld" in the project_settings.ts and propagates this to argocd-deployments ('/deployment'). The script is meant to be run before creating a release and will change the domain back to your setting after you committed.

# Acknowledgements

- CAPE EU project (www.your-domain.tld)

## Open source tools used

- TODO: List all used tools with links to their gits
- TODO: Tell people to give these project a star

# Roadmap

- Test, test, test
- Harden the cluster for production use
- Generalize setup and make it work for other cloud provider --> SECAPI
- Move repository to github.com/cape-project-eu
