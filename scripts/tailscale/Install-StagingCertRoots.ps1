<#
.SYNOPSIS
    Installs the Let's Encrypt STAGING trust anchors into the Windows 11
    machine trust store, so a Tailscale client can reach the cluster's
    headscale control server while the cluster issues staging certificates.

.DESCRIPTION
    While `certIssuerType` in project_settings.ts is "letsencrypt-staging", every
    cluster host serves a certificate signed by Let's Encrypt's STAGING CA, which
    no operating system trusts. headscale is healthy, but `tailscale up` aborts on
    the TLS handshake and there is no client-side --insecure to work around it.

    This installs the two staging ROOTS into LocalMachine\Root. Idempotent -
    re-running it re-verifies and reports what is already present.

    STAGING CERTIFICATES ARE NOT SECURE. Let's Encrypt publishes the staging
    keys' existence openly and issues to anyone for any name without the
    validation the production CA applies. Trusting these roots means any holder of
    a staging certificate can impersonate ANY site to this machine. Install them
    on a lab/dev machine only, never on one that handles anything of value, and
    remove them with -Remove when the cluster moves to letsencrypt-prod.

    The real fix is switching the cluster to letsencrypt-prod (see the TLS section
    of CLAUDE.md). Use this only when staging must stay.

.PARAMETER Verify
    Do not install anything. Report which roots are present and probe the live
    control server's TLS chain.

.PARAMETER Remove
    Uninstall the staging roots (do this once the cluster serves prod certs).

.PARAMETER Server
    Control-server host to probe, e.g. vpn.<subdomain>.<domain>. Mandatory: it changes on
    every cluster recreate, and this file is outside the settings engine's reach (it scans
    deployment/, src/provisioning-scripts/ and README.md), so a default here would silently
    go stale and probe a cluster that no longer exists.

.EXAMPLE
    .\Install-StagingCertRoots.ps1 -Server vpn.mycluster.mydomain.tld
.EXAMPLE
    .\Install-StagingCertRoots.ps1 -Server vpn.mycluster.mydomain.tld -Verify
.EXAMPLE
    .\Install-StagingCertRoots.ps1 -Server vpn.mycluster.mydomain.tld -Remove
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,
    [switch] $Verify,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

# Keep this file pure ASCII. Windows PowerShell 5.1 - still the default shell on
# Windows 11 - decodes a BOM-less file as ANSI (Windows-1252), so a UTF-8 em-dash
# or similar becomes three garbage characters. That shifts every column after it
# and breaks the next string literal, producing parser errors pointing at lines
# that are actually fine ("Die Zeichenfolge hat kein Abschlusszeichen").
# .gitattributes checks this out as CRLF; ASCII content makes the encoding moot.

# The trust anchors. Only the self-signed ROOTS belong here - the chain the
# cluster serves ends in "(STAGING) Yonder Yam Root YR", which despite its name
# is an INTERMEDIATE cross-signed by Pretend Pear X1, so X1 is the actual anchor.
# Installing Yonder Yam instead of X1 does NOT establish trust. Verified against
# the live chain on 2026-09-04: leaf -> Dastardly Durum YR1 -> Yonder Yam Root YR
# -> Pretend Pear X1.
# X2 (Bogus Broccoli, ECDSA) does not anchor today's chain but is the staging
# counterpart to prod's ISRG Root X2 and costs nothing to trust alongside X1.
$Roots = @(
    @{ Name        = '(STAGING) Pretend Pear X1'
       Url         = 'https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem'
       Thumbprint  = '66493BA4F36D1731729B1118C7F5E2D540E3F37B' }   # SHA-1
    @{ Name        = '(STAGING) Bogus Broccoli X2'
       Url         = 'https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem'
       Thumbprint  = 'A465AF9AF04F1A86A2701B987B3ED3A75D50ECEA' }   # SHA-1
)

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "    $m" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated (Administrator) PowerShell - it writes the machine trust store.'
    }
}

function Get-InstalledRoot {
    param([string]$Thumbprint)
    Get-ChildItem -Path Cert:\LocalMachine\Root |
        Where-Object { $_.Thumbprint -eq $Thumbprint } |
        Select-Object -First 1
}

# ----------------------------------------------------------------- verify ----
function Test-ControlServer {
    param([string]$HostName)

    Write-Step "Probing https://$HostName/health"

    # Trust is evaluated by the OS here on purpose: this is the same decision the
    # Tailscale client makes, so a pass means `tailscale up` will get through.
    try {
        $r = Invoke-WebRequest -Uri "https://$HostName/health" -TimeoutSec 20 -UseBasicParsing
        Write-Ok "TLS chain trusted, HTTP $($r.StatusCode) - tailscale up will work"
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'trust|SSL|TLS|secure channel|certificate') {
            Write-Err2 "TLS NOT trusted: $msg"
        } else {
            Write-Warn2 "Could not reach the server ($msg)"
            Write-Warn2 'If this is a network/DNS failure rather than TLS, the roots may still be fine.'
        }
        return $false
    }
}

function Show-State {
    param([string]$HostName)
    Write-Step 'Staging roots in LocalMachine\Root'
    foreach ($r in $Roots) {
        $c = Get-InstalledRoot -Thumbprint $r.Thumbprint
        if ($c) { Write-Ok    "present : $($r.Name)  (expires $($c.NotAfter.ToString('yyyy-MM-dd')))" }
        else    { Write-Warn2 "MISSING : $($r.Name)" }
    }
    Test-ControlServer -HostName $HostName | Out-Null
}

if ($Verify) {
    Show-State -HostName $Server
    return
}

# ----------------------------------------------------------------- remove ----
if ($Remove) {
    Assert-Admin
    foreach ($r in $Roots) {
        Write-Step "Removing $($r.Name)"
        $c = Get-InstalledRoot -Thumbprint $r.Thumbprint
        if (-not $c) { Write-Warn2 'not installed, nothing to do'; continue }
        $store = Get-Item Cert:\LocalMachine\Root
        $store.Open('ReadWrite')
        $store.Remove($c)
        $store.Close()
        Write-Ok 'removed'
    }
    Write-Step 'Done'
    Write-Warn2 'Staging certificates are no longer trusted. Any host still serving one will fail.'
    return
}

# ---------------------------------------------------------------- install ----
Assert-Admin

Write-Warn2 'WARNING: Trusting a STAGING CA lets any holder of a staging certificate impersonate'
Write-Warn2 '  ANY site to this machine. Lab/dev machines only. Remove with -Remove once the'
Write-Warn2 '  cluster switches to letsencrypt-prod.'
Write-Host ''

$tmp = Join-Path $env:TEMP "le-staging-roots-$PID"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    foreach ($r in $Roots) {
        Write-Step $r.Name

        if (Get-InstalledRoot -Thumbprint $r.Thumbprint) {
            Write-Ok 'already trusted, skipping'
            continue
        }

        $pem = Join-Path $tmp ((Split-Path $r.Url -Leaf))
        Invoke-WebRequest -Uri $r.Url -OutFile $pem -TimeoutSec 30 -UseBasicParsing

        # Pin the download by thumbprint BEFORE trusting it. Fetching a root over
        # TLS and then trusting whatever arrived would defeat the point: this
        # machine does not yet trust the CA that signed it, and the whole reason
        # the script exists is that the chain cannot be validated. The expected
        # SHA-1 above is the only thing that makes the fetch safe.
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pem)
        if ($cert.Thumbprint -ne $r.Thumbprint) {
            throw ("Thumbprint mismatch for $($r.Name).`n" +
                   "  expected $($r.Thumbprint)`n" +
                   "  got      $($cert.Thumbprint)`n" +
                   'Refusing to install. Either Let''s Encrypt rotated this root ' +
                   '(check https://letsencrypt.org/docs/staging-environment/ and update ' +
                   'the thumbprint here) or the download was tampered with.')
        }
        Write-Ok "thumbprint verified ($($cert.Thumbprint))"

        Import-Certificate -FilePath $pem -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Ok "installed, expires $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if (Test-ControlServer -HostName $Server) {
    Write-Host ''
    Write-Step 'Next step'
    Write-Ok "tailscale up --login-server=https://$Server --accept-routes"
} else {
    Write-Host ''
    Write-Warn2 'The roots are installed but the server still does not validate.'
    Write-Warn2 'Re-check the served chain - the staging intermediate may now anchor to a'
    Write-Warn2 'different root than the two pinned in this script:'
    Write-Warn2 "  openssl s_client -connect ${Server}:443 -servername $Server -showcerts"
}
