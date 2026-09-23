@echo off
REM ===========================================================================
REM  Connects this machine to the cluster VPN.
REM
REM  Wrapper for Connect-Vpn.ps1 - double-clickable from Explorer, or runnable
REM  from Windows Terminal / cmd. It exists because a default Windows 11 install
REM  refuses to run a .ps1 at all (PSSecurityException), so PowerShell has to be
REM  invoked with -ExecutionPolicy Bypass for this one call.
REM
REM  Deliberately does NOT request Administrator rights: none of these scripts
REM  need them, and an elevated shell maps drives into a separate logon session
REM  where Explorer cannot see them.
REM
REM  Usage:
REM    vpn-connect.bat                     connect
REM    vpn-connect.bat -Status             show connection status, change nothing
REM    vpn-connect.bat -Server vpn.x.y.z   point at a different cluster
REM ===========================================================================

setlocal
set "PS1=%~dp0Connect-Vpn.ps1"

REM Whether we were started with no arguments - i.e. double-clicked from
REM Explorer, where the window closes on exit and output must be held.
set "NOARGS="
if "%~1"=="" set "NOARGS=1"

if not exist "%PS1%" (
    echo ERROR: Connect-Vpn.ps1 not found next to this .bat
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
