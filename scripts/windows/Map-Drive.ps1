<#
.SYNOPSIS
    Maps a network drive to a share on the cluster fileserver.

.DESCRIPTION
    Wraps `net use` and handles the three things that make a manual attempt fail
    with a message that does not describe the actual problem:

      1. The AD\ prefix. Explorer and net use default the domain to the LOCAL
         MACHINE name, so they send <pc-name>\alice, which the fileserver cannot
         resolve. The prompt simply comes back, which reads as a wrong password.
         This script prefixes AD\ when the username carries no domain.
      2. Cached credentials. Windows caches credentials PER SERVER - including
         failed ones - and replays them instead of re-prompting, so correcting
         the username appears not to help. Any existing connection and stored
         credential for the target server is cleared before connecting.
      3. The password is prompted for by net use itself (the trailing *), never
         taken as an argument, so it cannot land in console history or a
         transcript log.

    You must be connected to the VPN first: run vpn-connect.bat.

.PARAMETER Letter
    Drive letter to map. "x", "X" and "X:" are all accepted.

.PARAMETER Path
    UNC path of the share, e.g. \\fs-1\eda or \\fs-1\userhomes.

.PARAMETER User
    AD account name. Prompted for when omitted. AD\ is added automatically.

.PARAMETER Persist
    Reconnect this drive at sign-in. Note this persists the CONNECTION, not the
    password - see the note printed on success.

.EXAMPLE
    .\Map-Drive.ps1 -Letter X -Path \\fs-1\eda -User alice
.EXAMPLE
    .\Map-Drive.ps1 X \\fs-1\userhomes
#>
# Nothing here is Mandatory on purpose. A mandatory parameter makes PowerShell
# prompt with the bare parameter name and no help ("Path:"), which is useless to
# someone who double-clicked the .bat and has never seen a UNC path. The script
# asks for what is missing itself, with examples - see Read-Missing below.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Letter,
    [Parameter(Position = 1)]
    [string] $Path,
    [Parameter(Position = 2)]
    [string] $User,
    [switch] $Persist
)

$ErrorActionPreference = 'Stop'

# Keep this file pure ASCII - see the note in Connect-Vpn.ps1.

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "    $m" -ForegroundColor Red }

# Runs a native command with its stderr folded into the output. Under Windows
# PowerShell 5.1 a redirected native stderr line (2>$null) becomes an error
# record, and with $ErrorActionPreference = 'Stop' that aborts the script -
# net.exe and cmdkey.exe write to stderr for normal "nothing there" results.
# The exit code is left in $LASTEXITCODE.
function Invoke-Native {
    param([scriptblock] $Block)
    $ErrorActionPreference = 'Continue'   # local to this function
    & $Block 2>&1 | ForEach-Object { "$_" }
}

# ------------------------------------------------------------ arguments ----
# The shares offered by number when the path is not given. Anything else can
# still be typed as a full UNC path.
$KnownShares = @(
    @{ Unc = '\\fs-1\userhomes'; What = 'your home directory' }
    @{ Unc = '\\fs-1\eda';       What = 'EDA installer media (needs the eda-developer group)' }
)

if (-not $Letter) {
    Write-Host 'Which drive letter should the share appear as?'
    Write-Host '  A single letter, for example X. Pick one that is not already a disk on'
    Write-Host '  this PC (C: is the local disk).'
    $Letter = Read-Host 'Drive letter'
}

$drive = $Letter.Trim().TrimEnd(':').ToUpper()
if ($drive -notmatch '^[A-Z]$') {
    Write-Err2 "Not a drive letter: '$Letter'. Use a single letter, e.g. X"
    exit 1
}

if (-not $Path) {
    Write-Host ''
    Write-Host 'Which share should be mapped?'
    for ($i = 0; $i -lt $KnownShares.Count; $i++) {
        '  {0}) {1,-20} {2}' -f ($i + 1), $KnownShares[$i].Unc, $KnownShares[$i].What | Write-Host
    }
    Write-Host '  or type a full path of the form \\server\share'
    $answer = (Read-Host 'Share [1]').Trim()
    if (-not $answer) { $answer = '1' }
    # A bare number picks from the list; anything else is taken as a path.
    if ($answer -match '^[0-9]+$' -and
        [int]$answer -ge 1 -and [int]$answer -le $KnownShares.Count) {
        $Path = $KnownShares[[int]$answer - 1].Unc
        Write-Ok "Using $Path"
    } else {
        $Path = $answer
    }
}

$unc = $Path.Trim().TrimEnd('\')
if ($unc -notmatch '^\\\\[^\\]+\\[^\\]+') {
    Write-Err2 "Not a share path: '$Path'"
    Write-Host '    Expected the form \\server\share, for example:'
    Write-Host '      \\fs-1\eda'
    Write-Host '      \\fs-1\userhomes'
    exit 1
}
# Server component, for the credential-cache entries: they are keyed by server
# name, and \\fs-1 and \\192.168.1.237 are SEPARATE entries.
$server = ($unc -split '\\')[2]

if (-not $User) {
    Write-Host ''
    Write-Host 'Which account should connect?'
    Write-Host '  Your AD account name, without a domain - the AD\ prefix is added for you.'
    Write-Host '  This is your normal work account, not a Tailscale login.'
    $User = (Read-Host 'Account name').Trim()
    if (-not $User) { Write-Err2 'No account name given.'; exit 1 }
}

# Prefix the domain unless one is already present in either accepted form.
# Case does not matter to the fileserver for either half.
if ($User -notmatch '[\\@]') {
    $account = "AD\$User"
    Write-Ok "Using $account (the AD\ prefix is required from Windows)."
} else {
    $account = $User
}

# ------------------------------------------------------- in use already ----
$null = Invoke-Native { net use "${drive}:" }
if ($LASTEXITCODE -eq 0) {
    Write-Warn2 "${drive}: is already in use. Disconnecting it first."
    $out = Invoke-Native { net use "${drive}:" /delete /y }
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 "Could not disconnect ${drive}: (exit code $LASTEXITCODE):"
        $out | Where-Object { $_.Trim() } | ForEach-Object { Write-Err2 "  $_" }
        Write-Warn2 "Close anything that has files on ${drive}: open, or run unmap-drive.bat $drive"
        exit 1
    }
} elseif ([IO.Directory]::GetLogicalDrives() -contains "${drive}:\") {
    Write-Err2 "${drive}: is already taken by a local disk or a mapping net use cannot see."
    Write-Warn2 "Run unmap-drive.bat $drive, or pick a different letter."
    exit 1
}

# --------------------------------------------------------- clear caches ----
# Both are expected to fail when there is nothing cached; that is not an error,
# so their output and exit codes are discarded.
Write-Step "Clearing any cached credential for $server"
$null = Invoke-Native { net use $unc /delete /y }
$null = Invoke-Native { cmdkey "/delete:$server" }

# -------------------------------------------------------------- connect ----
Write-Step "Mapping ${drive}: to $unc"
Write-Host "    Enter the password for $account when prompted."
Write-Host ''

$netArgs = @('use', "${drive}:", $unc, "/user:$account", '*')
if ($Persist) { $netArgs += '/persistent:yes' }

& net @netArgs
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Host ''
    Write-Err2 "Could not map the drive (exit code $rc)."
    Write-Host ''
    Write-Warn2 'Most likely causes, in order:'
    Write-Warn2 '  - Not connected to the VPN. Run vpn-connect.bat and check the tray icon.'
    Write-Warn2 '  - Wrong password. The account is your AD account, not a Tailscale login.'
    Write-Warn2 "  - No access to this share. The 'eda' share needs the eda-developer group."
    Write-Host ''
    Write-Warn2 'To separate a name-resolution problem from a routing one, try the'
    Write-Warn2 'fileserver by IP instead:'
    Write-Host "      map-drive.bat $drive \\192.168.1.237\$(($unc -split '\\')[3]) $User" -ForegroundColor White
    exit $rc
}

Write-Host ''
Write-Ok "${drive}: is now mapped to $unc"

# A drive mapped from an elevated shell lives in a different logon session and is
# invisible to a normal Explorer - the usual reason a mapping "worked but does
# not show up". Report it rather than failing: the mapping IS valid here.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (([Security.Principal.WindowsPrincipal]$id).IsInRole(
     [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Warn2 'This window is running as Administrator, so the drive will NOT appear in'
    Write-Warn2 'Explorer - the two run as separate sessions. Re-run it in a normal window.'
}

if (-not $Persist) {
    Write-Host ''
    Write-Host '    To have this drive come back after a restart, add -Persist:'
    Write-Host "      map-drive.bat $drive $unc $User -Persist" -ForegroundColor White
    Write-Host '    and save the password so it is not asked for again:'
    Write-Host "      cmdkey /add:$server /user:$account /pass" -ForegroundColor White
} else {
    Write-Host ''
    Write-Host '    -Persist reconnects the drive at sign-in, but not the password.'
    Write-Host '    To store that too:'
    Write-Host "      cmdkey /add:$server /user:$account /pass" -ForegroundColor White
}
