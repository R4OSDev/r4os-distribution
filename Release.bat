@echo off
setlocal EnableExtensions DisableDelayedExpansion

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh.exe^) was not found.
    endlocal & exit /b 1
)

pwsh.exe -NoLogo -NoProfile -File "%~dp0Tools\Release.ps1" %*
set "R4OS_RELEASE_EXIT=%ERRORLEVEL%"
endlocal & exit /b %R4OS_RELEASE_EXIT%
