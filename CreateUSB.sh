#!/bin/sh
set -eu
usb_script_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if ! command -v pwsh >/dev/null 2>&1; then
    echo 'PowerShell 7 wird benoetigt (pwsh).' >&2
    exit 1
fi
exec pwsh -NoLogo -NoProfile -File "$usb_script_root/CreateUSB.ps1" "$@"
