# Shared PS7 policy and workflow. Native claims contain only host I/O.
Set-StrictMode -Version Latest
function Initialize-R4Usb {
 if(!('R4UsbClaim' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'UsbHost.cs')}
 . (Join-Path $PSScriptRoot 'InstallationImage.Check.ps1')
}
function Get-R4UsbNodes($Nodes) {
 foreach($node in $Nodes){$node;if($node.Contains('children')){Get-R4UsbNodes $node.children}}
}
function Convert-R4UsbLinuxTargets($Inventory) {
 foreach($disk in $Inventory.blockdevices) {
  if($disk.type -cne 'disk' -or $disk.tran -cne 'usb' -or $disk.ro){continue}
  $nodes=@(Get-R4UsbNodes @($disk));$mounts=@($nodes|ForEach-Object {$_.mountpoints}|Where-Object {$_})
  if(@($mounts|Where-Object {$_ -in @('/','/boot','/boot/efi','[SWAP]')}).Count){continue}
  [ordered]@{path=$disk.path;bytes=[long]$disk.size;sectorBytes=[int]$disk.'log-sec';model=([string]$disk.model).Trim();
   identity=(@($disk.path,$disk.'maj:min',$disk.serial,$disk.wwn,$disk.size,$disk.'log-sec') -join '|');
   volumes=@();mounts=$mounts;devices=@($nodes|ForEach-Object {$_.path});number=-1}
 }
}
function Convert-R4UsbWindowsTargets($Disks,$Partitions) {
 foreach($disk in $Disks) {
  if([string]$disk.BusType -cne 'USB' -or $disk.IsReadOnly -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline){continue}
  $parts=@($Partitions|Where-Object {$_.DiskNumber -eq $disk.Number})
  $paths=@($parts|ForEach-Object {$_.AccessPaths}|Where-Object {$_})
  [ordered]@{path=('\\.\PhysicalDrive'+$disk.Number);bytes=[long]$disk.Size;sectorBytes=[int]$disk.LogicalSectorSize;
   model=([string]$disk.FriendlyName).Trim();identity=(@($disk.Number,$disk.UniqueId,$disk.SerialNumber,$disk.Size,$disk.LogicalSectorSize) -join '|');
   volumes=@($paths|Where-Object {$_.StartsWith('\\?\Volume{')}|Sort-Object -Unique);mounts=$paths;devices=@();number=[int]$disk.Number}
 }
}
function Get-R4UsbTargets {
 if($IsLinux){
  $json=& lsblk --json --bytes --paths --output 'PATH,TYPE,TRAN,RO,SIZE,LOG-SEC,MODEL,SERIAL,WWN,MAJ:MIN,MOUNTPOINTS'
  if($LASTEXITCODE -ne 0){throw 'USB-Datentraeger konnten nicht gelesen werden.'}
  Convert-R4UsbLinuxTargets ($json|ConvertFrom-Json -AsHashtable)
 }elseif($IsWindows){Convert-R4UsbWindowsTargets @(Get-Disk) @(Get-Partition)}else{throw 'Windows oder Linux erforderlich.'}
}
function Assert-R4UsbSources($Target,[string[]]$Paths) {
 foreach($path in $Paths) {
  $resolved=[R4UsbClaim]::Canonical($path)
  if($Target.Contains('virtual') -and $Target.virtual){
   if($resolved -ceq [R4UsbClaim]::Canonical($Target.path)){throw 'Quelle und Ziel sind identisch.'};continue
  }
  if($IsLinux){
   $source=@(& findmnt --noheadings --raw --output SOURCE --target $resolved)
   if($LASTEXITCODE -ne 0 -or $source.Count -ne 1){throw "Quellmedium nicht eindeutig: $resolved"}
   $device=([string]$source[0]) -replace '\[.*\]$',''
   if($device.StartsWith('/dev/')){
    $parents=@(& lsblk --inverse --list --noheadings --paths --output PATH $device)
    if($LASTEXITCODE -ne 0){throw 'Quellgeraet konnte nicht gebunden werden.'}
    if(@($parents|Where-Object {$_.Trim() -in $Target.devices}).Count){throw "Quelle liegt auf dem zu loeschenden USB-Medium: $resolved"}
   }
  }else{
   foreach($mount in $Target.mounts){
    $prefix=([string]$mount).TrimEnd('\')+'\'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $resolved.TrimEnd('\') -ieq $prefix.TrimEnd('\')){throw "Quelle liegt auf dem USB-Ziel: $resolved"}
   }
  }
 }
}
function Get-R4UsbFingerprint($Target) {
 $file=[IO.File]::Open($Target.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{return [R4UsbClaim]::Fingerprint($file,$Target.bytes)}finally{$file.Dispose()}
}
function Expand-R4UsbRelease([string]$Package,[string]$Output) {
 $zip=[IO.Compression.ZipFile]::OpenRead($Package)
 try {
  if($zip.Entries.Count -lt 4 -or $zip.Entries.Count -gt 4096){throw 'Ungueltige Release-Dateianzahl.'}
  $entry=$zip.GetEntry('manifest.json');if(!$entry -or $entry.Length -le 0 -or $entry.Length -gt 1MB){throw 'Release-Manifest fehlt.'}
  $reader=[IO.StreamReader]::new($entry.Open(),[Text.UTF8Encoding]::new($false,$true))
  try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}
  if($manifest.schema -ne 1 -or $manifest.product -cne 'r4os' -or $manifest.layout -cne 'r4os-gpt-1' -or
    $manifest.architecture -cne 'x86_64' -or $manifest.profile -cnotin @('slim','full') -or
    $manifest.releaseVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Dieses Releaseformat ist nicht fuer den USB-Starter geeignet.'}
  $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($file in $manifest.files){
   if($expected.ContainsKey($file.path) -or $file.path -ieq 'manifest.json' -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
     $file.bytes -isnot [long] -and $file.bytes -isnot [int] -or $file.bytes -lt 0){throw 'Ungueltige Release-Dateiliste.'}
   $expected.Add($file.path,$file)
  }
  if(!$expected.ContainsKey('disk.img') -or $expected['disk.img'].bytes -ne 2048MB -or !$expected.ContainsKey('recovery.zip') -or
     $expected.Count+1 -ne $zip.Entries.Count){throw 'Unvollstaendiges Release.'}
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);[long]$expanded=0
  foreach($entry in $zip.Entries){
   $name=$entry.FullName;$expanded+=$entry.Length
   if(!$seen.Add($name) -or $name.Length -gt 255 -or $name -cmatch '[^\x20-\x7e]|[<>:"\\|?*]' -or $expanded -gt 8GB){throw 'Ungueltiger ZIP-Pfad oder Paketumfang.'}
   foreach($part in $name.Split('/')){if(!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ')){throw 'Ungueltiger ZIP-Pfad.'}}
   if($name -ceq 'manifest.json'){continue}
   if(!$expected.ContainsKey($name) -or $name -cne $expected[$name].path -or $entry.Length -ne $expected[$name].bytes){throw "Release-Inhalt stimmt nicht: $name"}
  }
  [IO.Directory]::CreateDirectory($Output)|Out-Null
  foreach($entry in $zip.Entries){
   $path=Join-Path $Output $entry.FullName;[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
   $entryStream=$entry.Open();$file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
   try{$entryStream.CopyTo($file)}finally{$file.Dispose();$entryStream.Dispose()}
   if($entry.FullName -cne 'manifest.json' -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$entry.FullName].sha256){throw "Release-SHA256 stimmt nicht: $($entry.FullName)"}
  }
  return $manifest
 }finally{$zip.Dispose()}
}
function Invoke-R4UsbWrite($Target,$Plan,[string]$Prepared,[string]$Image,[string]$Fingerprint,[scriptblock]$BeforeClaim) {
 if($Plan.schema -ne 1 -or $Plan.targetBytes -ne $Target.bytes -or $Target.sectorBytes -ne 512 -or $Target.bytes -lt $Plan.minimumBytes){throw 'USB-Geometrie stimmt nicht.'}
 $ready=[IO.File]::Open($Prepared,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $source=[IO.File]::Open($Image,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $claim=$null
 try {
  if($ready.Length -ne $Target.bytes){throw 'Vorbereitetes Image hat eine falsche Groesse.'}
  foreach($step in @($Plan.image)+@($Plan.cache)){
   if($step.source -cnotin @('prepared','image') -or $step.first -lt 0 -or $step.count -le 0 -or
      $step.first -gt $Target.bytes/512-$step.count -or ($step.source -ceq 'image' -and $step.first+$step.count -gt $source.Length/512)){throw 'Ungueltiger USB-Schreibplan.'}
  }
  if($BeforeClaim){& $BeforeClaim}
  $virtual=$Target.Contains('virtual') -and $Target.virtual
  Write-Host 'Pruefe USB-Ziel vor dem Schreiben ...'
  $claim=[R4UsbClaim]::new($Target.path,$Target.bytes,$Target.sectorBytes,$virtual,[string[]]$Target.volumes)
  if([R4UsbClaim]::Fingerprint($claim.Stream,$claim.Bytes) -cne $Fingerprint){throw 'Datentraeger wurde seit der Auswahl veraendert.'}
  foreach($phase in @('image','cache')){
   Write-Host $(if($phase -ceq 'image'){'Schreibe und pruefe R4OS-USB-Layout ...'}else{'Kopiere und pruefe das Original-ZIP auf RECOVERY ...'})
   foreach($step in $Plan[$phase]){$copySource=if($step.source -ceq 'image'){$source}else{$ready};$claim.Copy($copySource,$step.first,$step.count)}
   $claim.Flush()
   foreach($step in $Plan[$phase]){$copySource=if($step.source -ceq 'image'){$source}else{$ready};$claim.Verify($copySource,$step.first,$step.count)}
  }
  . (Join-Path $PSScriptRoot 'InstallationImage.Check.ps1')
  $result=Test-R4OSInstallationImage -Stream $claim.Stream -ImageBytes $claim.Bytes -Medium usb
  $view=[InstallationImageCheck]::new($claim.Stream,$claim.Bytes,$false,$true)
  try{$result['originalZipSha256']=[InstallationImageCheck]::Hash($view.Volumes['RECOVERY'].ReadFile('INSTALL/RELEASE.ZIP'))}finally{$view.Dispose()}
  return $result
 }finally{if($claim){$claim.Dispose()};$ready.Dispose();$source.Dispose()}
}
