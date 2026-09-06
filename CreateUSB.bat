@echo off
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 wird benoetigt ^(pwsh^).
    exit /b 1
)
pwsh -NoLogo -NoProfile -File "%~dp0CreateUSB.ps1" %*
exit /b %errorlevel%
