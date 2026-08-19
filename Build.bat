@echo off
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0.") do set "R4OS_DISTRIBUTION_ROOT=%%~fI"
set "R4OS_SETTINGS=%R4OS_DISTRIBUTION_ROOT%\Settings.R4S"

set "R4OS_ACTION=%~1"
if not defined R4OS_ACTION set "R4OS_ACTION=tools"

if /i "%R4OS_ACTION%"=="tools" goto resolve_settings
if /i "%R4OS_ACTION%"=="test" goto resolve_settings
if /i "%R4OS_ACTION%"=="plan" goto require_profile
if /i "%R4OS_ACTION%"=="image" goto require_profile
if /i "%R4OS_ACTION%"=="verify" goto require_profile
if /i "%R4OS_ACTION%"=="qemu" goto require_profile
if /i "%R4OS_ACTION%"=="headless" goto require_profile
goto usage

:require_profile
set "R4OS_REQUESTED_PROFILE=%~2"
if not defined R4OS_REQUESTED_PROFILE goto usage

:resolve_settings
if not exist "%R4OS_SETTINGS%" (
    echo ERROR: Settings file not found: "%R4OS_SETTINGS%"
    exit /b 1
)

set "R4OS_WORKSPACE_SETTING="
set "R4OS_REPOSITORIES_SETTING="
set "R4OS_CONTRACT_SETTING="
set "R4OS_SDK_SETTING="
set "R4OS_LIBRARIES_SETTING="
set "R4OS_DEVKIT_SETTING="
set "R4OS_ARTIFACTS_SETTING="
set "R4OS_ZIG_SETTING="
set "R4OS_LIMINE_SETTING="
set "R4OS_QEMU_SETTING="
set "R4OS_DEVKIT_HOSTTOOLS_SETTING="
set "R4OS_DISTRIBUTION_OUTPUT_SETTING="
set "R4OS_INPUT_SETTING="
set "R4OS_PRIVATE_INJECTION_SETTING="

for /f "usebackq tokens=1,* delims==" %%A in ("%R4OS_SETTINGS%") do (
    if /i "%%A"=="WORKSPACE_ROOT" set "R4OS_WORKSPACE_SETTING=%%B"
    if /i "%%A"=="REPOSITORIES_ROOT" set "R4OS_REPOSITORIES_SETTING=%%B"
    if /i "%%A"=="CONTRACT_ROOT" set "R4OS_CONTRACT_SETTING=%%B"
    if /i "%%A"=="SDK_ROOT" set "R4OS_SDK_SETTING=%%B"
    if /i "%%A"=="LIBRARIES_ROOT" set "R4OS_LIBRARIES_SETTING=%%B"
    if /i "%%A"=="DEVKIT_ROOT" set "R4OS_DEVKIT_SETTING=%%B"
    if /i "%%A"=="ARTIFACTS_ROOT" set "R4OS_ARTIFACTS_SETTING=%%B"
    if /i "%%A"=="ZIG_ROOT" set "R4OS_ZIG_SETTING=%%B"
    if /i "%%A"=="LIMINE_ROOT" set "R4OS_LIMINE_SETTING=%%B"
    if /i "%%A"=="QEMU_ROOT" set "R4OS_QEMU_SETTING=%%B"
    if /i "%%A"=="DEVKIT_HOSTTOOLS_ROOT" set "R4OS_DEVKIT_HOSTTOOLS_SETTING=%%B"
    if /i "%%A"=="DISTRIBUTION_OUTPUT_ROOT" set "R4OS_DISTRIBUTION_OUTPUT_SETTING=%%B"
    if /i "%%A"=="INPUT_ROOT" set "R4OS_INPUT_SETTING=%%B"
    if /i "%%A"=="PRIVATE_INJECTION_ROOT" set "R4OS_PRIVATE_INJECTION_SETTING=%%B"
)

for %%K in (WORKSPACE REPOSITORIES CONTRACT SDK LIBRARIES DEVKIT ARTIFACTS ZIG LIMINE QEMU DEVKIT_HOSTTOOLS DISTRIBUTION_OUTPUT INPUT PRIVATE_INJECTION) do if not defined R4OS_%%K_SETTING (
    echo ERROR: %%K_ROOT mapping is missing in "%R4OS_SETTINGS%".
    exit /b 1
)

pushd "%R4OS_DISTRIBUTION_ROOT%" >nul || exit /b 1
for %%I in ("%R4OS_WORKSPACE_SETTING%") do set "R4OS_WORKSPACE_ROOT=%%~fI"
for %%I in ("%R4OS_REPOSITORIES_SETTING%") do set "R4OS_REPOSITORIES_ROOT=%%~fI"
popd

pushd "%R4OS_REPOSITORIES_ROOT%" >nul || (
    echo ERROR: Repositories root not found: "%R4OS_REPOSITORIES_ROOT%"
    exit /b 1
)
for %%I in ("%R4OS_CONTRACT_SETTING%") do set "R4OS_CONTRACT_ROOT=%%~fI"
for %%I in ("%R4OS_SDK_SETTING%") do set "R4OS_SDK_ROOT=%%~fI"
for %%I in ("%R4OS_LIBRARIES_SETTING%") do set "R4OS_LIBRARIES_ROOT=%%~fI"
popd

pushd "%R4OS_WORKSPACE_ROOT%" >nul || (
    echo ERROR: Workspace root not found: "%R4OS_WORKSPACE_ROOT%"
    exit /b 1
)
for %%I in ("%R4OS_DEVKIT_SETTING%") do set "R4OS_DEVKIT_ROOT=%%~fI"
for %%I in ("%R4OS_ARTIFACTS_SETTING%") do set "R4OS_ARTIFACTS_ROOT=%%~fI"
popd

pushd "%R4OS_DEVKIT_ROOT%" >nul || (
    echo ERROR: DevKit root not found: "%R4OS_DEVKIT_ROOT%"
    exit /b 1
)
for %%I in ("%R4OS_ZIG_SETTING%") do set "R4OS_ZIG_ROOT=%%~fI"
for %%I in ("%R4OS_LIMINE_SETTING%") do set "R4OS_LIMINE_ROOT=%%~fI"
for %%I in ("%R4OS_QEMU_SETTING%") do set "R4OS_QEMU_ROOT=%%~fI"
for %%I in ("%R4OS_DEVKIT_HOSTTOOLS_SETTING%") do set "R4OS_DEVKIT_HOSTTOOLS_ROOT=%%~fI"
popd

if not exist "%R4OS_ARTIFACTS_ROOT%" mkdir "%R4OS_ARTIFACTS_ROOT%" || exit /b 1
pushd "%R4OS_ARTIFACTS_ROOT%" >nul || exit /b 1
for %%I in ("%R4OS_DISTRIBUTION_OUTPUT_SETTING%") do set "R4OS_OUTPUT_ROOT=%%~fI"
for %%I in ("%R4OS_INPUT_SETTING%") do set "R4OS_INPUT_ROOT=%%~fI"
for %%I in ("%R4OS_PRIVATE_INJECTION_SETTING%") do set "R4OS_PRIVATE_INJECTION_ROOT=%%~fI"
popd

set "R4OS_ZIG_EXE=%R4OS_ZIG_ROOT%\zig.exe"
set "R4OS_LIMINE_EXE=%R4OS_LIMINE_ROOT%\limine-tool-windows-x86\limine.exe"
set "R4OS_QEMU_EXE=%R4OS_QEMU_ROOT%\qemu-system-x86_64.exe"
set "R4OS_BUILD_PREFIX=%R4OS_OUTPUT_ROOT%\HostTools"
set "R4OS_BUILD_CACHE=%R4OS_OUTPUT_ROOT%\.Cache\build"
set "R4OS_GLOBAL_CACHE=%R4OS_OUTPUT_ROOT%\.Cache\global"
set "R4OS_IMAGE_PLAN=%R4OS_BUILD_PREFIX%\bin\image-plan.exe"
set "R4OS_IMAGE_CREATOR=%R4OS_BUILD_PREFIX%\bin\imagecreater.exe"
set "R4OS_NTFS_VERIFY=%R4OS_BUILD_PREFIX%\bin\ntfsverify.exe"
set "R4OS_QEMU_CONFIG=%R4OS_DISTRIBUTION_ROOT%\QEMU\standard.conf"
set "R4OS_QEMU_TIMEOUT_HELPER=%R4OS_DISTRIBUTION_ROOT%\Tests\Invoke-QemuHeadless.ps1"
set "R4OS_QEMU_MARKER_TEST=%R4OS_DISTRIBUTION_ROOT%\Tests\Test-QemuApiMarkers.ps1"
set "R4OS_RELEASE_TOOL=%R4OS_DISTRIBUTION_ROOT%\Release.bat"
set "R4OS_LOG_ROOT=%R4OS_OUTPUT_ROOT%\Logs"
set "R4OS_LEGAL_SOURCE=%R4OS_DISTRIBUTION_ROOT%\Injection\R4OS\LICENSES"

if not exist "%R4OS_CONTRACT_ROOT%\build.zig.zon" (
    echo ERROR: Contract repository not found: "%R4OS_CONTRACT_ROOT%"
    exit /b 1
)
if not exist "%R4OS_SDK_ROOT%\build.zig.zon" (
    echo ERROR: SDK repository not found: "%R4OS_SDK_ROOT%"
    exit /b 1
)
if not exist "%R4OS_LIBRARIES_ROOT%\build.zig.zon" (
    echo ERROR: Libraries repository not found: "%R4OS_LIBRARIES_ROOT%"
    exit /b 1
)
if not exist "%R4OS_ZIG_EXE%" (
    echo ERROR: Zig executable not found: "%R4OS_ZIG_EXE%"
    exit /b 1
)

if /i "%R4OS_ACTION%"=="tools" goto build_tools_action
if /i "%R4OS_ACTION%"=="test" goto test_action
if /i "%R4OS_ACTION%"=="plan" goto plan_action
if /i "%R4OS_ACTION%"=="image" goto image_action
if /i "%R4OS_ACTION%"=="verify" goto verify_action
if /i "%R4OS_ACTION%"=="qemu" goto qemu_action
if /i "%R4OS_ACTION%"=="headless" goto headless_action
goto usage

:build_tools_action
call :build_tools
exit /b %ERRORLEVEL%

:test_action
call :run_profile_acceptance
if errorlevel 1 exit /b %ERRORLEVEL%
call :validate_legal_source
if errorlevel 1 exit /b %ERRORLEVEL%
call :build_tools test
if errorlevel 1 exit /b %ERRORLEVEL%
call :run_plan_acceptance
if errorlevel 1 exit /b %ERRORLEVEL%
call :run_marker_acceptance
if errorlevel 1 exit /b %ERRORLEVEL%
call :run_release_acceptance
exit /b %ERRORLEVEL%

:plan_action
call :generate_plan "%R4OS_REQUESTED_PROFILE%"
if errorlevel 1 exit /b %ERRORLEVEL%
call :validate_image_legal_plan
exit /b %ERRORLEVEL%

:image_action
call :generate_plan "%R4OS_REQUESTED_PROFILE%"
if errorlevel 1 exit /b %ERRORLEVEL%
call :validate_image_legal_plan
if errorlevel 1 exit /b %ERRORLEVEL%
call :validate_legal_source
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%R4OS_LIMINE_EXE%" (
    echo ERROR: Limine executable not found: "%R4OS_LIMINE_EXE%"
    exit /b 1
)
set "R4OS_NTFS_META=%R4OS_SDK_ROOT%\Tests\Fixture\Ntfs\Meta0605"
if not exist "%R4OS_NTFS_META%\upcase.bin" (
    echo ERROR: NTFS metadata fixture not found: "%R4OS_NTFS_META%"
    exit /b 1
)
echo === Create %R4OS_PROFILE% image ===
"%R4OS_IMAGE_CREATOR%" create-system --output "%R4OS_PROFILE_OUTPUT%\disk.img" --boot-mb %R4OS_BOOT_MB% --system-mb %R4OS_SYSTEM_MB% --meta "%R4OS_NTFS_META%" --add-list "%R4OS_IMAGE_LIST%"
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%R4OS_PROFILE_OUTPUT%\data.img" (
    "%R4OS_IMAGE_CREATOR%" --output "%R4OS_PROFILE_OUTPUT%\data.img" --size %R4OS_DATA_MB%
    if errorlevel 1 exit /b %ERRORLEVEL%
)
"%R4OS_LIMINE_EXE%" bios-install "%R4OS_PROFILE_OUTPUT%\disk.img"
if errorlevel 1 exit /b %ERRORLEVEL%
call :stage_legal
exit /b %ERRORLEVEL%

:verify_action
call :load_profile "%R4OS_REQUESTED_PROFILE%"
if errorlevel 1 exit /b %ERRORLEVEL%
set "R4OS_PROFILE_OUTPUT=%R4OS_OUTPUT_ROOT%\Profiles\%R4OS_PROFILE%"
if not exist "%R4OS_PROFILE_OUTPUT%\disk.img" (
    echo ERROR: Image not found: "%R4OS_PROFILE_OUTPUT%\disk.img"
    exit /b 1
)
set "R4OS_IMAGE_LIST=%R4OS_PROFILE_OUTPUT%\image-adds.txt"
call :validate_image_legal_plan
if errorlevel 1 exit /b %ERRORLEVEL%
set "R4OS_PROFILE_LEGAL=%R4OS_PROFILE_OUTPUT%\Legal"
call :validate_staged_legal
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%R4OS_NTFS_VERIFY%" call :build_tools
if errorlevel 1 exit /b %ERRORLEVEL%
"%R4OS_NTFS_VERIFY%" "%R4OS_PROFILE_OUTPUT%\disk.img"
exit /b %ERRORLEVEL%

:qemu_action
call :load_profile "%R4OS_REQUESTED_PROFILE%"
if errorlevel 1 exit /b %ERRORLEVEL%
set "R4OS_PROFILE_OUTPUT=%R4OS_OUTPUT_ROOT%\Profiles\%R4OS_PROFILE%"
if not exist "%R4OS_PROFILE_OUTPUT%\disk.img" (
    echo ERROR: Image not found: "%R4OS_PROFILE_OUTPUT%\disk.img"
    exit /b 1
)
if not exist "%R4OS_PROFILE_OUTPUT%\data.img" (
    echo ERROR: Data image not found: "%R4OS_PROFILE_OUTPUT%\data.img"
    exit /b 1
)
if not exist "%R4OS_QEMU_EXE%" (
    echo ERROR: QEMU executable not found: "%R4OS_QEMU_EXE%"
    exit /b 1
)
pushd "%R4OS_PROFILE_OUTPUT%" >nul || exit /b 1
"%R4OS_QEMU_EXE%" -readconfig "%R4OS_QEMU_CONFIG%" -m 1024 -smp 4 -cpu max -boot c
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %R4OS_EXIT_CODE%

:headless_action
call :load_profile "%R4OS_REQUESTED_PROFILE%"
if errorlevel 1 exit /b %ERRORLEVEL%
if /i not "%R4OS_PROFILE%"=="Test" (
    echo ERROR: Headless acceptance requires the Test profile.
    exit /b 1
)
if not "%R4OS_TEST_OVERLAY%"=="1" (
    echo ERROR: Test profile has no test overlay.
    exit /b 1
)
set "R4OS_PROFILE_OUTPUT=%R4OS_OUTPUT_ROOT%\Profiles\%R4OS_PROFILE%"
if not exist "%R4OS_PROFILE_OUTPUT%\disk.img" (
    echo ERROR: Image not found: "%R4OS_PROFILE_OUTPUT%\disk.img"
    exit /b 1
)
if not exist "%R4OS_IMAGE_CREATOR%" call :build_tools
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%R4OS_QEMU_EXE%" (
    echo ERROR: QEMU executable not found: "%R4OS_QEMU_EXE%"
    exit /b 1
)
if not exist "%R4OS_QEMU_CONFIG%" (
    echo ERROR: QEMU config not found: "%R4OS_QEMU_CONFIG%"
    exit /b 1
)
if not exist "%R4OS_QEMU_TIMEOUT_HELPER%" (
    echo ERROR: QEMU timeout helper not found: "%R4OS_QEMU_TIMEOUT_HELPER%"
    exit /b 1
)
if not exist "%R4OS_QEMU_MARKER_TEST%" (
    echo ERROR: QEMU marker test not found: "%R4OS_QEMU_MARKER_TEST%"
    exit /b 1
)

rem A headless run must never inherit a data disk damaged by an interrupted
rem previous run. GUI sessions intentionally keep their persistent data disk.
if exist "%R4OS_PROFILE_OUTPUT%\data.img" del /f /q "%R4OS_PROFILE_OUTPUT%\data.img" || exit /b 1
echo === Recreate Test data image for headless acceptance: %R4OS_DATA_MB% MB ===
"%R4OS_IMAGE_CREATOR%" --output "%R4OS_PROFILE_OUTPUT%\data.img" --size %R4OS_DATA_MB%
if errorlevel 1 exit /b %ERRORLEVEL%

if not exist "%R4OS_LOG_ROOT%" mkdir "%R4OS_LOG_ROOT%" || exit /b 1
set "R4OS_QEMU_LOG=%R4OS_LOG_ROOT%\qemu-test-standard.log"
set "R4OS_QEMU_ERROR_LOG=%R4OS_LOG_ROOT%\qemu-test-standard.err"
set "R4OS_QEMU_WORKING_DIRECTORY=%R4OS_PROFILE_OUTPUT%"
if exist "%R4OS_QEMU_LOG%" del /f /q "%R4OS_QEMU_LOG%" || exit /b 1
if exist "%R4OS_QEMU_ERROR_LOG%" del /f /q "%R4OS_QEMU_ERROR_LOG%" || exit /b 1
if not defined QEMU_TEST_TIMEOUT_SECONDS set "QEMU_TEST_TIMEOUT_SECONDS=240"

echo === Start QEMU Test profile headless ===
echo     Config:  %R4OS_QEMU_CONFIG%
echo     Serial:  %R4OS_QEMU_LOG%
echo     Timeout: %QEMU_TEST_TIMEOUT_SECONDS%s
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%R4OS_QEMU_TIMEOUT_HELPER%"
set "R4OS_QEMU_EXIT=%ERRORLEVEL%"
if "%R4OS_QEMU_EXIT%"=="124" echo QEMU: TIMEOUT after %QEMU_TEST_TIMEOUT_SECONDS%s; guest did not power off.
call :evaluate_headless_logs "%R4OS_QEMU_EXIT%"
exit /b %ERRORLEVEL%

:build_tools
if not exist "%R4OS_BUILD_PREFIX%" mkdir "%R4OS_BUILD_PREFIX%" || exit /b 1
if not exist "%R4OS_BUILD_CACHE%" mkdir "%R4OS_BUILD_CACHE%" || exit /b 1
if not exist "%R4OS_GLOBAL_CACHE%" mkdir "%R4OS_GLOBAL_CACHE%" || exit /b 1
echo === Distribution HostTools ===
pushd "%R4OS_DISTRIBUTION_ROOT%" >nul || exit /b 1
if /i "%~1"=="test" (
    "%R4OS_ZIG_EXE%" build test --cache-dir "%R4OS_BUILD_CACHE%" --global-cache-dir "%R4OS_GLOBAL_CACHE%" --prefix "%R4OS_BUILD_PREFIX%" -Doptimize=ReleaseSafe --fork="%R4OS_SDK_ROOT%" --fork="%R4OS_CONTRACT_ROOT%" --fork="%R4OS_LIBRARIES_ROOT%"
) else (
    "%R4OS_ZIG_EXE%" build --cache-dir "%R4OS_BUILD_CACHE%" --global-cache-dir "%R4OS_GLOBAL_CACHE%" --prefix "%R4OS_BUILD_PREFIX%" -Doptimize=ReleaseSafe --fork="%R4OS_SDK_ROOT%" --fork="%R4OS_CONTRACT_ROOT%" --fork="%R4OS_LIBRARIES_ROOT%"
)
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %R4OS_EXIT_CODE%

:validate_legal_source
if not exist "%R4OS_LEGAL_SOURCE%" (
    echo ERROR: Versioned legal payload not found: "%R4OS_LEGAL_SOURCE%"
    exit /b 1
)
for %%F in (
    "R4OS-LICENSE.txt"
    "R4OS-NOTICE.txt"
    "THIRD-PARTY-NOTICES.txt"
    "Limine-BSD-2-Clause.txt"
    "FreeType-FTL.txt"
    "Brotli-MIT.txt"
    "zlib.txt"
    "stb_image-MIT.txt"
    "RTL8168-GPL-2.0-only.txt"
) do if not exist "%R4OS_LEGAL_SOURCE%\%%~F" (
    echo ERROR: Required legal file is missing: "%R4OS_LEGAL_SOURCE%\%%~F"
    exit /b 1
)
fc /b "%R4OS_DISTRIBUTION_ROOT%\LICENSE" "%R4OS_LEGAL_SOURCE%\R4OS-LICENSE.txt" >nul
if errorlevel 1 (
    echo ERROR: Image Apache license differs from repository LICENSE.
    exit /b 1
)
fc /b "%R4OS_DISTRIBUTION_ROOT%\NOTICE" "%R4OS_LEGAL_SOURCE%\R4OS-NOTICE.txt" >nul
if errorlevel 1 (
    echo ERROR: Image NOTICE differs from repository NOTICE.
    exit /b 1
)
exit /b 0

:stage_legal
set "R4OS_PROFILE_LEGAL=%R4OS_PROFILE_OUTPUT%\Legal"
if exist "%R4OS_PROFILE_LEGAL%" rmdir /s /q "%R4OS_PROFILE_LEGAL%"
if exist "%R4OS_PROFILE_LEGAL%" (
    echo ERROR: Could not reset release legal directory: "%R4OS_PROFILE_LEGAL%"
    exit /b 1
)
mkdir "%R4OS_PROFILE_LEGAL%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Could not create release legal directory: "%R4OS_PROFILE_LEGAL%"
    exit /b 1
)
copy /y "%R4OS_LEGAL_SOURCE%\*" "%R4OS_PROFILE_LEGAL%\" >nul
if errorlevel 1 (
    echo ERROR: Could not stage release legal files.
    exit /b 1
)
call :validate_staged_legal
if errorlevel 1 exit /b %ERRORLEVEL%
echo [OK] Release legal payload: %R4OS_PROFILE_LEGAL%
exit /b 0

:validate_staged_legal
for %%F in (
    "R4OS-LICENSE.txt"
    "R4OS-NOTICE.txt"
    "THIRD-PARTY-NOTICES.txt"
    "Limine-BSD-2-Clause.txt"
    "FreeType-FTL.txt"
    "Brotli-MIT.txt"
    "zlib.txt"
    "stb_image-MIT.txt"
    "RTL8168-GPL-2.0-only.txt"
) do if not exist "%R4OS_PROFILE_LEGAL%\%%~F" (
    echo ERROR: Staged legal file is missing: "%R4OS_PROFILE_LEGAL%\%%~F"
    exit /b 1
)
exit /b 0

:validate_image_legal_plan
if not exist "%R4OS_IMAGE_LIST%" (
    echo ERROR: Image plan not found: "%R4OS_IMAGE_LIST%"
    exit /b 1
)
for %%F in (
    "R4OS-LICENSE.txt"
    "R4OS-NOTICE.txt"
    "THIRD-PARTY-NOTICES.txt"
    "Limine-BSD-2-Clause.txt"
    "FreeType-FTL.txt"
    "Brotli-MIT.txt"
    "zlib.txt"
    "stb_image-MIT.txt"
    "RTL8168-GPL-2.0-only.txt"
) do (
    findstr /l /c:":/R4OS/LICENSES/%%~F" "%R4OS_IMAGE_LIST%" >nul
    if errorlevel 1 (
        echo ERROR: Image plan omits legal file: /R4OS/LICENSES/%%~F
        exit /b 1
    )
)
exit /b 0

:generate_plan
call :load_profile "%~1"
if errorlevel 1 exit /b %ERRORLEVEL%
call :validate_legal_source
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%R4OS_IMAGE_PLAN%" call :build_tools
if errorlevel 1 exit /b %ERRORLEVEL%

set "R4OS_COMMON_PLAN=%R4OS_INPUT_ROOT%\%R4OS_COMMON_PLAN_NAME%"
set "R4OS_COMPONENT_PLAN=%R4OS_INPUT_ROOT%\%R4OS_COMPONENT_PLAN_NAME%"
if not exist "%R4OS_COMMON_PLAN%" (
    echo ERROR: Explicit common artifact plan not found: "%R4OS_COMMON_PLAN%"
    exit /b 1
)
if not exist "%R4OS_COMPONENT_PLAN%" (
    echo ERROR: Explicit component artifact plan not found: "%R4OS_COMPONENT_PLAN%"
    exit /b 1
)

set "R4OS_PROFILE_OUTPUT=%R4OS_OUTPUT_ROOT%\Profiles\%R4OS_PROFILE%"
set "R4OS_IMAGE_LIST=%R4OS_PROFILE_OUTPUT%\image-adds.txt"
if not exist "%R4OS_PROFILE_OUTPUT%" mkdir "%R4OS_PROFILE_OUTPUT%" || exit /b 1

echo === Generate %R4OS_PROFILE% image plan ===
if "%R4OS_TEST_OVERLAY%"=="1" goto generate_test_plan
"%R4OS_IMAGE_PLAN%" --output "%R4OS_IMAGE_LIST%" --plan "%R4OS_COMMON_PLAN%" --plan "%R4OS_COMPONENT_PLAN%" --tree "%R4OS_SDK_ROOT%\Shared\C\include|/R4OS/SDK/Include/C" --tree "%R4OS_SDK_ROOT%\Shared\C\src|/R4OS/SDK/Startup/C" --tree "%R4OS_SDK_ROOT%\r4os\linker|/R4OS/SDK/Linker" --tree "%R4OS_SDK_ROOT%\Templates|/R4OS/SDK/Templates" --tree "%R4OS_SDK_ROOT%\BuildProfiles|/R4OS/SDK/BuildProfiles" --tree "%R4OS_SDK_ROOT%\Toolchains|/R4OS/SDK/Toolchains" --tree "%R4OS_CONTRACT_ROOT%\ABI|/R4OS/SDK/Contract/ABI" --tree "%R4OS_CONTRACT_ROOT%\API|/R4OS/SDK/Contract/API" --tree "%R4OS_CONTRACT_ROOT%\Generated|/R4OS/SDK/Contract/Generated" --tree "%R4OS_CONTRACT_ROOT%\Module|/R4OS/SDK/Contract/Module" --overlay "%R4OS_DISTRIBUTION_ROOT%\Injection" --optional-overlay "%R4OS_OUTPUT_ROOT%\Injection" --optional-overlay "%R4OS_PRIVATE_INJECTION_ROOT%"
exit /b %ERRORLEVEL%

:generate_test_plan
"%R4OS_IMAGE_PLAN%" --output "%R4OS_IMAGE_LIST%" --plan "%R4OS_COMMON_PLAN%" --plan "%R4OS_COMPONENT_PLAN%" --tree "%R4OS_SDK_ROOT%\Shared\C\include|/R4OS/SDK/Include/C" --tree "%R4OS_SDK_ROOT%\Shared\C\src|/R4OS/SDK/Startup/C" --tree "%R4OS_SDK_ROOT%\r4os\linker|/R4OS/SDK/Linker" --tree "%R4OS_SDK_ROOT%\Templates|/R4OS/SDK/Templates" --tree "%R4OS_SDK_ROOT%\BuildProfiles|/R4OS/SDK/BuildProfiles" --tree "%R4OS_SDK_ROOT%\Toolchains|/R4OS/SDK/Toolchains" --tree "%R4OS_CONTRACT_ROOT%\ABI|/R4OS/SDK/Contract/ABI" --tree "%R4OS_CONTRACT_ROOT%\API|/R4OS/SDK/Contract/API" --tree "%R4OS_CONTRACT_ROOT%\Generated|/R4OS/SDK/Contract/Generated" --tree "%R4OS_CONTRACT_ROOT%\Module|/R4OS/SDK/Contract/Module" --overlay "%R4OS_DISTRIBUTION_ROOT%\Injection" --overlay "%R4OS_DISTRIBUTION_ROOT%\TestInjection" --optional-overlay "%R4OS_OUTPUT_ROOT%\Injection" --optional-overlay "%R4OS_PRIVATE_INJECTION_ROOT%"
exit /b %ERRORLEVEL%

:load_profile
set "R4OS_PROFILE_FILE=%R4OS_DISTRIBUTION_ROOT%\Profiles\%~1.R4S"
if not exist "%R4OS_PROFILE_FILE%" (
    echo ERROR: Unknown distribution profile: %~1
    exit /b 1
)
set "R4OS_PROFILE="
set "R4OS_COMMON_PLAN_NAME="
set "R4OS_COMPONENT_PLAN_NAME="
set "R4OS_TEST_OVERLAY="
set "R4OS_BOOT_MB="
set "R4OS_SYSTEM_MB="
set "R4OS_DATA_MB="
for /f "usebackq tokens=1,* delims==" %%A in ("%R4OS_PROFILE_FILE%") do (
    if /i "%%A"=="PROFILE" set "R4OS_PROFILE=%%B"
    if /i "%%A"=="COMMON_PLAN" set "R4OS_COMMON_PLAN_NAME=%%B"
    if /i "%%A"=="COMPONENT_PLAN" set "R4OS_COMPONENT_PLAN_NAME=%%B"
    if /i "%%A"=="TEST_OVERLAY" set "R4OS_TEST_OVERLAY=%%B"
    if /i "%%A"=="BOOT_MB" set "R4OS_BOOT_MB=%%B"
    if /i "%%A"=="SYSTEM_MB" set "R4OS_SYSTEM_MB=%%B"
    if /i "%%A"=="DATA_MB" set "R4OS_DATA_MB=%%B"
)
for %%K in (PROFILE COMMON_PLAN_NAME COMPONENT_PLAN_NAME TEST_OVERLAY BOOT_MB SYSTEM_MB DATA_MB) do if not defined R4OS_%%K (
    echo ERROR: Profile mapping %%K is missing in "%R4OS_PROFILE_FILE%".
    exit /b 1
)
exit /b 0

:run_profile_acceptance
echo === Distribution profile mapping acceptance ===
call :load_profile "Slim"
if errorlevel 1 exit /b %ERRORLEVEL%
if /i not "%R4OS_PROFILE%"=="Slim" exit /b 1
call :load_profile "Full"
if errorlevel 1 exit /b %ERRORLEVEL%
if /i not "%R4OS_PROFILE%"=="Full" exit /b 1
call :load_profile "Test"
if errorlevel 1 exit /b %ERRORLEVEL%
if /i not "%R4OS_PROFILE%"=="Test" exit /b 1
echo [OK] Slim, Full and Test profile mappings are readable.
exit /b 0

:run_plan_acceptance
echo === Slim, Full and Test image-plan acceptance ===
pushd "%R4OS_DISTRIBUTION_ROOT%" >nul || exit /b 1
"%R4OS_IMAGE_PLAN%" --check --output "Tests\Expected\Slim.plan" --plan "Tests\Fixtures\Plans\Common.plan" --plan "Tests\Fixtures\Plans\Slim.plan" --tree "Tests\Fixtures\Tree|/R4OS/SDK" --overlay "Tests\Fixtures\Injection"
if errorlevel 1 goto plan_acceptance_error
"%R4OS_IMAGE_PLAN%" --check --output "Tests\Expected\Full.plan" --plan "Tests\Fixtures\Plans\Common.plan" --plan "Tests\Fixtures\Plans\Full.plan" --tree "Tests\Fixtures\Tree|/R4OS/SDK" --overlay "Tests\Fixtures\Injection"
if errorlevel 1 goto plan_acceptance_error
"%R4OS_IMAGE_PLAN%" --check --output "Tests\Expected\Test.plan" --plan "Tests\Fixtures\Plans\Common.plan" --plan "Tests\Fixtures\Plans\Test.plan" --tree "Tests\Fixtures\Tree|/R4OS/SDK" --overlay "Tests\Fixtures\Injection" --overlay "Tests\Fixtures\TestInjection"
if errorlevel 1 goto plan_acceptance_error
"%R4OS_IMAGE_PLAN%" --check --output "Tests\Expected\Full.plan" --plan "Tests\Fixtures\Plans\Common.plan" --plan "Tests\Fixtures\Plans\Collision.plan" --tree "Tests\Fixtures\Tree|/R4OS/SDK" --overlay "Tests\Fixtures\Injection" >nul 2>&1
if not errorlevel 1 (
    echo ERROR: Duplicate target was accepted.
    goto plan_acceptance_error
)
popd
echo [OK] Slim, Full and Test plans are deterministic and collision-free.
exit /b 0

:plan_acceptance_error
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
if "%R4OS_EXIT_CODE%"=="0" set "R4OS_EXIT_CODE=1"
popd
exit /b %R4OS_EXIT_CODE%

:run_marker_acceptance
echo === QEMU marker evaluator acceptance ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%R4OS_QEMU_MARKER_TEST%" -SelfTest
exit /b %ERRORLEVEL%

:run_release_acceptance
echo === Release tool acceptance ===
call "%R4OS_RELEASE_TOOL%" selftest
exit /b %ERRORLEVEL%

:evaluate_headless_logs
set "R4OS_QEMU_EXIT=%~1"

echo.
echo === HEADLESS TEST EVALUATION ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%R4OS_QEMU_MARKER_TEST%" -LogPath "%R4OS_QEMU_LOG%" -ErrorPath "%R4OS_QEMU_ERROR_LOG%" -QemuExitCode %R4OS_QEMU_EXIT%
if errorlevel 1 (
    echo === HEADLESS TEST FAILED ===
    echo Log:    %R4OS_QEMU_LOG%
    echo Stderr: %R4OS_QEMU_ERROR_LOG%
    exit /b 1
)

echo === HEADLESS TEST OK ===
echo Boot: OK
echo Poweroff: OK
echo Errors: none
echo Log: %R4OS_QEMU_LOG%
exit /b 0

:usage
echo Usage:
echo   Build.bat
echo   Build.bat tools
echo   Build.bat test
echo   Build.bat plan Slim^|Full^|Test
echo   Build.bat image Slim^|Full^|Test
echo   Build.bat verify Slim^|Full^|Test
echo   Build.bat qemu Slim^|Full^|Test
echo   Build.bat headless Test
exit /b 1
