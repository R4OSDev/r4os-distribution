# Explicit disposable SNES benchmark image. No canonical image is modified.
function Invoke-R4SnesGuestBenchmark {
 param([ValidateSet('ntsc','pal')][string]$Region='ntsc',[ValidateSet('normal','detail','paired')][string]$Mode='normal',
  [ValidateSet('Small','Maximized')][string]$WindowSize='Small',[switch]$OutputAnalysis,[switch]$CheckOnly,[int]$TimeoutSeconds=420)
 $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
 $distribution=Split-Path $PSScriptRoot -Parent
 . (Join-Path $distribution 'Tools/Distribution.ps1')
 . (Join-Path $distribution 'Tools/Qemu-HostProfile.ps1')
 if(!('R4GuestNtfs' -as [type])){Add-Type -Path (Join-Path $distribution 'Tools/ReadGuestFile.cs')}
 $context=Get-R4DistributionContext $distribution
 $id=[guid]::NewGuid().ToString('N')
 $scratch=Join-Path $context.workspace ('Temp/SnesBenchmark/'+$id)
 $source=Join-Path $context.output ('Diagnostics/SubsystemBenchmarks/Work/'+$id)
 $null=New-Item -ItemType Directory -Force $scratch
 $starter=Join-Path $distribution $(if($IsWindows){'Build.bat'}else{'Build.sh'})
 $qemu=$null;$records=@();$failure=$null;$metadata=$null;$hostProfile=$null;$windowOutput=$null;$outputProfile=$null
 try{
  & $starter plan Test|Out-Host
  if($LASTEXITCODE -ne 0){throw 'SNES Test planning failed'}
  $regular=Get-Content -Raw (Join-Path $context.output 'Generated/MODULES.JSON')|ConvertFrom-Json
  $inventory=Join-Path $scratch 'MODULES.JSON';$components=Join-Path $scratch 'components.plan'
  $catalog=Join-Path $context.sdk ('zig-out/bin/module-catalog'+$context.suffix)
  $selection=@('workspace-image-plan','--workspace-map',(Join-Path $context.input 'WorkspaceModules.map'),'--image-mode','test',
   '--output',$components,'--inventory-output',$inventory,'--kernel-version-source',(Join-Path $context.repositories 'Kernel/VERSION.R4S'),
   '--kernel-artifact',(Join-Path $context.repositories 'Kernel/zig-out/bin/r4os.elf'),'--include-target','/R4OS/SUBSYSTEMS/r4os.snes/R4SNES.R4X')
  & $catalog @selection|Out-Host
  if($LASTEXITCODE -ne 0){throw 'SNES private catalog failed'}
  $selected=Get-Content -Raw $inventory|ConvertFrom-Json
  foreach($entry in $regular.entries){if($entry.kind -ne 'KERNEL' -and $entry.target -notin $selected.entries.target){$selection+=@('--include-target',$entry.target)}}
  & $catalog @selection|Out-Host
  if($LASTEXITCODE -ne 0){throw 'SNES final catalog failed'}
  $config=Join-Path $scratch 'CONFIG.R4S';$autoexec=Join-Path $scratch 'AUTOEXEC.BAT';$services=Join-Path $scratch 'SERVICES.R4S'
  $command=if($CheckOnly){'/PERF-CHECK-R4SNES'}else{'/PERF-R4SNES'}
  $shellArgs="$command /SNES-$($Region.ToUpperInvariant()) /SNES-$($Mode.ToUpperInvariant())"
  if($WindowSize -eq 'Maximized'){$shellArgs+=' /SNES-MAXIMIZED'}
  if($OutputAnalysis){$shellArgs+=' /SNES-OUTPUT-PROFILE'}
  [IO.File]::WriteAllLines($config,@('GRAPHICS=SOFTWARE','AUTO=PCI','AUTO=ACPI','SHELL=/R4OS/SOFTWARE/DESKTOP/R4DESK.R4X',"SHELL_ARGS=$shellArgs",'DRIVER=DISPBLIT','DRIVER=HDA','DRIVER=SERIAL','DRIVER=CPUPOWER','DRIVER=ACPIPLAT','LOG=verbose'),[Text.UTF8Encoding]::new($true))
  [IO.File]::WriteAllText($autoexec,"@ECHO OFF`r`n",[Text.UTF8Encoding]::new($false))
  $serviceLines=@(Get-Content (Join-Path $distribution 'Injection/R4OS/CONFIG/SERVICES.R4S')|Where-Object {$_ -match '^SERVICE;name=(WINSVC|AUDSVC|CLIPSVC|LOGSVC);'})
  if($serviceLines.Count -ne 4){throw 'SNES needs four explicit productive services'}
  [IO.File]::WriteAllLines($services,$serviceLines,[Text.UTF8Encoding]::new($true))
  $plan=@(foreach($line in Get-Content (Join-Path $context.output 'Profiles/Test/image-adds.txt')){
   if($line.EndsWith(':/CONFIG.R4S')){$config.Replace('\','/')+':/CONFIG.R4S'}
   elseif($line.EndsWith(':/AUTOEXEC.BAT')){$autoexec.Replace('\','/')+':/AUTOEXEC.BAT'}
   elseif($line.EndsWith(':/R4OS/CONFIG/SERVICES.R4S')){$services.Replace('\','/')+':/R4OS/CONFIG/SERVICES.R4S'}
   elseif($line.EndsWith(':/R4OS/CONFIG/MODULES.JSON')){$inventory.Replace('\','/')+':/R4OS/CONFIG/MODULES.JSON'}
   else{$line}
  })
  foreach($entry in @(Get-Content $components|Where-Object {$_ -match ':/R4OS/SUBSYSTEMS/r4os.snes/'})){
   $target=$entry.Substring($entry.LastIndexOf(':')+1)
   if(!@($plan|Where-Object {$_.EndsWith(':'+$target,[StringComparison]::OrdinalIgnoreCase)}).Count){$plan+=$entry}
  }
  $planPath=Join-Path $scratch 'image-adds.txt';[IO.File]::WriteAllLines($planPath,$plan,[Text.UTF8Encoding]::new($false))
  & $starter image Test -InputList $planPath -OutputRoot $source|Out-Host
  if($LASTEXITCODE -ne 0){throw 'SNES private image failed'}
  $metadata=Get-Content -Raw (Join-Path $source 'image.json')|ConvertFrom-Json -AsHashtable
  $image=Join-Path $source 'disk.img';$offset=[long]$metadata.installation.partitions.SYSTEM.firstLba*512
  $actual=[R4GuestNtfs]::ReadFile($image,$offset,'/R4OS/SUBSYSTEMS/r4os.snes/R4SNES.R4X')
  $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual)).ToLowerInvariant()
  $canonical=@(Get-Content $components|Where-Object {$_.EndsWith(':/R4OS/SUBSYSTEMS/r4os.snes/R4SNES.R4X')})
  if($canonical.Count -ne 1){throw 'SNES canonical artifact missing'}
  $artifactPath=$canonical[0].Substring(0,$canonical[0].LastIndexOf(':'))
  if($digest -cne (Get-FileHash $artifactPath).Hash.ToLowerInvariant()){throw 'SNES guest artifact differs'}
  $metadata.r4snes_sha256=$digest
  $desktopBytes=[R4GuestNtfs]::ReadFile($image,$offset,'/R4OS/SOFTWARE/DESKTOP/R4DESK.R4X')
  $desktopHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($desktopBytes)).ToLowerInvariant()
  $desktopPath=Join-Path $context.workspace 'Artifacts/Modules/Desktop/R4DESK.R4X'
  if($desktopHash -cne (Get-FileHash $desktopPath).Hash.ToLowerInvariant()){throw 'SNES Desktop guest artifact differs'}
  $metadata.desktop_sha256=$desktopHash
  $serial=Join-Path $scratch 'serial.log';$hostProfile=Resolve-R4QemuHostProfile $context.qemu
  $accelerator=$hostProfile.AcceleratorChain.Split(':')[0]
  $start=[Diagnostics.ProcessStartInfo]::new($context.qemu);$start.UseShellExecute=$false;$start.WorkingDirectory=$source;$start.RedirectStandardError=$true
  foreach($arg in @('-readconfig',(Join-Path $distribution 'QEMU/standard.conf'),'-cpu',$hostProfile.CpuModel,'-m','1G','-smp','4','-machine',('accel='+$accelerator),'-audiodev','driver=none,id=headless-audio','-global','hda-duplex.audiodev=headless-audio','-serial',('file:'+$serial),'-display','none','-monitor','none','-no-reboot','-nic','none')){$start.ArgumentList.Add($arg)}
  $qemu=[Diagnostics.Process]::Start($start);$errors=$qemu.StandardError.ReadToEndAsync()
  if(!$qemu.WaitForExit($TimeoutSeconds*1000)){$qemu.Kill($true);$qemu.WaitForExit();throw 'SNES guest timeout'}
  $boot=[IO.File]::ReadAllText($serial)
  if($boot -notmatch '\[SMP\] stage=active [^\r\n]*online=4 failed=0 fallback=no'){throw 'SNES guest requires four actually online CPUs'}
  if($qemu.ExitCode -ne 0 -or $boot -match 'KERNEL FATAL|Kernel panic|\[CRASH\]|\[PANIC\]' -or $boot -notmatch 'System poweroff\.'){
   throw ('SNES guest failed: '+$errors.GetAwaiter().GetResult())
  }
  $raw=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-PERF.JSONL'))
  foreach($line in $raw.Split("`n")){if($line.Trim()){$records+=,($line|ConvertFrom-Json -AsHashtable)}}
  $status=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-STATUS.TXT'))
  if($status -cne 'OK'){
   $detail=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-PERF.ERROR'))
   throw ('SNES application failed: '+$detail)
  }
  $trace=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-PRESENT.TXT'))
  $generations=@($trace.Split("`n")|Where-Object {$_.Trim()})
  $windowOutput=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-WINDOW.JSON'))|ConvertFrom-Json -AsHashtable
  if(!$records.Count -or !$generations.Count -or $windowOutput.records.Count -ne $generations.Count){throw 'SNES guest result incomplete'}
  for($i=0;$i -lt $generations.Count;$i++){
   if([ulong]$generations[$i] -ne [ulong]$windowOutput.records[$i].generation){throw 'SNES copy generation traces differ'}
  }
  if($OutputAnalysis){
   $outputProfile=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile($image,$offset,'/TEMP/SNES-OUTPUT.JSON'))|ConvertFrom-Json -AsHashtable
   if($outputProfile.contract -cne 'desktop-software-output-v1' -or $outputProfile.records.Count -ne 20){throw 'SNES output phase analysis incomplete'}
  }
 }catch{$failure=$_.Exception.Message}
 finally{
  if($qemu -and !$qemu.HasExited){$qemu.Kill($true);$qemu.WaitForExit()}
  if($failure -and !$records.Count -and $metadata){
   try{
    $partial=[Text.Encoding]::UTF8.GetString([R4GuestNtfs]::ReadFile((Join-Path $source 'disk.img'),([long]$metadata.installation.partitions.SYSTEM.firstLba*512),'/TEMP/SNES-PERF.JSONL'))
    foreach($line in $partial.Split("`n")){if($line.Trim()){$records+=,($line|ConvertFrom-Json -AsHashtable)}}
   }catch{}
  }
  if(Test-Path $source){Remove-Item -LiteralPath $source -Recurse -Force}
  Remove-Item -LiteralPath $scratch -Recurse -Force
 }
 return [pscustomobject]@{Records=$records;Failure=$failure;Image=$metadata;HostProfile=$hostProfile;WindowOutput=$windowOutput;OutputAnalysis=$outputProfile}
}
