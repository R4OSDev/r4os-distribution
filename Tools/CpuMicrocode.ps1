param([string]$Manifest=(Join-Path $PSScriptRoot '../Firmware/CPU/Manifest.json'),[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuMicrocodeFormat.ps1')
$image=New-R4CpuMicrocodeAppendix -Manifest $Manifest
$destination=[IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
[IO.File]::WriteAllBytes($destination,$image)
Write-Host ('CPU microcode appendix: '+$destination+'; pinned vendor files=2; bytes='+$image.Length+'; no hardware operation')
