@echo off
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0.") do set "R4OS_DISTRIBUTION_ROOT=%%~fI"
for %%I in ("%~dp0..\..") do set "R4OS_WORKSPACE_ROOT=%%~fI"
set "R4OS_RELEASE_SCRIPT=%R4OS_DISTRIBUTION_ROOT%\Tools\Release.ps1"
set "R4OS_CREDENTIAL_FILE=%R4OS_WORKSPACE_ROOT%\Tools\Credentials\Github.bat"

set "R4OS_RELEASE_ACTION=%~1"
set "R4OS_RELEASE_PROFILES=%~2"
set "R4OS_RELEASE_OPTION=%~3"

if not defined R4OS_RELEASE_ACTION goto interactive_action
if not defined R4OS_RELEASE_PROFILES set "R4OS_RELEASE_PROFILES=Standard"

if /I "%R4OS_RELEASE_ACTION%"=="prepare" goto validate_option
if /I "%R4OS_RELEASE_ACTION%"=="publish" goto validate_option
if /I "%R4OS_RELEASE_ACTION%"=="selftest" goto run_selftest
goto usage

:validate_option
set "R4OS_RELEASE_EXTRA="
if not defined R4OS_RELEASE_OPTION goto validate_profiles
if /I not "%R4OS_RELEASE_ACTION%"=="publish" goto usage
if /I "%R4OS_RELEASE_OPTION%"=="-prerelease" (
    set "R4OS_RELEASE_EXTRA=-Prerelease"
    goto validate_profiles
)
goto usage

:validate_profiles
if /I "%R4OS_RELEASE_PROFILES%"=="Standard" goto action_ready
if /I "%R4OS_RELEASE_PROFILES%"=="Slim" goto action_ready
if /I "%R4OS_RELEASE_PROFILES%"=="Full" goto action_ready
if /I "%R4OS_RELEASE_PROFILES%"=="Test" goto action_ready
if /I "%R4OS_RELEASE_PROFILES%"=="All" goto action_ready
goto usage

:action_ready
if /I "%R4OS_RELEASE_ACTION%"=="publish" goto load_credentials
goto run_release

:load_credentials
if not exist "%R4OS_CREDENTIAL_FILE%" (
    echo ERROR: GitHub credentials not found: "%R4OS_CREDENTIAL_FILE%"
    echo Run Tools\Setup.bat from the workspace root first.
    exit /b 1
)

call "%R4OS_CREDENTIAL_FILE%"
if errorlevel 1 (
    echo ERROR: GitHub credentials could not be loaded.
    exit /b 1
)
if not defined R4OS_GITHUB_TOKEN (
    echo ERROR: R4OS_GITHUB_TOKEN is missing from the credentials file.
    exit /b 1
)
if /I "%R4OS_GITHUB_TOKEN%"=="github_pat_DEIN_TOKEN" (
    echo ERROR: Replace the GitHub token placeholder before publishing.
    exit /b 1
)
goto run_release

:run_release
if not exist "%R4OS_RELEASE_SCRIPT%" (
    echo ERROR: Release implementation not found: "%R4OS_RELEASE_SCRIPT%"
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%R4OS_RELEASE_SCRIPT%" -Action "%R4OS_RELEASE_ACTION%" -Profiles "%R4OS_RELEASE_PROFILES%" %R4OS_RELEASE_EXTRA%
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %R4OS_EXIT_CODE%

:run_selftest
if not exist "%R4OS_RELEASE_SCRIPT%" (
    echo ERROR: Release implementation not found: "%R4OS_RELEASE_SCRIPT%"
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%R4OS_RELEASE_SCRIPT%" -Action SelfTest
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %R4OS_EXIT_CODE%

:interactive_action
echo.
echo R4OS release action:
echo   [1] Prepare assets locally
echo   [2] Prepare and publish on GitHub
echo   [3] Run release-tool self-test
choice /C 123 /N /M "Selection"
if errorlevel 3 goto interactive_selftest
if errorlevel 2 set "R4OS_INTERACTIVE_ACTION=publish"
if errorlevel 1 if not defined R4OS_INTERACTIVE_ACTION set "R4OS_INTERACTIVE_ACTION=prepare"

echo.
echo Profiles:
echo   [1] Standard - Slim and Full
echo   [2] Slim
echo   [3] Full
echo   [4] Test
echo   [5] All - Slim, Full and Test
choice /C 12345 /N /M "Selection"
if errorlevel 5 set "R4OS_INTERACTIVE_PROFILES=All"
if errorlevel 4 if not defined R4OS_INTERACTIVE_PROFILES set "R4OS_INTERACTIVE_PROFILES=Test"
if errorlevel 3 if not defined R4OS_INTERACTIVE_PROFILES set "R4OS_INTERACTIVE_PROFILES=Full"
if errorlevel 2 if not defined R4OS_INTERACTIVE_PROFILES set "R4OS_INTERACTIVE_PROFILES=Slim"
if errorlevel 1 if not defined R4OS_INTERACTIVE_PROFILES set "R4OS_INTERACTIVE_PROFILES=Standard"

if /I not "%R4OS_INTERACTIVE_ACTION%"=="publish" goto interactive_prepare

echo.
echo GitHub release type:
echo   [1] Stable release
echo   [2] Pre-release
choice /C 12 /N /M "Selection"
if errorlevel 2 goto interactive_publish_prerelease

:interactive_publish
call "%~f0" publish %R4OS_INTERACTIVE_PROFILES%
exit /b %ERRORLEVEL%

:interactive_publish_prerelease
call "%~f0" publish %R4OS_INTERACTIVE_PROFILES% -prerelease
exit /b %ERRORLEVEL%

:interactive_prepare
call "%~f0" prepare %R4OS_INTERACTIVE_PROFILES%
exit /b %ERRORLEVEL%

:interactive_selftest
call "%~f0" selftest
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   Release.bat
echo   Release.bat prepare [Standard^|Slim^|Full^|Test^|All]
echo   Release.bat publish [Standard^|Slim^|Full^|Test^|All] [-prerelease]
echo   Release.bat selftest
exit /b 1
