#!/bin/sh
set -eu

distribution_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

if ! command -v pwsh >/dev/null 2>&1; then
    echo 'ERROR: PowerShell 7 (pwsh) was not found.' >&2
    exit 1
fi

exec pwsh -NoLogo -NoProfile -File "$distribution_root/Tools/Release.ps1" "$@"
