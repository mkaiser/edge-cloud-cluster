# Workflow

This project is shared among others, Windows dev platform, VSCode devcontainer.

Use open source tools only

Pulumi TypeScript project deploying a Kubernetes cluster on Hetzner Cloud with ArgoCD, cert-manager Hetzner Storage.

Currently this git repository is shared by pulumi code and ArgoCD deployment code

# Debug

## Pulumi stack

If you need access to the Pulumi stack, run `source ./scripts/initPulumi.sh` in an interactive terminal. The user will insert the credentials and store them in the env

## Kubernetes

Kubeconfig is stored at `~/.kube/config` (default path). If this does not work, run `./scripts/getKubeCtrl.sh` to fetch it.

## ArgoCD CLI

you can use the argocd CLI. After 'make up' the CLI should be logged it. If this does not work, run `./scripts/argocdLoginCLI.sh` to fetch it.

## external repositories

in /external there are submodules for external projects. You can use them to search for documentations. NEVER edit them, as the path is - and never should be - referenced in this project.
