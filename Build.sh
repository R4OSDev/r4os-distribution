#!/bin/sh
set -eu

distribution_root=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
settings_file="$distribution_root/Settings.R4S"
action=${1:-tools}
requested_profile=${2:-}

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
output_root=$(resolve_path "$artifacts_root" "$distribution_output_setting")
input_root=$(resolve_path "$artifacts_root" "$input_setting")
private_injection_root=$(resolve_path "$artifacts_root" "$private_injection_setting")
zig_exe=$zig_root/zig
build_prefix=$output_root/HostTools
build_cache=$output_root/.Cache/build
global_cache=$output_root/.Cache/global
image_plan=$build_prefix/bin/image-plan
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
    "$zig_exe" build $build_step \
        "--cache-dir=$build_cache" \
        "--global-cache-dir=$global_cache" \
        "--prefix=$build_prefix" \
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
    if "$image_plan" --check --output Tests/Expected/Full.plan \
        --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Collision.plan \
        --tree 'Tests/Fixtures/Tree|/R4OS/SDK' --overlay Tests/Fixtures/Injection >/dev/null 2>&1; then
        echo 'ERROR: Duplicate target was accepted.' >&2
        exit 1
    fi
    echo '[OK] Slim, Full and Test plans are deterministic and collision-free.'
}

run_profile_acceptance() {
    for expected_profile in Slim Full Test; do
        load_profile "$expected_profile"
        if [ "$profile" != "$expected_profile" ]; then
            echo "ERROR: Profile identity mismatch: expected $expected_profile, got $profile" >&2
            exit 1
        fi
    done
    echo '[OK] Slim, Full and Test profile mappings are readable.'
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
    while IFS='=' read -r key value; do
        case "$key" in
            PROFILE) profile=$value ;;
            COMMON_PLAN) common_plan_name=$value ;;
            COMPONENT_PLAN) component_plan_name=$value ;;
            TEST_OVERLAY) test_overlay=$value ;;
        esac
    done < "$profile_file"
    require_setting PROFILE "$profile"
    require_setting COMMON_PLAN "$common_plan_name"
    require_setting COMPONENT_PLAN "$component_plan_name"
    require_setting TEST_OVERLAY "$test_overlay"
}

generate_plan() {
    load_profile "$1"
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
    if [ "$test_overlay" = 1 ]; then
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

case "$action" in
    tools) build_tools ;;
    test) run_profile_acceptance; validate_legal_source; build_tools test; run_plan_acceptance ;;
    plan)
        if [ -z "$requested_profile" ]; then
            echo 'Usage: Build.sh plan Slim|Full|Test' >&2
            exit 1
        fi
        generate_plan "$requested_profile"
        ;;
    *)
        echo 'Usage: Build.sh [tools|test|plan Slim|Full|Test]' >&2
        echo 'Image, verify and QEMU actions currently use Build.bat with the Windows DevKit.' >&2
        exit 1
        ;;
esac
