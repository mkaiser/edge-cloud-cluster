@echo off
REM ===========================================================================
REM  Disconnects a mapped network drive and forgets its stored password.
REM
REM  Wrapper for Unmap-Drive.ps1 - see vpn-connect.bat for why the wrapper
REM  exists and why it does not elevate.
REM
REM  Usage:
REM    unmap-drive.bat X                   disconnect X: and forget the password
REM    unmap-drive.bat X -KeepCredential   disconnect but keep the password
REM ===========================================================================

setlocal
set "PS1=%~dp0Unmap-Drive.ps1"

set "NOARGS="
if "%~1"=="" set "NOARGS=1"

if not exist "%PS1%" (
    echo ERROR: Unmap-Drive.ps1 not found next to this .bat
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
