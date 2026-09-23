<#
.SYNOPSIS
    Connects this Windows machine to the cluster's self-hosted Tailscale VPN.

.DESCRIPTION
    Wraps `tailscale up` with the two options that are not optional here:

      --login-server   points the client at the cluster's own headscale rather
                       than the Tailscale SaaS. Needs the full URL including
                       https:// - without the scheme the client fails silently,
                       printing nothing and never contacting the server.
      --accept-routes  required to reach the lab LAN (192.168.1.0/24). Without
                       it the client joins but the fileserver stays unreachable,
                       which looks like a firewall problem and is not.

    Both are composed by this script, so neither can be forgotten or mistyped.

    Before connecting it checks that Tailscale is installed, and whether the
    client is already logged in to a DIFFERENT control server - the Tailscale
    SaaS, or a previous cluster. `tailscale up` refuses that switch on its own
    ("can't change --login-server without --force-reauth"), so the script
    detects the case and explains it in this cluster's terms.

    The server default is rewritten by
    scripts/environment/updateConfigFromProjectSettings.sh, so after a cluster
    recreate a fresh copy of this script needs no edit. Copies already on a
    laptop do go stale - pass -Server to override.

.PARAMETER Server
    Control-server host, without a scheme (vpn.<subdomain>.<domain>). Defaults
    to this cluster; override it to reach a different one.

.PARAMETER Status
    Report the connection state and exit. Changes nothing.

.PARAMETER Force
    Skip the confirmation prompt shown when the machine is currently attached to
    a foreign tailnet and connecting here would detach it.

.EXAMPLE
    .\Connect-Vpn.ps1
.EXAMPLE
    .\Connect-Vpn.ps1 -Status
.EXAMPLE
    .\Connect-Vpn.ps1 -Server vpn.<subdomain>.<domain>
#>
[CmdletBinding()]
param(
    [string] $Server = 'vpn.subdomain1.your-domain.tld', # automatically updated from project-settings:{general.subdomain,general.domain}
    [switch] $Status,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Keep this file pure ASCII. Windows PowerShell 5.1 - still the default shell on
# Windows 11 - decodes a BOM-less file as ANSI (Windows-1252), so a UTF-8 dash or
# arrow becomes three garbage characters, shifting every column after it and
# breaking the next string literal. .gitattributes checks this out as CRLF.

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "    $m" -ForegroundColor Red }

# ------------------------------------------------------------- installed? ----
# The installer does not reliably put tailscale.exe on PATH, so a PATH-only check
# reports "not installed" on a machine that has it. Look in the default install
# locations too, and return the resolved path so every later call uses it.
function Find-Tailscale {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $candidate = Join-Path $base 'Tailscale\tailscale.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$TS = Find-Tailscale
if (-not $TS) {
    Write-Err2 'Tailscale is not installed on this machine.'
    Write-Host ''
    Write-Host '    Download and install it from:'
    Write-Host '      https://tailscale.com/download/windows' -ForegroundColor White
    Write-Host ''
    Write-Warn2 'During setup, do NOT sign in to Tailscale itself.'
    Write-Warn2 'This VPN is self-hosted - signing in to the Tailscale service joins the'
    Write-Warn2 'wrong network. Just install it, then run this script again.'
    exit 1
}
Write-Ok "Tailscale found: $TS"

# ---------------------------------------------------------------- status ----
if ($Status) {
    Write-Step 'Connection status'
    & $TS status
    Write-Step 'Network check'
    & $TS netcheck
    exit $LASTEXITCODE
}

# ------------------------------------------------- already on a tailnet? ----
# `tailscale status --json` does not carry the control URL; Prefs does. This call
# fails when the service is not running, which is a normal state - hence
# SilentlyContinue rather than letting $ErrorActionPreference abort the script.
# Setting $ErrorActionPreference inside these functions is deliberate: under
# Windows PowerShell 5.1, redirected native stderr (2>$null) turns into an error
# record that 'Stop' would escalate into aborting the script.
function Get-CurrentControlHost {
    $ErrorActionPreference = 'Continue'
    $raw = & $TS debug prefs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try {
        $url = ($raw | ConvertFrom-Json).ControlURL
    } catch {
        return $null
    }
    # Empty means the daemon has never been started: a fresh install, not a
    # foreign tailnet.
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    try   { return ([Uri]$url).Host }
    catch { return $null }
}

# Whether the daemon is actually Running. This matters because tailscale up only
# REFUSES a control-server change in that state; when it is stopped or logged out
# the switch goes through on its own, and passing --force-reauth anyway would
# force a needless browser sign-in.
function Test-BackendRunning {
    $ErrorActionPreference = 'Continue'
    $raw = & $TS status --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $false }
    try   { return (($raw | ConvertFrom-Json).BackendState -eq 'Running') }
    catch { return $false }
}

# The Tailscale SaaS is exactly these two hosts.
$SaasHosts = @('login.tailscale.com', 'controlplane.tailscale.com')

$currentHost = Get-CurrentControlHost
$forceReauth = $false

if ($currentHost) {
    if ($currentHost -ieq $Server) {
        Write-Ok "Already pointed at this cluster ($Server)."
    }
    elseif ($SaasHosts -contains $currentHost.ToLower()) {
        # Worth a warning: the user may be on a tailnet they did not intend to leave.
        Write-Warn2 "This machine is currently signed in to the Tailscale service ($currentHost)."
        Write-Warn2 'Connecting to the cluster VPN will DETACH it from that network.'
        if (-not $Force) {
            $answer = Read-Host '    Continue? [y/N]'
            if ($answer -notmatch '^[Yy]') {
                Write-Host '    Aborted. Nothing was changed.'
                exit 1
            }
        }
        $forceReauth = Test-BackendRunning
    }
    else {
        # The ordinary path after a cluster recreate: the subdomain changes and
        # every client must be re-pointed. Not an error, so no scare text.
        Write-Step "Switching control server: $currentHost -> $Server"
        $forceReauth = Test-BackendRunning
    }
}

# ------------------------------------------------------------- connect ----
$loginServer = "https://$Server"
$tsArgs = @('up', "--login-server=$loginServer", '--accept-routes')
if ($forceReauth) { $tsArgs += '--force-reauth' }

Write-Step "Connecting to $loginServer"
Write-Host '    A browser window or URL will appear. Sign in with your normal account.'
Write-Host ''

& $TS @tsArgs
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Host ''
    Write-Err2 "tailscale up failed (exit code $rc)."
    Write-Host ''
    Write-Warn2 'If the error mentions a certificate, the cluster is still issuing STAGING'
    Write-Warn2 'certificates, which Windows does not trust. Install the staging roots once:'
    Write-Host "      scripts\tailscale\install-staging-cert-roots.bat -Server $Server" -ForegroundColor White
    Write-Host ''
    Write-Warn2 'If nothing at all was printed above, check you are not on a network that'
    Write-Warn2 'blocks outbound HTTPS to cloud hosts - try a different network.'
    exit $rc
}

Write-Host ''
Write-Ok 'Connected.'
Write-Host ''
Write-Host '    Check the Tailscale icon in the notification area, bottom right of the'
Write-Host '    screen next to the clock. It may be hidden behind the "^" arrow that'
Write-Host '    holds overflow icons - click that to see it.'
Write-Host ''
Write-Host '    The icon must show "Connected" before network drives will work. It is'
Write-Host '    also the only ongoing sign that the VPN is still up: if a mapped drive'
Write-Host '    stops responding later, check the icon first.'
Write-Host ''
Write-Host '    Next, map a drive:'
Write-Host '      map-drive.bat X \\fs-1\eda <your-account>' -ForegroundColor White
