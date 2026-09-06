param([string]$RecoveryCandidate='', [string]$Qemu='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Tools/Distribution.ps1')
. (Join-Path $root 'Tools/InstallationImage.Check.ps1')
. (Join-Path $root 'Tools/Qemu-Media.ps1')
. (Join-Path $root 'Tools/RecoveryPin.ps1')
$context=Get-R4DistributionContext $root
if(!$Qemu){$Qemu=$context.qemu}
$work=Join-Path $context.output ('MediaAcceptance/'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
function Reject([scriptblock]$Action,[string]$Label){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};if(!$failed){throw "Unexpected success: $Label"}}
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$process=$null;$savedCandidate=$env:R4OS_RECOVERY_CANDIDATE
try {
 $env:R4OS_RECOVERY_CANDIDATE=$null
 $pinRoot=Join-Path $work 'pin';[IO.Directory]::CreateDirectory($pinRoot)|Out-Null
 Json (Join-Path $pinRoot 'RecoveryPin.json') @{schema=1;product='r4os-recovery';architecture='x86_64';status='unconfigured'}
 Reject {Resolve-R4RecoveryPackage $pinRoot $pinRoot} 'unconfigured production pin'
 if(!$RecoveryCandidate){throw 'Pass the exact technical Recovery ZIP used for these four images.'}
 $candidate=Resolve-R4RecoveryPackage $root $pinRoot $RecoveryCandidate
 if(!$candidate.technical){throw 'Candidate lost its technical provenance.'}
 $archive=[IO.Compression.ZipFile]::OpenRead($RecoveryCandidate)
 try{$reader=[IO.StreamReader]::new($archive.GetEntry('manifest.json').Open());try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}}finally{$archive.Dispose()}
 $cached=Join-Path $pinRoot "R4OS-Recovery-$($manifest.recoveryVersion)-x86_64.zip"
 Copy-Item -LiteralPath $RecoveryCandidate -Destination $cached
 $pin=@{schema=1;product='r4os-recovery';architecture='x86_64';status='published';version=$manifest.recoveryVersion;releaseId=1;sha256=$candidate.sha256}
 Json (Join-Path $pinRoot 'RecoveryPin.json') $pin
 $offline=Resolve-R4RecoveryPackage $pinRoot $pinRoot
 if($offline.technical -or $offline.sha256 -cne $candidate.sha256){throw 'Cached pin failed.'}
 $pin.sha256='0'*64;Json (Join-Path $pinRoot 'RecoveryPin.json') $pin
 Reject {Resolve-R4RecoveryPackage $pinRoot $pinRoot} 'wrong cached hash'

 # Tiny disposable source tests lifecycle and actual QEMU image locks. It
 # is never booted; -S keeps its four CPUs paused throughout the lock proof.
 $source=Join-Path $work 'source';[IO.Directory]::CreateDirectory($source)|Out-Null
 $disk=Join-Path $source 'disk.img';[IO.File]::WriteAllBytes($disk,[byte[]]::new(1MB))
 Json (Join-Path $source 'image.json') @{sha256=Digest $disk}
 $first=New-R4QemuMedia $source Fresh 'probe';$persistent=New-R4QemuMedia $source Persistent
 $persistentDisk=Join-Path $persistent 'disk.img'
 $f=[IO.File]::OpenWrite($persistentDisk);try{$f.WriteByte(73)}finally{$f.Dispose()}
 $changed=Digest $persistentDisk
 if((New-R4QemuMedia $source Persistent) -cne $persistent -or (Digest $persistentDisk) -cne $changed){throw 'Persistent state was lost.'}
 $freshDisk=Join-Path $first 'disk.img';[IO.File]::WriteAllBytes($freshDisk,[byte[]]@(1,2,3))
 $null=New-R4QemuMedia $source Fresh 'probe'
 if((Digest $freshDisk) -cne (Digest $disk)){throw 'Fresh run inherited data.'}
 $start=[Diagnostics.ProcessStartInfo]::new($Qemu);$start.UseShellExecute=$false;$start.RedirectStandardError=$true
 foreach($arg in @('-machine','q35,accel=tcg','-smp','4','-m','128','-S','-display','none','-monitor','none','-serial','none','-nic','none','-drive',"if=none,format=raw,file=$freshDisk")){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start);$stderr=$process.StandardError.ReadToEndAsync()
 Start-Sleep -Milliseconds 1000
 if($process.HasExited){throw "QEMU lock fixture failed: $($stderr.GetAwaiter().GetResult())"}
 $before=Digest $freshDisk
 Reject {New-R4QemuMedia $source Fresh 'probe'} 'active QEMU image'
 if((Digest $freshDisk) -cne $before){throw 'Active guest image changed.'}
 $process.Kill($true);$process.WaitForExit();$process.Dispose();$process=$null
 $f=[IO.File]::OpenWrite($disk);try{$f.WriteByte(91)}finally{$f.Dispose()}
 Reject {New-R4QemuMedia $source Fresh 'probe'} 'modified source seal'
 Json (Join-Path $source 'image.json') @{sha256=Digest $disk}
 if((New-R4QemuMedia $source Persistent) -ceq $persistent -or (Digest $persistentDisk) -cne $changed){throw 'Source generations were mixed.'}

 $profiles=@()
 foreach($name in @('Slim','Full','Test','Benchmark')){
  Test-R4DistributionImage $context $name
  $directory=Join-Path $context.output "Profiles/$name"
  $record=Get-Content -Raw -LiteralPath (Join-Path $directory 'image.json')|ConvertFrom-Json -AsHashtable
  if(!$record.technical -or $record.recoveryPackageSha256 -cne $candidate.sha256 -or $record.sha256 -cne (Digest (Join-Path $directory 'disk.img'))){throw "Image pin or seal mismatch: $name"}
  $profiles+=@{profile=$name;sha256=$record.sha256;recovery=$record.recoveryVersion}
 }
 # The same reset-data entry used by releases and benchmarks changes only
 # DATA; its complete byte range is excluded from the preservation hash.
 $image=Join-Path $work 'fresh.img';Copy-Item -LiteralPath (Join-Path $context.output 'Profiles/Benchmark/disk.img') -Destination $image
 $checked=Test-R4OSInstallationImage -Image $image
 $data=$checked.installation.partitions.DATA
 Add-Type -TypeDefinition @'
using System; using System.IO; using System.Security.Cryptography;
public static class R4MediaHash { public static string Outside(string path,long first,long length) {
 using(var f=File.OpenRead(path)) using(var h=IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
 byte[] b=new byte[1048576]; foreach(var range in new[]{new long[]{0,first},new long[]{first+length,f.Length-first-length}}) {
 f.Position=range[0];long left=range[1];while(left>0){int n=f.Read(b,0,(int)Math.Min(b.Length,left));if(n==0)throw new EndOfStreamException();h.AppendData(b,0,n);left-=n;} }
 return Convert.ToHexString(h.GetHashAndReset()); } } }
'@
 $outside=[R4MediaHash]::Outside($image,$data.firstLba*512,$data.sectorCount*512)
 $request=Join-Path $work 'BENCHMARK.BAT';[IO.File]::WriteAllText($request,"ECHO fixture`nPOWEROFF`n")
 $creator=Join-Path $context.prefix "bin/imagecreater$($context.suffix)"
 Invoke-R4Distribution $creator @('reset-data','--image',$image,'--add',($request+'|/BENCHMARK.BAT'))
 Invoke-R4Distribution $creator @('reset-data','--image',$image)
 if([R4MediaHash]::Outside($image,$data.firstLba*512,$data.sectorCount*512) -cne $outside){throw 'Fresh DATA modified another partition or GPT.'}
 Invoke-R4Distribution (Join-Path $context.prefix "bin/ntfsverify$($context.suffix)") @($image)
 Json (Join-Path (Split-Path $work -Parent) 'media-results.json') @{schema=1;result='PASS';cpus=4;booted=$false;host=$(if($IsLinux){'Linux'}else{'Windows'});profiles=$profiles;runnerSha256=Digest $PSCommandPath;checks=@('pin-required','cached-pin-offline','candidate-explicit','cached-hash-reject','fresh-state','persistent-generation','active-qemu-lock','source-seal','four-profile-structure','fresh-data-isolation')}
 Write-Host 'Distribution media acceptance PASS (no benchmark executed).'
} finally {
 if($process){if(!$process.HasExited){$process.Kill($true)};$process.WaitForExit();$process.Dispose()}
 $env:R4OS_RECOVERY_CANDIDATE=$savedCandidate
}
