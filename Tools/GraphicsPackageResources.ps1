# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
# Bounded host reads of the existing R4M0 resource and R4U2 manifest contracts.
function Read-GraphicsBytes($Stream,[long]$Offset,[int]$Count) {
 if($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Stream.Length -or $Count -gt $Stream.Length-$Offset){throw 'Container range is outside the file.'}
 $Stream.Position=$Offset
 $bytes=[byte[]]::new($Count);$done=0
 while($done -lt $Count){$read=$Stream.Read($bytes,$done,$Count-$done);if(!$read){throw 'Truncated container.'};$done+=$read}
 return ,$bytes
}
function Get-GraphicsRangeHash($Stream,[long]$Offset,[long]$Count) {
 if($Offset -lt 0 -or $Count -le 0 -or $Offset -gt $Stream.Length -or $Count -gt $Stream.Length-$Offset){throw 'Resource range is outside the file.'}
 $Stream.Position=$Offset
 $buffer=[byte[]]::new(65536)
 $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
 try {
  while($Count -gt 0){$read=$Stream.Read($buffer,0,[int][Math]::Min($Count,$buffer.Length));if(!$read){throw 'Truncated resource.'};$hash.AppendData($buffer,0,$read);$Count-=$read}
  return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
 }finally{$hash.Dispose()}
}
function Read-GraphicsPackageManifest([string]$Path) {
 $stream=[IO.File]::OpenRead($Path)
 try {
  $header=Read-GraphicsBytes $stream 0 64
  if([Text.Encoding]::ASCII.GetString($header,0,4) -cne 'R4U2' -or [BitConverter]::ToUInt16($header,4) -ne 2 -or [BitConverter]::ToUInt16($header,6) -ne 64){throw 'Invalid R4U2 header.'}
  $length=[BitConverter]::ToUInt64($header,8)
  if($length -eq 0 -or $length -gt 32768){throw 'Invalid R4U2 manifest size.'}
  return [Text.UTF8Encoding]::new($false,$true).GetString((Read-GraphicsBytes $stream 64 $length))
 }finally{$stream.Dispose()}
}
function Test-GraphicsPreloadResources([string]$Path,$Modules) {
 $stream=[IO.File]::OpenRead($Path)
 try {
  $header=Read-GraphicsBytes $stream 0 64
  if([Text.Encoding]::ASCII.GetString($header,0,4) -cne 'R4I0' -or [BitConverter]::ToUInt16($header,4) -ne 1 -or [BitConverter]::ToUInt16($header,6) -ne 64){throw 'Invalid boot preload header.'}
  $count=[BitConverter]::ToUInt32($header,8);$table=[BitConverter]::ToUInt32($header,12);$data=[BitConverter]::ToUInt32($header,16)
  if($count -ne $Modules.Count -or $count -gt 32 -or $table -lt 64 -or $table+128*$count -gt $data -or [BitConverter]::ToUInt32($header,20) -ne $stream.Length){throw 'Preload directory differs from the versioned component set.'}
  $seen=@{}
  for($i=0;$i -lt $count;$i++){
   $entry=Read-GraphicsBytes $stream ($table+128*$i) 128
   $nameLength=[BitConverter]::ToUInt16($entry,4)
   if($nameLength -lt 1 -or $nameLength -gt 32){throw 'Invalid preload name.'}
   $name=[Text.Encoding]::ASCII.GetString($entry,8,$nameLength)
   $module=@($Modules|Where-Object {($_.name+'.'+$_.kind) -ceq $name})
   if($module.Count -ne 1 -or $seen.ContainsKey($name)){throw 'Preload identity is missing/duplicated.'};$seen[$name]=$true
   $kind=[BitConverter]::ToUInt16($entry,0)
   if(($module[0].kind -ceq 'R4P' -and $kind -ne 2) -or ($module[0].kind -ceq 'R4D' -and $kind -ne 3)){throw 'Preload component kind differs.'}
   $offset=[BitConverter]::ToUInt32($entry,88);$bytes=[BitConverter]::ToUInt32($entry,92)
   if($offset -lt $data -or $bytes -ne (Get-Item $module[0].artifact).Length){throw 'Preload component range differs.'}
   $digest=Get-GraphicsRangeHash $stream $offset $bytes
   if($digest -cne (Get-FileHash $module[0].artifact).Hash.ToLowerInvariant()){throw 'Preload bytes differ from the separately versioned module.'}
   [pscustomobject]@{name=$name;source=$module[0].artifact;bytes=$bytes;sha256=$digest}
  }
 }finally{$stream.Dispose()}
}
function Test-GraphicsPackageResources($Module) {
 $expected=@{}
 $owner=Split-Path $Module.manifest -Parent
 foreach($line in $Module.lines){
  if(!$line.StartsWith('RESOURCE=',[StringComparison]::Ordinal)){continue}
  $value=$line.Substring(9);$separator=$value.IndexOf(':')
  if($separator -le 0){throw 'Invalid resource declaration.'}
  $name=$value.Substring(0,$separator)
  if($expected.ContainsKey($name)){throw 'Duplicate resource declaration.'}
  $expected[$name]=[IO.Path]::GetFullPath((Join-Path $owner $value.Substring($separator+1)))
 }
 $lockName=switch -CaseSensitive ($Module.name){'NVIDIA' {'NVFW-LOCK.json'} 'AMDGPU' {'AMD-FIRMWARE-LOCK.json'} default {throw 'Unknown firmware owner.'}}
 if(!$expected.ContainsKey($lockName)){throw "Firmware lock is missing: $lockName"}
 $pin=Get-Content -Raw -LiteralPath $expected[$lockName]|ConvertFrom-Json -AsHashtable
 if($pin.schema -ne 1){throw 'Unknown graphics firmware lock schema.'}
 $firmwareVersion=if($Module.name -ceq 'NVIDIA'){$pin.rm_version}else{
  if($pin.revision -cnotmatch '^[0-9a-f]{40}$' -or $pin.firmware.Count -ne 13 -or $pin.metadata.Count -ne 2){throw 'Invalid AMD firmware profile.'}
  $revisionMetadata=@($Module.lines | Where-Object {$_.StartsWith('META=firmware.revision=',[StringComparison]::Ordinal)})
  if($revisionMetadata.Count -ne 1 -or $revisionMetadata[0] -cne ('META=firmware.revision='+$pin.revision)){throw 'AMD firmware revision differs from its lock.'}
  'linux-firmware-'+$pin.revision.Substring(0,12)
 }
 $versions=@($Module.lines | Where-Object { $_.StartsWith('META=firmware.version=',[StringComparison]::Ordinal) })
 if($versions.Count -ne 1 -or $versions[0] -cne ('META=firmware.version='+$firmwareVersion)){throw 'Firmware version metadata differs from the package lock.'}
 $pinned=@{}
 function Add-PinnedResources($Node){
  if($Node -is [Collections.IDictionary]){
   if($Node.Contains('resource') -and $Node.Contains('sha256') -and $Node.Contains('bytes')){
    $name=[string]$Node.resource
    if($pinned.ContainsKey($name) -and ($pinned[$name].sha256 -cne $Node.sha256 -or $pinned[$name].bytes -ne $Node.bytes)){throw "Conflicting firmware pins: $name"}
    $pinned[$name]=$Node
   }
   foreach($value in $Node.Values){Add-PinnedResources $value}
  }elseif($Node -is [array]){foreach($value in $Node){Add-PinnedResources $value}}
 }
 Add-PinnedResources $pin
 foreach($firmware in $pin.firmware){if(!$expected.ContainsKey($firmware.resource)){throw 'A mandatory graphics firmware resource is absent.'}}
 if($Module.name -ceq 'AMDGPU'){
  foreach($entry in @($pin.firmware)+@($pin.metadata)){
   if(!$expected.ContainsKey($entry.resource) -or !$pinned.ContainsKey($entry.resource)){throw 'AMD firmware/legal pin is missing.'}
  }
  if($pinned.Count -ne 15 -or $expected.Count -ne 16){throw 'AMD firmware/legal resource set differs from the exact lock.'}
 }
 $stream=[IO.File]::OpenRead($Module.artifact)
 try {
  $header=Read-GraphicsBytes $stream 0 64
  if([Text.Encoding]::ASCII.GetString($header,0,4) -cne 'R4M0' -or [BitConverter]::ToUInt16($header,4) -ne 1){throw 'Invalid R4M0 resource container.'}
  $metadataSize=[BitConverter]::ToUInt32($header,60)
  if($metadataSize -eq 0 -or $metadataSize -gt 2048){throw 'Version metadata cannot be retained by the loader.'}
  $metadata=[Text.UTF8Encoding]::new($false,$true).GetString((Read-GraphicsBytes $stream ([BitConverter]::ToUInt32($header,56)) $metadataSize))
  $firmwareVersions=@($metadata.Split([char]0) | Where-Object { $_.StartsWith('firmware.version=',[StringComparison]::Ordinal) })
  if($firmwareVersions.Count -ne 1 -or $firmwareVersions[0] -cne ('firmware.version='+$firmwareVersion)){throw 'Loaded-container firmware metadata differs from the verified bundle.'}
  if($Module.name -ceq 'AMDGPU' -and @($metadata.Split([char]0) | Where-Object {$_ -ceq ('firmware.revision='+$pin.revision)}).Count -ne 1){throw 'Embedded AMD firmware revision differs.'}
  $sectionOffset=[BitConverter]::ToUInt32($header,16);$sectionCount=[BitConverter]::ToUInt32($header,20)
  if($sectionCount -eq 0 -or $sectionCount -gt 64){throw 'Invalid R4M0 section count.'}
  $resourceOffset=-1L;$resourceSize=0L
  for($index=0;$index -lt $sectionCount;$index++){
   $section=Read-GraphicsBytes $stream ([long]$sectionOffset+$index*32) 32
   if([Text.Encoding]::ASCII.GetString($section,0,8).TrimEnd([char]0) -cne '.rsrc'){continue}
   if($resourceOffset -ge 0 -or [BitConverter]::ToUInt32($section,8) -ne 0){throw 'Invalid or duplicate resource section.'}
   $resourceOffset=[long][BitConverter]::ToUInt32($section,12);$resourceSize=[long][BitConverter]::ToUInt32($section,16)
   if($resourceSize -lt 4 -or $resourceOffset -gt $stream.Length-$resourceSize){throw 'Invalid resource section range.'}
  }
  if($resourceOffset -lt 0){throw 'Missing resource section.'}
  $count=[BitConverter]::ToUInt32((Read-GraphicsBytes $stream $resourceOffset 4),0)
  if($count -gt 64 -or 4+16*$count -gt $resourceSize){throw 'Invalid resource directory.'}
  $seen=@{}
  for($index=0;$index -lt $count;$index++){
   $entry=Read-GraphicsBytes $stream ($resourceOffset+4+16*$index) 16
   if([BitConverter]::ToUInt16($entry,0) -ne 3){continue}
   $nameOffset=[long][BitConverter]::ToUInt32($entry,4)
   $dataOffset=[long][BitConverter]::ToUInt32($entry,8);$dataSize=[long][BitConverter]::ToUInt32($entry,12)
   if($nameOffset -lt 4+16*$count -or $nameOffset -ge $resourceSize -or $dataOffset -lt 4+16*$count -or $dataSize -le 0 -or $dataOffset -gt $resourceSize-$dataSize){throw 'Invalid named resource range.'}
   $nameBytes=Read-GraphicsBytes $stream ($resourceOffset+$nameOffset) ([int][Math]::Min(64,$resourceSize-$nameOffset))
   $end=[Array]::IndexOf($nameBytes,[byte]0)
   if($end -le 0){throw 'Unterminated resource name.'}
   $name=[Text.Encoding]::ASCII.GetString($nameBytes,0,$end)
   if($seen.ContainsKey($name) -or !$expected.ContainsKey($name)){throw "Unexpected embedded resource: $name"}
   $seen[$name]=$true
   $source=Get-Item -LiteralPath $expected[$name]
   $digest=Get-GraphicsRangeHash $stream ($resourceOffset+$dataOffset) $dataSize
   if($source.Length -ne $dataSize -or (Get-FileHash -LiteralPath $source.FullName).Hash.ToLowerInvariant() -cne $digest){throw "Embedded resource differs from current manifest source: $name"}
   if($pinned.ContainsKey($name) -and ($pinned[$name].sha256 -cne $digest -or $pinned[$name].bytes -ne $dataSize)){throw "Embedded firmware differs from its pin: $name"}
   [pscustomobject]@{name=$name;source=$source.FullName;bytes=$dataSize;sha256=$digest}
  }
  if($seen.Count -ne $expected.Count){throw 'Not every declared resource is embedded.'}
 }finally{$stream.Dispose()}
}
