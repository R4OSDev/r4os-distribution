param(
 [string]$ReleaseZip='', [string]$Target='', [string]$VirtualImage='',
 [string]$ImageCreator='', [string]$WorkRoot='', [string]$ConfirmErase=''
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
try {
 . (Join-Path $PSScriptRoot 'Tools/Usb.ps1');Initialize-R4Usb
 . (Join-Path $PSScriptRoot 'Tools/InstallationImage.Check.ps1')
 if($Target -and $VirtualImage){throw 'Nur ein USB-Ziel oder virtuelles Testimage angeben.'}
 if(!$ReleaseZip){
  $packages=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'R4OS-*-x86_64.zip' -File|Where-Object {$_.Name -notlike 'R4OS-Recovery-*'}|Sort-Object Name)
  if($packages.Count -eq 1){$ReleaseZip=$packages[0].FullName}else{
   for($i=0;$i -lt $packages.Count;$i++){Write-Host "$($i+1): $($packages[$i].Name)"}
   $choice=Read-Host 'Release-ZIP: Nummer aus der Liste oder Dateipfad'
   [int]$number=0
   if([int]::TryParse($choice,[ref]$number) -and $number -ge 1 -and $number -le $packages.Count){$ReleaseZip=$packages[$number-1].FullName}else{$ReleaseZip=$choice.Trim('"')}
  }
 }
 $ReleaseZip=[R4UsbClaim]::Canonical($ReleaseZip)
 if(!$WorkRoot){$WorkRoot=if(Test-Path (Join-Path $PSScriptRoot 'Settings.R4S')){Join-Path $PSScriptRoot '../../Temp/Usb'}else{Join-Path $PSScriptRoot 'Temp'}}
 $WorkRoot=[IO.Path]::GetFullPath($WorkRoot);[IO.Directory]::CreateDirectory($WorkRoot)|Out-Null
 $suffix=if($IsWindows){'.exe'}else{''}
 if(!$ImageCreator){
  $ImageCreator=Join-Path $PSScriptRoot "Tools/USB/$(if($IsWindows){'windows-x86_64'}else{'linux-x86_64'})/imagecreater$suffix"
  if(!(Test-Path $ImageCreator) -and (Test-Path (Join-Path $PSScriptRoot 'Settings.R4S'))){$ImageCreator=Join-Path $PSScriptRoot "../../Artifacts/Distribution/HostTools/bin/imagecreater$suffix"}
 }
 $ImageCreator=[R4UsbClaim]::Canonical($ImageCreator)
 if($IsLinux){
  $mode=[IO.File]::GetUnixFileMode($ImageCreator)
  if(($mode -band [IO.UnixFileMode]::UserExecute) -eq 0){[IO.File]::SetUnixFileMode($ImageCreator,($mode -bor [IO.UnixFileMode]::UserExecute))}
 }
 if($VirtualImage){
  $path=[R4UsbClaim]::Canonical($VirtualImage);$info=Get-Item -LiteralPath $path
  if($info.PSIsContainer -or $info.LinkType -or $path -match '^/dev/' -or $info.Extension -cne '.img'){throw 'Virtuelles Ziel muss eine vorhandene regulaere .img-Datei sein.'}
  $selected=[ordered]@{path=$path;bytes=[long]$info.Length;sectorBytes=512;model='VIRTUAL TEST IMAGE';identity="virtual|$path|$($info.Length)";volumes=@();mounts=@();devices=@();number=-1;virtual=$true}
 }else{
  $targets=@(Get-R4UsbTargets)
  if(!$targets.Count){throw 'Kein beschreibbarer USB-Datentraeger gefunden.'}
  if(!$Target){
   for($i=0;$i -lt $targets.Count;$i++){Write-Host "$($i+1): $($targets[$i].path) | $($targets[$i].model) | $([Math]::Round($targets[$i].bytes/1GB,2)) GB | $($targets[$i].identity)"}
   $choice=Read-Host 'USB-Zieldatentraeger (Nummer)';[int]$number=0
   if(![int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $targets.Count){throw 'Keine gueltige Auswahl.'};$Target=$targets[$number-1].path
  }
  $selectedTargets=@($targets|Where-Object {$_.path -ceq $Target})
  if($selectedTargets.Count -ne 1){throw 'Ziel ist kein eindeutig erkannter beschreibbarer USB-Datentraeger.'};$selected=$selectedTargets[0]
 }
 if($selected.sectorBytes -ne 512 -or $selected.bytes%512 -ne 0 -or $selected.bytes -lt (3411968L+32769+33)*512){throw 'USB-Geometrie ungeeignet: 512-Byte-Sektoren und mindestens 1683 MB erforderlich.'}
 $paths=@($ReleaseZip,$PSScriptRoot,$ImageCreator,$WorkRoot)
 Assert-R4UsbSources $selected $paths
 $fingerprint=Get-R4UsbFingerprint $selected
 Write-Host "Ziel: $($selected.path) | $($selected.model) | $($selected.bytes) Bytes"
 Write-Host "Identitaet: $($selected.identity) | Inhalt: $fingerprint"
 $confirmation='ERASE '+$selected.path
 if(!$ConfirmErase){$ConfirmErase=Read-Host "Alle Partitionen dieses Ziels werden ersetzt. Zur Bestaetigung exakt '$confirmation' eingeben"}
 if($ConfirmErase -cne $confirmation){throw 'Abgebrochen: keine passende Loeschbestaetigung.'}
 $work=Join-Path $WorkRoot ([Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($work)|Out-Null
 Write-Host 'Pruefe Original-ZIP und bereite USB-Layout auf dem Host vor ...'
 $original=Join-Path $work 'RELEASE.ZIP';Copy-Item -LiteralPath $ReleaseZip -Destination $original
 $zipHash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant()
 if($zipHash -cne (Get-FileHash -LiteralPath $ReleaseZip -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Original-ZIP wurde waehrend der Aufnahme veraendert.'}
 $stage=Join-Path $work 'release';$manifest=Expand-R4UsbRelease $original $stage
 $source=Join-Path $stage 'disk.img';$before=Test-R4OSInstallationImage -Image $source -Medium local
 if($before.installation.releaseVersion -cne $manifest.releaseVersion -or $before.installation.kernelVersion -cne $manifest.kernelVersion -or
    $before.recoveryVersion -cne $manifest.recovery.version){throw 'Image und Release-Manifest passen nicht zusammen.'}
 $view=[InstallationImageCheck]::new($source)
 try{if(@($view.Volumes['RECOVERY'].Paths()|Where-Object {$_ -match '^(?i:INSTALL/)'}).Count){throw 'Release-Image enthaelt bereits einen Installationscache.'}}finally{$view.Dispose()}
 $prepared=Join-Path $work 'prepared.img';$planFile=Join-Path $work 'write-plan.json'
 & $ImageCreator prepare-usb --image $source --zip $original --output $prepared --plan $planFile --sectors ([string]([long]($selected.bytes/512)))
 if($LASTEXITCODE -ne 0){throw 'USB-Vorbereitung fehlgeschlagen; Ziel wurde nicht beschrieben.'}
 $plan=Get-Content -Raw -LiteralPath $planFile|ConvertFrom-Json -AsHashtable
 $expected=Test-R4OSInstallationImage -Image $prepared -Medium usb
 if($expected.installation.diskGuid -ceq $before.installation.diskGuid -or $expected.installation.installationId -ceq $before.installation.installationId){throw 'USB-Identitaeten wurden nicht erneuert.'}
 foreach($role in @('BIOSBOOT','BOOT','SYSTEM','RECOVERY','DATA')){if($expected.installation.partitions[$role].partitionGuid -ceq $before.installation.partitions[$role].partitionGuid){throw 'Partitionsidentitaet wurde nicht erneuert.'}}
 $revalidate={
  Assert-R4UsbSources $selected ($paths+@($work))
  if(!$VirtualImage){
   $current=@(Get-R4UsbTargets|Where-Object {$_.path -ceq $selected.path})
   if($current.Count -ne 1 -or $current[0].identity -cne $selected.identity){throw 'USB-Datentraeger wurde seit der Auswahl ausgetauscht.'}
   $selected.volumes=$current[0].volumes
   if($IsLinux){foreach($mount in @($current[0].mounts|Sort-Object Length -Descending -Unique)){& umount -- $mount;if($LASTEXITCODE -ne 0){throw "USB-Mount ist in Benutzung: $mount"}}}
  }
 }
 $result=Invoke-R4UsbWrite $selected $plan $prepared $source $fingerprint $revalidate
 if($result.originalZipSha256 -cne $zipHash){throw 'Abschliessender Original-ZIP-Hash stimmt nicht.'}
 $record=[ordered]@{schema=1;target=$selected.path;identity=$selected.identity;bytes=$selected.bytes;sourceZipSha256=$zipHash;result='PASS';structure=$result}
 [IO.File]::WriteAllText((Join-Path $work 'result.json'),(($record|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
 Write-Host "R4OS-USB fertig: Recovery startet standardmaessig. Original-ZIP SHA256 $zipHash"
 Write-Host "Nachweis: $(Join-Path $work 'result.json')"
 exit 0
}catch{Write-Error $_ -ErrorAction Continue;exit 1}
