# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
# Offline R4U composition. Module manifests remain the version/target owner;
# this file selects product groups, never PCI devices or runtime capabilities.
param(
 [ValidateSet('all','platform','preload','core','api','video','desktop')][string]$Group='all',
 [ValidateSet('nvidia','amd')][string]$Vendor='nvidia',
 [string]$ReleaseVersion='', [string]$OutputDirectory=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Vendor=$Vendor.ToLowerInvariant();$Group=$Group.ToLowerInvariant()
. (Join-Path $PSScriptRoot 'Distribution.ps1')
. (Join-Path $PSScriptRoot 'GraphicsPackageResources.ps1')
$context=Get-R4DistributionContext (Split-Path $PSScriptRoot -Parent)
$utf8=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'GraphicsPackageProfiles.ps1')
$profile=Get-GraphicsPackageProfile $Vendor
$prefix=if($Vendor -ceq 'nvidia'){'GFX-'}else{'GFX-AMD-'}
$groups=$profile.groups
$legal=$profile.legal
if(!$ReleaseVersion){$ReleaseVersion=(Get-InstallationFields (Join-Path $context.root 'Injection/R4OS/CONFIG/VERSION.R4S')).RELEASE_VERSION}
if($ReleaseVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Invalid release version.'}
$selection=if($Group -ceq 'all'){@($groups.Keys)}else{@($Group)}
if(!$OutputDirectory){$OutputDirectory=Join-Path $context.output ("GraphicsPackages/$ReleaseVersion/$Vendor/$Group")}
$destination=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $destination){throw 'Output already exists; graphics package sets are immutable. Choose a new output directory.'}
$scratch=Join-Path $context.workspace ('Temp/GraphicsPackages-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch)|Out-Null
try {
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $context.workspace 'Tools/BuildWorkspace.ps1'),'-Action','plan','-Profile','Slim')
 Build-R4DistributionTools $context
 Test-R4DistributionLegal $context
 $catalog=Join-Path $context.sdk ('zig-out/bin/module-catalog'+$context.suffix)
 $packer=Join-Path $context.prefix ('bin/r4upack'+$context.suffix)
 $map=[IO.File]::ReadAllLines((Join-Path $context.input 'WorkspaceModules.map'))
 $modules=@{}
 function Get-GraphicsModule([string]$Name){
  if($modules.ContainsKey($Name)){return $modules[$Name]}
  $found=@(foreach($line in $map){
   $pair=$line.Split('|')
   if($pair.Count -ne 2){throw 'Invalid workspace map.'}
   $lines=[IO.File]::ReadAllLines($pair[0])
   if($lines -ccontains ('NAME='+$Name)){
    $fields=@{}
    foreach($key in @('KIND','NAME','VERSION','TARGET')){
     $values=@($lines|Where-Object {$_.StartsWith($key+'=',[StringComparison]::Ordinal)})
     if($values.Count -ne 1){throw "Invalid manifest field: $Name / $key"}
     $fields[$key]=$values[0].Substring($key.Length+1)
    }
    Invoke-R4Distribution $catalog @('validate','--manifest',$pair[0]) | Out-Host
    if(!(Test-Path -LiteralPath $pair[1] -PathType Leaf)){throw "Build $Name before packaging."}
    [pscustomobject]@{name=$Name;kind=$fields.KIND;version=$fields.VERSION;target=$fields.TARGET;manifest=$pair[0];artifact=$pair[1];lines=$lines}
   }
  })
  if($found.Count -ne 1){throw "Module identity must resolve exactly once: $Name"}
  $modules[$Name]=$found[0];return $found[0]
 }
 $kernelVersion=(Get-InstallationFields (Join-Path $context.repositories 'Kernel/VERSION.R4S')).KERNEL_VERSION
 $records=[Collections.Generic.List[object]]::new()
 $total=0
 foreach($groupName in $selection){
  $payloads=[Collections.Generic.List[string]]::new()
  $requirements=[Collections.Generic.List[string]]::new()
  $components=[Collections.Generic.List[object]]::new()
  $resources=[Collections.Generic.List[object]]::new()
  foreach($name in $groups[$groupName]){
   $module=Get-GraphicsModule $name
   $payloads.Add($module.artifact+'|C:'+$module.target+'|auto')
   $components.Add($module)
   if($name -in @('NVIDIA','AMDGPU')){
    $resources.AddRange([object[]]@(Test-GraphicsPackageResources $module))
   }
  }
  if($groupName -ceq 'preload'){
   $preload=Join-Path $context.output 'Generated/PRELOAD.R4I'
   $resources.AddRange([object[]]@(Test-GraphicsPreloadResources $preload $components))
   $payloads.Add($preload+'|/boot/preload.r4i|preload')
   foreach($name in @('HIDREPORT','USBHID','USBBOT','USBSCSI')){
    $module=Get-GraphicsModule $name
    $payloads.Add($module.artifact+'|/boot/preload/'+$name.ToLowerInvariant()+'.r4p|preload')
   }
  }
  $dependencyNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($component in $components){
   foreach($line in $component.lines){
    if(!$line.StartsWith('IMPORT=',[StringComparison]::Ordinal)){continue}
    $import=$line.Substring(7).Split(':')
    if($import[0] -in @('R4SYS','R4DESK','R4DRAW','R4NET','R4AUDIO','R4DEV') -or
       ($import.Count -ge 4 -and $import[3] -ceq '1') -or $import[0] -in $groups[$groupName]){continue}
    if($dependencyNames.Add($import[0])){
     $dependency=Get-GraphicsModule $import[0]
     if($dependency.kind -cne 'R4L'){throw 'An external runtime import must resolve to an R4L.'}
     $requirements.Add($dependency.kind+'|'+$dependency.name+'|'+$dependency.target+'|'+$dependency.version+'|installed')
    }
   }
  }
  if($groupName -ceq 'platform'){
   $kernel=Join-Path $context.repositories 'Kernel/zig-out/bin/r4os.elf'
   $payloads.Add($kernel+'|/boot/r4os.elf|boot-kernel')
   $components.Add([pscustomobject]@{name='KERNEL';kind='KERNEL';version=$kernelVersion;target='/boot/r4os.elf';artifact=$kernel})
  }else{
   # Companion paths must already be understood by the running boot-recovery
   # owner. Shipping a new kernel alongside them cannot meet this requirement.
   $requirements.Add('KERNEL|KERNEL|/boot/r4os.elf|'+$kernelVersion+'|active')
   if($groupName -in @('api','video')){
    foreach($name in $profile.providers){
     $dependency=Get-GraphicsModule $name
     $requirements.Add($dependency.kind+'|'+$dependency.name+'|'+$dependency.target+'|'+$dependency.version+'|installed')
    }
   }
   $texts=[Collections.Generic.List[string]]::new()
   foreach($name in @('R4OS-LICENSE.txt','R4OS-NOTICE.txt')+$legal[$groupName]){$texts.Add((Join-Path $context.legal $name))}
   if($groupName -ceq 'core'){
    if($Vendor -ceq 'nvidia'){$texts.Add((Join-Path $context.libraries 'R4NV/ThirdParty/Nvidia/LICENSES.txt'))}
    foreach($resource in $resources){if($resource.name -match 'LICENSE'){$texts.Add($resource.source)}}
   }
   $license=Join-Path $scratch ('LICENSE-'+$groupName+'.TXT')
   $stream=[IO.File]::Create($license)
   try {
    $stream.Write([Text.Encoding]::UTF8.GetPreamble())
    foreach($file in @($texts|Sort-Object -Unique)){
     $heading=$utf8.GetBytes("`n===== $([IO.Path]::GetFileName($file)) =====`n")
     $stream.Write($heading);$stream.Write([IO.File]::ReadAllBytes($file));$stream.Write($utf8.GetBytes("`n"))
    }
   }finally{$stream.Dispose()}
   $licenseScope=if($Vendor -ceq 'amd'){'AMD/'}else{''}
   $payloads.Add($license+'|C:/R4OS/LICENSES/GFX/'+$licenseScope+$groupName.ToUpperInvariant()+'.TXT|license')
   if($groupName -ceq 'video'){
    $sources=Join-Path $scratch 'VideoSources'
    Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $context.libraries 'R4VIDEO/Tools/PackageSources.ps1'),'-OutputDirectory',$sources)
    # Short leaves permit first installation on both FAT and NTFS.
    $payloads.Add((Join-Path $sources 'R4VIDEO-SOURCE.tar.gz')+'|C:/R4OS/SOURCES/R4VIDEO/SOURCE.TGZ|source')
    $payloads.Add((Join-Path $sources 'R4VIDEO-SOURCE.json')+'|C:/R4OS/SOURCES/R4VIDEO/MANIFEST|source')
   }
  }
  $file=Join-Path $scratch ($prefix+$groupName.ToUpperInvariant()+'.R4U')
  $description=Join-Path $scratch ('DESCRIPTION-'+$groupName+'.TXT')
  [IO.File]::WriteAllText($description,"R4OS $Vendor graphics $groupName version group. Offline payloads; activation follows the contained components. Physical hardware qualification is separate from package validation.",[Text.UTF8Encoding]::new($true))
  $arguments=@('--output',$file,'--package',($prefix+$groupName.ToUpperInvariant()),'--version',$ReleaseVersion,'--release',$ReleaseVersion,'--title',("R4OS $Vendor graphics $groupName"),'--description-file',$description)
  foreach($payload in $payloads){$arguments+=@('--payload',$payload)}
  foreach($requirement in $requirements){$arguments+=@('--require',$requirement)}
  Invoke-R4Distribution $packer $arguments
  $manifest=Read-GraphicsPackageManifest $file
  foreach($component in $components){
   $expected=';kind='+$component.kind+';name='+$component.name+';target='+$component.target+';version='+$component.version+';install='
   if(@($manifest.Split("`n")|Where-Object {$_.StartsWith('COMPONENT;') -and $_.Contains($expected,[StringComparison]::Ordinal)}).Count -ne 1){throw "Stale artifact or mismatched manifest: $($component.name)"}
  }
  [IO.File]::WriteAllText(($file+'.manifest'),$manifest,$utf8)
  $total+=$payloads.Count
  $records.Add([ordered]@{group=$groupName;file=[IO.Path]::GetFileName($file);sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $file).Length;
   payloads=$payloads.Count;requirements=@($requirements);components=@($components|ForEach-Object {[ordered]@{name=$_.name;kind=$_.kind;version=$_.version;target=$_.target;sha256=(Get-FileHash -LiteralPath $_.artifact).Hash.ToLowerInvariant()}});
   resources=@($resources|ForEach-Object {[ordered]@{name=$_.name;bytes=$_.bytes;sha256=$_.sha256}})})
 }
 $batches=@(
  [ordered]@{name='platform';groups=@('platform');reboots=1},
  [ordered]@{name='preload';groups=@('preload');reboots=2},
  [ordered]@{name='graphics';groups=@('core','api','video','desktop');reboots=1}
 )
 foreach($batch in $batches){
  $count=0;foreach($record in $records){if($record.group -in $batch.groups){$count+=$record.payloads}}
  if($count -gt 32){throw 'Selected restart batch exceeds the shared32-payload capacity.'}
  $batch.payloads=$count
 }

 $receipt=[ordered]@{schema=2;release=$ReleaseVersion;vendor=$Vendor;kernel=$kernelVersion;contract_sha256=(Get-FileHash -LiteralPath (Join-Path $context.repositories 'Contract/Generated/Inventory/API.json')).Hash.ToLowerInvariant();groups=@($records);total_payloads=$total;
  install_order='Install platform and reboot first. Install preload and reboot twice to cover interrupted commit or boot recovery: Limine reads files before early replay; a normal commit replaces them before reboot. Then stage core/api/video/desktop together and commit once.';batches=$batches;
  configuration='No CONFIG, SERVICES, DISPLAY or user preferences are overwritten. Explicit driver activation belongs to the installation operator.';
  inventory='MODULES.JSON is maintained transactionally by SYSUPD; this receipt is build evidence, not an installed hardware catalog.';
  native_hardware_qualified=$false}
 $publication=Join-Path $scratch 'Published'
 [IO.Directory]::CreateDirectory($publication)|Out-Null
 foreach($record in $records){foreach($suffix in @('','.manifest')){[IO.File]::Move((Join-Path $scratch ($record.file+$suffix)),(Join-Path $publication ($record.file+$suffix)))}}
 $receipt|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $publication 'PACKAGES.json') -Encoding utf8NoBOM
 [IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
 [IO.Directory]::Move($publication,$destination)
 Write-Host "Graphics package set: $destination ($total payloads; no network or hardware access)"
}finally{if(Test-Path -LiteralPath $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}}
