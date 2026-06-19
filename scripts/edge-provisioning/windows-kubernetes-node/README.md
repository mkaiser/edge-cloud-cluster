# Windows Hyper-V Kubernetes Edge Node

Add a Windows 11 PC as a Kubernetes edge node by running an Ubuntu VM under Hyper-V.

The devcontainer and the Windows PC are on separate networks — provisioning uses
a **self-contained bundle** that you copy manually (USB, shared folder, etc.).

## Prerequisites

- Windows 11 with Hyper-V enabled
- An Ubuntu autoinstall ISO (with SSH and your user pre-configured)
- Devcontainer running with kubectl connected to the cluster

---

## Step 1 — Create the VM (Windows, PowerShell as Administrator)

```powershell
.\scripts\edge-provisioning\windows-kubernetes-node\create-hyperv-vm.ps1 `
    -VMName    edge-ubuntu `
    -RAM       4GB `
    -StorageGB 60 `
    -AutoInstallIso C:\isos\ubuntu-autoinstall.iso
```

Wait for autoinstall to complete (VM reboots into Ubuntu).

---

## Step 2 — Add the node to project_settings.ts (devcontainer)

Get the VM's IP on Windows:
```powershell
Get-VMNetworkAdapter -VMName edge-ubuntu
```

Add an entry to `nodes.edge` in `project_settings.ts`:
```typescript
{
    id: "edge-ubuntu",       // lowercase, no spaces — becomes the k8s node name
    sshHost: "<VM-IP>",
    sshPort: 22,
    sshUser: "cape",
    location: "martinHome",
    kvm: true,
},
```

---

## Step 3 — Generate the bundle (devcontainer)

```bash
bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh edge-ubuntu
```

This calls `generateEdgeJoinScript.sh` (mints auth key, fetches CA cert and k3s token)
and produces a self-contained zip:

```
tmp/provisioning/edge-bundle-edge-ubuntu.zip
```

---

## Step 4 — Copy the bundle to Windows and deploy

Copy the zip to the Windows PC (USB drive, shared folder, etc.), then unzip it.

**Option A — PowerShell Direct** (no network needed, uses Hyper-V host→guest channel):
```powershell
cd edge-bundle-edge-ubuntu
.\deploy-to-vm.ps1 -VMName edge-ubuntu -GuestUser cape -GuestPassword (Read-Host -AsSecureString)
```

**Option B — VM console** (open Hyper-V Manager → Connect):
Copy the scripts into the VM manually, then inside the VM:
```bash
sudo bash run-on-vm.sh
```

---

## Step 5 — Apply labels (devcontainer, after VM has joined)

```bash
bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh --post edge-ubuntu
```

Verify:
```bash
kubectl get nodes
kubectl top node edge-ubuntu   # metrics appear after ~90s
```

---

## Re-provisioning

After cluster recreation (`make create`), regenerate a fresh bundle and redeploy:
```bash
bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh edge-ubuntu
# copy zip to Windows, run deploy-to-vm.ps1 again
bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh --post edge-ubuntu
```

Or if the devcontainer can reach the VM directly (e.g. via VPN):
```bash
make provision-edge ARGS=edge-ubuntu
```

---

## Notes

- The Default Switch gives the VM a DHCP address that may change on reboot.
  For a stable IP, configure a static address in `/etc/netplan/` on the Ubuntu VM.
- `ecc/kvm=true` is set so the Windows VM workload (QEMU/KVM) can schedule here.
- The bundle contains a pre-auth key valid for 30 days — regenerate if it expires.
