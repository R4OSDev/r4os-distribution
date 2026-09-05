# Shared PowerShell 7 orchestration. This remains a technical image producer
# until the release pipeline supplies its separately published Recovery pin.
function Get-InstallationFields([string]$Path) {
    $result=@{}
    foreach($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if($line -match '^([A-Z_]+)=(.+)$'){$result[$Matches[1]]=$Matches[2].Trim()}
    }
    return $result
}
function Get-InstallationPath([string]$Base,[string]$Path) {
    return [IO.Path]::GetFullPath((Join-Path $Base $Path.Replace('\',[IO.Path]::DirectorySeparatorChar)))
}
function Invoke-InstallationTool([string]$Program,[string[]]$Arguments) {
    & $Program @Arguments
    if($LASTEXITCODE -ne 0){throw "Installation image tool failed: $Program"}
}
function Expand-InstallationRecovery([string]$Package,[string]$Destination) {
    $archive=[IO.Compression.ZipFile]::OpenRead($Package)
    try {
        if($archive.Entries.Count -lt 4 -or $archive.Entries.Count -gt 4096){throw 'Invalid Recovery file count.'}
        $entry=$archive.GetEntry('manifest.json')
        if(!$entry -or $entry.Length -eq 0 -or $entry.Length -gt 1MB){throw 'Missing Recovery manifest.'}
        $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
        try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}
        if($manifest.schema -ne 1 -or $manifest.product -cne 'r4os-recovery' -or $manifest.architecture -cne 'x86_64' -or
            $manifest.runtime.format -cne 'fat32' -or $manifest.runtime.logicalSectorBytes -ne 512 -or
            $manifest.recoveryVersion -cnotmatch '^\d+\.\d+\.\d+$'){throw 'Incompatible Recovery package.'}
        $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($file in $manifest.files) {
            if($expected.ContainsKey($file.path) -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $file.bytes -lt 0){throw 'Invalid Recovery file manifest.'}
            $expected.Add($file.path,$file)
        }
        if(!$expected.ContainsKey('recovery.elf') -or !$expected.ContainsKey('runtime.img') -or
            $expected.Count+1 -ne $archive.Entries.Count){throw 'Incomplete Recovery package.'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$expanded=0
        foreach($file in $archive.Entries) {
            $path=$file.FullName
            if(!$seen.Add($path) -or $path.Length -gt 255 -or $path -cmatch '[^\x20-\x7e]|[<>:"\\|?*]'){throw 'Unsafe Recovery path.'}
            foreach($part in $path.Split('/')){if(!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ')){throw 'Unsafe Recovery path component.'}}
            $expanded+=$file.Length
            if($file.Length -gt 1GB -or $expanded -gt 1GB){throw 'Recovery exceeds technical expansion limit.'}
            if($path -ceq 'manifest.json'){continue}
            if(!$expected.ContainsKey($path) -or $expected[$path].bytes -ne $file.Length){throw "Unexpected Recovery file: $path"}
            $stream=$file.Open();$hash=[Security.Cryptography.SHA256]::Create()
            try{$actual=[Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant()}finally{$hash.Dispose();$stream.Dispose()}
            if($actual -cne $expected[$path].sha256){throw "Recovery SHA256 mismatch: $path"}
        }
        # Every entry was validated before its first filesystem extraction.
        if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Recurse -Force}
        [IO.Directory]::CreateDirectory($Destination)|Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive,$Destination)
        return $manifest
    }finally{$archive.Dispose()}
}
function New-R4OSInstallationImage {
    param([Parameter(Mandatory)][string]$Root,[ValidateSet('Slim','Full')][string]$Profile='Slim',
          [string]$InputList='', [string]$RecoveryPackage='', [ValidateSet('local','usb')][string]$Medium='local', [string]$OutputRoot='')
    $settings=Get-InstallationFields (Join-Path $Root 'Settings.R4S')
    $workspace=Get-InstallationPath $Root $settings.WORKSPACE_ROOT
    $repositories=Get-InstallationPath $Root $settings.REPOSITORIES_ROOT
    $sdk=Get-InstallationPath $repositories $settings.SDK_ROOT
    $contract=Get-InstallationPath $repositories $settings.CONTRACT_ROOT
    $libraries=Get-InstallationPath $repositories $settings.LIBRARIES_ROOT
    $devkit=Get-InstallationPath $workspace $settings.DEVKIT_ROOT
    $artifacts=Get-InstallationPath $workspace $settings.ARTIFACTS_ROOT
    $distribution=Get-InstallationPath $artifacts $settings.DISTRIBUTION_OUTPUT_ROOT
    $suffix=if($IsWindows){'.exe'}else{''}
    $zig=Join-Path (Get-InstallationPath $devkit $settings.ZIG_ROOT) "zig$suffix"
    $prefix=Join-Path $distribution 'HostTools'
    $generatePlan=!$InputList
    if($generatePlan){$InputList=Join-Path $distribution "Profiles/$Profile/image-adds.txt"}
    if(!$OutputRoot){$OutputRoot=Join-Path $distribution "RecoveryImages/$Profile-$Medium"}
    $OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
    $allowed=[IO.Path]::GetFullPath($distribution)+[IO.Path]::DirectorySeparatorChar
    if(!$OutputRoot.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Technical image output must remain below Distribution artifacts.'}
    [IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
    Push-Location $Root
    try{Invoke-InstallationTool $zig @('build','--prefix',$prefix,"--fork=$sdk","--fork=$contract","--fork=$libraries")}
    finally{Pop-Location}
    if($generatePlan){
        # Reuse the owner's current overlay/plan policy instead of keeping a
        # second image-plan recipe in this new format's orchestration.
        $starter=Join-Path $Root $(if($IsWindows){'Build.bat'}else{'Build.sh'})
        Invoke-InstallationTool $starter @('plan',$Profile)
    }
    if(!(Test-Path -LiteralPath $InputList -PathType Leaf)){throw "Generate the $Profile image plan first: $InputList"}
    if(!$RecoveryPackage){
        $recoveryRoot=Join-Path $repositories 'Recovery'
        . (Join-Path $recoveryRoot 'Tools/Package.ps1')
        $RecoveryPackage=(New-RecoveryPackage -Root $recoveryRoot).path
    }
    $recoveryDir=Join-Path $OutputRoot 'RecoveryPackage'
    $recovery=Expand-InstallationRecovery $RecoveryPackage $recoveryDir
    $utf8=[Text.UTF8Encoding]::new($false)
    $recoveryList=Join-Path $OutputRoot 'recovery-adds.txt'
    $files=@(Get-ChildItem -LiteralPath $recoveryDir -File -Recurse|Sort-Object FullName -CaseSensitive)
    $lines=@(foreach($slot in @('CURRENT','PREVIOUS')){foreach($file in $files){
        $relative=[IO.Path]::GetRelativePath($recoveryDir,$file.FullName).Replace('\','/')
        "$($file.FullName)|/$slot/$relative"
    }})
    [IO.File]::WriteAllText($recoveryList,($lines -join "`n")+"`n",$utf8)
    $release=(Get-InstallationFields (Join-Path $Root 'Injection/R4OS/CONFIG/VERSION.R4S')).RELEASE_VERSION
    $kernelVersion=(Get-InstallationFields (Join-Path (Get-InstallationPath $repositories $settings.KERNEL_ROOT) 'VERSION.R4S')).KERNEL_VERSION
    $image=Join-Path $OutputRoot 'disk.img';$manifestPath=Join-Path $OutputRoot 'installation.json'
    Invoke-InstallationTool (Join-Path $prefix "bin/imagecreater$suffix") @('create-installation','--output',$image,'--manifest-out',$manifestPath,
        '--add-list',$InputList,'--recovery-list',$recoveryList,'--release-version',$release,'--kernel-version',$kernelVersion,'--medium',$Medium)
    . (Join-Path $PSScriptRoot 'InstallationImage.Check.ps1')
    $checked=Test-R4OSInstallationImage -Image $image -Medium $Medium
    $record=[ordered]@{schema=1;technical=$true;profile=$Profile;medium=$Medium;image=$image;bytes=([IO.FileInfo]$image).Length;
        sha256=(Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant();installation=(Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json -AsHashtable);
        recoveryVersion=$recovery.recoveryVersion;recoveryPackageSha256=(Get-FileHash -LiteralPath $RecoveryPackage -Algorithm SHA256).Hash.ToLowerInvariant();structure=$checked}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'image.json'),(($record|ConvertTo-Json -Depth 20)+"`n"),$utf8)
    Write-Host "Technical five-partition $Profile image ready: $image"
    return $record
}
