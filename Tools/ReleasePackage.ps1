# Current Recovery-consumable R4OS format. The caller supplies the common GPT
# image, exact managed BOOT files and one already-built independent Recovery.
function Initialize-R4ReleaseStreams {
    if ('R4ReleaseStreams' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
public static class R4ReleaseStreams {
    public static string CopyAndHash(Stream source, Stream destination) {
        using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = source.Read(buffer, 0, buffer.Length)) != 0) {
                destination.Write(buffer, 0, count);
                hash.AppendData(buffer, 0, count);
            }
            return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        }
    }
}
'@
}

function Copy-R4ReleaseImage {
    param([string]$Source,[string]$Destination,[string]$ExpectedSha256)
    Initialize-R4ReleaseStreams
    $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $digest=[R4ReleaseStreams]::CopyAndHash($inputStream,$outputStream)
            if($digest -cne $ExpectedSha256){throw 'The canonical release image changed after creation.'}
            $outputStream.Flush($true)
        } finally {$outputStream.Dispose()}
    } finally {$inputStream.Dispose()}
}

function New-R4OSReleasePackage {
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$BootRoot,
          [Parameter(Mandatory)][string]$RecoveryPackage,[Parameter(Mandatory)][string]$LegalRoot,
          [Parameter(Mandatory)][string]$ReleaseVersion,[Parameter(Mandatory)][string]$KernelVersion,
          [ValidateSet('slim','full','test')][string]$Profile='slim',[Parameter(Mandatory)][string]$OutputRoot,
          [string]$ExtraRoot='',[switch]$Technical)
    $ErrorActionPreference='Stop'
    Initialize-R4ReleaseStreams
    # Keep the same file open from validation through compression. There is
    # no later path reopen that could substitute a different image.
    $imageStream=[IO.File]::Open($Image,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
    foreach($version in @($ReleaseVersion,$KernelVersion)){if($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Invalid package version.'}}
    if($imageStream.Length -ne 12GB){throw 'r4os-gpt-1 requires the standard 12288 MB source image with 10240 MB SYSTEM.'}
    $pair=[IO.Compression.ZipFile]::OpenRead($RecoveryPackage)
    try {
        $entry=$pair.GetEntry('manifest.json')
        if(!$entry -or $entry.Length -gt 1048576){throw 'Missing Recovery manifest.'}
        $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
        try{$recovery=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}
        $manifestStream=$entry.Open();$hasher=[Security.Cryptography.SHA256]::Create()
        try{$recoveryManifestHash=[Convert]::ToHexString($hasher.ComputeHash($manifestStream)).ToLowerInvariant()}finally{$hasher.Dispose();$manifestStream.Dispose()}
        if($recovery.schema -ne 1 -or $recovery.product -cne 'r4os-recovery' -or $recovery.architecture -cne 'x86_64' -or
            $recovery.recoveryVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Incompatible Recovery package.'}
    }finally{$pair.Dispose()}
    if(!$Technical){
        . (Join-Path $PSScriptRoot 'InstallationImage.Check.ps1')
        $checked=Test-R4OSInstallationImage -Stream $imageStream -ImageBytes $imageStream.Length -Medium local
        if($checked.installation.partitions.SYSTEM.sectorCount -ne 10GB/512){throw 'Release SYSTEM must use the 10 GB default.'}
        if($checked.installation.releaseVersion -cne $ReleaseVersion -or $checked.installation.kernelVersion -cne $KernelVersion -or
            $checked.recoveryVersion -cne $recovery.recoveryVersion -or $checked.recoveryManifestSha256 -cne $recoveryManifestHash){throw 'Release image, versions and pinned Recovery do not agree.'}
        foreach($path in $checked.bootHashes.Keys){if((Get-FileHash -LiteralPath (Join-Path $BootRoot $path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $checked.bootHashes[$path]){throw 'Release BOOT source differs from its image.'}}
        $view=[InstallationImageCheck]::new($imageStream,$imageStream.Length,$false,$true)
        try{if(@($view.Volumes['RECOVERY'].Paths()|Where-Object {$_ -match '^(?i:INSTALL/)'}).Count){throw 'Release image must not contain an original-ZIP cache.'}}finally{$view.Dispose()}
    }
    [IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
    $stage=Join-Path $OutputRoot 'staging'
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    Copy-Item -LiteralPath $RecoveryPackage -Destination (Join-Path $stage 'recovery.zip')
    Copy-Item -LiteralPath $LegalRoot -Destination (Join-Path $stage 'Legal') -Recurse
    if($ExtraRoot){
        foreach($file in Get-ChildItem -LiteralPath $ExtraRoot -File -Recurse){
            $relative=[IO.Path]::GetRelativePath($ExtraRoot,$file.FullName);$target=Join-Path $stage $relative
            if($relative -in @('disk.img','manifest.json')){throw "Reserved release extra: $relative"}
            if(Test-Path -LiteralPath $target){throw "Duplicate release extra: $relative"}
            [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
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
    $sources=@([pscustomobject]@{path='disk.img';source=$Image})+@(Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
        [pscustomobject]@{path=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');source=$_.FullName}
    })
    foreach($source in $sources){
        $path=$source.path
        if($path.Length -gt 255 -or $path -cmatch '[^\x20-\x7e]|[<>:"\\|?*]' -or !$seen.Add($path)){throw "Unsupported package path: $path"}
        foreach($part in $path.Split('/')){if(!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ')){throw "Unsupported path component: $path"}}
    }
    if($sources.Count -ge 4096){throw 'Too many R4OS package files.'}
    $asset="R4OS-$ReleaseVersion-$Profile-x86_64.zip"
    $archive=Join-Path $OutputRoot $asset
    if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}
    $archiveStream=[IO.File]::Open($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $zip=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            $files=@(foreach($source in ($sources|Sort-Object path -CaseSensitive)) {
                $isImage=$source.path -ceq 'disk.img'
                $inputStream=if($isImage){$imageStream}else{[IO.File]::Open($source.source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
                try {
                    $inputStream.Position=0
                    $length=$inputStream.Length
                    $entry=$zip.CreateEntry($source.path,[IO.Compression.CompressionLevel]::Optimal)
                    $outputStream=$entry.Open()
                    try {$digest=[R4ReleaseStreams]::CopyAndHash($inputStream,$outputStream)}finally{$outputStream.Dispose()}
                    if($inputStream.Position -ne $length -or $inputStream.Length -ne $length){throw "Package input changed: $($source.path)"}
                    [ordered]@{path=$source.path;bytes=$length;sha256=$digest}
                }finally{if(!$isImage){$inputStream.Dispose()}}
            })
            $manifest=[ordered]@{schema=1;product='r4os';architecture='x86_64';releaseVersion=$ReleaseVersion;kernelVersion=$KernelVersion;
                profile=$Profile;asset=$asset;layout='r4os-gpt-1';recovery=[ordered]@{version=$recovery.recoveryVersion;package='recovery.zip'};bootFiles=$bootFiles;files=$files}
            $manifestText=($manifest|ConvertTo-Json -Depth 32)+"`n"
            [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),$manifestText,[Text.UTF8Encoding]::new($false))
            $entry=$zip.CreateEntry('manifest.json',[IO.Compression.CompressionLevel]::Optimal)
            $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
            try {$writer.Write($manifestText)}finally{$writer.Dispose()}
        } finally {$zip.Dispose()}
        $archiveStream.Flush($true)
    } finally {$archiveStream.Dispose()}
    if(!$Technical){
        . (Join-Path $PSScriptRoot 'RecoveryBudget.ps1')
        $null=Test-R4RecoveryCacheBudget -FreeBytes $checked.recoveryFreeBytes -ClusterBytes $checked.recoveryClusterBytes -ReleaseBytes ([IO.FileInfo]$archive).Length -RecoveryBytes ([IO.FileInfo]$RecoveryPackage).Length
    }
    return [ordered]@{path=$archive;version=$ReleaseVersion;bytes=([IO.FileInfo]$archive).Length;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();manifest=$manifest}
    } finally {$imageStream.Dispose()}
}
