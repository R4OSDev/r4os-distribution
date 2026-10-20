$ErrorActionPreference = 'Stop'

$qemu = $env:R4OS_QEMU_EXE
$config = $env:R4OS_QEMU_CONFIG
$logPath = $env:R4OS_QEMU_LOG
$errorPath = $env:R4OS_QEMU_ERROR_LOG
$workingDirectory = $env:R4OS_QEMU_WORKING_DIRECTORY
$stopMarker = $env:R4OS_QEMU_STOP_MARKER

$hostProfileTool = Join-Path $PSScriptRoot '../Tools/Qemu-HostProfile.ps1'
if (-not (Test-Path -LiteralPath $hostProfileTool -PathType Leaf)) {
    Write-Host ('QEMU host profile tool not found: ' + $hostProfileTool)
    exit 125
}
. $hostProfileTool

$timeoutSeconds = 1200
if ($env:QEMU_TEST_TIMEOUT_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:QEMU_TEST_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) {
        $timeoutSeconds = $parsed
    }
}

$cpuCount = 4
if ($env:R4OS_QEMU_CPUS) {
    $parsedCpuCount = 0
    if (-not [int]::TryParse($env:R4OS_QEMU_CPUS, [ref]$parsedCpuCount) -or
        $parsedCpuCount -ne 4) {
        Write-Host ('Invalid R4OS_QEMU_CPUS: ' + $env:R4OS_QEMU_CPUS)
        exit 125
    }
    $cpuCount = $parsedCpuCount
}

function Assert-File([string]$Path, [string]$Label) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host ($Label + ' not found: ' + $Path)
        exit 125
    }
}

function Quote-Argument([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Normalize-StartProcessEnvironment {
    $pathEntries = @([Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { [string]$_.Key -ieq 'Path' })
    if ($pathEntries.Count -le 1) { return }
    $canonical = @($pathEntries | Where-Object { [string]$_.Key -ceq 'Path' } | Select-Object -First 1)
    $pathValue = if ($canonical.Count -eq 1) { [string]$canonical[0].Value } else { [string]$pathEntries[0].Value }
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', $pathValue, 'Process')
}

Assert-File $qemu 'QEMU executable'
Assert-File $config 'QEMU config'
$hostProfile = Resolve-R4QemuHostProfile $qemu
if ($env:R4OS_QEMU_EXPECTED_BACKEND -and $env:R4OS_QEMU_EXPECTED_BACKEND -cne $hostProfile.Name) {
    throw 'The selected accelerator differs from the benchmark metadata.'
}
$accelerator = if ($env:R4OS_QEMU_STRICT_ACCELERATOR -ceq '1') { $hostProfile.AcceleratorChain.Split(':')[0] } else { $hostProfile.AcceleratorChain }
$cpuModel = $hostProfile.CpuModel
$entropyArguments = @()
foreach ($key in @('R4OS_QEMU_DISABLE_RDRAND', 'R4OS_QEMU_ENTROPY_DEVICE')) {
    $value = [Environment]::GetEnvironmentVariable($key)
    if ($value -and $value -cnotin @('0', '1')) { throw ('Invalid Boolean ' + $key) }
}
if ($env:R4OS_QEMU_DISABLE_RDRAND -ceq '1' -or $env:R4OS_QEMU_ENTROPY_DEVICE -ceq '1') {
    if (-not $IsLinux -or $hostProfile.Name -cne 'KVM' -or $accelerator -cne 'kvm') {
        throw 'The explicit entropy qualification profile requires strict Linux KVM.'
    }
}
if ($env:R4OS_QEMU_DISABLE_RDRAND -ceq '1') { $cpuModel += ',rdrand=off' }
if ($env:R4OS_QEMU_ENTROPY_DEVICE -ceq '1') {
    $maximum = 1024
    $period = 1
    foreach ($setting in @(@('R4OS_QEMU_RNG_MAX_BYTES', 1, 4096), @('R4OS_QEMU_RNG_PERIOD_MS', 1, 1000))) {
        $value = [Environment]::GetEnvironmentVariable($setting[0])
        if (-not $value) { continue }
        $number = 0
        if (-not [int]::TryParse($value, [ref]$number) -or $number -lt $setting[1] -or $number -gt $setting[2]) {
            throw ('Invalid bounded entropy device setting: ' + $setting[0])
        }
        if ($setting[0] -ceq 'R4OS_QEMU_RNG_MAX_BYTES') { $maximum = $number } else { $period = $number }
    }
    Assert-File '/dev/urandom' 'Host entropy device'
    $entropyArguments = @('-object', 'rng-random,id=r4entropy,filename=/dev/urandom',
        '-device', ('virtio-rng-pci,rng=r4entropy,disable-legacy=on,max-bytes=' + $maximum + ',period=' + $period))
}
if (-not $logPath -or -not $errorPath) {
    Write-Host 'QEMU headless helper: log paths are not configured.'
    exit 125
}
if (-not $workingDirectory -or -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
    Write-Host ('QEMU working directory not found: ' + $workingDirectory)
    exit 125
}

$audioDevice = 'driver=none,id=headless-audio'
if ($env:R4OS_QEMU_WAV_OUTPUT) {
    $wavPath = [IO.Path]::GetFullPath($env:R4OS_QEMU_WAV_OUTPUT)
    if (Test-Path -LiteralPath $wavPath) { throw "WAV evidence already exists: $wavPath" }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($wavPath)) | Out-Null
    $audioDevice = 'driver=wav,id=headless-audio,path=' + $wavPath.Replace(',', ',,')
}

$nvmeTestDisk = $env:R4OS_QEMU_NVME_TEST_DISK
if ($nvmeTestDisk) { Assert-File $nvmeTestDisk 'NVMe IRQ test namespace' }
$nvmeArguments = if ($nvmeTestDisk) {
    @('-drive', (Quote-Argument ('if=none,id=r4nvme,format=raw,file=' + $nvmeTestDisk.Replace(',', ',,'))),
      '-device', 'nvme,drive=r4nvme,serial=R4OS-NVMEIRQ')
} else { @() }
$fatTestDisk = $env:R4OS_QEMU_FAT_TEST_DISK
if ($fatTestDisk) { Assert-File $fatTestDisk 'Private FAT32 test volume' }
$fatArguments = if ($fatTestDisk) {
    @('-drive', (Quote-Argument ('if=none,id=r4fat,format=raw,file=' + $fatTestDisk.Replace(',', ',,'))),
      '-device', 'ide-hd,drive=r4fat,bus=ahci0.1')
} else { @() }

$argumentLine = (@(
    '-readconfig', (Quote-Argument $config),
    '-cpu', $cpuModel,
    '-m', '1G',
    '-smp', ([string]$cpuCount),
    '-machine', ('accel=' + $accelerator),
    '-nic', 'none',
    '-audiodev', (Quote-Argument $audioDevice),
    '-global', 'hda-duplex.audiodev=headless-audio',
    '-serial', (Quote-Argument ('file:' + $logPath)),
    '-display', 'none',
    '-no-reboot',
    '-name', (Quote-Argument ('R4OS test ' + $cpuCount + 'cpu'))
) + $nvmeArguments + $fatArguments + $entropyArguments) -join ' '

Write-Host ('=== QEMU headless smoke; host=' + $hostProfile.Name + '; cpus=' + $cpuCount + ' timeout ' + $timeoutSeconds + 's ===')
Normalize-StartProcessEnvironment
$startParameters = @{
    FilePath = $qemu
    ArgumentList = $argumentLine
    WorkingDirectory = $workingDirectory
    RedirectStandardError = $errorPath
    PassThru = $true
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $startParameters.WindowStyle = 'Hidden'
}
$recordPath = ''
if ($env:R4OS_QEMU_LAUNCH_RECORD) {
    $recordPath = [IO.Path]::GetFullPath($env:R4OS_QEMU_LAUNCH_RECORD)
    if (Test-Path -LiteralPath $recordPath) { throw ('QEMU launch evidence already exists: ' + $recordPath) }
}
$process = Start-Process @startParameters
if ($recordPath) {
    $record = [ordered]@{ status = 'started'; pid = $process.Id; started_utc = [DateTime]::UtcNow.ToString('o');
        executable = $qemu; config = $config; cpu_model = $cpuModel; cpus = $cpuCount;
        accelerator = $accelerator; arguments = $argumentLine; working_directory = $workingDirectory }
    try {
        [IO.File]::WriteAllText($recordPath, (($record | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    } catch {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        throw
    }
}
if ($stopMarker) {
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            try {
                $stream = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $reader = [IO.StreamReader]::new($stream)
                    try {
                        $serialText = $reader.ReadToEnd()
                    } finally {
                        $reader.Dispose()
                    }
                } finally {
                    $stream.Dispose()
                }
                if ($serialText.IndexOf($stopMarker, [StringComparison]::Ordinal) -ge 0) {
                    Write-Host ('=== QEMU short-smoke marker reached; terminating process: ' + $stopMarker + ' ===')
                    if (-not $process.HasExited) {
                        $process.Kill()
                        $process.WaitForExit(5000) | Out-Null
                    }
                    exit 0
                }
            } catch [IO.IOException] {
                # QEMU may still be creating or flushing the serial file.
            }
        }
        Start-Sleep -Milliseconds 100
    }
} elseif ($process.WaitForExit($timeoutSeconds * 1000)) {
    exit $process.ExitCode
}

if ($process.HasExited) {
    exit $process.ExitCode
}

Write-Host ('=== QEMU TIMEOUT after ' + $timeoutSeconds + 's; terminating process ===')
try {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit(5000) | Out-Null
    }
} catch {
    Write-Host ('QEMU headless helper: termination failed: ' + $_.Exception.Message)
}
exit 124
