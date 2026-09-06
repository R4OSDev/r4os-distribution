param([Parameter(Mandatory)][string]$ReleaseZip,[switch]$SkipBoot,[switch]$PackagedStarter,[string]$Zig='', [string]$Qemu='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent;$workspace=[IO.Path]::GetFullPath((Join-Path $root '../..'))
$output=Join-Path $workspace 'Artifacts/Distribution/UsbAcceptance';[IO.Directory]::CreateDirectory($output)|Out-Null
$suffix=if($IsWindows){'.exe'}else{''};if(!$Zig){$Zig=Join-Path $workspace "DevKit/Toolchains/Zig/zig$suffix"};if(!$Qemu){$Qemu=Join-Path $workspace "DevKit/Emulation/QEMU/qemu-system-x86_64$suffix"}
. (Join-Path $root 'Tools/Usb.ps1');Initialize-R4Usb
. (Join-Path $root 'Tools/UsbPackage.ps1')
. (Join-Path $root 'Tools/InstallationImage.Check.ps1')
$utf8=[Text.UTF8Encoding]::new($false)
function Require([bool]$Condition,[string]$Why){if(!$Condition){throw $Why}}
function Reject([scriptblock]$Operation,[string]$Why){$failed=$false;try{& $Operation|Out-Null}catch{$failed=$true};Require $failed $Why}
function Blank([string]$Path,[long]$Bytes){$file=[IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite);try{$file.SetLength($Bytes);$file.Write([Text.Encoding]::ASCII.GetBytes('OLD USB CONTENT'));$file.Flush($true)}finally{$file.Dispose()}}
function Virtual([string]$Path){return [ordered]@{path=$Path;bytes=([IO.FileInfo]$Path).Length;sectorBytes=512;identity='test';model='virtual';virtual=$true;volumes=@();mounts=@();devices=@();number=-1}}
function Port{$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();$p=$l.LocalEndpoint.Port;$l.Stop();return $p}
$linux=@{blockdevices=@(
 @{path='/dev/sda';type='disk';tran='sata';ro=$false;size=4GB;'log-sec'=512;model='System';serial='A';wwn='';'maj:min'='8:0';mountpoints=@('/')},
 @{path='/dev/sdb';type='disk';tran='usb';ro=$false;size=4GB;'log-sec'=512;model='Stick';serial='B';wwn='';'maj:min'='8:16';mountpoints=@($null);children=@(@{path='/dev/sdb1';mountpoints=@('/media/USB')})},
 @{path='/dev/sdc';type='disk';tran='usb';ro=$false;size=4GB;'log-sec'=512;model='Live host';serial='C';wwn='';'maj:min'='8:32';mountpoints=@('/boot')},
 @{path='/dev/sdd';type='disk';tran='usb';ro=$true;size=4GB;'log-sec'=512;model='Read only';serial='D';wwn='';'maj:min'='8:48';mountpoints=@($null)}
)}
$items=@(Convert-R4UsbLinuxTargets $linux);Require ($items.Count -eq 1 -and $items[0].path -ceq '/dev/sdb' -and $items[0].devices.Count -eq 2) 'Linux selection failed.'
$windows=@(@{Number=0;BusType='NVMe';IsReadOnly=$false;IsBoot=$true;IsSystem=$true;IsOffline=$false;Size=4GB;LogicalSectorSize=512;FriendlyName='Host';UniqueId='A';SerialNumber='A'},
 @{Number=2;BusType='USB';IsReadOnly=$false;IsBoot=$false;IsSystem=$false;IsOffline=$false;Size=4GB;LogicalSectorSize=512;FriendlyName='Stick';UniqueId='B';SerialNumber='B'})
$parts=@(@{DiskNumber=2;AccessPaths=@('E:\','\\?\Volume{11111111-1111-1111-1111-111111111111}\')})
$items=@(Convert-R4UsbWindowsTargets $windows $parts);Require ($items.Count -eq 1 -and $items[0].path -ceq '\\.\PhysicalDrive2' -and $items[0].volumes.Count -eq 1) 'Windows selection failed.'
$bundle=Join-Path $output $(if($PackagedStarter){'Packaged USB Starter'}else{'Standalone USB Starter'})
if($PackagedStarter){
 if(Test-Path -LiteralPath $bundle){Remove-Item -LiteralPath $bundle -Recurse -Force}
 $null=Expand-R4UsbRelease $ReleaseZip $bundle
 foreach($relative in @('CreateUSB.ps1','CreateUSB.bat','CreateUSB.sh','Tools/USB/linux-x86_64/imagecreater','Tools/USB/windows-x86_64/imagecreater.exe')){
  Require (Test-Path -LiteralPath (Join-Path $bundle $relative) -PathType Leaf) "Packaged USB input missing: $relative"
 }
}else{$null=New-R4UsbStarterBundle -Root $root -Zig $Zig -Sdk (Join-Path $workspace 'Repositories/SDK') -Destination $bundle}
$starter=if($PackagedStarter -and $IsLinux){'sh'}else{'pwsh'}
[string[]]$starterArguments=@(if($PackagedStarter -and $IsLinux){Join-Path $bundle 'CreateUSB.sh'}else{'-NoProfile';'-File';Join-Path $bundle 'CreateUSB.ps1'})
if($IsLinux){[IO.File]::SetUnixFileMode((Join-Path $bundle 'Tools/USB/linux-x86_64/imagecreater'),[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)}
$image=Join-Path $output 'stick.img';Blank $image (3GB+13*512)
$snapshot=Get-R4UsbFingerprint (Virtual $image)
# Bad confirmation uses the complete public entry point and must not mutate.
& $starter @starterArguments -ReleaseZip $ReleaseZip -VirtualImage $image -WorkRoot (Join-Path $output 'work') -ConfirmErase WRONG
Require ($LASTEXITCODE -eq 1) "Bad confirmation returned unexpected exit code $LASTEXITCODE."
Require ((Get-R4UsbFingerprint (Virtual $image)) -ceq $snapshot) 'Bad confirmation changed target.'
$watch=[Diagnostics.Stopwatch]::StartNew()
& $starter @starterArguments -ReleaseZip $ReleaseZip -VirtualImage $image -WorkRoot (Join-Path $output 'work') -ConfirmErase ('ERASE '+$image)
Require ($LASTEXITCODE -eq 0) 'Standalone USB creation failed.'
$report=Get-ChildItem -LiteralPath (Join-Path $output 'work') -Filter result.json -File -Recurse|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
$created=Get-Content -Raw -LiteralPath $report.FullName|ConvertFrom-Json -AsHashtable
$work=$report.DirectoryName;$plan=Get-Content -Raw -LiteralPath (Join-Path $work 'write-plan.json')|ConvertFrom-Json -AsHashtable
$prepared=Join-Path $work 'prepared.img';$source=Join-Path $work 'release/disk.img';$target=Virtual $image
Require ($created.bytes -eq 3GB+13*512 -and $created.structure.installation.partitions.DATA.sectorCount -eq $target.bytes/512-33-3411968) 'Real DATA rest differs.'
Require ($created.sourceZipSha256 -ceq (Get-FileHash -LiteralPath $ReleaseZip -Algorithm SHA256).Hash.ToLowerInvariant()) 'Original ZIP differs.'
$after=Get-R4UsbFingerprint $target
Reject {Invoke-R4UsbWrite $target $plan $prepared $source ('0'*64) $null} 'Stale target accepted.'
$invalid=Virtual $image;$invalid.sectorBytes=4096
Reject {Invoke-R4UsbWrite $invalid $plan $prepared $source $after $null} '4K geometry accepted.'
Reject {Assert-R4UsbSources $target @($image)} 'Source on virtual target accepted.'
$held=[R4UsbClaim]::new($image,$target.bytes,512,$true,[string[]]@())
try{Reject {Invoke-R4UsbWrite $target $plan $prepared $source $after $null} 'Busy target accepted.'}finally{$held.Dispose()}
Require ((Get-R4UsbFingerprint $target) -ceq $after) 'Preflight rejection changed target.'
# Inspect the complete written image through raw-device read constraints.
# This catches partial final-file reads that ordinary host files accept.
Add-Type -Path (Join-Path $PSScriptRoot 'UsbSectorReadStream.cs')
$sectorStream=[UsbSectorReadStream]::new($image)
try {
 $sectorCheck=Test-R4OSInstallationImage -Stream $sectorStream -ImageBytes $target.bytes -Medium usb
 Require ($sectorCheck.installation.diskGuid -ceq $created.structure.installation.diskGuid) 'Sector-read installation differs.'
 $sectorView=[InstallationImageCheck]::new($sectorStream,$target.bytes,$false,$true)
 try {$sectorZipHash=[InstallationImageCheck]::Hash($sectorView.Volumes['RECOVERY'].ReadFile('INSTALL/RELEASE.ZIP'))}finally{$sectorView.Dispose()}
 Require ($sectorZipHash -ceq $created.sourceZipSha256 -and $sectorStream.FinalSectorReads -gt 0) 'Sector-read ZIP or final device sector differs.'
 $rawReadContract=[ordered]@{result='PASS';sectorBytes=512;readCalls=$sectorStream.ReadCalls;readBytes=$sectorStream.ReadBytes;finalSectorReads=$sectorStream.FinalSectorReads;originalZipSha256=$sectorZipHash}
}finally{$sectorStream.Dispose()}
# Minimum geometry is prepared and read-only checked through the same owner.
$minimum=Join-Path $output 'minimum.img';if(Test-Path $minimum){Remove-Item -LiteralPath $minimum -Force}
$creator=Join-Path $bundle "Tools/USB/$(if($IsWindows){'windows-x86_64'}else{'linux-x86_64'})/imagecreater$suffix"
& $creator prepare-usb --image $source --zip (Join-Path $work 'RELEASE.ZIP') --output $minimum --plan (Join-Path $output 'minimum-plan.json') --sectors ([string]([long]($plan.minimumBytes/512)))
Require ($LASTEXITCODE -eq 0) 'Minimum DATA geometry could not be formatted.'
$minimumCheck=Test-R4OSInstallationImage -Image $minimum -Medium usb
Require ($minimumCheck.installation.partitions.DATA.sectorCount -eq 32769) 'Minimum DATA is not 16 MB plus one sector.'
& $creator prepare-usb --image $source --zip (Join-Path $work 'RELEASE.ZIP') --output (Join-Path $output 'too-small.img') --plan (Join-Path $output 'too-small.json') --sectors ([string]([long]($plan.minimumBytes/512-1)))
Require ($LASTEXITCODE -ne 0 -and !(Test-Path (Join-Path $output 'too-small.img'))) 'Undersized geometry created output.'
$runs=@(@{case='HostWriteAndGuards';result='PASS';seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)})
Write-Host 'PASS USB host: both selections, standalone writer, exact geometry/ZIP, stale/claimed/4K/source guards, minimum DATA.'
if(!$SkipBoot){
 $recovery=Join-Path $workspace 'Repositories/Recovery';. (Join-Path $recovery 'Tools/Guest-Qmp.ps1');. (Join-Path $recovery 'Tools/Guest-NetClients.ps1');. (Join-Path $root 'Tools/Qemu-HostProfile.ps1')
 $profile=Resolve-R4QemuHostProfile $Qemu;$qmpPort=Port;$sshPort=Port
 $serial=Join-Path $output 'usb-serial.log';$clientLog=Join-Path $output 'usb-clients.log';[IO.File]::WriteAllText($clientLog,'',$utf8)
 if(Test-Path $serial){Remove-Item -LiteralPath $serial -Force}
 $askpass=Join-Path $output "askpass$suffix";& $Zig cc -O2 (Join-Path $recovery 'Tools/Guest-Askpass.c') -o $askpass;Require ($LASTEXITCODE -eq 0) 'Askpass failed.'
 $ssh=(Get-Command "ssh$suffix" -CommandType Application|Select-Object -First 1).Source
 $sshOptions=@('-c','chacha20-poly1305@openssh.com','-o','StrictHostKeyChecking=no','-o',('UserKnownHostsFile='+$(if($IsWindows){'NUL'}else{'/dev/null'})),'-o','LogLevel=ERROR','-o','ConnectTimeout=5')
 $bootCopy=Join-Path $output 'boot-work.img';Copy-Item -LiteralPath $image -Destination $bootCopy -Force
 $qemuArguments=@('-machine',"q35,accel=$($profile.AcceleratorChain)",'-cpu',$profile.CpuModel,'-smp','4','-m','8192','-display','none','-monitor','none','-no-reboot','-serial',"file:$serial",'-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off",'-device','qemu-xhci,id=xhci','-device','usb-kbd',
  '-drive',"if=none,id=usb,file=$bootCopy,format=raw",'-device','usb-storage,drive=usb,bootindex=1','-netdev',"user,id=net,hostfwd=tcp:127.0.0.1:$sshPort-:22",'-device','virtio-net-pci,netdev=net')
 $start=[Diagnostics.ProcessStartInfo]::new($Qemu);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;foreach($arg in $qemuArguments){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$session=$null;$watch.Restart()
 try {
  $deadline=[DateTime]::UtcNow.AddSeconds(120)
  do{
   [string]$text=if(Test-Path $serial){Get-Content -Raw -LiteralPath $serial}else{''}
   if($text -match '\[CRASH\]|panic-ret=' -or $process.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'USB Recovery did not boot.'}
   Start-Sleep -Milliseconds 100
  }while($text -notmatch '\[RECOVERY\] shell=READY' -or $text -notmatch 'DHCP05913 state=bound')
  Require ($text -match 'bus=usb') 'Recovery did not identify USB source.'
  $null=Ssh 'VER';$listing=Ssh 'DIR R:\INSTALL';Require ($listing -match 'RELEASE.ZIP') 'Original ZIP missing through guest SSH.'
  if($PackagedStarter){
   # Current production Recovery validates its complete slot after starting
   # SSH. Wait for that real menu-ready boundary before sending console keys.
   $deadline=[DateTime]::UtcNow.AddSeconds(60)
   do{
    $state=if((Ssh 'DIR R:\') -match 'state\.r4s'){Ssh 'TYPE R:\state.r4s'}else{''}
    if($state -match 'CURRENT_CONFIRMED=yes'){break}
    if($process.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'Packaged Recovery menu did not confirm its boot.'}
    Start-Sleep -Milliseconds 250
   }while($true)
  }
  $session=Open-Qmp $qmpPort;Start-Sleep -Milliseconds 1000;Send-Keys $session @('up','up','ret');Start-Sleep -Milliseconds 1000
  foreach($key in @('p','o','w','e','r','o','f','f','ret')){Send-Keys $session @($key)}
  Require ($process.WaitForExit(20000) -and $process.ExitCode -eq 0) 'USB keyboard/Terminal poweroff failed.'
  $runs+=@(@{case='Smp4UsbBoot';result='PASS';cpus=4;ramMB=8192;seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)})
 }finally{
  if($session){$session.Writer.Dispose();$session.Reader.Dispose();$session.Client.Dispose()}
  if(!$process.HasExited){$process.Kill($true)};$process.WaitForExit();[IO.File]::WriteAllText((Join-Path $output 'usb-qemu.log'),$stderr.GetAwaiter().GetResult(),$utf8);$null=$stdout.GetAwaiter().GetResult();$process.Dispose()
 }
}
$result=[ordered]@{schema=1;host=$(if($IsWindows){'Windows'}else{'Linux'});packagedStarter=[bool]$PackagedStarter;runs=$runs;rawReadContract=$rawReadContract;sourceZipSha256=$created.sourceZipSha256;creatorSha256=(Get-FileHash -LiteralPath $creator -Algorithm SHA256).Hash.ToLowerInvariant();runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();created=$created}
[IO.File]::WriteAllText((Join-Path $output 'usb-results.json'),(($result|ConvertTo-Json -Depth 30)+"`n"),$utf8)
Write-Host 'USB acceptance PASS.'
