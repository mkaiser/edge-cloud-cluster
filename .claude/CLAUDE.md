# Workflow

This project is shared among others, Windows dev platform, VSCode devcontainer.

Use open source tools only

Pulumi TypeScript project deploying a Kubernetes cluster on Hetzner Cloud with ArgoCD, cert-manager Hetzner Storage.

Currently this git repository is shared by pulumi code and ArgoCD deployment code

There is no need to keep backwards compatibily.

# Debug

## Pulumi stack

If you need access to the Pulumi stack, run `source ./scripts/initPulumi.sh` in an interactive terminal. The user will insert the credentials and store them in the env

Pulumi entrypoint: main.ts

## Kubernetes

Kubeconfig is stored at `~/.kube/config` (default path). If this does not work, run `./scripts/getKubeConfig.sh` to fetch it.

## ArgoCD CLI

you can use the argocd CLI. After 'make up' the CLI should be logged it. If this does not work, run `./scripts/argocdLoginCLI.sh` to fetch it.

### workaround using kubectl

kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=127.0.0.1 &>/tmp/argocd-pf.log &
PF_PID=$!
sleep 3
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d 2>/dev/null)
argocd login localhost:8080 --username admin --password "$ARGOCD_PASS" --insecure 2>&1
echo "PF_PID=$PF_PID"

## external repositories

in /external there are sources for external projects (openDesk, opendesk-argocd-deploy, Nubus, Ryax). You can use them to search for documentations. NEVER edit them, or refer to them in cour code.

if the repositories in external do not exist, ask the user to run scripts/checkoutExternalGits.sh

# Token opt

- Use short 3-6 word sentences
- no filler, preamble or pleasantries
- run tools first, show results then stop, don't narrate
- drop articles ("Me fix code" not "I will fix the code")

## Opendesk

CMP sidecar: deployment/opendesk-cmp, chart override: deployment/opendesk-cmp/chart-overrides.yaml

Enabled/disabled apps: deployment/opendesk-apps/value.yaml

## Ryax install

- Code is locally checked out as submodule: external/git_ryax-engine

see installation instructions: https://docs.ryax.tech/howto/install_ryax_kubernetes
