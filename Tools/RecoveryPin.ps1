function Resolve-R4RecoveryPackage {
 param([Parameter(Mandatory)][string]$DistributionRoot,[Parameter(Mandatory)][string]$CacheRoot,[string]$Candidate='')
 $ErrorActionPreference='Stop'
 if(!$Candidate){$Candidate=[Environment]::GetEnvironmentVariable('R4OS_RECOVERY_CANDIDATE')}
 if($Candidate){
  $path=[IO.Path]::GetFullPath($Candidate)
  if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Explicit local Recovery candidate is missing.'}
  Write-Host "TECHNICAL RECOVERY CANDIDATE: $path"
  return [ordered]@{path=$path;technical=$true;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();pin=$null}
 }
 $pin=Get-Content -Raw -LiteralPath (Join-Path $DistributionRoot 'RecoveryPin.json')|ConvertFrom-Json -AsHashtable
 if($pin.schema -ne 1 -or $pin.product -cne 'r4os-recovery' -or $pin.architecture -cne 'x86_64' -or $pin.status -cne 'published'){
  throw 'No published Recovery pin is configured. Technical checks require an explicit -RecoveryCandidate or R4OS_RECOVERY_CANDIDATE.'
 }
 if($pin.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
    $pin.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $pin.releaseId -le 0){throw 'Invalid published Recovery pin.'}
 $asset="R4OS-Recovery-$($pin.version)-x86_64.zip"
 [IO.Directory]::CreateDirectory($CacheRoot)|Out-Null
 $path=Join-Path $CacheRoot $asset
 if(!(Test-Path -LiteralPath $path -PathType Leaf)){
  $temporary=Join-Path $CacheRoot ($asset+'.'+[Guid]::NewGuid().ToString('N')+'.part')
  try{
   Invoke-WebRequest -Uri "https://github.com/R4OSDev/r4os-recovery/releases/download/v$($pin.version)/$asset" -OutFile $temporary
   if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256){throw 'Downloaded Recovery differs from its explicit pin.'}
   Move-Item -LiteralPath $temporary -Destination $path
  }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
 }
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256){throw 'Cached Recovery differs from its explicit pin.'}
 return [ordered]@{path=$path;technical=$false;sha256=$pin.sha256;pin=$pin}
}
