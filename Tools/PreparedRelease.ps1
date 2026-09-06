# Publish the exact already-qualified assets; never regenerate their ZIPs.
function Read-R4PreparedAssets {
 param([string]$Directory,[string]$Version,[string[]]$ProfileNames,
       [object[]]$Repositories,[object]$RecoveryPin)
 $sourceName="R4OS-SOURCES-$Version.json"
 $names=@($ProfileNames|ForEach-Object {"R4OS-$Version-$($_.ToLowerInvariant())-x86_64.zip"})+@($sourceName)
 $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($name in $names){if(!$expected.Add($name)){throw 'Duplicate prepared profile.'}}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($line in [IO.File]::ReadAllLines((Join-Path $Directory 'SHA256SUMS.txt'))){
  if(!$line -or $line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9_.-]+)$'){throw 'Invalid prepared checksum record.'}
  $digest=$Matches[1];$name=$Matches[2]
  if(!$expected.Contains($name) -or !$seen.Add($name)){throw 'Unexpected or duplicate prepared asset.'}
  if((Get-Sha256 (Join-Path $Directory $name)) -cne $digest){throw "Prepared asset changed: $name"}
 }
 if(!$seen.SetEquals($expected)){throw 'Prepared checksums do not cover every selected asset.'}
 $source=Get-Content -Raw -LiteralPath (Join-Path $Directory $sourceName)|ConvertFrom-Json
 if($source.schema -ne 1 -or $source.technical -or $source.release_version -cne $Version -or
    $source.tag -cne "v$Version" -or $source.architecture -cne 'x86_64' -or
    (@($source.profiles|Sort-Object) -join '|') -cne (@($ProfileNames|Sort-Object) -join '|')){throw 'Prepared source/version/profile contract differs.'}
 # Compare the already-pushed source identities, including the complete
 # repository set. A later source change requires a new preparation/test.
 $fields=@('name','github_repository','workspace_path','branch','commit','dirty')
 $old=@($source.repositories|Sort-Object name|Select-Object -Property $fields)|ConvertTo-Json -Depth 8 -Compress
 $now=@($Repositories|Sort-Object name|Select-Object -Property $fields)|ConvertTo-Json -Depth 8 -Compress
 if(!$Repositories.Count -or $old -cne $now){throw 'Source repositories changed since preparation.'}
 $distribution=@($Repositories|Where-Object {$_.name -ceq 'Distribution'})
 if($distribution.Count -ne 1 -or $source.distribution_commit -cne $distribution[0].commit){throw 'Prepared distribution commit differs.'}
 foreach($field in @('schema','product','architecture','status','version','releaseId','sha256')){
  if([string]$source.recovery_pin.$field -cne [string]$RecoveryPin.$field){throw 'Recovery pin changed since preparation.'}
 }
 if($RecoveryPin.status -cne 'published' -or $source.recovery_inputs.Count -ne $ProfileNames.Count){throw 'Prepared Recovery input is not published.'}
 foreach($profileName in $ProfileNames){
  $recoveryInput=@($source.recovery_inputs|Where-Object {$_.profile -ceq $profileName})
  if($recoveryInput.Count -ne 1 -or $recoveryInput[0].technical -or $recoveryInput[0].version -cne $RecoveryPin.version -or $recoveryInput[0].sha256 -cne $RecoveryPin.sha256){throw 'Prepared package does not use the selected published Recovery.'}
 }
 $notes=Join-Path $Directory 'RELEASE-NOTES.md'
 if(!(Test-Path -LiteralPath $notes -PathType Leaf)){throw 'Prepared release notes are missing.'}
 $assets=@($names|ForEach-Object {Join-Path $Directory $_})+@(Join-Path $Directory 'SHA256SUMS.txt')
 return [pscustomobject]@{Version=$Version;Tag="v$Version";Profiles=@($ProfileNames);
  DistributionCommit=$source.distribution_commit;OutputRoot=$Directory;NotesPath=$notes;Assets=$assets}
}

function Get-R4PreparedRelease {
 param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string[]]$ProfileNames)
 if($Context.TechnicalCandidate){throw 'Technical preparations cannot be published.'}
 $version=Get-ReleaseVersion $Context.VersionFile
 $repositories=@(Get-RepositorySnapshots $Context)
 $pin=Get-Content -Raw -LiteralPath (Join-Path $Context.DistributionRoot 'RecoveryPin.json')|ConvertFrom-Json
 $prepared=Read-R4PreparedAssets (Join-Path $Context.ReleaseOutputRoot $version) $version $ProfileNames $repositories $pin
 Write-Host "[OK] Exact prepared assets verified: $($prepared.OutputRoot)"
 return $prepared
}

function Test-R4PreparedRelease {
 param([string]$Directory)
 [IO.Directory]::CreateDirectory($Directory)|Out-Null
 $repository=[pscustomobject]@{name='Distribution';github_repository='R4OSDev/r4os-distribution';workspace_path='Repositories/Distribution';branch='main';commit=('a'*40);dirty=$false}
 $pin=[pscustomobject]@{schema=1;product='r4os-recovery';architecture='x86_64';status='published';version='0.1.19';releaseId=1;sha256=('b'*64)}
 $source=[pscustomobject]@{schema=1;technical=$false;release_version='1.2.3';tag='v1.2.3';architecture='x86_64';profiles=@('Slim');distribution_commit=$repository.commit;repositories=@($repository);recovery_pin=$pin;
  recovery_inputs=@(@{profile='Slim';version=$pin.version;sha256=$pin.sha256;technical=$false})}
 $asset=Join-Path $Directory 'R4OS-1.2.3-slim-x86_64.zip';Write-Utf8NoBom $asset 'Qualified bytes'
 $sourcePath=Join-Path $Directory 'R4OS-SOURCES-1.2.3.json';Write-JsonFile $sourcePath $source
 Write-Utf8NoBom (Join-Path $Directory 'RELEASE-NOTES.md') 'Qualified release'
 $checksum=Join-Path $Directory 'SHA256SUMS.txt'
 $lines=@($asset,$sourcePath)|ForEach-Object {(Get-Sha256 $_)+'  '+(Split-Path $_ -Leaf)}
 Write-Utf8NoBom $checksum (($lines -join "`n")+"`n")
 $null=Read-R4PreparedAssets $Directory '1.2.3' @('Slim') @($repository) $pin
 $before=Get-Sha256 $asset
 Write-Utf8NoBom $asset 'Later regenerated bytes'
 $rejected=$false;try{$null=Read-R4PreparedAssets $Directory '1.2.3' @('Slim') @($repository) $pin}catch{$rejected=$true}
 if(!$rejected){throw 'Changed qualified ZIP was accepted.'}
 Write-Utf8NoBom $asset 'Qualified bytes'
 $repository.commit='c'*40
 $rejected=$false;try{$null=Read-R4PreparedAssets $Directory '1.2.3' @('Slim') @($repository) $pin}catch{$rejected=$true}
 if(!$rejected){throw 'Changed source was accepted.'};$repository.commit='a'*40
 $pin.sha256='d'*64
 $rejected=$false;try{$null=Read-R4PreparedAssets $Directory '1.2.3' @('Slim') @($repository) $pin}catch{$rejected=$true}
 if(!$rejected){throw 'Changed Recovery pin was accepted.'};$pin.sha256='b'*64
 $null=Read-R4PreparedAssets $Directory '1.2.3' @('Slim') @($repository) $pin
 if((Get-Sha256 $asset) -cne $before){throw 'Read-only preparation verification changed an asset.'}
 Write-Host '[OK] Prepared release: exact ZIP, changed source/pin rejection, no rebuild.'
}
