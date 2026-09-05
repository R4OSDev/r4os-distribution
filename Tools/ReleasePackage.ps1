# Current Recovery-consumable R4OS format. The caller supplies the common GPT
# image, exact managed BOOT files and one already-built independent Recovery.
function New-R4OSReleasePackage {
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$BootRoot,
          [Parameter(Mandatory)][string]$RecoveryPackage,[Parameter(Mandatory)][string]$LegalRoot,
          [Parameter(Mandatory)][string]$ReleaseVersion,[Parameter(Mandatory)][string]$KernelVersion,
          [ValidateSet('slim','full')][string]$Profile='slim',[Parameter(Mandatory)][string]$OutputRoot)
    $ErrorActionPreference='Stop'
    foreach($version in @($ReleaseVersion,$KernelVersion)){if($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Invalid package version.'}}
    if(([IO.FileInfo]$Image).Length -ne 2147483648){throw 'r4os-gpt-1 requires the standard 2048 MB source image.'}
    $pair=[IO.Compression.ZipFile]::OpenRead($RecoveryPackage)
    try {
        $entry=$pair.GetEntry('manifest.json')
        if(!$entry -or $entry.Length -gt 1048576){throw 'Missing Recovery manifest.'}
        $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
        try{$recovery=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}
        if($recovery.schema -ne 1 -or $recovery.product -cne 'r4os-recovery' -or $recovery.architecture -cne 'x86_64' -or
            $recovery.recoveryVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Incompatible Recovery package.'}
    }finally{$pair.Dispose()}
    [IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
    $stage=Join-Path $OutputRoot 'staging'
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    Copy-Item -LiteralPath $Image -Destination (Join-Path $stage 'disk.img')
    Copy-Item -LiteralPath $RecoveryPackage -Destination (Join-Path $stage 'recovery.zip')
    Copy-Item -LiteralPath $LegalRoot -Destination (Join-Path $stage 'Legal') -Recurse
    $bootFiles=@()
    foreach($file in @(Get-ChildItem -LiteralPath $BootRoot -File -Recurse | Sort-Object FullName -CaseSensitive)){
        $path=[IO.Path]::GetRelativePath($BootRoot,$file.FullName).Replace('\','/')
        if(@($path.Split('/')|Where-Object {$_ -ieq 'limine.conf'}).Count -ne 0){continue}
        $target=Join-Path $stage "BOOT/$path";[IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $bootFiles+=$path
    }
    if($bootFiles.Count -gt 32 -or $bootFiles -cnotcontains 'boot/r4os.elf'){throw 'Missing or excessive managed BOOT files.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files=@(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName -CaseSensitive | ForEach-Object {
        $path=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')
        if($path.Length -gt 255 -or $path -cmatch '[^\x20-\x7e]|[<>:"\\|?*]' -or !$seen.Add($path)){throw "Unsupported package path: $path"}
        foreach($part in $path.Split('/')){if(!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ')){throw "Unsupported path component: $path"}}
        [ordered]@{path=$path;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    if($files.Count -ge 4096){throw 'Too many R4OS package files.'}
    $asset="R4OS-$ReleaseVersion-$Profile-x86_64.zip"
    $manifest=[ordered]@{schema=1;product='r4os';architecture='x86_64';releaseVersion=$ReleaseVersion;kernelVersion=$KernelVersion;
        profile=$Profile;asset=$asset;layout='r4os-gpt-1';recovery=[ordered]@{version=$recovery.recoveryVersion;package='recovery.zip'};bootFiles=$bootFiles;files=$files}
    [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),(($manifest|ConvertTo-Json -Depth 32)+"`n"),[Text.UTF8Encoding]::new($false))
    $archive=Join-Path $OutputRoot $asset
    if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
    return [ordered]@{path=$archive;version=$ReleaseVersion;bytes=([IO.FileInfo]$archive).Length;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();manifest=$manifest}
}
