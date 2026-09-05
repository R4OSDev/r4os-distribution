param(
    [Parameter(Position=0)][ValidateSet('recovery-image')][string]$Action='recovery-image',
    [Parameter(Position=1)][ValidateSet('Slim','Full')][string]$Profile='Slim',
    [string]$InputList='', [string]$RecoveryPackage='',
    [ValidateSet('local','usb')][string]$Medium='local', [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
    . (Join-Path $PSScriptRoot 'Tools/InstallationImage.ps1')
    New-R4OSInstallationImage -Root $PSScriptRoot -Profile $Profile -InputList $InputList -RecoveryPackage $RecoveryPackage -Medium $Medium -OutputRoot $OutputRoot
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
