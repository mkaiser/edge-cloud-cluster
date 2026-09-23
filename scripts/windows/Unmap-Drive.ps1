<#
.SYNOPSIS
    Disconnects a mapped network drive and forgets its stored password.

.DESCRIPTION
    Runs `net use <letter>: /delete`, and also removes the matching Credential
    Manager entry so a later reconnect prompts fresh rather than replaying a
    stored - possibly wrong - password.

    Credentials are stored PER SERVER, so the target server is read from the
    mapping before it is removed. Note \\fs-1 and \\192.168.1.237 count as two
    different servers: a drive mapped by IP leaves an entry under the IP.

    A drive can exist without `net use` listing it: a remembered (persistent)
    mapping that has not reconnected yet, or one made from Explorer. So the
    target is also looked up via WMI and the per-user registry key
    HKCU:\Network\<letter>, and when `net use /delete` does not remove the
    drive, the Explorer API (WScript.Network) and the registry key are tried
    as fallbacks. The script then checks the letter is really gone and exits
    non-zero if it is not.

.PARAMETER Letter
    Drive letter to disconnect. "x", "X" and "X:" are all accepted.

.PARAMETER KeepCredential
    Disconnect the drive but leave the stored password in place.

.EXAMPLE
    .\Unmap-Drive.ps1 -Letter X
.EXAMPLE
    .\Unmap-Drive.ps1 X -KeepCredential
#>
# Letter is deliberately not Mandatory: that makes PowerShell prompt with a bare
# "Letter:" and no help, which is useless to someone who double-clicked the .bat.
# The script asks for it itself, listing what is actually mapped.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Letter,
    [switch] $KeepCredential
)

$ErrorActionPreference = 'Stop'

# Keep this file pure ASCII - see the note in Connect-Vpn.ps1.

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "    $m" -ForegroundColor Red }

# Runs a native command and returns its output (stdout and stderr) as strings.
# Needed because under Windows PowerShell 5.1 a native command that writes to
# stderr while it is redirected (2>$null, 2>&1) raises a NativeCommandError,
# and with $ErrorActionPreference = 'Stop' that aborts the whole script. net.exe
# and cmdkey.exe write to stderr for perfectly normal "nothing there" results.
# The exit code is left in $LASTEXITCODE.
function Invoke-Native {
    param([scriptblock] $Block)
    $ErrorActionPreference = 'Continue'   # local to this function
    & $Block 2>&1 | ForEach-Object { "$_" }
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Whether the letter still exists in THIS logon session, in any form.
function Test-DriveExists {
    param([string] $d)
    # GetLogicalDrives asks Windows directly; Get-PSDrive can lag behind.
    if ([IO.Directory]::GetLogicalDrives() -contains "${d}:\") { return $true }
    $null = Invoke-Native { net use "${d}:" }
    return ($LASTEXITCODE -eq 0)
}

if (-not $Letter) {
    # Show what can actually be disconnected, so the letter does not have to be
    # remembered. DriveType 4 = network drive.
    $mapped = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=4' -ErrorAction SilentlyContinue)
    if ($mapped.Count -gt 0) {
        Write-Host 'Network drives currently mapped:'
        foreach ($m in $mapped) {
            '  {0}  {1}' -f $m.DeviceID, $m.ProviderName | Write-Host
        }
    } else {
        Write-Warn2 'No network drives appear to be mapped in this session.'
    }
    Write-Host ''
    $Letter = Read-Host 'Which drive letter should be disconnected'
    if (-not $Letter) { Write-Err2 'No drive letter given.'; exit 1 }
}

$drive = $Letter.Trim().TrimEnd(':').ToUpper()
if ($drive -notmatch '^[A-Z]$') {
    Write-Err2 "Not a drive letter: '$Letter'. Use a single letter, e.g. X"
    exit 1
}

$elevated = Test-IsElevated
$regKey   = "HKCU:\Network\$drive"

# ------------------------------------------------------ resolve target ----
# Resolve the target BEFORE deleting the mapping - afterwards there is nothing
# left to read the server name from. Three sources, first hit wins.
$remote = $null

$info = Invoke-Native { net use "${drive}:" }
$netUseKnows = ($LASTEXITCODE -eq 0)
if ($netUseKnows) {
    $m = [regex]::Match(($info -join ' '), '\\\\[^\\\s]+\\[^\s]+')
    if ($m.Success) { $remote = $m.Value }
}

$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'" -ErrorAction SilentlyContinue
if ($disk -and $disk.DriveType -ne 4) {
    # 4 = network drive. Anything else is a local disk, USB stick or subst.
    Write-Err2 "${drive}: is not a network drive (DriveType $($disk.DriveType)) - nothing to unmap."
    Write-Err2 "If it was created with subst, remove it with:  subst ${drive}: /d"
    exit 1
}
if (-not $remote -and $disk -and $disk.ProviderName) { $remote = $disk.ProviderName }

$persisted = Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
if (-not $remote -and $persisted -and $persisted.RemotePath) { $remote = $persisted.RemotePath }

if (-not $netUseKnows -and -not $disk -and -not $persisted) {
    Write-Warn2 "${drive}: is not mapped in this session."
    if ($elevated) {
        Write-Warn2 'This window runs as Administrator. Drives mapped from a normal window'
        Write-Warn2 '(or from Explorer) are invisible here. Re-run it in a normal window.'
    } else {
        Write-Warn2 'If Explorer still shows it, it may have been mapped from a window running'
        Write-Warn2 'as Administrator - run this script from such a window as well.'
    }
    exit 1
}

$server = $null
if ($remote) {
    $server = ($remote -split '\\')[2]
    Write-Ok "${drive}: -> $remote"
}

# -------------------------------------------------------------- remove ----
Write-Step "Disconnecting ${drive}:"
$out = Invoke-Native { net use "${drive}:" /delete /y }
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "net use /delete failed (exit code $LASTEXITCODE):"
    $out | Where-Object { $_.Trim() } | ForEach-Object { Write-Warn2 "  $_" }
}

# Fallback: the Explorer API. It also removes remembered mappings that net use
# does not list, and updateProfile=$true drops the persistent entry.
if (Test-DriveExists $drive) {
    try {
        (New-Object -ComObject WScript.Network).RemoveNetworkDrive("${drive}:", $true, $true)
    } catch {
        Write-Warn2 "WScript.Network could not remove it either: $($_.Exception.Message)"
    }
}

# A remembered mapping that never reconnected lives only in the registry; left
# there it comes back at the next sign-in and shows as a red X in Explorer.
if (Test-Path $regKey) {
    Remove-Item -Path $regKey -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-DriveExists $drive) {
    Write-Err2 "${drive}: is still connected."
    Write-Warn2 'Most likely causes:'
    Write-Warn2 '  - A program has a file or folder on the drive open (Explorer window,'
    Write-Warn2 '    editor, terminal whose current directory is on it). Close it, retry.'
    Write-Warn2 '  - It was mapped from a window with different rights (Administrator vs'
    Write-Warn2 '    normal). Run this script from the same kind of window.'
    exit 1
}
Write-Ok "${drive}: disconnected."

# ----------------------------------------------------------- credential ----
if ($KeepCredential) {
    Write-Host ''
    Write-Host '    Stored password left in place (-KeepCredential).'
} elseif ($server) {
    Write-Step "Removing the stored password for $server"
    # Expected to fail when nothing was stored; not an error.
    $null = Invoke-Native { cmdkey "/delete:$server" }
    Write-Ok "Credential Manager entry for $server removed (if one existed)."
    Write-Host ''
    Write-Host '    If you also mapped this share by IP, clear that entry too:'
    Write-Host '      cmdkey /delete:192.168.1.237' -ForegroundColor White
}

Write-Host ''
Write-Host '    Explorer may keep showing the letter until you press F5 in "This PC".'
exit 0
