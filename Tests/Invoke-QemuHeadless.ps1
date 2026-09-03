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

$cpuCount = 1
if ($env:R4OS_QEMU_CPUS) {
    $parsedCpuCount = 0
    if (-not [int]::TryParse($env:R4OS_QEMU_CPUS, [ref]$parsedCpuCount) -or
        $parsedCpuCount -lt 1 -or $parsedCpuCount -gt 32) {
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
if (-not $logPath -or -not $errorPath) {
    Write-Host 'QEMU headless helper: log paths are not configured.'
    exit 125
}
if (-not $workingDirectory -or -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
    Write-Host ('QEMU working directory not found: ' + $workingDirectory)
    exit 125
}

$argumentLine = @(
    '-readconfig', (Quote-Argument $config),
    '-cpu', $hostProfile.CpuModel,
    '-m', '1G',
    '-smp', ([string]$cpuCount),
    '-machine', ('accel=' + $hostProfile.AcceleratorChain),
    '-nic', 'none',
    '-audiodev', 'driver=none,id=headless-audio',
    '-global', 'hda-duplex.audiodev=headless-audio',
    '-serial', (Quote-Argument ('file:' + $logPath)),
    '-display', 'none',
    '-no-reboot',
    '-name', (Quote-Argument ('R4OS test ' + $cpuCount + 'cpu'))
) -join ' '

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
$process = Start-Process @startParameters
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
