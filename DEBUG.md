# Debug

## Pulumi

`pulumi stack`

view all outputs of the stack (with URLS to click, etc)
`pulumi stack output`

Something wired / pulumi tells some old cached data?
`pulumi destroy -y`

completely destory all

```
PULUMI_K8S_DELETE_UNREACHABLE=true && pulumi destroy -y || true \
&& pulumi stack rm --force mystack -y && pulumi stack init mystack  && pulumi stack select mystack \
&& git restore {Pulumi.mystack.yaml,.pulumi-state/.pulumi/stacks/edgecloudinfra/mystack.json,.pulumi-state/.pulumi/stacks/edgecloudinfra/mystack.json.attrs} \
&& ./scripts/deleteDnsRecords.sh

```

## Pulumi secrets

`pulumi config --show-secrets`

## hcloud CLI

```
pulumi config get hcloudToken | hcloud context create default

Alternative: export HCLOUD_TOKEN=$(pulumi config get hcloudToken)

hcloud context create default
```

`hcloud image list --type system `

`hcloud server list`

Cleanup Pulumi / argocd DNS entries

hcloud dns record delete anicedomain.tld portal A

```
hcloud server-type list --output columns=name,description,cores,memory,disk,storage_type 2>&1 | head -40
```

# ArgoCD

View launched ArgoCD applications
kubectl get applications.argoproj.io -A \
 --sort-by=.metadata.creationTimestamp \
 -o custom-columns='NAMESPACE:.metadata.namespace,APP:.metadata.name,CREATED:.metadata.creationTimestamp'

## Deadlocked ArgoCD sync

`kubectl patch application opendesk -n argocd --type merge -p '{"status":{"operationState":null}`

Restart it

```
kubectl rollout restart -n argocd deployment argocd-server argocd-repo-server argocd-applicationset-controller
kubectl rollout restart -n argocd statefulset argocd-application-controller
```

## kubectl

`kubectl config view `

`kubectl cluster-info`

`kubectl -n argocd get applications`

`kubectl get nodes`

`kubectl get all -A`

`kubectl get application -n argocd`

`kubectl logs -n argocd deployment/argocd-application-controller -f`

`kubectl delete all --all -n argocd --force --grace-period=0`
`kubectl delete namespace argocd --force --grace-period=0`

Show used resources
`kubectl top node 2>&1 `

Get all Ingresses:
`kubectl get ingress -A 2>&1 `

## ARGOCD

Kill ArgoCD

`kubectl delete pods -n argocd --all `

View helmfile manifest generation

`kubectl logs -n argocd -l app.kubernetes.io/component=repo-server -c helmfile-plugin -f`

Check opendesk pod status
`kubectl get pods -n opendesk --no-headers 2>&1`

kubectl get applications -n argocd | grep opendesk

# with sync time

kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,LAST_SYNC:.status.operationState.finishedAt' | grep opendesk

kubectl rollout restart deployment argocd-repo-server -n argocd

argocd app get opendesk --hard-refresh

## DNS

kubectl get ingress hello-pulumi-ingress -n default -o jsonpath='{.status.loadBalancer}'

# OPendesk

get initial keycloak password:

`kubectl get secret -n opendesk opendesk-keycloak-bootstrap-admin-creds -o jsonpath='{.data}' 2>&1 | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print({k:base64.b64decode(v).decode() for k,v in d.items()})" 2>/dev/null`

## unreachable resources

```
pulumi stack --show-urns | grep nfs-server-backing-pvc

 pulumi state delete 'InsertNamehere' --yes 2>&1

```

Resource deleted

```
PULUMI_K8S_DELETE_UNREACHABLE=true pulumi down -y --skip-preview --timeout 30
```

```
helm uninstall argocd -n argocd
# or more aggressively:
kubectl delete namespace argocd
```

## Undeleteable namespace:

### Option 1

put this into another terminal

```
source scripts/getKubeCtrl.sh
for NS in cert-manager argocd traefik; do
  kubectl get namespace $NS -o json | grep -v "\"kubernetes\"" > /tmp/$NS.json
  sed -i "s/\"finalizers\": \[.*\]/\"finalizers\": []/" /tmp/$NS.json
  kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f /tmp/$NS.json
done
kubectl get ns
```

### Option 2

kubectl get namespace argocd -o json \
 | jq 'del(.spec.finalizers)' \
 | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -

pulumi refresh # oder direkt
pulumi up

### Option 3

kubectl patch namespace argocd -p '{"spec":{"finalizers":null}}' --type=merge
pulumi refresh # State korrigieren
pulumi up # Neu erstellen (falls nötig)

kubectl delete certificates --all -n argocd
kubectl delete certificaterequests --all -n argocd  
kubectl delete challenges --all -n argocd
pulumi dn -f

### option 4

```
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(pulumi stack output controlPlaneIP 2>/dev/null) '
for NS in cert-manager argocd traefik; do
  kubectl get namespace $NS -o json 2>/dev/null | sed "s/\"finalizers\": \[[^]]*\]/\"finalizers\": []/" | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
done
kubectl get ns
'
```

## DEBUG DNS stuff

dig +short hello.niceDomain.eu

with
dig +short hello.niceDomain.eu @8.8.8.8

## Delete Stack

pulumi stack rm --force mystack

## Cloud init provisioning log

sudo cat /var/log/cloud-init-output.log
sudo cat /var/log/cloud-init.log | grep -i "error\|warn"

sudo journalctl -u k3s -n 200 --no-pager

Filter for errors only

```
sudo journalctl -u k3s -p err --since "1 hour ago"
```

## Access metrics port

```
# Get the external-dns pod name
kubectl get pods -n external-dns

# Forward the webhook sidecar's metrics port to your local machine
kubectl port-forward -n external-dns deployment/external-dns 9979:9979

curl http://localhost:9979/metrics | grep ratelimit

```

## Add edge node (WireGuard + K3s agent)

Edge nodes connect to the Hetzner cloud via a WireGuard VPN tunnel,
then join K3s as regular worker nodes over the encrypted tunnel.

### 1. Proxmox host: Create Debian LXC

`bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"`

Select:

- Privileged
- Hostname: proxmox-edge-1
- Disk Size: 40 GB
- Allocate CPU Cores: all
- Allocate RAM: all - 1 GB
- Enable Nesting + keyctl

Check and edit config file:

```
nano /etc/pve/lxc/100.conf

arch: amd64
cores: 12
features: keyctl=1,nesting=1
hostname: proxmox-edge-1
memory: 15000
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:6C:B1:60,ip=dhcp,ip6=auto,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-100-disk-0,size=40G
swap: 512
tags: community-script;os
timezone: Europe/Berlin
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.cgroup2.devices.allow: c 188:* rwm
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/serial/by-id  dev/serial/by-id  none bind,optional,create=dir
lxc.mount.entry: /dev/ttyUSB0       dev/ttyUSB0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyUSB1       dev/ttyUSB1       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM0       dev/ttyACM0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM1       dev/ttyACM1       none bind,optional,create=file
```

## SSH stuff

kubectl get challenge -A

kubectl describe challenge -n wireguard wireguard-ui-tls-1-251032804-1467280464

kubectl delete challenge -n argocd argocd-server-tls-1-2532526060-508004393

## Watch resources

watch -n5 kubectl top nodes

## Secrets stuff / secret "wireguard-ui-secret" not found

kubectl get namespace wireguard
kubectl get sealedsecret -n wireguard / kubectl get sealedsecret -A

# Errors

```
Diagnostics:
  hcloud:index:Server (edgecloudinfra-server-k3s-worker0):
    error:   sdk-v2/provider2.go:572: sdk.helper_schema: error during placement (resource_unavailable, fb59f56b750c95e3aff2ef68661507df): provider=hcloud@1.32.1
    error: 1 error occurred:
        * error during placement (resource_unavailable, fb59f56b750c95e3aff2ef68661507df)

  pulumi:pulumi:Stack (edgecloudinfra-mystack):
    error: update failed
```

--> Server resource is currently not available @Hetzner. Select a higher-priced resource or wait
