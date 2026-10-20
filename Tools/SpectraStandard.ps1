# One bounded phase of the existing SMP4 runner. Spectra owns results/scoring.
function Start-R4SpectraStandard($Context,[switch]$SelfReference) {
 . (Join-Path $PSScriptRoot 'Qemu-HostProfile.ps1')
 . (Join-Path $PSScriptRoot 'Qemu-Media.ps1')
 . (Join-Path $PSScriptRoot 'Test-Retention.ps1')
 $spectra=Join-Path $Context.repositories 'Diagnostics/Spectra'
 . (Join-Path $spectra 'Tools/StandardBenchmark.ps1')
 $reference=$null
 if(!$SelfReference){
  $api=$env:R4OS_DEVCENTER_API_URL
  $hostSettings=Join-Path $Context.workspace 'Tools/BenchmarkHost.R4S'
  if(!$api -and (Test-Path -LiteralPath $hostSettings)){$api=(Get-InstallationFields $hostSettings)['DEVCENTER_API_URL']}
  $reference=Resolve-SpectraReference -Descriptor (Join-Path $spectra 'Baselines/standard-3.reference.json') -CacheRoot (Join-Path $Context.output 'Diagnostics/SpectraStandard') -ApiUrl $api
 }
 $id=[guid]::NewGuid().ToString();$evidence=Join-Path $Context.output ('Diagnostics/SpectraStandard/'+$id)
 $scratch=Join-Path $Context.workspace ('Temp/SpectraStandard/'+$id)
 $sourceRoot=Join-Path $evidence 'Source'
 [IO.Directory]::CreateDirectory($scratch)|Out-Null;[IO.Directory]::CreateDirectory($evidence)|Out-Null
 try {
 $sourcePlan=Join-Path $Context.output 'Profiles/Test/image-adds.txt'
 if(!(Test-Path -LiteralPath $sourcePlan)){throw 'Build the current Test image before running the standard phase.'}
 $configSource=Join-Path $Context.root 'TestInjection/CONFIG.R4S'
 $configText=[IO.File]::ReadAllText($configSource)
 $configText=[regex]::Replace($configText,'(?m)^SHELL=.*$','SHELL=/R4OS/SOFTWARE/TERMINAL/TERMINAL.R4X')
 $configText=[regex]::Replace($configText,'(?m)^SHELL_ARGS=.*$','SHELL_ARGS=')
 # This phase has its own defined boot state: no desktop/subsystem workload,
 # boot selftest off (the following regular acceptance retains its probes).
 $configText=[regex]::Replace($configText,'(?m)^OPTION SMP selftest=.*$','OPTION SMP selftest=no')
 $configPath=Join-Path $scratch 'CONFIG.R4S';[IO.File]::WriteAllText($configPath,$configText,[Text.UTF8Encoding]::new($true))
 $autoexec=Join-Path $scratch 'AUTOEXEC.BAT'
 $lines=@('@ECHO OFF','SET TEMP=C:\TEMP','C:\R4OS\SOFTWARE\TERMINAL\SERVMAN.R4X BOOT',
  'ECHO [SPECTRA-STANDARD] BEGIN','C:\R4OS\SOFTWARE\TERMINAL\DIAG\SPECTRA.R4X BENCH STANDARD /SETTLE:200 /JSON',
  'SET','ECHO [SPECTRA-STANDARD] END','C:\R4OS\SOFTWARE\TERMINAL\DIAG\SPECTRA.R4X METRICS SMP /JSON','POWEROFF')
 [IO.File]::WriteAllLines($autoexec,$lines,[Text.UTF8Encoding]::new($false))
 $plan=Join-Path $scratch 'image-adds.txt';$entries=[Collections.Generic.List[string]]::new();$replaced=@{}
 $artifactSpecs=@(@('kernel','Kernel','/boot/r4os.elf'),@('spectra','Diagnostics/Spectra','/R4OS/SOFTWARE/TERMINAL/DIAG/SPECTRA.R4X'),@('lifecycle-fixture','Diagnostics/Spectra','/R4OS/SOFTWARE/TERMINAL/DIAG/SPECTRA/STDCHILD.R4X'),@('terminal','Apps/Terminal','/R4OS/SOFTWARE/TERMINAL/TERMINAL.R4X'),@('servman','Apps/ServiceManager','/R4OS/SOFTWARE/TERMINAL/SERVMAN.R4X'))
 $sourceFiles=@{}
 $kernelBuild=$null
 foreach($line in [IO.File]::ReadLines($sourcePlan)){
  $split=$line.LastIndexOf(':/');if($split -lt 0){throw 'Invalid canonical image plan line.'}
  $target=$line.Substring($split+1);$source=$line.Substring(0,$split)
  if($target -ieq '/CONFIG.R4S'){$source=$configPath;$replaced.config=$true}
  if($target -ieq '/AUTOEXEC.BAT'){$source=$autoexec;$replaced.autoexec=$true}
  foreach($item in $artifactSpecs){
   if($target -ieq $item[2]){
    $snapshot=Join-Path $scratch ($item[0]+'.artifact')
    Copy-Item -LiteralPath $source -Destination $snapshot
    $source=$snapshot
   }
  }
  if($target -ieq '/R4OS/CONFIG/VERSION.R4S'){
   $snapshot=Join-Path $scratch 'VERSION.R4S';Copy-Item -LiteralPath $source -Destination $snapshot;$source=$snapshot
  }
  if($target -ieq '/boot/r4os.elf'){
   $kernelOwner=Join-Path $Context.repositories 'Kernel'
   . (Join-Path $kernelOwner 'Tools/BuildMetadata.ps1')
   $kernelBuild=Get-R4KernelBuildMetadata -KernelRoot $kernelOwner -Artifact $source
   [IO.File]::WriteAllText((Join-Path $scratch 'kernel.build.json'),($kernelBuild|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
  }
  $sourceFiles[$target.ToUpperInvariant()]=$source;$entries.Add($source+':'+$target)
 }
 if(!$replaced.config -or !$replaced.autoexec){throw 'Test image lacks canonical boot configuration.'}
 [IO.File]::WriteAllLines($plan,$entries,[Text.UTF8Encoding]::new($false))
 $built=New-R4OSInstallationImage -Root $Context.root -Profile Benchmark -InputList $plan -OutputRoot $sourceRoot -ToolsReady
 $run=New-R4QemuMedia -SourceRoot (Split-Path $built.image -Parent) -Mode Fresh -Name standard-smp4
 $hostProfile=Resolve-R4QemuHostProfile $Context.qemu
 $hostId=$env:R4OS_BENCHMARK_HOST_ID
 $hostFile=Join-Path $Context.workspace 'Tools/BenchmarkHost.R4S'
 if(!$hostId -and (Test-Path -LiteralPath $hostFile)){$hostId=(Get-InstallationFields $hostFile).HOST_ID}
 if(!$hostId){$hostId=[regex]::Replace([Environment]::MachineName.ToLowerInvariant(),'[^a-z0-9-]','-')}
 $qemuVersion=([string](@(& $Context.qemu --version)[0])).Trim();if($LASTEXITCODE -ne 0){throw 'QEMU version query failed.'}
 $method=[ordered]@{
  execution='qemu';vcpus='4';ram_bytes='1073741824';
  cpu_policy='all-available-v1';measurement='parallel-wall-ns-per-operation-v3';filesystem='ntfs';settle_ms='200';
  qemu=[ordered]@{version=$qemuVersion;backend=$hostProfile.Name.ToLowerInvariant();machine='q35';cpu_selection=$hostProfile.CpuModel;network='none';host_audio='none';rtc='default';strict_accelerator=$true};
  storage=[ordered]@{layout='r4os-gpt-1';image_mb='16384';boot_mb='128';system_mb='10240';recovery_mb='5120';controller='ich9-ahci';format='raw';host_cache='none';filesystem='ntfs';fixture='fresh-image';nvme_namespace_bytes='16777216'};
  workloads=$script:SpectraWorkloads;cache_state='parallel-active-per-area-1s-3batches-v3';warmup_runs='1';warmup_min_ns='1000000000';warmup_min_batches='3';repetitions='5'
 }
 $method.workloads=[ordered]@{};foreach($key in $script:SpectraWorkloads.Keys){$method.workloads[$key]=$script:SpectraWorkloads[$key]}
 $method.workloads.lifecycle_fixture_sha256=(Get-FileHash -LiteralPath $sourceFiles['/R4OS/SOFTWARE/TERMINAL/DIAG/SPECTRA/STDCHILD.R4X']).Hash.ToLowerInvariant()
 $methodBytes=[Text.Encoding]::UTF8.GetBytes((Get-SpectraCanonical (Get-SpectraMethod $method)));$comparison=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($methodBytes)).ToLowerInvariant()
 $environment=[ordered]@{};foreach($key in $method.Keys){$environment[$key]=$method[$key]}
 $environment.host=[ordered]@{operating_system=[Runtime.InteropServices.RuntimeInformation]::OSDescription;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();processor_count=[string][Environment]::ProcessorCount}
 $cpuLabel=$null
 if($IsLinux -and (Test-Path -LiteralPath '/proc/cpuinfo')){
  $line=Get-Content -LiteralPath '/proc/cpuinfo'|Where-Object {$_ -match '^model name\s*:'}|Select-Object -First 1
  if($line){$cpuLabel=($line -split ':',2)[1].Trim()}
 }elseif($IsWindows){
  try{$cpuLabel=[string](Get-CimInstance Win32_Processor|Select-Object -First 1).Name}catch{$cpuLabel=$env:PROCESSOR_IDENTIFIER}
 }
 $environment.cpu=[ordered]@{model_selection=$hostProfile.CpuModel;host_model=$cpuLabel;architecture='x86_64'}
 $environment.boot=[ordered]@{profile='Test';shell='Terminal';desktop=$false;subsystem_workloads=$false;network='none';services='SERVMAN BOOT';settle_ms='200';phase='before-first-prompt';smp_selftest=$false}
 $artifacts=[Collections.Generic.List[object]]::new()
 foreach($item in $artifactSpecs){
  $file=$sourceFiles[$item[2].ToUpperInvariant()];if(!$file){throw 'Missing benchmark artifact: '+$item[0]}
  $repo=Join-Path $Context.repositories $item[1]
  $commit=([string](& git -C $repo rev-parse HEAD)).Trim();if($LASTEXITCODE -ne 0){throw 'Artifact owner commit missing.'}
  $dirty=@(& git -C $repo status --porcelain).Count -ne 0
  $buildOptions=if($item[0] -ceq 'kernel'){
   if(!$kernelBuild){throw 'The exact kernel compiler/profile record was not captured.'}
   [ordered]@{languages=$kernelBuild.languages;compilers=$kernelBuild.compilers;profiles=$kernelBuild.profiles;options=$kernelBuild.options;configuration_sha256=$kernelBuild.configuration_sha256;metrics=$null;metrics_source='guest-header'}
  }else{@{optimize='ReleaseSmall';red_zone=$false}}
  $artifacts.Add([ordered]@{component=$item[0];commit=$commit;dirty=$dirty;sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant();build_options=$buildOptions})
 }
 $artifacts.Add([ordered]@{component='fresh-image';sha256=(Get-Content -Raw -LiteralPath (Join-Path $run 'source.json')|ConvertFrom-Json).sourceSha256;image_method='r4os-gpt-1';boot_config_sha256=(Get-FileHash $configPath).Hash.ToLowerInvariant();autoexec_sha256=(Get-FileHash $autoexec).Hash.ToLowerInvariant()})
 $versionFile=$sourceFiles['/R4OS/CONFIG/VERSION.R4S'];$release=(Get-InstallationFields $versionFile).RELEASE_VERSION
 $kernelVersion=$kernelBuild.kernel_version
 $metadata=[ordered]@{run_id=$id;host_id=$hostId;started_at_utc=$null;finished_at_utc=$null;release_version=$release;kernel_version=$kernelVersion;environment_id=('r4os-standard3-smp4-'+$hostProfile.Name.ToLowerInvariant()+'-1');comparison_key=$comparison;environment=$environment;artifacts=@($artifacts.ToArray())}
 $serial=Join-Path $evidence 'serial.log';$errors=Join-Path $evidence 'qemu.err';$contextPath=Join-Path $evidence 'context.json';$outputPath=Join-Path $evidence 'run.json'
 $nvme=Join-Path $run 'nvme.img';$f=[IO.File]::Open($nvme,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.SetLength(16MB);$f.Flush($true)}finally{$f.Dispose()}
 $values=@{R4OS_QEMU_EXE=$Context.qemu;R4OS_QEMU_CONFIG=Join-Path $Context.root 'QEMU/standard.conf';R4OS_QEMU_WORKING_DIRECTORY=$run;R4OS_QEMU_LOG=$serial;R4OS_QEMU_ERROR_LOG=$errors;R4OS_QEMU_CPUS='4';R4OS_QEMU_STOP_MARKER='';R4OS_QEMU_NVME_TEST_DISK=$nvme;R4OS_QEMU_STRICT_ACCELERATOR='1';R4OS_QEMU_EXPECTED_BACKEND=$hostProfile.Name;QEMU_TEST_TIMEOUT_SECONDS='420'}
 $saved=@{};foreach($key in $values.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$values[$key])}
 $metadata.started_at_utc=[DateTime]::UtcNow.ToString('o')
 try{& pwsh -NoProfile -File (Join-Path $Context.root 'Tests/Invoke-QemuHeadless.ps1')|Out-Host;$code=$LASTEXITCODE}
 finally{
  $metadata.finished_at_utc=[DateTime]::UtcNow.ToString('o');foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}
  [IO.File]::WriteAllText($contextPath,($metadata|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))
 }
 $arguments=@('-NoProfile','-File',(Join-Path $spectra 'Tools/Export-StandardBenchmark.ps1'),'-GuestRecords',$serial,'-Context',$contextPath,'-Output',$outputPath)
 if($SelfReference){$arguments+='-SelfReference'}elseif(Test-Path -LiteralPath $reference){$arguments+=@('-Reference',$reference)}
 & pwsh @arguments|Out-Host;$exportCode=$LASTEXITCODE
 if($code -ne 0 -or $exportCode -ne 0){throw "Spectra standard phase failed; QEMU=$code export=$exportCode; evidence=$evidence"}
 $text=[IO.File]::ReadAllText($serial)
 if(!$text.Contains('[SPECTRA-STANDARD] END') -or $text -match 'KERNEL FATAL|Kernel panic|Zig [Pp]anic|\[CRASH\]'){throw 'Standard guest did not finish cleanly.'}
 foreach($path in @($serial,$errors,$contextPath)){
  if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
 }
 Write-Host ('Spectra standard SMP4 phase passed: '+$outputPath)
 return $outputPath
 } finally {
  Remove-R4TestDirectory $Context.workspace $sourceRoot
  Remove-R4TestDirectory $Context.workspace $scratch
 }
}
