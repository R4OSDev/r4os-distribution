#!/bin/sh
set -eu

distribution_root=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
settings_file="$distribution_root/Settings.R4S"
action=${1:-tools}
requested_profile=${2:-}
requested_variant=${3:-}

if [ ! -f "$settings_file" ]; then
    echo "ERROR: Settings file not found: $settings_file" >&2
    exit 1
fi

workspace_setting=
repositories_setting=
contract_setting=
sdk_setting=
libraries_setting=
devkit_setting=
artifacts_setting=
zig_setting=
limine_setting=
qemu_setting=
devkit_hosttools_setting=
distribution_output_setting=
input_setting=
private_injection_setting=

while IFS='=' read -r key value; do
    case "$key" in
        WORKSPACE_ROOT) workspace_setting=$value ;;
        REPOSITORIES_ROOT) repositories_setting=$value ;;
        CONTRACT_ROOT) contract_setting=$value ;;
        SDK_ROOT) sdk_setting=$value ;;
        LIBRARIES_ROOT) libraries_setting=$value ;;
        DEVKIT_ROOT) devkit_setting=$value ;;
        ARTIFACTS_ROOT) artifacts_setting=$value ;;
        ZIG_ROOT) zig_setting=$value ;;
        LIMINE_ROOT) limine_setting=$value ;;
        QEMU_ROOT) qemu_setting=$value ;;
        DEVKIT_HOSTTOOLS_ROOT) devkit_hosttools_setting=$value ;;
        DISTRIBUTION_OUTPUT_ROOT) distribution_output_setting=$value ;;
        INPUT_ROOT) input_setting=$value ;;
        PRIVATE_INJECTION_ROOT) private_injection_setting=$value ;;
    esac
done < "$settings_file"

require_setting() {
    if [ -z "$2" ]; then
        echo "ERROR: $1 is missing in $settings_file" >&2
        exit 1
    fi
}

resolve_path() {
    case "$2" in
        /*) printf '%s\n' "$2" ;;
        *) printf '%s/%s\n' "$1" "$2" ;;
    esac
}

require_setting WORKSPACE_ROOT "$workspace_setting"
require_setting REPOSITORIES_ROOT "$repositories_setting"
require_setting CONTRACT_ROOT "$contract_setting"
require_setting SDK_ROOT "$sdk_setting"
require_setting LIBRARIES_ROOT "$libraries_setting"
require_setting DEVKIT_ROOT "$devkit_setting"
require_setting ARTIFACTS_ROOT "$artifacts_setting"
require_setting ZIG_ROOT "$zig_setting"
require_setting LIMINE_ROOT "$limine_setting"
require_setting QEMU_ROOT "$qemu_setting"
require_setting DEVKIT_HOSTTOOLS_ROOT "$devkit_hosttools_setting"
require_setting DISTRIBUTION_OUTPUT_ROOT "$distribution_output_setting"
require_setting INPUT_ROOT "$input_setting"
require_setting PRIVATE_INJECTION_ROOT "$private_injection_setting"

workspace_root=$(resolve_path "$distribution_root" "$workspace_setting")
repositories_root=$(resolve_path "$distribution_root" "$repositories_setting")
contract_root=$(resolve_path "$repositories_root" "$contract_setting")
sdk_root=$(resolve_path "$repositories_root" "$sdk_setting")
libraries_root=$(resolve_path "$repositories_root" "$libraries_setting")
devkit_root=$(resolve_path "$workspace_root" "$devkit_setting")
artifacts_root=$(resolve_path "$workspace_root" "$artifacts_setting")
zig_root=$(resolve_path "$devkit_root" "$zig_setting")
limine_root=$(resolve_path "$devkit_root" "$limine_setting")
qemu_root=$(resolve_path "$devkit_root" "$qemu_setting")
devkit_hosttools_root=$(resolve_path "$devkit_root" "$devkit_hosttools_setting")
output_root=$(resolve_path "$artifacts_root" "$distribution_output_setting")
input_root=$(resolve_path "$artifacts_root" "$input_setting")
private_injection_root=$(resolve_path "$artifacts_root" "$private_injection_setting")
if [ "${R4OS_PUBLIC_IMAGE:-0}" = 1 ]; then
    # Public release builds deliberately point the optional overlay at a
    # reserved absent path. Release.ps1 additionally rejects any plan that
    # still names the real private root.
    private_injection_root=$output_root/.PublicImageNoPrivateInjection
fi
zig_exe=$zig_root/zig
limine_exe=$limine_root/limine
qemu_exe=$qemu_root/qemu-system-x86_64
build_prefix=$output_root/HostTools
build_cache=$output_root/.Cache/build
global_cache=$output_root/.Cache/global
image_plan=$build_prefix/bin/image-plan
image_creator=$build_prefix/bin/imagecreater
ntfs_verify=$build_prefix/bin/ntfsverify
qemu_config=$distribution_root/QEMU/standard.conf
benchmark_qemu_config=$distribution_root/QEMU/benchmark.conf
qemu_runner=$distribution_root/Tools/Invoke-Qemu.ps1
qemu_timeout_helper=$distribution_root/Tests/Invoke-QemuHeadless.ps1
benchmark_runner=$distribution_root/Tests/Invoke-QemuBenchmark.ps1
benchmark_history=$distribution_root/Tools/BenchmarkHistory.ps1
qemu_marker_test=$distribution_root/Tests/Test-QemuApiMarkers.ps1
release_tool=$distribution_root/Tools/Release.ps1
log_root=$output_root/Logs
legal_source=$distribution_root/Injection/R4OS/LICENSES

if [ ! -f "$contract_root/build.zig.zon" ]; then
    echo "ERROR: Contract repository not found: $contract_root" >&2
    exit 1
fi
if [ ! -f "$sdk_root/build.zig.zon" ]; then
    echo "ERROR: SDK repository not found: $sdk_root" >&2
    exit 1
fi
if [ ! -f "$libraries_root/build.zig.zon" ]; then
    echo "ERROR: Libraries repository not found: $libraries_root" >&2
    exit 1
fi
if [ ! -x "$zig_exe" ]; then
    echo "ERROR: Zig executable not found: $zig_exe" >&2
    exit 1
fi

build_tools() {
    mkdir -p "$build_prefix" "$build_cache" "$global_cache"
    if [ "${1:-}" = test ]; then
        build_step=test
    else
        build_step=
    fi
    cd "$distribution_root"
    "$zig_exe" build \
        --cache-dir "$build_cache" \
        --global-cache-dir "$global_cache" \
        --prefix "$build_prefix" \
        $build_step \
        -Doptimize=ReleaseSafe \
        "--fork=$sdk_root" \
        "--fork=$contract_root" \
        "--fork=$libraries_root"
}

validate_legal_source() {
    for name in \
        R4OS-LICENSE.txt \
        R4OS-NOTICE.txt \
        THIRD-PARTY-NOTICES.txt \
        Limine-BSD-2-Clause.txt \
        FreeType-FTL.txt \
        Brotli-MIT.txt \
        zlib.txt \
        stb_image-MIT.txt \
        RTL8168-GPL-2.0-only.txt
    do
        if [ ! -f "$legal_source/$name" ]; then
            echo "ERROR: Required legal file is missing: $legal_source/$name" >&2
            exit 1
        fi
    done
    if ! cmp -s "$distribution_root/LICENSE" "$legal_source/R4OS-LICENSE.txt"; then
        echo 'ERROR: Image Apache license differs from repository LICENSE.' >&2
        exit 1
    fi
    if ! cmp -s "$distribution_root/NOTICE" "$legal_source/R4OS-NOTICE.txt"; then
        echo 'ERROR: Image NOTICE differs from repository NOTICE.' >&2
        exit 1
    fi
}

validate_image_legal_plan() {
    if [ ! -f "$image_list" ]; then
        echo "ERROR: Image plan not found: $image_list" >&2
        exit 1
    fi
    for name in \
        R4OS-LICENSE.txt \
        R4OS-NOTICE.txt \
        THIRD-PARTY-NOTICES.txt \
        Limine-BSD-2-Clause.txt \
        FreeType-FTL.txt \
        Brotli-MIT.txt \
        zlib.txt \
        stb_image-MIT.txt \
        RTL8168-GPL-2.0-only.txt
    do
        if ! grep -F ":/R4OS/LICENSES/$name" "$image_list" >/dev/null; then
            echo "ERROR: Image plan omits legal file: /R4OS/LICENSES/$name" >&2
            exit 1
        fi
    done
}

run_plan_acceptance() {
    cd "$distribution_root"
    "$image_plan" --check --output Tests/Expected/Slim.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Slim.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' --overlay Tests/Fixtures/Injection
    "$image_plan" --check --output Tests/Expected/Full.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Full.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' --overlay Tests/Fixtures/Injection
    "$image_plan" --check --output Tests/Expected/Test.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Test.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' \
        --overlay Tests/Fixtures/Injection --overlay Tests/Fixtures/TestInjection
    "$image_plan" --check --output Tests/Expected/Benchmark.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Test.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' \
        --overlay Tests/Fixtures/Injection --overlay Tests/Fixtures/BenchmarkInjection
    if "$image_plan" --check --output Tests/Expected/Full.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Collision.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' --overlay Tests/Fixtures/Injection >/dev/null 2>&1; then
        echo 'ERROR: Duplicate target was accepted.' >&2
        exit 1
    fi
    echo '[OK] Slim, Full, Test and Benchmark plans are deterministic and collision-free.'
}

run_profile_acceptance() {
    for expected_profile in Slim Full Test Benchmark; do
        load_profile "$expected_profile"
        if [ "$profile" != "$expected_profile" ]; then
            echo "ERROR: Profile identity mismatch: expected $expected_profile, got $profile" >&2
            exit 1
        fi
    done
    if [ "$benchmark_overlay" != 1 ]; then
        echo 'ERROR: Benchmark profile has no benchmark overlay.' >&2
        exit 1
    fi
    echo '[OK] Slim, Full, Test and Benchmark profile mappings are readable.'
}

load_profile() {
    profile_file=$distribution_root/Profiles/$1.R4S
    if [ ! -f "$profile_file" ]; then
        echo "ERROR: Unknown distribution profile: $1" >&2
        exit 1
    fi
    profile=
    common_plan_name=
    component_plan_name=
    test_overlay=
    benchmark_overlay=
    boot_mb=
    system_mb=
    data_mb=
    while IFS='=' read -r key value; do
        case "$key" in
            PROFILE) profile=$value ;;
            COMMON_PLAN) common_plan_name=$value ;;
            COMPONENT_PLAN) component_plan_name=$value ;;
            TEST_OVERLAY) test_overlay=$value ;;
            BENCHMARK_OVERLAY) benchmark_overlay=$value ;;
            BOOT_MB) boot_mb=$value ;;
            SYSTEM_MB) system_mb=$value ;;
            DATA_MB) data_mb=$value ;;
        esac
    done < "$profile_file"
    require_setting PROFILE "$profile"
    require_setting COMMON_PLAN "$common_plan_name"
    require_setting COMPONENT_PLAN "$component_plan_name"
    require_setting TEST_OVERLAY "$test_overlay"
    require_setting BENCHMARK_OVERLAY "$benchmark_overlay"
    require_setting BOOT_MB "$boot_mb"
    require_setting SYSTEM_MB "$system_mb"
    require_setting DATA_MB "$data_mb"
}

generate_plan() {
    load_profile "$1"
    plan_variant=${2:-}
    if [ -n "$plan_variant" ] && { [ "$profile" != Test ] || [ "$plan_variant" != browser ]; }; then
        echo "ERROR: Unknown image variant for $profile: $plan_variant" >&2
        exit 1
    fi
    validate_legal_source
    if [ ! -x "$image_plan" ]; then
        build_tools
    fi
    common_plan=$input_root/$common_plan_name
    component_plan=$input_root/$component_plan_name
    if [ ! -f "$common_plan" ] || [ ! -f "$component_plan" ]; then
        echo "ERROR: Explicit artifact plans are missing below $input_root" >&2
        exit 1
    fi
    profile_output=$output_root/Profiles/$profile
    image_list=$profile_output/image-adds.txt
    mkdir -p "$profile_output"
    cd "$distribution_root"
    if [ "$benchmark_overlay" = 1 ]; then
        "$image_plan" --output "$image_list" --plan "$common_plan" --plan "$component_plan" \
            --tree "$sdk_root/Shared/C/include|/R4OS/SDK/Include/C" \
            --tree "$sdk_root/Shared/C/src|/R4OS/SDK/Startup/C" \
            --tree "$sdk_root/r4os/linker|/R4OS/SDK/Linker" \
            --tree "$sdk_root/Templates|/R4OS/SDK/Templates" \
            --tree "$sdk_root/BuildProfiles|/R4OS/SDK/BuildProfiles" \
            --tree "$sdk_root/Toolchains|/R4OS/SDK/Toolchains" \
            --tree "$contract_root/ABI|/R4OS/SDK/Contract/ABI" \
            --tree "$contract_root/API|/R4OS/SDK/Contract/API" \
            --tree "$contract_root/Generated|/R4OS/SDK/Contract/Generated" \
            --tree "$contract_root/Module|/R4OS/SDK/Contract/Module" \
            --overlay "$distribution_root/Injection" \
            --overlay "$distribution_root/BenchmarkInjection"
    elif [ "$test_overlay" = 1 ]; then
        if [ "$plan_variant" = browser ]; then
            "$image_plan" --output "$image_list" --plan "$common_plan" --plan "$component_plan" \
                --tree "$sdk_root/Shared/C/include|/R4OS/SDK/Include/C" \
                --tree "$sdk_root/Shared/C/src|/R4OS/SDK/Startup/C" \
                --tree "$sdk_root/r4os/linker|/R4OS/SDK/Linker" \
                --tree "$sdk_root/Templates|/R4OS/SDK/Templates" \
                --tree "$sdk_root/BuildProfiles|/R4OS/SDK/BuildProfiles" \
                --tree "$sdk_root/Toolchains|/R4OS/SDK/Toolchains" \
                --tree "$contract_root/ABI|/R4OS/SDK/Contract/ABI" \
                --tree "$contract_root/API|/R4OS/SDK/Contract/API" \
                --tree "$contract_root/Generated|/R4OS/SDK/Contract/Generated" \
                --tree "$contract_root/Module|/R4OS/SDK/Contract/Module" \
                --overlay "$distribution_root/Injection" \
                --overlay "$distribution_root/TestInjection" \
                --overlay "$distribution_root/BrowserTestInjection" \
                --optional-overlay "$output_root/Injection" \
                --optional-overlay "$private_injection_root"
        else
            "$image_plan" --output "$image_list" --plan "$common_plan" --plan "$component_plan" \
                --tree "$sdk_root/Shared/C/include|/R4OS/SDK/Include/C" \
                --tree "$sdk_root/Shared/C/src|/R4OS/SDK/Startup/C" \
                --tree "$sdk_root/r4os/linker|/R4OS/SDK/Linker" \
                --tree "$sdk_root/Templates|/R4OS/SDK/Templates" \
                --tree "$sdk_root/BuildProfiles|/R4OS/SDK/BuildProfiles" \
                --tree "$sdk_root/Toolchains|/R4OS/SDK/Toolchains" \
                --tree "$contract_root/ABI|/R4OS/SDK/Contract/ABI" \
                --tree "$contract_root/API|/R4OS/SDK/Contract/API" \
                --tree "$contract_root/Generated|/R4OS/SDK/Contract/Generated" \
                --tree "$contract_root/Module|/R4OS/SDK/Contract/Module" \
                --overlay "$distribution_root/Injection" \
                --overlay "$distribution_root/TestInjection" \
                --optional-overlay "$output_root/Injection" \
                --optional-overlay "$private_injection_root"
        fi
    else
        "$image_plan" --output "$image_list" --plan "$common_plan" --plan "$component_plan" \
            --tree "$sdk_root/Shared/C/include|/R4OS/SDK/Include/C" \
            --tree "$sdk_root/Shared/C/src|/R4OS/SDK/Startup/C" \
            --tree "$sdk_root/r4os/linker|/R4OS/SDK/Linker" \
            --tree "$sdk_root/Templates|/R4OS/SDK/Templates" \
            --tree "$sdk_root/BuildProfiles|/R4OS/SDK/BuildProfiles" \
            --tree "$sdk_root/Toolchains|/R4OS/SDK/Toolchains" \
            --tree "$contract_root/ABI|/R4OS/SDK/Contract/ABI" \
            --tree "$contract_root/API|/R4OS/SDK/Contract/API" \
            --tree "$contract_root/Generated|/R4OS/SDK/Contract/Generated" \
            --tree "$contract_root/Module|/R4OS/SDK/Contract/Module" \
            --overlay "$distribution_root/Injection" \
            --optional-overlay "$output_root/Injection" \
            --optional-overlay "$private_injection_root"
    fi
    validate_image_legal_plan
}

validate_staged_legal() {
    for name in \
        R4OS-LICENSE.txt \
        R4OS-NOTICE.txt \
        THIRD-PARTY-NOTICES.txt \
        Limine-BSD-2-Clause.txt \
        FreeType-FTL.txt \
        Brotli-MIT.txt \
        zlib.txt \
        stb_image-MIT.txt \
        RTL8168-GPL-2.0-only.txt
    do
        if [ ! -f "$profile_legal/$name" ]; then
            echo "ERROR: Staged legal file is missing: $profile_legal/$name" >&2
            exit 1
        fi
    done
}

stage_legal() {
    profile_legal=$profile_output/Legal
    case "$profile_legal/" in
        "$output_root"/*) ;;
        *)
            echo "ERROR: Refusing to reset legal directory outside output root: $profile_legal" >&2
            exit 1
            ;;
    esac
    rm -rf "$profile_legal"
    mkdir -p "$profile_legal"
    cp "$legal_source"/* "$profile_legal/"
    validate_staged_legal
    echo "[OK] Release legal payload: $profile_legal"
}

image_action() {
    generate_plan "$1" "${2:-}"
    validate_legal_source
    if [ ! -x "$image_creator" ]; then
        build_tools
    fi
    if [ ! -x "$limine_exe" ]; then
        echo "ERROR: Limine executable not found: $limine_exe" >&2
        exit 1
    fi
    ntfs_meta=$sdk_root/Tests/Fixture/Ntfs/Meta0605
    if [ ! -f "$ntfs_meta/upcase.bin" ]; then
        echo "ERROR: NTFS metadata fixture not found: $ntfs_meta" >&2
        exit 1
    fi
    echo "=== Create $profile image ==="
    "$image_creator" create-system \
        --output "$profile_output/disk.img" \
        --boot-mb "$boot_mb" \
        --system-mb "$system_mb" \
        --meta "$ntfs_meta" \
        --add-list "$image_list"
    if [ "$profile" = Benchmark ]; then
        rm -f "$profile_output/data.img"
    fi
    if [ ! -f "$profile_output/data.img" ]; then
        "$image_creator" --output "$profile_output/data.img" --size "$data_mb"
    fi
    "$limine_exe" bios-install "$profile_output/disk.img"
    stage_legal
}

verify_action() {
    load_profile "$1"
    profile_output=$output_root/Profiles/$profile
    image_list=$profile_output/image-adds.txt
    profile_legal=$profile_output/Legal
    if [ ! -f "$profile_output/disk.img" ]; then
        echo "ERROR: Image not found: $profile_output/disk.img" >&2
        exit 1
    fi
    validate_image_legal_plan
    validate_staged_legal
    if [ ! -x "$ntfs_verify" ]; then
        build_tools
    fi
    "$ntfs_verify" "$profile_output/disk.img"
}

qemu_action() {
    load_profile "$1"
    profile_output=$output_root/Profiles/$profile
    if [ ! -f "$profile_output/disk.img" ]; then
        echo "ERROR: Image not found: $profile_output/disk.img" >&2
        exit 1
    fi
    if [ ! -f "$profile_output/data.img" ]; then
        echo "ERROR: Data image not found: $profile_output/data.img" >&2
        exit 1
    fi
    for required_file in "$qemu_exe" "$qemu_config" "$qemu_runner"; do
        if [ ! -e "$required_file" ]; then
            echo "ERROR: QEMU dependency not found: $required_file" >&2
            exit 1
        fi
    done
    pwsh -NoLogo -NoProfile -File "$qemu_runner" \
        -Mode Gui -QemuPath "$qemu_exe" -ConfigPath "$qemu_config" \
        -WorkingDirectory "$profile_output"
}

ssh_action() {
    load_profile "$1"
    if [ "$profile" != Full ]; then
        echo 'ERROR: SSH debugging requires the Full profile.' >&2
        exit 1
    fi
    profile_output=$output_root/Profiles/$profile
    for required_file in "$profile_output/disk.img" "$profile_output/data.img" "$qemu_exe" "$qemu_config" "$qemu_runner"; do
        if [ ! -e "$required_file" ]; then
            echo "ERROR: SSH debug dependency not found: $required_file" >&2
            exit 1
        fi
    done
    mkdir -p "$log_root"
    pwsh -NoLogo -NoProfile -File "$qemu_runner" \
        -Mode SshDebug -QemuPath "$qemu_exe" -ConfigPath "$qemu_config" \
        -WorkingDirectory "$profile_output" -SerialLogPath "$log_root/qemu-ssh-debug.log"
}

headless_action() {
    load_profile "$1"
    headless_variant=${2:-}
    if [ -n "$headless_variant" ] && [ "$headless_variant" != browser ] && \
        [ "$headless_variant" != smp2 ] && [ "$headless_variant" != smp4 ] && \
        [ "$headless_variant" != smpfail4 ]; then
        echo "ERROR: Unknown headless variant: $headless_variant" >&2
        exit 1
    fi
    smp_cpu_count=1
    smp_failed_count=0
    if [ "$headless_variant" = smp2 ]; then smp_cpu_count=2; fi
    if [ "$headless_variant" = smp4 ]; then smp_cpu_count=4; fi
    if [ "$headless_variant" = smpfail4 ]; then
        smp_cpu_count=4
        smp_failed_count=1
    fi
    if [ "$profile" != Test ] || [ "$test_overlay" != 1 ]; then
        echo 'ERROR: Headless acceptance requires the Test profile with test overlay.' >&2
        exit 1
    fi
    profile_output=$output_root/Profiles/$profile
    if [ ! -f "$profile_output/disk.img" ]; then
        echo "ERROR: Image not found: $profile_output/disk.img" >&2
        exit 1
    fi
    if [ ! -x "$image_creator" ]; then
        build_tools
    fi
    for required_file in "$qemu_exe" "$qemu_config" "$qemu_timeout_helper" "$qemu_marker_test"; do
        if [ ! -e "$required_file" ]; then
            echo "ERROR: Headless dependency not found: $required_file" >&2
            exit 1
        fi
    done

    rm -f "$profile_output/data.img"
    echo "=== Recreate Test data image for headless acceptance: $data_mb MB ==="
    "$image_creator" --output "$profile_output/data.img" --size "$data_mb"

    mkdir -p "$log_root"
    qemu_log=$log_root/qemu-test-${headless_variant:-standard}.log
    qemu_error_log=$log_root/qemu-test-${headless_variant:-standard}.err
    rm -f "$qemu_log" "$qemu_error_log"
    if [ -n "${QEMU_TEST_TIMEOUT_SECONDS:-}" ]; then
        qemu_timeout=$QEMU_TEST_TIMEOUT_SECONDS
    elif [ "$headless_variant" = browser ]; then
        qemu_timeout=360
    else
        qemu_timeout=240
    fi

    export R4OS_QEMU_EXE=$qemu_exe
    export R4OS_QEMU_CONFIG=$qemu_config
    export R4OS_QEMU_LOG=$qemu_log
    export R4OS_QEMU_ERROR_LOG=$qemu_error_log
    export R4OS_QEMU_WORKING_DIRECTORY=$profile_output
    export R4OS_QEMU_CPUS=$smp_cpu_count
    export QEMU_TEST_TIMEOUT_SECONDS=$qemu_timeout

    echo '=== Start QEMU Test profile headless ==='
    echo "    Config:  $qemu_config"
    echo "    Serial:  $qemu_log"
    echo "    Timeout: ${qemu_timeout}s"
    if pwsh -NoLogo -NoProfile -File "$qemu_timeout_helper"; then
        qemu_exit=0
    else
        qemu_exit=$?
    fi
    if [ "$qemu_exit" -eq 124 ]; then
        echo "QEMU: TIMEOUT after ${qemu_timeout}s; guest did not power off."
    fi

    echo '=== HEADLESS TEST EVALUATION ==='
    if [ "$headless_variant" = browser ]; then
        marker_exit=0
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" \
            -LogPath "$qemu_log" -ErrorPath "$qemu_error_log" -QemuExitCode "$qemu_exit" -Browser || marker_exit=$?
    elif [ "$smp_cpu_count" -gt 1 ]; then
        marker_exit=0
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" \
            -LogPath "$qemu_log" -ErrorPath "$qemu_error_log" -QemuExitCode "$qemu_exit" \
            -SmpCpuCount "$smp_cpu_count" -SmpFailedCount "$smp_failed_count" || marker_exit=$?
    else
        marker_exit=0
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" \
            -LogPath "$qemu_log" -ErrorPath "$qemu_error_log" -QemuExitCode "$qemu_exit" || marker_exit=$?
    fi
    if [ "$marker_exit" -ne 0 ]; then
        echo '=== HEADLESS TEST FAILED ==='
        echo "Log:    $qemu_log"
        echo "Stderr: $qemu_error_log"
        exit 1
    fi
    echo '=== HEADLESS TEST OK ==='
    echo 'Boot: OK'
    echo 'Poweroff: OK'
    echo 'Errors: none'
    echo "Log: $qemu_log"
}

benchmark_action() {
    load_profile "$1"
    if [ "$profile" != Benchmark ] || [ "$benchmark_overlay" != 1 ]; then
        echo 'ERROR: Explicit benchmark runs require the Benchmark profile with benchmark overlay.' >&2
        exit 1
    fi
    profile_output=$output_root/Profiles/$profile
    if [ ! -f "$profile_output/disk.img" ]; then
        echo "ERROR: Benchmark image not found: $profile_output/disk.img" >&2
        exit 1
    fi
    if [ ! -x "$image_creator" ]; then
        build_tools
    fi
    for required_file in "$qemu_exe" "$benchmark_qemu_config" "$benchmark_runner"; do
        if [ ! -e "$required_file" ]; then
            echo "ERROR: Benchmark dependency not found: $required_file" >&2
            exit 1
        fi
    done

    export R4OS_BENCHMARK_QEMU_EXE=$qemu_exe
    export R4OS_BENCHMARK_QEMU_CONFIG=$benchmark_qemu_config
    export R4OS_BENCHMARK_IMAGE_CREATOR=$image_creator
    export R4OS_BENCHMARK_PROFILE_OUTPUT=$profile_output
    export R4OS_BENCHMARK_RUN_OUTPUT=$profile_output/Runs/current
    export R4OS_BENCHMARK_DATA_MB=$data_mb
    export R4OS_BENCHMARK_RELEASE_VERSION_FILE=$distribution_root/Injection/R4OS/CONFIG/VERSION.R4S
    pwsh -NoLogo -NoProfile -File "$benchmark_runner" \
        -Suite "$2" -WorkloadVersion "$3" -CacheState "$4" \
        -Repetitions "$5" -EnvironmentId "$6"
}

case "$action" in
    tools) build_tools ;;
    test)
        run_profile_acceptance
        validate_legal_source
        build_tools test
        run_plan_acceptance
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" -SelfTest
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" -SelfTest -Browser
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" -SelfTest -SmpCpuCount 4
        pwsh -NoLogo -NoProfile -File "$qemu_marker_test" -SelfTest -SmpCpuCount 4 -SmpFailedCount 1
        pwsh -NoLogo -NoProfile -File "$qemu_runner" -SelfTest
        pwsh -NoLogo -NoProfile -File "$benchmark_runner" -SelfTest
        pwsh -NoLogo -NoProfile -File "$benchmark_history" -Action selftest
        pwsh -NoLogo -NoProfile -File "$release_tool" -Action SelfTest
        ;;
    plan)
        if [ -z "$requested_profile" ]; then
            echo 'Usage: Build.sh plan Slim|Full|Test|Benchmark' >&2
            exit 1
        fi
        generate_plan "$requested_profile" "$requested_variant"
        ;;
    image) image_action "$requested_profile" "$requested_variant" ;;
    verify) verify_action "$requested_profile" ;;
    qemu) qemu_action "$requested_profile" ;;
    ssh) ssh_action "$requested_profile" ;;
    headless) headless_action "$requested_profile" "$requested_variant" ;;
    benchmark)
        if [ "$#" -ne 7 ]; then
            echo 'Usage: Build.sh benchmark Benchmark SUITE WORKLOAD_VERSION WARM|COLD REPETITIONS ENVIRONMENT_ID' >&2
            exit 1
        fi
        benchmark_action "$requested_profile" "$3" "$4" "$5" "$6" "$7"
        ;;
    *)
        echo 'Usage: Build.sh [tools|test|plan|image|verify|qemu|ssh|headless|benchmark] ... (headless Test [browser|smp2|smp4|smpfail4])' >&2
        exit 1
        ;;
esac
