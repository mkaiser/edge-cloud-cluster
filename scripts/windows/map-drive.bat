@echo off
REM ===========================================================================
REM  Maps a network drive to a share on the cluster fileserver.
REM
REM  Wrapper for Map-Drive.ps1 - see vpn-connect.bat for why the wrapper exists
REM  and why it does not elevate.
REM
REM  Connect the VPN first with vpn-connect.bat.
REM
REM  Usage:
REM    map-drive.bat X \\fs-1\eda alice       map X: as AD\alice (prompts for password)
REM    map-drive.bat X \\fs-1\userhomes       prompts for the account name too
REM    map-drive.bat X \\fs-1\eda alice -Persist    reconnect at sign-in
REM
REM  The AD\ prefix is added for you - pass just the account name.
REM ===========================================================================

setlocal
set "PS1=%~dp0Map-Drive.ps1"

set "NOARGS="
if "%~1"=="" set "NOARGS=1"

if not exist "%PS1%" (
    echo ERROR: Map-Drive.ps1 not found next to this .bat
    echo        expected at: %PS1%
    goto :fail
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
if errorlevel 1 goto :fail

if defined NOARGS pause
endlocal
exit /b 0

:fail
if defined NOARGS pause
endlocal
exit /b 1
