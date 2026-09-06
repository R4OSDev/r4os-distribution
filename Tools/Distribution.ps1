# One owner for Windows/Linux profile, image and runner orchestration.
. (Join-Path $PSScriptRoot 'InstallationImage.ps1')
function Invoke-R4Distribution([string]$Program,[string[]]$Arguments) {
 & $Program @Arguments|Out-Host
 if($LASTEXITCODE -ne 0){throw "Distribution command failed ($LASTEXITCODE): $Program"}
}
function Get-R4DistributionContext([string]$Root) {
 $s=Get-InstallationFields (Join-Path $Root 'Settings.R4S');$ws=Get-InstallationPath $Root $s.WORKSPACE_ROOT
 $repos=Get-InstallationPath $Root $s.REPOSITORIES_ROOT;$art=Get-InstallationPath $ws $s.ARTIFACTS_ROOT
 $dev=Get-InstallationPath $ws $s.DEVKIT_ROOT;$suffix=if($IsWindows){'.exe'}else{''}
 $out=Get-InstallationPath $art $s.DISTRIBUTION_OUTPUT_ROOT
 return [ordered]@{root=$Root;workspace=$ws;repositories=$repos;output=$out;input=Get-InstallationPath $art $s.INPUT_ROOT;
  sdk=Get-InstallationPath $repos $s.SDK_ROOT;contract=Get-InstallationPath $repos $s.CONTRACT_ROOT;libraries=Get-InstallationPath $repos $s.LIBRARIES_ROOT;
  private=Get-InstallationPath $art $s.PRIVATE_INJECTION_ROOT;prefix=Join-Path $out 'HostTools';suffix=$suffix;
  zig=Join-Path (Get-InstallationPath $dev $s.ZIG_ROOT) "zig$suffix";qemu=Join-Path (Get-InstallationPath $dev $s.QEMU_ROOT) "qemu-system-x86_64$suffix";
  legal=Join-Path $Root 'Injection/R4OS/LICENSES';logs=Join-Path $out 'Logs'}
}
function Build-R4DistributionTools($Context,[switch]$Tests) {
 $arguments=@('build','--prefix',$Context.prefix,'--cache-dir',(Join-Path $Context.output '.Cache/build'),'--global-cache-dir',(Join-Path $Context.output '.Cache/global'),'-Doptimize=ReleaseSafe',"--fork=$($Context.sdk)","--fork=$($Context.contract)","--fork=$($Context.libraries)")
 if($Tests){$arguments+='test'}
 Push-Location -LiteralPath $Context.root
 try{Invoke-R4Distribution $Context.zig $arguments}finally{Pop-Location}
}
function Get-R4DistributionProfile($Context,[string]$Name) {
 if($Name -cnotin @('Slim','Full','Test','Benchmark')){throw 'Profile must be Slim, Full, Test or Benchmark.'}
 $profile=Get-InstallationFields (Join-Path $Context.root "Profiles/$Name.R4S")
 if($profile.PROFILE -cne $Name -or $profile.LAYOUT -cne 'r4os-gpt-1' -or $profile.IMAGE_MB -cne '2048' -or
    $profile.BOOT_MB -cne '128' -or $profile.SYSTEM_MB -cne '1024' -or $profile.RECOVERY_MB -cne '512' -or $profile.DATA_SIZE -cne 'rest'){throw "Invalid common layout in $Name profile."}
 return $profile
}
function Get-R4DistributionLegalNames {return @('R4OS-LICENSE.txt','R4OS-NOTICE.txt','THIRD-PARTY-NOTICES.txt','Limine-BSD-2-Clause.txt','FreeType-FTL.txt','Brotli-MIT.txt','zlib.txt','stb_image-MIT.txt','RTL8168-GPL-2.0-only.txt')}
function Test-R4DistributionLegal($Context,[string]$Plan='',[string]$Staged='') {
 $text=if($Plan){Get-Content -Raw -LiteralPath $Plan}else{''}
 foreach($name in Get-R4DistributionLegalNames){
  if(!(Test-Path -LiteralPath (Join-Path $Context.legal $name) -PathType Leaf)){throw "Missing legal source: $name"}
  if($Plan -and !$text.Contains('/R4OS/LICENSES/'+$name)){throw "Image plan omits legal file: $name"}
  if($Staged -and !(Test-Path -LiteralPath (Join-Path $Staged $name) -PathType Leaf)){throw "Missing staged legal file: $name"}
 }
 foreach($pair in @(@('LICENSE','R4OS-LICENSE.txt'),@('NOTICE','R4OS-NOTICE.txt'))){
  if((Get-FileHash -LiteralPath (Join-Path $Context.root $pair[0])).Hash -cne (Get-FileHash -LiteralPath (Join-Path $Context.legal $pair[1])).Hash){throw 'Repository/image legal text differs.'}
 }
}
function Copy-R4DistributionLegal($Context,[string]$Output) {
 Test-R4DistributionLegal $Context
 $destination=Join-Path $Output 'Legal';[IO.Directory]::CreateDirectory($destination)|Out-Null
 Copy-Item -Path (Join-Path $Context.legal '*') -Destination $destination -Force
 Test-R4DistributionLegal $Context -Staged $destination
}
function New-R4DistributionPlan($Context,[string]$Name,[string]$Variant='') {
 $profile=Get-R4DistributionProfile $Context $Name
 if($Variant -and ($Name -cne 'Test' -or $Variant -cne 'browser')){throw "Unknown $Name image variant: $Variant"}
 # The root owner produces MODULES.JSON and component includes for exactly
 # this profile before the Distribution owner applies its overlays.
 $prepare=@('-NoProfile','-File',(Join-Path $Context.workspace 'Tools/BuildWorkspace.ps1'),'-Action','plan','-Profile',$Name)
 if($Variant -ceq 'browser'){$prepare+='-BrowserTest'}
 Invoke-R4Distribution 'pwsh' $prepare
 Test-R4DistributionLegal $Context
 $tool=Join-Path $Context.prefix "bin/image-plan$($Context.suffix)"
 if(!(Test-Path $tool)){Build-R4DistributionTools $Context}
 $out=Join-Path $Context.output "Profiles/$Name";[IO.Directory]::CreateDirectory($out)|Out-Null
 $list=Join-Path $out 'image-adds.txt'
 $arguments=@('--output',$list,'--plan',(Join-Path $Context.input $profile.COMMON_PLAN),'--plan',(Join-Path $Context.input $profile.COMPONENT_PLAN))
 foreach($tree in @(@('sdk','Shared/C/include','Include/C'),@('sdk','Shared/C/src','Startup/C'),@('sdk','r4os/linker','Linker'),@('sdk','Templates','Templates'),@('sdk','BuildProfiles','BuildProfiles'),@('sdk','Toolchains','Toolchains'),
   @('contract','ABI','Contract/ABI'),@('contract','API','Contract/API'),@('contract','Generated','Contract/Generated'),@('contract','Module','Contract/Module'))){
  $arguments+=@('--tree',((Join-Path $Context[$tree[0]] $tree[1])+'|/R4OS/SDK/'+$tree[2]))
 }
 $arguments+=@('--overlay',(Join-Path $Context.root 'Injection'))
 if($profile.BENCHMARK_OVERLAY -ceq '1'){$arguments+=@('--overlay',(Join-Path $Context.root 'BenchmarkInjection'))}
 else{
  if($profile.TEST_OVERLAY -ceq '1'){$arguments+=@('--overlay',(Join-Path $Context.root 'TestInjection'))}
  if($Variant -ceq 'browser'){$arguments+=@('--overlay',(Join-Path $Context.root 'BrowserTestInjection'))}
  $arguments+=@('--optional-overlay',(Join-Path $Context.output 'Injection'))
  if([Environment]::GetEnvironmentVariable('R4OS_PUBLIC_IMAGE') -cne '1'){$arguments+=@('--optional-overlay',$Context.private)}
 }
 Push-Location -LiteralPath $Context.root
 try{Invoke-R4Distribution $tool $arguments}finally{Pop-Location}
 Test-R4DistributionLegal $Context -Plan $list
 return $list
}
function Test-R4DistributionImage($Context,[string]$Name) {
 $null=Get-R4DistributionProfile $Context $Name;$out=Join-Path $Context.output "Profiles/$Name"
 Test-R4DistributionLegal $Context -Plan (Join-Path $out 'image-adds.txt') -Staged (Join-Path $out 'Legal')
 . (Join-Path $PSScriptRoot 'InstallationImage.Check.ps1')
 $null=Test-R4OSInstallationImage -Image (Join-Path $out 'disk.img')
 Invoke-R4Distribution (Join-Path $Context.prefix "bin/ntfsverify$($Context.suffix)") @((Join-Path $out 'disk.img'))
}
function Start-R4DistributionInteractive($Context,[string]$Name,[string]$Adapter,[string]$Mode) {
 $null=Get-R4DistributionProfile $Context $Name
 if(!$Adapter){$Adapter='VirtioNet'}
 if($Mode -ceq 'SshDebug' -and $Name -cne 'Full'){throw 'Normal SSH debugging requires the Full profile.'}
 [IO.Directory]::CreateDirectory($Context.logs)|Out-Null
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Invoke-Qemu.ps1'),'-Mode',$Mode,'-QemuPath',$Context.qemu,'-ConfigPath',(Join-Path $Context.root 'QEMU/standard.conf'),
  '-WorkingDirectory',(Join-Path $Context.output "Profiles/$Name"),'-SerialLogPath',(Join-Path $Context.logs 'qemu-ssh-debug.log'),'-NetworkAdapter',$Adapter)
}
function Start-R4DistributionHeadless($Context,[string]$Name,[string]$Variant) {
 $profile=Get-R4DistributionProfile $Context $Name
 if($Name -cne 'Test' -or $profile.TEST_OVERLAY -cne '1' -or $Variant -cnotin @('','browser','smp4','clock4','smpfail4')){throw 'Headless acceptance requires Test and four vCPUs.'}
 . (Join-Path $PSScriptRoot 'Qemu-Media.ps1')
 $run=New-R4QemuMedia -SourceRoot (Join-Path $Context.output 'Profiles/Test') -Mode Fresh -Name ('headless-'+$(if($Variant){$Variant}else{'standard'}))
 [IO.Directory]::CreateDirectory($Context.logs)|Out-Null
 $log=Join-Path $Context.logs "qemu-test-$Variant.log";$errors=Join-Path $Context.logs "qemu-test-$Variant.err"
 foreach($path in @($log,$errors)){if(Test-Path $path){Remove-Item -LiteralPath $path -Force}}
 $values=@{R4OS_QEMU_EXE=$Context.qemu;R4OS_QEMU_CONFIG=Join-Path $Context.root 'QEMU/standard.conf';R4OS_QEMU_LOG=$log;R4OS_QEMU_ERROR_LOG=$errors;R4OS_QEMU_WORKING_DIRECTORY=$run;R4OS_QEMU_CPUS='4';
  R4OS_QEMU_STOP_MARKER=$(if($Variant -ceq 'clock4'){'[QUICKPROBE] result=DONE'}else{''});QEMU_TEST_TIMEOUT_SECONDS=$(if($env:QEMU_TEST_TIMEOUT_SECONDS){$env:QEMU_TEST_TIMEOUT_SECONDS}elseif($Variant -ceq 'clock4'){'60'}else{'1200'})}
 $saved=@{};foreach($key in $values.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,[string]$values[$key])}
 try{& pwsh -NoProfile -File (Join-Path $Context.root 'Tests/Invoke-QemuHeadless.ps1');$code=$LASTEXITCODE}
 finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
 $arguments=@('-NoProfile','-File',(Join-Path $Context.root 'Tests/Test-QemuApiMarkers.ps1'),'-LogPath',$log,'-ErrorPath',$errors,'-QemuExitCode',[string]$code,'-SmpCpuCount','4')
 if($Variant -ceq 'clock4'){$arguments+='-ClockSmoke'}
 if($Variant -ceq 'smpfail4'){$arguments+=@('-SmpFailedCount','1')}
 Invoke-R4Distribution 'pwsh' $arguments
}
function Start-R4DistributionBenchmark($Context,[string]$Name,[string]$Suite,[string]$Version,[string]$Cache,[int]$Count,[string]$Environment) {
 $profile=Get-R4DistributionProfile $Context $Name
 if($Name -cne 'Benchmark' -or $profile.BENCHMARK_OVERLAY -cne '1'){throw 'Benchmark requires its explicit profile.'}
 $values=@{R4OS_BENCHMARK_QEMU_EXE=$Context.qemu;R4OS_BENCHMARK_QEMU_CONFIG=Join-Path $Context.root 'QEMU/benchmark.conf';R4OS_BENCHMARK_IMAGE_CREATOR=Join-Path $Context.prefix "bin/imagecreater$($Context.suffix)";
  R4OS_BENCHMARK_PROFILE_OUTPUT=Join-Path $Context.output 'Profiles/Benchmark';R4OS_BENCHMARK_RUN_OUTPUT=Join-Path $Context.output 'Profiles/Benchmark/Runs/current';R4OS_BENCHMARK_RELEASE_VERSION_FILE=Join-Path $Context.root 'Injection/R4OS/CONFIG/VERSION.R4S'}
 $saved=@{};foreach($key in $values.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,[string]$values[$key])}
 try{Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $Context.root 'Tests/Invoke-QemuBenchmark.ps1'),'-Suite',$Suite,'-WorkloadVersion',$Version,'-CacheState',$Cache,'-Repetitions',[string]$Count,'-EnvironmentId',$Environment)}
 finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
}
function Test-R4Distribution($Context) {
 foreach($name in @('Slim','Full','Test','Benchmark')){$null=Get-R4DistributionProfile $Context $name}
 Test-R4DistributionLegal $Context
 $tool=Join-Path $Context.prefix "bin/image-plan$($Context.suffix)"
 Push-Location -LiteralPath $Context.root
 try{
  foreach($name in @('Slim','Full','Test','Benchmark')){
   $component=if($name -ceq 'Benchmark'){'Test'}else{$name}
   $arguments=@('--check','--output',"Tests/Expected/$name.plan",'--plan','Tests/Fixtures/Plans/Common.plan','--plan',"Tests/Fixtures/Plans/$component.plan",'--tree','Tests/Fixtures/Tree|/R4OS/SDK','--overlay','Tests/Fixtures/Injection')
   if($name -in @('Test','Benchmark')){$arguments+=@('--overlay',"Tests/Fixtures/$($name)Injection")}
   Invoke-R4Distribution $tool $arguments
  }
  & $tool --check --output Tests/Expected/Full.plan --plan Tests/Fixtures/Plans/Common.plan --plan Tests/Fixtures/Plans/Collision.plan --tree 'Tests/Fixtures/Tree|/R4OS/SDK' --overlay Tests/Fixtures/Injection 2>$null
  if($LASTEXITCODE -eq 0){throw 'Duplicate image-plan target accepted.'}
 }finally{Pop-Location}
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Invoke-Qemu.ps1'),'-SelfTest','-QemuPath',$Context.qemu)
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $Context.root 'Tests/Invoke-QemuBenchmark.ps1'),'-SelfTest')
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'BenchmarkHistory.ps1'),'-Action','selftest')
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $Context.root 'Tests/Test-QemuApiMarkers.ps1'),'-SelfTest')
 Invoke-R4Distribution 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Release.ps1'),'-Action','SelfTest')
 Write-Host 'Distribution profiles, common image plans and runner checks PASS.'
}
