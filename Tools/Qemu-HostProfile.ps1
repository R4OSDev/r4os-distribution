function Get-R4QemuAcceleratorNames([string]$QemuPath) {
    if ([string]::IsNullOrWhiteSpace($QemuPath) -or -not (Test-Path -LiteralPath $QemuPath -PathType Leaf)) {
        throw ('QEMU fehlt: ' + $QemuPath)
    }

    $output = @(& $QemuPath -accel help 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('QEMU-Beschleuniger konnten nicht ermittelt werden; Exitcode ' + $exitCode + '.')
    }

    $names = [Collections.Generic.List[string]]::new()
    foreach ($line in $output) {
        $candidate = ([string]$line).Trim()
        if ($candidate -cmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
            $names.Add($candidate)
        }
    }
    if ($names.Count -eq 0) { throw 'QEMU meldet keine Beschleuniger.' }
    return @($names | Sort-Object -Unique)
}

function Test-R4KvmAccess {
    if (-not $IsLinux -or -not (Test-Path -LiteralPath '/dev/kvm')) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::Open('/dev/kvm', [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-R4WhpxRuntime {
    if (-not $IsWindows) { return $false }
    $runtime = Join-Path ([Environment]::SystemDirectory) 'WinHvPlatform.dll'
    return Test-Path -LiteralPath $runtime -PathType Leaf
}

function Select-R4QemuHostProfile {
    param(
        [ValidateSet('Linux', 'Windows', 'MacOS', 'Other')]
        [string]$Platform,

        [string]$Architecture,

        [string[]]$AvailableAccelerators,

        [bool]$KvmAccessible = $false,

        [bool]$WhpxRuntimeAvailable = $false
    )

    $available = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $AvailableAccelerators) {
        if (-not [string]::IsNullOrWhiteSpace($name)) { $available.Add($name) | Out-Null }
    }
    if (-not $available.Contains('tcg')) {
        throw 'Die deterministische TCG-Rueckfallebene fehlt in diesem QEMU.'
    }

    $x64Host = $Architecture.Equals('X64', [StringComparison]::OrdinalIgnoreCase)
    if ($Platform -eq 'Linux' -and $x64Host -and $KvmAccessible -and $available.Contains('kvm')) {
        return [pscustomobject]@{
            Name = 'KVM'
            AcceleratorChain = 'kvm:tcg'
            CpuModel = 'host'
            HardwareAccelerated = $true
        }
    }
    if ($Platform -eq 'Windows' -and $x64Host -and $WhpxRuntimeAvailable -and $available.Contains('whpx')) {
        return [pscustomobject]@{
            Name = 'WHPX'
            AcceleratorChain = 'whpx:tcg'
            CpuModel = 'Haswell'
            HardwareAccelerated = $true
        }
    }
    if ($Platform -eq 'MacOS' -and $x64Host -and $available.Contains('hvf')) {
        return [pscustomobject]@{
            Name = 'HVF'
            AcceleratorChain = 'hvf:tcg'
            CpuModel = 'Haswell'
            HardwareAccelerated = $true
        }
    }
    return [pscustomobject]@{
        Name = 'TCG'
        AcceleratorChain = 'tcg'
        CpuModel = 'Haswell'
        HardwareAccelerated = $false
    }
}

function Resolve-R4QemuHostProfile([string]$QemuPath) {
    $platform = if ($IsLinux) {
        'Linux'
    } elseif ($IsWindows) {
        'Windows'
    } elseif ($IsMacOS) {
        'MacOS'
    } else {
        'Other'
    }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $selection = @{
        Platform = $platform
        Architecture = $architecture
        AvailableAccelerators = @(Get-R4QemuAcceleratorNames $QemuPath)
        KvmAccessible = $(Test-R4KvmAccess)
        WhpxRuntimeAvailable = $(Test-R4WhpxRuntime)
    }
    return Select-R4QemuHostProfile @selection
}

function Assert-R4QemuHostProfile($Profile, [string]$Name, [string]$Accelerators, [string]$Cpu, [bool]$Accelerated) {
    if ($Profile.Name -cne $Name -or
        $Profile.AcceleratorChain -cne $Accelerators -or
        $Profile.CpuModel -cne $Cpu -or
        $Profile.HardwareAccelerated -ne $Accelerated) {
        throw ('Unerwartetes QEMU-Hostprofil fuer ' + $Name + '.')
    }
}

function Test-R4QemuHostProfileSelection {
    $linux = Select-R4QemuHostProfile Linux X64 @('tcg', 'kvm') $true $false
    Assert-R4QemuHostProfile $linux 'KVM' 'kvm:tcg' 'host' $true

    $linuxFallback = Select-R4QemuHostProfile Linux X64 @('tcg', 'kvm') $false $false
    Assert-R4QemuHostProfile $linuxFallback 'TCG' 'tcg' 'Haswell' $false

    $windows = Select-R4QemuHostProfile Windows X64 @('tcg', 'whpx') $false $true
    Assert-R4QemuHostProfile $windows 'WHPX' 'whpx:tcg' 'Haswell' $true

    $windowsFallback = Select-R4QemuHostProfile Windows X64 @('tcg', 'whpx') $false $false
    Assert-R4QemuHostProfile $windowsFallback 'TCG' 'tcg' 'Haswell' $false

    $mac = Select-R4QemuHostProfile MacOS X64 @('tcg', 'hvf') $false $false
    Assert-R4QemuHostProfile $mac 'HVF' 'hvf:tcg' 'Haswell' $true

    $macArm = Select-R4QemuHostProfile MacOS Arm64 @('tcg', 'hvf') $false $false
    Assert-R4QemuHostProfile $macArm 'TCG' 'tcg' 'Haswell' $false

    $missingFallbackRejected = $false
    try {
        Select-R4QemuHostProfile Linux X64 @('kvm') $true $false | Out-Null
    }
    catch {
        $missingFallbackRejected = $true
    }
    if (-not $missingFallbackRejected) { throw 'QEMU-Hostprofil akzeptiert fehlendes TCG.' }

    Write-Host 'QEMU host profile selection self-test OK.'
}
