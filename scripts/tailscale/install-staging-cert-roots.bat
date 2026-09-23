@echo off
REM ===========================================================================
REM  Wrapper for Install-StagingCertRoots.ps1 - double-clickable from Explorer
REM  or runnable from Windows Terminal / cmd.
REM
REM  Exists because the PowerShell script cannot be launched directly on a
REM  default Windows 11 install: script execution is disabled (PSSecurityException)
REM  and the machine trust store needs Administrator. This handles both.
REM
REM  Usage (-Server is mandatory; double-clicking prompts for it):
REM    install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain>
REM    install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain> -Verify
REM    install-staging-cert-roots.bat -Server vpn.<subdomain>.<domain> -Remove
REM ===========================================================================

setlocal EnableDelayedExpansion
set "PS1=%~dp0Install-StagingCertRoots.ps1"

REM Whether we were started with no arguments - i.e. double-clicked from Explorer,
REM where the window closes on exit and output must be held with 'pause'. Captured
REM NOW because the elevation path below consumes %1 with SHIFT.
set "NOARGS="
if "%~1"=="" set "NOARGS=1"

if not exist "%PS1%" (
    echo ERROR: Install-StagingCertRoots.ps1 not found next to this .bat
    echo        expected at: %PS1%
    goto :fail
)

REM One SHIFT pass over the arguments, doing two things at once:
REM   PSARGS     - a quoted, comma-separated tail to forward into the elevated
REM                call, because %* cannot be used inside the -ArgumentList string
REM   VERIFYONLY - whether -Verify was passed ANYWHERE, not just as %1: -Server is
REM                mandatory and normally comes first, so -Verify is rarely first
REM
REM SHIFT rather than 'for %%A in (%*)': that form treats its argument as a
REM filename set, so a switch like -Remove can be glob-expanded or dropped.
REM %* is captured before the loop, since SHIFT does not affect it.
set "ALLARGS=%*"
set "PSARGS="
set "VERIFYONLY="
:collect
if "%~1"=="" goto collected
if /i "%~1"=="-Verify" set "VERIFYONLY=1"
set "PSARGS=!PSARGS!,'%~1'"
shift
goto collect
:collected

REM -Verify only reads the trust store and probes the server, so do not force a
REM UAC prompt for it - the script itself allows it unelevated.
if defined VERIFYONLY (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ALLARGS%
    goto :done
)

REM Already elevated? 'net session' fails for non-admins.
net session >nul 2>&1
if %errorlevel%==0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ALLARGS%
    goto :done
)

REM Not elevated: re-launch via UAC. Start-Process -Verb RunAs opens a NEW window,
REM so -NoExit keeps it open or the output vanishes before it can be read.

echo Requesting Administrator rights (the trust store is machine-wide)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -Verb RunAs -FilePath 'powershell' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%PS1%'!PSARGS!"
if errorlevel 1 (
    echo.
    echo ERROR: elevation was declined or failed.
    echo        Alternatively, open an Administrator PowerShell and run:
    echo          powershell -ExecutionPolicy Bypass -File "%PS1%" -Server ^<host^>
    goto :fail
)
echo Continuing in the elevated window.
goto :done

:fail
if defined NOARGS pause
endlocal
exit /b 1

:done
REM Pause only when double-clicked from Explorer (no args), so a console run is
REM not left hanging on a keypress. Before 'endlocal', which would discard NOARGS.
if defined NOARGS pause
endlocal
exit /b 0
