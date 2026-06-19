#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Connect a Windows 11 PC to the headscale VPN.

.DESCRIPTION
    Imports the Let's Encrypt staging root CA into the Windows trust store so
    Tailscale can verify the headscale TLS certificate, then connects Tailscale
    to the headscale login server.

    Run once. After this, Tailscale reconnects automatically on reboot.

.PARAMETER LoginServer
    Headscale URL, e.g. https://vpn.ecc131.cape-project.eu

.PARAMETER AuthKey
    Headscale pre-auth key (hskey-auth-...). Generate one via:
      kubectl exec -n headscale <pod> -- headscale preauthkeys create --user on-premise-resident --reusable --expiration 720h

.EXAMPLE
    .\connect-tailscale-windows.ps1 -LoginServer https://vpn.ecc131.cape-project.eu -AuthKey hskey-auth-xxx
#>

param(
    [Parameter(Mandatory)][string]$LoginServer,
    [Parameter(Mandatory)][string]$AuthKey
)

$ErrorActionPreference = "Stop"

# ── Import LE staging root CA ─────────────────────────────────────────────────
# Let's Encrypt staging certs are not trusted by default. Windows (and Tailscale's
# Go TLS) need the staging root "(STAGING) Pretend Pear X1" in the trust store.
Write-Host "=== Importing Let's Encrypt staging root CA ===" -ForegroundColor Cyan

$TempRoot = "$env:TEMP\le-staging-root-x1.pem"
Invoke-WebRequest -Uri "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem" `
    -OutFile $TempRoot -UseBasicParsing
Import-Certificate -FilePath $TempRoot -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Write-Host "  Staging root CA imported into LocalMachine\Root." -ForegroundColor Green
Remove-Item $TempRoot -Force

# Also import the staging intermediate so the chain is complete
$TempInt = "$env:TEMP\le-staging-int-e1.pem"
try {
    Invoke-WebRequest -Uri "https://letsencrypt.org/certs/staging/letsencrypt-stg-int-e1.pem" `
        -OutFile $TempInt -UseBasicParsing -ErrorAction Stop
    Import-Certificate -FilePath $TempInt -CertStoreLocation Cert:\LocalMachine\CA | Out-Null
    Write-Host "  Staging intermediate CA imported into LocalMachine\CA." -ForegroundColor Green
    Remove-Item $TempInt -Force
} catch {
    Write-Host "  (Intermediate CA fetch skipped — root alone may suffice.)" -ForegroundColor Yellow
}

# ── Verify Tailscale is installed ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Connecting Tailscale to headscale ===" -ForegroundColor Cyan

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-Error "tailscale not found in PATH. Install from https://tailscale.com/download/windows"
    exit 1
}

# ── Connect ───────────────────────────────────────────────────────────────────
tailscale login --login-server $LoginServer --authkey $AuthKey --accept-dns=false

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
tailscale status
