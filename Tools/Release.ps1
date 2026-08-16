[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Publish', 'SelfTest')]
    [string]$Action = 'Prepare',

    [string]$Profiles = 'Standard',

    [switch]$Prerelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:GitHubOrganization = 'R4OSDev'
$script:GitHubRepository = 'r4os-distribution'
$script:GitHubApiVersion = '2022-11-28'
$script:MaximumAssetBytes = 2GB

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $normalized, $script:Utf8NoBom)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    Write-Utf8NoBom -Path $Path -Text ($json + "`n")
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash($stream)
        return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Read-KeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required settings file not found: $Path"
    }

    $result = @{}
    foreach ($rawLine in [IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.TrimStart([char]0xFEFF).Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim().ToUpperInvariant()
        $value = $line.Substring($separator + 1).Trim()
        $result[$key] = $value
    }
    return $result
}

function Require-Setting {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $key = $Name.ToUpperInvariant()
    if (-not $Settings.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Settings[$key])) {
        throw "Required setting is missing: $Name"
    }
    return [string]$Settings[$key]
}

function Resolve-MappedPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Value))
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath"
    }
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git.exe -C $RepositoryPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        $message = ($output -join [Environment]::NewLine).Trim()
        if ($message.Length -eq 0) {
            $message = 'no diagnostic output'
        }
        throw "Git command failed in ${RepositoryPath}: $message"
    }
    return $output
}

function Get-ReleaseContext {
    $distributionRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $settingsPath = Join-Path $distributionRoot 'Settings.R4S'
    $settings = Read-KeyValueFile -Path $settingsPath

    $workspaceRoot = Resolve-MappedPath -BasePath $distributionRoot -Value (Require-Setting $settings 'WORKSPACE_ROOT')
    $repositoriesRoot = Resolve-MappedPath -BasePath $distributionRoot -Value (Require-Setting $settings 'REPOSITORIES_ROOT')
    $devKitRoot = Resolve-MappedPath -BasePath $workspaceRoot -Value (Require-Setting $settings 'DEVKIT_ROOT')
    $artifactsRoot = Resolve-MappedPath -BasePath $workspaceRoot -Value (Require-Setting $settings 'ARTIFACTS_ROOT')
    $distributionOutputRoot = Resolve-MappedPath -BasePath $artifactsRoot -Value (Require-Setting $settings 'DISTRIBUTION_OUTPUT_ROOT')

    return [pscustomobject][ordered]@{
        DistributionRoot = $distributionRoot
        WorkspaceRoot = $workspaceRoot
        RepositoriesRoot = $repositoriesRoot
        DevKitRoot = $devKitRoot
        ArtifactsRoot = $artifactsRoot
        DistributionOutputRoot = $distributionOutputRoot
        ProfileOutputRoot = Join-Path $distributionOutputRoot 'Profiles'
        ReleaseOutputRoot = Join-Path $distributionOutputRoot 'Releases'
        BuildScript = Join-Path $distributionRoot 'Build.bat'
        VersionFile = Join-Path $distributionRoot 'Injection\R4OS\CONFIG\VERSION.R4S'
        ProfileSourceRoot = Join-Path $distributionRoot 'Profiles'
        QemuConfig = Join-Path $distributionRoot 'QEMU\standard.conf'
        ImageCreator = Join-Path $distributionOutputRoot 'HostTools\bin\imagecreater.exe'
        ContractRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'CONTRACT_ROOT')
        SdkRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'SDK_ROOT')
        LibrariesRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'LIBRARIES_ROOT')
        KernelRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'KERNEL_ROOT')
        AppsRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'APPS_ROOT')
        ServicesRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'SERVICES_ROOT')
        DiagnosticsRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'DIAGNOSTICS_ROOT')
        DriversRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'DRIVERS_ROOT')
        ProtocolsRoot = Resolve-MappedPath -BasePath $repositoriesRoot -Value (Require-Setting $settings 'PROTOCOLS_ROOT')
        ZigExe = Join-Path (Resolve-MappedPath -BasePath $devKitRoot -Value (Require-Setting $settings 'ZIG_ROOT')) 'zig.exe'
        LimineExe = Join-Path (Resolve-MappedPath -BasePath $devKitRoot -Value (Require-Setting $settings 'LIMINE_ROOT')) 'limine-tool-windows-x86\limine.exe'
        QemuExe = Join-Path (Resolve-MappedPath -BasePath $devKitRoot -Value (Require-Setting $settings 'QEMU_ROOT')) 'qemu-system-x86_64.exe'
    }
}

function Get-ReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = Read-KeyValueFile -Path $Path
    $version = Require-Setting $values 'RELEASE_VERSION'
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Invalid RELEASE_VERSION in ${Path}: $version"
    }
    return $version
}

function Resolve-ProfileNames {
    param([Parameter(Mandatory = $true)][string]$Selection)

    switch ($Selection.ToUpperInvariant()) {
        'STANDARD' { return @('Slim', 'Full') }
        'SLIM' { return @('Slim') }
        'FULL' { return @('Full') }
        'TEST' { return @('Test') }
        'ALL' { return @('Slim', 'Full', 'Test') }
        default { throw "Unknown release profile selection: $Selection" }
    }
}

function Get-ProfileDefinition {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $path = Join-Path $Context.ProfileSourceRoot ($Profile + '.R4S')
    $values = Read-KeyValueFile -Path $path
    $declaredProfile = Require-Setting $values 'PROFILE'
    if ($declaredProfile -cne $Profile) {
        throw "Profile identity mismatch in ${path}: $declaredProfile"
    }
    $dataMbText = Require-Setting $values 'DATA_MB'
    $dataMb = 0
    if (-not [int]::TryParse($dataMbText, [ref]$dataMb) -or $dataMb -le 0) {
        throw "Invalid DATA_MB in ${path}: $dataMbText"
    }
    return [pscustomobject][ordered]@{
        Name = $Profile
        DataMb = $dataMb
        SourcePath = $path
        OutputPath = Join-Path $Context.ProfileOutputRoot $Profile
    }
}

function New-RepositorySpec {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$GitHubRepository
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Path = [IO.Path]::GetFullPath($Path)
        GitHubRepository = $GitHubRepository
        ExpectedRemote = "https://github.com/${GitHubRepository}.git"
    }
}

function Get-RepositorySpecs {
    param([Parameter(Mandatory = $true)]$Context)

    $specs = @()
    $specs += New-RepositorySpec 'Project' $Context.WorkspaceRoot 'R4OSDev/r4os-project'
    $specs += New-RepositorySpec 'DevKit' $Context.DevKitRoot 'R4OSDev/r4os-devkit'
    $specs += New-RepositorySpec 'Contract' $Context.ContractRoot 'R4OSDev/r4os-contract'
    $specs += New-RepositorySpec 'SDK' $Context.SdkRoot 'R4OSDev/r4os-sdk'
    $specs += New-RepositorySpec 'Libraries' $Context.LibrariesRoot 'R4OSDev/r4os-libraries'
    $specs += New-RepositorySpec 'Kernel' $Context.KernelRoot 'R4OSDev/r4os-kernel'
    $specs += New-RepositorySpec 'Distribution' $Context.DistributionRoot 'R4OSDev/r4os-distribution'

    $roles = @(
        [pscustomobject]@{ Label = 'App'; Root = $Context.AppsRoot; Slug = 'app' },
        [pscustomobject]@{ Label = 'Service'; Root = $Context.ServicesRoot; Slug = 'service' },
        [pscustomobject]@{ Label = 'Diagnostic'; Root = $Context.DiagnosticsRoot; Slug = 'diagnostic' },
        [pscustomobject]@{ Label = 'Driver'; Root = $Context.DriversRoot; Slug = 'driver' },
        [pscustomobject]@{ Label = 'Protocol'; Root = $Context.ProtocolsRoot; Slug = 'protocol' }
    )

    foreach ($role in $roles) {
        if (-not (Test-Path -LiteralPath $role.Root -PathType Container)) {
            continue
        }
        foreach ($directory in Get-ChildItem -LiteralPath $role.Root -Directory | Sort-Object Name) {
            if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName '.git'))) {
                continue
            }
            $componentSlug = $directory.Name.ToLowerInvariant()
            $repositoryName = "R4OSDev/r4os-$($role.Slug)-$componentSlug"
            $specs += New-RepositorySpec "$($role.Label)/$($directory.Name)" $directory.FullName $repositoryName
        }
    }

    return @($specs | Sort-Object Name)
}

function Get-WorkspaceRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    $rootPrefix = $root + '\'
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the workspace: $fullPath"
    }
    return $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-RepositorySnapshots {
    param([Parameter(Mandatory = $true)]$Context)

    $snapshots = @()
    foreach ($spec in Get-RepositorySpecs -Context $Context) {
        if (-not (Test-Path -LiteralPath (Join-Path $spec.Path '.git'))) {
            throw "Required Git repository is missing: $($spec.Path)"
        }

        $status = @(Invoke-GitCapture $spec.Path @('status', '--porcelain', '--untracked-files=normal'))
        if ($status.Count -gt 0) {
            $preview = ($status | Select-Object -First 20) -join '; '
            throw "Repository has uncommitted files: $($spec.Name): $preview"
        }

        $branch = ((Invoke-GitCapture $spec.Path @('branch', '--show-current')) -join '').Trim()
        if ($branch -cne 'main') {
            throw "Repository is not on main: $($spec.Name): $branch"
        }

        $remote = ((Invoke-GitCapture $spec.Path @('remote', 'get-url', 'origin')) -join '').Trim()
        if ($remote -ine $spec.ExpectedRemote) {
            throw "Unexpected origin for $($spec.Name): $remote"
        }

        $head = ((Invoke-GitCapture $spec.Path @('rev-parse', 'HEAD')) -join '').Trim()
        $originMain = ((Invoke-GitCapture $spec.Path @('rev-parse', 'origin/main')) -join '').Trim()
        if ($head -cne $originMain) {
            throw "Repository is not synchronized with origin/main: $($spec.Name)"
        }

        $snapshots += [pscustomobject][ordered]@{
            name = $spec.Name
            github_repository = $spec.GitHubRepository
            workspace_path = Get-WorkspaceRelativePath $Context.WorkspaceRoot $spec.Path
            branch = $branch
            commit = $head
        }
    }
    return @($snapshots)
}

function Get-ToolRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RecordedPath,
        [string[]]$VersionArguments = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            name = $Name
            workspace_path = $RecordedPath
            present = $false
            version = $null
            sha256 = $null
        }
    }

    $version = $null
    if ($VersionArguments.Count -gt 0) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $versionOutput = @(& $Path @VersionArguments 2>&1 | ForEach-Object { $_.ToString() })
            $versionExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($versionExit -eq 0 -and $versionOutput.Count -gt 0) {
            $version = $versionOutput[0].Trim()
        }
    }

    return [pscustomobject][ordered]@{
        name = $Name
        workspace_path = $RecordedPath
        present = $true
        version = $version
        sha256 = Get-Sha256 -Path $Path
    }
}

function Test-ProfileImage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Definition
    )

    Write-Host "=== Verify $($Definition.Name) image ==="
    Invoke-NativeChecked -FilePath $Context.BuildScript -Arguments @('verify', $Definition.Name)

    $diskImage = Join-Path $Definition.OutputPath 'disk.img'
    $legalRoot = Join-Path $Definition.OutputPath 'Legal'
    if (-not (Test-Path -LiteralPath $diskImage -PathType Leaf)) {
        throw "Verified system image is missing: $diskImage"
    }
    if ((Get-Item -LiteralPath $diskImage).Length -le 0) {
        throw "Verified system image is empty: $diskImage"
    }
    if (-not (Test-Path -LiteralPath $legalRoot -PathType Container)) {
        throw "Staged legal directory is missing: $legalRoot"
    }
    if (-not (Test-Path -LiteralPath $Context.ImageCreator -PathType Leaf)) {
        throw "ImageCreator is missing after verification: $($Context.ImageCreator)"
    }
}

function Get-PackageFileRecords {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $records = @()
    foreach ($file in Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($PackageRoot.TrimEnd('\').Length + 1).Replace('\', '/')
        $records += [pscustomobject][ordered]@{
            path = $relative
            size = $file.Length
            sha256 = Get-Sha256 -Path $file.FullName
        }
    }
    return @($records)
}

function New-ZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDirectory,
        $DestinationPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
}

function New-ProfilePackage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$SourceManifestPath
    )

    $packageName = "R4OS-$Version-$($Definition.Name)-x86_64"
    $packageRoot = Join-Path (Join-Path $StagingRoot '.packages') $packageName
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    $diskSource = Join-Path $Definition.OutputPath 'disk.img'
    $diskTarget = Join-Path $packageRoot 'disk.img'
    $dataTarget = Join-Path $packageRoot 'data.img'
    $legalTarget = Join-Path $packageRoot 'Legal'

    Copy-Item -LiteralPath $diskSource -Destination $diskTarget
    Invoke-NativeChecked -FilePath $Context.ImageCreator -Arguments @('--output', $dataTarget, '--size', [string]$Definition.DataMb)
    $expectedDataBytes = [int64]$Definition.DataMb * 1024 * 1024
    $actualDataBytes = (Get-Item -LiteralPath $dataTarget).Length
    if ($actualDataBytes -ne $expectedDataBytes) {
        throw "Fresh data image has unexpected size for $($Definition.Name): $actualDataBytes"
    }

    Copy-Item -LiteralPath (Join-Path $Definition.OutputPath 'Legal') -Destination $legalTarget -Recurse
    Copy-Item -LiteralPath $Context.QemuConfig -Destination (Join-Path $packageRoot 'qemu.conf')
    Copy-Item -LiteralPath $SourceManifestPath -Destination (Join-Path $packageRoot (Split-Path $SourceManifestPath -Leaf))

    $readme = @"
R4OS $Version - $($Definition.Name) - x86_64

disk.img is the bootable R4OS system image.
data.img is a newly generated empty $($Definition.DataMb) MB data disk.
qemu.conf is the R4OS QEMU drive configuration.
Legal contains the licenses and notices shipped with this build.

The persistent data.img from the developer workspace is never included in a
release because it may contain state from earlier QEMU sessions.
"@
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'README.txt') -Text ($readme + "`n")

    $imageManifestPath = Join-Path $packageRoot 'IMAGE-MANIFEST.json'
    $imageManifest = [pscustomobject][ordered]@{
        schema = 1
        release_version = $Version
        profile = $Definition.Name
        architecture = 'x86_64'
        data_image = [pscustomobject][ordered]@{
            state = 'fresh-empty'
            size_mb = $Definition.DataMb
        }
        files = @(Get-PackageFileRecords -PackageRoot $packageRoot)
    }
    Write-JsonFile -Path $imageManifestPath -Value $imageManifest

    $zipPath = Join-Path $StagingRoot ($packageName + '.zip')
    Write-Host "=== Compress $($Definition.Name) release package ==="
    New-ZipArchive -SourceDirectory $packageRoot -DestinationPath $zipPath
    $zipInfo = Get-Item -LiteralPath $zipPath
    if ($zipInfo.Length -ge $script:MaximumAssetBytes) {
        throw "Release asset reaches GitHub's 2 GiB per-file limit: $($zipInfo.FullName)"
    }
    return $zipPath
}

function New-ReleaseNotes {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string[]]$ProfileNames,
        [Parameter(Mandatory = $true)][string[]]$AssetNames
    )

    $profileText = $ProfileNames -join ', '
    $assets = ($AssetNames | ForEach-Object { '- `' + $_ + '`' }) -join "`n"
    return @"
# R4OS $Version

Architecture: x86_64

Profiles: $profileText

Each ZIP contains a bootable `disk.img`, a freshly generated empty `data.img`,
the QEMU drive configuration, legal material and exact image checksums. The
source manifest records the Git commit of every repository in the release
workspace.

## Assets

$assets
"@
}

function New-ReleasePreparation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string[]]$ProfileNames
    )

    $version = Get-ReleaseVersion -Path $Context.VersionFile
    $tag = 'v' + $version
    $definitions = @($ProfileNames | ForEach-Object { Get-ProfileDefinition $Context $_ })
    $repositories = @(Get-RepositorySnapshots -Context $Context)
    $distributionSnapshot = $repositories | Where-Object { $_.name -eq 'Distribution' } | Select-Object -First 1
    if ($null -eq $distributionSnapshot) {
        throw 'Distribution repository is absent from the source snapshot.'
    }

    foreach ($definition in $definitions) {
        Test-ProfileImage -Context $Context -Definition $definition
    }

    if (-not (Test-Path -LiteralPath $Context.ReleaseOutputRoot)) {
        New-Item -ItemType Directory -Path $Context.ReleaseOutputRoot -Force | Out-Null
    }

    $stagingRoot = Join-Path $Context.ReleaseOutputRoot ('.staging-' + $version + '-' + [Guid]::NewGuid().ToString('N'))
    $finalRoot = Join-Path $Context.ReleaseOutputRoot $version
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null

    try {
        $sourceManifestName = "R4OS-SOURCES-$version.json"
        $sourceManifestPath = Join-Path $stagingRoot $sourceManifestName
        $tools = @(
            Get-ToolRecord 'Zig' $Context.ZigExe 'DevKit/Toolchains/Zig/zig.exe' @('version')
            Get-ToolRecord 'Limine' $Context.LimineExe 'DevKit/Boot/Limine/limine-tool-windows-x86/limine.exe'
            Get-ToolRecord 'QEMU' $Context.QemuExe 'DevKit/Emulation/QEMU/qemu-system-x86_64.exe' @('--version')
            Get-ToolRecord 'ImageCreator' $Context.ImageCreator 'Artifacts/Distribution/HostTools/bin/imagecreater.exe'
        )
        $sourceManifest = [pscustomobject][ordered]@{
            schema = 1
            release_version = $version
            tag = $tag
            architecture = 'x86_64'
            created_utc = [DateTime]::UtcNow.ToString('o')
            profiles = @($ProfileNames)
            distribution_commit = $distributionSnapshot.commit
            repository_scope = 'complete-local-release-workspace'
            repositories = $repositories
            tools = $tools
        }
        Write-JsonFile -Path $sourceManifestPath -Value $sourceManifest

        $zipPaths = @()
        foreach ($definition in $definitions) {
            $zipPaths += New-ProfilePackage $Context $version $definition $stagingRoot $sourceManifestPath
        }

        $checksumInputs = @($zipPaths) + @($sourceManifestPath)
        $checksumLines = foreach ($path in $checksumInputs | Sort-Object { Split-Path $_ -Leaf }) {
            $hash = Get-Sha256 -Path $path
            "$hash  $(Split-Path $path -Leaf)"
        }
        $checksumPath = Join-Path $stagingRoot 'SHA256SUMS.txt'
        Write-Utf8NoBom -Path $checksumPath -Text (($checksumLines -join "`n") + "`n")

        $assetNames = @($zipPaths | ForEach-Object { Split-Path $_ -Leaf }) + @($sourceManifestName, 'SHA256SUMS.txt')
        $notesPath = Join-Path $stagingRoot 'RELEASE-NOTES.md'
        $notes = New-ReleaseNotes -Version $version -ProfileNames $ProfileNames -AssetNames $assetNames
        Write-Utf8NoBom -Path $notesPath -Text ($notes + "`n")

        $packageScratch = Join-Path $stagingRoot '.packages'
        if (Test-Path -LiteralPath $packageScratch) {
            Remove-Item -LiteralPath $packageScratch -Recurse -Force
        }

        if (Test-Path -LiteralPath $finalRoot) {
            Remove-Item -LiteralPath $finalRoot -Recurse -Force
        }
        Move-Item -LiteralPath $stagingRoot -Destination $finalRoot

        $assets = @(
            Get-ChildItem -LiteralPath $finalRoot -File |
                Where-Object { $_.Name -ne 'RELEASE-NOTES.md' } |
                Sort-Object Name |
                Select-Object -ExpandProperty FullName
        )
        Write-Host "[OK] Release assets prepared: $finalRoot"
        foreach ($asset in $assets) {
            Write-Host "     $(Split-Path $asset -Leaf)"
        }

        return [pscustomobject][ordered]@{
            Version = $version
            Tag = $tag
            Profiles = @($ProfileNames)
            DistributionCommit = $distributionSnapshot.commit
            OutputRoot = $finalRoot
            NotesPath = Join-Path $finalRoot 'RELEASE-NOTES.md'
            Assets = $assets
        }
    }
    catch {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
        throw
    }
}

function New-GitHubClient {
    param([Parameter(Mandatory = $true)][string]$Token)

    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.Http.HttpClient
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('R4OS-ReleaseTool/1.0')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-GitHub-Api-Version', $script:GitHubApiVersion)
    return $client
}

function Send-GitHubJson {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        $Body = $null,
        [int[]]$AllowedStatus = @(200, 201)
    )

    $httpMethod = New-Object Net.Http.HttpMethod($Method)
    $request = New-Object Net.Http.HttpRequestMessage($httpMethod, $Url)
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $request.Content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    }
    $response = $null
    try {
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($AllowedStatus -notcontains $status) {
            throw "GitHub API returned HTTP ${status}: $text"
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Dispose()
    }
}

function Send-GitHubAsset {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][long]$ReleaseId,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ge $script:MaximumAssetBytes) {
        throw "Release asset reaches GitHub's 2 GiB per-file limit: $($file.FullName)"
    }

    $contentType = 'application/octet-stream'
    switch ($file.Extension.ToLowerInvariant()) {
        '.zip' { $contentType = 'application/zip' }
        '.json' { $contentType = 'application/json' }
        '.txt' { $contentType = 'text/plain' }
    }

    $assetName = [Uri]::EscapeDataString($file.Name)
    $url = "https://uploads.github.com/repos/$($script:GitHubOrganization)/$($script:GitHubRepository)/releases/$ReleaseId/assets?name=$assetName"
    $stream = [IO.File]::OpenRead($file.FullName)
    $content = New-Object Net.Http.StreamContent($stream)
    $content.Headers.ContentType = New-Object Net.Http.Headers.MediaTypeHeaderValue($contentType)
    $response = $null
    try {
        $response = $Client.PostAsync($url, $content).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ne 201) {
            throw "GitHub asset upload returned HTTP ${status} for $($file.Name): $text"
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $content.Dispose()
        $stream.Dispose()
    }
}

function Test-RemoteTag {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    $lines = @(Invoke-GitCapture $RepositoryPath @('ls-remote', '--tags', 'origin', "refs/tags/$Tag", "refs/tags/$Tag^{}"))
    if ($lines.Count -eq 0) {
        return
    }
    $peeled = $lines | Where-Object { $_ -like "*refs/tags/$Tag^{}" } | Select-Object -First 1
    $selected = $peeled
    if ($null -eq $selected) {
        $selected = $lines | Select-Object -First 1
    }
    $remoteCommit = ($selected -split '[\s]+')[0]
    if ($remoteCommit -cne $ExpectedCommit) {
        throw "Remote tag $Tag already points to a different commit: $remoteCommit"
    }
}

function Find-GitHubRelease {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $page = 1
    while ($true) {
        $url = "https://api.github.com/repos/$($script:GitHubOrganization)/$($script:GitHubRepository)/releases?per_page=100&page=$page"
        $releases = @(Send-GitHubJson -Client $Client -Method GET -Url $url)
        $matching = @($releases | Where-Object { $_.tag_name -eq $Tag })
        if ($matching.Count -gt 0) {
            return $matching[0]
        }
        if ($releases.Count -lt 100) {
            return $null
        }
        $page++
    }
}

function Publish-Release {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Preparation,
        [Parameter(Mandatory = $true)][bool]$IsPrerelease
    )

    $token = [Environment]::GetEnvironmentVariable('R4OS_GITHUB_TOKEN')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'R4OS_GITHUB_TOKEN is not available for publishing.'
    }

    Test-RemoteTag -RepositoryPath $Context.DistributionRoot -Tag $Preparation.Tag -ExpectedCommit $Preparation.DistributionCommit

    $client = New-GitHubClient -Token $token
    $release = $null
    try {
        $existing = Find-GitHubRelease -Client $client -Tag $Preparation.Tag
        if ($null -ne $existing) {
            throw "GitHub release already exists for tag $($Preparation.Tag). Existing releases are never overwritten."
        }

        $notes = [IO.File]::ReadAllText($Preparation.NotesPath)
        $createBody = [pscustomobject][ordered]@{
            tag_name = $Preparation.Tag
            target_commitish = $Preparation.DistributionCommit
            name = "R4OS $($Preparation.Version)"
            body = $notes
            draft = $true
            prerelease = $IsPrerelease
            generate_release_notes = $false
        }
        $release = Send-GitHubJson -Client $client -Method POST -Url "https://api.github.com/repos/$($script:GitHubOrganization)/$($script:GitHubRepository)/releases" -Body $createBody -AllowedStatus @(201)
        Write-Host "GitHub draft created: $($release.html_url)"

        foreach ($asset in $Preparation.Assets) {
            Write-Host "Upload: $(Split-Path $asset -Leaf)"
            Send-GitHubAsset -Client $client -ReleaseId ([long]$release.id) -Path $asset
        }

        $publishBody = [pscustomobject][ordered]@{
            draft = $false
            prerelease = $IsPrerelease
        }
        $published = Send-GitHubJson -Client $client -Method PATCH -Url "https://api.github.com/repos/$($script:GitHubOrganization)/$($script:GitHubRepository)/releases/$($release.id)" -Body $publishBody
        Write-Host "[OK] GitHub release published: $($published.html_url)"
    }
    catch {
        if ($null -ne $release) {
            Write-Host "The incomplete release remains a GitHub draft: $($release.html_url)"
        }
        throw
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-ReleaseSelfTest {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('R4OS-Release-SelfTest-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $versionFile = Join-Path $tempRoot 'VERSION.R4S'
        Write-Utf8NoBom -Path $versionFile -Text "RELEASE_VERSION=1.2.3`n"
        if ((Get-ReleaseVersion -Path $versionFile) -cne '1.2.3') {
            throw 'Version parsing self-test failed.'
        }
        if (((Resolve-ProfileNames 'Standard') -join ',') -cne 'Slim,Full') {
            throw 'Standard profile selection self-test failed.'
        }
        if (((Resolve-ProfileNames 'All') -join ',') -cne 'Slim,Full,Test') {
            throw 'All profile selection self-test failed.'
        }
        if ((Get-WorkspaceRelativePath -WorkspaceRoot $tempRoot -Path $tempRoot) -cne '.') {
            throw 'Workspace-root path self-test failed.'
        }

        $packageRoot = Join-Path $tempRoot 'Package'
        $nestedRoot = Join-Path $packageRoot 'Nested'
        New-Item -ItemType Directory -Path $nestedRoot -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $packageRoot 'README.txt') -Text "fixture`n"
        Write-Utf8NoBom -Path (Join-Path $nestedRoot 'file.txt') -Text "payload`n"
        $records = @(Get-PackageFileRecords -PackageRoot $packageRoot)
        if ($records.Count -ne 2) {
            throw 'Package manifest self-test failed.'
        }
        $toolRecord = Get-ToolRecord 'Fixture' (Join-Path $packageRoot 'README.txt') 'Fixture/README.txt'
        if (-not $toolRecord.present -or $toolRecord.workspace_path -cne 'Fixture/README.txt' -or $toolRecord.sha256.Length -ne 64) {
            throw 'Tool provenance self-test failed.'
        }

        $zipPath = Join-Path $tempRoot 'Package.zip'
        New-ZipArchive -SourceDirectory $packageRoot -DestinationPath $zipPath
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            throw 'ZIP creation self-test failed.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            if ($archive.Entries.Count -ne 2) {
                throw 'ZIP content self-test failed.'
            }
        }
        finally {
            $archive.Dispose()
        }

        $jsonPath = Join-Path $tempRoot 'manifest.json'
        Write-JsonFile -Path $jsonPath -Value ([pscustomobject][ordered]@{ schema = 1; ok = $true })
        $roundTrip = [IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json
        if ($roundTrip.schema -ne 1 -or -not $roundTrip.ok) {
            throw 'JSON self-test failed.'
        }

        $client = New-GitHubClient -Token 'release-selftest-token'
        try {
            if ($client.DefaultRequestHeaders.Authorization.Scheme -cne 'Bearer') {
                throw 'GitHub client self-test failed.'
            }
        }
        finally {
            $client.Dispose()
        }
        Write-Host '[OK] Release tool self-test passed.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

try {
    if ($Action -eq 'SelfTest') {
        Invoke-ReleaseSelfTest
        exit 0
    }

    $context = Get-ReleaseContext
    $profileNames = @(Resolve-ProfileNames -Selection $Profiles)
    $preparation = New-ReleasePreparation -Context $context -ProfileNames $profileNames

    if ($Action -eq 'Publish') {
        Publish-Release -Context $context -Preparation $preparation -IsPrerelease ([bool]$Prerelease)
    }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}
