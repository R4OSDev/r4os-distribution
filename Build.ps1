param(
 [Parameter(Position=0)][ValidateSet('tools','test','plan','image','verify','qemu','ssh','headless','benchmark','recovery-image','check')][string]$Action='tools',
 [Parameter(Position=1)][ValidateSet('','Slim','Full','Test','Benchmark')][string]$Profile='',
 [Parameter(Position=2)][string]$Variant='', [Parameter(Position=3)][string]$WorkloadVersion='',
 [Parameter(Position=4)][string]$CacheState='', [Parameter(Position=5)][int]$Repetitions=0,
 [Parameter(Position=6)][string]$EnvironmentId='',
 [string]$InputList='', [Alias('RecoveryPackage')][string]$RecoveryCandidate='',
 [ValidateSet('local','usb')][string]$Medium='local', [string]$OutputRoot=''
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
try {
 . (Join-Path $PSScriptRoot 'Tools/Distribution.ps1')
 $context=Get-R4DistributionContext $PSScriptRoot
 switch($Action){
  'tools' {Build-R4DistributionTools $context}
  'check' {Test-R4Distribution $context}
  'test' {Build-R4DistributionTools $context -Tests;Test-R4Distribution $context}
  'plan' {New-R4DistributionPlan $context $Profile $Variant|Out-Null}
  {$_ -in @('image','recovery-image')} {
   if(!$Profile){$Profile='Slim'}
   $list=if($InputList){$InputList}else{New-R4DistributionPlan $context $Profile $Variant}
   Build-R4DistributionTools $context
   . (Join-Path $PSScriptRoot 'Tools/InstallationImage.ps1')
   $result=New-R4OSInstallationImage -Root $PSScriptRoot -Profile $Profile -InputList $list -RecoveryCandidate $RecoveryCandidate -Medium $Medium -OutputRoot $OutputRoot -ToolsReady
   Copy-R4DistributionLegal $context (Split-Path $result.image -Parent)
  }
  'verify' {Test-R4DistributionImage $context $Profile}
  'qemu' {Start-R4DistributionInteractive $context $Profile $Variant 'Gui'}
  'ssh' {Start-R4DistributionInteractive $context $Profile $Variant 'SshDebug'}
  'headless' {Start-R4DistributionHeadless $context $Profile $Variant}
  'benchmark' {Start-R4DistributionBenchmark $context $Profile $Variant $WorkloadVersion $CacheState $Repetitions $EnvironmentId}
 }
 exit 0
}catch{Write-Error $_ -ErrorAction Continue;exit 1}
