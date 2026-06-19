#!/bin/bash
# provision-hyperv-node.sh — Build a self-contained bundle for a Hyper-V edge node.
#
# Run from the devcontainer. Generates filled provisioning scripts and packages
# them into a zip that you copy to the Windows PC and run on the Ubuntu VM.
#
# Usage:
#   bash provision-hyperv-node.sh <node-id> [ssh-user] [ssh-port] [location]
#
# Arguments:
#   node-id   k8s node name (must match id in project_settings.ts nodes.edge)
#   ssh-user  SSH user on the VM (default: cape)
#   ssh-port  SSH port on the VM (default: 22)
#   location  ecc/location label value (default: martinHome)
#
# Output:
#   tmp/provisioning/edge-bundle-<node-id>.zip
#
# Workflow:
#   1. Run this script from devcontainer → produces edge-bundle-<node-id>.zip
#   2. Copy the zip to the Windows PC (USB, shared folder, etc.)
#   3. On Windows: unzip, then run deploy-to-vm.ps1 (copies scripts into the VM
#      via Hyper-V VMConnect file copy or PowerShell Direct, then executes them)
#   4. After the VM joins: run this script again with --post to apply labels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GENERATE_SCRIPT="$ROOT_DIR/scripts/runtime/generateEdgeJoinScript.sh"
OUTPUT_DIR="$ROOT_DIR/tmp/provisioning"
PROJECT_SETTINGS="$ROOT_DIR/project_settings.ts"

# ── Args ──────────────────────────────────────────────────────────────────────
if [ "$#" -lt 1 ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 <node-id> [ssh-user] [ssh-port] [location]" >&2
  echo "       $0 --post <node-id> [location]   (run after VM has joined: apply labels)" >&2
  exit 1
fi

# Post-join labeling mode
if [ "$1" = "--post" ]; then
  NODE_ID="${2:?node-id required for --post}"
  LOCATION="${3:-martinHome}"
  echo "=== Post-join: applying labels to $NODE_ID ==="
  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: kubectl not connected." >&2; exit 1
  fi
  kubectl get node "$NODE_ID" &>/dev/null \
    || { echo "ERROR: node '$NODE_ID' not registered yet." >&2; exit 1; }
  kubectl label node "$NODE_ID" \
    node-role.kubernetes.io/edge=edge \
    node.kubernetes.io/edge-worker=true \
    "ecc/location=${LOCATION}" \
    ecc/kvm=true \
    --overwrite
  kubectl get node "$NODE_ID"
  echo "Done. Run 'make provision-edge ARGS=$NODE_ID' for future re-provisioning."
  exit 0
fi

NODE_ID="$1"
SSH_USER="${2:-cape}"
SSH_PORT="${3:-22}"
LOCATION="${4:-martinHome}"

echo "=== Hyper-V Edge Node Bundle Generator ==="
echo "  Node ID  : $NODE_ID"
echo "  SSH user : $SSH_USER  (port $SSH_PORT)"
echo "  Location : $LOCATION"

# ── Warn if node not in project_settings.ts ───────────────────────────────────
if ! grep -q "\"${NODE_ID}\"" "$PROJECT_SETTINGS"; then
  echo ""
  echo "WARNING: '$NODE_ID' not found in project_settings.ts nodes.edge." >&2
  echo "Add it so 'make provision-edge ARGS=$NODE_ID' works in future:" >&2
  echo ""
  echo "  {" >&2
  echo "    id: \"$NODE_ID\"," >&2
  echo "    sshHost: \"<VM-IP>\","  >&2
  echo "    sshPort: $SSH_PORT," >&2
  echo "    sshUser: \"$SSH_USER\"," >&2
  echo "    location: \"${LOCATION}\"," >&2
  echo "    kvm: true," >&2
  echo "  }," >&2
  echo ""
fi

# ── Verify kubectl ────────────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl not connected. Run: ./scripts/runtime/getKubeConfig.sh" >&2
  exit 1
fi

# ── Generate filled scripts ───────────────────────────────────────────────────
echo ""
echo "Fetching cluster inputs and generating scripts..."
bash "$GENERATE_SCRIPT"

# ── Build bundle zip ──────────────────────────────────────────────────────────
BUNDLE_NAME="edge-bundle-${NODE_ID}"
BUNDLE_DIR="$OUTPUT_DIR/$BUNDLE_NAME"
BUNDLE_ZIP="$OUTPUT_DIR/${BUNDLE_NAME}.zip"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Copy the filled scripts
cp "$OUTPUT_DIR/0_install_prerequisites.sh" "$BUNDLE_DIR/"
cp "$OUTPUT_DIR/1_connectVPN.sh"            "$BUNDLE_DIR/"
cp "$OUTPUT_DIR/2_joinCluster.sh"           "$BUNDLE_DIR/"

# Generate a run-on-vm.sh that runs the three scripts in order
cat > "$BUNDLE_DIR/run-on-vm.sh" << RUNEOF
#!/bin/bash
# run-on-vm.sh — Run all provisioning steps on this VM.
# Copy this directory to the VM and run: sudo bash run-on-vm.sh
set -euo pipefail
cd "\$(dirname "\$0")"
echo "=== Step 1/3: Prerequisites ==="
sudo bash 0_install_prerequisites.sh
echo ""
echo "=== Step 2/3: VPN ==="
sudo bash 1_connectVPN.sh
echo ""
echo "=== Step 3/3: Join cluster ==="
sudo bash 2_joinCluster.sh --node-name=${NODE_ID} --force
echo ""
echo "Done. The node should now appear in: kubectl get nodes"
echo "From the devcontainer, run:"
echo "  bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh --post ${NODE_ID}"
RUNEOF
chmod +x "$BUNDLE_DIR/run-on-vm.sh"

# Generate a PowerShell helper that copies files into the VM and runs them
cat > "$BUNDLE_DIR/deploy-to-vm.ps1" << PSEOF
#Requires -Version 5.1
<#
.SYNOPSIS
    Copy provisioning scripts into the Hyper-V VM and run them.
.DESCRIPTION
    Uses PowerShell Direct (no network needed) to push files into the VM
    and execute the provisioning sequence.
    Requires the VM to be running and the guest credentials to be known.
.PARAMETER VMName
    Name of the Hyper-V VM (as shown in Hyper-V Manager).
.PARAMETER GuestUser
    Username inside the Ubuntu VM.
.PARAMETER GuestPassword
    Password for the guest user.
.EXAMPLE
    .\deploy-to-vm.ps1 -VMName edge-ubuntu -GuestUser cape -GuestPassword secret
#>
param(
    [Parameter(Mandatory)][string]\$VMName,
    [Parameter(Mandatory)][string]\$GuestUser,
    [Parameter(Mandatory)][SecureString]\$GuestPassword
)

\$ErrorActionPreference = "Stop"
\$ScriptDir = Split-Path -Parent \$MyInvocation.MyCommand.Path
\$Cred = New-Object PSCredential(\$GuestUser, \$GuestPassword)

Write-Host "=== Deploying provisioning scripts to VM: \$VMName ===" -ForegroundColor Cyan

# Check VM is running
\$vm = Get-VM -Name \$VMName -ErrorAction Stop
if (\$vm.State -ne "Running") {
    Write-Error "VM '\$VMName' is not running (state: \$(\$vm.State)). Start it first."
    exit 1
}

# Files to copy into the VM
\$files = @(
    "0_install_prerequisites.sh",
    "1_connectVPN.sh",
    "2_joinCluster.sh",
    "run-on-vm.sh"
)

Write-Host "Copying scripts into VM via PowerShell Direct..."
foreach (\$f in \$files) {
    \$src = Join-Path \$ScriptDir \$f
    \$content = Get-Content \$src -Raw
    # Write file into VM home directory
    Invoke-Command -VMName \$VMName -Credential \$Cred -ScriptBlock {
        param(\$name, \$text)
        Set-Content -Path "/home/\$env:USER/\$name" -Value \$text -NoNewline
    } -ArgumentList \$f, \$content
    Write-Host "  Copied: \$f"
}

Write-Host ""
Write-Host "Running provisioning inside VM..." -ForegroundColor Yellow
Invoke-Command -VMName \$VMName -Credential \$Cred -ScriptBlock {
    chmod +x ~/run-on-vm.sh ~/0_install_prerequisites.sh ~/1_connectVPN.sh ~/2_joinCluster.sh
    sudo bash ~/run-on-vm.sh
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "From the devcontainer, apply node labels:"
Write-Host "  bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh --post ${NODE_ID}"
PSEOF

# Zip the bundle
rm -f "$BUNDLE_ZIP"
(cd "$OUTPUT_DIR" && zip -r "${BUNDLE_NAME}.zip" "$BUNDLE_NAME/" -x "*.DS_Store")

echo ""
echo "=== Bundle ready ==="
echo ""
echo "  $BUNDLE_ZIP"
echo ""
echo "Steps:"
echo "  1. Copy $BUNDLE_ZIP to the Windows PC"
echo "  2. Unzip it"
echo "  3. In Hyper-V Manager, use 'Connect' to open a VM console and copy the"
echo "     scripts in, OR run deploy-to-vm.ps1 (PowerShell Direct, no network needed):"
echo ""
echo "     .\\deploy-to-vm.ps1 -VMName <vm-name> -GuestUser $SSH_USER -GuestPassword (Read-Host -AsSecureString)"
echo ""
echo "  4. Inside the VM console, you can also run manually:"
echo "     sudo bash run-on-vm.sh"
echo ""
echo "  5. After the VM joins, from the devcontainer:"
echo "     bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh --post $NODE_ID"
