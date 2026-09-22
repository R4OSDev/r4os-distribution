# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
# Extend the normal profile through the canonical module catalog. The final
# generated MODULES.JSON is still the sole installed module inventory.
function Add-R4GraphicsImageSelection($Context,[string]$Name,[ValidateSet('amd','nvidia')][string]$Vendor,[string]$ComponentPlan) {
 if($Name -ceq 'Benchmark'){throw 'Explicit graphics packages require Slim, Full or Test.'}
 . (Join-Path $PSScriptRoot 'GraphicsPackageProfiles.ps1')
 . (Join-Path $PSScriptRoot 'GraphicsPackageResources.ps1')
 $profile=Get-GraphicsPackageProfile $Vendor
 $wanted=@($profile.groups.Values|ForEach-Object {$_}|Sort-Object -Unique)
 $inventory=Join-Path $Context.output 'Generated/MODULES.JSON'
 $regular=Get-Content -Raw $inventory|ConvertFrom-Json
 $targets=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $regular.entries){if($entry.kind -cne 'KERNEL'){[void]$targets.Add($entry.target)}}
 $found=@{}
 $explicit=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($line in [IO.File]::ReadAllLines((Join-Path $Context.input 'WorkspaceModules.map'))){
  $pair=$line.Split('|');if($pair.Count -ne 2){throw 'Invalid workspace module map.'}
  $fields=Get-InstallationFields $pair[0]
  if($fields.NAME -in $wanted){
   if($found.ContainsKey($fields.NAME)){throw 'Duplicate graphics module identity.'}
   $found[$fields.NAME]=$true;[void]$targets.Add($fields.TARGET)
  }
  if(!$targets.Contains($fields.TARGET)){continue}
  $automatic=switch($Name.ToLowerInvariant()){
   'slim' {$fields.IMAGE_SCOPE -ceq 'slim'}
   'full' {$fields.IMAGE_SCOPE -in @('slim','full')}
   'test' {$fields.IMAGE_SCOPE -in @('slim','test')}
  }
  if(!$automatic){[void]$explicit.Add($fields.TARGET)}
  if($fields.NAME -in @('AMDGPU','NVIDIA')){
   $null=@(Test-GraphicsPackageResources ([pscustomobject]@{name=$fields.NAME;manifest=$pair[0];artifact=$pair[1];lines=[IO.File]::ReadAllLines($pair[0])}))
  }
 }
 if($found.Count -ne $wanted.Count){throw 'An explicitly requested graphics module is missing.'}
 $args=@('workspace-image-plan','--workspace-map',(Join-Path $Context.input 'WorkspaceModules.map'),'--image-mode',$Name.ToLowerInvariant(),
  '--output',(Join-Path $Context.input $ComponentPlan),'--inventory-output',$inventory,
  '--kernel-version-source',(Join-Path $Context.repositories 'Kernel/VERSION.R4S'),'--kernel-artifact',(Join-Path $Context.repositories 'Kernel/zig-out/bin/r4os.elf'))
 foreach($target in ($explicit|Sort-Object)){$args+=@('--include-target',$target)}
 Invoke-R4Distribution (Join-Path $Context.sdk ('zig-out/bin/module-catalog'+$Context.suffix)) $args
 $final=Get-Content -Raw $inventory|ConvertFrom-Json
 foreach($target in $targets){if($target -notin $final.entries.target){throw 'Generated inventory omitted an explicit graphics target.'}}
 Write-Host "Explicit $Vendor graphics image: $($wanted.Count) versioned modules plus normal $Name profile. Driver activation/configuration remains unchanged."
}
