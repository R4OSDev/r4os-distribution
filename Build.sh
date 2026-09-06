#!/bin/sh
set -eu
distribution_script_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if ! command -v pwsh >/dev/null 2>&1; then
    echo 'PowerShell 7 is required (pwsh).' >&2
    exit 1
fi
exec pwsh -NoLogo -NoProfile -File "$distribution_script_root/Build.ps1" "$@"
