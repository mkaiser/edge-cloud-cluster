#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Create a Hyper-V Ubuntu VM for use as a Kubernetes edge node.

.DESCRIPTION
    Creates a Generation 2 Hyper-V VM, attaches an autoinstall ISO, and boots it.
    After autoinstall completes, run provision-hyperv-node.sh from the devcontainer
    to join the VM to the cluster.

    The VHDX disk is created in the same directory as the ISO.

.PARAMETER VMName
    Name of the VM (also used as the Kubernetes node name).

.PARAMETER RAM
    Amount of RAM, e.g. "4GB" or "8GB".

.PARAMETER StorageGB
    Disk size in GB, e.g. 60.

.PARAMETER AutoInstallIso
    Full path to the Ubuntu autoinstall ISO.

.EXAMPLE
    .\create-hyperv-vm.ps1 -VMName edge-ubuntu -RAM 4GB -StorageGB 60 -AutoInstallIso C:\isos\ubuntu-autoinstall.iso
#>

param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$RAM,
    [Parameter(Mandatory)][int]$StorageGB,
    [Parameter(Mandatory)][string]$AutoInstallIso
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Validate inputs ───────────────────────────────────────────────────────────
if (-not (Test-Path $AutoInstallIso)) {
    Write-Error "ISO not found: $AutoInstallIso"
    exit 1
}

$IsoDir   = Split-Path -Parent (Resolve-Path $AutoInstallIso)
$VhdxPath = Join-Path $IsoDir "$VMName.vhdx"

# Parse RAM string (e.g. "4GB" -> 4294967296)
$RamBytes = switch -Regex ($RAM.ToUpper()) {
    '(\d+)GB$' { [long]$Matches[1] * 1GB }
    '(\d+)MB$' { [long]$Matches[1] * 1MB }
    default    { Write-Error "Cannot parse RAM value '$RAM'. Use format like '4GB'."; exit 1 }
}

Write-Host "=== Creating Hyper-V VM: $VMName ===" -ForegroundColor Cyan
Write-Host "  RAM      : $RAM ($RamBytes bytes)"
Write-Host "  Storage  : ${StorageGB}GB -> $VhdxPath"
Write-Host "  ISO      : $AutoInstallIso"
Write-Host "  Switch   : Default Switch"

# ── Check VM does not already exist ──────────────────────────────────────────
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Error "VM '$VMName' already exists. Remove it first: Remove-VM -Name $VMName -Force"
    exit 1
}

if (Test-Path $VhdxPath) {
    Write-Error "VHDX already exists: $VhdxPath. Delete it first."
    exit 1
}

# ── Create VM ─────────────────────────────────────────────────────────────────
Write-Host "`nCreating VM..." -ForegroundColor Yellow
New-VM -Name $VMName `
       -Generation 2 `
       -MemoryStartupBytes $RamBytes `
       -SwitchName "Default Switch" | Out-Null

# ── Disable dynamic memory (Ubuntu works better with static) ──────────────────
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# ── Create and attach VHDX ────────────────────────────────────────────────────
Write-Host "Creating VHDX ($StorageGB GB)..." -ForegroundColor Yellow
New-VHD -Path $VhdxPath -SizeBytes ($StorageGB * 1GB) -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $VhdxPath

# ── Attach ISO ────────────────────────────────────────────────────────────────
Write-Host "Attaching ISO..." -ForegroundColor Yellow
Add-VMDvdDrive -VMName $VMName -Path $AutoInstallIso

# ── Disable Secure Boot (required for Ubuntu Gen 2) ───────────────────────────
Set-VMFirmware -VMName $VMName -SecureBootTemplate MicrosoftUEFICertificateAuthority

# ── Set boot order: DVD first, then disk ─────────────────────────────────────
$Dvd  = Get-VMDvdDrive  -VMName $VMName
$Disk = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -BootOrder $Dvd, $Disk

# ── Enable CPU virtualisation extensions (for KVM/QEMU inside the VM) ────────
Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true

# ── Start VM ──────────────────────────────────────────────────────────────────
Write-Host "Starting VM..." -ForegroundColor Yellow
Start-VM -Name $VMName

Write-Host ""
Write-Host "=== VM '$VMName' is booting from the autoinstall ISO ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Wait for autoinstall to complete (VM will reboot into Ubuntu)."
Write-Host "  2. Get the VM's IP address:"
Write-Host "       Get-VMNetworkAdapter -VMName $VMName"
Write-Host "  3. Add the node to project_settings.ts (nodes.edge array):"
Write-Host "       { id: `"$VMName`", sshHost: `"<VM-IP>`", sshPort: 22, sshUser: `"<user>`", location: `"martinHome`", kvm: true }"
Write-Host "  4. From the devcontainer, run:"
Write-Host "       bash scripts/edge-provisioning/windows-kubernetes-node/provision-hyperv-node.sh \"$VMName\" <ssh-user> <VM-IP>"
Write-Host ""
Write-Host "Or use 'make provision-edge ARGS=$VMName' after adding to project_settings.ts."
